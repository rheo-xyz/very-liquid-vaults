// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Id, Market} from "@morpho-blue/interfaces/IMorpho.sol";

/// @title MorphoMock
/// @notice Minimal mock of the Morpho Blue singleton exposing a settable `market(Id)`.
/// @dev Only `totalSupplyAssets`/`totalBorrowAssets` are settable; the resolver under test reads
///      `marketFree = totalSupplyAssets - totalBorrowAssets` and ignores the other fields.
contract MorphoMock {
    mapping(bytes32 => Market) internal _markets;

    function setMarket(Id id, uint128 totalSupplyAssets, uint128 totalBorrowAssets) external {
        Market storage m = _markets[Id.unwrap(id)];
        m.totalSupplyAssets = totalSupplyAssets;
        m.totalBorrowAssets = totalBorrowAssets;
    }

    function market(Id id) external view returns (Market memory) {
        return _markets[Id.unwrap(id)];
    }
}
