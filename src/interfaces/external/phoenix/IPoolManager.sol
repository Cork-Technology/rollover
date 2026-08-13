// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Wrapped Phoenix pool identifier (typed `bytes32`).
type MarketId is bytes32;

/// @notice Phoenix market descriptor returned by `IPoolManager.market`.
/// @dev Mirrors the Phoenix shape; fields are not interpreted by Cork directly.
/// @param collateralAsset Asset deposited into the Phoenix market.
/// @param referenceAsset Reference asset paired with the collateral asset.
/// @param expiryTimestamp Unix timestamp after which the market is expired.
/// @param rateMin Minimum swap-rate bound configured for the market.
/// @param rateMax Maximum swap-rate bound configured for the market.
/// @param rateChangePerDayMax Maximum daily swap-rate change configured for the market.
/// @param rateChangeCapacityMax Maximum accumulated swap-rate change capacity.
/// @param rateOracle Oracle address used by Phoenix to source the market rate.
struct Market {
    address collateralAsset;
    address referenceAsset;
    uint256 expiryTimestamp;
    uint256 rateMin;
    uint256 rateMax;
    uint256 rateChangePerDayMax;
    uint256 rateChangeCapacityMax;
    address rateOracle;
}

/// @title IPoolManager
/// @notice Phoenix pool manager surface consumed by `CorkRolloverContract` during rollover legs.
interface IPoolManager {
    /// @notice Resolve a pool id to its market descriptor.
    /// @param poolId Phoenix pool identifier.
    /// @return marketStruct Market descriptor for the pool.
    function market(MarketId poolId) external view returns (Market memory marketStruct);

    /// @notice Resolve the principal-token (CPT) and swap-token (CST) addresses for a pool.
    /// @param poolId Phoenix pool identifier.
    /// @return principalToken Address of the principal token (CPT) contract.
    /// @return swapToken Address of the swap token (CST) contract.
    function shares(MarketId poolId)
        external
        view
        returns (address principalToken, address swapToken);

    /// @notice Burn paired CPT+CST shares and return collateral assets to `receiver`.
    /// @param poolId Phoenix pool identifier.
    /// @param cptAndCstSharesIn Amount of paired shares to burn.
    /// @param owner Address whose shares are burned.
    /// @param receiver Recipient of the released collateral assets.
    /// @return collateralAssetsOut Collateral assets released.
    function unwindMint(MarketId poolId, uint256 cptAndCstSharesIn, address owner, address receiver)
        external
        returns (uint256 collateralAssetsOut);

    /// @notice Deposit collateral assets into a pool and mint paired CPT+CST shares to `receiver`.
    /// @param poolId Phoenix pool identifier.
    /// @param collateralAssetsIn Collateral assets deposited.
    /// @param receiver Recipient of the minted paired shares.
    /// @return cptAndCstSharesOut Paired shares minted.
    function deposit(MarketId poolId, uint256 collateralAssetsIn, address receiver)
        external
        returns (uint256 cptAndCstSharesOut);

    /// @notice Quote the canonical paired-share mint amount for a given collateral input.
    /// @dev    Phoenix's `CorkPoolManager.previewDeposit` returns the canonical 1:1 amount
    ///         (`tokenNativeDecimalsToFixed(collateralAssetsIn, collateralDecimals)`) when the
    ///         pool is active, and zero when deposits are paused or the pool is expired.
    ///         Consumed by `CorkRolloverContract._depositLeg` as the live upper bound on the actual
    ///         mint — see `INV-DST-CST-MINT-RATIO-BOUNDED`.
    /// @param poolId Phoenix pool identifier.
    /// @param collateralAssetsIn Collateral assets to quote.
    /// @return cptAndCstSharesOut Canonical paired-share amount for `collateralAssetsIn`.
    function previewDeposit(MarketId poolId, uint256 collateralAssetsIn)
        external
        view
        returns (uint256 cptAndCstSharesOut);
}
