// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IMorphoMarketV1Adapter
/// @notice Minimal view-only interface for a Morpho Vault V2 "Morpho Market V1" liquidity adapter.
/// @dev Vendored locally (instead of importing vault-v2's IMorphoMarketV1AdapterV2) to avoid the adapter
///      interface's nested `MarketParams` import from vault-v2's own morpho-blue copy, which would clash with
///      the morpho-blue types this repo imports directly. Selectors match the on-chain adapter.
interface IMorphoMarketV1Adapter {
    /// @notice The Morpho Blue singleton this adapter supplies to.
    function morpho() external view returns (address);

    /// @notice The adapter's accrued supply position (in underlying assets) on the given Morpho Blue market.
    /// @param marketId The Morpho Blue market id (`Id` unwrapped to bytes32).
    function expectedSupplyAssets(bytes32 marketId) external view returns (uint256);
}
