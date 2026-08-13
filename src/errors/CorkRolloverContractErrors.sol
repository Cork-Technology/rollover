// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { ModuleType } from "src/interfaces/external/erc7484/IERC7484.sol";

/// @notice Reverts when `msg.sender` is not the CWIA-baked factory.
error CorkRolloverContract__NotFactory();

/// @notice Reverts when `msg.sender` is not the CWIA-baked owner.
error CorkRolloverContract__NotOwner();

/// @notice Reverts when the fill deadline has elapsed.
error CorkRolloverContract__DeadlineExpired();

/// @notice Reverts when the intent's own deadline has elapsed.
error CorkRolloverContract__IntentDeadlineExpired();

/// @notice Reverts when async-capable orders sign an intent that expires before fill expiry.
/// @param intentDeadline Signed owner-hook intent deadline.
/// @param fillDeadline cPT-holder-signed order lifecycle fill deadline.
error CorkRolloverContract__IntentDeadlineBeforeFillDeadline(
    uint64 intentDeadline, uint64 fillDeadline
);

/// @notice Reverts when the supplied filler address is zero.
error CorkRolloverContract__ZeroFiller();

/// @notice Reverts when the rollover-terminal bit is already set for this order.
error CorkRolloverContract__PhaseAlreadyConsumed();

/// @notice Reverts when `rolled + fillAmount > orderSize` (N-INV-ROLLED-MONOTONE-AND-BOUNDED).
/// @param rolled Cumulative srcCST rolled prior to this leg.
/// @param fillAmount srcCST requested by the current leg.
/// @param orderSize Order's srcCST ceiling.
error CorkRolloverContract__OverfillCeiling(uint256 rolled, uint256 fillAmount, uint256 orderSize);

/// @notice Reverts when post-hooks drained dstCST (INV-5).
/// @param dstBefore dstCST balance observed before post-hooks.
/// @param dstAfter dstCST balance observed after post-hooks.
error CorkRolloverContract__MidPhaseDstCstDrain(uint256 dstBefore, uint256 dstAfter);

/// @notice Reverts when a hook `Call` is not flagged delegate-call.
error CorkRolloverContract__MustBeDelegateCall();

/// @notice Reverts when a hook `Call` is flagged `allowFailure`.
error CorkRolloverContract__MayNotAllowFailure();

/// @notice Reverts when a hook `Call` carries non-zero `value`.
error CorkRolloverContract__MayNotHaveValue();

/// @notice Reverts when a trust config violates threshold / attester invariants.
error CorkRolloverContract__InvalidThreshold();

/// @notice Reverts when a trust attester list exceeds `MAX_TRUST_ATTESTERS`.
/// @param supplied Attester-list length supplied.
/// @param max Protocol maximum attester count.
error CorkRolloverContract__TooManyAttesters(uint256 supplied, uint256 max);

/// @notice Reverts when a trust attester list is not strictly ascending.
/// @dev ERC-7484 / Rhinestone require the attester array to be sorted ascending and unique;
///      the rolloverContract fails fast instead of late at the registry.
/// @param previous Attester at index `i - 1`.
/// @param current Attester at index `i` that is not greater than `previous`.
error CorkRolloverContract__InvalidTrustAttesterOrder(address previous, address current);

/// @notice Reverts when an executed hook's delegatecall reverts.
/// @param target Hook contract whose delegatecall reverted.
/// @param returndata Raw revert returndata from the failed delegatecall.
error CorkRolloverContract__DelegatecallFailed(address target, bytes returndata);

/// @notice Reverts when a hook target has no code.
/// @param target Hook address that had no code.
error CorkRolloverContract__HookTargetNoCode(address target);

/// @notice Reverts when a hook's delegatecall mutated `liveTrust*` storage mid-execution.
///         Field scope: `liveTrustThreshold`, `liveTrustAttesters`.
/// @param beforeHash Hash of the trust-config snapshot taken before the hook executed.
/// @param afterHash Hash of the trust-config observed after the hook returned.
error CorkRolloverContract__TrustConfigMutatedDuringHook(bytes32 beforeHash, bytes32 afterHash);

/// @notice Reverts when the rolloverContract-local premium latch has already fired for
///         `(orderDigest, filler, subFiller)`. Local replay protection for
///         `_handlePhasePremium`; the protocol-wide M-11 gate lives Settler-side. Under
///         atomic-fill, rolloverContract and Settler premium latches commit in the same successful
///         frame — any hook or factory revert rolls back the entire fill.
error CorkRolloverContract__PremiumAlreadyFiredForFiller();

/// @notice Reverts when PREMIUM phase fires for an `orderDigest` that has no
///         rollover record (`$.rolled[orderDigest] == 0`). Defense-in-depth against
///         a compromised approved Settler bypassing its own per-filler
///         `rec.dstCstProduced != 0` ordering check.
error CorkRolloverContract__PremiumBeforeRollover();

