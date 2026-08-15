// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AaveStrategyVault} from "@src/strategies/AaveStrategyVault.sol";
import {GUARDIAN_ROLE} from "@src/Auth.sol";

/// @title AaveStrategyVaultEmergencyRescue
/// @custom:security-contact security@size.credit
/// @author Size (https://size.credit/)
/// @notice Emergency upgrade implementation for AaveStrategyVault that adds a function
///         to transfer the vault's full aToken (e.g. aUSDC) balance to a hardcoded
///         Gnosis Safe recipient.
/// @dev Purely additive: inherits from AaveStrategyVault, declares no new storage, and does
///      not change any existing behavior. Intended to be deployed behind the existing UUPS
///      proxy via a timelock upgrade, then replaced with a clean implementation once the
///      incident is resolved.
/// @dev Callable by either a GUARDIAN_ROLE holder or directly by RESCUE_RECIPIENT itself.
///      The latter allows the Gnosis Safe to trigger the rescue without first being granted
///      GUARDIAN_ROLE (which would require a 7-day DEFAULT_ADMIN_ROLE timelock) while still
///      forcing the assets to land in the hardcoded Safe address.
/// @dev Transfers the aToken directly rather than calling Pool.withdraw, so the rescue works
///      when the Aave market has zero available liquidity (e.g. 100% utilization). The
///      recipient holds the rebasing aToken position and can unwind to the underlying asset
///      later once Aave has cash.
contract AaveStrategyVaultEmergencyRescue is AaveStrategyVault {
    using SafeERC20 for IERC20;

    /// @notice Hardcoded recipient for emergency-rescued assets (Gnosis Safe)
    /// @dev Also authorized as an alternative caller of `emergencyRescue`
    address public constant RESCUE_RECIPIENT = 0xa9c62d9E0F2208456E50B208aE2547F36Bc3452d;

    // EVENTS
    event EmergencyRescue(address indexed caller, address indexed to, uint256 amount);

    /// @notice Transfers the vault's full aToken balance to the hardcoded rescue recipient.
    /// @dev Callable by (a) any GUARDIAN_ROLE holder, or (b) RESCUE_RECIPIENT directly.
    ///      Any other caller reverts with AccessControlUnauthorizedAccount.
    /// @dev Deliberately omits `notPaused` so the rescue works even when the vault is paused.
    /// @dev Transfers the aToken itself (not the underlying) so the rescue works at 100%
    ///      Aave utilization when Pool.withdraw would revert for lack of cash. Aave v3 aToken
    ///      transfers only revert on reserve-level pause or caller health-factor issues; this
    ///      vault never borrows so the health-factor check is a no-op.
    /// @return amount The aToken amount transferred to the recipient (rebasing balance at the
    ///      time of the call).
    function emergencyRescue() external nonReentrant emitVaultStatus returns (uint256 amount) {
        address sender = _msgSender();
        if (sender != RESCUE_RECIPIENT && !auth().hasRole(GUARDIAN_ROLE, sender)) {
            revert IAccessControl.AccessControlUnauthorizedAccount(sender, GUARDIAN_ROLE);
        }
        IERC20 aTokenAsERC20 = IERC20(address(aToken()));
        amount = aTokenAsERC20.balanceOf(address(this));
        aTokenAsERC20.safeTransfer(RESCUE_RECIPIENT, amount);
        emit EmergencyRescue(sender, RESCUE_RECIPIENT, amount);
    }
}
