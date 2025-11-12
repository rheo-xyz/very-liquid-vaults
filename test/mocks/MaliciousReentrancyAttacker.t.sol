// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseVaultMockReentrancy} from "@test/mocks/BaseVaultMockReentrancy.t.sol";
import {IReentrancyCallback} from "@test/mocks/IReentrancyCallback.t.sol";

contract MaliciousReentrancyAttacker is IReentrancyCallback {
    BaseVaultMockReentrancy public vault;

    constructor(BaseVaultMockReentrancy vault_) {
        vault = vault_;
    }

    function onCallback() external override {
        // Attempt to call a view function protected by nonReentrantView
        // This should revert with ReentrancyGuardReentrantCall
        vault.totalAssetsCap();
    }
}