/// @notice Reverts when `unwindMint` produces less collateral than the rollover floor.
/// @param produced Collateral amount actually produced by `unwindMint`.
/// @param floor Minimum collateral required by the rollover floor.
error CorkRolloverContract__UnwindMintShortfall(uint256 produced, uint256 floor);

/// @notice Reverts when `deposit` produces fewer dstCST shares than `minSharesOut`.
/// @param produced dstCST shares actually produced by `deposit`.
/// @param floor `minSharesOut` requested by the filler.
error CorkRolloverContract__UnwindDepositShortfall(uint256 produced, uint256 floor);

/// @notice Reverts when caDst growth across mid-hooks is zero (nothing to deposit).
error CorkRolloverContract__CaInsufficientForDeposit();

/// @notice Reverts when `fillContext.fillAmount` is zero.
error CorkRolloverContract__ZeroRollover();

/// @notice Reverts when a fill amount cannot map to Phoenix's minimum share quantum.
/// @param amount Requested source-share amount.
/// @param quantum Required source-share quantum.
error CorkRolloverContract__ShareAmountNotQuantumAligned(uint256 amount, uint256 quantum);

/// @notice Reverts when a partial fill would leave an unfillable source-share residual.
/// @param residual Source-share residual that would remain after the fill.
/// @param quantum Required source-share quantum.
error CorkRolloverContract__PartialResidualNotQuantumAligned(uint256 residual, uint256 quantum);

/// @notice Reverts when premium-hook execution net-reduces the rolloverContract's balance of
///         `fillContext.premiumToken` below the value observed at PREMIUM entry
///         (INV-PREMIUM-HOOKS-CANNOT-SWEEP-STANDING-BALANCE).
/// @param swept Net deficit observed (preBalance - postBalance).
/// @param premium Maximum amount the hooks were allowed to sweep (`fillContext.premium`).
error CorkRolloverContract__PremiumHookSweptExcess(uint256 swept, uint256 premium);

/// @notice Reverts when the intent's `rolloverContract` field does not equal `address(this)`.
error CorkRolloverContract__RolloverContractMismatch();

/// @notice Reverts when the factory's origin-settler latch disagrees with `fillContext.originSettler`.
error CorkRolloverContract__SettlerMismatch();

/// @notice Reverts when the intent's `orderDigest` field does not equal the dispatched digest.
error CorkRolloverContract__OrderDigestMismatch();

/// @notice Reverts when the canonical zero-digest intent hash does not equal `fillContext.rolloverIntentHash`.
error CorkRolloverContract__IntentHashMismatch();

/// @notice Reverts when owner authorization fails: invalid cPT-holder signature over `orderDigest`.
error CorkRolloverContract__BadIntentSignature();

/// @notice Reverts when the ERC-7484 registry baked into the CWIA trailer is zero.
error CorkRolloverContract__RegistryZero();

/// @notice Reverts when the default attester list passed to `initialize` is empty.
error CorkRolloverContract__EmptyDefaultAttesters();

/// @notice Reverts when underfill is not permitted but the leg under-rolled.
/// @param fillAmount srcCST requested by the leg.
/// @param actualRolled srcCST actually rolled.
error CorkRolloverContract__UnderfillNotAllowed(uint256 fillAmount, uint256 actualRolled);

/// @notice Reverts when srcCPT delivery falls below the requested fill amount.
/// @param expected Expected srcCPT delivery.
/// @param delivered srcCPT actually delivered.
error CorkRolloverContract__SrcCptShortfall(uint256 expected, uint256 delivered);

/// @notice Reverts when `params.srcPoolId` does not match `IPoolShare(srcCstToken).poolId()`.
error CorkRolloverContract__SrcPoolIdMismatch();

/// @notice Reverts when `params.dstPoolId` does not match `IPoolShare(dstCstToken).poolId()`.
error CorkRolloverContract__DstPoolIdMismatch();

/// @notice Reverts when cPT-holder-signed `orderData.rolloverParams.settler` disagrees with
///         `fillContext.originSettler` (INV-PARAMS-SETTLER-PIN).
/// @param signedSettler Settler address from signed `orderData.rolloverParams`.
/// @param fillContextOriginSettler Origin settler latched in the dispatch context.
error CorkRolloverContract__SignedSettlerOriginMismatch(
    address signedSettler, address fillContextOriginSettler
);

/// @notice Reverts when Phoenix `unwindMint` returns zero (DSR-1).
error CorkRolloverContract__RolloverZeroUnwindMint();

/// @notice Reverts when Phoenix `deposit` returns zero (DSR-1).
error CorkRolloverContract__RolloverZeroDeposit();

/// @notice Reverts when `_depositLeg` observes more dstCST minted than the canonical
///         Phoenix mint formula admits (INV-DST-CST-MINT-RATIO-BOUNDED). Defense-in-depth
///         against a buggy / governance-compromised / future-upgraded PoolManager that
///         over-mints dstCST relative to `caForDeposit`. Under-mint (e.g. future Phoenix
///         protocol-fee models) remains allowed — this is strictly an upper bound.
/// @param sharesOut Observed mint via the rolloverContract's local balance delta.
/// @param canonical Canonical upper bound reported by `IPoolManager.previewDeposit`.
error CorkRolloverContract__DepositOverMint(uint256 sharesOut, uint256 canonical);

