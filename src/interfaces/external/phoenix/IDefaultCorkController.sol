// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Market } from "src/interfaces/external/phoenix/IPoolManager.sol";

/// @title IDefaultCorkController
/// @notice Phoenix controller surface used to create a destination pool just in time.
interface IDefaultCorkController {
    /// @notice Parameters required to create a Phoenix pool.
    /// @param pool Market descriptor the pool is created from.
    /// @param unwindSwapFeePercentage Unwind fee, 18 decimals (1% = 1e18).
    /// @param swapFeePercentage Swap fee, 18 decimals (1% = 1e18).
    /// @param isWhitelistEnabled Whether the new pool gates callers by whitelist.
    struct PoolCreationParams {
        Market pool;
        uint256 unwindSwapFeePercentage;
        uint256 swapFeePercentage;
        bool isWhitelistEnabled;
    }

    /// @notice Create a Phoenix pool. Caller must hold `POOL_CREATOR_ROLE`.
    /// @param params Pool creation parameters.
    function createNewPool(PoolCreationParams calldata params) external;
}
