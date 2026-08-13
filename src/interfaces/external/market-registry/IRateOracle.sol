// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title IRateOracle
/// @notice Rate source a Phoenix market is created against.
interface IRateOracle {
    /// @notice One reference-asset unit quoted in the collateral asset, scaled to 1e18.
    /// @return The current rate.
    function rate() external view returns (uint256);
}
