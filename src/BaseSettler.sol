// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import {
    ReentrancyGuardTransient
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { SignatureChecker } from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import {
    Settler__AsyncPremiumOptInRequired,
    Settler__AtomicFillRequired,
    Settler__BadUserSignature,
    Settler__DstCstNotCanonical,
    Settler__DstProducedNotDelivered,
    Settler__FillAfterDeadline,
    Settler__FillDeadlineExceedsPoolExpiry,
    Settler__InsufficientMintRate,
    Settler__InsufficientRecoverableBalance,
    Settler__MarkExpiredBeforeFillDeadline,
    Settler__OpenAfterOpenDeadline,
    Settler__OrderIdMismatch,
    Settler__OrderInTerminalState,
    Settler__OrderNotCancellable,
    Settler__OrderNotExpirable,
    Settler__OrderNotReclaimable,
    Settler__PremiumDeliveryMismatch,
    Settler__PremiumDestinationMismatch,
    Settler__PremiumExceedsCap,
    Settler__ReclaimBeforeFillDeadline,
    Settler__RolloverAmountOutOfBounds,
    Settler__RolloverContractNotDeployed,
    Settler__SrcCstNotCanonical,
    Settler__SrcLeftoverDeliveryShortfall,
    Settler__SrcLeftoverExceedsFillAmount,
    Settler__UnauthorizedCancel,
    Settler__UnauthorizedFiller,
    Settler__UnderfundedDstCstLiability,
    Settler__UserMismatch,
    Settler__UserNotRolloverContractOwner,
    Settler__ZeroAddress,
    Settler__ZeroAmount,
    Settler__ZeroMint
} from "src/errors/SettlerErrors.sol";
import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import { IOriginSettler } from "src/interfaces/external/erc7683/IOriginSettler.sol";
import { IPoolManager, MarketId } from "src/interfaces/external/phoenix/IPoolManager.sol";
import { IPoolShare } from "src/interfaces/external/phoenix/IPoolShare.sol";
import { ICorkRolloverContract } from "src/interfaces/rollover/ICorkRolloverContract.sol";
import {
    ICorkRolloverContractFactory
} from "src/interfaces/rollover/ICorkRolloverContractFactory.sol";
import { IRolloverHookDispatcher } from "src/interfaces/rollover/IRolloverHookDispatcher.sol";
import { ISettler } from "src/interfaces/settlers/ISettler.sol";
import { ISettlerAdmin } from "src/interfaces/settlers/ISettlerAdmin.sol";
import { LibAtomicFill } from "src/libraries/LibAtomicFill.sol";
import { LibFillerAuth } from "src/libraries/LibFillerAuth.sol";
import { LibFillerPayloadExternal } from "src/libraries/LibFillerPayloadExternal.sol";
import { LibHookPhase } from "src/libraries/LibHookPhase.sol";
import { LibPhoenixShareQuantum } from "src/libraries/LibPhoenixShareQuantum.sol";
import { LibRolloverOrder } from "src/libraries/LibRolloverOrder.sol";
import { LibSettlerAdmission } from "src/libraries/LibSettlerAdmission.sol";
import { LibSettlerHashing } from "src/libraries/LibSettlerHashing.sol";
import { Typehashes } from "src/libraries/Typehashes.sol";
import { FillerPayload } from "src/types/FillerTypes.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";
import {
    blocksCancel,
    blocksReclaim,
    blocksRollover,
    isHardTerminal,
    isMarkExpiredStatus
} from "src/types/SettlerTypes.sol";

