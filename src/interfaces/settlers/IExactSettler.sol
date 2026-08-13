// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { ISettler } from "src/interfaces/settlers/ISettler.sol";
import { SettlerTypes } from "src/types/SettlerTypes.sol";

/// @title IExactSettler
/// @notice Exact-mode Settler accounting views.
interface IExactSettler is ISettler {
    /// @notice Read the exact-mode rollover record for an order.
    /// @dev Exact mode records at most one rollover per order. This is historical accounting:
    ///      settlement or reclaim can later drain escrowed dstCST without clearing the record.
    ///      Returns zero/default fields before rollover.
    /// @custom:invariant N-INV-EXACT-RESIDUAL-RECONCILES-TO-FILL-RECORD — exact residual
    ///                   accounting is bounded by the recorded produced amount.
    /// @param orderDigest Canonical order digest, used as the ERC-7683 order id.
    /// @return accounting Exact rollover filler, settlement destination, dstCST production,
    ///         fill timestamp, and premium state.
    function rolloverAccountingOf(bytes32 orderDigest)
        external
        view
        returns (SettlerTypes.ExactRolloverAccounting memory accounting);
}
