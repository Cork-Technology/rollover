// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

/// @notice Reverts when `msg.sender` already has a deployed rolloverContract.
/// @param user cPT holder / CWIA cPT holder.
error CorkRolloverContractFactory__AlreadyDeployed(address user);

/// @notice Reverts when a factory address argument is zero.
error CorkRolloverContractFactory__ZeroAddress();

/// @notice Reverts when a factory address argument must be a contract but has no code.
/// @param target Address that was expected to contain contract code.
error CorkRolloverContractFactory__AddressHasNoCode(address target);

/// @notice Reverts when the default attester list is empty.
error CorkRolloverContractFactory__EmptyDefaultAttesters();

/// @notice Reverts when the default threshold is zero or exceeds attester count.
error CorkRolloverContractFactory__InvalidDefaultThreshold();

/// @notice Reverts when a trust attester list contains duplicates.
/// @param attester Duplicate attester address.
error CorkRolloverContractFactory__DuplicateAttester(address attester);

/// @notice Reverts when a trust attester list is not strictly ascending.
/// @dev ERC-7484 / Rhinestone require the attester array to be sorted ascending and unique;
///      Cork fails fast at queue/default time instead of late at the registry.
/// @param previous Attester at index `i - 1`.
/// @param current Attester at index `i` that is not greater than `previous`.
error CorkRolloverContractFactory__UnsortedAttesters(address previous, address current);

/// @notice Reverts when a trust attester list exceeds the factory maximum.
/// @param supplied Attester-list length supplied.
/// @param max Protocol maximum attester count.
error CorkRolloverContractFactory__TooManyAttesters(uint256 supplied, uint256 max);

/// @notice Reverts when a trust-config threshold is zero, exceeds the attester-list length, or
///         the attester list is empty.
error CorkRolloverContractFactory__InvalidThreshold();

/// @notice Reverts when a function is called for a rolloverContract address that the factory did not
///         deploy.
/// @param rolloverContract RolloverContract address supplied by the caller.
error CorkRolloverContractFactory__UnknownRolloverContract(address rolloverContract);

/// @notice Reverts when a trust-config entrypoint is called for an unknown rolloverContract.
/// @param rolloverContract RolloverContract address.
error CorkRolloverContractFactory__NotFactoryRolloverContract(address rolloverContract);

/// @notice Reverts when a caller-owned trust-config entrypoint is called before deploying a
///         rolloverContract through this factory.
/// @param caller Calling address.
error CorkRolloverContractFactory__CallerHasNoRolloverContract(address caller);

/// @notice Reverts when a trust-config entrypoint is called by an address that is not the
///         rolloverContract's CWIA-baked owner.
/// @param caller Calling address.
/// @param rolloverContract RolloverContract whose owner the caller failed to match.
error CorkRolloverContractFactory__NotRolloverContractOwner(
    address caller, address rolloverContract
);

/// @notice Reverts when `relayTrustConfig` is called by anything except the per-rolloverContract
///         trust-config timelock.
/// @param caller Calling address.
error CorkRolloverContractFactory__NotTimelock(address caller);

/// @notice Reverts when the supplied trust-config timelock delay exceeds the protocol cap.
error CorkRolloverContractFactory__InvalidTrustConfigTimelockDelay();

/// @notice Reverts when the supplied trust-config timelock has not granted a required role.
/// @param role Timelock role that must be granted.
/// @param account Account that must hold the role.
error CorkRolloverContractFactory__TrustConfigTimelockMissingRole(bytes32 role, address account);

/// @notice Reverts when the supplied trust-config timelock cannot execute factory-scheduled ops.
/// @param factory Factory address that must be able to execute.
error CorkRolloverContractFactory__TrustConfigTimelockCannotExecute(address factory);

/// @notice Reverts when the supplied trust-config timelock allows open execution.
error CorkRolloverContractFactory__TrustConfigTimelockOpenExecutor();

/// @notice Reverts when `applyTrustConfig` or `cancelTrustConfig` runs without a queued
///         configuration for the target rolloverContract.
/// @param rolloverContract RolloverContract address.
error CorkRolloverContractFactory__NoQueuedTrustConfig(address rolloverContract);

/// @notice Reverts when `applyTrustConfigDelayUpdate` or `cancelTrustConfigDelayUpdate` runs
///         without a queued trust-config timelock delay update.
error CorkRolloverContractFactory__NoQueuedTrustConfigDelayUpdate();

/// @notice Reverts when timelock relay calldata/salt does not match the queued mirror or
///         operation identity.
/// @param expectedSalt Salt of the queued op, the on-chain truth.
error CorkRolloverContractFactory__MismatchedApplyArgs(bytes32 expectedSalt);

/// @notice Reverts when the timelock callback is not the exact op being applied by
///         `applyTrustConfig`.
/// @param expectedOpId Operation id temporarily authorized by `applyTrustConfig`.
/// @param actualOpId Operation id derived from the relay calldata and supplied salt.
error CorkRolloverContractFactory__UnexpectedTrustConfigRelay(
    bytes32 expectedOpId, bytes32 actualOpId
);

/// @notice Reverts when `executeIntentHooks` is called with `orderDigest == 0`.
error CorkRolloverContractFactory__InvalidOrderBinding();

/// @notice Reverts when `executeIntentHooks` is called with a valid but unsupported hook phase.
/// @dev Raw values outside the `HookPhase` enum range are rejected by ABI enum decoding before
///      the function body executes.
/// @param phase Enum value that is not accepted by the factory dispatch path.
error CorkRolloverContractFactory__PhaseNotDispatchable(uint8 phase);

/// @notice Reverts when `executeIntentHooks` is called by a Settler whose dispatch approval
///         flag is false.
/// @param settler `msg.sender` of the dispatch.
error CorkRolloverContractFactory__SettlerNotApproved(address settler);

/// @notice Reverts when the transient origin-settler latch is already set to a different
///         Settler.
/// @dev Defensive consistency guard. Normal nested factory dispatch is blocked by the factory's
///      `nonReentrant` modifier.
/// @param current Latched origin Settler.
/// @param caller Calling Settler.
error CorkRolloverContractFactory__SettlerLatchMismatch(address current, address caller);

/// @notice Reverts when `executeIntentHooks` is called with
///         `fillContext.originSettler != msg.sender`.
/// @param originSettler `fillContext.originSettler` from the calling Settler.
/// @param caller `msg.sender` of the dispatch.
error CorkRolloverContractFactory__SettlerNotOriginSettler(address originSettler, address caller);
