// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

/// @title ICorkRolloverContractFactory
/// @notice Public factory surface for deploying rolloverContracts, resolving factory-deployed rolloverContracts, and
///         managing per-rolloverContract trust-config changes.
interface ICorkRolloverContractFactory {
    /// @notice Emitted when `deployRolloverContract` creates a rolloverContract for `msg.sender`.
    /// @param user cPT holder that deployed the clone.
    /// @param rolloverContract Deployed Cork rolloverContract address.
    event RolloverContractDeployed(address indexed user, address indexed rolloverContract);

    /// @notice Emitted when a per-rolloverContract trust configuration is queued on the timelock.
    /// @dev Re-queueing first cancels the prior pending operation and emits
    ///      `TrustConfigCanceled`. This event reflects both the factory pending-config mirror and
    ///      the newly scheduled timelock operation.
    /// @param rolloverContract Target rolloverContract.
    /// @param opId Timelock operation id (`hashOperation`).
    /// @param threshold Queued trust threshold.
    /// @param attesters Queued attester list.
    /// @param effectiveAt Earliest timestamp the queued op can be applied.
    event TrustConfigQueued(
        address indexed rolloverContract,
        bytes32 indexed opId,
        uint8 threshold,
        address[] attesters,
        uint64 effectiveAt
    );

    /// @notice Emitted when a queued trust configuration is applied after timelock execution.
    /// @dev The matching timelock operation has executed, the factory pending-config mirror has
    ///      been cleared, and the config has been relayed to the rolloverContract as live trust state.
    /// @param rolloverContract Target rolloverContract.
    /// @param opId Timelock operation id that just executed.
    /// @param threshold Newly live trust threshold.
    /// @param attesters Newly live attester list.
    event TrustConfigApplied(
        address indexed rolloverContract, bytes32 indexed opId, uint8 threshold, address[] attesters
    );

    /// @notice Emitted when a pending trust-config operation is cancelled and mirrored state clears.
    /// @dev Emitted both by explicit cancellation and by re-queueing, which cancels the prior
    ///      pending timelock operation before scheduling the replacement.
    /// @param rolloverContract Target rolloverContract.
    /// @param opId Timelock operation id that was cancelled.
    /// @param canceler cPT holder who cancelled the op.
    event TrustConfigCanceled(
        address indexed rolloverContract, bytes32 indexed opId, address indexed canceler
    );

    /// @notice Emitted when a trust-config timelock delay update is queued.
    /// @param opId Timelock operation id (`hashOperation`).
    /// @param newDelay Queued replacement delay.
    /// @param effectiveAt Earliest timestamp the queued delay update can be applied.
    event TrustConfigDelayUpdateQueued(bytes32 indexed opId, uint256 newDelay, uint64 effectiveAt);

    /// @notice Emitted when a pending trust-config timelock delay update is cancelled.
    /// @param opId Timelock operation id that was cancelled.
    /// @param canceler Account that cancelled the op.
    event TrustConfigDelayUpdateCanceled(bytes32 indexed opId, address indexed canceler);

    /// @notice Emitted when a trust-config timelock delay update is applied.
    /// @param opId Timelock operation id that was applied.
    /// @param newDelay Newly live trust-config timelock delay.
    event TrustConfigDelayUpdateApplied(bytes32 indexed opId, uint256 newDelay);

    /// @notice Deploy a rolloverContract clone owned by the caller.
    /// @dev One rolloverContract can be deployed per caller. The cPT holder is not supplied as an
    ///      argument; it is always `msg.sender`. The CWIA clone is bound to
    ///      `(owner, address(this), live ERC-7484 registry)` and initialized with the factory's
    ///      current default trust threshold and attester list.
    /// @custom:invariant N-INV-ROLLOVER-CONTRACT-OF-IMMUTABLE-AFTER-SET — `deployRolloverContract` is the sole
    ///                   writer of `rolloverContractOf[owner]` and the deployed-rolloverContract flag.
    /// @custom:invariant INV-DEFAULT-ATTESTERS-FACTORY-SEEDED — the clone receives the
    ///                   factory's current default threshold and attester list at init.
    /// @return rolloverContract Address of the newly deployed rolloverContract clone.
    function deployRolloverContract() external returns (address rolloverContract);

    /// @notice Predict the rolloverContract address for `owner` before deployment.
    /// @dev Uses the same CREATE2 deployer, implementation, owner-derived salt, and CWIA
    ///      initcode as `deployRolloverContract()`. Because the CWIA args include
    ///      `(owner, address(this), live ERC-7484 registry)`, same-address parity across
    ///      chains requires identical factory address, implementation address, owner, and
    ///      live registry address at prediction/deployment time.
    /// @param owner cPT holder address whose rolloverContract address is being predicted.
    /// @return rolloverContract Predicted factory-deployed rolloverContract address.
    function predictRolloverContractOf(address owner)
        external
        view
        returns (address rolloverContract);

