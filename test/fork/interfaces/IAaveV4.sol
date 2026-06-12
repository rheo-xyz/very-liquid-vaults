// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IAaveV4Hub
/// @notice Minimal interface for the Aave V4 Hub control surface exercised by the mainnet fork tests.
/// @dev Transcribed (only the touched subset) from `aave/aave-v4` @ commit
///      `1e8de8630dfeb26ad309d986eaec44c1ceb48a6d` — `src/hub/interfaces/IHub.sol`. The upstream implementation is
///      BUSL-licensed and compiles under `0.8.28`; reproducing just this interface keeps the repo's `0.8.26`
///      toolchain unchanged (it cannot be added as a buildable submodule). Error signatures and the `SpokeConfig`
///      field order/types match the source exactly, so the selectors used in `vm.expectRevert` and the struct
///      decoding through `getSpokeConfig`/`updateSpokeConfig` are byte-compatible with the deployed Hub.
interface IAaveV4Hub {
    /// @notice Spoke configuration (a subset of the Hub's internal `SpokeData`). Field order and widths are
    ///         storage-significant and must mirror the source for correct ABI (de)coding.
    struct SpokeConfig {
        uint40 addCap;
        uint40 drawCap;
        uint24 riskPremiumThreshold;
        bool active;
        bool halted;
    }

    /// @notice Thrown by the Hub on an action against an inactive spoke.
    error SpokeNotActive();
    /// @notice Thrown by the Hub on a liquidity-updating action against a halted spoke.
    error SpokeHalted();
    /// @notice Thrown by the Hub when a removal exceeds the asset's available liquidity.
    /// @param liquidity The current available liquidity.
    error InsufficientLiquidity(uint256 liquidity);
    /// @notice Thrown by the Hub when an addition exceeds the spoke's add cap.
    /// @param addCap The current `addCap`, expressed in whole assets (not scaled by decimals).
    error AddCapExceeded(uint256 addCap);

    /// @notice Resolves the Hub assetId of a listed underlying (reverts if not listed).
    function getAssetId(address underlying) external view returns (uint256);

    /// @notice The liquidity available to be removed for an asset, expressed in asset units (net of swept).
    function getAssetLiquidity(uint256 assetId) external view returns (uint256);

    /// @notice The spoke configuration for `(assetId, spoke)`.
    function getSpokeConfig(uint256 assetId, address spoke) external view returns (SpokeConfig memory);

    /// @notice Updates the spoke configuration. `restricted` on the Hub; callable only by the HubConfigurator
    ///         (the fork tests reach it by pranking the configurator address).
    function updateSpokeConfig(uint256 assetId, address spoke, SpokeConfig calldata config) external;
}
