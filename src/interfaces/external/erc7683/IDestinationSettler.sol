// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

/// @title IDestinationSettler
/// @notice ERC-7683 destination-side settler entrypoint that fillers call to satisfy an order.
interface IDestinationSettler {
    /// @notice Execute the filler-side leg of a cross-chain order on the destination chain.
    /// @param orderId Canonical order identifier (EIP-712 digest) supplied by the origin settler.
    /// @param originData ABI-encoded order envelope as produced on the origin chain.
    /// @param fillerData ABI-encoded filler-supplied payload (intent, hooks, premium, etc.).
    function fill(bytes32 orderId, bytes calldata originData, bytes calldata fillerData) external;
}