/// @notice Reverts when post-leg dstCPT balance differs from entry snapshot
///         (INV-CPT-CONTAINED, dstCPT direction).
/// @param expected Entry-snapshot dstCPT balance.
/// @param actual Post-leg dstCPT balance.
error CorkRolloverContract__DstCptNotRestored(uint256 expected, uint256 actual);

/// @notice Reverts when post-leg srcCPT balance differs from entry snapshot
///         (INV-CPT-CONTAINED, srcCPT direction).
/// @param expected Entry-snapshot srcCPT balance.
/// @param actual Post-leg srcCPT balance.
error CorkRolloverContract__SrcCptNotRestored(uint256 expected, uint256 actual);

/// @notice Reverts when post-leg srcCST balance does not match the entry snapshot. Defense-
///         in-depth tail-guard symmetric with `CorkRolloverContract__MidPhaseDstCstDrain`; catches any
///         src-side drift the Phoenix-truncation reconciliation might miss (Phoenix semantic
///         change, donations, future hook mutations).
/// @param expected Entry-snapshot srcCST balance.
/// @param actual Post-leg srcCST balance.
error CorkRolloverContract__SrcCstNotReturned(uint256 expected, uint256 actual);

/// @notice Reverts when a Phoenix pool-manager view call fails or returns malformed data.
/// @param selector Pool-manager function selector that failed.
/// @param returndata Raw revert returndata from the failed call.
error CorkRolloverContract__PoolManagerCallFailed(bytes4 selector, bytes returndata);

/// @notice Reverts when an ERC-7484 module-type attestation fails for a hook target.
/// @param target Hook address that failed attestation.
/// @param expected Module type expected for `target`.
error CorkRolloverContract__ModuleTypeMismatch(address target, ModuleType expected);

/// @notice Reverts when the digest re-derived rolloverContract-side from `orderData` does not match
///         the Settler-supplied `orderDigest` (INV-ORDER-DIGEST-RE-DERIVED-ROLLOVER_CONTRACT-SIDE).
/// @dev Distinct from `CorkRolloverContract__OrderDigestMismatch`, which fires when the intent's own
///      `orderDigest` field disagrees with the dispatch argument.
/// @param expected Digest re-derived from `orderData` via EIP-712.
/// @param supplied Settler-supplied `orderDigest`.
error CorkRolloverContract__OrderDataDigestMismatch(bytes32 expected, bytes32 supplied);

/// @notice Reverts when `fillContext.orderSize` disagrees with `orderData.orderSize`
///         (INV-FILL-CONTEXT-MATCHES-ORDER).
/// @param fillContextValue Settler-supplied `fillContext.orderSize`.
/// @param orderValue cPT-holder-signed `orderData.orderSize`.
error CorkRolloverContract__OrderSizeMismatch(uint256 fillContextValue, uint256 orderValue);

/// @notice Reverts when `fillContext.fillDeadline` disagrees with `orderData.fillDeadline`
///         (INV-FILL-CONTEXT-MATCHES-ORDER).
/// @param fillContextValue Settler-supplied `fillContext.fillDeadline`.
/// @param orderValue cPT-holder-signed `orderData.fillDeadline`.
error CorkRolloverContract__FillDeadlineMismatch(uint64 fillContextValue, uint64 orderValue);

/// @notice Reverts when `fillContext.premiumToken` disagrees with `orderData.premiumToken`
///         (INV-FILL-CONTEXT-MATCHES-ORDER). Premium phase only — rollover phase passes zero.
/// @param fillContextValue Settler-supplied `fillContext.premiumToken`.
/// @param orderValue cPT-holder-signed `orderData.premiumToken`.
error CorkRolloverContract__PremiumTokenMismatch(address fillContextValue, address orderValue);

/// @notice Reverts when `fillContext.allowPartialFills` disagrees with `orderData.allowPartialFills`
///         (INV-FILL-CONTEXT-MATCHES-ORDER).
/// @param fillContextValue Settler-supplied flag.
/// @param orderValue cPT-holder-signed flag.
error CorkRolloverContract__AllowPartialFillsMismatch(bool fillContextValue, bool orderValue);

/// @notice Reverts when `fillContext.allowUnderfill` disagrees with `orderData.allowUnderfill`
///         (INV-FILL-CONTEXT-MATCHES-ORDER).
/// @param fillContextValue Settler-supplied flag.
/// @param orderValue cPT-holder-signed flag.
error CorkRolloverContract__AllowUnderfillMismatch(bool fillContextValue, bool orderValue);

/// @notice Reverts when `fillContext.rolloverIntentHash` disagrees with `orderData.rolloverIntentHash`
///         (INV-FILL-CONTEXT-MATCHES-ORDER).
error CorkRolloverContract__RolloverIntentHashCtxMismatch();
