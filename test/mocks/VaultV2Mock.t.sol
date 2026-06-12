// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

import {MarketParams} from "@morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@morpho-blue/libraries/MarketParamsLib.sol";

import {IMorphoMarketV1Adapter} from "@src/strategies/interfaces/IMorphoMarketV1Adapter.sol";
import {MorphoMock} from "@test/mocks/MorphoMock.t.sol";

/// @title VaultV2Mock
/// @notice Minimal mock of a Morpho Vault V2 for exercising {MorphoVaultV2StrategyVault}'s resolver.
/// @dev Reproduces the two behaviors the resolver must cope with:
///      1. all four ERC-4626 `max*` views are hardcoded to 0 (the "lying views" that brick the generic wrapper);
///      2. `deposit`/`mint`/`withdraw`/`redeem` execution works and is gated only by the four `can*` predicates
///         (never by `max*`), matching V2's `enter`/`exit`.
///      Adds settable `liquidityAdapter`/`liquidityData`, the four `can*` gates, and a phantom `allocatedAssets`
///      term so `totalAssets()` can model assets supplied to a market (not held idle) without real transfers.
contract VaultV2Mock is ERC4626 {
    using MarketParamsLib for MarketParams;

    address public liquidityAdapter;
    bytes public liquidityData;

    bool public canSendSharesFlag = true;
    bool public canReceiveSharesFlag = true;
    bool public canSendAssetsFlag = true;
    bool public canReceiveAssetsFlag = true;

    /// @dev Phantom (not actually held) assets, modeling the vault's supply position in a market.
    uint256 public allocatedAssets;

    error GateClosed();

    constructor(IERC20 asset_, string memory name_, string memory symbol_) ERC4626(asset_) ERC20(name_, symbol_) {}

    // --- V2 lies: every max* hardcoded to 0 ---
    function maxDeposit(address) public pure override returns (uint256) {
        return 0;
    }

    function maxMint(address) public pure override returns (uint256) {
        return 0;
    }

    function maxWithdraw(address) public pure override returns (uint256) {
        return 0;
    }

    function maxRedeem(address) public pure override returns (uint256) {
        return 0;
    }

    // --- totalAssets reflects idle balance + supplied-to-market ---
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) + allocatedAssets;
    }

    // --- gates (address argument ignored; a single flag governs all callers) ---
    function canSendShares(address) external view returns (bool) {
        return canSendSharesFlag;
    }

    function canReceiveShares(address) external view returns (bool) {
        return canReceiveSharesFlag;
    }

    function canSendAssets(address) external view returns (bool) {
        return canSendAssetsFlag;
    }

    function canReceiveAssets(address) external view returns (bool) {
        return canReceiveAssetsFlag;
    }

    // --- execution bypasses max* (like V2 enter/exit), enforces gates ---
    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        if (!(canReceiveSharesFlag && canSendAssetsFlag)) revert GateClosed();
        uint256 shares = previewDeposit(assets);
        _deposit(_msgSender(), receiver, assets, shares);
        return shares;
    }

    function mint(uint256 shares, address receiver) public override returns (uint256) {
        if (!(canReceiveSharesFlag && canSendAssetsFlag)) revert GateClosed();
        uint256 assets = previewMint(shares);
        _deposit(_msgSender(), receiver, assets, shares);
        return assets;
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256) {
        if (!(canSendSharesFlag && canReceiveAssetsFlag)) revert GateClosed();
        _ensureLiquidity(assets);
        uint256 shares = previewWithdraw(assets);
        _withdraw(_msgSender(), receiver, owner, assets, shares);
        return shares;
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256) {
        if (!(canSendSharesFlag && canReceiveAssetsFlag)) revert GateClosed();
        uint256 assets = previewRedeem(shares);
        _ensureLiquidity(assets);
        _withdraw(_msgSender(), receiver, owner, assets, shares);
        return assets;
    }

    /// @dev Models V2 `exit` deallocating the shortfall above idle from the single liquidity adapter's market, so
    ///      withdrawal execution is bounded by real market free liquidity (not just idle). No-op when no adapter is
    ///      wired or idle already covers the request. Keeps `totalAssets()` invariant by moving the served amount out
    ///      of the modeled supplied position (`allocatedAssets`) and into the now-larger idle balance.
    function _ensureLiquidity(uint256 assets) internal {
        uint256 ownIdle = IERC20(asset()).balanceOf(address(this));
        if (assets <= ownIdle || liquidityAdapter == address(0)) return;
        uint256 shortfall = assets - ownIdle;
        address morpho = IMorphoMarketV1Adapter(liquidityAdapter).morpho();
        MarketParams memory mp = abi.decode(liquidityData, (MarketParams));
        MorphoMock(morpho).serveLiquidity(mp.id(), shortfall, address(this));
        allocatedAssets = allocatedAssets > shortfall ? allocatedAssets - shortfall : 0;
    }

    // --- setters ---
    function setLiquidityAdapter(address adapter) external {
        liquidityAdapter = adapter;
    }

    function setLiquidityData(bytes calldata data) external {
        liquidityData = data;
    }

    function setGates(bool sendShares, bool receiveShares, bool sendAssets, bool receiveAssets) external {
        canSendSharesFlag = sendShares;
        canReceiveSharesFlag = receiveShares;
        canSendAssetsFlag = sendAssets;
        canReceiveAssetsFlag = receiveAssets;
    }

    function setAllocatedAssets(uint256 allocatedAssets_) external {
        allocatedAssets = allocatedAssets_;
    }
}
