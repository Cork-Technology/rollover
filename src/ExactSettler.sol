// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { BaseSettler } from "src/BaseSettler.sol";
import {
    Settler__AlreadyFilled,
    Settler__ExactFillRequiresFullOrderSize,
    Settler__ExactFillerMismatch,
    Settler__ExactNoUnderfillRolloverContractReturnedLeftover,
    Settler__ExactSubFillerMismatch,
    Settler__NoResidualToReclaim,
    Settler__OrderHasFills,
    Settler__OrderInTerminalState,
    Settler__PartialFillsNotSupported,
    Settler__PremiumAlreadyFired,
    Settler__PremiumBeforeRollover,
    Settler__PremiumForMismatch,
    Settler__PremiumNotSettled
} from "src/errors/SettlerErrors.sol";
import { IPoolManager } from "src/interfaces/external/phoenix/IPoolManager.sol";
import { IExactSettler } from "src/interfaces/settlers/IExactSettler.sol";
import { LibAtomicFill } from "src/libraries/LibAtomicFill.sol";
import { LibPhoenixShareQuantum } from "src/libraries/LibPhoenixShareQuantum.sol";
import { FillerPayload } from "src/types/FillerTypes.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";
import { SettlerTypes, isHardTerminal } from "src/types/SettlerTypes.sol";

