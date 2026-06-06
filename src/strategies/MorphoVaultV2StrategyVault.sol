// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ERC4626StrategyVault} from "@src/strategies/ERC4626StrategyVault.sol";
import {IMorphoMarketV1Adapter} from "@src/strategies/interfaces/IMorphoMarketV1Adapter.sol";
import {BaseVault} from "@src/utils/BaseVault.sol";

import {IMorpho, Id, Market, MarketParams} from "@morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@morpho-blue/libraries/MarketParamsLib.sol";
import {IVaultV2} from "@morpho-vault-v2/interfaces/IVaultV2.sol";

/// @title MorphoVaultV2StrategyVault
/// @custom:security-contact security@size.credit
/// @author Size (https://size.credit/)
/// @notice A strategy that invests assets in a Morpho Vault V2.
/// @dev Morpho Vault V2 hardcodes all four ERC-4626 `max*` views to `return 0` (an arbitrary gate could reject any
///      caller/amount, so 0 is the only revert-safe value it can promise). The generic {ERC4626StrategyVault} clamps
///      its own views with the underlying's, collapsing every `max*` to `min(0, ...) = 0` and bricking deposits,
///      withdrawals and rebalances against a V2 venue. This subclass replaces those four views with an honest,
///      on-chain liquidity resolver computed from V2/Morpho-Blue primitives, while reusing the audited
///      deposit/withdraw/totalAssets paths (V2's actual `deposit`/`withdraw` execution works; only its views lie).
contract MorphoVaultV2StrategyVault is ERC4626StrategyVault {
    using MarketParamsLib for MarketParams;

    /// @dev The abi-encoded length of a Morpho Blue `MarketParams` (5 static 32-byte words). Used to reject
    ///      `liquidityData` that is not a `MarketParams` (e.g. when the liquidity adapter is not a Morpho Market V1
    ///      adapter), in which case the resolver conservatively degrades to idle-only liquidity.
    uint256 private constant MARKET_PARAMS_LENGTH = 5 * 32;

    // ERC4626 OVERRIDES

    /// @notice Returns the maximum amount that can be deposited.
    /// @dev Gate-only: bounded by V2's entry gate and this vault's own pause + `totalAssetsCap` headroom (via
    ///      {BaseVault}). It intentionally does not subtract the liquidity adapter's market cap headroom; deposit
    ///      overstatement is cheaply contained by {VeryLiquidVault}'s per-strategy try/catch and off-chain sizing.
    function maxDeposit(address receiver) public view override returns (uint256) {
        if (!_gateEnter()) return 0;
        // Bypass ERC4626StrategyVault.maxDeposit (which would clamp with V2's lying `maxDeposit() == 0`).
        return BaseVault.maxDeposit(receiver);
    }

    /// @notice Returns the maximum amount that can be withdrawn by an owner.
    /// @dev Bounded by the owner's redeemable value + pause (via {BaseVault}) and the real exitable liquidity of the
    ///      underlying V2 vault. Returns 0 if V2's exit gate would reject this vault.
    function maxWithdraw(address owner) public view override returns (uint256) {
        if (!_gateExit()) return 0;
        // Bypass ERC4626StrategyVault.maxWithdraw (which would clamp with V2's lying `maxWithdraw() == 0`).
        return Math.min(BaseVault.maxWithdraw(owner), _exitableLiquidity());
    }

    // `maxMint` and `maxRedeem` are inherited from {ERC4626StrategyVault}: they derive from `maxDeposit`/`maxWithdraw`
    // via virtual dispatch (resolving to the overrides above) and clamp with {BaseVault}'s share-denominated caps, so
    // they already reflect the honest resolver without re-implementing the share-conversion shape here.

    // LIQUIDITY RESOLVER

    /// @notice The real amount of assets currently withdrawable from the underlying Morpho Vault V2.
    /// @dev `exitable = idle + min(vaultPositionInLiquidityMarket, freeLiquidityInLiquidityMarket)`, mirroring V2's
    ///      `exit`: it pays `idle` from its own balance and pulls the remainder from the single `liquidityAdapter`'s
    ///      market. `marketFree = totalSupplyAssets - totalBorrowAssets` is invariant under interest accrual (accrual
    ///      adds the same amount to both), so the raw (non-accrued) `market(id)` totals are exact for free liquidity.
    ///      Must never revert: it is read inside {VeryLiquidVault}'s deposit/withdraw/rebalance loops, where a
    ///      reverting strategy view would brick the whole vault. Any failed external read degrades to idle-only.
    function _exitableLiquidity() internal view returns (uint256) {
        IVaultV2 v2 = IVaultV2(address(vault()));
        uint256 idle = IERC20(asset()).balanceOf(address(v2));

        address liquidityAdapter;
        try v2.liquidityAdapter() returns (address adapter) {
            liquidityAdapter = adapter;
        } catch {
            return idle;
        }
        if (liquidityAdapter == address(0)) return idle;

        bytes memory liquidityData;
        try v2.liquidityData() returns (bytes memory data) {
            liquidityData = data;
        } catch {
            return idle;
        }
        // Not a Morpho Market V1 adapter's `MarketParams` (e.g. a different adapter type): degrade to idle-only.
        if (liquidityData.length != MARKET_PARAMS_LENGTH) return idle;
        MarketParams memory marketParams = abi.decode(liquidityData, (MarketParams));
        Id id = marketParams.id();

        uint256 vaultPosition;
        try IMorphoMarketV1Adapter(liquidityAdapter).expectedSupplyAssets(Id.unwrap(id)) returns (uint256 assets) {
            vaultPosition = assets;
        } catch {
            return idle;
        }

        address morpho;
        try IMorphoMarketV1Adapter(liquidityAdapter).morpho() returns (address morpho_) {
            morpho = morpho_;
        } catch {
            return idle;
        }

        uint256 marketFree;
        try IMorpho(morpho).market(id) returns (Market memory market) {
            marketFree = Math.saturatingSub(uint256(market.totalSupplyAssets), uint256(market.totalBorrowAssets));
        } catch {
            return idle;
        }

        return idle + Math.min(vaultPosition, marketFree);
    }

    /// @notice Whether this vault is allowed to enter (deposit into) the underlying V2 vault.
    /// @dev V2's `enter` requires `canReceiveShares(onBehalf) && canSendAssets(msg.sender)`, both this vault here.
    ///      A reverting gate read is treated as "not allowed" (conservative for deposits).
    function _gateEnter() internal view returns (bool) {
        IVaultV2 v2 = IVaultV2(address(vault()));
        try v2.canReceiveShares(address(this)) returns (bool canReceiveShares) {
            if (!canReceiveShares) return false;
        } catch {
            return false;
        }
        try v2.canSendAssets(address(this)) returns (bool canSendAssets) {
            return canSendAssets;
        } catch {
            return false;
        }
    }

    /// @notice Whether this vault is allowed to exit (withdraw from) the underlying V2 vault.
    /// @dev V2's `exit` requires `canSendShares(onBehalf) && canReceiveAssets(receiver)`, both this vault here.
    ///      A reverting gate read is treated as "not allowed" (conservative for withdrawals).
    function _gateExit() internal view returns (bool) {
        IVaultV2 v2 = IVaultV2(address(vault()));
        try v2.canSendShares(address(this)) returns (bool canSendShares) {
            if (!canSendShares) return false;
        } catch {
            return false;
        }
        try v2.canReceiveAssets(address(this)) returns (bool canReceiveAssets) {
            return canReceiveAssets;
        } catch {
            return false;
        }
    }
}