/// @title BaseSettler
/// @notice Shared ERC-7683 lifecycle, validation, dispatch, filler auth, and token movement for
///         Cork exact and partial rollover settlers.
/// @custom:invariant INV-NON-ROTATABLE-TRUST-ANCHORS — the rolloverContract factory (`ROLLOVER_CONTRACT_FACTORY`) and
///                   Phoenix pool manager (`CORK_POOL_MANAGER`) are immutable
///                   post-construction by design; rotation requires Settler redeploy.
/// @custom:security-contact security@cork.tech
abstract contract BaseSettler is
    ISettler,
    ISettlerAdmin,
    EIP712,
    AccessControl,
    Ownable,
    Pausable,
    ReentrancyGuardTransient
{
    using SafeERC20 for IERC20;

    /// @notice RolloverContract-reported rollover outputs after Settler-side delivery reconciliation.
    /// @param dstProduced Reported dstCST produced and backed by the observed dstCST delta.
    /// @param srcLeftover Reported srcCST leftover bounded by fill amount and observed srcCST delta.
    struct VerifiedRolloverDelivery {
        uint256 dstProduced;
        uint256 srcLeftover;
    }

    /// @notice AccessControl role whose holders may call `pause()`.
    /// @dev Pausing gates state-changing lifecycle entrypoints that use `whenNotPaused`:
    ///      `open`, `openFor`, `fill`, `reclaim`, `markExpired`, and `cancel`.
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    /// @notice AccessControl role whose holders may call `unpause()`.
    /// @dev Kept separate from `PAUSER_ROLE` so halt and resume authority can be assigned to
    ///      distinct operational keys.
    bytes32 internal constant UNPAUSER_ROLE = keccak256("UNPAUSER_ROLE");
    /// @notice AccessControl role whose holders may rescue non-liability-backed tokens.
    bytes32 public constant RECOVERY_ROLE = keccak256("RECOVERY_ROLE");

    /// @notice Live Settler-held dstCST liability per token.
    /// @dev Increased when a ROLLOVER leg records a residual and decreased only when owed dstCST
    ///      leaves through settlement or reclaim. Rescue never mutates this mapping.
    mapping(address token => uint256 amount) internal dstCstLiability;

    /// @notice Cork rolloverContract factory used for deployed-rolloverContract checks and hook dispatch.
    /// @dev Non-rotatable trust anchor. User signatures bind the Settler address; this deployed
    ///      Settler fixes its rolloverContract factory immutably, so changing factory lineage requires a
    ///      new Settler deployment rather than rotating this pointer in place. See
    ///      INV-NON-ROTATABLE-TRUST-ANCHORS.
    address public immutable ROLLOVER_CONTRACT_FACTORY;
    /// @notice Phoenix PoolManager singleton used to resolve canonical cSTs and share quantum.
    /// @dev Non-rotatable trust anchor. User signatures bind pool ids and cST addresses;
    ///      admission validates those fields against this PoolManager's `shares(...)` view.
    ///      Rotating the PoolManager would redefine canonical token identity for signed and
    ///      in-flight orders, so recovery is a new Settler deployment. See INV-CST-CANONICAL and
    ///      INV-NON-ROTATABLE-TRUST-ANCHORS.
    address public immutable CORK_POOL_MANAGER;

    /// @notice Premium payment context loaded from the rollover record being paid.
    struct PremiumPaymentContext {
        address rolloverFiller;
        uint256 produced;
        uint256 requiredPremium;
        address destination;
    }

    /// @notice Decoded shared context for Cork's tag-routed `fill` dispatcher.
    /// @param order Gasless ERC-7683 order envelope decoded from `originData`.
    /// @param orderData Cork order body decoded from `originData`.
    /// @param orderDigest Canonical digest re-derived from `orderData` and matched to `orderId`.
    /// @param statusOnEntry Order lifecycle status snapshotted before fill-side mutation.
    /// @param dispatch Cork fill-dispatch branch derived from the leading `fillerData` tag.
    struct FillDispatchContext {
        ERC7683Types.GaslessCrossChainOrder order;
        RolloverTypes.OrderData orderData;
        bytes32 orderDigest;
        RolloverTypes.OrderStatus statusOnEntry;
        LibAtomicFill.FillDispatch dispatch;
    }

    /// @param rolloverContractFactory_ Cork rolloverContract factory used for deployed-rolloverContract checks and hook dispatch.
    /// @param phoenixPoolManager_ Phoenix PoolManager used for canonical cST and share quantum checks.
    /// @param ensOwner_ Initial transferable `owner()` identity for ENS/deployment observability.
    ///                  Does not receive roles unless also passed as a role holder.
    /// @param initialAdmin_ Initial default admin for role management and initial recovery holder.
    /// @param initialPauser_ Initial emergency pause authority.
    /// @param initialUnpauser_ Initial unpause authority.
    constructor(
        address rolloverContractFactory_,
        address phoenixPoolManager_,
        address ensOwner_,
        address initialAdmin_,
        address initialPauser_,
        address initialUnpauser_
    ) EIP712("CorkSettler", "1.0.0") Ownable(ensOwner_) {
        if (
            rolloverContractFactory_ == address(0) || phoenixPoolManager_ == address(0)
                || ensOwner_ == address(0) || initialAdmin_ == address(0)
                || initialPauser_ == address(0) || initialUnpauser_ == address(0)
        ) {
            revert Settler__ZeroAddress();
        }

        ROLLOVER_CONTRACT_FACTORY = rolloverContractFactory_;
        CORK_POOL_MANAGER = phoenixPoolManager_;

        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin_);
        _grantRole(RECOVERY_ROLE, initialAdmin_);
        _grantRole(PAUSER_ROLE, initialPauser_);
        _grantRole(UNPAUSER_ROLE, initialUnpauser_);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISettlerAdmin
    function recoverToken(IERC20 token, address to, uint256 amount)
        external
        nonReentrant
        onlyRole(RECOVERY_ROLE)
    {
        if (address(token) == address(0)) {
            revert Settler__ZeroAddress();
        }

        if (to == address(0)) {
            revert Settler__ZeroAddress();
        }

        if (amount == 0) {
            revert Settler__ZeroAmount();
        }

        uint256 recoverableBalance = _recoverableTokenBalance(token);
        if (amount > recoverableBalance) {
            revert Settler__InsufficientRecoverableBalance();
        }

        token.safeTransfer(to, amount);

        emit TokenRecovered(token, to, amount);
    }

    /// @inheritdoc ISettlerAdmin
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @inheritdoc ISettlerAdmin
    function unpause() external onlyRole(UNPAUSER_ROLE) {
        _unpause();
    }

    /*//////////////////////////////////////////////////////////////
                    USER-FACING STATE-CHANGING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Registers a standard ERC-7683 on-chain order submitted by the decoded order user.
    /// @dev The caller must be `orderData.user`; no cPT-holder signature is required because the
    ///      user submits the transaction directly. No tokens move during open.
    /// @param order On-chain cross-chain order envelope.
    function open(ERC7683Types.OnchainCrossChainOrder calldata order)
        external
        nonReentrant
        whenNotPaused
    {
        RolloverTypes.OrderData memory orderData = LibRolloverOrder.decodeOrderData(order);
        ERC7683Types.GaslessCrossChainOrder memory gaslessOrder = _gaslessEquivalentOrder(
            orderData, order.orderDataType, order.orderData, order.fillDeadline
        );
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > orderData.openDeadline) {
            revert Settler__OpenAfterOpenDeadline();
        }
        _validateOrderCommon(orderData, gaslessOrder);
        if (msg.sender != orderData.user) {
            revert Settler__UserMismatch();
        }

        bytes32 orderDigest = _orderDigestMemory(orderData);
        _openValidatedOrder(orderData, gaslessOrder, orderDigest);
    }

    /// @inheritdoc IOriginSettler
    function openFor(
        ERC7683Types.GaslessCrossChainOrder calldata order,
        bytes calldata signature,
        bytes calldata /* originFillerData */
    ) external nonReentrant whenNotPaused {
        RolloverTypes.OrderData memory orderData = LibRolloverOrder.decodeOrderData(order);
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > orderData.openDeadline) {
            revert Settler__OpenAfterOpenDeadline();
        }
        _validateOrderCommon(orderData, order);

        bytes32 orderDigest = _orderDigestMemory(orderData);
        if (!SignatureChecker.isValidSignatureNow(orderData.user, orderDigest, signature)) {
            revert Settler__BadUserSignature();
        }

        _openValidatedOrder(orderData, order, orderDigest);
    }

    /// @notice Fills an order through Cork's tag-routed ERC-7683 fill surface.
    /// @param orderId Order digest.
    /// @param originData ABI-encoded `GaslessCrossChainOrder`.
    /// @param fillerData ABI-encoded filler payload.
    /// @custom:invariant INV-OPENED-ORDERS-FILLABLE-UNTIL-FILLDEADLINE — once an order
    ///                   is `Opened`, it remains fillable until `fillDeadline`,
    ///                   regardless of `openDeadline`. Direct-fill admission through
    ///                   `_admitDirectFill` is still gated by `openDeadline`; the
    ///                   `fillDeadline` gate at this entry bounds every subsequent fill
    ///                   of an Opened order.
    /// @custom:invariant INV-DIRECT-FILL-CPT-HOLDER-SIG — direct-fill ROLLOVER admission
    ///                   (status `None` branch) verifies a cPT-holder EIP-712 signature
    ///                   on `orderDigest` from `FillerPayload.cptHolderSig`. Async PREMIUM
    ///                   also verifies its own cPT-holder signature at the Settler boundary;
    ///                   atomic PREMIUM does not because it is synthesized after the
    ///                   verified ROLLOVER leg in the same frame.
    /// @custom:invariant INV-FILL-TAG-DISPATCH — `ATOMIC_TAG` executes the atomic
    ///                   lifecycle; ROLLOVER/PREMIUM tags execute the cPT-holder-opt-in
    ///                   async lifecycle; every other tag reverts at dispatch.
    function fill(bytes32 orderId, bytes calldata originData, bytes calldata fillerData)
        external
        override(ISettler)
        nonReentrant
        whenNotPaused
    {
        FillDispatchContext memory context =
            _decodeFillDispatchContext(orderId, originData, fillerData);

        if (context.dispatch == LibAtomicFill.FillDispatch.Atomic) {
            _fillAtomic(context, fillerData);
        } else {
            _fillAsync(context, fillerData);
        }
    }

    /// @inheritdoc ISettler
    /// @dev Shared reclaim gate and dstCST release path. Mode hooks clear reclaim state;
    ///      Base decrements liability, returns dstCST to `orderData.rolloverContract`,
    ///      and delegates terminal status to `_finalizeReclaimStatusForMode`.
    /// @custom:invariant INV-FSM-TERMINAL-WRITE-COMPLETE
    function reclaim(
        bytes32 orderId,
        address defaulterFiller,
        bytes32 subFiller,
        bytes calldata originData
    ) external override(ISettler) nonReentrant whenNotPaused {
        RolloverTypes.OrderStatus status = _orderStatusOf(orderId);
        if (blocksReclaim(status)) {
            revert Settler__OrderNotReclaimable();
        }

        RolloverTypes.OrderData memory orderData;
        (, orderData) = _decodeBoundOriginData(orderId, originData);
        if (orderData.premiumPaymentMode != RolloverTypes.PREMIUM_PAYMENT_MODE_ATOMIC_OR_SEPARATE) {
            revert Settler__AsyncPremiumOptInRequired();
        }
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp <= orderData.fillDeadline) {
            revert Settler__ReclaimBeforeFillDeadline();
        }
        uint256 dstCstToRelease =
            _clearReclaimableResidualForMode(orderId, defaulterFiller, subFiller, orderData);

        address dstCstToken = orderData.dstCstToken;
        address recipientRolloverContract = orderData.rolloverContract;

        dstCstLiability[dstCstToken] -= dstCstToRelease;
        IERC20(dstCstToken).safeTransfer(recipientRolloverContract, dstCstToRelease);

        _finalizeReclaimStatusForMode(orderId, status);
    }

    /// @inheritdoc ISettler
    function markExpired(bytes32 orderId, bytes calldata originData)
        external
        nonReentrant
        whenNotPaused
    {
        RolloverTypes.OrderStatus status = _orderStatusOf(orderId);
        if (!isMarkExpiredStatus(status)) {
            revert Settler__OrderNotExpirable();
        }
        RolloverTypes.OrderData memory orderData;
        (, orderData) = _decodeBoundOriginData(orderId, originData);
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp <= orderData.fillDeadline) {
            revert Settler__MarkExpiredBeforeFillDeadline();
        }
        _setOrderStatus(orderId, RolloverTypes.OrderStatus.Expired);
        emit OrderExpired(orderId);
    }

    /// @inheritdoc ISettler
    function cancel(bytes32 orderId, bytes calldata originData, bytes calldata cptHolderSig)
        external
        nonReentrant
        whenNotPaused
    {
        RolloverTypes.OrderStatus status = _orderStatusOf(orderId);
        if (blocksCancel(status)) {
            revert Settler__OrderNotCancellable();
        }

        RolloverTypes.OrderData memory orderData;
        (, orderData) = _decodeBoundOriginData(orderId, originData);

        bytes32 cancelDigest =
            _hashTypedDataV4(LibSettlerHashing.hashCancelOrder(orderId, orderData.orderSalt));
        if (!SignatureChecker.isValidSignatureNow(orderData.user, cancelDigest, cptHolderSig)) {
            revert Settler__UnauthorizedCancel();
        }

        _cancelOrderForMode(orderId);
    }

    /*//////////////////////////////////////////////////////////////
                        USER-FACING VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISettler
    // forge-lint: disable-next-line(mixed-case-function)
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @inheritdoc ISettler
    function version() external pure returns (string memory) {
        return "1.0.0";
    }

    /// @inheritdoc ISettler
    function fillerAuthTypehash() external pure returns (bytes32) {
        return Typehashes.FILLER_AUTH_TYPEHASH;
    }

    /// @inheritdoc ISettlerAdmin
    function dstCstLiabilityOf(address token) external view returns (uint256) {
        return dstCstLiability[token];
    }

    /// @inheritdoc ISettlerAdmin
    function recoverableTokenBalance(address token) external view returns (uint256) {
        if (token == address(0)) {
            revert Settler__ZeroAddress();
        }
        return _recoverableTokenBalance(IERC20(token));
    }

    /// @notice Resolves a standard ERC-7683 on-chain order into resolved-order form.
    /// @param order On-chain cross-chain order envelope.
    /// @return resolved ERC-7683 resolved order.
    function resolve(ERC7683Types.OnchainCrossChainOrder calldata order)
        external
        view
        returns (ERC7683Types.ResolvedCrossChainOrder memory resolved)
    {
        RolloverTypes.OrderData memory orderData = LibRolloverOrder.decodeOrderData(order);
        ERC7683Types.GaslessCrossChainOrder memory gaslessOrder = _gaslessEquivalentOrder(
            orderData, order.orderDataType, order.orderData, order.fillDeadline
        );
        return _resolveDecodedOrder(orderData, gaslessOrder);
    }

    /// @inheritdoc IOriginSettler
    function resolveFor(
        ERC7683Types.GaslessCrossChainOrder calldata order,
        bytes calldata /* originFillerData */
    )
        external
        view
        returns (ERC7683Types.ResolvedCrossChainOrder memory)
    {
        RolloverTypes.OrderData memory orderData = LibRolloverOrder.decodeOrderData(order);
        ERC7683Types.GaslessCrossChainOrder memory gaslessOrder = order;
        return _resolveDecodedOrder(orderData, gaslessOrder);
    }

    /// @inheritdoc ISettler
    function orderStatus(bytes32 orderDigest)
        external
        view
        returns (RolloverTypes.OrderStatus status)
    {
        return _orderStatusOf(orderDigest);
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL STATE-CHANGING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Shared ERC-7683 fill boundary. Decodes `originData` exactly once, checks that it
    ///      binds to `orderId`, enforces the signed fill deadline, rejects short `fillerData`,
    ///      and classifies the Cork dispatch tag. Branch handlers must not reparse `originData`.
    /// @param orderId Caller-supplied ERC-7683 order id / Cork order digest.
    /// @param originData ABI-encoded `GaslessCrossChainOrder`.
    /// @param fillerData ABI-encoded atomic envelope or async filler payload.
    /// @return context Shared decoded fill context.
    function _decodeFillDispatchContext(
        bytes32 orderId,
        bytes calldata originData,
        bytes calldata fillerData
    ) private view returns (FillDispatchContext memory context) {
        context.statusOnEntry = _orderStatusOf(orderId);
        (context.order, context.orderData) = _decodeBoundOriginData(orderId, originData);
        context.orderDigest = orderId;
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > context.orderData.fillDeadline) {
            revert Settler__FillAfterDeadline();
        }

        if (fillerData.length < 32) {
            revert Settler__AtomicFillRequired();
        }
        context.dispatch = LibAtomicFill.peekDispatch(fillerData);
    }

    /// @dev Atomic path for `fill(ATOMIC_TAG)`. Decodes and validates both inner legs before
    ///      rollover-side effects, admits and executes the rollover leg, pins
    ///      `premiumFor`/`subFiller` from the just-recorded rollover, and settles in the same
    ///      frame after enforcing the envelope premium cap.
    /// @param context Shared fill context from `_decodeFillDispatchContext`.
    /// @param fillerData ABI-encoded atomic envelope.
    function _fillAtomic(FillDispatchContext memory context, bytes calldata fillerData) private {
        (
            FillerPayload memory rolloverPayload,
            uint256 atomicPremiumCap,
            bytes memory envelopeCptHolderSig
        ) = LibFillerPayloadExternal.decodeAtomicPayloads(fillerData);

        if (context.statusOnEntry == RolloverTypes.OrderStatus.None) {
            _admitDirectFill(context, envelopeCptHolderSig);
        }

        _checkFillerAuth(
            context.orderData,
            context.orderDigest,
            rolloverPayload.destination,
            rolloverPayload.subFiller,
            rolloverPayload.fillerAuthSig
        );
        _validateRolloverBeforeExecution(
            context.orderData,
            context.orderDigest,
            context.statusOnEntry,
            msg.sender,
            rolloverPayload
        );
        VerifiedRolloverDelivery memory delivery = _executeRolloverHooksAndVerifyDelivery(
            context.orderData, context.orderDigest, rolloverPayload
        );
        _finalizeVerifiedRollover(context.orderData, context.orderDigest, rolloverPayload, delivery);

        FillerPayload memory premiumPayload = _synthesizeAtomicPremiumPayload(
            rolloverPayload.intent, rolloverPayload.subFiller, envelopeCptHolderSig
        );

        (PremiumPaymentContext memory paymentContext,) = _loadPremiumPaymentContext(
            context.orderDigest, premiumPayload, context.orderData.minPremiumPerShare
        );

        // Atomic premium settlement verifies the same cPT-holder signature again at the rolloverContract.
        _payPremiumAndReleaseDstCst(
            context.orderData,
            context.orderDigest,
            context.statusOnEntry,
            premiumPayload,
            paymentContext,
            atomicPremiumCap
        );
    }

    /// @dev Synthesize a `FillerPayload` for the atomic-frame PREMIUM dispatch.
    /// @dev The atomic envelope carries no separate premium intent. Premium hooks reuse the
    ///      rollover `RolloverIntent`, whose zero-digest hash was committed by `OrderData`.
    ///      Every other downstream-consumed field is set here from atomic-frame-derived
    ///      values (`premiumFor = msg.sender`, `subFiller` inherited from the rollover leg
    ///      in the same frame) or left at type default because the atomic-premium dispatch
    ///      path does not consume them.
    function _synthesizeAtomicPremiumPayload(
        RolloverTypes.RolloverIntent memory intent,
        bytes32 subFiller,
        bytes memory cptHolderSig
    ) private view returns (FillerPayload memory) {
        return FillerPayload({
            phaseU8: uint8(RolloverTypes.HookPhase.PREMIUM),
            fillAmount: 0,
            premium: 0,
            destination: address(0),
            premiumFor: msg.sender,
            intent: intent,
            minDstPerSrc: 0,
            fillerAuthSig: bytes(""),
            subFiller: subFiller,
            cptHolderSig: cptHolderSig
        });
    }

    /// @dev cPT-holder-opt-in async path for phase-tagged `fill`. Requires
    ///      `PREMIUM_PAYMENT_MODE_ATOMIC_OR_SEPARATE`, then executes either a rollover-only leg
    ///      or a premium leg that pays and settles a previously recorded rollover slot. Invalid
    ///      or future dispatch enum values revert before payload decode.
    /// @param context Shared fill context from `_decodeFillDispatchContext`.
    /// @param fillerData ABI-encoded async `FillerPayload`.
    function _fillAsync(FillDispatchContext memory context, bytes calldata fillerData) private {
        LibAtomicFill.FillDispatch dispatch = context.dispatch;
        if (
            dispatch != LibAtomicFill.FillDispatch.Rollover
                && dispatch != LibAtomicFill.FillDispatch.Premium
        ) {
            revert Settler__AtomicFillRequired();
        }

        if (
            context.orderData.premiumPaymentMode
                != RolloverTypes.PREMIUM_PAYMENT_MODE_ATOMIC_OR_SEPARATE
        ) {
            revert Settler__AsyncPremiumOptInRequired();
        }

        if (dispatch == LibAtomicFill.FillDispatch.Rollover) {
            FillerPayload memory rolloverPayload =
                LibFillerPayloadExternal.decodeAsyncRolloverPayload(fillerData);

            if (context.statusOnEntry == RolloverTypes.OrderStatus.None) {
                _admitDirectFill(context, rolloverPayload.cptHolderSig);
            }

            _checkFillerAuth(
                context.orderData,
                context.orderDigest,
                rolloverPayload.destination,
                rolloverPayload.subFiller,
                rolloverPayload.fillerAuthSig
            );
            _validateRolloverBeforeExecution(
                context.orderData,
                context.orderDigest,
                context.statusOnEntry,
                msg.sender,
                rolloverPayload
            );
            VerifiedRolloverDelivery memory delivery = _executeRolloverHooksAndVerifyDelivery(
                context.orderData, context.orderDigest, rolloverPayload
            );
            _finalizeVerifiedRollover(
                context.orderData, context.orderDigest, rolloverPayload, delivery
            );
        } else if (dispatch == LibAtomicFill.FillDispatch.Premium) {
            FillerPayload memory premiumPayload =
                LibFillerPayloadExternal.decodeAsyncPremiumPayload(fillerData);
            uint256 asyncPremiumCap = premiumPayload.premium;
            // Async PREMIUM is an independent fill frame. With no owner-auth cache, the
            // Settler rechecks the cPT-holder signature before the RolloverContract verifies it again.
            if (!SignatureChecker.isValidSignatureNow(
                    context.orderData.user, context.orderDigest, premiumPayload.cptHolderSig
                )) {
                revert Settler__BadUserSignature();
            }

            PremiumPaymentContext memory paymentContext;
            bytes32 resolvedSubFiller;
            (paymentContext, resolvedSubFiller) = _loadPremiumPaymentContext(
                context.orderDigest, premiumPayload, context.orderData.minPremiumPerShare
            );
            premiumPayload.subFiller = resolvedSubFiller;
            if (
                premiumPayload.destination != address(0)
                    && premiumPayload.destination != paymentContext.destination
            ) {
                revert Settler__PremiumDestinationMismatch();
            }

            _payPremiumAndReleaseDstCst(
                context.orderData,
                context.orderDigest,
                context.statusOnEntry,
                premiumPayload,
                paymentContext,
                asyncPremiumCap
            );
        }
    }

    /// @dev Admits a direct-fill order on first fill admission. cPT-holder order validation intentionally
    ///      precedes rollover filler auth because pre-open calldata is not admitted yet.
    /// @param context Shared fill context decoded from ERC-7683 `originData`.
    /// @param cptHolderSignature cPT-holder signature over `context.orderDigest`.
    function _admitDirectFill(FillDispatchContext memory context, bytes memory cptHolderSignature)
        private
    {
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > context.orderData.openDeadline) {
            revert Settler__OpenAfterOpenDeadline();
        }
        _validateOrderCommon(context.orderData, context.order);
        if (!SignatureChecker.isValidSignatureNow(
                context.orderData.user, context.orderDigest, cptHolderSignature
            )) {
            revert Settler__BadUserSignature();
        }

        // Transition None -> Opened on first admission.
        _setOrderStatus(context.orderDigest, RolloverTypes.OrderStatus.Opened);
        emit Open(
            context.orderDigest,
            LibRolloverOrder.buildResolvedOrder(
                context.orderData, context.order, context.orderDigest
            )
        );
    }

    /// @dev Completes an already-validated open admission by recording `Opened` and emitting Open.
    ///      All caller authorization, signature checks, deadlines, decoding, and shared envelope
    ///      validation must complete before this helper is called.
    /// @param orderData Canonical decoded order data.
    /// @param order ERC-7683 gasless cross-chain order envelope.
    /// @param orderDigest Canonical order digest.
    function _openValidatedOrder(
        RolloverTypes.OrderData memory orderData,
        ERC7683Types.GaslessCrossChainOrder memory order,
        bytes32 orderDigest
    ) private {
        RolloverTypes.OrderStatus status = _orderStatusOf(orderDigest);
        if (status == RolloverTypes.OrderStatus.Opened) {
            return;
        }
        if (blocksRollover(status)) {
            revert Settler__OrderInTerminalState();
        }
        _setOrderStatus(orderDigest, RolloverTypes.OrderStatus.Opened);
        emit Open(orderDigest, LibRolloverOrder.buildResolvedOrder(orderData, order, orderDigest));
    }

    /// @dev State-aware resolver core shared by gasless and on-chain ERC-7683 surfaces.
    ///      Orders at `None` must still satisfy the full admission envelope including
    ///      `openDeadline`; orders already `Opened` skip only that open-deadline gate while
    ///      retaining non-time envelope binding, shared Cork shape validation, fill-deadline
    ///      liveness, and terminal/closing exclusions.
    function _resolveDecodedOrder(
        RolloverTypes.OrderData memory orderData,
        ERC7683Types.GaslessCrossChainOrder memory gaslessOrder
    ) private view returns (ERC7683Types.ResolvedCrossChainOrder memory resolved) {
        bytes32 orderDigest = _orderDigestMemory(orderData);
        RolloverTypes.OrderStatus status = _orderStatusOf(orderDigest);
        if (blocksRollover(status)) {
            revert Settler__OrderInTerminalState();
        }
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > orderData.fillDeadline) {
            revert Settler__FillAfterDeadline();
        }

        // forge-lint: disable-next-line(block-timestamp)
        if (status != RolloverTypes.OrderStatus.Opened && block.timestamp > orderData.openDeadline)
        {
            revert Settler__OpenAfterOpenDeadline();
        }
        _validateOrderCommon(orderData, gaslessOrder);
        return LibRolloverOrder.buildResolvedOrder(orderData, gaslessOrder, orderDigest);
    }

    /// @dev Construct the gasless envelope Cork uses inside resolved-order `originData`.
    ///      The on-chain projection carries the envelope `fillDeadline` so common validation
    ///      binds it against the decoded order data.
    function _gaslessEquivalentOrder(
        RolloverTypes.OrderData memory orderData,
        bytes32 orderDataType,
        bytes memory encodedOrderData,
        uint32 fillDeadline
    ) private pure returns (ERC7683Types.GaslessCrossChainOrder memory gaslessOrder) {
        gaslessOrder = ERC7683Types.GaslessCrossChainOrder({
            originSettler: orderData.settler,
            user: orderData.user,
            nonce: orderData.orderSalt,
            originChainId: orderData.originChainId,
            openDeadline: uint32(orderData.openDeadline),
            fillDeadline: fillDeadline,
            orderDataType: orderDataType,
            orderData: encodedOrderData
        });
    }

    /// @dev Decodes canonical single-envelope ERC-7683 `originData`, derives the Cork order
    ///      body from `order.orderData`, and requires that order body to bind to `orderId`
    ///      before any lifecycle logic consumes it.
    /// @param orderId Caller-supplied ERC-7683 order id / Cork order digest.
    /// @param originData ABI-encoded `GaslessCrossChainOrder`.
    /// @return order Raw ERC-7683 gasless cross-chain order envelope.
    /// @return orderData Canonical order data decoded from `order.orderData`.
    function _decodeBoundOriginData(bytes32 orderId, bytes calldata originData)
        private
        view
        returns (
            ERC7683Types.GaslessCrossChainOrder memory order,
            RolloverTypes.OrderData memory orderData
        )
    {
        order = abi.decode(originData, (ERC7683Types.GaslessCrossChainOrder));
        if (keccak256(originData) != keccak256(abi.encode(order))) {
            revert Settler__OrderIdMismatch();
        }

        orderData = LibRolloverOrder.decodeOrderDataMemory(order);
        if (_orderDigestMemory(orderData) != orderId) {
            revert Settler__OrderIdMismatch();
        }
    }

    /// @dev Shape-and-binding validation shared by `openFor` admission and direct-fill
    ///      admission. Rejects malformed or self-grief envelopes before any state moves.
    /// @custom:invariant INV-PREMIUM-TOKEN-NONZERO — `orderData.premiumToken` must be
    ///                   nonzero at admission.
    /// @custom:invariant INV-PARAMS-SETTLER-PIN-MIRROR — `orderData.rolloverParams.settler`
    ///                   must equal `orderData.settler` at admission. Pattern-consistent
    ///                   with the srcCstToken / dstCstToken mirror checks. Defence in
    ///                   depth alongside the rolloverContract-side `_validateRolloverPreflight` pin.
    /// @custom:invariant INV-USER-IS-ROLLOVER_CONTRACT-OWNER — `orderData.user` must equal the
    ///                   CWIA-baked owner of `orderData.rolloverContract` at every admission point.
    /// @param orderData Canonical decoded order data.
    /// @param order ERC-7683 gasless cross-chain order envelope.
    function _validateOrderCommon(
        RolloverTypes.OrderData memory orderData,
        ERC7683Types.GaslessCrossChainOrder memory order
    ) internal view {
        LibSettlerAdmission.validateEnvelope(orderData, order, address(this));
        _validateMode(orderData);
        (bytes32 srcPoolId, bytes32 dstPoolId) =
            LibSettlerAdmission.validateOrderShape(orderData, address(this));

        if (!ICorkRolloverContractFactory(ROLLOVER_CONTRACT_FACTORY)
                .isDeployedRolloverContract(orderData.rolloverContract)) {
            revert Settler__RolloverContractNotDeployed(orderData.user);
        }
        if (orderData.user != ICorkRolloverContract(orderData.rolloverContract).owner()) {
            revert Settler__UserNotRolloverContractOwner(orderData.user, orderData.rolloverContract);
        }

        IPoolManager poolManager = IPoolManager(CORK_POOL_MANAGER);
        (, address canonicalSrcCst) = poolManager.shares(MarketId.wrap(srcPoolId));
        if (canonicalSrcCst != orderData.srcCstToken) {
            revert Settler__SrcCstNotCanonical();
        }
        (, address canonicalDstCst) = poolManager.shares(MarketId.wrap(dstPoolId));
        if (canonicalDstCst != orderData.dstCstToken) {
            revert Settler__DstCstNotCanonical();
        }

        LibPhoenixShareQuantum.requireOrderSizeAligned(poolManager, srcPoolId, orderData.orderSize);

        uint256 srcExpiry = IPoolShare(orderData.srcCstToken).expiry();
        uint256 dstExpiry = IPoolShare(orderData.dstCstToken).expiry();
        if (orderData.fillDeadline >= srcExpiry || orderData.fillDeadline >= dstExpiry) {
            revert Settler__FillDeadlineExceedsPoolExpiry(
                orderData.fillDeadline, srcExpiry, dstExpiry
            );
        }
    }

    /// @dev Re-derives the canonical lifecycle digest from decoded `OrderData`.
    /// @param orderData Canonical decoded order data.
    /// @return orderDigest EIP-712 digest for `orderData` under this settler's domain.
    /// @custom:invariant N-INV-LIFECYCLE-ORIGINDATA-DIGEST-BINDING
    function _orderDigestMemory(RolloverTypes.OrderData memory orderData)
        internal
        view
        returns (bytes32 orderDigest)
    {
        return LibSettlerHashing.computeOrderDigestMemory(orderData, _domainSeparatorV4());
    }

    /// @dev Validates decoded rollover admission before token movement.
    ///      This helper is a pre-movement admission boundary: every revert here occurs before
    ///      filler funds move or rolloverContract hooks execute. Assumes `fillerPayload` came from a
    ///      rollover-specific decoder that already rejected non-ROLLOVER phase and premium fields.
    /// @custom:invariant INV-ROLLOVER-FILL-AMOUNT-RANGE — zero fills and overfills are rejected
    ///                   before execution for both exact and partial modes.
    /// @param orderData Canonical decoded order data.
    /// @param orderDigest Canonical order digest.
    /// @param statusOnEntry Order status captured at the `fill` entry boundary.
    /// @param filler Current rollover filler.
    /// @param fillerPayload Decoded rollover payload.
    function _validateRolloverBeforeExecution(
        RolloverTypes.OrderData memory orderData,
        bytes32 orderDigest,
        RolloverTypes.OrderStatus statusOnEntry,
        address filler,
        FillerPayload memory fillerPayload
    ) private view {
        if (blocksRollover(statusOnEntry)) {
            revert Settler__OrderInTerminalState();
        }

        // INV-ROLLOVER-FILL-AMOUNT-RANGE: every requested rollover leg must fit the signed order.
        if (fillerPayload.fillAmount == 0 || fillerPayload.fillAmount > orderData.orderSize) {
            revert Settler__RolloverAmountOutOfBounds(orderData.orderSize, fillerPayload.fillAmount);
        }
        if (fillerPayload.destination == address(0)) {
            revert Settler__ZeroAddress();
        }

        _validateRolloverBeforeExecutionForMode(orderData, orderDigest, filler, fillerPayload);
    }

    /// @dev Executes the rollover hook boundary and verifies RolloverContract reports against token deltas.
    ///      This helper owns the external factory/rolloverContract boundary: returned values are reports
    ///      only, and are not used for accounting until bounded by observed token movement.
    /// @custom:invariant INV-SRC-CST-PREDEPOSITED — srcCST moves directly from filler to rolloverContract;
    ///                   the Settler only measures and refunds rolloverContract-returned srcCST leftover.
    /// @custom:invariant INV-ROLLOVER-SRC-DELTA-FLOOR —
    ///                   `reportedSrcLeftover <= fillAmount` and
    ///                   `srcDelivered >= reportedSrcLeftover` after hooks.
    /// @custom:invariant INV-DSTCST-LIABILITY-BACKED — `delivered >= reportedDstProduced` after
    ///                   hooks; overdelivery is not credited to fill accounting. A backed high
    ///                   report is credited as real production; premium caps bound payment.
    /// @param orderData Canonical decoded order data.
    /// @param orderDigest Canonical order digest.
    /// @param fillerPayload Decoded rollover payload.
    /// @return delivery Verified rollover hook delivery.
    function _executeRolloverHooksAndVerifyDelivery(
        RolloverTypes.OrderData memory orderData,
        bytes32 orderDigest,
        FillerPayload memory fillerPayload
    ) private returns (VerifiedRolloverDelivery memory delivery) {
        uint256 fillAmount = fillerPayload.fillAmount;

        // INV-SRC-CST-PREDEPOSITED — srcCST flows filler → rolloverContract DIRECTLY. The Settler is not
        // a transient custodian on the rollover path; `srcBeforeRollover` snapshots the Settler's
        // pre-dispatch balance so the post-leg `srcDelivered` check at the bottom of this function
        // measures only the rolloverContract's refund of unconsumed srcCST.
        IERC20 srcCst = IERC20(orderData.srcCstToken);
        IERC20 dstCst = IERC20(orderData.dstCstToken);

        srcCst.safeTransferFrom(msg.sender, orderData.rolloverContract, fillAmount);

        uint256 srcBeforeRollover = srcCst.balanceOf(address(this));
        uint256 dstBeforeRollover = dstCst.balanceOf(address(this));
        RolloverTypes.FillContext memory rolloverContext = RolloverTypes.FillContext({
            filler: msg.sender,
            fillAmount: fillerPayload.fillAmount,
            rolloverIntentHash: orderData.rolloverIntentHash,
            fillDeadline: orderData.fillDeadline,
            allowPartialFills: orderData.allowPartialFills,
            allowUnderfill: orderData.allowUnderfill,
            orderSize: orderData.orderSize,
            originSettler: address(this),
            premiumToken: address(0),
            premium: 0,
            subFiller: fillerPayload.subFiller
        });
        (uint256 reportedDstProduced, uint256 reportedSrcLeftover) =
            _dispatchToFactory(orderData, orderDigest, fillerPayload, rolloverContext);

        if (reportedDstProduced == 0) {
            revert Settler__ZeroMint();
        }
        if (reportedSrcLeftover > fillAmount) {
            revert Settler__SrcLeftoverExceedsFillAmount(reportedSrcLeftover, fillAmount);
        }

        uint256 dstDelivered = dstCst.balanceOf(address(this)) - dstBeforeRollover;
        if (dstDelivered < reportedDstProduced) {
            revert Settler__DstProducedNotDelivered(reportedDstProduced, dstDelivered);
        }

        uint256 srcDelivered = srcCst.balanceOf(address(this)) - srcBeforeRollover;
        if (srcDelivered < reportedSrcLeftover) {
            revert Settler__SrcLeftoverDeliveryShortfall(reportedSrcLeftover, srcDelivered);
        }

        delivery = VerifiedRolloverDelivery({
            dstProduced: reportedDstProduced, srcLeftover: reportedSrcLeftover
        });
    }

    /// @dev Applies a verified rollover delivery. Ordering is intentional: mode delivery checks,
    ///      mint-floor check, record write, liability increase, event, srcCST refund.
    /// @custom:invariant INV-DSTCST-FLOOR — filler's minimum dst-per-src floor is checked against
    ///                   reported dstCST after delivery reconciliation.
    /// @param orderData Canonical decoded order data.
    /// @param orderDigest Canonical order digest.
    /// @param fillerPayload Decoded rollover payload.
    /// @param delivery Verified rollover hook delivery.
    function _finalizeVerifiedRollover(
        RolloverTypes.OrderData memory orderData,
        bytes32 orderDigest,
        FillerPayload memory fillerPayload,
        VerifiedRolloverDelivery memory delivery
    ) private {
        address rolloverFiller = msg.sender;

        _validateRolloverDeliveryForMode(orderData, delivery);

        uint256 srcConsumed = fillerPayload.fillAmount - delivery.srcLeftover;
        // INV-DSTCST-FLOOR — explicit `Math.Rounding.Floor` per phoenix `MathHelper`
        // convention (filler-receives amounts round protocol-conservative). Floor is the
        // OZ default; the 4-arg form makes the rounding contract explicit and pins the
        // 1-wei filler-favourable drift bound visible at the call site.
        uint256 requiredDstProduced = fillerPayload.minDstPerSrc == 0
            ? 0
            : Math.mulDiv(srcConsumed, fillerPayload.minDstPerSrc, 1e18, Math.Rounding.Floor);

        if (delivery.dstProduced < requiredDstProduced) {
            revert Settler__InsufficientMintRate(requiredDstProduced, delivery.dstProduced);
        }

        _recordRolloverAccountingForMode(
            orderDigest,
            rolloverFiller,
            fillerPayload.subFiller,
            delivery.dstProduced,
            srcConsumed,
            fillerPayload.destination,
            orderData.orderSize
        );
        dstCstLiability[orderData.dstCstToken] += delivery.dstProduced;
        emit RolloverLegFilled(
            orderDigest, rolloverFiller, fillerPayload.subFiller, srcConsumed, delivery.dstProduced
        );

        if (delivery.srcLeftover > 0) {
            // Refund unused srcCST to the immediate fill caller. Helper contracts and adapters
            // receive this refund first, then apply their own upstream tail-refund policy.
            IERC20(orderData.srcCstToken).safeTransfer(rolloverFiller, delivery.srcLeftover);
            emit SrcCstRefunded(
                orderDigest, rolloverFiller, fillerPayload.subFiller, delivery.srcLeftover
            );
        }
    }

    /// @dev Returns token balance not backing live dstCST liability. Reverts fail-closed when the
    ///      current balance is already below tracked liability.
    /// @param token ERC-20 token being inspected.
    /// @return recoverableBalance Token balance above tracked dstCST liability.
    function _recoverableTokenBalance(IERC20 token) internal view returns (uint256) {
        address tokenAddress = address(token);
        uint256 balance = token.balanceOf(address(this));
        uint256 liability = dstCstLiability[tokenAddress];
        if (balance < liability) {
            revert Settler__UnderfundedDstCstLiability();
        }
        return balance - liability;
    }

    /// @dev Pays the PREMIUM leg and releases the recorded dstCST residual. The premium payment
    ///      path enforces the caller-supplied cap, pushes required premium from the filler directly
    ///      to the rolloverContract (no Settler intermediary), dispatches premium hooks, latches mode premium
    ///      state, settles the paid rollover record, and releases owed dstCST.
    ///
    ///      Any premium hook revert bubbles through the current `fill`. In atomic fill this
    ///      unwinds admit + rollover + premium in one frame; in async PREMIUM the previous
    ///      rollover record remains unpaid because it was created in an earlier transaction.
    /// @custom:invariant INV-PREMIUM-PAID-RELEASES-DST — premium ERC-20 successfully
    ///                   transferred from filler to rolloverContract AND rolloverContract hook succeeded ⇒
    ///                   Settler `premiumFired = true` and owed dstCST released on return. Hook
    ///                   reverts never park premium state without a successful hook dispatch.
    /// @custom:invariant INV-PREMIUM-HOOK-REVERT-CASCADES — atomic premium hook revert reverts
    ///                   the entire atomic fill; no partial atomic state persists.
    /// @param orderData Canonical decoded order data.
    /// @param orderDigest Canonical order digest.
    /// @param statusOnEntry Order status captured at the `fill` entry boundary.
    /// @param fillerPayload Decoded premium payload.
    /// @param paymentContext Premium payment context loaded from mode storage.
    /// @param premiumPaymentCap Caller-supplied cap on required premium.
    function _payPremiumAndReleaseDstCst(
        RolloverTypes.OrderData memory orderData,
        bytes32 orderDigest,
        RolloverTypes.OrderStatus statusOnEntry,
        FillerPayload memory fillerPayload,
        PremiumPaymentContext memory paymentContext,
        uint256 premiumPaymentCap
    ) private {
        if (isHardTerminal(statusOnEntry)) {
            revert Settler__OrderInTerminalState();
        }

        uint256 requiredPremium = paymentContext.requiredPremium;
        if (requiredPremium > premiumPaymentCap) {
            revert Settler__PremiumExceedsCap(premiumPaymentCap, requiredPremium);
        }

        if (requiredPremium > 0) {
            // Direct filler → rolloverContract push (no Settler custody). The delivered-delta check measures
            // the rolloverContract's balance change so fee-on-transfer / blocklist / rebasing tokens still
            // surface as a delivery mismatch.
            IERC20 premiumToken = IERC20(orderData.premiumToken);
            uint256 rolloverContractPremiumBefore =
                premiumToken.balanceOf(orderData.rolloverContract);
            premiumToken.safeTransferFrom(msg.sender, orderData.rolloverContract, requiredPremium);
            uint256 premiumDelivered =
                premiumToken.balanceOf(orderData.rolloverContract) - rolloverContractPremiumBefore;
            if (premiumDelivered != requiredPremium) {
                revert Settler__PremiumDeliveryMismatch(requiredPremium, premiumDelivered);
            }
        }

        // Direct factory call — any hook revert cascades through the current fill.
        RolloverTypes.FillContext memory premiumContext = RolloverTypes.FillContext({
            filler: paymentContext.rolloverFiller,
            fillAmount: fillerPayload.fillAmount,
            rolloverIntentHash: orderData.rolloverIntentHash,
            fillDeadline: orderData.fillDeadline,
            allowPartialFills: orderData.allowPartialFills,
            allowUnderfill: orderData.allowUnderfill,
            orderSize: orderData.orderSize,
            originSettler: address(this),
            premiumToken: orderData.premiumToken,
            premium: requiredPremium,
            subFiller: fillerPayload.subFiller
        });
        _dispatchToFactory(orderData, orderDigest, fillerPayload, premiumContext);
        _recordPremiumPaid(orderDigest, paymentContext, fillerPayload.subFiller);
        emit PremiumLegFilled(
            orderDigest,
            msg.sender,
            paymentContext.rolloverFiller,
            fillerPayload.subFiller,
            requiredPremium
        );

        uint256 settledDstCst = _settlePaidRolloverRecord(
            orderDigest,
            paymentContext.rolloverFiller,
            fillerPayload.subFiller,
            _orderStatusOf(orderDigest),
            orderData
        );
        if (settledDstCst > 0) {
            dstCstLiability[orderData.dstCstToken] -= settledDstCst;
            IERC20(orderData.dstCstToken).safeTransfer(paymentContext.destination, settledDstCst);
        }
    }

    /// @dev External factory/rolloverContract hook-dispatch boundary. The returned values are rolloverContract
    ///      reports and must be verified by the caller before they affect accounting.
    ///      Kept as a stack-pressure boundary: inlining this dispatch breaks non-IR builds.
    /// @param orderData Decoded order data.
    /// @param orderDigest Canonical order digest / ERC-7683 order id.
    /// @param fillerPayload Decoded filler payload for the current hook phase.
    /// @param fillContext Cork fill context forwarded to the rolloverContract hooks.
    /// @return reportedDstProduced RolloverContract-reported dstCST production.
    /// @return reportedSrcLeftover RolloverContract-reported srcCST leftover.
    function _dispatchToFactory(
        RolloverTypes.OrderData memory orderData,
        bytes32 orderDigest,
        FillerPayload memory fillerPayload,
        RolloverTypes.FillContext memory fillContext
    ) private returns (uint256, uint256) {
        return IRolloverHookDispatcher(ROLLOVER_CONTRACT_FACTORY)
            .executeIntentHooks(
                orderData.rolloverContract,
                orderDigest,
                LibHookPhase.from(fillerPayload.phaseU8),
                fillerPayload.intent,
                fillerPayload.cptHolderSig,
                fillContext,
                orderData
            );
    }

    /// @dev Verifies the current rollover-leg caller is authorized for `(orderDigest, authDestination,
    ///      subFiller)`. Async PREMIUM settlement does not re-query live filler auth after a
    ///      rollover slot records the destination.
    /// @param orderData Decoded order data containing optional `exclusiveFiller`.
    /// @param orderDigest Canonical order digest / ERC-7683 order id.
    /// @param authDestination Destination bound into the filler authorization digest.
    /// @param subFiller Sub-filler key bound into the filler authorization digest.
    /// @param fillerAuthSig Optional signature by `orderData.exclusiveFiller`.
    function _checkFillerAuth(
        RolloverTypes.OrderData memory orderData,
        bytes32 orderDigest,
        address authDestination,
        bytes32 subFiller,
        bytes memory fillerAuthSig
    ) private view {
        bool isAuthorised = LibFillerAuth.isAuthorised(
            orderData.exclusiveFiller,
            msg.sender,
            _domainSeparatorV4(),
            orderDigest,
            authDestination,
            subFiller,
            fillerAuthSig
        );
        if (!isAuthorised) {
            revert Settler__UnauthorizedFiller(orderData.exclusiveFiller, msg.sender);
        }
    }

    /// @notice Validates exact-vs-partial mode flags during order admission.
    /// @dev Called from shared order validation before any status write or token movement.
    /// @param orderData Decoded order data.
    function _validateMode(RolloverTypes.OrderData memory orderData) internal view virtual;

    /// @notice Reads mode-specific order status storage.
    /// @param orderDigest Order digest.
    /// @return Current status enum value.
    function _orderStatusOf(bytes32 orderDigest)
        internal
        view
        virtual
        returns (RolloverTypes.OrderStatus);

    /// @notice Writes mode-specific order status storage.
    /// @param orderDigest Order digest.
    /// @param status New status enum value.
    function _setOrderStatus(bytes32 orderDigest, RolloverTypes.OrderStatus status) internal virtual;

    /// @notice Reverts when mode-specific policy or state blocks rollover execution.
    /// @dev Called after Base's universal rollover gates and before srcCST movement or hook
    ///      dispatch. Exact mode enforces full-fill/underfill/one-fill policy; partial mode
    ///      enforces aggregate fill, quantum, and per-slot repeat-fill policy.
    /// @param orderData Decoded order data.
    /// @param orderId Order digest.
    /// @param filler Rollover filler.
    /// @param fillerPayload Decoded rollover payload.
    function _validateRolloverBeforeExecutionForMode(
        RolloverTypes.OrderData memory orderData,
        bytes32 orderId,
        address filler,
        FillerPayload memory fillerPayload
    ) internal view virtual;

    /// @notice Reverts when mode-specific policy rejects verified rollover delivery.
    /// @dev Called after Base has reconciled rolloverContract reports against observed token deltas and
    ///      before mode accounting or dstCST liability is recorded.
    /// @param orderData Decoded order data.
    /// @param delivery Verified rollover hook delivery.
    function _validateRolloverDeliveryForMode(
        RolloverTypes.OrderData memory orderData,
        VerifiedRolloverDelivery memory delivery
    ) internal view virtual { }

    /// @notice Records mode-specific rollover leg accounting.
    /// @dev Called after Base's delivery and mint-floor checks. A revert here unwinds the current
    ///      fill before Base increases dstCST liability or emits rollover/refund events.
    /// @param orderId Order digest.
    /// @param filler Rollover filler.
    /// @param subFiller Partial-mode sub-filler identity (ignored by exact mode).
    /// @param dstProduced Destination CST produced.
    /// @param srcConsumed Source CST consumed.
    /// @param destination Recorded settlement destination.
    /// @param orderSize Signed order size.
    function _recordRolloverAccountingForMode(
        bytes32 orderId,
        address filler,
        bytes32 subFiller,
        uint256 dstProduced,
        uint256 srcConsumed,
        address destination,
        uint256 orderSize
    ) internal virtual;

    /// @notice Loads the premium payment context for the rollover record being paid.
    /// @dev Resolves the mode-specific sub-filler key, rejects missing/paid/settled rollover
    ///      records, and returns the premium amount and settlement destination Base must use.
    /// @param orderId Order digest.
    /// @param fillerPayload Decoded premium payload.
    /// @param minPremiumPerShare Signed minimum premium per produced dstCST share.
    /// @return paymentContext Premium payment context used for auth, premium floor, and dispatch.
    /// @return resolvedSubFiller Resolved sub-filler key used for auth, accounting, and settlement.
    function _loadPremiumPaymentContext(
        bytes32 orderId,
        FillerPayload memory fillerPayload,
        uint256 minPremiumPerShare
    )
        internal
        view
        virtual
        returns (PremiumPaymentContext memory paymentContext, bytes32 resolvedSubFiller);

    /// @notice Records mode-specific premium accounting and marks the rollover record paid.
    /// @dev Called only after Base has verified premium delivery and premium hook success.
    /// @param orderId Order digest.
    /// @param paymentContext Premium context loaded from mode storage before payment.
    /// @param subFiller Resolved sub-filler key.
    function _recordPremiumPaid(
        bytes32 orderId,
        PremiumPaymentContext memory paymentContext,
        bytes32 subFiller
    ) internal virtual;

    /// @notice Settles a paid exact or partial rollover residual.
    /// @dev Mode hook mutates mode residual/status state and returns the dstCST amount Base must
    ///      release. It must not transfer dstCST; Base owns liability decrement and token release.
    /// @param orderId Order digest.
    /// @param filler Filler whose residual should settle.
    /// @param subFiller Partial-mode sub-filler identity (ignored by exact mode).
    /// @param status Status on entry.
    /// @param orderData Decoded order data.
    function _settlePaidRolloverRecord(
        bytes32 orderId,
        address filler,
        bytes32 subFiller,
        RolloverTypes.OrderStatus status,
        RolloverTypes.OrderData memory orderData
    ) internal virtual returns (uint256 settledDstCst);

    /// @notice Clears mode-specific unpaid residual state for reclaim and returns the dstCST amount to release.
    /// @dev Called after Base reclaim status/deadline/mode gates. It must not transfer dstCST;
    ///      Base owns liability decrement and token release to the originating rolloverContract.
    /// @param orderId Order digest.
    /// @param defaulterFiller Filler whose unpaid residual is being reclaimed.
    /// @param subFiller Partial-mode sub-filler identity (ignored by exact mode).
    /// @param orderData Decoded order data.
    /// @return reclaimedDstCst Destination CST amount Base must release to `orderData.rolloverContract`.
    function _clearReclaimableResidualForMode(
        bytes32 orderId,
        address defaulterFiller,
        bytes32 subFiller,
        RolloverTypes.OrderData memory orderData
    ) internal virtual returns (uint256 reclaimedDstCst);

    /// @notice Applies exact or partial cancel transition accounting.
    /// @dev Called after Base has verified the cPT-holder cancel signature and status gate.
    /// @param orderId Order digest.
    function _cancelOrderForMode(bytes32 orderId) internal virtual;

    /// @notice Applies mode-specific status finalization after reclaim.
    /// @dev Must not finalize `Closing` partial orders as `Cancelled` until mode escrow is drained.
    /// @custom:invariant INV-FSM-TERMINAL-WRITE-COMPLETE
    /// @param orderId Order digest.
    /// @param statusOnEntry Order status captured at the `reclaim` entry boundary.
    function _finalizeReclaimStatusForMode(bytes32 orderId, RolloverTypes.OrderStatus statusOnEntry)
        internal
        virtual;
}
