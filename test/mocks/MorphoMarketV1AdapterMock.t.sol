// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Id} from "@morpho-blue/interfaces/IMorpho.sol";

/// @title MorphoMarketV1AdapterMock
/// @notice Minimal mock of a Morpho Vault V2 "Morpho Market V1" liquidity adapter.
/// @dev Mirrors the two selectors the resolver reads: `morpho()` and `expectedSupplyAssets(bytes32)`.
contract MorphoMarketV1AdapterMock {
    address public morpho;
    mapping(bytes32 => uint256) internal _expectedSupplyAssets;

    constructor(address morpho_) {
        morpho = morpho_;
    }

    function setMorpho(address morpho_) external {
        morpho = morpho_;
    }

    function setExpectedSupplyAssets(Id id, uint256 assets) external {
        _expectedSupplyAssets[Id.unwrap(id)] = assets;
    }

    function expectedSupplyAssets(bytes32 marketId) external view returns (uint256) {
        return _expectedSupplyAssets[marketId];
    }
}
