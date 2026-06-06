// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {MorphoVaultV2StrategyVaultScript} from "@script/MorphoVaultV2StrategyVault.s.sol";
import {MorphoVaultV2StrategyVault} from "@src/strategies/MorphoVaultV2StrategyVault.sol";
import {ForkTest} from "@test/fork/ForkTest.t.sol";

/// @notice Fork tests for {MorphoVaultV2StrategyVault} against a live Morpho Vault V2 (Steakhouse High Yield USDC).
/// @dev The underlying V2 vault hardcodes all four ERC-4626 `max*` views to 0; these tests prove the strategy's
///      on-chain resolver restores honest, non-zero capacity/liquidity and that the previously-bricked
///      `rebalance(V2 -> cash)` Guardian primitive now works through a real {VeryLiquidVault}.
contract MorphoVaultV2StrategyVaultForkTest is ForkTest {
    IERC4626 internal morphoV2Vault;
    MorphoVaultV2StrategyVault internal morphoV2StrategyVault;

    function setUp() public override {
        super.setUp();

        morphoV2Vault = IERC4626(MORPHO_STEAKHOUSE_HIGH_YIELD_USDC_VAULT_V2_BASE_MAINNET);

        MorphoVaultV2StrategyVaultScript script = new MorphoVaultV2StrategyVaultScript();
        _mint(erc20Asset, address(script), FIRST_DEPOSIT_AMOUNT);
        morphoV2StrategyVault = script.deploy(auth, FIRST_DEPOSIT_AMOUNT, morphoV2Vault);

        vm.label(address(morphoV2Vault), "MorphoV2Vault");
        vm.label(address(morphoV2StrategyVault), "MorphoVaultV2StrategyVault");
    }

    /// @dev Regression for the `min(0, ...) = 0` bug: the underlying V2 vault lies (all `max*` == 0) yet the strategy
    ///      reports honest, non-zero deposit capacity and withdrawable liquidity.
    function testFork_MorphoVaultV2StrategyVault_underlying_lies_but_strategy_resolves() public {
        uint256 amount = 10 * 10 ** erc20Asset.decimals();
        _mint(erc20Asset, alice, amount);
        _approve(alice, erc20Asset, address(morphoV2StrategyVault), amount);
        vm.prank(alice);
        morphoV2StrategyVault.deposit(amount, alice);

        // The underlying Morpho Vault V2 hardcodes every ERC-4626 max* to 0.
        assertEq(morphoV2Vault.maxDeposit(address(morphoV2StrategyVault)), 0);
        assertEq(morphoV2Vault.maxWithdraw(address(morphoV2StrategyVault)), 0);

        // The strategy's on-chain resolver returns honest, non-zero capacity/liquidity instead.
        assertGt(morphoV2StrategyVault.maxDeposit(alice), 0);
        assertGt(morphoV2StrategyVault.maxWithdraw(alice), 0);
    }

    /// @dev Deposit then redeem the full position: the V2 enter/exit execution paths round-trip through the
    ///      resolver-backed strategy without principal loss. A fresh V2 deposit lands in the vault's idle balance and
    ///      only earns once an allocator supplies it to a market, so this asserts principal preservation, not yield.
    function testFork_MorphoVaultV2StrategyVault_deposit_redeem_roundtrip() public {
        uint256 amount = 10 * 10 ** erc20Asset.decimals();
        _mint(erc20Asset, alice, amount);
        _approve(alice, erc20Asset, address(morphoV2StrategyVault), amount);

        vm.startPrank(alice);
        morphoV2StrategyVault.deposit(amount, alice);

        uint256 maxRedeem = morphoV2StrategyVault.maxRedeem(alice);
        assertGt(maxRedeem, 0);
        uint256 redeemedAssets = morphoV2StrategyVault.redeem(maxRedeem, alice, alice);
        vm.stopPrank();

        assertApproxEqAbs(redeemedAssets, amount, 10);
    }

    /// @dev End-to-end through a real {VeryLiquidVault}: rebalance INTO the V2 venue (honest `maxDeposit`) and, more
    ///      importantly, OUT of it (`rebalance(V2 -> cash)`). The latter is the exact Guardian path that previously
    ///      reverted with `NullAmount` because `maxWithdraw` collapsed to 0.
    function testFork_MorphoVaultV2StrategyVault_e2e_rebalance_in_and_out() public {
        uint256 amount = 100 * 10 ** erc20Asset.decimals();

        vm.prank(admin);
        veryLiquidVault.addStrategy(morphoV2StrategyVault);

        _mint(erc20Asset, alice, amount);
        _approve(alice, erc20Asset, address(veryLiquidVault), amount);
        vm.prank(alice);
        veryLiquidVault.deposit(amount, alice);

        // Rebalance INTO the V2 venue: exercises the honest non-zero maxDeposit (was min(0, ...) = 0 before the fix).
        vm.prank(admin);
        veryLiquidVault.rebalance(cashStrategyVault, morphoV2StrategyVault, amount / 2, 1e18);
        uint256 v2Position =
            morphoV2StrategyVault.convertToAssets(morphoV2StrategyVault.balanceOf(address(veryLiquidVault)));
        assertGt(v2Position, 0);

        // Rebalance OUT of the V2 venue (the Guardian primitive): must no longer revert with NullAmount.
        uint256 cashBefore = cashStrategyVault.convertToAssets(cashStrategyVault.balanceOf(address(veryLiquidVault)));
        vm.prank(admin);
        veryLiquidVault.rebalance(morphoV2StrategyVault, cashStrategyVault, amount / 4, 1e18);
        uint256 cashAfter = cashStrategyVault.convertToAssets(cashStrategyVault.balanceOf(address(veryLiquidVault)));

        assertGt(cashAfter, cashBefore);
    }

    /// @dev Withdrawing exactly `maxWithdraw()` succeeds; asking for more is rejected up front (no silent partial fill
    ///      or principal loss).
    function testFork_MorphoVaultV2StrategyVault_withdraw_bounded_by_maxWithdraw() public {
        uint256 amount = 100 * 10 ** erc20Asset.decimals();
        _mint(erc20Asset, alice, amount);
        _approve(alice, erc20Asset, address(morphoV2StrategyVault), amount);
        vm.prank(alice);
        morphoV2StrategyVault.deposit(amount, alice);

        uint256 maxWithdraw = morphoV2StrategyVault.maxWithdraw(alice);
        assertGt(maxWithdraw, 0);

        vm.prank(alice);
        vm.expectRevert();
        morphoV2StrategyVault.withdraw(maxWithdraw + 1, alice, alice);

        vm.prank(alice);
        morphoV2StrategyVault.withdraw(maxWithdraw, alice, alice);
        assertGe(erc20Asset.balanceOf(alice), maxWithdraw);
    }
}
