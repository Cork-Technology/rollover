// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { ISettler } from "src/interfaces/settlers/ISettler.sol";
import { SettlerTypes } from "src/types/SettlerTypes.sol";

/// @title IPartialSettler
/// @notice Partial-mode Settler events and accounting views.
/// @dev Partial mode separates order-level aggregate accounting from per-slot accounting.
///      A filler slot is keyed by `(orderDigest, filler, subFiller)`.
interface IPartialSettler is ISettler {
    /// @notice Emitted when partial-mode cancellation moves an order to `Closing`.
    /// @dev `Closing` means the order stopped accepting fills but still has live dstCST escrow
    ///      or residual recovery work before it can become terminal.
    /// @param orderId Canonical order digest / ERC-7683 order id.
    event OrderClosing(bytes32 indexed orderId);

    /// @notice Emitted when a partial-mode filler slot settles its dstCST residual.
    /// @dev The residual is released to the slot's recorded settlement destination.
    /// @param orderId Canonical order digest / ERC-7683 order id.
    /// @param filler Filler whose residual settled.
    /// @param subFiller Partial-mode sub-filler identity.
    /// @param residual Destination CST amount released from Settler escrow.
    event FillerSettled(
        bytes32 indexed orderId, address indexed filler, bytes32 indexed subFiller, uint256 residual
    );

    /// @notice Enriched partial-mode reclaim telemetry including the full filler slot key.
    /// @dev Emitted alongside `DefaulterResidualReclaimed` for partial-mode residual reclaim.
    /// @param orderId Canonical order digest / ERC-7683 order id.
    /// @param defaulterFiller Filler whose unpaid residual is reclaimed.
    /// @param subFiller Partial-mode sub-filler identity.
    /// @param recipientRolloverContract RolloverContract that receives the reclaimed residual.
    /// @param amount Destination CST amount reclaimed.
    event DefaulterResidualReclaimedWithSubFiller(
        bytes32 indexed orderId,
        address indexed defaulterFiller,
        bytes32 indexed subFiller,
        address recipientRolloverContract,
        uint256 amount
    );

    /// @notice Read aggregate rollover accounting for a partial-mode order.
    /// @dev Returns zero/default fields before any partial rollover. The returned accounting
    ///      combines historical counters with live escrow; see `PartialOrderAccounting`.
    /// @custom:invariant INV-PARTIAL-AGGREGATE-SRC-CONSUMED — partial order finality is derived
    ///                   from aggregate consumed srcCST and live dstCST escrow.
    /// @param orderDigest Canonical order digest, used as the ERC-7683 order id.
    /// @return accounting Aggregate partial-order rollover accounting.
    function rolloverAccountingOf(bytes32 orderDigest)
        external
        view
        returns (SettlerTypes.PartialOrderAccounting memory accounting);

    /// @notice Read accounting for one partial-mode filler slot.
    /// @dev The slot is keyed by `(orderDigest, filler, subFiller)`. The embedded rollover
    ///      record is historical: settlement or reclaim can drain residual dstCST without clearing
    ///      the record. Returns zero/default fields before the slot rolls over.
    /// @custom:invariant INV-PARTIAL-SUBFILLER-KEYING — partial slot accounting is keyed by
    ///                   `(orderDigest, filler, subFiller)`.
    /// @custom:invariant N-INV-FILLER-DESTINATION-NONZERO — successful rollover slots carry a
    ///                   set-once nonzero settlement destination.
    /// @param orderDigest Canonical order digest, used as the ERC-7683 order id.
    /// @param filler Address that called the Settler for the rollover leg.
    /// @param subFiller Filler-scoped identity discriminator for the partial slot.
    /// @return accounting Per-slot partial accounting.
    function fillerSlotAccountingOf(bytes32 orderDigest, address filler, bytes32 subFiller)
        external
        view
        returns (SettlerTypes.FillerSlotAccounting memory accounting);
}