/// @title ExactSettler
/// @notice Exact-fill Cork Rollover settler. Shared lifecycle and dispatch live in
///         `BaseSettler`; this contract keeps exact-only storage and accounting hooks.
/// @custom:invariant INV-NEW-POLARITY-ISOLATION — exact-mode accounting is isolated from
///                   partial-mode slot accounting. Each order has at most one rollover record,
///                   one live dstCST residual, and one recorded sub-filler key.
/// @custom:security-contact security@cork.tech
contract ExactSettler is BaseSettler, IExactSettler {
    /// @notice ERC-7201 storage slot for exact-fill settler state.
    /// @dev Derived from `cork.rollover.exact-settler`.
    bytes32 private constant EXACT_SETTLER_STORAGE_SLOT =
        0x545e6593eaef4a0977611e4e3c66cf08833dc54fedd0a55f3f6572464c0e3900;

    /// @notice Exact-fill settler storage layout.
    /// @param orderStatus Lifecycle status for each canonical order digest.
    /// @param rolloverAccounting Historical singleton rollover record for each exact order.
    ///        Settlement or reclaim may drain live escrow without clearing this record.
    /// @param dstCstResidual Live dstCST residual currently escrowed at the Settler for an exact
    ///        order. Drains to zero on settlement or reclaim.
    /// @param orderById Reserved former `orderById` storage slot; intentionally unused.
    /// @param exactSubFiller Sub-filler key recorded at rollover and used to bind later exact
    ///        premium payloads. Exact mode does not expose per-sub-filler accounting.
    struct ExactSettlerStorage {
        mapping(bytes32 orderDigest => RolloverTypes.OrderStatus status) orderStatus;
        mapping(bytes32 orderDigest => SettlerTypes.ExactRolloverAccounting record)
            rolloverAccounting;
        mapping(bytes32 orderDigest => uint256 residual) dstCstResidual;
        mapping(bytes32 orderId => RolloverTypes.OrderData orderData) orderById;
        mapping(bytes32 orderDigest => bytes32 subFiller) exactSubFiller;
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

    /// @inheritdoc IExactSettler
    function rolloverAccountingOf(bytes32 orderDigest)
        external
        view
        returns (SettlerTypes.ExactRolloverAccounting memory)
    {
        return _s().rolloverAccounting[orderDigest];
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Returns the ERC-7201 exact-settler storage namespace.
    function _s() private pure returns (ExactSettlerStorage storage $) {
        bytes32 slot = EXACT_SETTLER_STORAGE_SLOT;
        assembly {
            $.slot := slot
        }
    }

    /// @inheritdoc BaseSettler
    /// @dev Exact mode accepts only orders whose signed payload disables partial fills.
    function _validateMode(RolloverTypes.OrderData memory orderData) internal pure override {
        if (orderData.allowPartialFills) {
            revert Settler__PartialFillsNotSupported();
        }
    }

    /// @inheritdoc BaseSettler
    /// @dev Reads exact-mode status storage keyed by the canonical order digest.
    function _orderStatusOf(bytes32 orderDigest)
        internal
        view
        override
        returns (RolloverTypes.OrderStatus)
    {
        return _s().orderStatus[orderDigest];
    }

    /// @inheritdoc BaseSettler
    /// @dev Writes exact-mode status storage keyed by the canonical order digest.
    function _setOrderStatus(bytes32 orderDigest, RolloverTypes.OrderStatus status)
        internal
        override
    {
        _s().orderStatus[orderDigest] = status;
    }

    /// @inheritdoc BaseSettler
    /// @dev Exact pre-movement gate. Enforces full-size fills unless `allowUnderfill` is signed,
    ///      enforces Phoenix share quantum alignment for this fill and any resulting residual,
    ///      and rejects a second rollover record for the same order.
    function _validateRolloverBeforeExecutionForMode(
        RolloverTypes.OrderData memory orderData,
        bytes32 orderId,
        address, /* filler — exact mode records the filler after delivery verification */
        FillerPayload memory fillerPayload
    ) internal view override {
        if (!orderData.allowUnderfill && fillerPayload.fillAmount != orderData.orderSize) {
            revert Settler__ExactFillRequiresFullOrderSize(
                orderData.orderSize, fillerPayload.fillAmount
            );
        }

        uint256 quantum = LibPhoenixShareQuantum.srcShareQuantum(
            IPoolManager(CORK_POOL_MANAGER), orderData.rolloverParams.srcPoolId
        );
        uint256 residual = orderData.orderSize - fillerPayload.fillAmount;
        LibPhoenixShareQuantum.requireFillAndResidualQuantumAligned(
            fillerPayload.fillAmount, residual, quantum
        );

        if (_s().rolloverAccounting[orderId].dstCstProduced != 0) {
            revert Settler__AlreadyFilled();
        }
    }

    /// @inheritdoc BaseSettler
    /// @dev Exact delivery gate. For strict exact orders, a rolloverContract-reported srcCST leftover is
    ///      rejected after Base has verified token deltas; underfill-enabled exact orders may
    ///      return leftover and remain exact because only one rollover record can exist.
    function _validateRolloverDeliveryForMode(
        RolloverTypes.OrderData memory orderData,
        VerifiedRolloverDelivery memory delivery
    ) internal pure override {
        // Exact-mode defence-in-depth: the rolloverContract contract must consume the full signed order.
        if (!orderData.allowPartialFills && !orderData.allowUnderfill && delivery.srcLeftover != 0)
        {
            revert Settler__ExactNoUnderfillRolloverContractReturnedLeftover(delivery.srcLeftover);
        }
    }

    /// @inheritdoc BaseSettler
    /// @dev Records the singleton exact rollover after delivery reconciliation. The record is
    ///      historical; `dstCstResidual` is the live balance Base later releases on settlement
    ///      or reclaim. `subFiller` is retained only to bind later exact premium payloads.
    /// @custom:invariant N-INV-FILLER-DESTINATION-NONZERO — the rollover record write is the
    ///                   sole writer of `rolloverAccounting[orderDigest].settlementDestination`.
    ///                   The value stored is `payload.destination`, which is rejected when zero
    ///                   by the universal admission gate in `BaseSettler._validateRolloverBeforeExecution`.
    ///                   The `dstCstProduced != 0` guard above makes the write set-once: no later
    ///                   code path overwrites or clears the field.
    /// @custom:invariant N-INV-EXACT-RESIDUAL-RECONCILES-TO-FILL-RECORD
    function _recordRolloverAccountingForMode(
        bytes32 orderDigest,
        address filler,
        bytes32 subFiller,
        uint256 dstProduced,
        uint256, /* srcConsumed — exact accounting does not expose consumed srcCST */
        address destination,
        uint256 /* orderSize — exact aggregate size is enforced before execution */
    ) internal override {
        ExactSettlerStorage storage $ = _s();
        SettlerTypes.ExactRolloverAccounting storage rec = $.rolloverAccounting[orderDigest];
        rec.filler = filler;
        rec.settlementDestination = destination;
        rec.dstCstProduced = dstProduced;
        rec.filledAt = uint64(block.timestamp);
        $.dstCstResidual[orderDigest] = dstProduced;
        $.exactSubFiller[orderDigest] = subFiller;
    }

    /// @inheritdoc BaseSettler
    /// @dev Resolves the singleton exact rollover record, enforces the recorded sub-filler key
    ///      when one is supplied, and returns the exact premium amount and settlement destination.
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
        ExactSettlerStorage storage $ = _s();
        resolvedSubFiller = $.exactSubFiller[orderId];
        if (fillerPayload.subFiller != bytes32(0) && fillerPayload.subFiller != resolvedSubFiller) {
            revert Settler__ExactSubFillerMismatch(resolvedSubFiller, fillerPayload.subFiller);
        }

        SettlerTypes.ExactRolloverAccounting storage rec = $.rolloverAccounting[orderId];
        if (rec.dstCstProduced == 0) {
            revert Settler__PremiumBeforeRollover();
        }
        if (rec.premiumFired) {
            revert Settler__PremiumAlreadyFired();
        }
        if (fillerPayload.premiumFor != rec.filler) {
            revert Settler__PremiumForMismatch();
        }
        paymentContext.rolloverFiller = rec.filler;
        paymentContext.produced = rec.dstCstProduced;
        paymentContext.requiredPremium =
            LibAtomicFill.computeRequiredPremium(rec.dstCstProduced, minPremiumPerShare);
        // INV-FILLER-DESTINATION-NONZERO — `settlementDestination` is only written by
        // `_recordRolloverAccountingForMode` with the value of `payload.destination`, which the
        // universal admission gate at `BaseSettler._validateRolloverBeforeExecution` rejects when
        // zero.
        paymentContext.destination = rec.settlementDestination;
    }

    /// @inheritdoc BaseSettler
    /// @dev Marks the singleton exact rollover record as paid after Base has verified premium
    ///      delivery and hook success.
    function _recordPremiumPaid(bytes32 orderId, PremiumPaymentContext memory, bytes32)
        internal
        override
    {
        _s().rolloverAccounting[orderId].premiumFired = true;
    }

    /// @inheritdoc BaseSettler
    /// @dev The caller-supplied `filler` argument is identity-asserting only: it MUST equal the
    ///      recorded `exactRec.filler` or the call reverts with `Settler__ExactFillerMismatch`.
    ///      Recipient resolution uses `exactRec.settlementDestination`, which preserves
    ///      helper-keyed flows (`BaseFiller`, `EvcRolloverAdapter`) where the recorded filler is
    ///      the helper contract address and the stored destination is the upstream user
    ///      subaccount. Permissionless callers passing any other `filler` value are rejected
    ///      before `dstCstResidual` is zeroed or any token transfer is attempted.
    /// @custom:invariant INV-EXACT-FILLER-IDENTITY
    /// @custom:invariant N-INV-EXACT-RESIDUAL-RECONCILES-TO-FILL-RECORD
    function _settlePaidRolloverRecord(
        bytes32 orderId,
        address filler,
        bytes32, /* subFiller — exact mode ignores partial-mode keying */
        RolloverTypes.OrderStatus status,
        RolloverTypes.OrderData memory
    ) internal override returns (uint256 settledDstCst) {
        ExactSettlerStorage storage $ = _s();
        if (isHardTerminal(status)) {
            revert Settler__OrderInTerminalState();
        }
        SettlerTypes.ExactRolloverAccounting storage exactRec = $.rolloverAccounting[orderId];
        if (exactRec.dstCstProduced == 0 || !exactRec.premiumFired) {
            revert Settler__PremiumNotSettled();
        }
        if (filler != exactRec.filler) {
            revert Settler__ExactFillerMismatch(exactRec.filler, filler);
        }
        settledDstCst = $.dstCstResidual[orderId];
        if (settledDstCst > 0) {
            $.dstCstResidual[orderId] = 0;
        }
        $.orderStatus[orderId] = RolloverTypes.OrderStatus.Settled;
        emit OrderSettled(orderId);
    }

    /// @inheritdoc BaseSettler
    /// @dev Clears the unpaid exact residual after the fill deadline so Base can release tracked
    ///      dstCST back to the originating rolloverContract. Paid exact records have no reclaimable defaulter
    ///      residual.
    /// @custom:invariant N-INV-EXACT-RESIDUAL-RECONCILES-TO-FILL-RECORD
    function _clearReclaimableResidualForMode(
        bytes32 orderId,
        address, /* defaulterFiller */
        bytes32, /* subFiller — exact mode ignores partial-mode keying */
        RolloverTypes.OrderData memory orderData
    ) internal override returns (uint256 reclaimedDstCst) {
        ExactSettlerStorage storage $ = _s();
        SettlerTypes.ExactRolloverAccounting storage exactRec = $.rolloverAccounting[orderId];
        if (exactRec.premiumFired) {
            revert Settler__NoResidualToReclaim();
        }
        reclaimedDstCst = $.dstCstResidual[orderId];
        if (reclaimedDstCst == 0) {
            revert Settler__NoResidualToReclaim();
        }
        $.dstCstResidual[orderId] = 0;
        emit DefaulterResidualReclaimed(
            orderId, exactRec.filler, orderData.rolloverContract, reclaimedDstCst
        );
    }

    /// @inheritdoc BaseSettler
    /// @dev Exact orders can cancel only before any rollover has been recorded.
    function _cancelOrderForMode(bytes32 orderId) internal override {
        ExactSettlerStorage storage $ = _s();
        if ($.rolloverAccounting[orderId].dstCstProduced != 0) {
            revert Settler__OrderHasFills();
        }
        $.orderStatus[orderId] = RolloverTypes.OrderStatus.Cancelled;
        emit OrderCancelled(orderId);
    }

    /// @inheritdoc BaseSettler
    /// @dev Exact mode keeps the sticky `Expired` reclaim terminalization: any non-`Expired`
    ///      status (exact mode has no `Closing` state because exact orders cannot cancel after a
    ///      fill) writes `Expired` and emits `OrderExpired`; an already-`Expired` order does not
    ///      re-emit.
    /// @custom:invariant INV-FSM-TERMINAL-WRITE-COMPLETE
    function _finalizeReclaimStatusForMode(bytes32 orderId, RolloverTypes.OrderStatus statusOnEntry)
        internal
        override
    {
        if (statusOnEntry != RolloverTypes.OrderStatus.Expired) {
            _s().orderStatus[orderId] = RolloverTypes.OrderStatus.Expired;
            emit OrderExpired(orderId);
        }
    }
}
