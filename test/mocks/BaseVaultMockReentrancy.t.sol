// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseVaultMock} from "@test/mocks/BaseVaultMock.t.sol";
import {IReentrancyCallback} from "@test/mocks/IReentrancyCallback.t.sol";

contract BaseVaultMockReentrancy is BaseVaultMock {
    function triggerReentrancy(address callback) external nonReentrant {
        // Call the callback while we're in a nonReentrant state
        IReentrancyCallback(callback).onCallback();
    }
}
