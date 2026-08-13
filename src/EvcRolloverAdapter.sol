// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    ReentrancyGuardTransient
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { ISignatureTransfer } from "permit2/interfaces/ISignatureTransfer.sol";
import {
    EvcRolloverAdapter__CallerNotEvc,
    EvcRolloverAdapter__ControllerNotEnabled,
    EvcRolloverAdapter__FundingAccountMismatch,
    EvcRolloverAdapter__FundingSigInvalid,
    EvcRolloverAdapter__NotEvcContext,
    EvcRolloverAdapter__OnBehalfMismatch,
    EvcRolloverAdapter__PartialOrderRequired,
    EvcRolloverAdapter__SettlerMismatch,
    EvcRolloverAdapter__SubaccountAuthorityMissing,
    EvcRolloverAdapter__UnknownSettler,
    EvcRolloverAdapter__ZeroController,
    EvcRolloverAdapter__ZeroEvc,
    EvcRolloverAdapter__ZeroFundingAccount,
    EvcRolloverAdapter__ZeroPermit2,
    EvcRolloverAdapter__ZeroRecipient,
    EvcRolloverAdapter__ZeroSettler
} from "src/errors/EvcRolloverAdapterErrors.sol";
import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import { ISettler } from "src/interfaces/settlers/ISettler.sol";
import { LibAuthenticatedHooks } from "src/libraries/LibAuthenticatedHooks.sol";
import { LibFillerPayload } from "src/libraries/LibFillerPayload.sol";
import { LibRolloverOrder } from "src/libraries/LibRolloverOrder.sol";
import { LibSettlerHashing } from "src/libraries/LibSettlerHashing.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @title IEVC
/// @notice Minimal Euler EVC surface consumed by `EvcRolloverAdapter`: on-behalf-of
///         frame inspection for INV-EVC-CALLER-AUTHORIZED and subaccount owner
///         resolution for the Permit2 witness path
///         (INV-ADAPTER-JOB-AUTHORIZED).
interface IEVC {
    /// @notice Read the current `(onBehalfOfAccount, controllerEnabled)` pair for a controller.
    /// @param controllerToCheck Controller address to query.
    /// @return onBehalfOfAccount Subaccount that the call is running on behalf of.
    /// @return controllerEnabled True if the controller is enabled for `onBehalfOfAccount`.
    function getCurrentOnBehalfOfAccount(address controllerToCheck)
        external
        view
        returns (address onBehalfOfAccount, bool controllerEnabled);

    /// @notice Resolve the registered owner of an EVC account (primary EOA for
    ///         XOR-derived subaccounts, or the contract address for
    ///         contract-at-subaccount integrators).
    /// @dev Reverts in real EVC when the account has no registered owner.
    /// @param account EVC account / subaccount to query.
    /// @return owner The account's registered owner.
    function getAccountOwner(address account) external view returns (address owner);
}

