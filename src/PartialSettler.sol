// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { BaseSettler } from "src/BaseSettler.sol";
import {
    Settler__AlreadyFilled,
    Settler__ExactFillsNotSupported,
    Settler__FillerAlreadySettled,
    Settler__NoResidualToReclaim,
    Settler__NoRolloverLegForFiller,
    Settler__OrderInTerminalState,
    Settler__PremiumAlreadyFired,
    Settler__PremiumAlreadyFiredRollover,
    Settler__PremiumForRequired,
    Settler__PremiumNotPaid,
    Settler__RolloverAmountOutOfBounds
} from "src/errors/SettlerErrors.sol";
import { IPoolManager } from "src/interfaces/external/phoenix/IPoolManager.sol";
import { IPartialSettler } from "src/interfaces/settlers/IPartialSettler.sol";
import { LibAtomicFill } from "src/libraries/LibAtomicFill.sol";
import { LibPhoenixShareQuantum } from "src/libraries/LibPhoenixShareQuantum.sol";
import { FillerPayload } from "src/types/FillerTypes.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";
import { SettlerTypes, isHardTerminal } from "src/types/SettlerTypes.sol";

/// @title PartialSettler
/// @notice Partial-fill Cork Rollover settler. Shared lifecycle and dispatch live in
///         `BaseSettler`; this contract keeps per-`(filler, subFiller)` slot storage and
///         accounting hooks.
/// @custom:invariant INV-PARTIAL-SUBFILLER-KEYING — partial-mode accounting keys by
///                   `(orderDigest, msg.sender, subFiller)` on the four per-slot mappings
///                   (`fillerRollovers`, `fillerDstCstResidual`, `fillerDestination`,
///                   `fillerSettled`). Shared filler contracts derive `subFiller` from caller
///                   identity (BaseFiller: `bytes32(msg.sender)`; EvcRolloverAdapter:
///                   `bytes32(job.subaccount)`). Direct-EOA fillers self-key via decoder default.
/// @custom:security-contact security@cork.tech
contract PartialSettler is BaseSettler, IPartialSettler {
    /// @notice ERC-7201 storage slot for partial-fill settler state.
    /// @dev Derived from `cork.rollover.partial-settler`. Outer struct slot anchors the struct
    ///      location, not the inner mapping value type.
    bytes32 private constant PARTIAL_SETTLER_STORAGE_SLOT =
        0xde4df9e562f99ce501d2218ebb94dfddd6f4be4f9c4423c45effffd6fd3f6f00;

    /// @notice Partial-fill settler storage layout.
    /// @param orderStatus Lifecycle status for each canonical order digest.
    /// @param fillerRollovers Historical rollover record for each `(orderDigest, filler,
    ///        subFiller)` slot. Settlement or reclaim may drain live escrow without clearing
    ///        this record.
    /// @param totalDstCstEscrowed Live aggregate dstCST residual currently escrowed at the
    ///        Settler for unsettled or unreclaimed partial slots.
    /// @param totalDstCstPremiumed Aggregate produced dstCST amount that has already been
    ///        included in premium calculations.
    /// @param totalPremiumCharged Aggregate premium already charged for the order.
    /// @param totalSrcCstConsumed Historical aggregate srcCST actually consumed by partial
    ///        rollover fills, net of per-fill leftovers.
    /// @param participantCount Historical count of unique `(filler, subFiller)` slots that
    ///        rolled over for the order.
    /// @param fillerDstCstResidual Live dstCST residual for each `(orderDigest, filler,
    ///        subFiller)` slot. Drains to zero on settlement or reclaim.
    /// @param orderById Reserved former `orderById` storage slot; intentionally unused.
    /// @param fillerDestination Settlement destination recorded at rollover for each
    ///        `(orderDigest, filler, subFiller)` slot.
    /// @param fillerSettled Sticky latch set when a partial slot's residual is settled or
    ///        reclaimed.
    struct PartialSettlerStorage {
        mapping(bytes32 orderDigest => RolloverTypes.OrderStatus status) orderStatus;
        mapping(
            bytes32 orderDigest
                => mapping(
                address filler
                    => mapping(bytes32 subFiller => SettlerTypes.FillerRolloverAccounting)
            )
        ) fillerRollovers;
        mapping(bytes32 orderDigest => uint256 escrow) totalDstCstEscrowed;
        mapping(bytes32 orderDigest => uint256 produced) totalDstCstPremiumed;
        mapping(bytes32 orderDigest => uint256 premium) totalPremiumCharged;
        mapping(bytes32 orderDigest => uint256 consumed) totalSrcCstConsumed;
        mapping(bytes32 orderDigest => uint32 count) participantCount;
        mapping(
            bytes32 orderDigest
                => mapping(address filler => mapping(bytes32 subFiller => uint256 residual))
        ) fillerDstCstResidual;
        mapping(bytes32 orderId => RolloverTypes.OrderData orderData) orderById;
        mapping(
            bytes32 orderDigest
                => mapping(address filler => mapping(bytes32 subFiller => address destination))
        ) fillerDestination;
        mapping(
            bytes32 orderDigest
                => mapping(address filler => mapping(bytes32 subFiller => bool settled))
        ) fillerSettled;
    }

    /// @param rolloverContractFactory_ Cork rolloverContract factory used for deployed-rolloverContract checks and hook dispatch.
    /// @param phoenixPoolManager_ Phoenix PoolManager used for canonical cST and share quantum checks.
    /// @param ensOwner_ Initial transferable owner identity for ENS/deployment observability.
    /// @param initialAdmin_ Initial default admin for role management and bounded token rescue.
    /// @param initialPauser_ Initial emergency pause authority.
    /// @param initialUnpauser_ Initial unpause authority.
    constructor(
        address rolloverContractFactory_,
        address phoenixPoolManager_,
        address ensOwner_,
        address initialAdmin_,
        address initialPauser_,
        address initialUnpauser_
    )
        BaseSettler(
            rolloverContractFactory_,
            phoenixPoolManager_,
            ensOwner_,
            initialAdmin_,
            initialPauser_,
            initialUnpauser_
        )
    { }

    /*//////////////////////////////////////////////////////////////
                        USER-FACING VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IPartialSettler
    function rolloverAccountingOf(bytes32 orderDigest)
        external
        view
        returns (SettlerTypes.PartialOrderAccounting memory accounting)
    {
        PartialSettlerStorage storage $ = _s();
        accounting.participantSlotCount = $.participantCount[orderDigest];
        accounting.dstCstEscrowed = $.totalDstCstEscrowed[orderDigest];
        accounting.srcCstConsumed = $.totalSrcCstConsumed[orderDigest];
    }

    /// @inheritdoc IPartialSettler
    function fillerSlotAccountingOf(bytes32 orderDigest, address filler, bytes32 subFiller)
        external
        view
        returns (SettlerTypes.FillerSlotAccounting memory accounting)
    {
        PartialSettlerStorage storage $ = _s();
        accounting.rollover = $.fillerRollovers[orderDigest][filler][subFiller];
        accounting.settlementDestination = $.fillerDestination[orderDigest][filler][subFiller];
        accounting.settled = $.fillerSettled[orderDigest][filler][subFiller];
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Returns the ERC-7201 partial-settler storage namespace.
    function _s() private pure returns (PartialSettlerStorage storage $) {
        bytes32 slot = PARTIAL_SETTLER_STORAGE_SLOT;
        assembly {
            $.slot := slot
        }
    }

    /// @inheritdoc BaseSettler
    /// @dev Partial mode accepts only orders whose signed payload enables partial fills.
    function _validateMode(RolloverTypes.OrderData memory orderData) internal pure override {
        if (!orderData.allowPartialFills) {
            revert Settler__ExactFillsNotSupported();
        }
    }

    /// @inheritdoc BaseSettler
    /// @dev Reads partial-mode status storage keyed by the canonical order digest.
    function _orderStatusOf(bytes32 orderDigest)
        internal
        view
        override
        returns (RolloverTypes.OrderStatus)
    {
        return _s().orderStatus[orderDigest];
    }

    /// @inheritdoc BaseSettler
    /// @dev Writes partial-mode status storage keyed by the canonical order digest.
    function _setOrderStatus(bytes32 orderDigest, RolloverTypes.OrderStatus status)
        internal
        override
    {
        _s().orderStatus[orderDigest] = status;
    }

    /// @inheritdoc BaseSettler
    /// @dev Partial pre-movement gate. Bounds aggregate requested consumption by `orderSize`,
    ///      enforces Phoenix share quantum alignment for this fill and the resulting residual,
    ///      and rejects any `(orderId, filler, subFiller)` slot that already rolled, settled, or
    ///      fired premium. The aggregate bound is intentionally repeated at record time with the
    ///      verified consumed amount because allow-underfill can make `srcProvided < fillAmount`.
    /// @custom:invariant INV-PARTIAL-SUBFILLER-KEYING
    function _validateRolloverBeforeExecutionForMode(
        RolloverTypes.OrderData memory orderData,
        bytes32 orderId,
        address filler,
        FillerPayload memory fillerPayload
    ) internal view override {
        PartialSettlerStorage storage $ = _s();
        uint256 orderSize = orderData.orderSize;
        uint256 consumedAfter = $.totalSrcCstConsumed[orderId] + fillerPayload.fillAmount;
        if (consumedAfter > orderSize) {
            revert Settler__RolloverAmountOutOfBounds(orderSize, consumedAfter);
        }

        uint256 quantum = LibPhoenixShareQuantum.srcShareQuantum(
            IPoolManager(CORK_POOL_MANAGER), orderData.rolloverParams.srcPoolId
        );
        uint256 residual = orderSize - consumedAfter;
        LibPhoenixShareQuantum.requireFillAndResidualQuantumAligned(
            fillerPayload.fillAmount, residual, quantum
        );

        SettlerTypes.FillerRolloverAccounting storage rec =
            $.fillerRollovers[orderId][filler][fillerPayload.subFiller];
        if (rec.premiumFired) {
            revert Settler__PremiumAlreadyFiredRollover();
        }
        if (rec.dstCstProduced != 0 || $.fillerSettled[orderId][filler][fillerPayload.subFiller]) {
            revert Settler__AlreadyFilled();
        }
    }

    /// @inheritdoc BaseSettler
    /// @dev Records verified partial rollover delivery after rolloverContract hook reconciliation. The
    ///      aggregate consumed-source bound is checked again here against `srcProvided`, not the
    ///      requested `fillAmount`, so underfilled legs record only actually consumed srcCST.
    /// @custom:invariant INV-PARTIAL-SUBFILLER-KEYING — record-write keys by
    ///                   `(orderDigest, msg.sender, subFiller)`; participantCount counts unique
    ///                   `(filler, subFiller)` PAIRS.
    /// @custom:invariant N-INV-FILLER-DESTINATION-NONZERO — the rollover record write is the
    ///                   sole writer of `fillerDestination[orderDigest][filler][subFiller]`.
    ///                   The value stored is `payload.destination`, which is rejected when zero
    ///                   by the universal admission gate in
    ///                   `BaseSettler._validateRolloverBeforeExecution`. The slot is set-once per
    ///                   `(orderDigest, filler, subFiller)` triple because
    ///                   `_validateRolloverBeforeExecutionForMode` rejects repeat fills for an
    ///                   already-written slot before token movement; no later code path clears the
    ///                   slot.
    function _recordRolloverAccountingForMode(
        bytes32 orderDigest,
        address filler,
        bytes32 subFiller,
        uint256 dstProduced,
        uint256 srcProvided,
        address destination,
        uint256 orderSize
    ) internal override {
        PartialSettlerStorage storage $ = _s();
        SettlerTypes.FillerRolloverAccounting storage rec =
            $.fillerRollovers[orderDigest][filler][subFiller];
        $.participantCount[orderDigest] += 1;
        $.fillerDestination[orderDigest][filler][subFiller] = destination;
        uint256 newTotalConsumed = $.totalSrcCstConsumed[orderDigest] + srcProvided;
        if (newTotalConsumed > orderSize) {
            revert Settler__RolloverAmountOutOfBounds(orderSize, newTotalConsumed);
        }
        $.totalSrcCstConsumed[orderDigest] = newTotalConsumed;
        rec.dstCstProduced = dstProduced;
        rec.srcCstProvided = srcProvided;
        rec.filledAt = uint64(block.timestamp);
        $.totalDstCstEscrowed[orderDigest] += dstProduced;
        $.fillerDstCstResidual[orderDigest][filler][subFiller] += dstProduced;
    }

    /// @inheritdoc BaseSettler
    /// @dev Resolves the partial premium target slot, calculates the incremental aggregate
    ///      premium due for that slot, and returns the recorded destination for dstCST release.
    /// @custom:invariant INV-PARTIAL-SUBFILLER-KEYING — premium-payment context lookup keys by
    ///                   `(orderId, fillerPayload.premiumFor, resolvedSubFiller)`, after
    ///                   applying the same direct-EOA wire-zero self-key convention used by
    ///                   partial async ROLLOVER.
    function _loadPremiumPaymentContext(
        bytes32 orderId,
        FillerPayload memory fillerPayload,
        uint256 minPremiumPerShare
    )
        internal
        view
        override
        returns (PremiumPaymentContext memory paymentContext, bytes32 resolvedSubFiller)
    {
        resolvedSubFiller = fillerPayload.subFiller;
        if (resolvedSubFiller == bytes32(0)) {
            resolvedSubFiller = bytes32(uint256(uint160(msg.sender)));
        }

        address rolloverFiller = fillerPayload.premiumFor;
        if (rolloverFiller == address(0)) {
            revert Settler__PremiumForRequired();
        }

        PartialSettlerStorage storage $ = _s();
        SettlerTypes.FillerRolloverAccounting storage rec =
            $.fillerRollovers[orderId][rolloverFiller][resolvedSubFiller];
        if (rec.dstCstProduced == 0) {
            revert Settler__NoRolloverLegForFiller();
        }
        if (rec.premiumFired) {
            revert Settler__PremiumAlreadyFired();
        }
        if ($.fillerSettled[orderId][rolloverFiller][resolvedSubFiller]) {
            revert Settler__FillerAlreadySettled();
        }
        paymentContext.rolloverFiller = rolloverFiller;
        paymentContext.produced = rec.dstCstProduced;
        uint256 aggregatePremium = LibAtomicFill.computeRequiredPremium(
            $.totalDstCstPremiumed[orderId] + rec.dstCstProduced, minPremiumPerShare
        );
        paymentContext.requiredPremium = aggregatePremium - $.totalPremiumCharged[orderId];
        // INV-FILLER-DESTINATION-NONZERO — `fillerDestination` is only written by
        // `_recordRolloverAccountingForMode` with the value of `payload.destination`, which the
        // universal admission gate at `BaseSettler._validateRolloverBeforeExecution` rejects when
        // zero. The mapping therefore can never hold `address(0)` after a successful
        // rollover record write; the prior `destination = rolloverFiller` fallback was dead
        // defence-in-depth.
        paymentContext.destination = $.fillerDestination[orderId][rolloverFiller][resolvedSubFiller];
    }

    /// @inheritdoc BaseSettler
    /// @dev Marks the paid partial slot and advances aggregate premium counters used to charge
    ///      each later slot only for its incremental premium obligation.
    function _recordPremiumPaid(
        bytes32 orderId,
        PremiumPaymentContext memory paymentContext,
        bytes32 subFiller
    ) internal override {
        PartialSettlerStorage storage $ = _s();
        $.totalDstCstPremiumed[orderId] += paymentContext.produced;
        $.totalPremiumCharged[orderId] += paymentContext.requiredPremium;
        $.fillerRollovers[orderId][paymentContext.rolloverFiller][subFiller].premiumFired = true;
    }

    /// @inheritdoc BaseSettler
    /// @dev Clears one paid partial residual slot and returns the dstCST amount Base must
    ///      release. Paid settlement rejects every hard-terminal status, including `Expired`.
    ///      If aggregate source consumption reached `orderSize` and live escrow is fully
    ///      drained, the order promotes to `Settled`.
    ///      If a cPT-holder-cancelled underfilled order was already `Closing`, the final residual
    ///      drain promotes it to terminal `Cancelled`.
    /// @custom:invariant INV-FSM-TERMINAL-WRITE-COMPLETE — partial-mode settlement
    ///                   promotes the order to `Settled` and emits `OrderSettled`
    ///                   when aggregate consumed srcCST reaches `orderSize` and the
    ///                   last filler drains `totalDstCstEscrowed` to zero. Post-deadline
    ///                   unpaid cleanup belongs to `reclaim`; paid settlement does not drain
    ///                   hard-terminal `Expired` orders.
    function _settlePaidRolloverRecord(
        bytes32 orderId,
        address filler,
        bytes32 subFiller,
        RolloverTypes.OrderStatus status,
        RolloverTypes.OrderData memory orderData
    ) internal override returns (uint256 settledDstCst) {
        PartialSettlerStorage storage $ = _s();
        if (isHardTerminal(status)) {
            revert Settler__OrderInTerminalState();
        }
        SettlerTypes.FillerRolloverAccounting storage rec =
            $.fillerRollovers[orderId][filler][subFiller];
        if (!rec.premiumFired) {
            revert Settler__PremiumNotPaid();
        }
        if ($.fillerSettled[orderId][filler][subFiller]) {
            revert Settler__FillerAlreadySettled();
        }

        settledDstCst = $.fillerDstCstResidual[orderId][filler][subFiller];
        $.fillerSettled[orderId][filler][subFiller] = true;
        $.fillerDstCstResidual[orderId][filler][subFiller] = 0;
        $.totalDstCstEscrowed[orderId] -= settledDstCst;

        // INV-FSM-TERMINAL-WRITE-COMPLETE — promote to `Settled` only after aggregate
        // consumed srcCST reaches orderSize and escrow drains. `allowUnderfill` is
        // per-leg only; incomplete partial orders clean up through expiry/reclaim/cancel.
        if (
            $.totalSrcCstConsumed[orderId] >= orderData.orderSize
                && $.totalDstCstEscrowed[orderId] == 0
        ) {
            $.orderStatus[orderId] = RolloverTypes.OrderStatus.Settled;
            emit OrderSettled(orderId);
        } else if (status == RolloverTypes.OrderStatus.Closing) {
            _promoteClosingIfDrained($, orderId);
        }
        emit FillerSettled(orderId, filler, subFiller, settledDstCst);
    }

    /// @inheritdoc BaseSettler
    /// @dev Clears an unpaid partial slot after the fill deadline so Base can release its
    ///      tracked dstCST back to the originating rolloverContract. Paid or already-settled slots have
    ///      no reclaimable defaulter residual.
    function _clearReclaimableResidualForMode(
        bytes32 orderId,
        address defaulterFiller,
        bytes32 subFiller,
        RolloverTypes.OrderData memory orderData
    ) internal override returns (uint256 reclaimedDstCst) {
        PartialSettlerStorage storage $ = _s();
        SettlerTypes.FillerRolloverAccounting storage rec =
            $.fillerRollovers[orderId][defaulterFiller][subFiller];
        if (rec.premiumFired) {
            revert Settler__NoResidualToReclaim();
        }
        if ($.fillerSettled[orderId][defaulterFiller][subFiller]) {
            revert Settler__NoResidualToReclaim();
        }
        reclaimedDstCst = $.fillerDstCstResidual[orderId][defaulterFiller][subFiller];
        if (reclaimedDstCst == 0) {
            revert Settler__NoResidualToReclaim();
        }
        $.fillerSettled[orderId][defaulterFiller][subFiller] = true;
        $.fillerDstCstResidual[orderId][defaulterFiller][subFiller] = 0;
        $.totalDstCstEscrowed[orderId] -= reclaimedDstCst;
        emit DefaulterResidualReclaimed(
            orderId, defaulterFiller, orderData.rolloverContract, reclaimedDstCst
        );
        emit DefaulterResidualReclaimedWithSubFiller(
            orderId, defaulterFiller, subFiller, orderData.rolloverContract, reclaimedDstCst
        );
    }

    /// @inheritdoc BaseSettler
    /// @dev `hasFills` tracks LIVE escrowed residual via `totalDstCstEscrowed`, not the
    ///      monotone `participantCount` counter. After every filler settles or reclaims
    ///      their residual, escrow drains to zero and a subsequent cPT holder `cancel` lands
    ///      cleanly in `Cancelled` instead of the intermediate `Closing` status. A historical
    ///      `participantCount` read would keep fully-settled orders permanently routed to
    ///      `Closing`. `participantCount` retains its monotone semantics as a cumulative
    ///      unique-pair counter exposed via `rolloverAccountingOf`.
    /// @custom:invariant INV-FSM-TERMINAL-WRITE-COMPLETE
    function _cancelOrderForMode(bytes32 orderId) internal override {
        PartialSettlerStorage storage $ = _s();
        if ($.totalDstCstEscrowed[orderId] != 0) {
            $.orderStatus[orderId] = RolloverTypes.OrderStatus.Closing;
            emit OrderClosing(orderId);
        } else {
            $.orderStatus[orderId] = RolloverTypes.OrderStatus.Cancelled;
            emit OrderCancelled(orderId);
        }
    }

    /// @inheritdoc BaseSettler
    /// @dev Called after `_clearReclaimableResidualForMode` has already decremented
    ///      `totalDstCstEscrowed`, so the post-drain escrow reflects this reclaim:
    ///        - `Closing` with live escrow remaining: stay `Closing`, emit no terminal event
    ///          (writing `Cancelled` now would block reclaim of the remaining unpaid slots);
    ///        - `Closing` with escrow fully drained: promote to `Cancelled`, emit `OrderCancelled`,
    ///          never `OrderExpired`;
    ///        - any other non-`Expired` status: write `Expired`, emit `OrderExpired`;
    ///        - already `Expired`: no re-emit.
    /// @custom:invariant INV-FSM-TERMINAL-WRITE-COMPLETE
    function _finalizeReclaimStatusForMode(bytes32 orderId, RolloverTypes.OrderStatus statusOnEntry)
        internal
        override
    {
        PartialSettlerStorage storage $ = _s();
        if (statusOnEntry == RolloverTypes.OrderStatus.Closing) {
            _promoteClosingIfDrained($, orderId);
            return;
        }
        if (statusOnEntry != RolloverTypes.OrderStatus.Expired) {
            $.orderStatus[orderId] = RolloverTypes.OrderStatus.Expired;
            emit OrderExpired(orderId);
        }
    }

    /// @dev Promote a cPT-holder-cancelled order to terminal `Cancelled` once all partial
    ///      dstCST residual has drained.
    function _promoteClosingIfDrained(PartialSettlerStorage storage $, bytes32 orderId) private {
        if ($.totalDstCstEscrowed[orderId] != 0) {
            return;
        }
        $.orderStatus[orderId] = RolloverTypes.OrderStatus.Cancelled;
        emit OrderCancelled(orderId);
    }
}
