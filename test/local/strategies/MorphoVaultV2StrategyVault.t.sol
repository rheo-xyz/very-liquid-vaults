// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Id, MarketParams} from "@morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@morpho-blue/libraries/MarketParamsLib.sol";

import {MorphoVaultV2StrategyVaultScript} from "@script/MorphoVaultV2StrategyVault.s.sol";
import {IVault} from "@src/IVault.sol";
import {MorphoVaultV2StrategyVault} from "@src/strategies/MorphoVaultV2StrategyVault.sol";

import {BaseTest} from "@test/BaseTest.t.sol";
import {MorphoMarketV1AdapterMock} from "@test/mocks/MorphoMarketV1AdapterMock.t.sol";
import {MorphoMock} from "@test/mocks/MorphoMock.t.sol";
import {VaultV2Mock} from "@test/mocks/VaultV2Mock.t.sol";

/// @notice Unit tests for {MorphoVaultV2StrategyVault}'s on-chain liquidity resolver and gate handling.
/// @dev The underlying {VaultV2Mock} reproduces Morpho V2's "lying" `max* == 0` views so every assertion that
///      the strategy reports non-zero capacity is a direct regression guard against the `min(0, ...) = 0` bug.
contract MorphoVaultV2StrategyVaultTest is BaseTest {
    using MarketParamsLib for MarketParams;

    /// @dev A phantom market position large enough that {BaseVault}'s share-value cap never binds, so assertions
    ///      observe the resolver's `exitable` term directly.
    uint256 internal constant BIG_POSITION = 1_000_000e6;

    function _newVaultV2() internal returns (VaultV2Mock) {
        return new VaultV2Mock(IERC20(address(erc20Asset)), "Morpho V2", "mV2");
    }

    function _deployStrategy(VaultV2Mock v2) internal returns (MorphoVaultV2StrategyVault strat) {
        MorphoVaultV2StrategyVaultScript script = new MorphoVaultV2StrategyVaultScript();
        _mint(erc20Asset, address(script), FIRST_DEPOSIT_AMOUNT);
        strat = script.deploy(auth, FIRST_DEPOSIT_AMOUNT, IERC4626(address(v2)));
    }

    function _marketParams() internal view returns (MarketParams memory) {
        return MarketParams({
            loanToken: address(erc20Asset),
            collateralToken: address(weth),
            oracle: address(0xABCD),
            irm: address(0xBEEF),
            lltv: 0.86e18
        });
    }

    /// @notice Wires `v2`'s single liquidity adapter to a fresh Morpho market with the given position/liquidity.
    function _wireMarket(VaultV2Mock v2, uint256 vaultPosition, uint128 totalSupplyAssets, uint128 totalBorrowAssets)
        internal
        returns (MorphoMock morpho, MorphoMarketV1AdapterMock adapter, Id id)
    {
        morpho = new MorphoMock(IERC20(address(erc20Asset)));
        adapter = new MorphoMarketV1AdapterMock(address(morpho));
        MarketParams memory mp = _marketParams();
        id = mp.id();
        v2.setLiquidityAdapter(address(adapter));
        v2.setLiquidityData(abi.encode(mp));
        adapter.setExpectedSupplyAssets(id, vaultPosition);
        morpho.setMarket(id, totalSupplyAssets, totalBorrowAssets);
    }

    // REGRESSION: the underlying lies (max* == 0) but the strategy resolves honest, non-zero capacity.

    function test_MorphoVaultV2StrategyVault_maxWithdraw_nonzero_when_underlying_lies() public {
        VaultV2Mock v2 = _newVaultV2();
        MorphoVaultV2StrategyVault strat = _deployStrategy(v2);

        // Underlying V2 view lies.
        assertEq(v2.maxWithdraw(address(strat)), 0);

        // No adapter wired => exitable == idle (the V2 vault's own balance), which is non-zero post first-deposit.
        uint256 idle = erc20Asset.balanceOf(address(v2));
        uint256 baseTerm = strat.convertToAssets(strat.balanceOf(address(strat)));
        uint256 mw = strat.maxWithdraw(address(strat));
        assertGt(mw, 0);
        assertEq(mw, Math.min(baseTerm, idle));
    }

    function test_MorphoVaultV2StrategyVault_maxDeposit_nonzero_when_underlying_lies() public {
        VaultV2Mock v2 = _newVaultV2();
        MorphoVaultV2StrategyVault strat = _deployStrategy(v2);

        assertEq(v2.maxDeposit(address(strat)), 0);
        // Gate open + uncapped => uncapped deposit (regression vs. min(0, ...) = 0).
        assertEq(strat.maxDeposit(alice), type(uint256).max);
    }

    // RESOLVER MATH: exitable = idle + min(vaultPosition, marketFree).

    function test_MorphoVaultV2StrategyVault_maxWithdraw_binds_to_market_free_liquidity() public {
        VaultV2Mock v2 = _newVaultV2();
        MorphoVaultV2StrategyVault strat = _deployStrategy(v2);
        v2.setAllocatedAssets(BIG_POSITION);

        uint256 vaultPosition = 100e6;
        uint128 totalSupplyAssets = 60e6;
        uint128 totalBorrowAssets = 20e6; // marketFree = 40e6 < vaultPosition
        _wireMarket(v2, vaultPosition, totalSupplyAssets, totalBorrowAssets);

        uint256 idle = erc20Asset.balanceOf(address(v2));
        uint256 marketFree = uint256(totalSupplyAssets - totalBorrowAssets);
        assertEq(strat.maxWithdraw(address(strat)), idle + Math.min(vaultPosition, marketFree));
    }

    /// @dev Finding 2: the market-liquidity clamp is *executable*, not just a reported number. Drive the market so
    ///      free liquidity (`marketFree`) binds below the vault's position, then withdraw exactly the reported
    ///      `maxWithdraw` end-to-end: idle is paid from the V2 vault and the remainder is deallocated from the market
    ///      (which reverts if asked for more than `marketFree`). Success proves the resolver does not over-report —
    ///      an over-estimate would pull more than `marketFree` and revert, re-introducing the `NullAmount` failure
    ///      the Guardian de-risking loop exists to avoid.
    function test_MorphoVaultV2StrategyVault_maxWithdraw_executable_at_market_liquidity_boundary() public {
        VaultV2Mock v2 = _newVaultV2();
        MorphoVaultV2StrategyVault strat = _deployStrategy(v2);

        uint256 vaultPosition = 9e6;
        uint128 totalSupplyAssets = 10e6;
        uint128 totalBorrowAssets = 6e6; // marketFree = 4e6 < vaultPosition => the market clamp binds
        (MorphoMock morpho,,) = _wireMarket(v2, vaultPosition, totalSupplyAssets, totalBorrowAssets);

        // Simulate the allocator having supplied most idle into the market: move it from the V2 vault to the
        // token-holding market singleton and book it as the supplied position, leaving only a small idle balance.
        uint256 supplied = 9e6;
        vm.prank(address(v2));
        erc20Asset.transfer(address(morpho), supplied);
        v2.setAllocatedAssets(supplied);

        uint256 idle = erc20Asset.balanceOf(address(v2));
        uint256 marketFree = uint256(totalSupplyAssets - totalBorrowAssets);
        uint256 expectedMax = idle + marketFree;

        // View binds on idle + marketFree, strictly below the (idle + position) the lying underlying could imply.
        assertEq(strat.maxWithdraw(address(strat)), expectedMax);
        assertLt(expectedMax, idle + vaultPosition);

        // Execute exactly the reported max: idle from the vault + a marketFree-sized deallocation from the market.
        uint256 recvBefore = erc20Asset.balanceOf(alice);
        uint256 marketBefore = erc20Asset.balanceOf(address(morpho));
        vm.prank(address(strat));
        strat.withdraw(expectedMax, alice, address(strat));

        // The receiver got the full reported max, and the shortfall above idle came out of the market (proving the
        // marketFree branch executed, not just idle). No revert => view == executable at the liquidity boundary.
        assertEq(erc20Asset.balanceOf(alice) - recvBefore, expectedMax);
        assertEq(marketBefore - erc20Asset.balanceOf(address(morpho)), marketFree);
    }

    function test_MorphoVaultV2StrategyVault_maxWithdraw_binds_to_vault_position() public {
        VaultV2Mock v2 = _newVaultV2();
        MorphoVaultV2StrategyVault strat = _deployStrategy(v2);
        v2.setAllocatedAssets(BIG_POSITION);

        uint256 vaultPosition = 50e6;
        uint128 totalSupplyAssets = 200e6;
        uint128 totalBorrowAssets = 20e6; // marketFree = 180e6 > vaultPosition
        _wireMarket(v2, vaultPosition, totalSupplyAssets, totalBorrowAssets);

        uint256 idle = erc20Asset.balanceOf(address(v2));
        uint256 marketFree = uint256(totalSupplyAssets - totalBorrowAssets);
        assertEq(strat.maxWithdraw(address(strat)), idle + Math.min(vaultPosition, marketFree));
    }

    function test_MorphoVaultV2StrategyVault_maxWithdraw_no_adapter_returns_idle() public {
        VaultV2Mock v2 = _newVaultV2();
        MorphoVaultV2StrategyVault strat = _deployStrategy(v2);
        v2.setAllocatedAssets(BIG_POSITION); // idle binds

        uint256 idle = erc20Asset.balanceOf(address(v2));
        assertGt(idle, 0);
        assertEq(strat.maxWithdraw(address(strat)), idle);
    }

    // GATES.

    function test_MorphoVaultV2StrategyVault_maxWithdraw_zero_when_exit_gate_closed() public {
        VaultV2Mock v2 = _newVaultV2();
        MorphoVaultV2StrategyVault strat = _deployStrategy(v2);
        v2.setAllocatedAssets(BIG_POSITION);
        _wireMarket(v2, 100e6, 60e6, 20e6);

        // canSendShares = false => exit gate closed.
        v2.setGates(false, true, true, true);
        assertEq(strat.maxWithdraw(address(strat)), 0);

        // canReceiveAssets = false => exit gate closed.
        v2.setGates(true, true, true, false);
        assertEq(strat.maxWithdraw(address(strat)), 0);
    }

    function test_MorphoVaultV2StrategyVault_maxDeposit_zero_when_enter_gate_closed() public {
        VaultV2Mock v2 = _newVaultV2();
        MorphoVaultV2StrategyVault strat = _deployStrategy(v2);

        // canReceiveShares = false => enter gate closed.
        v2.setGates(true, false, true, true);
        assertEq(strat.maxDeposit(alice), 0);

        // canSendAssets = false => enter gate closed.
        v2.setGates(true, true, false, true);
        assertEq(strat.maxDeposit(alice), 0);
    }

    function test_MorphoVaultV2StrategyVault_maxDeposit_respects_totalAssetsCap() public {
        VaultV2Mock v2 = _newVaultV2();
        MorphoVaultV2StrategyVault strat = _deployStrategy(v2);

        uint256 totalAssetsBefore = strat.totalAssets();
        uint256 cap = totalAssetsBefore + 25e6;
        vm.prank(manager);
        strat.setTotalAssetsCap(cap);

        assertEq(strat.maxDeposit(alice), Math.saturatingSub(cap, totalAssetsBefore));
    }

    // maxMint / maxRedeem inherit the override semantics via virtual dispatch.

    function test_MorphoVaultV2StrategyVault_maxMint_maxRedeem_track_gates() public {
        VaultV2Mock v2 = _newVaultV2();
        MorphoVaultV2StrategyVault strat = _deployStrategy(v2);
        _wireMarket(v2, 100e6, 60e6, 20e6);

        assertGt(strat.maxMint(alice), 0);
        assertGt(strat.maxRedeem(address(strat)), 0);

        // Enter gate closed => maxMint == 0.
        v2.setGates(true, false, true, true);
        assertEq(strat.maxMint(alice), 0);

        // Exit gate closed => maxRedeem == 0.
        v2.setGates(false, true, true, true);
        assertEq(strat.maxRedeem(address(strat)), 0);
    }

    // GRACEFUL DEGRADATION: a reverting external read must never bubble up (it would brick the whole VLV).

    function test_MorphoVaultV2StrategyVault_degrades_when_liquidityAdapter_reverts() public {
        VaultV2Mock v2 = _newVaultV2();
        MorphoVaultV2StrategyVault strat = _deployStrategy(v2);
        v2.setAllocatedAssets(BIG_POSITION);
        _wireMarket(v2, 100e6, 60e6, 20e6);

        uint256 idle = erc20Asset.balanceOf(address(v2));
        vm.mockCallRevert(address(v2), abi.encodeWithSignature("liquidityAdapter()"), bytes("BOOM"));
        assertEq(strat.maxWithdraw(address(strat)), idle);
    }

    function test_MorphoVaultV2StrategyVault_degrades_when_liquidityData_reverts() public {
        VaultV2Mock v2 = _newVaultV2();
        MorphoVaultV2StrategyVault strat = _deployStrategy(v2);
        v2.setAllocatedAssets(BIG_POSITION);
        _wireMarket(v2, 100e6, 60e6, 20e6);

        uint256 idle = erc20Asset.balanceOf(address(v2));
        vm.mockCallRevert(address(v2), abi.encodeWithSignature("liquidityData()"), bytes("BOOM"));
        assertEq(strat.maxWithdraw(address(strat)), idle);
    }

    function test_MorphoVaultV2StrategyVault_degrades_when_liquidityData_wrong_length() public {
        VaultV2Mock v2 = _newVaultV2();
        MorphoVaultV2StrategyVault strat = _deployStrategy(v2);
        v2.setAllocatedAssets(BIG_POSITION);

        // Non-zero adapter but liquidityData is not a 160-byte MarketParams => degrade before touching the adapter.
        v2.setLiquidityAdapter(address(0xADA9));
        v2.setLiquidityData(abi.encode(uint256(123)));

        uint256 idle = erc20Asset.balanceOf(address(v2));
        assertEq(strat.maxWithdraw(address(strat)), idle);
    }

    /// @dev Finding 1 regression: a malformed but correctly-sized (160-byte) `liquidityData` whose first word is not
    ///      a clean address makes a bare `abi.decode` revert. The resolver decodes via a catchable self-call and must
    ///      degrade to idle-only, since `maxWithdraw` runs inside {VeryLiquidVault} withdraw/rebalance (must not revert).
    function test_MorphoVaultV2StrategyVault_degrades_when_liquidityData_decode_reverts() public {
        VaultV2Mock v2 = _newVaultV2();
        MorphoVaultV2StrategyVault strat = _deployStrategy(v2);
        v2.setAllocatedAssets(BIG_POSITION);

        // 160 bytes (passes the length gate), but the first (loanToken address) word has dirty upper bits.
        v2.setLiquidityAdapter(address(0xADA9));
        v2.setLiquidityData(abi.encodePacked(type(uint256).max, uint256(0), uint256(0), uint256(0), uint256(0)));

        uint256 idle = erc20Asset.balanceOf(address(v2));
        assertEq(strat.maxWithdraw(address(strat)), idle);
    }

    function test_MorphoVaultV2StrategyVault_degrades_when_expectedSupplyAssets_reverts() public {
        VaultV2Mock v2 = _newVaultV2();
        MorphoVaultV2StrategyVault strat = _deployStrategy(v2);
        v2.setAllocatedAssets(BIG_POSITION);
        (, MorphoMarketV1AdapterMock adapter,) = _wireMarket(v2, 100e6, 60e6, 20e6);

        uint256 idle = erc20Asset.balanceOf(address(v2));
        vm.mockCallRevert(address(adapter), abi.encodeWithSignature("expectedSupplyAssets(bytes32)"), bytes("BOOM"));
        assertEq(strat.maxWithdraw(address(strat)), idle);
    }

    function test_MorphoVaultV2StrategyVault_degrades_when_adapter_morpho_reverts() public {
        VaultV2Mock v2 = _newVaultV2();
        MorphoVaultV2StrategyVault strat = _deployStrategy(v2);
        v2.setAllocatedAssets(BIG_POSITION);
        (, MorphoMarketV1AdapterMock adapter,) = _wireMarket(v2, 100e6, 60e6, 20e6);

        uint256 idle = erc20Asset.balanceOf(address(v2));
        vm.mockCallRevert(address(adapter), abi.encodeWithSignature("morpho()"), bytes("BOOM"));
        assertEq(strat.maxWithdraw(address(strat)), idle);
    }

    function test_MorphoVaultV2StrategyVault_degrades_when_market_reverts() public {
        VaultV2Mock v2 = _newVaultV2();
        MorphoVaultV2StrategyVault strat = _deployStrategy(v2);
        v2.setAllocatedAssets(BIG_POSITION);
        (MorphoMock morpho,,) = _wireMarket(v2, 100e6, 60e6, 20e6);

        uint256 idle = erc20Asset.balanceOf(address(v2));
        vm.mockCallRevert(address(morpho), abi.encodeWithSignature("market(bytes32)"), bytes("BOOM"));
        assertEq(strat.maxWithdraw(address(strat)), idle);
    }

    function test_MorphoVaultV2StrategyVault_degrades_when_exit_gate_reverts() public {
        VaultV2Mock v2 = _newVaultV2();
        MorphoVaultV2StrategyVault strat = _deployStrategy(v2);
        v2.setAllocatedAssets(BIG_POSITION);
        _wireMarket(v2, 100e6, 60e6, 20e6);

        vm.mockCallRevert(address(v2), abi.encodeWithSignature("canSendShares(address)"), bytes("BOOM"));
        assertEq(strat.maxWithdraw(address(strat)), 0);
    }

    function test_MorphoVaultV2StrategyVault_degrades_when_enter_gate_reverts() public {
        VaultV2Mock v2 = _newVaultV2();
        MorphoVaultV2StrategyVault strat = _deployStrategy(v2);

        vm.mockCallRevert(address(v2), abi.encodeWithSignature("canReceiveShares(address)"), bytes("BOOM"));
        assertEq(strat.maxDeposit(alice), 0);
    }

    // END-TO-END through a real VeryLiquidVault: deposit routes in and rebalance(v2 -> cash) succeeds.

    function test_MorphoVaultV2StrategyVault_end_to_end_deposit_and_rebalance_to_cash() public {
        VaultV2Mock v2 = _newVaultV2();
        MorphoVaultV2StrategyVault v2Strat = _deployStrategy(v2);

        vm.prank(manager);
        veryLiquidVault.addStrategy(v2Strat);

        // Route deposits to the V2 strategy first.
        IVault[] memory order = new IVault[](4);
        order[0] = v2Strat;
        order[1] = cashStrategyVault;
        order[2] = aaveStrategyVault;
        order[3] = erc4626StrategyVault;
        vm.prank(strategist);
        veryLiquidVault.reorderStrategies(order);

        uint256 amount = 100e6;
        _deposit(charlie, veryLiquidVault, amount);

        // Underlying lies, but the strategy reports the deposit as withdrawable.
        assertEq(v2.maxWithdraw(address(v2Strat)), 0);
        assertApproxEqAbs(v2Strat.maxWithdraw(address(veryLiquidVault)), amount, 2);

        uint256 cashBefore = cashStrategyVault.convertToAssets(cashStrategyVault.balanceOf(address(veryLiquidVault)));

        // The Guardian de-risking primitive: rebalance out of the V2 venue. Pre-fix this reverted with NullAmount.
        uint256 pull = 30e6;
        vm.prank(strategist);
        veryLiquidVault.rebalance(v2Strat, cashStrategyVault, pull, 0.01e18);

        uint256 cashAfter = cashStrategyVault.convertToAssets(cashStrategyVault.balanceOf(address(veryLiquidVault)));
        assertApproxEqAbs(cashAfter - cashBefore, pull, 2);
    }
}
