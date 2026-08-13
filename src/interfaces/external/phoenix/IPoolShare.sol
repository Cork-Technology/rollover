// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IPoolManager, MarketId } from "src/interfaces/external/phoenix/IPoolManager.sol";

/// @title IPoolShare
/// @notice Minimal Phoenix pool-share (CPT/CST) view surface consumed by Cork.
interface IPoolShare {
    /// @notice Pool manager that mints/burns this share token.
    /// @return manager The pool manager contract.
    function poolManager() external view returns (IPoolManager manager);

    /// @notice Phoenix pool identifier this share is bound to.
    /// @return id Pool identifier.
    function poolId() external view returns (MarketId id);

    /// @notice ERC-20 token decimals.
    /// @return tokenDecimals Number of decimals.
    function decimals() external view returns (uint8 tokenDecimals);

    /// @notice Phoenix-pool expiry timestamp for the underlying market.
    /// @return expiryTimestamp Unix timestamp at which the pool expires.
    function expiry() external view returns (uint256 expiryTimestamp);
}
