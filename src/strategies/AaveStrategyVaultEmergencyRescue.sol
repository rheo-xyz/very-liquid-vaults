// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {AaveStrategyVault} from "@src/strategies/AaveStrategyVault.sol";
import {GUARDIAN_ROLE} from "@src/Auth.sol";

/// @title AaveStrategyVaultEmergencyRescue
/// @custom:security-contact security@size.credit
/// @author Size (https://size.credit/)
/// @notice Emergency upgrade implementation for AaveStrategyVault that adds a function
///         to unwind the full aToken position to a hardcoded Gnosis Safe recipient.
/// @dev Purely additive: inherits from AaveStrategyVault, declares no new storage, and does
///      not change any existing behavior. Intended to be deployed behind the existing UUPS
///      proxy via a timelock upgrade, then replaced with a clean implementation once the
///      incident is resolved.
/// @dev Callable by either a GUARDIAN_ROLE holder or directly by RESCUE_RECIPIENT itself.
///      The latter allows the Gnosis Safe to trigger the rescue without first being granted
///      GUARDIAN_ROLE (which would require a 7-day DEFAULT_ADMIN_ROLE timelock) while still
///      forcing the assets to land in the hardcoded Safe address.
contract AaveStrategyVaultEmergencyRescue is AaveStrategyVault {
    /// @notice Hardcoded recipient for emergency-rescued assets (Gnosis Safe)
    /// @dev Also authorized as an alternative caller of `emergencyRescue`
    address public constant RESCUE_RECIPIENT = 0xa9c62d9E0F2208456E50B208aE2547F36Bc3452d;

    // EVENTS
    event EmergencyRescue(address indexed caller, address indexed to, uint256 amount);

    /// @notice Unwinds the full aToken position via Aave and sends the underlying asset
    ///         to the hardcoded rescue recipient.
    /// @dev Callable by (a) any GUARDIAN_ROLE holder, or (b) RESCUE_RECIPIENT directly.
    ///      Any other caller reverts with AccessControlUnauthorizedAccount.
    /// @dev Deliberately omits `notPaused` so the rescue works even when the vault is paused.
    /// @dev Uses pool().withdraw with type(uint256).max to sweep the entire aToken balance.
    /// @return amount The amount of underlying asset transferred to the recipient
    function emergencyRescue() external nonReentrant emitVaultStatus returns (uint256 amount) {
        address sender = _msgSender();
        if (sender != RESCUE_RECIPIENT && !auth().hasRole(GUARDIAN_ROLE, sender)) {
            revert IAccessControl.AccessControlUnauthorizedAccount(sender, GUARDIAN_ROLE);
        }
        amount = pool().withdraw(asset(), type(uint256).max, RESCUE_RECIPIENT);
        emit EmergencyRescue(sender, RESCUE_RECIPIENT, amount);
    }
}
