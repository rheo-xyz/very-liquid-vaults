// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {BaseVault} from "@src/utils/BaseVault.sol";
import {ForkTestMainnet} from "@test/fork/ForkTestMainnet.t.sol";
import {IAaveV4Hub} from "@test/fork/interfaces/IAaveV4.sol";

/// @notice Mainnet fork tests for the Aave V4 integration (issue #11): the audited generic {ERC4626StrategyVault}
///         wrapping the Aave V4 Core USDC `TokenizationSpoke`. No bespoke strategy contract is added.
/// @dev The point of this suite is the de-risking *exit sensor*: the spoke's `maxWithdraw`/`maxRedeem` already fold
///      in the Hub's two exit gates (available liquidity + the `active`/`halted` kill-switches), and the existing
///      `min()` plumbing propagates that honestly up to `VeryLiquidVault.rebalance`. These tests drive the real Hub
///      gates and assert both the views and the underlying execution reverts react — including the exact 19-April
///      `rebalance(AaveV4 -> Cash)` -> `NullAmount` scenario the Guardian loop was built around.
contract AaveV4StrategyVaultForkTest is ForkTestMainnet {
    /// @dev (1) Happy path: a deposit accrues (Hub share index grows) and the full position redeems back without
    ///      principal loss. A fresh-fork deposit lands in the Core Hub's shared USDC liquidity and earns from
    ///      borrower interest, so `redeem(maxRedeem)` returns at least the deposit.
    function testFork_AaveV4Strategy_deposit_redeem_with_interest() public {
        uint256 amount = 100e6;
        _mint(erc20Asset, alice, amount);
        _approve(alice, erc20Asset, address(aaveV4StrategyVault), amount);

        vm.startPrank(alice);
        aaveV4StrategyVault.deposit(amount, alice);
        uint256 valueAfterDeposit = aaveV4StrategyVault.convertToAssets(aaveV4StrategyVault.balanceOf(alice));

        vm.warp(block.timestamp + 1 weeks);

        // The position value grows purely from accrual (no further action), proving yield reaches suppliers.
        uint256 valueAfterAccrual = aaveV4StrategyVault.convertToAssets(aaveV4StrategyVault.balanceOf(alice));
        assertGe(valueAfterAccrual, valueAfterDeposit);

        uint256 maxRedeem = aaveV4StrategyVault.maxRedeem(alice);
        assertGt(maxRedeem, 0);
        uint256 redeemedAssets = aaveV4StrategyVault.redeem(maxRedeem, alice, alice);
        vm.stopPrank();

        // Principal preserved: a week's accrual exceeds ERC4626 floor-rounding dust here. This runs against live
        // (latest-block) state, so if a future run lands in a near-zero-utilization window where weekly yield dips
        // below that dust, warp longer or relax to a 1-2 wei tolerance (assertApproxGeAbs). The accrual itself is
        // already proven above (valueAfterAccrual >= valueAfterDeposit), independent of this round-trip's rounding.
        assertGe(redeemedAssets, amount);
    }

    /// @dev (2) Halt closes the exit sensor: with the spoke halted, the strategy reports `maxWithdraw`/`maxRedeem`
    ///      == 0 *gracefully* (no revert, so VLV views stay live), while a direct removal from the underlying spoke
    ///      reverts `SpokeHalted`. Un-halting reopens the window.
    function testFork_AaveV4Strategy_halt_closes_exit_sensor_gracefully() public {
        uint256 amount = 100e6;
        _mint(erc20Asset, alice, amount);
        _approve(alice, erc20Asset, address(aaveV4StrategyVault), amount);
        vm.prank(alice);
        aaveV4StrategyVault.deposit(amount, alice);

        assertGt(aaveV4StrategyVault.maxWithdraw(alice), 0);

        _setSpokeHalted(true);

        // Graceful 0 (the BaseVault/min plumbing must not revert here — it runs inside VLV withdraw/rebalance loops).
        assertEq(aaveV4StrategyVault.maxWithdraw(alice), 0);
        assertEq(aaveV4StrategyVault.maxRedeem(alice), 0);

        // The underlying really blocks removal (the strategy holds the spoke shares), which is what makes the 0 honest.
        vm.prank(address(aaveV4StrategyVault));
        vm.expectRevert(IAaveV4Hub.SpokeHalted.selector);
        tokenizationSpoke.withdraw(1e6, address(aaveV4StrategyVault), address(aaveV4StrategyVault));

        _setSpokeHalted(false);
        assertGt(aaveV4StrategyVault.maxWithdraw(alice), 0);
    }

    /// @dev (3) Inactive closes the exit sensor: same shape as halt, but deactivating the spoke yields a
    ///      `SpokeNotActive` revert on direct removal. Re-activation reopens the window.
    function testFork_AaveV4Strategy_inactive_closes_exit_sensor_gracefully() public {
        uint256 amount = 100e6;
        _mint(erc20Asset, alice, amount);
        _approve(alice, erc20Asset, address(aaveV4StrategyVault), amount);
        vm.prank(alice);
        aaveV4StrategyVault.deposit(amount, alice);

        assertGt(aaveV4StrategyVault.maxWithdraw(alice), 0);

        _setSpokeActive(false);

        assertEq(aaveV4StrategyVault.maxWithdraw(alice), 0);
        assertEq(aaveV4StrategyVault.maxRedeem(alice), 0);

        vm.prank(address(aaveV4StrategyVault));
        vm.expectRevert(IAaveV4Hub.SpokeNotActive.selector);
        tokenizationSpoke.withdraw(1e6, address(aaveV4StrategyVault), address(aaveV4StrategyVault));

        _setSpokeActive(true);
        assertGt(aaveV4StrategyVault.maxWithdraw(alice), 0);
    }

    /// @dev (4) Liquidity squeeze clamps the exit: with Hub liquidity driven below the holder's position, the
    ///      strategy `maxWithdraw` lands exactly on `min(position, liquidity)` and an over-large direct removal
    ///      reverts `InsufficientLiquidity(liquidity)` — the partial-fill boundary the Guardian must respect, while a
    ///      removal of exactly the available liquidity still executes.
    function testFork_AaveV4Strategy_liquidity_squeeze_clamps_exit() public {
        uint256 amount = 100e6;
        _mint(erc20Asset, alice, amount);
        _approve(alice, erc20Asset, address(aaveV4StrategyVault), amount);
        vm.prank(alice);
        aaveV4StrategyVault.deposit(amount, alice);

        uint256 holderAssets = aaveV4StrategyVault.convertToAssets(aaveV4StrategyVault.balanceOf(alice));
        uint256 lowLiquidity = 5e6; // strictly below the holder's ~100 USDC position, so the liquidity clamp binds
        _setAssetLiquidity(lowLiquidity);
        // `getAssetLiquidity` returns the raw `_assets[id].liquidity` field (already maintained net of `swept` by the
        // Hub) that `_setAssetLiquidity` overwrites directly, so this equality is exact and independent of the live
        // `swept` value. (On a re-pin where `swept` matters for execution, keep `lowLiquidity` a plain absolute floor
        // as here.) The assertEq also self-validates the storage slot — a layout change fails loudly.
        assertEq(aaveV4Hub.getAssetLiquidity(usdcAssetId), lowLiquidity);
        assertLt(lowLiquidity, holderAssets);

        // The exit sensor clamps to available liquidity, not the (larger) position value.
        assertEq(aaveV4StrategyVault.maxWithdraw(alice), lowLiquidity);

        // Asking the underlying for more than the liquidity reverts up front (no silent partial fill).
        vm.prank(address(aaveV4StrategyVault));
        vm.expectRevert(abi.encodeWithSelector(IAaveV4Hub.InsufficientLiquidity.selector, lowLiquidity));
        tokenizationSpoke.withdraw(lowLiquidity + 1e6, address(aaveV4StrategyVault), address(aaveV4StrategyVault));

        // Removing exactly the available liquidity succeeds.
        vm.prank(address(aaveV4StrategyVault));
        tokenizationSpoke.withdraw(lowLiquidity, address(aaveV4StrategyVault), address(aaveV4StrategyVault));
        assertEq(aaveV4Hub.getAssetLiquidity(usdcAssetId), 0);
    }

    /// @dev (5) Deposit cap: with `addCap` set just above the spoke's current supply, the strategy `maxDeposit`
    ///      clamps to the small headroom and an over-cap deposit on the underlying reverts `AddCapExceeded(addCap)`.
    function testFork_AaveV4Strategy_deposit_cap_clamps_and_reverts() public {
        // Conservative launch cap: leave at most ~1 whole USDC of headroom over the spoke's current supply.
        uint40 tightCap = uint40(tokenizationSpoke.totalAssets() / 1e6 + 1);
        _setSpokeAddCap(tightCap);

        // The strategy's deposit capacity is clamped down to that tiny headroom (it would otherwise be ~uncapped).
        assertLt(aaveV4StrategyVault.maxDeposit(alice), 2e6);

        // A deposit well above the headroom reverts at the Hub with the configured cap.
        uint256 tooMuch = 5e6;
        _mint(erc20Asset, alice, tooMuch);
        _approve(alice, erc20Asset, address(tokenizationSpoke), tooMuch);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAaveV4Hub.AddCapExceeded.selector, uint256(tightCap)));
        tokenizationSpoke.deposit(tooMuch, alice);
    }

    /// @dev (6) The 19-April scenario end-to-end through a real {VeryLiquidVault}: route assets into the V4 venue,
    ///      halt the spoke, and the Guardian's `rebalance(AaveV4 -> Cash)` reverts `NullAmount` (its `maxWithdraw`
    ///      clamp collapsed the amount to 0). Un-halting lets the retry succeed — "trigger early + keep retrying".
    function testFork_AaveV4Strategy_vlv_rebalance_blocked_on_halt_then_recovers() public {
        uint256 amount = 100e6;
        _mint(erc20Asset, alice, amount);
        _approve(alice, erc20Asset, address(veryLiquidVault), amount);
        vm.prank(alice);
        veryLiquidVault.deposit(amount, alice);

        // Move half the cash into the V4 venue so there is a position to de-risk out of.
        vm.prank(admin);
        veryLiquidVault.rebalance(cashStrategyVault, aaveV4StrategyVault, amount / 2, 1e18);
        assertGt(aaveV4StrategyVault.convertToAssets(aaveV4StrategyVault.balanceOf(address(veryLiquidVault))), 0);

        // Halt: the de-risking exit reverts NullAmount (maxWithdraw -> 0 -> amount clamped to 0).
        _setSpokeHalted(true);
        vm.prank(admin);
        vm.expectRevert(BaseVault.NullAmount.selector);
        veryLiquidVault.rebalance(aaveV4StrategyVault, cashStrategyVault, amount / 4, 1e18);

        // Un-halt: the same de-risking move now succeeds and grows the cash buffer.
        _setSpokeHalted(false);
        uint256 cashBefore = cashStrategyVault.convertToAssets(cashStrategyVault.balanceOf(address(veryLiquidVault)));
        vm.prank(admin);
        veryLiquidVault.rebalance(aaveV4StrategyVault, cashStrategyVault, amount / 4, 1e18);
        uint256 cashAfter = cashStrategyVault.convertToAssets(cashStrategyVault.balanceOf(address(veryLiquidVault)));
        assertGt(cashAfter, cashBefore);
    }
}
