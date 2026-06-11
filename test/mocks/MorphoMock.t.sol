// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Id, Market} from "@morpho-blue/interfaces/IMorpho.sol";

/// @title MorphoMock
/// @notice Minimal mock of the Morpho Blue singleton: a settable `market(Id)` (for the resolver's view inputs) plus
///         a token-backed `serveLiquidity` so withdrawal *execution* can enforce real market free liquidity.
/// @dev `setMarket` controls `marketFree = totalSupplyAssets - totalBorrowAssets`, which the strategy's resolver
///      reads. `serveLiquidity` models a Blue withdrawal/deallocation: it pays out up to free liquidity from this
///      singleton's own token balance and reduces supply, reverting if asked for more. That makes an over-estimating
///      resolver observably fail at execution, which is the property the boundary test exercises.
contract MorphoMock {
    using SafeERC20 for IERC20;

    IERC20 public immutable loanToken;
    mapping(bytes32 => Market) internal _markets;

    constructor(IERC20 loanToken_) {
        loanToken = loanToken_;
    }

    function setMarket(Id id, uint128 totalSupplyAssets, uint128 totalBorrowAssets) external {
        Market storage m = _markets[Id.unwrap(id)];
        m.totalSupplyAssets = totalSupplyAssets;
        m.totalBorrowAssets = totalBorrowAssets;
    }

    function market(Id id) external view returns (Market memory) {
        return _markets[Id.unwrap(id)];
    }

    /// @notice Serves `assets` of free market liquidity to `to`, mirroring a Morpho Blue withdrawal/deallocation.
    /// @dev Reverts when `assets` exceeds current free liquidity (`totalSupplyAssets - totalBorrowAssets`) — the exact
    ///      bound the strategy's resolver promises is withdrawable — and reduces supply by the served amount.
    function serveLiquidity(Id id, uint256 assets, address to) external {
        Market storage m = _markets[Id.unwrap(id)];
        uint256 free = uint256(m.totalSupplyAssets) - uint256(m.totalBorrowAssets);
        require(assets <= free, "MorphoMock: insufficient market liquidity");
        m.totalSupplyAssets -= uint128(assets);
        loanToken.safeTransfer(to, assets);
    }
}
