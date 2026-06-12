// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {AuthScript} from "@script/Auth.s.sol";
import {CashStrategyVaultScript} from "@script/CashStrategyVault.s.sol";
import {ERC4626StrategyVaultScript} from "@script/ERC4626StrategyVault.s.sol";
import {VeryLiquidVaultScript} from "@script/VeryLiquidVault.s.sol";

import {IVault} from "@src/IVault.sol";
import {ERC4626StrategyVault} from "@src/strategies/ERC4626StrategyVault.sol";
import {BaseTest} from "@test/BaseTest.t.sol";
import {IAaveV4Hub} from "@test/fork/interfaces/IAaveV4.sol";

/// @title ForkTestMainnet
/// @notice Ethereum-mainnet fork base for the Aave V4 integration (issue #11). Sibling to the Base-hardwired
///         {ForkTest}; do not merge them — Aave V4 is mainnet-only today.
/// @dev Deploys a minimal Rheo stack (Auth -> CashStrategyVault + an {ERC4626StrategyVault} over the Aave V4 Core
///      USDC `TokenizationSpoke` -> a {VeryLiquidVault} holding `[cash, aaveV4]`) against live mainnet bytecode, then
///      exposes helpers that drive the Hub's real exit gates so the tests can prove the de-risking exit sensor:
///      - `_setSpokeHalted` / `_setSpokeActive` / `_setSpokeAddCap` flip the on-chain `SpokeConfig` by pranking the
///        HubConfigurator and calling the Hub's `restricted` `updateSpokeConfig` directly (the configurator is the
///        Hub's authorized role holder, verified on-fork). This is real state, so both the views and the underlying
///        execution reverts (`SpokeHalted`/`SpokeNotActive`/`AddCapExceeded`) react.
///      - `_setAssetLiquidity` writes `_assets[assetId].liquidity` (low 120 bits of `keccak256(assetId, slot 1)` in
///        `HubStorage`; slot verified on-fork) to model a liquidity squeeze, so `getAssetLiquidity` and the
///        `InsufficientLiquidity` removal revert both bind.
contract ForkTestMainnet is BaseTest {
    // --- Ethereum mainnet + Aave V4 Core USDC instantiation (issue #11 §2; byte-verified on-fork) ---
    address public constant USDC_MAINNET = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant AAVE_V4_CORE_USDC_TSPOKE = 0x531E90a2376902DE8915789Fcc1075e3B0c153E7;
    address public constant AAVE_V4_CORE_HUB = 0xCca852Bc40e560adC3b1Cc58CA5b55638ce826c9;
    address public constant AAVE_V4_HUB_CONFIGURATOR = 0x1F0753480bB03EaA00863224602267B7E0525C3d;

    /// @dev Slot of the `_assets` mapping in `HubStorage` (slot 0 is `_assetCount`). Verified on-fork: the low 120
    ///      bits of `keccak256(abi.encode(assetId, _ASSETS_SLOT))` equal `getAssetLiquidity(assetId)`.
    uint256 private constant _ASSETS_SLOT = 1;

    IAaveV4Hub internal aaveV4Hub = IAaveV4Hub(AAVE_V4_CORE_HUB);
    IERC4626 internal tokenizationSpoke;
    ERC4626StrategyVault internal aaveV4StrategyVault;
    uint256 internal usdcAssetId;

    function setUp() public virtual override {
        vm.createSelectFork("mainnet");

        FIRST_DEPOSIT_AMOUNT = 10e6;
        admin = address(this);
        erc20Asset = IERC20Metadata(USDC_MAINNET);
        tokenizationSpoke = IERC4626(AAVE_V4_CORE_USDC_TSPOKE);
        usdcAssetId = aaveV4Hub.getAssetId(USDC_MAINNET);

        // Auth: deploy(admin) grants admin all four roles (DEFAULT_ADMIN/VAULT_MANAGER/STRATEGIST/GUARDIAN).
        AuthScript authScript = new AuthScript();
        auth = authScript.deploy(admin);

        // Cash strategy.
        CashStrategyVaultScript cashStrategyVaultScript = new CashStrategyVaultScript();
        _mint(erc20Asset, address(cashStrategyVaultScript), FIRST_DEPOSIT_AMOUNT);
        cashStrategyVault = cashStrategyVaultScript.deploy(auth, erc20Asset, FIRST_DEPOSIT_AMOUNT);

        // Aave V4 strategy = the audited generic ERC4626 wrapper, pointed at the Core USDC TokenizationSpoke.
        ERC4626StrategyVaultScript erc4626StrategyVaultScript = new ERC4626StrategyVaultScript();
        _mint(erc20Asset, address(erc4626StrategyVaultScript), FIRST_DEPOSIT_AMOUNT);
        aaveV4StrategyVault = erc4626StrategyVaultScript.deploy(auth, FIRST_DEPOSIT_AMOUNT, tokenizationSpoke);

        // Very Liquid Vault holding [cash, aaveV4].
        VeryLiquidVaultScript veryLiquidVaultScript = new VeryLiquidVaultScript();
        IVault[] memory strategies = new IVault[](2);
        strategies[0] = IVault(address(cashStrategyVault));
        strategies[1] = IVault(address(aaveV4StrategyVault));
        _mint(erc20Asset, address(veryLiquidVaultScript), strategies.length * FIRST_DEPOSIT_AMOUNT + 1);
        veryLiquidVault = veryLiquidVaultScript.deploy(
            "Test", auth, erc20Asset, strategies.length * FIRST_DEPOSIT_AMOUNT + 1, strategies
        );

        vm.label(USDC_MAINNET, "USDC");
        vm.label(AAVE_V4_CORE_USDC_TSPOKE, "AaveV4_CoreUSDC_TSpoke");
        vm.label(AAVE_V4_CORE_HUB, "AaveV4_CoreHub");
        vm.label(AAVE_V4_HUB_CONFIGURATOR, "AaveV4_HubConfigurator");
        vm.label(address(aaveV4StrategyVault), "AaveV4StrategyVault");
    }

    // --- Hub state helpers (mechanisms verified against live mainnet bytecode) ---

    /// @dev Flips the spoke `halted` kill-switch by pranking the HubConfigurator (the Hub's authorized caller for
    ///      the `restricted` `updateSpokeConfig`).
    function _setSpokeHalted(bool halted) internal {
        IAaveV4Hub.SpokeConfig memory config = aaveV4Hub.getSpokeConfig(usdcAssetId, AAVE_V4_CORE_USDC_TSPOKE);
        config.halted = halted;
        vm.prank(AAVE_V4_HUB_CONFIGURATOR);
        aaveV4Hub.updateSpokeConfig(usdcAssetId, AAVE_V4_CORE_USDC_TSPOKE, config);
    }

    /// @dev Flips the spoke `active` kill-switch (same authorization path as `_setSpokeHalted`).
    function _setSpokeActive(bool active) internal {
        IAaveV4Hub.SpokeConfig memory config = aaveV4Hub.getSpokeConfig(usdcAssetId, AAVE_V4_CORE_USDC_TSPOKE);
        config.active = active;
        vm.prank(AAVE_V4_HUB_CONFIGURATOR);
        aaveV4Hub.updateSpokeConfig(usdcAssetId, AAVE_V4_CORE_USDC_TSPOKE, config);
    }

    /// @dev Sets the spoke `addCap` (whole assets, not scaled by decimals).
    function _setSpokeAddCap(uint40 addCap) internal {
        IAaveV4Hub.SpokeConfig memory config = aaveV4Hub.getSpokeConfig(usdcAssetId, AAVE_V4_CORE_USDC_TSPOKE);
        config.addCap = addCap;
        vm.prank(AAVE_V4_HUB_CONFIGURATOR);
        aaveV4Hub.updateSpokeConfig(usdcAssetId, AAVE_V4_CORE_USDC_TSPOKE, config);
    }

    /// @dev Overwrites `_assets[usdcAssetId].liquidity` (the `getAssetLiquidity` source) to model a squeeze.
    ///      `liquidity` is the first field of the `Asset` struct (a `uint120`), packed in the low 120 bits of the
    ///      struct's base slot; the upper bits (`realizedFees`/`decimals`) are preserved.
    function _setAssetLiquidity(uint256 newLiquidity) internal {
        require(newLiquidity <= type(uint120).max, "ForkTestMainnet: liquidity exceeds uint120");
        bytes32 slot = keccak256(abi.encode(usdcAssetId, _ASSETS_SLOT));
        uint256 raw = uint256(vm.load(AAVE_V4_CORE_HUB, slot));
        uint256 upperBits = raw & ~uint256((uint256(1) << 120) - 1);
        vm.store(AAVE_V4_CORE_HUB, slot, bytes32(upperBits | newLiquidity));
    }
}
