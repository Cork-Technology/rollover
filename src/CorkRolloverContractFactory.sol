// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import {
    ReentrancyGuardTransient
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {
    CorkRolloverContractFactory__AddressHasNoCode,
    CorkRolloverContractFactory__AlreadyDeployed,
    CorkRolloverContractFactory__CallerHasNoRolloverContract,
    CorkRolloverContractFactory__DuplicateAttester,
    CorkRolloverContractFactory__EmptyDefaultAttesters,
    CorkRolloverContractFactory__InvalidDefaultThreshold,
    CorkRolloverContractFactory__InvalidOrderBinding,
    CorkRolloverContractFactory__InvalidThreshold,
    CorkRolloverContractFactory__InvalidTrustConfigTimelockDelay,
    CorkRolloverContractFactory__MismatchedApplyArgs,
    CorkRolloverContractFactory__NoQueuedTrustConfig,
    CorkRolloverContractFactory__NoQueuedTrustConfigDelayUpdate,
    CorkRolloverContractFactory__NotFactoryRolloverContract,
    CorkRolloverContractFactory__NotRolloverContractOwner,
    CorkRolloverContractFactory__NotTimelock,
    CorkRolloverContractFactory__PhaseNotDispatchable,
    CorkRolloverContractFactory__SettlerLatchMismatch,
    CorkRolloverContractFactory__SettlerNotApproved,
    CorkRolloverContractFactory__SettlerNotOriginSettler,
    CorkRolloverContractFactory__TooManyAttesters,
    CorkRolloverContractFactory__TrustConfigTimelockCannotExecute,
    CorkRolloverContractFactory__TrustConfigTimelockMissingRole,
    CorkRolloverContractFactory__TrustConfigTimelockOpenExecutor,
    CorkRolloverContractFactory__UnexpectedTrustConfigRelay,
    CorkRolloverContractFactory__UnknownRolloverContract,
    CorkRolloverContractFactory__UnsortedAttesters,
    CorkRolloverContractFactory__ZeroAddress
} from "src/errors/CorkRolloverContractFactoryErrors.sol";
import { ICorkRolloverContract } from "src/interfaces/rollover/ICorkRolloverContract.sol";
import {
    ICorkRolloverContractFactory
} from "src/interfaces/rollover/ICorkRolloverContractFactory.sol";
import {
    ICorkRolloverContractFactoryAdmin
} from "src/interfaces/rollover/ICorkRolloverContractFactoryAdmin.sol";
import {
    ICorkRolloverContractFactoryDefaults
} from "src/interfaces/rollover/ICorkRolloverContractFactoryDefaults.sol";
import { IRolloverContractLens } from "src/interfaces/rollover/IRolloverContractLens.sol";
import { IRolloverHookDispatcher } from "src/interfaces/rollover/IRolloverHookDispatcher.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @title CorkRolloverContractFactory
/// @notice Factory + lens + admin contract for the Cork Rollover protocol. Deploys per-user
///         rolloverContract clones (CWIA with `owner ‖ factory ‖ registry` trailer), maintains the
///         Settler allowlist, brokers Settler → RolloverContract dispatch with a transient origin-settler
///         latch, and exposes a read-only `IRolloverContractLens` projection over deployed rolloverContracts.
/// @custom:invariant INV-SETTLER-APPROVED — `executeIntentHooks` requires
///                   `approvedSettlers[msg.sender] == true`; default-deny; revoke is instant.
/// @custom:invariant INV-DEFAULT-ATTESTERS-FACTORY-SEEDED — defaults are validated at
///                   construction (non-empty, no zero, strictly ascending,
///                   threshold in [1,length], length ≤ MAX_TRUST_ATTESTERS);
///                   uniqueness follows from strict ascending order.
///                   and forwarded to every deployed rolloverContract's `initialize`.
/// @custom:invariant INV-FACTORY-DEFAULTS-MANAGED — factory-wide defaults rotation
///                   (threshold + attesters + registry) is gated by DEFAULTS_MANAGER_ROLE.
///                   Deployments should assign that role to external governance/timelock if
///                   delayed governance is desired. Affects only NEW rolloverContracts; existing rolloverContracts
///                   rotate via per-rolloverContract `setTrustConfig`.
/// @custom:invariant INV-NON-ROTATABLE-TRUST-ANCHORS — `ROLLOVER_CONTRACT_IMPLEMENTATION` and
///                   `trustConfigTimelock` are immutable post-construction by design; rotation
///                   requires factory redeploy and a new rolloverContract lineage. The timelock delay is
///                   mutable only through the factory-governed delay-update path.
/// @custom:invariant INV-FACTORY-QUEUE-CHECKS-OWNER — every owner-only path that schedules
///                   on the trust-config timelock derives `rolloverContractOf[msg.sender]`, verifies it
///                   is a deployed factory rolloverContract, and then operates only on that rolloverContract.
/// @custom:invariant INV-SCHEDULE-VIA-HELPERS-ONLY — `_scheduleTrustConfig` and
///                   `_scheduleTrustConfigDelayUpdate` are the only factory call sites of
///                   `trustConfigTimelock.schedule`.
/// @custom:invariant INV-PENDING-MIRRORS-TIMELOCK — `pendingConfig[lastSalt[c]]` mirrors the
///                   params encoded in the trust-config timelock op for rolloverContract `c`; direct
///                   external timelock cancellation leaves the mirror visible with timestamp 0.
/// @custom:security-contact security@cork.tech
contract CorkRolloverContractFactory is
    ICorkRolloverContractFactory,
    IRolloverHookDispatcher,
    ICorkRolloverContractFactoryAdmin,
    ICorkRolloverContractFactoryDefaults,
    IRolloverContractLens,
    Ownable,
    AccessControl,
    ReentrancyGuardTransient
{
    /// @notice Maximum number of trust attesters in any factory or per-rolloverContract trust config.
    uint256 public constant MAX_TRUST_ATTESTERS = 16;

    /// @notice Maximum configurable delay for the external trust-config timelock.
    uint256 public constant MAX_TRUST_CONFIG_DELAY = 4 hours;

    /// @notice Domain separator for trust-config timelock delay-update salts.
    bytes32 private constant TRUST_CONFIG_DELAY_UPDATE_SALT_DOMAIN =
        keccak256("cork.factory.trust-config-delay-update");

    /// @notice Domain separator for deterministic per-owner rolloverContract clone salts.
    bytes32 private constant ROLLOVER_CONTRACT_SALT_DOMAIN =
        keccak256("cork.rollover.rolloverContract");

    /// @notice Factory storage slot.
    /// @dev ERC-7201 namespaced storage slot for `FactoryStorage` (namespace
    ///      `cork.factory.storage.v3`). Computed as
    ///      `keccak256(abi.encode(uint256(keccak256("cork.factory.storage.v3")) - 1))
    ///      & ~bytes32(uint256(0xff))`.
    bytes32 private constant FACTORY_STORAGE_SLOT =
        0x33e161bf0309d8211c87f71dbb3e2f85e82ce7cff87a5e8b28dd7396ad330700;

    /// @notice AccessControl role whose holders may approve new Settlers for dispatch.
    bytes32 public constant SETTLER_APPROVER_ROLE = keccak256("SETTLER_APPROVER_ROLE");

    /// @notice AccessControl role whose holders may revoke Settler dispatch approval.
    bytes32 public constant SETTLER_REVOKER_ROLE = keccak256("SETTLER_REVOKER_ROLE");

    /// @notice AccessControl role whose holders may set factory-wide deployment defaults.
    bytes32 public constant DEFAULTS_MANAGER_ROLE = keccak256("DEFAULTS_MANAGER_ROLE");

    /// @notice AccessControl role whose holders may queue/cancel trust-config timelock delay updates.
    bytes32 public constant TRUST_CONFIG_DELAY_MANAGER_ROLE =
        keccak256("TRUST_CONFIG_DELAY_MANAGER_ROLE");

    /// @notice Salt-keyed mirror of a queued trust configuration on the trust-config timelock.
    /// @param threshold Queued trust threshold mirrored from the timelock calldata.
    /// @param attesters Queued attester list mirrored from the timelock calldata.
    struct PendingConfig {
        uint8 threshold;
        address[] attesters;
    }

    /// @notice Namespaced factory storage layout.
    /// @param approvedSettlers Settler allowlist (default-deny; INV-SETTLER-APPROVED).
    /// @param isDeployedRolloverContract Set of rolloverContracts deployed by this factory.
    /// @param rolloverContractOf Lookup `user → rolloverContract` (one rolloverContract per user).
    /// @param lastSalt Per-rolloverContract salt of the currently queued trust-config operation.
    /// @param pendingConfig Per-salt mirror of the trust configuration queued on the timelock.
    /// @param queueNonce Per-rolloverContract monotonic nonce mixed into the queue salt.
    /// @param pendingDelayUpdateSalt Salt of the currently queued timelock delay update.
    /// @param pendingDelayUpdateNewDelay Mirrored new delay for the currently queued update.
    /// @param delayUpdateNonce Monotonic nonce mixed into trust-config delay-update salts.
    /// @param defaultTrustThreshold Live default trust threshold seeded into new rolloverContracts.
    /// @param erc7484Registry Live ERC-7484 registry baked into new rolloverContract CWIA trailers.
    /// @param defaultAttesters Live default attester list seeded into new rolloverContracts.
    struct FactoryStorage {
        // --- Settler / rolloverContract registry ---
        mapping(address settler => bool isApproved) approvedSettlers;
        mapping(address rolloverContract => bool isDeployed) isDeployedRolloverContract;
        mapping(address user => address rolloverContract) rolloverContractOf;
        // --- Per-rolloverContract mirror of the timelock-queued trust configuration ---
        mapping(address rolloverContract => bytes32 salt) lastSalt;
        mapping(bytes32 salt => PendingConfig) pendingConfig;
        mapping(address rolloverContract => uint64) queueNonce;
        bytes32 pendingDelayUpdateSalt;
        uint256 pendingDelayUpdateNewDelay;
        uint64 delayUpdateNonce;
        // --- Factory-wide deployment defaults (live; set by DEFAULTS_MANAGER_ROLE) ---
        uint8 defaultTrustThreshold;
        address erc7484Registry;
        address[] defaultAttesters;
    }

    /// @dev Transient origin-settler provenance latch. Set to `msg.sender` for the active
    ///      factory-to-rolloverContract dispatch, read by the rolloverContract through `originatingSettler()`, and
    ///      cleared when the rolloverContract call returns. Revert rollback clears the write on failed
    ///      dispatches; `nonReentrant` is the practical nested-dispatch guard. Does not block
    ///      sequential mixed-settler dispatches after the latch clears.
    address private transient _originatingSettler;

    /// @dev Transient apply latch. Only the active `applyTrustConfig` frame sets this to the
    ///      canonical timelock op id it is executing. A direct timelock execution reaches
    ///      `relayTrustConfig` with this value unset and therefore reverts even if calldata
    ///      matches the pending mirror. Revert rollback clears failed apply attempts; the
    ///      surrounding `nonReentrant` modifier prevents nested apply frames from changing it.
    bytes32 private transient _expectedTrustConfigOpId;

    /// @notice CWIA implementation address used by deterministic per-owner clones.
    /// @dev Non-rotatable by design. CWIA-clone semantic: every existing rolloverContract is bound to the
    ///      implementation address it was cloned from at deploy time. Rotation requires factory
    ///      redeploy and a new rolloverContract lineage. See INV-NON-ROTATABLE-TRUST-ANCHORS.
    /// @return ROLLOVER_CONTRACT_IMPLEMENTATION Stored rolloverContract implementation value.
    address public immutable ROLLOVER_CONTRACT_IMPLEMENTATION;

    /// @notice External `TimelockController` used for per-rolloverContract trust-config changes and its delay.
    /// @dev Non-rotatable by design. The controller must grant proposer/canceller rights to
    ///      this factory and grant executor rights to this factory so canonical apply paths run
    ///      through `applyTrustConfig` and `applyTrustConfigDelayUpdate`. Rotation requires
    ///      factory redeploy + new rolloverContract lineage. See INV-NON-ROTATABLE-TRUST-ANCHORS.
    /// @return Address of the external trust-config `TimelockController`.
    address public immutable trustConfigTimelock;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Construct the factory, validate the seed trust configuration, and bind the
    ///         external trust-config `TimelockController`.
    /// @custom:invariant INV-DEFAULT-ATTESTERS-FACTORY-SEEDED — defaults validated here.
    /// @param rolloverContractImplementation_ CWIA rolloverContract implementation address.
    /// @param erc7484Registry_ ERC-7484 registry address.
    /// @param defaultThreshold_ Default trust threshold.
    /// @param defaultAttesters_ Default attester list (non-empty, no zero, strictly ascending;
    ///        uniqueness follows from strict ascending order).
    /// @param trustConfigTimelock_ External per-rolloverContract trust-config timelock.
    /// @param ensOwner_ Phoenix-style owner identity for deployment and ENS observability.
    /// @param factoryAdmin_ Holder of DEFAULT_ADMIN_ROLE.
    /// @param defaultsManager_ Holder of DEFAULTS_MANAGER_ROLE.
    /// @param settlerApprover_ Holder of SETTLER_APPROVER_ROLE.
    /// @param settlerRevoker_ Holder of SETTLER_REVOKER_ROLE.
    constructor(
        address rolloverContractImplementation_,
        address erc7484Registry_,
        uint8 defaultThreshold_,
        address[] memory defaultAttesters_,
        address trustConfigTimelock_,
        address ensOwner_,
        address factoryAdmin_,
        address defaultsManager_,
        address settlerApprover_,
        address settlerRevoker_
    ) Ownable(ensOwner_) {
        if (
            rolloverContractImplementation_ == address(0) || erc7484Registry_ == address(0)
                || trustConfigTimelock_ == address(0) || factoryAdmin_ == address(0)
                || defaultsManager_ == address(0) || settlerApprover_ == address(0)
                || settlerRevoker_ == address(0)
        ) {
            revert CorkRolloverContractFactory__ZeroAddress();
        }
        if (rolloverContractImplementation_.code.length == 0) {
            revert CorkRolloverContractFactory__AddressHasNoCode(rolloverContractImplementation_);
        }
        if (erc7484Registry_.code.length == 0) {
            revert CorkRolloverContractFactory__AddressHasNoCode(erc7484Registry_);
        }
        if (trustConfigTimelock_.code.length == 0) {
            revert CorkRolloverContractFactory__AddressHasNoCode(trustConfigTimelock_);
        }
        if (defaultAttesters_.length == 0) {
            revert CorkRolloverContractFactory__EmptyDefaultAttesters();
        }
        if (defaultAttesters_.length > MAX_TRUST_ATTESTERS) {
            revert CorkRolloverContractFactory__TooManyAttesters(
                defaultAttesters_.length, MAX_TRUST_ATTESTERS
            );
        }
        if (defaultThreshold_ == 0 || defaultThreshold_ > defaultAttesters_.length) {
            revert CorkRolloverContractFactory__InvalidDefaultThreshold();
        }
        _requireStrictlyAscendingAttesters(defaultAttesters_);

        FactoryStorage storage $ = _s();
        for (uint256 i = 0; i < defaultAttesters_.length; ++i) {
            $.defaultAttesters.push(defaultAttesters_[i]);
        }
        ROLLOVER_CONTRACT_IMPLEMENTATION = rolloverContractImplementation_;
        trustConfigTimelock = trustConfigTimelock_;
        $.erc7484Registry = erc7484Registry_;
        $.defaultTrustThreshold = defaultThreshold_;

        _validateTrustConfigTimelock(trustConfigTimelock_);

        _grantRole(DEFAULT_ADMIN_ROLE, factoryAdmin_);
        _grantRole(SETTLER_APPROVER_ROLE, settlerApprover_);
        _grantRole(SETTLER_REVOKER_ROLE, settlerRevoker_);
        _grantRole(DEFAULTS_MANAGER_ROLE, defaultsManager_);
        _grantRole(TRUST_CONFIG_DELAY_MANAGER_ROLE, factoryAdmin_);
    }

    /*//////////////////////////////////////////////////////////////
                   EXTERNAL / PUBLIC STATE-CHANGING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ICorkRolloverContractFactory
    /// @custom:invariant N-INV-ROLLOVER-CONTRACT-OF-IMMUTABLE-AFTER-SET — `deployRolloverContract` is the sole
    ///                   writer of `rolloverContractOf[owner]` and `isDeployedRolloverContract[rolloverContract]`.
    ///                   The pre-write guard `rolloverContractOf[owner] != address(0)` makes the
    ///                   write set-once per user; no other code path writes or clears either
    ///                   slot. Corollary: one rolloverContract address per user for the factory's
    ///                   lifetime.
    function deployRolloverContract() external nonReentrant returns (address rolloverContract) {
        FactoryStorage storage $ = _s();
        address owner = msg.sender;

        if ($.rolloverContractOf[owner] != address(0)) {
            revert CorkRolloverContractFactory__AlreadyDeployed(owner);
        }

        address registry = $.erc7484Registry;
        uint8 trustThreshold = $.defaultTrustThreshold;
        address[] memory trustAttesters = $.defaultAttesters;
        bytes memory args = _rolloverContractArgs(owner, registry);
        bytes32 salt = _rolloverContractSalt(owner);

        rolloverContract = Clones.cloneDeterministicWithImmutableArgs(
            ROLLOVER_CONTRACT_IMPLEMENTATION, args, salt
        );

        $.rolloverContractOf[owner] = rolloverContract;
        $.isDeployedRolloverContract[rolloverContract] = true;

        ICorkRolloverContract(rolloverContract).initialize(trustThreshold, trustAttesters);

        emit RolloverContractDeployed(owner, rolloverContract);
    }

    /// @inheritdoc ICorkRolloverContractFactory
    function predictRolloverContractOf(address owner)
        external
        view
        returns (address rolloverContract)
    {
        FactoryStorage storage $ = _s();
        rolloverContract = Clones.predictDeterministicAddressWithImmutableArgs(
            ROLLOVER_CONTRACT_IMPLEMENTATION,
            _rolloverContractArgs(owner, $.erc7484Registry),
            _rolloverContractSalt(owner),
            address(this)
        );
    }

    /// @inheritdoc IRolloverHookDispatcher
    /// @custom:invariant INV-SETTLER-APPROVED — default-deny allowlist enforced here.
    /// @custom:invariant N-INV-FACTORY-ORIGIN-LATCH-SCOPED — `_originatingSettler` is set for
    ///                   rolloverContract hook dispatch and cleared after the call returns.
    function executeIntentHooks(
        address rolloverContract,
        bytes32 orderDigest,
        RolloverTypes.HookPhase phase,
        RolloverTypes.RolloverIntent calldata intent,
        bytes calldata cptHolderSig,
        RolloverTypes.FillContext calldata fillContext,
        RolloverTypes.OrderData calldata orderData
    ) external nonReentrant returns (uint256 dstProduced, uint256 srcLeftover) {
        FactoryStorage storage $ = _s();
        address settler = msg.sender;

        if (phase != RolloverTypes.HookPhase.ROLLOVER && phase != RolloverTypes.HookPhase.PREMIUM) {
            revert CorkRolloverContractFactory__PhaseNotDispatchable(uint8(phase));
        }

        if (orderDigest == bytes32(0)) {
            revert CorkRolloverContractFactory__InvalidOrderBinding();
        }

        _requireApprovedSettler($, settler);

        if (fillContext.originSettler != settler) {
            revert CorkRolloverContractFactory__SettlerNotOriginSettler(
                fillContext.originSettler, settler
            );
        }

        if (!$.isDeployedRolloverContract[rolloverContract]) {
            revert CorkRolloverContractFactory__UnknownRolloverContract(rolloverContract);
        }

        address origin = _originatingSettler;
        if (origin == address(0)) {
            _originatingSettler = settler;
        } else if (origin != settler) {
            revert CorkRolloverContractFactory__SettlerLatchMismatch(origin, settler);
        }

        (dstProduced, srcLeftover) = ICorkRolloverContract(rolloverContract)
            .executeIntentHooks(orderDigest, phase, intent, cptHolderSig, fillContext, orderData);
        _originatingSettler = address(0);
    }

    /// @inheritdoc ICorkRolloverContractFactoryAdmin
    /// @custom:invariant INV-SETTLER-APPROVED — approval gated on non-zero code presence.
    function approveSettler(address settler) external nonReentrant onlyRole(SETTLER_APPROVER_ROLE) {
        if (settler == address(0)) {
            revert CorkRolloverContractFactory__ZeroAddress();
        }
        if (settler.code.length == 0) {
            revert CorkRolloverContractFactory__AddressHasNoCode(settler);
        }
        FactoryStorage storage $ = _s();
        $.approvedSettlers[settler] = true;
        emit SettlerApproved(settler);
    }

    /// @inheritdoc ICorkRolloverContractFactoryAdmin
    /// @custom:invariant INV-SETTLER-APPROVED — instant kill-switch; next dispatch reverts.
    function revokeSettler(address settler) external nonReentrant onlyRole(SETTLER_REVOKER_ROLE) {
        FactoryStorage storage $ = _s();
        $.approvedSettlers[settler] = false;
        emit SettlerRevoked(settler);
    }

    /// @notice Set the factory-wide defaults (threshold, attesters, registry) for future
    ///         rolloverContract deployments.
    /// @dev Affects only NEW rolloverContracts. Existing rolloverContracts rotate via per-rolloverContract
    ///      `queueFactoryDefaultTrustConfig` or `queueTrustConfig` followed by
    ///      `applyTrustConfig` (INV-TRUST-CONFIG-DELAY). The per-rolloverContract
    ///      trust-config timelock is separate from factory governance; assign
    ///      DEFAULTS_MANAGER_ROLE to external governance/timelock if delayed defaults changes
    ///      are desired. The CWIA-trailer registry stays bound to the registry that was live at
    ///      clone time.
    /// @custom:invariant INV-FACTORY-DEFAULTS-MANAGED
    /// @param defaultTrustThreshold New default trust threshold (must satisfy
    ///        `1 ≤ defaultTrustThreshold ≤ defaultTrustAttesters.length`).
    /// @param defaultTrustAttesters New default attester list (non-empty, no zero,
    ///        strictly ascending; uniqueness follows from strict ascending order).
    /// @param defaultRegistry New ERC-7484 registry (must be non-zero and contain code).
    function setDefaults(
        uint8 defaultTrustThreshold,
        address[] calldata defaultTrustAttesters,
        address defaultRegistry
    ) external nonReentrant onlyRole(DEFAULTS_MANAGER_ROLE) {
        _validateTrustConfig(defaultTrustThreshold, defaultTrustAttesters);

        if (defaultRegistry == address(0)) {
            revert CorkRolloverContractFactory__ZeroAddress();
        }

        if (defaultRegistry.code.length == 0) {
            revert CorkRolloverContractFactory__AddressHasNoCode(defaultRegistry);
        }

        FactoryStorage storage $ = _s();
        $.defaultTrustThreshold = defaultTrustThreshold;
        $.erc7484Registry = defaultRegistry;
        delete $.defaultAttesters;
        for (uint256 i = 0; i < defaultTrustAttesters.length; ++i) {
            $.defaultAttesters.push(defaultTrustAttesters[i]);
        }

        emit DefaultsSet(defaultTrustThreshold, defaultTrustAttesters, defaultRegistry);
    }

    /// @inheritdoc ICorkRolloverContractFactory
    /// @custom:invariant INV-FACTORY-QUEUE-CHECKS-OWNER
    /// @custom:invariant INV-SCHEDULE-VIA-HELPERS-ONLY
    function queueTrustConfig(uint8 threshold, address[] calldata attesters) external nonReentrant {
        FactoryStorage storage $ = _s();
        address rolloverContract = _requireCallerRolloverContract($, msg.sender);
        _scheduleTrustConfig($, rolloverContract, threshold, attesters);
    }

    /// @inheritdoc ICorkRolloverContractFactory
    /// @custom:invariant INV-FACTORY-QUEUE-CHECKS-OWNER
    /// @custom:invariant INV-SCHEDULE-VIA-HELPERS-ONLY
    function queueFactoryDefaultTrustConfig() external nonReentrant {
        FactoryStorage storage $ = _s();
        address rolloverContract = _requireCallerRolloverContract($, msg.sender);
        uint8 defaultTrustThreshold = $.defaultTrustThreshold;
        address[] memory defaultTrustAttesters = $.defaultAttesters;
        _scheduleTrustConfig($, rolloverContract, defaultTrustThreshold, defaultTrustAttesters);
    }

    /// @inheritdoc ICorkRolloverContractFactory
    function queueTrustConfigDelayUpdate(uint256 newDelay)
        external
        nonReentrant
        onlyRole(TRUST_CONFIG_DELAY_MANAGER_ROLE)
    {
        FactoryStorage storage $ = _s();
        _scheduleTrustConfigDelayUpdate($, newDelay, msg.sender);
    }

    /// @inheritdoc ICorkRolloverContractFactory
    /// @dev Permissionless after the timelock delay. Loads threshold and attesters from the
    ///      on-chain queued `pendingConfig`. The relay clears the mirror before mutating the
    ///      rolloverContract; revert rollback restores it if execution fails.
    ///
    ///      The timelock op targets the factory's `relayTrustConfig` helper rather than the
    ///      rolloverContract directly. This preserves the rolloverContract's `msg.sender == _factory()` gate —
    ///      the factory itself is the call frame that reaches `rolloverContract.setTrustConfig`.
    function applyTrustConfig(address rolloverContract) external nonReentrant {
        FactoryStorage storage $ = _s();
        (bytes32 salt, PendingConfig memory queued, bytes memory data, bytes32 opId) =
            _trustConfigOperation($, rolloverContract);
        _expectedTrustConfigOpId = opId;
        TimelockController(payable(trustConfigTimelock))
            .execute(address(this), 0, data, bytes32(0), salt);
        _expectedTrustConfigOpId = bytes32(0);

        emit TrustConfigApplied(rolloverContract, opId, queued.threshold, queued.attesters);
    }

    /// @inheritdoc ICorkRolloverContractFactory
    /// @custom:invariant INV-FACTORY-QUEUE-CHECKS-OWNER
    function cancelTrustConfig() external nonReentrant {
        FactoryStorage storage $ = _s();
        address rolloverContract = _requireCallerRolloverContract($, msg.sender);
        _clearTrustConfigOperation($, rolloverContract, msg.sender);
    }

    /// @inheritdoc ICorkRolloverContractFactory
    function cancelTrustConfigDelayUpdate()
        external
        nonReentrant
        onlyRole(TRUST_CONFIG_DELAY_MANAGER_ROLE)
    {
        _clearTrustConfigDelayUpdate(_s(), msg.sender);
    }

    /// @inheritdoc ICorkRolloverContractFactory
    function applyTrustConfigDelayUpdate() external nonReentrant {
        FactoryStorage storage $ = _s();
        (bytes32 salt, uint256 newDelay, bytes memory data, bytes32 opId) =
            _trustConfigDelayUpdateOperation($);

        delete $.pendingDelayUpdateSalt;
        delete $.pendingDelayUpdateNewDelay;

        TimelockController(payable(trustConfigTimelock))
            .execute(trustConfigTimelock, 0, data, bytes32(0), salt);

        emit TrustConfigDelayUpdateApplied(opId, newDelay);
    }

    /// @notice Forward a timelock-released trust-config to a rolloverContract. Callable ONLY by the
    ///         external per-rolloverContract trust-config `TimelockController`. The rolloverContract gates on
    ///         `msg.sender == _factory()`, so this relay frame is what reaches it.
    /// @custom:invariant INV-ROLLOVER_CONTRACT-TRUST-ONLY-VIA-FACTORY
    /// @param rolloverContract Target rolloverContract.
    /// @param salt Salt of the exact queued timelock operation.
    /// @param threshold New trust threshold.
    /// @param attesters New attester list (non-empty, no zero, strictly ascending;
    ///        uniqueness follows from strict ascending order).
    function relayTrustConfig(
        address rolloverContract,
        bytes32 salt,
        uint8 threshold,
        address[] calldata attesters
    ) external {
        if (msg.sender != trustConfigTimelock) {
            revert CorkRolloverContractFactory__NotTimelock(msg.sender);
        }
        FactoryStorage storage $ = _s();
        _requireFactoryRolloverContract($, rolloverContract);

        bytes32 expectedSalt = $.lastSalt[rolloverContract];
        if (expectedSalt == bytes32(0)) {
            revert CorkRolloverContractFactory__NoQueuedTrustConfig(rolloverContract);
        }
        if (salt != expectedSalt) {
            revert CorkRolloverContractFactory__MismatchedApplyArgs(expectedSalt);
        }

        PendingConfig memory queued = $.pendingConfig[salt];
        if (queued.threshold != threshold || !_attesterListsEqual(queued.attesters, attesters)) {
            revert CorkRolloverContractFactory__MismatchedApplyArgs(salt);
        }

        bytes memory data = _relayCalldata(rolloverContract, salt, threshold, attesters);
        bytes32 actualOpId = TimelockController(payable(trustConfigTimelock))
            .hashOperation(address(this), 0, data, bytes32(0), salt);
        bytes32 expectedOpId = _expectedTrustConfigOpId;
        if (expectedOpId == bytes32(0) || expectedOpId != actualOpId) {
            revert CorkRolloverContractFactory__UnexpectedTrustConfigRelay(expectedOpId, actualOpId);
        }

        delete $.pendingConfig[salt];
        $.lastSalt[rolloverContract] = bytes32(0);

        // Forward the calldata list directly into the rolloverContract's calldata trust-config surface.
        ICorkRolloverContract(rolloverContract).setTrustConfig(threshold, attesters);
    }

    /*//////////////////////////////////////////////////////////////
                       EXTERNAL / PUBLIC VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Default trust threshold seeded into every newly deployed rolloverContract.
    /// @dev Reads the rotatable value from namespaced storage. Constructor-seeded; subsequent
    ///      changes run through `setDefaults` gated by DEFAULTS_MANAGER_ROLE. Selector preserved
    ///      across the immutable → storage migration for off-chain ABI compatibility.
    /// @return The live default trust threshold.
    function DEFAULT_TRUST_THRESHOLD() external view returns (uint8) {
        return _s().defaultTrustThreshold;
    }

    /// @notice ERC-7484 registry baked into the CWIA trailer of every newly deployed rolloverContract.
    /// @dev Reads the rotatable value from namespaced storage. Constructor-seeded; subsequent
    ///      changes run through `setDefaults` gated by DEFAULTS_MANAGER_ROLE. Existing rolloverContracts
    ///      retain the registry they were cloned with — only future rolloverContracts see the updated
    ///      value. Selector preserved across the immutable → storage migration for off-chain ABI
    ///      compatibility.
    /// @return The live ERC-7484 registry address.
    function ERC7484_REGISTRY() external view returns (address) {
        return _s().erc7484Registry;
    }

    /// @notice Read the live default attester list for future rolloverContract deployments.
    /// @dev Returns a memory copy of factory storage. Existing rolloverContracts retain the attester
    ///      snapshot seeded at `deployRolloverContract`.
    /// @return attesters Live default attester list seeded into newly deployed rolloverContracts.
    function defaultAttesters() external view returns (address[] memory attesters) {
        attesters = _s().defaultAttesters;
    }

    /// @notice Return the factory implementation version string.
    /// @dev Static code version for off-chain compatibility checks; does not encode deployment
    ///      address, factory defaults, trust config, or runtime state.
    /// @return version_ Factory implementation version.
    function version() external pure returns (string memory version_) {
        version_ = "1.0.0";
    }

    /// @inheritdoc IRolloverHookDispatcher
    function originatingSettler() external view returns (address originSettler) {
        originSettler = _originatingSettler;
    }

    /// @inheritdoc ICorkRolloverContractFactory
    function isDeployedRolloverContract(address rolloverContract) external view returns (bool) {
        return _s().isDeployedRolloverContract[rolloverContract];
    }

    /// @inheritdoc ICorkRolloverContractFactory
    function rolloverContractOf(address owner_) external view returns (address) {
        return _s().rolloverContractOf[owner_];
    }

    /// @inheritdoc ICorkRolloverContractFactoryAdmin
    function approvedSettlers(address settler) external view returns (bool) {
        return _s().approvedSettlers[settler];
    }

    /// @inheritdoc IRolloverContractLens
    function orderState(address rolloverContract, bytes32 orderDigest)
        external
        view
        returns (ICorkRolloverContract.RolloverContractOrderState memory state)
    {
        if (!_s().isDeployedRolloverContract[rolloverContract]) {
            revert CorkRolloverContractFactory__UnknownRolloverContract(rolloverContract);
        }
        state = ICorkRolloverContract(rolloverContract).orderState(orderDigest);
    }

    /// @inheritdoc IRolloverContractLens
    function premiumFiredFor(
        address rolloverContract,
        bytes32 orderDigest,
        address filler,
        bytes32 subFiller
    ) external view returns (bool) {
        if (!_s().isDeployedRolloverContract[rolloverContract]) {
            revert CorkRolloverContractFactory__UnknownRolloverContract(rolloverContract);
        }
        return
            ICorkRolloverContract(rolloverContract).premiumFiredFor(orderDigest, filler, subFiller);
    }

    /// @inheritdoc IRolloverContractLens
    function rolloverContractConfig(address rolloverContract)
        external
        view
        returns (IRolloverContractLens.RolloverContractConfig memory config)
    {
        if (!_s().isDeployedRolloverContract[rolloverContract]) {
            revert CorkRolloverContractFactory__UnknownRolloverContract(rolloverContract);
        }
        ICorkRolloverContract.RolloverContractTrustSnapshot memory snap =
            ICorkRolloverContract(rolloverContract).rolloverContractSnapshot();
        (address ownerAddr, address factoryAddr) = _decodeCwiaArgs(rolloverContract);
        config.owner = ownerAddr;
        config.factory = factoryAddr;
        config.erc7484Registry = snap.erc7484Registry;
        config.liveTrustThreshold = snap.liveTrustThreshold;
        config.liveTrustAttesters = snap.liveTrustAttesters;
    }

    /// @inheritdoc ICorkRolloverContractFactory
    function pendingTrustConfig(address rolloverContract)
        external
        view
        returns (uint8 threshold, address[] memory attesters, uint64 effectiveAt)
    {
        FactoryStorage storage $ = _s();
        bytes32 salt = $.lastSalt[rolloverContract];
        if (salt == bytes32(0)) {
            return (0, new address[](0), 0);
        }
        PendingConfig memory queued = $.pendingConfig[salt];
        threshold = queued.threshold;
        attesters = queued.attesters;

        bytes memory data =
            _relayCalldata(rolloverContract, salt, queued.threshold, queued.attesters);
        bytes32 opId = TimelockController(payable(trustConfigTimelock))
            .hashOperation(address(this), 0, data, bytes32(0), salt);
        // forge-lint: disable-next-line(unsafe-typecast)
        effectiveAt = uint64(TimelockController(payable(trustConfigTimelock)).getTimestamp(opId));
    }

    /// @inheritdoc ICorkRolloverContractFactory
    function pendingTrustConfigDelayUpdate()
        external
        view
        returns (bool queued, uint256 newDelay, uint64 effectiveAt)
    {
        FactoryStorage storage $ = _s();
        bytes32 salt = $.pendingDelayUpdateSalt;
        if (salt == bytes32(0)) {
            return (false, 0, 0);
        }

        newDelay = $.pendingDelayUpdateNewDelay;
        bytes memory data = _delayUpdateCalldata(newDelay);
        bytes32 opId = TimelockController(payable(trustConfigTimelock))
            .hashOperation(trustConfigTimelock, 0, data, bytes32(0), salt);

        queued = true;
        // forge-lint: disable-next-line(unsafe-typecast)
        effectiveAt = uint64(TimelockController(payable(trustConfigTimelock)).getTimestamp(opId));
    }

    /*//////////////////////////////////////////////////////////////
                      INTERNAL / PRIVATE STATE-CHANGING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Sole factory call site of `trustConfigTimelock.schedule` for per-rolloverContract trust-config
    ///      updates. Public owner entrypoints resolve the caller's rolloverContract before this helper.
    ///      This helper still gates on
    ///      factory-rolloverContract membership so direct/internal misuse cannot schedule for non-factory
    ///      addresses. Overwriting a pending op cancels it first so factory-mediated updates keep
    ///      timelock state in lockstep with the factory mirror.
    /// @custom:invariant INV-SCHEDULE-VIA-HELPERS-ONLY
    /// @custom:invariant INV-FACTORY-QUEUE-CHECKS-OWNER
    /// @custom:invariant INV-PENDING-MIRRORS-TIMELOCK
    /// @custom:invariant N-INV-FACTORY-QUEUE-NONCE-SALT-UNIQUE
    function _scheduleTrustConfig(
        FactoryStorage storage $,
        address rolloverContract,
        uint8 threshold,
        address[] memory attesters
    ) private {
        _requireFactoryRolloverContract($, rolloverContract);
        _validateTrustConfig(threshold, attesters);

        // Cancel any pre-existing pending op so re-queueing restarts the timelock clock and the
        // factory mirror tracks at most one live timelock op per rolloverContract.
        bytes32 priorSalt = $.lastSalt[rolloverContract];
        if (priorSalt != bytes32(0)) {
            _clearTrustConfigOperation($, rolloverContract, msg.sender);
        }

        uint64 nonce = $.queueNonce[rolloverContract];
        bytes32 salt = keccak256(abi.encode(rolloverContract, nonce));

        address[] memory stored = new address[](attesters.length);
        for (uint256 i = 0; i < attesters.length; ++i) {
            stored[i] = attesters[i];
        }

        TimelockController tl = TimelockController(payable(trustConfigTimelock));
        bytes memory data = _relayCalldata(rolloverContract, salt, threshold, stored);
        bytes32 opId = tl.hashOperation(address(this), 0, data, bytes32(0), salt);

        uint256 delay = _currentTrustConfigTimelockDelay();
        // If another proposer pre-scheduled the exact factory operation before the owner queued,
        // cancel it so the owner queue establishes a fresh delay from this transaction.
        if (tl.isOperationPending(opId)) {
            tl.cancel(opId);
        }
        tl.schedule(address(this), 0, data, bytes32(0), salt, delay);

        $.queueNonce[rolloverContract] = nonce + 1;
        $.pendingConfig[salt] = PendingConfig({ threshold: threshold, attesters: stored });
        $.lastSalt[rolloverContract] = salt;

        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 effectiveAt = uint64(block.timestamp + delay);
        emit TrustConfigQueued(rolloverContract, opId, threshold, attesters, effectiveAt);
    }

    /// @dev Queue a bounded update to the external trust-config timelock's configured delay.
    ///      Uses the raw current configured delay for scheduling so a bounded decrease can
    ///      recover an out-of-policy live timelock; only `newDelay` is capped here. Cancels
    ///      any existing pending delay-update op first so the factory mirror tracks at most one
    ///      live update.
    function _scheduleTrustConfigDelayUpdate(
        FactoryStorage storage $,
        uint256 newDelay,
        address canceler
    ) private {
        TimelockController tl = TimelockController(payable(trustConfigTimelock));
        uint256 delay = tl.getMinDelay();
        _validateTrustConfigDelay(newDelay);

        if ($.pendingDelayUpdateSalt != bytes32(0)) {
            _clearTrustConfigDelayUpdate($, canceler);
        }

        uint64 nonce = $.delayUpdateNonce;
        bytes32 salt = keccak256(abi.encode(TRUST_CONFIG_DELAY_UPDATE_SALT_DOMAIN, nonce));

        bytes memory data = _delayUpdateCalldata(newDelay);
        bytes32 opId = tl.hashOperation(trustConfigTimelock, 0, data, bytes32(0), salt);

        if (tl.isOperationPending(opId)) {
            tl.cancel(opId);
        }
        tl.schedule(trustConfigTimelock, 0, data, bytes32(0), salt, delay);

        $.delayUpdateNonce = nonce + 1;
        $.pendingDelayUpdateSalt = salt;
        $.pendingDelayUpdateNewDelay = newDelay;

        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 effectiveAt = uint64(block.timestamp + delay);
        emit TrustConfigDelayUpdateQueued(opId, newDelay, effectiveAt);
    }

    /// @dev Clear the factory mirror for a queued trust config and cancel the timelock op only
    ///      while the external controller still considers it pending/ready. External cancellers
    ///      can unset the op directly; in that case the factory must still be able to recover
    ///      liveness by deleting its mirror.
    function _clearTrustConfigOperation(
        FactoryStorage storage $,
        address rolloverContract,
        address canceler
    ) private returns (bytes32 opId) {
        (bytes32 salt,,, bytes32 computedOpId) = _trustConfigOperation($, rolloverContract);
        opId = computedOpId;

        TimelockController tl = TimelockController(payable(trustConfigTimelock));
        if (tl.isOperationPending(opId)) {
            tl.cancel(opId);
        }

        delete $.pendingConfig[salt];
        $.lastSalt[rolloverContract] = bytes32(0);

        emit TrustConfigCanceled(rolloverContract, opId, canceler);
    }

    /// @dev Clear the factory mirror for a queued delay update and cancel the timelock op when
    ///      the controller still considers it pending/ready.
    function _clearTrustConfigDelayUpdate(FactoryStorage storage $, address canceler)
        private
        returns (bytes32 opId)
    {
        (,,, bytes32 computedOpId) = _trustConfigDelayUpdateOperation($);
        opId = computedOpId;

        TimelockController tl = TimelockController(payable(trustConfigTimelock));
        if (tl.isOperationPending(opId)) {
            tl.cancel(opId);
        }

        delete $.pendingDelayUpdateSalt;
        delete $.pendingDelayUpdateNewDelay;

        emit TrustConfigDelayUpdateCanceled(opId, canceler);
    }

    /*//////////////////////////////////////////////////////////////
                         INTERNAL / PRIVATE VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev ERC-7201 storage-pointer accessor.
    function _s() private pure returns (FactoryStorage storage $) {
        bytes32 slot = FACTORY_STORAGE_SLOT;
        assembly {
            $.slot := slot
        }
    }

    /// @dev Build the timelock-payload that forwards through `relayTrustConfig`.
    function _relayCalldata(
        address rolloverContract,
        bytes32 salt,
        uint8 threshold,
        address[] memory attesters
    ) private pure returns (bytes memory) {
        return abi.encodeWithSelector(
            this.relayTrustConfig.selector, rolloverContract, salt, threshold, attesters
        );
    }

    /// @dev Build calldata for the timelock self-call that updates its configured delay.
    function _delayUpdateCalldata(uint256 newDelay) private pure returns (bytes memory) {
        return abi.encodeWithSelector(TimelockController.updateDelay.selector, newDelay);
    }

    /// @dev Canonical CWIA trailer for rolloverContract clones: owner ‖ factory ‖ registry.
    function _rolloverContractArgs(address owner, address registry)
        private
        view
        returns (bytes memory)
    {
        return abi.encodePacked(owner, address(this), registry);
    }

    /// @dev Domain-separated CREATE2 salt for a user's one-per-owner rolloverContract clone.
    function _rolloverContractSalt(address owner_) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(ROLLOVER_CONTRACT_SALT_DOMAIN, owner_));
    }

    /// @dev Canonical construction of the current per-rolloverContract trust-config timelock operation.
    function _trustConfigOperation(FactoryStorage storage $, address rolloverContract)
        private
        view
        returns (bytes32 salt, PendingConfig memory queued, bytes memory data, bytes32 opId)
    {
        salt = $.lastSalt[rolloverContract];
        if (salt == bytes32(0)) {
            revert CorkRolloverContractFactory__NoQueuedTrustConfig(rolloverContract);
        }
        queued = $.pendingConfig[salt];
        data = _relayCalldata(rolloverContract, salt, queued.threshold, queued.attesters);
        opId = TimelockController(payable(trustConfigTimelock))
            .hashOperation(address(this), 0, data, bytes32(0), salt);
    }

    /// @dev Canonical construction of the current trust-config delay-update timelock operation.
    function _trustConfigDelayUpdateOperation(FactoryStorage storage $)
        private
        view
        returns (bytes32 salt, uint256 newDelay, bytes memory data, bytes32 opId)
    {
        salt = $.pendingDelayUpdateSalt;
        if (salt == bytes32(0)) {
            revert CorkRolloverContractFactory__NoQueuedTrustConfigDelayUpdate();
        }
        newDelay = $.pendingDelayUpdateNewDelay;
        data = _delayUpdateCalldata(newDelay);
        opId = TimelockController(payable(trustConfigTimelock))
            .hashOperation(trustConfigTimelock, 0, data, bytes32(0), salt);
    }

    /// @dev Current delay configured on the external per-rolloverContract trust-config timelock.
    function _currentTrustConfigTimelockDelay() private view returns (uint256 delay) {
        delay = TimelockController(payable(trustConfigTimelock)).getMinDelay();
        _validateTrustConfigDelay(delay);
    }

    /// @dev Validate a configured trust-config timelock delay against the protocol cap.
    function _validateTrustConfigDelay(uint256 delay) private pure {
        if (delay > MAX_TRUST_CONFIG_DELAY) {
            revert CorkRolloverContractFactory__InvalidTrustConfigTimelockDelay();
        }
    }

    /// @dev Validate that the supplied trust-config timelock can be used by this factory.
    function _validateTrustConfigTimelock(address controller) private view {
        TimelockController tl = TimelockController(payable(controller));
        uint256 delay = tl.getMinDelay();
        _validateTrustConfigDelay(delay);

        bytes32 proposerRole = tl.PROPOSER_ROLE();
        if (!tl.hasRole(proposerRole, address(this))) {
            revert CorkRolloverContractFactory__TrustConfigTimelockMissingRole(
                proposerRole, address(this)
            );
        }

        bytes32 cancellerRole = tl.CANCELLER_ROLE();
        if (!tl.hasRole(cancellerRole, address(this))) {
            revert CorkRolloverContractFactory__TrustConfigTimelockMissingRole(
                cancellerRole, address(this)
            );
        }

        bytes32 executorRole = tl.EXECUTOR_ROLE();
        if (!tl.hasRole(executorRole, address(this))) {
            revert CorkRolloverContractFactory__TrustConfigTimelockCannotExecute(address(this));
        }
        if (tl.hasRole(executorRole, address(0))) {
            revert CorkRolloverContractFactory__TrustConfigTimelockOpenExecutor();
        }
    }

    /// @dev Factory-side validator shared by defaults updates and per-rolloverContract trust queues.
    ///      Mirrors `CorkRolloverContract._validateTrustConfig` so invalid configs fail before delay.
    function _validateTrustConfig(uint8 threshold, address[] memory attesters) private pure {
        if (attesters.length > MAX_TRUST_ATTESTERS) {
            revert CorkRolloverContractFactory__TooManyAttesters(
                attesters.length, MAX_TRUST_ATTESTERS
            );
        }
        if (threshold == 0 || attesters.length == 0 || threshold > attesters.length) {
            revert CorkRolloverContractFactory__InvalidThreshold();
        }
        _requireStrictlyAscendingAttesters(attesters);
    }

    /// @dev ERC-7484 / Rhinestone require attesters to be non-zero and strictly ascending.
    ///      Uniqueness follows from strict ascending order because duplicates must be adjacent
    ///      in a sorted list.
    function _requireStrictlyAscendingAttesters(address[] memory attesters) private pure {
        for (uint256 i = 0; i < attesters.length; ++i) {
            if (attesters[i] == address(0)) {
                revert CorkRolloverContractFactory__ZeroAddress();
            }
            if (i != 0 && attesters[i] <= attesters[i - 1]) {
                if (attesters[i] == attesters[i - 1]) {
                    revert CorkRolloverContractFactory__DuplicateAttester(attesters[i]);
                }
                revert CorkRolloverContractFactory__UnsortedAttesters(
                    attesters[i - 1], attesters[i]
                );
            }
        }
    }

    /// @dev Production deployed-rolloverContract queue/cancel guard for trust-config entrypoints.
    function _requireFactoryRolloverContract(FactoryStorage storage $, address rolloverContract)
        internal
        view
    {
        if (!$.isDeployedRolloverContract[rolloverContract]) {
            revert CorkRolloverContractFactory__NotFactoryRolloverContract(rolloverContract);
        }
    }

    /// @dev Resolve the rolloverContract owned by `caller` for owner-only trust-config entrypoints.
    ///      The mapping is the source of authority for the one-rolloverContract-per-owner factory model; the
    ///      deployed-rolloverContract and CWIA-owner checks defend against corrupted or incorrectly reused
    ///      helper inputs.
    function _requireCallerRolloverContract(FactoryStorage storage $, address caller)
        private
        view
        returns (address rolloverContract)
    {
        rolloverContract = $.rolloverContractOf[caller];
        if (rolloverContract == address(0)) {
            revert CorkRolloverContractFactory__CallerHasNoRolloverContract(caller);
        }
        _requireFactoryRolloverContract($, rolloverContract);
        (address ownerAddr,) = _decodeCwiaArgs(rolloverContract);
        _requireRolloverContractOwner(rolloverContract, caller, ownerAddr);
    }

    /// @dev Production caller-vs-owner queue/cancel guard. The owner value is read from the
    ///      target rolloverContract/CWIA path by production callers before this comparison.
    function _requireRolloverContractOwner(address rolloverContract, address caller, address owner_)
        internal
        pure
    {
        if (caller != owner_) {
            revert CorkRolloverContractFactory__NotRolloverContractOwner(caller, rolloverContract);
        }
    }

    /// @dev Production approved-settler allowlist guard.
    function _requireApprovedSettler(FactoryStorage storage $, address settler) internal view {
        if (!$.approvedSettlers[settler]) {
            revert CorkRolloverContractFactory__SettlerNotApproved(settler);
        }
    }

    /// @dev Element-wise equality for storage-ordered attester lists.
    function _attesterListsEqual(address[] memory a, address[] calldata b)
        private
        pure
        returns (bool)
    {
        if (a.length != b.length) {
            return false;
        }
        for (uint256 i = 0; i < a.length; ++i) {
            if (a[i] != b[i]) {
                return false;
            }
        }
        return true;
    }

    /// @dev Decode owner+factory from the CWIA immutable-args trailer for a deployed rolloverContract via
    ///      `Clones.fetchCloneArgs`. Trailer is 60 bytes (owner ‖ factory ‖ registry); this helper
    ///      reads only the first 40 because the registry is not needed at the factory level.
    function _decodeCwiaArgs(address rolloverContract)
        internal
        view
        returns (address ownerAddr, address factoryAddr)
    {
        bytes memory args = Clones.fetchCloneArgs(rolloverContract);
        assembly {
            ownerAddr := shr(0x60, mload(add(args, 0x20)))
            factoryAddr := shr(0x60, mload(add(args, 0x34)))
        }
    }
}
