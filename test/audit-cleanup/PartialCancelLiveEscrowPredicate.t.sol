// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { FillScaffold } from "../base/FillScaffold.sol";
import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import { IPartialSettler } from "src/interfaces/settlers/IPartialSettler.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice Pins the partial-cancel predicate: `totalDstCstEscrowed[orderId]`
///         is the live-fill signal. `participantCount`
///         is historical and remains nonzero after all residual escrow drains.
///
///         Observable state combinations (E := totalDstCstEscrowed,
///         P := participantCount):
///           1. (E=0, P=0) — pristine, never filled
///           2. (E>0, P>0) — async rollover filled, not yet settled/reclaimed
///           3. (E=0, P>0) — filled and drained in-frame or by settlement/reclaim
///           4. (E>0, P=0) — impossible: every residual-escrow write also increments
///              participant count.
contract PartialCancelLiveEscrowPredicateTest is FillScaffold {
    /// @notice Order size for the partial-mode fill.
    uint256 internal constant ORDER_SIZE = 1000e18;

    /// @notice State 1: pristine order — both counters zero, so no live escrow exists.
    function test_PristineOrder_BothCountersZero_NoLiveEscrow() public view {
        bytes32 orderDigest = bytes32(uint256(0xBEEF));
        uint32 partCount =
            IPartialSettler(address(partialSettler))
        .rolloverAccountingOf(orderDigest)
        .participantSlotCount;
        uint256 escrow =
            IPartialSettler(address(partialSettler))
        .rolloverAccountingOf(orderDigest)
        .dstCstEscrowed;
        assertEq(partCount, 0, "pristine: participantCount == 0");
        assertEq(escrow, 0, "pristine: totalDstCstEscrowed == 0");
        assertFalse(escrow != 0, "pristine: no live escrow");
    }

    /// @notice State 3: after an atomic-fill partial rollover, participantCount is historical
    ///         and positive, while escrow is drained in-frame.
    function test_AtomicFilledOrder_HistoricalCountNonzeroButNoLiveEscrow() public {
        bytes32 orderDigest = _partialFill(ORDER_SIZE);
        uint32 partCount =
            IPartialSettler(address(partialSettler))
        .rolloverAccountingOf(orderDigest)
        .participantSlotCount;
        uint256 escrow =
            IPartialSettler(address(partialSettler))
        .rolloverAccountingOf(orderDigest)
        .dstCstEscrowed;
        assertGt(partCount, 0, "post-fill: participantCount > 0");
        assertEq(escrow, 0, "atomic-fill: escrow drained in-frame");
        assertFalse(escrow != 0, "atomic-fill: no live escrow");
    }

    /// @notice Cross-validation: historical participant count must not be used as live escrow.
    function test_HistoricalParticipantCount_DoesNotImplyLiveEscrow() public {
        // Pristine
        bytes32 d1 = bytes32(uint256(0xABCD));
        uint32 p1 =
            IPartialSettler(address(partialSettler)).rolloverAccountingOf(d1).participantSlotCount;
        uint256 e1 =
            IPartialSettler(address(partialSettler)).rolloverAccountingOf(d1).dstCstEscrowed;
        assertEq(p1, 0, "pristine: participant count zero");
        assertEq(e1, 0, "pristine: escrow zero");

        // Filled
        bytes32 d2 = _partialFill(ORDER_SIZE);
        uint32 p2 =
            IPartialSettler(address(partialSettler)).rolloverAccountingOf(d2).participantSlotCount;
        uint256 e2 =
            IPartialSettler(address(partialSettler)).rolloverAccountingOf(d2).dstCstEscrowed;
        assertGt(p2, 0, "filled: participant count historical");
        assertEq(e2, 0, "filled: escrow drained");
    }

    /// @dev Open a partial-mode order and drive a full-size rollover fill via the
    ///      shared FillScaffold helpers.
    function _partialFill(uint256 amount) internal returns (bytes32 orderDigest) {
        RolloverTypes.OrderData memory orderData = _orderForMode(SettlerMode.Partial);
        orderData.allowUnderfill = true;
        RolloverTypes.RolloverIntent memory intent = _signedIntent(bytes32(0), amount, amount);
        orderData.rolloverIntentHash = _zeroDigestHash(intent);

        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory userSig = _signOrder(cptHolderPk, orderData);
        bytes memory empty;
        partialSettler.openFor(g, userSig, empty);
        orderDigest = _orderDigest(orderData);
        intent.orderDigest = orderDigest;
        srcCst.mint(filler, amount);
        _approveFiller(amount, 0);
        _doRolloverAs(orderDigest, orderData, intent, amount, filler);
    }
}
