// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title IMarketRegistry
/// @notice Cork market registry surface consumed when a fill creates its destination market.
interface IMarketRegistry {
    /// @notice Which kind of rate oracle `deploy` builds for a pair.
    enum OracleMode {
        PRICE,
        NAV
    }

    /// @notice The four rate limits a market is created with, on the rate scale (1e18 = 1.0).
    /// @dev Derived off-chain at order-signing time so the pool id stays fixed once signed.
    /// @param rateMin Lower rate limit.
    /// @param rateMax Upper rate limit.
    /// @param rateChangePerDayMax Absolute rate movement allowed per day.
    /// @param rateChangeCapacityMax Ceiling on accumulated rate-change allowance.
    struct ResolvedConstraint {
        uint256 rateMin;
        uint256 rateMax;
        uint256 rateChangePerDayMax;
        uint256 rateChangeCapacityMax;
    }

    /// @notice Reverts when an order names a recipe the registry has not approved.
    /// @param recipe The unregistered recipe address.
    error RecipeNotRegistered(address recipe);

    /// @notice Deploy (or return) the rate oracle for a collateral/reference pair.
    /// @param ca Collateral asset.
    /// @param ref Reference asset.
    /// @param mode Oracle mode derived from the recipe's `source()`.
    /// @return wrapper The rate oracle address.
    function deploy(address ca, address ref, OracleMode mode) external returns (address wrapper);

    /// @notice Deploy (or return) the fixed-rate oracle for `rate`.
    /// @param rate The fixed rate, scaled to 1e18.
    /// @return oracle The fixed-rate oracle address.
    function deployFixedRateOracle(uint256 rate) external returns (address oracle);

    /// @notice Longest duration from the current timestamp that a newly created market may run.
    /// @return duration Maximum market expiry duration, in seconds.
    function maxExpiryDuration() external view returns (uint256 duration);

    /// @notice Whether an address is an approved recipe contract.
    /// @param recipe The address to test.
    /// @return True when registered.
    function isRecipe(address recipe) external view returns (bool);
}