/// @title EvcRolloverAdapter
/// @notice Euler-EVC-gated rollover adapter. Mirrors `BaseFiller` execution but bills the
///         caller's EVC subaccount instead of `msg.sender` and gates entry on a live EVC
///         controller-enabled context. Both exact and partial jobs settle in the same transaction.
///
/// @dev EVC-gated Permit2 funding model:
///      `execute` / `executePartial` pull `fillerSrcCst` and `premium` from
///      `job.fundingAccount` via a single `Permit2.permitWitnessTransferFrom`
///      batch call whose witness binds the exact job parameters (subaccount,
///      funding account, both token amounts, minDstPerSrc, intent hash, order
///      digest, nonce, deadline). The adapter does NOT consume any direct
///      ERC-20 standing allowance from `job.subaccount`; the user's only
///      allowance is the canonical "approve Permit2 once, sign per-job amounts"
///      pattern.
///
///      The Permit2 signer is `job.fundingAccount`, which must equal
///      `EVC.getAccountOwner(subaccount)` — for an EOA-owned subaccount, the
///      primary EOA; for a contract-owned subaccount, the contract address
///      itself (Permit2's `SignatureVerification.verify` falls back to
///      EIP-1271 `isValidSignature` when the resolved signer is a contract).
///      Contract-at-subaccount integrators remain supported.
/// @custom:security-contact security@cork.tech
contract EvcRolloverAdapter is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice Caller-supplied job description for an EVC-gated rollover execution.
    /// @param settler Expected Settler address (must equal `SETTLER`).
    /// @param order ERC-7683 gasless cross-chain order envelope.
    /// @param userSig cPT-holder signature.
    /// @param subaccount EVC subaccount whose on-behalf-of frame authorizes the fill.
    /// @param fundingAccount Permit2 token owner that funds the fill; must equal
    ///        `EVC.getAccountOwner(subaccount)` and is bound in the witness.
    /// @param recipient Settlement destination and tail-refund recipient; bound in the
    ///        Permit2 witness, rollover `destination`, and filler-auth digest.
    /// @param srcCst Source CST ERC-20.
    /// @param premiumToken Premium-token ERC-20.
    /// @param fillerSrcCst srcCST amount this job provides.
    /// @param minDstPerSrc dstCST-per-srcCST floor (INV-DSTCST-FLOOR; 0 = opt out). The on-chain
    ///        check is `dstProduced >= floor(srcConsumed × minDstPerSrc / 1e18)`; per-fill drift
    ///        bounded at 1 wei dstCST in the filler's favour when the product is not divisible
    ///        by 1e18 (phoenix-convention Floor rounding, OZ Math.Rounding.Floor).
    /// @param intent `RolloverIntent` payload committed by the cPT-holder-signed order.
    /// @param premium Premium ceiling (also used as the upfront pull from the subaccount).
    /// @param fillerAuthSig Optional exclusive-filler signature (INV-FILLER-AUTH).
    /// @param nonce Permit2 unordered nonce for the per-job funding signature
    ///        (INV-ADAPTER-JOB-AUTHORIZED).
    /// @param deadline Permit2 deadline (UNIX seconds) for the per-job funding signature.
    /// @param fundingSig EIP-712 signature over the Permit2
    ///        `PermitBatchWitnessTransferFrom` typehash (TokenPermissions[]
    ///        + nonce + deadline + witness), produced by
    ///        `EVC.getAccountOwner(subaccount)`. Replaces the standing ERC-20
    ///        allowance funding model (INV-ADAPTER-NO-STANDING-ALLOWANCE).
    struct EvcRolloverJob {
        ISettler settler;
        ERC7683Types.GaslessCrossChainOrder order;
        bytes userSig;
        address subaccount;
        address fundingAccount;
        address recipient;
        IERC20 srcCst;
        IERC20 premiumToken;
        uint256 fillerSrcCst;

        uint256 minDstPerSrc;
        RolloverTypes.RolloverIntent intent;
        uint256 premium;

        bytes fillerAuthSig;
        uint256 nonce;
        uint256 deadline;
        bytes fundingSig;
    }

    /// @notice Immutable EVC instance this adapter is bound to.
    /// @return EVC Stored evc value.
    IEVC public immutable EVC;

    /// @notice Controller address whose context gates entry.
    /// @return CONTROLLER Stored controller value.
    address public immutable CONTROLLER;

    /// @notice Immutable exact-mode Settler this adapter is bound to.
    /// @return EXACT_SETTLER Stored exact settler value.
    ISettler public immutable EXACT_SETTLER;

    /// @notice Immutable partial-mode Settler this adapter is bound to.
    /// @return PARTIAL_SETTLER Stored partial settler value.
    ISettler public immutable PARTIAL_SETTLER;

    /// @notice Immutable canonical Permit2 instance this adapter pulls job
    ///         funds through (INV-ADAPTER-JOB-AUTHORIZED).
    /// @return PERMIT2 Stored Permit2 value.
    ISignatureTransfer public immutable PERMIT2;

    /// @notice EIP-712 typehash for the per-job witness blob signed by the
    ///         subaccount's EVC owner alongside the Permit2
    ///         `PermitBatchTransferFrom` envelope.
    bytes32 public constant WITNESS_TYPEHASH = keccak256(
        // solhint-disable-next-line max-line-length
        "EvcRolloverJobWitness(address subaccount,address fundingAccount,address recipient,address srcCst,uint256 fillerSrcCst,address premiumToken,uint256 premium,uint256 minDstPerSrc,bytes32 intentHash,bytes32 orderDigest,uint256 nonce,uint256 deadline)"
    );

    /// @notice EIP-712 type-string suffix required by Permit2 for the
    ///         witness-typed batch transfer (must append the trailing
    ///         `TokenPermissions` struct per Permit2 conventions).
    // solhint-disable-next-line max-line-length
    string public constant WITNESS_TYPESTRING =
        "EvcRolloverJobWitness witness)EvcRolloverJobWitness(address subaccount,address fundingAccount,address recipient,address srcCst,uint256 fillerSrcCst,address premiumToken,uint256 premium,uint256 minDstPerSrc,bytes32 intentHash,bytes32 orderDigest,uint256 nonce,uint256 deadline)TokenPermissions(address token,uint256 amount)";

    /// @notice Emitted after Permit2 successfully pulls job funding into the adapter.
    /// @param orderDigest Canonical order digest for the job.
    /// @param subaccount EVC subaccount authorizing the rollover.
    /// @param fundingAccount Permit2 token owner that funded the job.
    /// @param subFiller Adapter-derived sub-filler key for the EVC subaccount.
    /// @param token Token pulled into the adapter.
    /// @param amount Amount pulled.
    /// @param recipient Settlement destination and tail-refund recipient bound to the job.
    event AdapterFundingPulled(
        bytes32 indexed orderDigest,
        address indexed subaccount,
        address indexed fundingAccount,
        bytes32 subFiller,
        address token,
        uint256 amount,
        address recipient
    );

    /// @notice Emitted after surplus adapter-held funding is returned to the job recipient.
    /// @param orderDigest Canonical order digest for the job.
    /// @param subaccount EVC subaccount authorizing the rollover.
    /// @param recipient Settlement destination and tail-refund recipient bound to the job.
    /// @param subFiller Adapter-derived sub-filler key for the EVC subaccount.
    /// @param token Token refunded from the adapter tail.
    /// @param amount Amount refunded.
    event AdapterTailRefunded(
        bytes32 indexed orderDigest,
        address indexed subaccount,
        address indexed recipient,
        bytes32 subFiller,
        address token,
        uint256 amount
    );

    /// @notice Bind this adapter to an EVC + controller + exact/partial Settler set + Permit2.
    /// @param evc_ EVC contract.
    /// @param controller_ Controller address whose context gates entry.
    /// @param exactSettler_ Exact-mode Settler address.
    /// @param partialSettler_ Partial-mode Settler address.
    /// @param permit2_ Permit2 instance (canonical
    ///        `0x000000000022D473030F116dDEE9F6B43aC78BA3` on every supported
    ///        chain; deployment scripts MUST verify chain coverage).
    constructor(
        IEVC evc_,
        address controller_,
        ISettler exactSettler_,
        ISettler partialSettler_,
        ISignatureTransfer permit2_
    ) {
        if (address(evc_) == address(0)) {
            revert EvcRolloverAdapter__ZeroEvc();
        }
        if (controller_ == address(0)) {
            revert EvcRolloverAdapter__ZeroController();
        }
        if (address(exactSettler_) == address(0)) {
            revert EvcRolloverAdapter__ZeroSettler();
        }
        if (address(partialSettler_) == address(0)) {
            revert EvcRolloverAdapter__ZeroSettler();
        }
        if (address(permit2_) == address(0)) {
            revert EvcRolloverAdapter__ZeroPermit2();
        }
        EVC = evc_;
        CONTROLLER = controller_;
        EXACT_SETTLER = exactSettler_;
        PARTIAL_SETTLER = partialSettler_;
        PERMIT2 = permit2_;
    }

    /// @notice Execute an openFor → atomic fill flow under EVC gating.
    /// @dev Supports exact and partial orders; settlement happens inside the atomic fill.
    /// @custom:invariant N-INV-HELPER-FUNDING-RESTORES-SNAPSHOTS
    /// @param job Job descriptor.
    function execute(EvcRolloverJob calldata job) external nonReentrant {
        _gateEvc(job.subaccount);
        bytes32 subFiller = bytes32(uint256(uint160(job.subaccount)));
        RolloverTypes.OrderData memory orderData = LibRolloverOrder.decodeOrderData(job.order);
        ISettler settler = _settlerFor(orderData);
        _assertExpectedSettler(settler, job.settler);
        bytes32 orderDigest =
            LibSettlerHashing.computeOrderDigestMemory(orderData, settler.DOMAIN_SEPARATOR());

        uint256 preBal = job.srcCst.balanceOf(address(this));
        uint256 premiumPreBal = job.premiumToken.balanceOf(address(this));
        _pullJobFundsAndAuthorize(job, settler, orderData, orderDigest, subFiller);

        _runSettlementCommon(job, settler, orderDigest, subFiller);

        _refundTails(
            job.srcCst,
            job.premiumToken,
            preBal,
            premiumPreBal,
            job.subaccount,
            job.recipient,
            orderDigest,
            subFiller
        );
    }

    /// @notice Execute a partial-mode openFor → atomic fill flow under EVC gating.
    /// @dev Kept as an explicit partial-mode entrypoint for callers that want a mode-named API.
    /// @custom:invariant N-INV-HELPER-FUNDING-RESTORES-SNAPSHOTS
    /// @param job Job descriptor.
    function executePartial(EvcRolloverJob calldata job) external nonReentrant {
        _gateEvc(job.subaccount);
        bytes32 subFiller = bytes32(uint256(uint160(job.subaccount)));
        RolloverTypes.OrderData memory orderData = LibRolloverOrder.decodeOrderData(job.order);
        if (!orderData.allowPartialFills) {
            revert EvcRolloverAdapter__PartialOrderRequired();
        }
        ISettler settler = _settlerFor(orderData);
        _assertExpectedSettler(settler, job.settler);
        bytes32 orderDigest =
            LibSettlerHashing.computeOrderDigestMemory(orderData, settler.DOMAIN_SEPARATOR());

        uint256 preBal = job.srcCst.balanceOf(address(this));
        uint256 premiumPreBal = job.premiumToken.balanceOf(address(this));
        _pullJobFundsAndAuthorize(job, settler, orderData, orderDigest, subFiller);

        _runSettlementCommon(job, settler, orderDigest, subFiller);

        _refundTails(
            job.srcCst,
            job.premiumToken,
            preBal,
            premiumPreBal,
            job.subaccount,
            job.recipient,
            orderDigest,
            subFiller
        );
    }

    /// @dev Pull `fillerSrcCst` and `premium` from `job.fundingAccount` via a single
    ///      Permit2 batch transfer whose witness binds every job parameter that
    ///      affects fill economics. Replaces standing ERC-20 allowance funding;
    ///      no fallback path is provided.
    ///
    ///      The Permit2 signer is `job.fundingAccount`, which must equal the
    ///      value resolved via `EVC.getAccountOwner(subaccount)`.
    ///      If the EVC call reverts (no registered owner) or returns the zero
    ///      address, this function reverts with `__SubaccountAuthorityMissing`.
    ///      The signer-bytes path supports both EOA (ECDSA) and contract
    ///      subaccounts (Permit2's `SignatureVerification.verify` falls back to
    ///      EIP-1271 `isValidSignature` when the signer is a contract).
    /// @custom:invariant INV-ADAPTER-JOB-AUTHORIZED
    /// @custom:invariant INV-ADAPTER-NO-STANDING-ALLOWANCE
    function _pullJobFundsAndAuthorize(
        EvcRolloverJob calldata job,
        ISettler settler,
        RolloverTypes.OrderData memory orderData,
        bytes32 orderDigest,
        bytes32 subFiller
    ) internal {
        if (job.fundingSig.length == 0) {
            revert EvcRolloverAdapter__FundingSigInvalid();
        }
        if (job.fundingAccount == address(0)) {
            revert EvcRolloverAdapter__ZeroFundingAccount();
        }
        if (job.recipient == address(0)) {
            revert EvcRolloverAdapter__ZeroRecipient();
        }

        address signer;
        try EVC.getAccountOwner(job.subaccount) returns (address owner) {
            signer = owner;
        } catch {
            revert EvcRolloverAdapter__SubaccountAuthorityMissing();
        }
        if (signer == address(0)) {
            revert EvcRolloverAdapter__SubaccountAuthorityMissing();
        }
        if (signer != job.fundingAccount) {
            revert EvcRolloverAdapter__FundingAccountMismatch(signer, job.fundingAccount);
        }

        bytes32 witness = _computeJobWitness(job, settler, orderData);

        (
            ISignatureTransfer.PermitBatchTransferFrom memory permit,
            ISignatureTransfer.SignatureTransferDetails[] memory details
        ) = _buildPermit2Batch(job);

        PERMIT2.permitWitnessTransferFrom(
            permit, details, job.fundingAccount, witness, WITNESS_TYPESTRING, job.fundingSig
        );

        if (job.fillerSrcCst != 0) {
            emit AdapterFundingPulled(
                orderDigest,
                job.subaccount,
                job.fundingAccount,
                subFiller,
                address(job.srcCst),
                job.fillerSrcCst,
                job.recipient
            );
        }
        if (job.premium != 0) {
            emit AdapterFundingPulled(
                orderDigest,
                job.subaccount,
                job.fundingAccount,
                subFiller,
                address(job.premiumToken),
                job.premium,
                job.recipient
            );
        }
    }

    /// @dev Compute the Permit2 witness binding every job parameter that
    ///      affects fill economics: subaccount, funding account, both token amounts,
    ///      minDstPerSrc, intent hash (zero-digest canonical form), order
    ///      digest (locally computed), nonce, and deadline.
    function _computeJobWitness(
        EvcRolloverJob calldata job,
        ISettler settler,
        RolloverTypes.OrderData memory orderData
    ) internal view returns (bytes32) {
        bytes32 intentHash = LibAuthenticatedHooks.intentStructHash(job.intent);
        bytes32 orderDigest =
            LibSettlerHashing.computeOrderDigestMemory(orderData, settler.DOMAIN_SEPARATOR());
        return _hashJobWitnessFields(job, intentHash, orderDigest);
    }

    /// @dev Source-owned primitive for FV-014. Keeping this split prevents the
    ///      harness from proving an independently reimplemented witness hash.
    function _hashJobWitnessFields(
        EvcRolloverJob calldata job,
        bytes32 intentHash,
        bytes32 orderDigest
    ) internal pure returns (bytes32) {
        return _hashJobWitnessFieldsRaw(
            job.subaccount,
            job.fundingAccount,
            job.recipient,
            address(job.srcCst),
            job.fillerSrcCst,
            address(job.premiumToken),
            job.premium,
            job.minDstPerSrc,
            intentHash,
            orderDigest,
            job.nonce,
            job.deadline
        );
    }

    function _hashJobWitnessFieldsRaw(
        address subaccount,
        address fundingAccount,
        address recipient,
        address srcCst,
        uint256 fillerSrcCst,
        address premiumToken,
        uint256 premium,
        uint256 minDstPerSrc,
        bytes32 intentHash,
        bytes32 orderDigest,
        uint256 nonce,
        uint256 deadline
    ) internal pure returns (bytes32) {
        bytes memory prefix = abi.encode(
            WITNESS_TYPEHASH,
            subaccount,
            fundingAccount,
            recipient,
            srcCst,
            fillerSrcCst,
            premiumToken,
            premium
        );
        bytes memory suffix = abi.encode(minDstPerSrc, intentHash, orderDigest, nonce, deadline);
        return keccak256(bytes.concat(prefix, suffix));
    }

    /// @dev Build the Permit2 `PermitBatchTransferFrom` envelope + transfer
    ///      details for the dual srcCST/premium-token pull.
    function _buildPermit2Batch(EvcRolloverJob calldata job)
        internal
        view
        returns (
            ISignatureTransfer.PermitBatchTransferFrom memory permit,
            ISignatureTransfer.SignatureTransferDetails[] memory details
        )
    {
        (
            address srcToken,
            uint256 srcAmount,
            address premiumToken,
            uint256 premiumAmount,
            address detailTo,
            uint256 permitNonce,
            uint256 permitDeadline
        ) = _permit2BatchShapeFields(
            address(job.srcCst),
            job.fillerSrcCst,
            address(job.premiumToken),
            job.premium,
            job.nonce,
            job.deadline
        );
        ISignatureTransfer.TokenPermissions[] memory permitted =
            new ISignatureTransfer.TokenPermissions[](2);
        permitted[0] = ISignatureTransfer.TokenPermissions({ token: srcToken, amount: srcAmount });
        permitted[1] =
            ISignatureTransfer.TokenPermissions({ token: premiumToken, amount: premiumAmount });
        permit = ISignatureTransfer.PermitBatchTransferFrom({
            permitted: permitted, nonce: permitNonce, deadline: permitDeadline
        });

        details = new ISignatureTransfer.SignatureTransferDetails[](2);
        details[0] = ISignatureTransfer.SignatureTransferDetails({
            to: detailTo, requestedAmount: srcAmount
        });
        details[1] = ISignatureTransfer.SignatureTransferDetails({
            to: detailTo, requestedAmount: premiumAmount
        });
    }

    /// @dev Primitive Permit2 batch shape split out for FV-015. It proves the adapter's
    ///      funding path requests exactly the per-job src/premium amounts to itself.
    function _permit2BatchShapeFields(
        address srcCst,
        uint256 fillerSrcCst,
        address premiumToken,
        uint256 premium,
        uint256 nonce,
        uint256 deadline
    )
        internal
        view
        returns (
            address token0,
            uint256 amount0,
            address token1,
            uint256 amount1,
            address to,
            uint256 permitNonce,
            uint256 permitDeadline
        )
    {
        return (srcCst, fillerSrcCst, premiumToken, premium, address(this), nonce, deadline);
    }

    /// @dev Shared openFor → atomic fill (admit → rollover → premium → settle in one
    ///      frame) body. Computes the canonical orderId locally via
    ///      `LibSettlerHashing.computeOrderDigestMemory` (no `resolve` round-trip) and
    ///      skips `openFor` when the cached order status is already `Opened`. Settlement
    ///      happens inside the atomic `fill` frame; there is no second Settler call.
    /// @custom:invariant INV-OPENED-ORDERS-FILLABLE-UNTIL-FILLDEADLINE — helpers skip
    ///                   `openFor` on already-`Opened` orders and derive `orderId`
    ///                   locally without calling `resolve`, so a helper-driven fill
    ///                   past `openDeadline` succeeds on an Opened order.
    /// @custom:invariant INV-ATOMIC-FILL-CANONICAL — emits a single atomic-envelope
    ///                   `fillerData` (`ATOMIC_TAG`) per fill.
    function _runSettlementCommon(
        EvcRolloverJob calldata job,
        ISettler settler,
        bytes32 orderId,
        bytes32 subFiller
    ) internal {
        if (settler.orderStatus(orderId) != RolloverTypes.OrderStatus.Opened) {
            settler.openFor(job.order, job.userSig, "");
        }

        bytes memory originData = abi.encode(job.order);

        _dispatchAtomicFill(job, settler, orderId, originData, subFiller);

        job.srcCst.forceApprove(address(settler), 0);
        job.premiumToken.forceApprove(address(settler), 0);
    }

    /// @dev Compose the atomic-fill envelope and dispatch a single `settler.fill` call.
    ///      Approves srcCST at `fillerSrcCst` and premiumToken at the job-supplied
    ///      premium ceiling upfront — the Settler recomputes the exact required
    ///      premium from observed dstCST production and pulls only that amount; the
    ///      surplus stays with the adapter and is refunded to `job.recipient` by
    ///      `_refundTails`. The inner premium leg carries only the intent; Settler derives
    ///      `(requiredPremium, msg.sender, subFiller)` from the
    ///      rollover leg and rejects caller-supplied premium routing in the premium blob.
    /// @custom:invariant INV-ATOMIC-FILL-CANONICAL — adapter dispatch uses one
    ///                   `ATOMIC_TAG` envelope per ERC-7683 `fill(...)` call.
    /// @custom:invariant INV-SUBFILLER-PROVENANCE — `subFiller` is derived from the EVC
    ///                   subaccount and never accepted from caller-supplied input.
    function _dispatchAtomicFill(
        EvcRolloverJob calldata job,
        ISettler settler,
        bytes32 orderId,
        bytes memory originData,
        bytes32 subFiller
    ) private {
        job.srcCst.forceApprove(address(settler), job.fillerSrcCst);
        job.premiumToken.forceApprove(address(settler), job.premium);

        bytes memory rolloverData = _buildRolloverInnerBlob(job, subFiller);

        // `job.userSig` is the cPT-holder EIP-712 sig over `orderDigest`; it lives in the
        // envelope's `cptHolderSig` slot so direct-fill admission (None → Opened) can
        // verify it per INV-DIRECT-FILL-CPT-HOLDER-SIG.
        bytes memory atomicFillerData =
            LibFillerPayload.encodeAtomicEnvelope(rolloverData, job.premium, job.userSig);
        settler.fill(orderId, originData, atomicFillerData);
    }

    /// @dev Encodes the 10-tuple ROLLOVER inner-leg `FillerPayload` blob for the atomic
    ///      envelope. The nested `cptHolderSig` slot is left empty — the envelope-level
    ///      `cptHolderSig` carries the cPT-holder attestation under atomic-fill.
    function _buildRolloverInnerBlob(EvcRolloverJob calldata job, bytes32 subFiller)
        private
        pure
        returns (bytes memory)
    {
        return LibFillerPayload.encodeRolloverLeg(
            job.fillerSrcCst,
            job.recipient,
            job.intent,
            job.minDstPerSrc,
            job.fillerAuthSig,
            subFiller,
            ""
        );
    }

    /// @dev Revert unless the supplied Settler equals the immutable `SETTLER`.
    function _settlerFor(RolloverTypes.OrderData memory orderData)
        internal
        view
        returns (ISettler)
    {
        return orderData.allowPartialFills ? PARTIAL_SETTLER : EXACT_SETTLER;
    }

    function _assertExpectedSettler(ISettler expected, ISettler actual) internal pure {
        if (address(actual) == address(0)) {
            revert EvcRolloverAdapter__UnknownSettler();
        }
        if (address(actual) != address(expected)) {
            revert EvcRolloverAdapter__SettlerMismatch(address(expected), address(actual));
        }
    }

    /// @dev Return any srcCST / premium-token surplus to the EVC subaccount.
    function _refundTails(
        IERC20 srcCst,
        IERC20 premiumToken,
        uint256 preBal,
        uint256 premiumPreBal,
        address subaccount,
        address to,
        bytes32 orderDigest,
        bytes32 subFiller
    ) internal {
        uint256 postBal = srcCst.balanceOf(address(this));
        if (postBal > preBal) {
            uint256 refund = postBal - preBal;
            srcCst.safeTransfer(to, refund);
            emit AdapterTailRefunded(
                orderDigest, subaccount, to, subFiller, address(srcCst), refund
            );
        }
        uint256 postPremiumBal = premiumToken.balanceOf(address(this));
        if (postPremiumBal > premiumPreBal) {
            uint256 refund = postPremiumBal - premiumPreBal;
            premiumToken.safeTransfer(to, refund);
            emit AdapterTailRefunded(
                orderDigest, subaccount, to, subFiller, address(premiumToken), refund
            );
        }
    }

    /// @dev Verify the EVC context: the call must originate from the EVC contract,
    ///      reporting a controller-enabled on-behalf-of frame for `subaccount`.
    ///      Owner/operator authorization is performed by the EVC itself BEFORE
    ///      dispatch — see Euler EVC `EthereumVaultConnector.callWithContextInternal`
    ///      which validates `authenticationData` and then forwards calldata to the
    ///      target unchanged. The adapter therefore does not (and cannot) re-derive
    ///      the authenticated principal from calldata, because real EVC does not
    ///      append it.
    /// @custom:invariant INV-EVC-CALLER-AUTHORIZED
    function _gateEvc(address subaccount) internal view {
        (address onBehalf, bool enabled) = EVC.getCurrentOnBehalfOfAccount(CONTROLLER);
        if (onBehalf == address(0)) {
            revert EvcRolloverAdapter__NotEvcContext();
        }
        if (!enabled) {
            revert EvcRolloverAdapter__ControllerNotEnabled();
        }
        if (onBehalf != subaccount) {
            revert EvcRolloverAdapter__OnBehalfMismatch(onBehalf, subaccount);
        }

        // Dispatch must originate from the EVC: rejects direct-EOA calls that
        // happen to sit inside another subaccount's open EVC frame.
        if (msg.sender != address(EVC)) {
            revert EvcRolloverAdapter__CallerNotEvc();
        }
    }
}
