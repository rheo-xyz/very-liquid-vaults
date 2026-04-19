// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AaveStrategyVault} from "@src/strategies/AaveStrategyVault.sol";
import {GUARDIAN_ROLE} from "@src/Auth.sol";

/// @title AaveStrategyVaultEmergencyRescue
/// @custom:security-contact security@size.credit
/// @author Size (https://size.credit/)
/// @notice Emergency upgrade implementation for AaveStrategyVault that adds a GUARDIAN-gated
///         function to unwind the full aToken position to a hardcoded Gnosis Safe recipient.
/// @dev Purely additive: inherits from AaveStrategyVault, declares no new storage, and does
///      not change any existing behavior. Intended to be deployed behind the existing UUPS
///      proxy via a timelock upgrade, then replaced with a clean implementation once the
///      incident is resolved.
contract AaveStrategyVaultEmergencyRescue is AaveStrategyVault {
    /// @notice Hardcoded recipient for emergency-rescued assets (Gnosis Safe)
    address public constant RESCUE_RECIPIENT = 0xa9c62d9E0F2208456E50B208aE2547F36Bc3452d;

    // EVENTS
    event EmergencyRescue(address indexed to, uint256 amount);

    /// @notice Unwinds the full aToken position via Aave and sends the underlying asset
    ///         to the hardcoded rescue recipient.
    /// @dev Only addresses with GUARDIAN_ROLE can call this function.
    /// @dev Deliberately omits `notPaused` so the rescue works even when the vault is paused.
    /// @dev Uses pool().withdraw with type(uint256).max to sweep the entire aToken balance.
    /// @return amount The amount of underlying asset transferred to the recipient
    function emergencyRescue()
        external
        nonReentrant
        onlyAuth(GUARDIAN_ROLE)
        emitVaultStatus
        returns (uint256 amount)
    {
        amount = pool().withdraw(asset(), type(uint256).max, RESCUE_RECIPIENT);
        emit EmergencyRescue(RESCUE_RECIPIENT, amount);
    }
}
