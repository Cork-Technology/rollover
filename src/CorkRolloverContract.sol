// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    ReentrancyGuardTransient
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { SignatureChecker } from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {
    CorkRolloverContract__AllowPartialFillsMismatch,
    CorkRolloverContract__AllowUnderfillMismatch,
    CorkRolloverContract__BadIntentSignature,
    CorkRolloverContract__CaInsufficientForDeposit,
    CorkRolloverContract__DeadlineExpired,
    CorkRolloverContract__DelegatecallFailed,
    CorkRolloverContract__DepositOverMint,
    CorkRolloverContract__DstCptNotRestored,
    CorkRolloverContract__DstPoolIdMismatch,
    CorkRolloverContract__EmptyDefaultAttesters,
    CorkRolloverContract__FillDeadlineMismatch,
    CorkRolloverContract__HookTargetNoCode,
    CorkRolloverContract__IntentDeadlineBeforeFillDeadline,
    CorkRolloverContract__IntentDeadlineExpired,
    CorkRolloverContract__IntentHashMismatch,
    CorkRolloverContract__InvalidThreshold,
    CorkRolloverContract__InvalidTrustAttesterOrder,
    CorkRolloverContract__MayNotAllowFailure,
    CorkRolloverContract__MayNotHaveValue,
    CorkRolloverContract__MidPhaseDstCstDrain,
    CorkRolloverContract__ModuleTypeMismatch,
    CorkRolloverContract__MustBeDelegateCall,
    CorkRolloverContract__NotFactory,
    CorkRolloverContract__NotOwner,
    CorkRolloverContract__OrderDataDigestMismatch,
    CorkRolloverContract__OrderDigestMismatch,
    CorkRolloverContract__OrderSizeMismatch,
    CorkRolloverContract__OverfillCeiling,
    CorkRolloverContract__PartialResidualNotQuantumAligned,
    CorkRolloverContract__PhaseAlreadyConsumed,
    CorkRolloverContract__PoolManagerCallFailed,
    CorkRolloverContract__PremiumAlreadyFiredForFiller,
    CorkRolloverContract__PremiumBeforeRollover,
    CorkRolloverContract__PremiumHookSweptExcess,
    CorkRolloverContract__PremiumTokenMismatch,
    CorkRolloverContract__RegistryZero,
    CorkRolloverContract__RolloverContractMismatch,
    CorkRolloverContract__RolloverIntentHashCtxMismatch,
    CorkRolloverContract__RolloverZeroDeposit,
    CorkRolloverContract__RolloverZeroUnwindMint,
    CorkRolloverContract__SettlerMismatch,
    CorkRolloverContract__ShareAmountNotQuantumAligned,
    CorkRolloverContract__SignedSettlerOriginMismatch,
    CorkRolloverContract__SrcCptNotRestored,
    CorkRolloverContract__SrcCptShortfall,
    CorkRolloverContract__SrcCstNotReturned,
    CorkRolloverContract__SrcPoolIdMismatch,
    CorkRolloverContract__TooManyAttesters,
    CorkRolloverContract__TrustConfigMutatedDuringHook,
    CorkRolloverContract__UnderfillNotAllowed,
    CorkRolloverContract__UnwindDepositShortfall,
    CorkRolloverContract__UnwindMintShortfall,
    CorkRolloverContract__ZeroFiller,
    CorkRolloverContract__ZeroRollover
} from "src/errors/CorkRolloverContractErrors.sol";
import { IERC7484, ModuleType } from "src/interfaces/external/erc7484/IERC7484.sol";
import { IPoolManager, MarketId } from "src/interfaces/external/phoenix/IPoolManager.sol";
import { IPoolShare } from "src/interfaces/external/phoenix/IPoolShare.sol";
import { ICorkRolloverContract } from "src/interfaces/rollover/ICorkRolloverContract.sol";
import { IRolloverHookDispatcher } from "src/interfaces/rollover/IRolloverHookDispatcher.sol";
import { ISettler } from "src/interfaces/settlers/ISettler.sol";
import { LibAuthenticatedHooks } from "src/libraries/LibAuthenticatedHooks.sol";
import { LibLastDeliveredPremium } from "src/libraries/LibLastDeliveredPremium.sol";
import { LibPhoenixShareQuantum } from "src/libraries/LibPhoenixShareQuantum.sol";
import { LibPostRolloverDstCptMinted } from "src/libraries/LibPostRolloverDstCptMinted.sol";
import { LibSettlerHashing } from "src/libraries/LibSettlerHashing.sol";
import { Typehashes } from "src/libraries/Typehashes.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @title CorkRolloverContract
/// @notice cPT-holder-owned rolloverContract (CWIA clone) that holds rollover capacity, executes
///         cPT-holder-signed hook intents, and brackets every rollover leg with attester-gated
///         module checks plus balance no-drain guards. The rolloverContract consumes srcCST from the
///         filler-funded Settler, drives `unwindMint → midHooks → deposit`, transfers
///         `dstProduced` to `params.settler`, and refunds any srcCST leftover when underfill is
///         permitted.
/// @custom:invariant INV-CPT-CONTAINED — srcCPT and dstCPT are cPT holder property; rolloverContract
///                   holds CPT only inside the transient rollover window and enforces
///                   end-of-leg equality `srcCptAfter == srcCptBefore` AND
///                   `dstCptAfter == dstCptBefore` via `CorkRolloverContract__SrcCptNotRestored` /
///                   `CorkRolloverContract__DstCptNotRestored`. Post-rollover hooks can read
///                   the dynamic `dstCptAfterDeposit - dstCptBeforeDeposit` register to route newly
///                   minted dstCPT without sweeping standing dstCPT. The final bidirectional
///                   guard catches both residual leftover above entry snapshot AND silent sweep
///                   of pre-existing CPT below entry snapshot.
/// @custom:invariant INV-DST-FLOOR — `params.minSharesOut` is the load-bearing safety against
///                   mid-hook value-skim. The mid-hook MAY decrease caSrc (cross-CA rollover);
///                   end-to-end value is guaranteed only by the deposit-side floor in
///                   `_handlePhaseRollover` (`CorkRolloverContract__UnwindDepositShortfall`). cPT holder signs
///                   this floor per intent.
/// @custom:invariant INV-5 — across the rollover leg, the rolloverContract's dstCST balance ends at or
///                   above the entry snapshot (`CorkRolloverContract__MidPhaseDstCstDrain`).
/// @custom:invariant INV-DST-CST-MINT-RATIO-BOUNDED — `_depositLeg` caps the observed dstCST
///                   mint at the live canonical quote from
///                   `IPoolManager.previewDeposit(dstPoolId, caForDeposit)`. Defense-in-depth
///                   against a buggy or upgraded PoolManager that over-mints dstCST relative
///                   to `caForDeposit`; under-mint is allowed (future Phoenix protocol-fee
///                   models).
/// @custom:invariant INV-SRC-CST-RETURNED — across the rollover leg, the rolloverContract's srcCST
///                   balance ends exactly at `s.srcCstBefore - fillContext.fillAmount`
///                   (`CorkRolloverContract__SrcCstNotReturned`). `s.srcCstBefore` is sampled AFTER the
///                   Settler has transferred `fillAmount` srcCST into the rolloverContract; the
///                   legitimate path drains exactly `fillAmount` (Phoenix `unwindMint` burns
///                   `effectivelyBurned`; `srcLeftover = fillAmount - effectivelyBurned`
///                   forwarded back to the Settler). Defense-in-depth symmetric with INV-5;
///                   catches any src-side drift the Phoenix-truncation reconciliation in
///                   `_unwindLeg` might miss (Phoenix semantic change, donation absorbed
///                   mid-leg, hook mutating rolloverContract srcCST balance).
/// @custom:invariant DSR-1 — both legs derive their outbound amount from `balanceOf` deltas;
///                   pool's `unwindMint`/`deposit` returning zero is rejected.
/// @custom:invariant DSR-2 — `_depositLeg` does not re-sample `caDst.balanceOf` between the
///                   approve and the `deposit` call; `caForDeposit` is sampled once.
/// @custom:invariant DSR-2c — `caForDeposit = caDstAfterMid - caDstBefore` uses the
///                   pre-pre-hook `caDstBefore` snapshot from `_populateScratch`. cPT-holder-signed
///                   pre-rollover hooks that credit caDst to the rollover intentionally widen
///                   the deposit bracket and are minted into the deposit; the inflated
///                   dstCST routes to the settler. This is cPT holder discretion per
///                   accepted-03: caDst is not balance-bracketed. Asymmetric with DSR-2b:
///                   caDst's wider bracket is by-design cPT holder behaviour; dstCST's tight
///                   bracket is the INV-5 floor closure.
/// @custom:invariant INV-TRUST-CONFIG-DELAY — trust-config changes are time-locked by the
///                   configured trust-config timelock delay;
///                   the queue is owned by the factory's `TimelockController` and the
///                   rolloverContract's `setTrustConfig` accepts writes only from the factory.
/// @custom:invariant INV-ROLLOVER_CONTRACT-TRUST-ONLY-VIA-FACTORY — every function writing `liveTrust*`
///                   storage gates on `msg.sender == _factory()`.
/// @custom:invariant INV-PARAMS-SETTLER-PIN — signed
///                   `orderData.rolloverParams.settler == fillContext.originSettler ==
///                   factory-latched-msg.sender`; the pin is defence in depth against a
///                   compromised approved Settler.
/// @custom:invariant INV-ROLLOVER_CONTRACT-CPT-HOLDER-SIG-EVERY-DISPATCH — every hook dispatch verifies the
///                   cPT-holder signature over the cPT-holder-signed `OrderData` digest.
/// @custom:invariant INV-ROLLOVER_CONTRACT-OWNER-IMMUTABLE — owner is fixed via the CWIA trailer; no
///                   transfer/setter; `erc7484Registry` is CWIA-immutable (trailer bytes
///                   40-60); no setter; no storage slot.
/// @custom:invariant INV-DEFAULT-ATTESTERS-FACTORY-SEEDED — initialize forwards the factory's
///                   default attester set to the ERC-7484 registry.
/// @custom:invariant N-INV-ROLLED-MONOTONE-AND-BOUNDED — `rolled[orderDigest]` tracks srcCST
///                   actually burned by Phoenix (post-truncation), not the calldata-supplied
///                   request. `_unwindLeg` mirrors Phoenix's truncation
///                   (`effectivelyBurned = srcSharesToBurn - (srcSharesToBurn % minimumShares)`,
///                   `minimumShares = 10**(18 - CAdecimals)`) before recording the credit;
///                   the truncation residue is forwarded to the Settler as srcLeftover and
///                   refunded to the filler. `rolled` is strictly non-decreasing, never
///                   exceeds `fillContext.orderSize`, and the terminal bit is set-only.
/// @custom:security-contact security@cork.tech
contract CorkRolloverContract is ICorkRolloverContract, Initializable, ReentrancyGuardTransient {
    /// @notice Maximum number of trust attesters in any rolloverContract trust config.
    uint256 public constant MAX_TRUST_ATTESTERS = 16;
    using SafeERC20 for IERC20;

    /// @notice ERC-7201 namespaced storage slot for `RolloverContractStorage`.
    bytes32 private constant ROLLOVER_CONTRACT_STORAGE_SLOT =
        0xb4cefcf1cd721ac7aa7779687f98e0bf77365d8cc544d423bc3152971ed5cc00;

    /// @notice Bit position in `hookNonces[orderDigest]` flagging rollover-phase termination.
    uint256 private constant PHASE_0_TERMINAL_BIT = 1 << 0;

    /// @notice Maximum number of bytes of revert returndata copied from a failed hook
    ///         delegatecall into the rolloverContract's outer revert payload. Bounds the gas an
    ///         attested-but-malicious hook can burn by reverting with a giant blob.
    /// @dev See INV-HOOK-RETURNDATA-DISCARDED. Picked at 256 B to fit any reasonable
    ///      Solidity custom-error payload (selector + ABI-encoded args) with headroom.
    uint256 internal constant REVERT_REASON_CAP = 256;

    /// @notice Namespaced rolloverContract storage layout.
    /// @dev `erc7484Registry` is CWIA-immutable (trailer bytes 40-60); read via `_registry()`.
    ///      Trust-config queuing lives on the factory's `TimelockController`; the rolloverContract stores
    ///      only live trust state.
    /// @param hookNonces Per-order bitfield: bit 0 = rollover terminal latch.
    /// @param rolled Per-order srcCST cumulative rollover total (N-INV-ROLLED-MONOTONE-AND-BOUNDED).
    /// @param premiumFiredFor RolloverContract-local per-`(orderDigest, filler, subFiller)` latch. Set
    ///        during a successful `_handlePhasePremium`. Local rolloverContract replay protection only
    ///        — NOT the protocol-wide M-11 gate, which lives Settler-side as
    ///        `rec.premiumFired` / `exactRec.premiumFired`. Under atomic-fill both latches
    ///        commit or roll back in the same transaction frame.
    /// @param liveTrustThreshold Currently effective trust threshold.
    /// @param liveTrustAttesters Currently effective attester list.
    struct RolloverContractStorage {
        // --- Per-order rollover accounting ---
        mapping(bytes32 => uint256) hookNonces;
        mapping(bytes32 => uint256) rolled;
        // --- Per-order replay protection ---
        mapping(bytes32 => mapping(address => mapping(bytes32 => bool))) premiumFiredFor;
        // --- Live trust configuration (set via factory-relayed timelock) ---
        uint8 liveTrustThreshold;
        address[] liveTrustAttesters;
    }

    /// @dev Memory-only scratch used to thread Phoenix pointers and entry snapshots through the
    ///      rollover-leg helper chain.
    struct _RolloverScratch {
        uint256 srcCstBefore;
        uint256 srcCptBefore;
        uint256 dstCstBefore;
        uint256 dstCptBefore;
        uint256 caDstBefore;
        uint256 caDstAfterMid;
        uint256 srcSharesToBurn;
        address srcPoolManager;
        address dstPoolManager;
        address caSrc;
        address caDst;
        address srcCpt;
        address dstCpt;
    }

    /// @notice Restricts a function to the CWIA-baked owner.
    modifier onlyOwner() {
        if (msg.sender != _owner()) {
            revert CorkRolloverContract__NotOwner();
        }
        _;
    }

    /// @notice Restricts a function to the CWIA-baked factory.
    modifier onlyFactory() {
        if (msg.sender != _factory()) {
            revert CorkRolloverContract__NotFactory();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Lock the implementation against initialization; clones initialize through
    ///         `initialize` against the CWIA proxy address.
    constructor() {
        _disableInitializers();
    }

    /*//////////////////////////////////////////////////////////////
                   EXTERNAL / PUBLIC STATE-CHANGING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ICorkRolloverContract
    /// @custom:invariant INV-DEFAULT-ATTESTERS-FACTORY-SEEDED — initialize forwards the factory
    ///                   defaults to the ERC-7484 registry and mirrors them in rolloverContract storage.
    function initialize(uint8 initialTrustThreshold, address[] calldata initialTrustAttesters)
        external
        nonReentrant
        onlyFactory
        initializer
    {
        address registry = _registry();
        if (registry == address(0)) {
            revert CorkRolloverContract__RegistryZero();
        }
        if (initialTrustAttesters.length == 0) {
            revert CorkRolloverContract__EmptyDefaultAttesters();
        }
        _validateTrustConfig(initialTrustThreshold, initialTrustAttesters);

        RolloverContractStorage storage $ = _s();
        $.liveTrustThreshold = initialTrustThreshold;
        $.liveTrustAttesters = initialTrustAttesters;

        IERC7484(registry).trustAttesters(initialTrustThreshold, initialTrustAttesters);

        emit RolloverContractInitialized(registry, initialTrustThreshold, initialTrustAttesters);
    }

    /// @inheritdoc ICorkRolloverContract
    /// @custom:invariant INV-FILL-CONTEXT-MATCHES-ORDER — every `fillContext.*` field that semantically
    ///                   duplicates an `orderData.*` field is cross-checked at the rolloverContract
    ///                   boundary; a compromised approved Settler cannot fabricate them.
    /// @custom:invariant INV-ORDER-DIGEST-RE-DERIVED-ROLLOVER_CONTRACT-SIDE — the rolloverContract re-derives
    ///                   `orderDigest` from `orderData` via EIP-712 and rejects any mismatch.
    function executeIntentHooks(
        bytes32 orderDigest,
        RolloverTypes.HookPhase phase,
        RolloverTypes.RolloverIntent calldata intent,
        bytes calldata cptHolderSig,
        RolloverTypes.FillContext calldata fillContext,
        RolloverTypes.OrderData calldata orderData
    ) external nonReentrant onlyFactory returns (uint256 dstProduced, uint256 srcLeftover) {
        _validateFillEnvelope(intent, fillContext);
        _validateOrderDataBinding(orderDigest, intent, fillContext, orderData, phase);
        _validateIntentHashBinding(intent, orderDigest, fillContext.rolloverIntentHash);

        RolloverContractStorage storage $ = _s();
        _ensureOwnerAuthorized(orderDigest, cptHolderSig);

        // `actualRolled` is emitted for telemetry. The Settler derives consumed source from
        // `fillAmount - srcLeftover`, so the return tuple carries only dst/output accounting.
        uint256 actualRolled;
        if (phase == RolloverTypes.HookPhase.PREMIUM) {
            _handlePhasePremium($, orderDigest, fillContext, intent.premiumHooks);
        } else {
            // The factory admits only ROLLOVER and PREMIUM before dispatch; non-premium is ROLLOVER.
            (actualRolled, dstProduced, srcLeftover) =
                _handlePhaseRollover($, orderDigest, fillContext, orderData.rolloverParams, intent);
        }

        _emitIntentPhaseFired($, orderDigest, phase, fillContext, actualRolled, dstProduced);
    }

    /// @inheritdoc ICorkRolloverContract
    function withdraw(address withdrawToken, uint256 withdrawAmount)
        external
        nonReentrant
        onlyOwner
    {
        IERC20(withdrawToken).safeTransfer(msg.sender, withdrawAmount);
        emit OwnerWithdrawn(withdrawToken, withdrawAmount);
    }

    /// @inheritdoc ICorkRolloverContract
    /// @dev Direct setter — the factory is the SOLE authorized caller. The trust-config
    ///      timelock window lives on the factory-bound external timelock; the rolloverContract enforces the
    ///      "trust changes go through factory" invariant by gating on `_factory()`.
    ///
    ///      Trust-config timing policy (P-09): an apply MAY land at any block (the external
    ///      trust-config timelock is permissionless after the delay), including between two phases of an
    ///      already-cached order. The rolloverContract reads trust state live for every hook phase
    ///      (pre/mid/post rollover and premium) via `_prevalidateIntentCalls` + the underlying
    ///      registry's `IERC7484.check`, so an apply that lands between phases of an
    ///      already-started order applies to later phases. If an apply lands between ROLLOVER
    ///      and PREMIUM and de-attests a premium-hook module, premium-phase prevalidation
    ///      reverts; that revert propagates through the atomic-fill frame and rolls back
    ///      admit / rollover / premium state (`INV-PREMIUM-HOOK-REVERT-CASCADES`). No premium
    ///      is parked. Filler liveness for in-flight orders depends on retrying with valid
    ///      trust config, on `Settler.pause()`, or on other protocol/admin controls as applicable.
    ///      The intra-hook trust-mutation guard is still active for every hook phase. cPT holder
    ///      emergency response for in-flight orders is `Settler.pause()` (blunt instrument).
    ///      Fillers and integrators MUST treat
    ///      `ICorkRolloverContractFactory.pendingTrustConfig(rolloverContract)` as a live operational signal and
    ///      avoid scheduling rollover fills whose hooks depend on an attester being removed
    ///      mid-order. The configured trust-config timelock delay is the stability window for
    ///      off-chain simulation;
    ///      on-chain races after the apply for hook phases are intentional and aligned with
    ///      `INV-TRUST-CONFIG-DELAY`.
    /// @custom:invariant INV-ROLLOVER_CONTRACT-TRUST-ONLY-VIA-FACTORY
    function setTrustConfig(uint8 liveTrustThreshold, address[] calldata liveTrustAttesters)
        external
        nonReentrant
        onlyFactory
    {
        _validateTrustConfig(liveTrustThreshold, liveTrustAttesters);

        RolloverContractStorage storage $ = _s();
        $.liveTrustThreshold = liveTrustThreshold;
        $.liveTrustAttesters = liveTrustAttesters;

        IERC7484(_registry()).trustAttesters(liveTrustThreshold, liveTrustAttesters);
        emit TrustConfigSet(liveTrustThreshold, liveTrustAttesters);
    }

    /*//////////////////////////////////////////////////////////////
                       EXTERNAL / PUBLIC VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Return the rolloverContract implementation version.
    /// @dev Static code version for off-chain compatibility checks. Order signatures use the
    ///      Settler EIP-712 domain over `OrderData`; changing this implementation version does not
    ///      invalidate signed orders or their committed `rolloverIntentHash`.
    /// @return implementationVersion RolloverContract implementation semantic version.
    function version() external pure returns (string memory implementationVersion) {
        implementationVersion = "1.0.0";
    }

    /// @notice Return the factory baked into this rolloverContract clone.
    /// @dev Read from CWIA immutable args, not storage. Identifies the factory that deployed and
    ///      initialized this clone.
    /// @return rolloverContractFactory Factory address baked into the clone.
    function factory() external view returns (address rolloverContractFactory) {
        rolloverContractFactory = _factory();
    }

    /// @notice Return the owner baked into this rolloverContract clone.
    /// @dev Read from CWIA immutable args, not storage. Used by the factory to authorize
    ///      owner-managed trust-config changes and by the Settler to enforce
    ///      `INV-USER-IS-ROLLOVER_CONTRACT-OWNER`.
    /// @return rolloverContractOwner cPT holder baked into the clone.
    function owner() external view returns (address rolloverContractOwner) {
        rolloverContractOwner = _owner();
    }

    /// @inheritdoc ICorkRolloverContract
    function rolloverContractSnapshot()
        external
        view
        returns (ICorkRolloverContract.RolloverContractTrustSnapshot memory trustSnapshot)
    {
        RolloverContractStorage storage $ = _s();
        trustSnapshot.erc7484Registry = _registry();
        trustSnapshot.liveTrustThreshold = $.liveTrustThreshold;
        trustSnapshot.liveTrustAttesters = $.liveTrustAttesters;
    }

    /// @inheritdoc ICorkRolloverContract
    function orderState(bytes32 orderDigest)
        external
        view
        returns (ICorkRolloverContract.RolloverContractOrderState memory state)
    {
        RolloverContractStorage storage $ = _s();
        state.rolled = $.rolled[orderDigest];
        state.rolloverTerminal = _isRolloverTerminal($, orderDigest);
    }

    /// @inheritdoc ICorkRolloverContract
    function premiumFiredFor(bytes32 orderDigest, address filler, bytes32 subFiller)
        external
        view
        returns (bool fired)
    {
        return _s().premiumFiredFor[orderDigest][filler][subFiller];
    }

    /*//////////////////////////////////////////////////////////////
                      INTERNAL / PRIVATE STATE-CHANGING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Emit the per-phase diagnostic event with the final cumulative state.
    function _emitIntentPhaseFired(
        RolloverContractStorage storage $,
        bytes32 orderDigest,
        RolloverTypes.HookPhase phase,
        RolloverTypes.FillContext calldata fillContext,
        uint256 actualRolled,
        uint256 dstProduced
    ) internal {
        uint256 cumulativeRolled = $.rolled[orderDigest];
        bool rolloverTerminal = _isRolloverTerminal($, orderDigest);
        uint8 phaseU8 = uint8(phase);
        uint256 premium = phase == RolloverTypes.HookPhase.PREMIUM ? fillContext.premium : 0;
        emit IntentPhaseFired(
            orderDigest,
            phaseU8,
            fillContext.filler,
            fillContext.fillAmount,
            actualRolled,
            cumulativeRolled,
            rolloverTerminal,
            dstProduced,
            premium
        );
        emit IntentPhaseFiredWithSubFiller(
            orderDigest,
            fillContext.filler,
            fillContext.subFiller,
            phaseU8,
            fillContext.fillAmount,
            actualRolled,
            cumulativeRolled,
            rolloverTerminal,
            dstProduced,
            premium
        );
    }

    /// @dev OrderData ↔ fillContext cross-binding: re-derive the EIP-712 order digest from `orderData`
    ///      using the Settler's domain separator (the Settler is already pinned by
    ///      `_validateFillEnvelope` via the factory latch) and assert it equals the dispatched
    ///      `orderDigest`. Then cross-check every `fillContext.*` field that semantically duplicates
    ///      an `orderData.*` field. Defends the rolloverContract against a compromised approved Settler
    ///      that fabricates `fillContext.*` numerics or swaps `fillContext.premiumToken`.
    /// @custom:invariant INV-FILL-CONTEXT-MATCHES-ORDER — listed `fillContext.*` fields equal `orderData.*`.
    /// @custom:invariant INV-ORDER-DIGEST-RE-DERIVED-ROLLOVER_CONTRACT-SIDE — digest re-derived locally.
    function _validateOrderDataBinding(
        bytes32 orderDigest,
        RolloverTypes.RolloverIntent calldata intent,
        RolloverTypes.FillContext calldata fillContext,
        RolloverTypes.OrderData calldata orderData,
        RolloverTypes.HookPhase phase
    ) internal view {
        bytes32 domainSeparator = ISettler(fillContext.originSettler).DOMAIN_SEPARATOR();
        bytes32 derived = LibSettlerHashing.computeOrderDigest(orderData, domainSeparator);
        if (derived != orderDigest) {
            revert CorkRolloverContract__OrderDataDigestMismatch(derived, orderDigest);
        }
        if (fillContext.orderSize != orderData.orderSize) {
            revert CorkRolloverContract__OrderSizeMismatch(
                fillContext.orderSize, orderData.orderSize
            );
        }
        if (fillContext.fillDeadline != orderData.fillDeadline) {
            revert CorkRolloverContract__FillDeadlineMismatch(
                fillContext.fillDeadline, orderData.fillDeadline
            );
        }
        if (
            orderData.premiumPaymentMode == RolloverTypes.PREMIUM_PAYMENT_MODE_ATOMIC_OR_SEPARATE
                && intent.deadline < orderData.fillDeadline
        ) {
            revert CorkRolloverContract__IntentDeadlineBeforeFillDeadline(
                intent.deadline, orderData.fillDeadline
            );
        }
        if (fillContext.allowPartialFills != orderData.allowPartialFills) {
            revert CorkRolloverContract__AllowPartialFillsMismatch(
                fillContext.allowPartialFills, orderData.allowPartialFills
            );
        }
        if (fillContext.allowUnderfill != orderData.allowUnderfill) {
            revert CorkRolloverContract__AllowUnderfillMismatch(
                fillContext.allowUnderfill, orderData.allowUnderfill
            );
        }
        if (fillContext.rolloverIntentHash != orderData.rolloverIntentHash) {
            revert CorkRolloverContract__RolloverIntentHashCtxMismatch();
        }
        if (orderData.rolloverParams.settler != fillContext.originSettler) {
            revert CorkRolloverContract__SignedSettlerOriginMismatch(
                orderData.rolloverParams.settler, fillContext.originSettler
            );
        }
        // PREMIUM phase only — ROLLOVER phase populates fillContext.premiumToken with address(0).
        if (
            phase == RolloverTypes.HookPhase.PREMIUM
                && fillContext.premiumToken != orderData.premiumToken
        ) {
            revert CorkRolloverContract__PremiumTokenMismatch(
                fillContext.premiumToken, orderData.premiumToken
            );
        }
    }

    /// @dev Envelope-level validation: rolloverContract binding, settler latch, deadlines, and filler.
    ///      Phase range is rejected by the factory dispatcher before the rolloverContract call.
    function _validateFillEnvelope(
        RolloverTypes.RolloverIntent calldata intent,
        RolloverTypes.FillContext calldata fillContext
    ) internal view {
        if (intent.rolloverContract != address(this)) {
            revert CorkRolloverContract__RolloverContractMismatch();
        }
        if (IRolloverHookDispatcher(_factory()).originatingSettler() != fillContext.originSettler) {
            revert CorkRolloverContract__SettlerMismatch();
        }
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > fillContext.fillDeadline) {
            revert CorkRolloverContract__DeadlineExpired();
        }
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > intent.deadline) {
            revert CorkRolloverContract__IntentDeadlineExpired();
        }
        if (fillContext.filler == address(0)) {
            revert CorkRolloverContract__ZeroFiller();
        }
    }

    /// @dev Verify that the calldata intent corresponds to the dispatched `orderDigest` and
    ///      hashes to `rolloverIntentHash` with the order-digest field zeroed.
    function _validateIntentHashBinding(
        RolloverTypes.RolloverIntent calldata intent,
        bytes32 orderDigest,
        bytes32 rolloverIntentHash
    ) internal pure {
        if (intent.orderDigest != orderDigest) {
            revert CorkRolloverContract__OrderDigestMismatch();
        }

        RolloverTypes.RolloverIntent memory copy = RolloverTypes.RolloverIntent({
            rolloverContract: intent.rolloverContract,
            orderDigest: bytes32(0),
            deadline: intent.deadline,
            nonce: intent.nonce,
            preRolloverHooks: intent.preRolloverHooks,
            midRolloverHooks: intent.midRolloverHooks,
            postRolloverHooks: intent.postRolloverHooks,
            premiumHooks: intent.premiumHooks
        });
        if (LibAuthenticatedHooks.intentStructHash(copy) != rolloverIntentHash) {
            revert CorkRolloverContract__IntentHashMismatch();
        }
    }

    /// @dev Owner-authorisation gate. Every hook dispatch verifies the cPT-holder EIP-712 /
    ///      ERC-1271 signature over `orderDigest`.
    function _ensureOwnerAuthorized(bytes32 orderDigest, bytes calldata cptHolderSig)
        internal
        view
    {
        if (!SignatureChecker.isValidSignatureNow(_owner(), orderDigest, cptHolderSig)) {
            revert CorkRolloverContract__BadIntentSignature();
        }
    }

    /// @dev PREMIUM phase handler — premium is already on this rolloverContract (the Settler frame's
    ///      direct `safeTransferFrom(filler, rolloverContract, premium)` deposits it pre-call); this
    ///      handler runs premium hooks and flips the persistent replay latch. The standing
    ///      balance snapshot bounds the hook frame: any net reduction in the rolloverContract's
    ///      balance of `fillContext.premiumToken` below the value observed at PREMIUM entry
    ///      reverts (INV-PREMIUM-HOOKS-CANNOT-SWEEP-STANDING-BALANCE). The per-token transient
    ///      slot exposed by `LibLastDeliveredPremium` is written after the Settler-side
    ///      delivery check has completed and cleared after the post-hook trip-wire so
    ///      delegatecalled scoped modules (`ScopedSplitModule`,
    ///      `ScopedTransferModule`) can read the just-delivered amount via
    ///      `LibLastDeliveredPremium.read` only while premium hooks execute. EIP-1153 tx-end
    ///      clearing remains as a fallback boundary.
    /// @custom:invariant M-11 — premium fires at most once per `(orderDigest, filler, subFiller)`.
    /// @custom:invariant INV-PREMIUM-HOOKS-CANNOT-SWEEP-STANDING-BALANCE — premium-hook
    ///                   execution may not reduce the rolloverContract's balance of `fillContext.premiumToken`
    ///                   below the value observed at PREMIUM entry.
    /// @custom:invariant INV-PREMIUM-REQUIRES-ROLLOVER — PREMIUM phase reverts if no
    ///                   ROLLOVER has fired for `orderDigest` (`$.rolled[orderDigest] == 0`).
    ///                   Order-wide floor, not per-filler. Per-filler ordering remains the
    ///                   Settler's responsibility (`rec.dstCstProduced != 0`).
    function _handlePhasePremium(
        RolloverContractStorage storage $,
        bytes32 orderDigest,
        RolloverTypes.FillContext calldata fillContext,
        RolloverTypes.Call[] calldata premiumHooks
    ) internal {
        _markPremiumFiredForFiller($, orderDigest, fillContext.filler, fillContext.subFiller);
        // `fillContext.premiumToken == address(0)` is rejected at Settler admission via
        // `BaseSettler._validateOrderCommon` (INV-PREMIUM-TOKEN-NONZERO); no per-rolloverContract
        // re-check is needed here.
        // Premium has already been delivered to this rolloverContract by the Settler frame's direct
        // `safeTransferFrom(filler, rolloverContract, premium)` (INV-PREMIUM-PAID-RELEASES-DST). The
        // Settler-side delivery check (`delivered == payload.premium` on the rolloverContract's balance
        // delta) is authoritative; no rolloverContract-side re-pull is required.
        //
        address premiumToken = fillContext.premiumToken;
        uint256 premium = fillContext.premium;

        // INV-PREMIUM-HOOKS-CANNOT-SWEEP-STANDING-BALANCE — snapshots the rolloverContract's
        // standing balance: live balance minus the just-delivered premium. Premium hooks
        // may spend up to `premium` of `premiumToken` (split, transfer-to-recipient,
        // vault-deposit), but they MUST NOT net-reduce the balance below this snapshot.
        uint256 standingBalanceBeforeHooks = IERC20(premiumToken).balanceOf(address(this)) - premium;

        LibLastDeliveredPremium.write(premiumToken, premium);

        _executeIntentCalls(premiumHooks, Typehashes.MODULE_TYPE_EXECUTOR);

        uint256 balanceAfterHooks = IERC20(premiumToken).balanceOf(address(this));
        if (balanceAfterHooks < standingBalanceBeforeHooks) {
            revert CorkRolloverContract__PremiumHookSweptExcess(
                standingBalanceBeforeHooks - balanceAfterHooks, premium
            );
        }

        LibLastDeliveredPremium.write(premiumToken, 0);

        emit PremiumFired(orderDigest, fillContext.filler, fillContext.subFiller, premium);
        emit HookPhaseExecuted(orderDigest, RolloverTypes.HookPhase.PREMIUM);
    }

    /// @dev Mark the rolloverContract-local premium latch after enforcing the production ordering and
    ///      replay guards.
    function _markPremiumFiredForFiller(
        RolloverContractStorage storage $,
        bytes32 orderDigest,
        address filler,
        bytes32 subFiller
    ) internal {
        // Placed BEFORE the latch-mutation gate so the structural ordering error surfaces
        // ahead of `PremiumAlreadyFiredForFiller` and no state is mutated on the failed path.
        if ($.rolled[orderDigest] == 0) {
            revert CorkRolloverContract__PremiumBeforeRollover();
        }
        if ($.premiumFiredFor[orderDigest][filler][subFiller]) {
            revert CorkRolloverContract__PremiumAlreadyFiredForFiller();
        }
        $.premiumFiredFor[orderDigest][filler][subFiller] = true;
    }

    /// @dev ROLLOVER phase handler — pre-validate hooks, snapshot, run pre-hooks, `unwindMint`,
    ///      run mid-hooks, `deposit`, apply rollover accounting, transfer `dstProduced` and any
    ///      leftover srcCST to the Settler, then run post-hooks and tail guards. The mid-hook may
    ///      freely consume caSrc (cross-CA rollover via attested SwapModule); end-to-end value is
    ///      bounded by the cPT-holder-signed `params.minSharesOut` floor enforced after `_depositLeg`.
    /// @custom:invariant INV-DST-FLOOR — `params.minSharesOut` floor enforced after the deposit
    ///                   step; mid-hook caSrc consumption is unbounded by design.
    function _handlePhaseRollover(
        RolloverContractStorage storage $,
        bytes32 orderDigest,
        RolloverTypes.FillContext calldata fillContext,
        RolloverTypes.RolloverParams calldata params,
        RolloverTypes.RolloverIntent calldata intent
    ) internal returns (uint256 actualRolled, uint256 dstProduced, uint256 srcLeftover) {
        _validateRolloverPreflight($, orderDigest, fillContext, params);
        _prevalidateIntentCalls(intent.preRolloverHooks, Typehashes.MODULE_TYPE_PRE_ROLLOVER_HOOK);
        _prevalidateIntentCalls(intent.midRolloverHooks, Typehashes.MODULE_TYPE_MID_ROLLOVER_HOOK);
        _prevalidateIntentCalls(intent.postRolloverHooks, Typehashes.MODULE_TYPE_POST_ROLLOVER_HOOK);

        _RolloverScratch memory s;
        _populateScratch(s, params);

        _executeIntentCalls(intent.preRolloverHooks, Typehashes.MODULE_TYPE_PRE_ROLLOVER_HOOK);

        uint256 caReceived = _unwindLeg(s, params, fillContext);
        if (caReceived < params.minCaReceived) {
            revert CorkRolloverContract__UnwindMintShortfall(caReceived, params.minCaReceived);
        }

        _executeIntentCalls(intent.midRolloverHooks, Typehashes.MODULE_TYPE_MID_ROLLOVER_HOOK);

        s.caDstAfterMid = IERC20(s.caDst).balanceOf(address(this));

        uint256 dstCptBeforeDeposit = IERC20(s.dstCpt).balanceOf(address(this));
        dstProduced = _depositLeg(s, params);
        if (dstProduced < params.minSharesOut) {
            revert CorkRolloverContract__UnwindDepositShortfall(dstProduced, params.minSharesOut);
        }

        (actualRolled, srcLeftover) = _finalizeRolloverLeg(
            $, orderDigest, fillContext, params, intent, s, dstProduced, dstCptBeforeDeposit
        );

        emit RolloverLegSettled(orderDigest, fillContext.filler, dstProduced);
        emit RolloverLegSettledWithSubFiller(
            orderDigest, fillContext.filler, fillContext.subFiller, dstProduced
        );
        emit HookPhaseExecuted(orderDigest, RolloverTypes.HookPhase.ROLLOVER);
    }

    /// @dev Rollover-preflight: terminal-bit check, overfill ceiling, and pool-id pins.
    /// @custom:invariant N-INV-ROLLED-MONOTONE-AND-BOUNDED — overfill and post-terminal rejected.
    /// @custom:invariant INV-PARAMS-SETTLER-PIN — enforced earlier in `_validateOrderDataBinding`.
    function _validateRolloverPreflight(
        RolloverContractStorage storage $,
        bytes32 orderDigest,
        RolloverTypes.FillContext calldata fillContext,
        RolloverTypes.RolloverParams calldata params
    ) internal view {
        uint256 rolledBefore = $.rolled[orderDigest];
        if (_isRolloverTerminal($, orderDigest)) {
            revert CorkRolloverContract__PhaseAlreadyConsumed();
        }
        if (fillContext.fillAmount == 0) {
            revert CorkRolloverContract__ZeroRollover();
        }
        if (rolledBefore + fillContext.fillAmount > fillContext.orderSize) {
            revert CorkRolloverContract__OverfillCeiling(
                rolledBefore, fillContext.fillAmount, fillContext.orderSize
            );
        }
        if (MarketId.unwrap(IPoolShare(params.srcCstToken).poolId()) != params.srcPoolId) {
            revert CorkRolloverContract__SrcPoolIdMismatch();
        }
        if (MarketId.unwrap(IPoolShare(params.dstCstToken).poolId()) != params.dstPoolId) {
            revert CorkRolloverContract__DstPoolIdMismatch();
        }
        uint256 quantum = LibPhoenixShareQuantum.srcShareQuantum(
            IPoolShare(params.srcCstToken).poolManager(), params.srcPoolId
        );
        if (fillContext.orderSize % quantum != 0) {
            revert CorkRolloverContract__ShareAmountNotQuantumAligned(
                fillContext.orderSize, quantum
            );
        }
        if (fillContext.fillAmount % quantum != 0) {
            revert CorkRolloverContract__ShareAmountNotQuantumAligned(
                fillContext.fillAmount, quantum
            );
        }
        uint256 residual = fillContext.orderSize - rolledBefore - fillContext.fillAmount;
        if (residual != 0 && residual % quantum != 0) {
            revert CorkRolloverContract__PartialResidualNotQuantumAligned(residual, quantum);
        }
    }

    /// @dev Populate the rollover scratch with entry snapshots and resolved Phoenix pointers.
    function _populateScratch(
        _RolloverScratch memory s,
        RolloverTypes.RolloverParams calldata params
    ) internal view {
        s.srcCstBefore = IERC20(params.srcCstToken).balanceOf(address(this));
        s.dstCstBefore = IERC20(params.dstCstToken).balanceOf(address(this));
        IPoolManager srcPm = IPoolShare(params.srcCstToken).poolManager();
        IPoolManager dstPm = IPoolShare(params.dstCstToken).poolManager();
        s.srcPoolManager = address(srcPm);
        s.dstPoolManager = address(dstPm);
        s.caSrc = srcPm.market(MarketId.wrap(params.srcPoolId)).collateralAsset;
        s.caDst = dstPm.market(MarketId.wrap(params.dstPoolId)).collateralAsset;
        s.srcCpt = _siblingCptToken(srcPm, params.srcPoolId, params.srcCstToken);
        s.dstCpt = _siblingCptToken(dstPm, params.dstPoolId, params.dstCstToken);
        s.srcCptBefore = IERC20(s.srcCpt).balanceOf(address(this));
        s.dstCptBefore = IERC20(s.dstCpt).balanceOf(address(this));
        s.caDstBefore = IERC20(s.caDst).balanceOf(address(this));
    }

    /// @dev Burn paired srcCPT+srcCST shares via Phoenix `unwindMint`; honour underfill if the
    ///      delta delivered to the rolloverContract falls short of the requested fill amount. The shares
    ///      passed to `unwindMint` are pre-truncated to a multiple of
    ///      `minimumShares = 10**(18 - CAdecimals)` so the rolloverContract's `rolled[]` credit reflects
    ///      what Phoenix actually burns rather than the calldata request (Phoenix truncates
    ///      internally before the burn). The residue
    ///      `R = srcSharesToBurn - effectivelyBurned` becomes srcLeftover and is refunded to
    ///      the filler by `_finalizeRolloverLeg`.
    /// @custom:invariant DSR-1 — `unwindMint == 0` rejected; outbound amount derived from delta.
    /// @custom:invariant N-INV-ROLLED-MONOTONE-AND-BOUNDED — `s.srcSharesToBurn` is reconciled
    ///                   against Phoenix's truncation policy before being read by
    ///                   `_finalizeRolloverLeg` to credit `rolled[]`.
    function _unwindLeg(
        _RolloverScratch memory s,
        RolloverTypes.RolloverParams calldata params,
        RolloverTypes.FillContext calldata fillContext
    ) internal returns (uint256 caReceived) {
        uint256 srcCptDelta = IERC20(s.srcCpt).balanceOf(address(this)) - s.srcCptBefore;
        uint256 srcSharesToBurn = fillContext.fillAmount;
        if (srcCptDelta < fillContext.fillAmount) {
            if (!fillContext.allowUnderfill) {
                revert CorkRolloverContract__SrcCptShortfall(fillContext.fillAmount, srcCptDelta);
            }
            srcSharesToBurn = srcCptDelta;
        }
        // Mirror Phoenix's truncation so rolled[] tracks the actually-burned amount.
        // Phoenix uses minimumShares = 10**(18 - CAdecimals) and truncates the input down to
        // a multiple before burning srcCST + srcCPT; we pre-truncate so the rolloverContract's view
        // matches Phoenix's burn ledger. The truncation residue srcCPT is swept to the cPT holder
        // alongside any pre-existing donation excess (INV-CPT-CONTAINED — srcCPT is cPT holder
        // property, never retained in the rolloverContract after the leg); the srcCST residue is
        // forwarded as srcLeftover by `_finalizeRolloverLeg` and refunded to the filler.
        uint256 minimumShares = LibPhoenixShareQuantum.srcShareQuantum(
            IPoolManager(s.srcPoolManager), params.srcPoolId
        );
        srcSharesToBurn = srcSharesToBurn - (srcSharesToBurn % minimumShares);
        if (srcCptDelta > srcSharesToBurn) {
            IERC20(s.srcCpt).safeTransfer(_owner(), srcCptDelta - srcSharesToBurn);
        }
        s.srcSharesToBurn = srcSharesToBurn;
        uint256 caBefore = IERC20(s.caSrc).balanceOf(address(this));
        uint256 caReportedOut = IPoolManager(s.srcPoolManager)
            .unwindMint(
                MarketId.wrap(params.srcPoolId), srcSharesToBurn, address(this), address(this)
            );
        if (caReportedOut == 0) {
            revert CorkRolloverContract__RolloverZeroUnwindMint();
        }
        caReceived = IERC20(s.caSrc).balanceOf(address(this)) - caBefore;
    }

    /// @dev Deposit caDst growth into the destination Phoenix pool; samples `caDstAfterMid`
    ///      once before approving (DSR-2). The mid-hook may produce caDst from any source
    ///      (swap from caSrc via an attested SwapModule, transfer-in, mint, etc.); the
    ///      `CorkRolloverContract__UnwindDepositShortfall` check at `_handlePhaseRollover` catches
    ///      insufficient end-to-end output against the cPT-holder-signed `params.minSharesOut` floor
    ///      (INV-DST-FLOOR).
    ///
    ///      Bracket-width semantics (DSR-2c): `caForDeposit` includes ANY caDst credited to
    ///      the rolloverContract between `_populateScratch` (entry snapshot) and `caDstAfterMid`
    ///      (sample after pre/mid hooks). cPT-holder-signed pre-rollover hooks that pre-stage caDst
    ///      into the rolloverContract are folded into the deposit and minted into dstCST; the mint
    ///      routes to the settler. This is intentional cPT holder discretion per accepted-03 and is
    ///      asymmetric with DSR-2b (dstCST post-hook anchor) by design: dstCST's tight
    ///      bracket is the INV-5 floor closure; caDst's wider bracket lets cPT holder pre-stage
    ///      collateral in the same intent. cPT holders that intend pre-hook caDst credits to REMAIN
    ///      in the rolloverContract (not deposit) must route via a post-rollover hook instead;
    ///      `params.minSharesOut` is a FLOOR not a CEILING and cannot cap over-production.
    /// @custom:invariant DSR-2 — `caForDeposit` is sampled once; not re-read between approve
    ///                   and `deposit`.
    /// @custom:invariant DSR-2c — `caForDeposit` baseline is the pre-pre-hook `caDstBefore`;
    ///                   pre-rollover-hook caDst credits are intentionally folded into the
    ///                   deposit under the accepted-03 cPT-holder discretion model. Asymmetric with DSR-2b.
    /// @custom:invariant DSR-2b — `sharesOut` is the dstCST balance delta across the deposit
    ///                   call alone, anchored on a local snapshot taken AFTER pre/mid hooks
    ///                   have already run. Anchoring on `s.dstCstBefore` (the entry snapshot
    ///                   sealed in `_populateScratch` BEFORE the hook brackets) would let a
    ///                   pre/mid-hook drain of `X` dstCST be silently absorbed into an
    ///                   under-stated `sharesOut = D - X`, restoring the rolloverContract's balance to
    ///                   the entry snapshot and bypassing the INV-5 floor check.
    /// @custom:invariant INV-DST-FLOOR — verified at the caller via the `minSharesOut` floor.
    /// @custom:invariant INV-DST-CST-MINT-RATIO-BOUNDED — `sharesOut` is capped at the
    ///                   pre-deposit `previewDeposit(dstPoolId, caForDeposit)` quote;
    ///                   over-mint reverts and under-mint remains allowed.
    function _depositLeg(_RolloverScratch memory s, RolloverTypes.RolloverParams calldata params)
        internal
        returns (uint256 sharesOut)
    {
        uint256 caForDeposit = s.caDstAfterMid - s.caDstBefore;
        if (caForDeposit == 0) {
            revert CorkRolloverContract__CaInsufficientForDeposit();
        }
        uint256 canonical = IPoolManager(s.dstPoolManager)
            .previewDeposit(MarketId.wrap(params.dstPoolId), caForDeposit);
        uint256 dstCstAtDeposit = IERC20(params.dstCstToken).balanceOf(address(this));
        IERC20(s.caDst).forceApprove(s.dstPoolManager, caForDeposit);
        uint256 sharesReported = IPoolManager(s.dstPoolManager)
            .deposit(MarketId.wrap(params.dstPoolId), caForDeposit, address(this));
        if (sharesReported == 0) {
            revert CorkRolloverContract__RolloverZeroDeposit();
        }
        IERC20(s.caDst).forceApprove(s.dstPoolManager, 0);
        sharesOut = IERC20(params.dstCstToken).balanceOf(address(this)) - dstCstAtDeposit;
        if (sharesOut > canonical) {
            revert CorkRolloverContract__DepositOverMint(sharesOut, canonical);
        }
    }

    /// @dev Tail of the rollover leg: update `rolled`, set terminal bit if appropriate, forward
    ///      dstCST and any srcCST leftover to the Settler, expose the dynamic dstCPT net increase
    ///      to post-hooks, run post-hooks, and enforce the no-drain guards (INV-5 dstCST,
    ///      INV-CPT-CONTAINED dstCPT).
    /// @custom:invariant N-INV-ROLLED-MONOTONE-AND-BOUNDED — `rolled[orderDigest]` updated here.
    /// @custom:invariant INV-CPT-CONTAINED — bidirectional `!=` guards at end of leg via
    ///                   `CorkRolloverContract__SrcCptNotRestored` and `CorkRolloverContract__DstCptNotRestored`;
    ///                   post-hooks receive only `dstCptAfterDeposit - dstCptBeforeDeposit`, not the
    ///                   full live dstCPT balance, so nonzero standing dstCPT is not swept.
    /// @custom:invariant INV-5 — `CorkRolloverContract__MidPhaseDstCstDrain` guard at end of leg.
    /// @custom:invariant INV-SRC-CST-RETURNED — `CorkRolloverContract__SrcCstNotReturned` guard at end
    ///                   of leg enforces `srcCstAfter == s.srcCstBefore - fillContext.fillAmount`.
    ///                   Defense-in-depth symmetric with INV-5; catches any src-side drift the
    ///                   Phoenix truncation reconciliation in `_unwindLeg` might miss.
    function _finalizeRolloverLeg(
        RolloverContractStorage storage $,
        bytes32 orderDigest,
        RolloverTypes.FillContext calldata fillContext,
        RolloverTypes.RolloverParams calldata params,
        RolloverTypes.RolloverIntent calldata intent,
        _RolloverScratch memory s,
        uint256 dstProduced,
        uint256 dstCptBeforeDeposit
    ) internal returns (uint256 actualRolled, uint256 srcLeftover) {
        actualRolled = s.srcSharesToBurn;
        srcLeftover = _applyRolloverAccounting($, orderDigest, fillContext, actualRolled);

        IERC20(params.dstCstToken).safeTransfer(params.settler, dstProduced);
        if (srcLeftover > 0) {
            IERC20(params.srcCstToken).safeTransfer(params.settler, srcLeftover);
        }

        uint256 dstCptAfterDeposit = IERC20(s.dstCpt).balanceOf(address(this));
        uint256 dstCptMinted =
            dstCptAfterDeposit > dstCptBeforeDeposit ? dstCptAfterDeposit - dstCptBeforeDeposit : 0;
        LibPostRolloverDstCptMinted.write(s.dstCpt, dstCptMinted);

        _executeIntentCalls(intent.postRolloverHooks, Typehashes.MODULE_TYPE_POST_ROLLOVER_HOOK);

        LibPostRolloverDstCptMinted.write(s.dstCpt, 0);

        uint256 dstCptAfter = IERC20(s.dstCpt).balanceOf(address(this));
        if (dstCptAfter != s.dstCptBefore) {
            revert CorkRolloverContract__DstCptNotRestored(s.dstCptBefore, dstCptAfter);
        }
        uint256 srcCptAfter = IERC20(s.srcCpt).balanceOf(address(this));
        if (srcCptAfter != s.srcCptBefore) {
            revert CorkRolloverContract__SrcCptNotRestored(s.srcCptBefore, srcCptAfter);
        }
        uint256 dstCstAfter = IERC20(params.dstCstToken).balanceOf(address(this));
        if (dstCstAfter < s.dstCstBefore) {
            revert CorkRolloverContract__MidPhaseDstCstDrain(s.dstCstBefore, dstCstAfter);
        }
        // Defense-in-depth: end-of-leg srcCST balance must equal the entry snapshot minus the
        // calldata `fillContext.fillAmount`. `s.srcCstBefore` is sampled AFTER the Settler
        // has already transferred `fillAmount` srcCST into the rolloverContract (per BaseSettler.fill:
        // filler -> rolloverContract happens before `executeIntentHooks`). The legitimate flow then
        // drains exactly `fillAmount` srcCST from the rolloverContract — `effectivelyBurned` burned by
        // Phoenix (`unwindMint`) plus `srcLeftover` (= `fillAmount - effectivelyBurned`)
        // forwarded back to the Settler. Any deviation indicates an unexpected src-side
        // mutation (Phoenix truncation semantic shift, donation absorbed mid-leg, hook
        // mutating the rolloverContract's srcCST balance) and must brick the leg.
        uint256 srcCstAfter = IERC20(params.srcCstToken).balanceOf(address(this));
        uint256 expectedSrcCstAfter = s.srcCstBefore - fillContext.fillAmount;
        if (srcCstAfter != expectedSrcCstAfter) {
            revert CorkRolloverContract__SrcCstNotReturned(expectedSrcCstAfter, srcCstAfter);
        }
    }

    /// @dev Apply the rolled counter and terminal-bit update once Phoenix burn accounting is
    ///      known.
    function _applyRolloverAccounting(
        RolloverContractStorage storage $,
        bytes32 orderDigest,
        RolloverTypes.FillContext calldata fillContext,
        uint256 actualRolled
    ) internal returns (uint256 srcLeftover) {
        srcLeftover = fillContext.fillAmount - actualRolled;
        if (!fillContext.allowUnderfill && actualRolled != fillContext.fillAmount) {
            revert CorkRolloverContract__UnderfillNotAllowed(fillContext.fillAmount, actualRolled);
        }

        uint256 cumulativeRolled = $.rolled[orderDigest] + actualRolled;
        $.rolled[orderDigest] = cumulativeRolled;
        if (cumulativeRolled == fillContext.orderSize || !fillContext.allowPartialFills) {
            $.hookNonces[orderDigest] = $.hookNonces[orderDigest] | PHASE_0_TERMINAL_BIT;
        }
    }

    /// @dev Read whether the rollover terminal bit is set for `orderDigest`.
    function _isRolloverTerminal(RolloverContractStorage storage $, bytes32 orderDigest)
        internal
        view
        returns (bool)
    {
        return ($.hookNonces[orderDigest] & PHASE_0_TERMINAL_BIT) != 0;
    }

    /// @dev Resolve the sibling CPT for a given CST via `IPoolManager.shares`; reverts on
    ///      malformed returndata or a mismatched swapToken.
    function _siblingCptToken(IPoolManager pm, bytes32 poolIdRaw, address cstToken)
        internal
        view
        returns (address cpt)
    {
        bytes4 selector = IPoolManager.shares.selector;
        (bool ok, bytes memory data) =
            address(pm).staticcall(abi.encodeWithSelector(selector, poolIdRaw));

        if (!ok || data.length != 64) {
            revert CorkRolloverContract__PoolManagerCallFailed(selector, data);
        }
        (address principalToken, address swapToken) = abi.decode(data, (address, address));
        if (principalToken == address(0) || swapToken == address(0)) {
            revert CorkRolloverContract__PoolManagerCallFailed(selector, data);
        }

        if (swapToken != cstToken) {
            revert CorkRolloverContract__PoolManagerCallFailed(selector, data);
        }
        cpt = principalToken;
    }

    /// @dev Validate every hook in `hooks` is delegatecall-only, no value, no allowFailure,
    ///      has bytecode, and passes the ERC-7484 four-argument `check` overload against
    ///      the rolloverContract's live trust threshold and attester snapshot for `moduleType`.
    function _prevalidateIntentCalls(RolloverTypes.Call[] calldata hooks, ModuleType moduleType)
        internal
        view
    {
        if (hooks.length == 0) {
            return;
        }

        IERC7484 registry = IERC7484(_registry());
        RolloverContractStorage storage $ = _s();

        uint8 threshold = $.liveTrustThreshold;
        address[] memory attesters = $.liveTrustAttesters;

        for (uint256 i = 0; i < hooks.length; ++i) {
            RolloverTypes.Call calldata c = hooks[i];
            if (!c.isDelegateCall) {
                revert CorkRolloverContract__MustBeDelegateCall();
            }
            if (c.allowFailure) {
                revert CorkRolloverContract__MayNotAllowFailure();
            }
            if (c.value != 0) {
                revert CorkRolloverContract__MayNotHaveValue();
            }
            if (c.target.code.length == 0) {
                revert CorkRolloverContract__HookTargetNoCode(c.target);
            }

            try registry.check(c.target, moduleType, attesters, threshold) { }
            catch {
                revert CorkRolloverContract__ModuleTypeMismatch(c.target, moduleType);
            }
        }
    }

    /// @dev Fingerprint the live trust configuration for the during-hook mutation guard.
    ///      Pending trust state lives on the factory's `TimelockController`; only `liveTrust*`
    ///      storage exists on the rolloverContract.
    function _liveTrustHash(RolloverContractStorage storage $) internal view returns (bytes32) {
        return keccak256(abi.encode($.liveTrustThreshold, $.liveTrustAttesters));
    }

    /// @dev Execute a single hook via inline-assembly delegatecall that does NOT copy
    ///      returndata into memory on success and clamps the revert-reason copy at
    ///      `REVERT_REASON_CAP` bytes on failure. Shared by `_executeIntentCalls`.
    ///
    ///      Inline assembly is load-bearing here: Solidity's high-level
    ///      `(bool ok, ) = target.delegatecall(cd)` discard form still triggers the
    ///      returndatacopy via the ABI-decode machinery — the `(bool, bytes memory)`
    ///      tuple is materialised before the second element is dropped. The discard
    ///      defense requires setting DELEGATECALL's `out=(0, 0)` operands, which has
    ///      no Solidity-level surface. A trampoline contract would lose the storage context
    ///      delegatecall provides and is not viable for rolloverContract hooks.
    /// @custom:invariant INV-HOOK-RETURNDATA-DISCARDED — success path does not copy
    ///                   hook returndata to memory; revert reasons clamped to
    ///                   `REVERT_REASON_CAP` bytes on failure.
    function _delegatecallHookDiscardReturndata(RolloverTypes.Call calldata c) internal {
        bool ok;
        address target = c.target;
        bytes calldata callData = c.callData;
        assembly ("memory-safe") {
            let argsPtr := mload(0x40)
            let cdLen := callData.length
            calldatacopy(argsPtr, callData.offset, cdLen)
            // out = (0, 0): returndata is NOT copied to memory on success regardless of
            // size — bounds attested-but-malicious modules that try to gas-grief by
            // returning megabytes of data.
            ok := delegatecall(gas(), target, argsPtr, cdLen, 0, 0)
        }
        if (!ok) {
            bytes memory reason;
            assembly ("memory-safe") {
                let cap := REVERT_REASON_CAP
                let size := returndatasize()
                if gt(size, cap) { size := cap }
                reason := mload(0x40)
                mstore(reason, size)
                returndatacopy(add(reason, 0x20), 0, size)
                // Defensive: zero the word immediately after the copied bytes so any
                // trailing ABI-padding region is deterministically zero regardless of
                // size%32 and prior free-memory contents. The ABI encoder already
                // zero-pads when re-encoding, but this removes any reliance on that
                // behaviour for downstream low-level readers of the bytes buffer.
                mstore(add(add(reason, 0x20), size), 0)
                // Advance free-memory pointer; round up to a word.
                mstore(0x40, and(add(add(reason, add(size, 0x20)), 0x1f), not(0x1f)))
            }
            revert CorkRolloverContract__DelegatecallFailed(target, reason);
        }
    }

    /// @dev Prevalidate every hook against the live trust snapshot, execute via delegatecall,
    ///      reject hook-induced live trust mutation, and restore the registry's trust-attester
    ///      view from the rolloverContract mirror after each hook.
    /// @custom:invariant INV-HOOK-RETURNDATA-DISCARDED — success path does not copy
    ///                   hook returndata to memory; revert reasons clamped to
    ///                   `REVERT_REASON_CAP` bytes on failure.
    function _executeIntentCalls(RolloverTypes.Call[] calldata hooks, ModuleType moduleType)
        internal
    {
        if (hooks.length == 0) {
            return;
        }

        RolloverContractStorage storage $ = _s();
        _prevalidateIntentCalls(hooks, moduleType);
        IERC7484 registry = IERC7484(_registry());
        bytes32 trustHash = _liveTrustHash($);
        uint8 threshold = $.liveTrustThreshold;
        address[] memory attesters = $.liveTrustAttesters;
        for (uint256 i = 0; i < hooks.length; ++i) {
            _delegatecallHookDiscardReturndata(hooks[i]);
            bytes32 afterHash = _liveTrustHash($);
            if (afterHash != trustHash) {
                revert CorkRolloverContract__TrustConfigMutatedDuringHook(trustHash, afterHash);
            }
            registry.trustAttesters(threshold, attesters);
        }
    }

    /*//////////////////////////////////////////////////////////////
                         INTERNAL / PRIVATE VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev ERC-7201 storage-pointer accessor.
    function _s() private pure returns (RolloverContractStorage storage $) {
        bytes32 slot = ROLLOVER_CONTRACT_STORAGE_SLOT;
        assembly {
            $.slot := slot
        }
    }

    /// @dev Decode the CWIA immutable-args trailer (60 bytes: owner ‖ factory ‖ registry).
    function _cwiaImmutableArgs()
        private
        view
        returns (address ownerAddr, address factoryAddr, address registryAddr)
    {
        bytes memory args = Clones.fetchCloneArgs(address(this));
        assembly {
            ownerAddr := shr(0x60, mload(add(args, 0x20)))
            factoryAddr := shr(0x60, mload(add(args, 0x34)))
            registryAddr := shr(0x60, mload(add(args, 0x48)))
        }
    }

    /// @dev Owner address baked into the CWIA trailer.
    function _owner() internal view returns (address o) {
        (o,,) = _cwiaImmutableArgs();
    }

    /// @dev Factory address baked into the CWIA trailer.
    function _factory() internal view returns (address f) {
        (, f,) = _cwiaImmutableArgs();
    }

    /// @dev ERC-7484 attester registry baked into the CWIA trailer.
    function _registry() internal view returns (address r) {
        (,, r) = _cwiaImmutableArgs();
    }

    /// @dev Validate a trust config (threshold and attester list).
    function _validateTrustConfig(uint8 threshold, address[] calldata attesters) private pure {
        if (attesters.length > MAX_TRUST_ATTESTERS) {
            revert CorkRolloverContract__TooManyAttesters(attesters.length, MAX_TRUST_ATTESTERS);
        }
        if (threshold == 0 || attesters.length == 0 || threshold > attesters.length) {
            revert CorkRolloverContract__InvalidThreshold();
        }
        // ERC-7484 / Rhinestone require attesters strictly ascending, which also enforces
        // uniqueness because duplicates must be adjacent in a sorted list.
        for (uint256 i = 0; i < attesters.length; ++i) {
            if (attesters[i] == address(0)) {
                revert CorkRolloverContract__InvalidThreshold();
            }
            if (i != 0 && attesters[i] <= attesters[i - 1]) {
                if (attesters[i] == attesters[i - 1]) {
                    revert CorkRolloverContract__InvalidThreshold();
                }
                revert CorkRolloverContract__InvalidTrustAttesterOrder(
                    attesters[i - 1], attesters[i]
                );
            }
        }
    }
}