    /// @notice Return the rolloverContract deployed by `owner` through this factory.
    /// @dev The mapping is set by `deployRolloverContract()` and is never cleared or overwritten.
    /// @param owner cPT holder address.
    /// @return rolloverContract Factory-deployed rolloverContract for `owner`, or zero if `owner` has not deployed one.
    function rolloverContractOf(address owner) external view returns (address rolloverContract);

    /// @notice Return whether `rolloverContract` was deployed by this factory.
    /// @dev Factory-lineage check used by Settlers and factory policy gates. It does not prove
    ///      that `rolloverContract` is a valid Cork rolloverContract from another factory.
    /// @param rolloverContract RolloverContract address to check.
    /// @return deployed True if this factory deployed `rolloverContract`.
    function isDeployedRolloverContract(address rolloverContract)
        external
        view
        returns (bool deployed);

    /// @notice Return the factory implementation version string.
    /// @dev Static code version for off-chain compatibility checks; does not encode deployment
    ///      address, factory defaults, trust config, or runtime state.
    /// @return version_ Factory implementation version.
    function version() external pure returns (string memory version_);

    /// @notice Address of the external per-rolloverContract trust-config `TimelockController`.
    /// @dev Used for per-rolloverContract trust-config queue/apply/cancel operations and off-chain
    ///      operation-id derivation. This timelock does not gate factory governance,
    ///      Settler approval, Settler revocation, or factory-wide default rotation.
    /// @return controller TimelockController address.
    function trustConfigTimelock() external view returns (address controller);

    /// @notice Stage a custom replacement trust threshold and attester list for the caller's
    ///         deployed rolloverContract.
    /// @dev Only a caller with a rolloverContract deployed through this factory may call. The target rolloverContract is
    ///      resolved from `rolloverContractOf[msg.sender]`; callers cannot supply or affect another rolloverContract.
    ///      The new config is validated and stored as this rolloverContract's pending config, but does not
    ///      change the live rolloverContract or registry trust state until `applyTrustConfig(rolloverContract)` executes
    ///      through the per-rolloverContract trust-config timelock after its minimum delay. Re-queueing
    ///      cancels the prior pending operation and restarts the delay. This is the advanced path
    ///      for owners that intentionally provide a custom config instead of the current factory
    ///      defaults.
    /// @custom:invariant INV-TRUST-CONFIG-DELAY — queued trust changes are delayed and cannot
    ///                   mutate live trust state until `applyTrustConfig`.
    /// @custom:invariant INV-FACTORY-QUEUE-CHECKS-OWNER — queueing resolves
    ///                   `rolloverContractOf[msg.sender]` and requires a deployed factory rolloverContract.
    /// @custom:invariant INV-SCHEDULE-VIA-HELPERS-ONLY — queueing routes through the canonical
    ///                   trust-config scheduling helper.
    /// @custom:invariant N-INV-FACTORY-QUEUE-NONCE-SALT-UNIQUE — each successful queue consumes
    ///                   a per-rolloverContract nonce for a fresh timelock salt.
    /// @param threshold New trust threshold.
    /// @param attesters Complete replacement attester list. MUST be strictly ascending and
    ///        unique (ERC-7484 / Rhinestone); unsorted lists revert at queue time and are never
    ///        scheduled.
    function queueTrustConfig(uint8 threshold, address[] calldata attesters) external;

    /// @notice Stage the current factory default trust config as the caller's rolloverContract pending
    ///         config.
    /// @dev Only a caller with a rolloverContract deployed through this factory may call. The target rolloverContract is
    ///      resolved from `rolloverContractOf[msg.sender]`; callers cannot supply or affect another rolloverContract.
    ///      The factory snapshots its live default threshold and attester list at queue time, then
    ///      schedules the same timelock operation as `queueTrustConfig`. Later `setDefaults` calls
    ///      do not alter the queued config; owners must queue again to use newer defaults.
    ///      Re-queueing cancels the prior pending operation and restarts the delay.
    /// @custom:invariant INV-TRUST-CONFIG-DELAY — queued trust changes are delayed and cannot
    ///                   mutate live trust state until `applyTrustConfig`.
    /// @custom:invariant INV-FACTORY-QUEUE-CHECKS-OWNER — queueing resolves
    ///                   `rolloverContractOf[msg.sender]` and requires a deployed factory rolloverContract.
    /// @custom:invariant INV-SCHEDULE-VIA-HELPERS-ONLY — queueing routes through the canonical
    ///                   trust-config scheduling helper.
    /// @custom:invariant N-INV-FACTORY-QUEUE-NONCE-SALT-UNIQUE — each successful queue consumes
    ///                   a per-rolloverContract nonce for a fresh timelock salt.
    function queueFactoryDefaultTrustConfig() external;

    /// @notice Queue a replacement delay for future trust-config timelock operations.
    /// @dev Only callable by `TRUST_CONFIG_DELAY_MANAGER_ROLE`. The queued operation calls
    ///      `TimelockController.updateDelay(newDelay)` on the immutable trust-config timelock
    ///      itself. Re-queueing cancels the prior pending delay-update op before scheduling the
    ///      replacement. Existing already-scheduled trust-config ops keep their original
    ///      effective timestamp.
    /// @param newDelay New delay, bounded by `MAX_TRUST_CONFIG_DELAY`.
    function queueTrustConfigDelayUpdate(uint256 newDelay) external;

