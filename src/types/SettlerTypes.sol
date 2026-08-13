// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice Returns whether an order status is a final lifecycle state.
function isHardTerminal(RolloverTypes.OrderStatus status) pure returns (bool) {
    return status == RolloverTypes.OrderStatus.Settled
        || status == RolloverTypes.OrderStatus.Expired
        || status == RolloverTypes.OrderStatus.Cancelled;
}

/// @notice Returns whether an order status blocks a new rollover leg.
function blocksRollover(RolloverTypes.OrderStatus status) pure returns (bool) {
    return isHardTerminal(status) || status == RolloverTypes.OrderStatus.Closing;
}

/// @notice Returns whether an order status blocks unpaid residual reclaim.
function blocksReclaim(RolloverTypes.OrderStatus status) pure returns (bool) {
    return
        status == RolloverTypes.OrderStatus.Settled || status == RolloverTypes.OrderStatus.Cancelled;
}

/// @notice Returns whether an order status blocks cPT holder cancellation.
function blocksCancel(RolloverTypes.OrderStatus status) pure returns (bool) {
    return isHardTerminal(status) || status == RolloverTypes.OrderStatus.Closing;
}

/// @notice Returns whether an order status is admitted by `markExpired`.
function isMarkExpiredStatus(RolloverTypes.OrderStatus status) pure returns (bool) {
    return status == RolloverTypes.OrderStatus.Opened || status == RolloverTypes.OrderStatus.Closing;
}

/// @title SettlerTypes
/// @notice Settler-owned accounting structs exposed through Settler lens interfaces.
library SettlerTypes {
    /// @notice Exact-mode rollover accounting record, keyed one-per-order digest.
    /// @param filler Filler that executed the rollover leg.
    /// @param settlementDestination Destination recorded during rollover and used when settling
    ///        the exact residual. Zero before the order rolls over.
    /// @param dstCstProduced Destination CST minted by the rollover leg and initially escrowed.
    /// @param filledAt Timestamp when the rollover accounting record was written.
    /// @param premiumFired True once the premium leg has completed for this rollover.
    struct ExactRolloverAccounting {
        address filler;
        address settlementDestination;
        uint256 dstCstProduced;
        uint64 filledAt;
        bool premiumFired;
    }

    /// @notice Historical partial-mode rollover accounting for one `(filler, subFiller)` slot.
    /// @dev `srcCstProvided` stores the actual srcCST paid by the filler (M-29). Settlement or
    ///      reclaim can drain the slot's residual dstCST without clearing this record.
    /// @param dstCstProduced Destination CST minted by this filler slot and initially escrowed.
    /// @param srcCstProvided Source CST actually consumed by this filler slot, net of leftovers.
    /// @param filledAt Timestamp when the slot's latest rollover accounting record was written.
    /// @param premiumFired True once the premium leg has completed for this filler slot.
    struct FillerRolloverAccounting {
        uint256 dstCstProduced;
        uint256 srcCstProvided;
        uint64 filledAt;
        bool premiumFired;
    }

    /// @notice Partial-mode accounting snapshot for one `(filler, subFiller)` slot.
    /// @param rollover Historical rollover accounting for the slot; may remain nonzero after
    ///        settlement or reclaim.
    /// @param settlementDestination Destination recorded during rollover and used when settling
    ///        the slot's residual. Zero before the slot rolls over.
    /// @param settled True once the slot's residual was settled or reclaimed.
    struct FillerSlotAccounting {
        FillerRolloverAccounting rollover;
        address settlementDestination;
        bool settled;
    }

    /// @notice Partial-mode aggregate rollover accounting for one order.
    /// @param participantSlotCount Number of distinct `(filler, subFiller)` slots that rolled
    ///        over for the order; historical and monotone.
    /// @param dstCstEscrowed Destination CST currently escrowed at the Settler for unsettled or
    ///        unreclaimed partial slots; live value that decreases on settlement and reclaim.
    /// @param srcCstConsumed Source CST cumulatively consumed by partial rollover fills, net of
    ///        per-fill leftovers; historical value that does not decrease.
    struct PartialOrderAccounting {
        uint32 participantSlotCount;
        uint256 dstCstEscrowed;
        uint256 srcCstConsumed;
    }
}
