// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IMarketRegistry } from "src/interfaces/external/market-registry/IMarketRegistry.sol";

/// @notice Which kind of rate a recipe works against.
enum RecipeSource {
    NAV,
    PRICE,
    FIXED
}

/// @title IMarketRecipe
/// @notice Rate-constraint policy a just-in-time created market is checked against.
interface IMarketRecipe {
    /// @notice The recipe's rate kind; selects which oracle the caller produces.
    /// @return The rate kind.
    function source() external view returns (RecipeSource);

    /// @notice Check that a submitted constraint is one this recipe stands behind right now.
    /// @param ca Collateral asset.
    /// @param ref Reference asset.
    /// @param rateOracle Live rate oracle the caller already produced.
    /// @param constraint The constraint the order carries.
    /// @param additionalData Recipe-specific bytes carried in the order.
    /// @return True when the recipe accepts the constraint.
    function verify(
        address ca,
        address ref,
        address rateOracle,
        IMarketRegistry.ResolvedConstraint calldata constraint,
        bytes calldata additionalData
    ) external view returns (bool);
}
