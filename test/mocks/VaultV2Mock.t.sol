// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

/// @title VaultV2Mock
/// @notice Minimal mock of a Morpho Vault V2 for exercising {MorphoVaultV2StrategyVault}'s resolver.
/// @dev Reproduces the two behaviors the resolver must cope with:
///      1. all four ERC-4626 `max*` views are hardcoded to 0 (the "lying views" that brick the generic wrapper);
///      2. `deposit`/`mint`/`withdraw`/`redeem` execution works and is gated only by the four `can*` predicates
///         (never by `max*`), matching V2's `enter`/`exit`.
///      Adds settable `liquidityAdapter`/`liquidityData`, the four `can*` gates, and a phantom `allocatedAssets`
///      term so `totalAssets()` can model assets supplied to a market (not held idle) without real transfers.
contract VaultV2Mock is ERC4626 {
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
        uint256 shares = previewWithdraw(assets);
        _withdraw(_msgSender(), receiver, owner, assets, shares);
        return shares;
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256) {
        if (!(canSendSharesFlag && canReceiveAssetsFlag)) revert GateClosed();
        uint256 assets = previewRedeem(shares);
        _withdraw(_msgSender(), receiver, owner, assets, shares);
        return assets;
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