    /// @notice Cancel the pending trust-config timelock delay update.
    /// @dev Only callable by `TRUST_CONFIG_DELAY_MANAGER_ROLE`.
    function cancelTrustConfigDelayUpdate() external;

    /// @notice Apply a queued trust-config timelock delay update after its timelock delay.
    /// @dev Permissionless. The factory executes the matching timelock operation so the
    ///      canonical path remains `applyTrustConfigDelayUpdate()`.
    function applyTrustConfigDelayUpdate() external;

    /// @notice Read the pending trust configuration for `rolloverContract`.
    /// @dev Public view for fillers and operators checking trust-config stability. Returns
    ///      `(0, [], 0)` when no factory pending mirror exists. `threshold` and `attesters`
    ///      come from the factory mirror; `effectiveAt` comes from the external trust-config
    ///      timelock operation. A nonzero config with `effectiveAt == 0` means the factory
    ///      mirror exists but the corresponding timelock op is absent, done, or unset.
    /// @custom:invariant INV-TRUST-CONFIG-DELAY — exposes the pending apply timestamp used as
    ///                   the trust-config stability signal.
    /// @custom:invariant INV-PENDING-MIRRORS-TIMELOCK — reports the factory mirror paired with
    ///                   the currently queued timelock operation for `rolloverContract`.
    /// @param rolloverContract Target rolloverContract.
    /// @return threshold Factory-mirrored pending trust threshold, or zero if no mirror exists.
    /// @return attesters Factory-mirrored pending attester list, or empty if no mirror exists.
    /// @return effectiveAt Timelock timestamp for the mirrored op, or zero if absent/done/unset.
    function pendingTrustConfig(address rolloverContract)
        external
        view
        returns (uint8 threshold, address[] memory attesters, uint64 effectiveAt);

    /// @notice Read the pending trust-config timelock delay update, if any.
    /// @return queued True when the factory has a pending delay-update mirror.
    /// @return newDelay Factory-mirrored replacement delay, or zero when none is queued.
    /// @return effectiveAt Timelock timestamp for the mirrored op, or zero if absent/done/unset.
    function pendingTrustConfigDelayUpdate()
        external
        view
        returns (bool queued, uint256 newDelay, uint64 effectiveAt);

    /// @notice Apply a queued trust configuration after the trust-config timelock delay.
    /// @dev Permissionless. The factory loads `threshold` and `attesters` from the pending
    ///      mirror for `rolloverContract`. The call executes the matching timelock operation, clears the
    ///      pending mirror, and relays the config to the rolloverContract through `relayTrustConfig`.
    /// @custom:invariant INV-TRUST-CONFIG-DELAY — live trust state can change only through the
    ///                   timelock-delayed apply path.
    /// @custom:invariant INV-PENDING-MIRRORS-TIMELOCK — apply uses the pending mirror and clears
    ///                   it in lockstep with timelock execution.
    /// @param rolloverContract Target rolloverContract.
    function applyTrustConfig(address rolloverContract) external;

    /// @notice Relay a timelock-released trust configuration to a rolloverContract.
    /// @dev Callable only by the external per-rolloverContract trust-config `TimelockController`. This
    ///      external selector is the timelock operation target used by `applyTrustConfig`; callers
    ///      should not treat it as a direct admin or cPT-holder entrypoint. The factory requires
    ///      a matching pending mirror and the exact operation id temporarily authorized by
    ///      `applyTrustConfig`, so direct timelock execution reverts.
    /// @custom:invariant INV-ROLLOVER_CONTRACT-TRUST-ONLY-VIA-FACTORY — live rolloverContract trust writes are
    ///                   reached through the factory call frame only.
    /// @param rolloverContract Target rolloverContract.
    /// @param salt Salt of the exact queued timelock operation.
    /// @param threshold New live trust threshold.
    /// @param attesters New complete live trust attester list.
    function relayTrustConfig(
        address rolloverContract,
        bytes32 salt,
        uint8 threshold,
        address[] memory attesters
    ) external;

    /// @notice Cancel the pending trust configuration for the caller's deployed rolloverContract.
    /// @dev Only a caller with a rolloverContract deployed through this factory may call. The target rolloverContract is
    ///      resolved from `rolloverContractOf[msg.sender]`; callers cannot supply or affect another rolloverContract.
    ///      Cancels the matching timelock operation and clears the pending factory mirror without
    ///      changing the rolloverContract's live trust state. Reverts if no trust configuration is queued.
    /// @custom:invariant INV-FACTORY-QUEUE-CHECKS-OWNER — cancellation resolves
    ///                   `rolloverContractOf[msg.sender]` and requires a deployed factory rolloverContract.
    /// @custom:invariant INV-TRUST-CONFIG-DELAY — owners can abort pending delayed trust changes
    ///                   without mutating live trust state.
    /// @custom:invariant INV-PENDING-MIRRORS-TIMELOCK — cancellation clears the factory mirror
    ///                   in lockstep with timelock cancellation.
    function cancelTrustConfig() external;
}
