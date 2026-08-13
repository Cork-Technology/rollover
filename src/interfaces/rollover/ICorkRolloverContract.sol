// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @title ICorkRolloverContract
/// @notice cPT-holder-owned rolloverContract (CWIA clone) that holds risk-coverage capacity, executes
///         signed hook intents on behalf of the cPT holder, and brackets every rollover leg
///         with attester-gated module checks.
interface ICorkRolloverContract {
    /// @notice RolloverContract trust snapshot: CWIA registry anchor plus live trust configuration.
    /// @dev `erc7484Registry` is baked into the CWIA clone trailer. Threshold and attesters are
    ///      live rolloverContract storage. Pending trust config is held on the factory; read it via
    ///      `ICorkRolloverContractFactory.pendingTrustConfig(rolloverContract)`.
    /// @param erc7484Registry ERC-7484 registry baked into the rolloverContract clone.
    /// @param liveTrustThreshold Active trust threshold currently applied to module checks.
    /// @param liveTrustAttesters Active trust attester set currently applied to module checks.
    struct RolloverContractTrustSnapshot {
        address erc7484Registry;
        uint8 liveTrustThreshold;
        address[] liveTrustAttesters;
    }

    /// @notice RolloverContract-local rollover state for one order.
    /// @dev This is not Settler lifecycle status. `rolled` and `rolloverTerminal` are live
    ///      rolloverContract accounting/state.
    /// @param rolled Source CST consumed by successful rollover phases for the order.
    /// @param rolloverTerminal True once the rolloverContract has observed a terminal rollover state.
    struct RolloverContractOrderState {
        uint256 rolled;
        bool rolloverTerminal;
    }

    /// @notice Emitted as coarse telemetry after a hook phase completes successfully.
    /// @dev Emitted after the phase-specific settlement/premium events for the same phase.
    /// @param orderDigest Canonical order digest the hook executed for.
    /// @param phase Hook-phase discriminator that just completed.
    event HookPhaseExecuted(bytes32 indexed orderDigest, RolloverTypes.HookPhase phase);

    /// @notice Emitted after a rollover phase produces dstCST and transfers it to the Settler.
    /// @param orderDigest Canonical order digest.
    /// @param filler Filler identity for the phase; not the dstCST transfer recipient.
    /// @param dstCstProduced dstCST amount produced and transferred to `params.settler`.
    event RolloverLegSettled(
        bytes32 indexed orderDigest, address indexed filler, uint256 dstCstProduced
    );

    /// @notice Enriched rollover telemetry including the resolved sub-filler key.
    /// @dev Emitted alongside `RolloverLegSettled`.
    /// @param orderDigest Canonical order digest.
    /// @param filler Filler identity for the phase; not the dstCST transfer recipient.
    /// @param subFiller Resolved sub-filler identity keyed with the rollover slot.
    /// @param dstCstProduced dstCST amount produced and transferred to `params.settler`.
    event RolloverLegSettledWithSubFiller(
        bytes32 indexed orderDigest,
        address indexed filler,
        bytes32 indexed subFiller,
        uint256 dstCstProduced
    );

    /// @notice Emitted when a PREMIUM phase completes and sets the rolloverContract-local premium latch.
    /// @param orderDigest Canonical order digest.
    /// @param filler Filler whose premium-fired latch is being set.
    /// @param subFiller Resolved sub-filler identity keyed with the rolloverContract latch.
    /// @param premium Premium-token amount delivered to the premium hook frame.
    event PremiumFired(
        bytes32 indexed orderDigest,
        address indexed filler,
        bytes32 indexed subFiller,
        uint256 premium
    );

    /// @notice Emitted when ERC-20 tokens are withdrawn from the rolloverContract to its CWIA-baked owner.
    /// @param token Token address withdrawn.
    /// @param amount Amount transferred to the owner.
    event OwnerWithdrawn(address indexed token, uint256 amount);

    /// @notice Emitted once when the factory initializes the rolloverContract clone.
    /// @dev The registry is read from the CWIA clone trailer; threshold and attesters become the
    ///      rolloverContract's initial live trust configuration.
    /// @param registry ERC-7484 registry address baked into this rolloverContract.
    /// @param threshold Initial live trust threshold seeded by the factory.
    /// @param attesters Initial live attester list seeded by the factory.
    event RolloverContractInitialized(address registry, uint8 threshold, address[] attesters);

    /// @notice Emitted when the factory applies a new live trust configuration.
    /// @dev Emitted after the rolloverContract stores the supplied threshold/attester set and mirrors it
    ///      into the ERC-7484 registry.
    /// @param threshold New live trust threshold.
    /// @param attesters New complete live attester list.
    event TrustConfigSet(uint8 threshold, address[] attesters);

    /// @notice Coarse accounting snapshot for each successful hook phase.
    /// @dev ROLLOVER phases report rollover consumption and dstCST production with `premium == 0`;
    ///      PREMIUM phases report premium with rollover production fields set to zero.
    /// @param orderDigest Canonical order digest.
    /// @param phase Hook-phase discriminator.
    /// @param filler Filler that initiated the phase.
    /// @param requestedFillAmount Fill-context srcCST amount for this phase.
    /// @param actualRolled ROLLOVER-phase srcCST actually consumed; zero for PREMIUM.
    /// @param cumulativeRolled Per-order cumulative rolled total after this phase.
    /// @param rolloverTerminal True once the rollover-terminal bit is set.
    /// @param dstProduced ROLLOVER-phase dstCST produced; zero for PREMIUM.
    /// @param premium PREMIUM-phase amount delivered to premium hooks; zero for ROLLOVER.
    event IntentPhaseFired(
        bytes32 indexed orderDigest,
        uint8 indexed phase,
        address indexed filler,
        uint256 requestedFillAmount,
        uint256 actualRolled,
        uint256 cumulativeRolled,
        bool rolloverTerminal,
        uint256 dstProduced,
        uint256 premium
    );

    /// @notice Enriched accounting snapshot carrying the resolved sub-filler key.
    /// @dev Emitted alongside `IntentPhaseFired`. ROLLOVER phases report rollover consumption
    ///      and dstCST production with `premium == 0`; PREMIUM phases report premium with
    ///      rollover production fields set to zero.
    /// @param orderDigest Canonical order digest.
    /// @param filler Filler that initiated the phase.
    /// @param subFiller Resolved sub-filler identity keyed with phase-local state.
    /// @param phase Hook-phase discriminator.
    /// @param requestedFillAmount Fill-context srcCST amount for this phase.
    /// @param actualRolled ROLLOVER-phase srcCST actually consumed; zero for PREMIUM.
    /// @param cumulativeRolled Per-order cumulative rolled total after this phase.
    /// @param rolloverTerminal True once the rollover-terminal bit is set.
    /// @param dstProduced ROLLOVER-phase dstCST produced; zero for PREMIUM.
    /// @param premium PREMIUM-phase amount delivered to premium hooks; zero for ROLLOVER.
    event IntentPhaseFiredWithSubFiller(
        bytes32 indexed orderDigest,
        address indexed filler,
        bytes32 indexed subFiller,
        uint8 phase,
        uint256 requestedFillAmount,
        uint256 actualRolled,
        uint256 cumulativeRolled,
        bool rolloverTerminal,
        uint256 dstProduced,
        uint256 premium
    );

    /// @notice Return the owner baked into this rolloverContract clone.
    /// @dev Read from CWIA immutable args, not storage. Used by the factory to authorize
    ///      owner-managed trust-config changes and by the Settler to enforce
    ///      `INV-USER-IS-ROLLOVER_CONTRACT-OWNER`: accepted orders must have
    ///      `orderData.user == ICorkRolloverContract(orderData.rolloverContract).owner()`.
    /// @custom:invariant INV-ROLLOVER_CONTRACT-OWNER-IMMUTABLE — owner is CWIA-baked and has no transfer
    ///                   path.
    /// @return rolloverContractOwner cPT holder baked into the clone.
    function owner() external view returns (address rolloverContractOwner);

    /// @notice Maximum attester-list length accepted by rolloverContract trust configs.
    /// @dev Public constant getter used by tests, deployment checks, operators, and callers to
    ///      preflight rolloverContract-side trust writes.
    /// @return maxAttesters Maximum supported attester-list length.
    function MAX_TRUST_ATTESTERS() external view returns (uint256 maxAttesters);

    /// @notice Return the factory baked into this rolloverContract clone.
    /// @dev Read from CWIA immutable args, not storage. Identifies the factory that deployed and
    ///      initialized this clone.
    /// @return rolloverContractFactory Factory address baked into the clone.
    function factory() external view returns (address rolloverContractFactory);

    /// @notice Return the rolloverContract implementation version.
    /// @dev Static code version for off-chain compatibility checks. Order signatures use the
    ///      Settler EIP-712 domain over `OrderData`; changing this implementation version does not
    ///      invalidate signed orders or their committed `rolloverIntentHash`.
    /// @return implementationVersion RolloverContract implementation semantic version.
    function version() external pure returns (string memory implementationVersion);

    /// @notice Read the registry anchor and live trust config used by this rolloverContract.
    /// @dev Returns the CWIA-baked ERC-7484 registry plus the current live threshold and attester
    ///      list stored on the rolloverContract. Pending trust config is held on the factory and is not reflected
    ///      here until applied; read it via `ICorkRolloverContractFactory.pendingTrustConfig(rolloverContract)`.
    /// @return trustSnapshot Registry anchor and live trust config used for module checks.
    function rolloverContractSnapshot()
        external
        view
        returns (RolloverContractTrustSnapshot memory trustSnapshot);

    /// @notice Read rolloverContract-local rollover state for an order.
    /// @dev Returns the rolloverContract's local accumulator and terminal bit for `orderDigest`. This is not
    ///      Settler lifecycle status. Unseen orders return the zero/default state.
    /// @custom:invariant N-INV-ROLLED-MONOTONE-AND-BOUNDED — exposes the rolloverContract-local rolled
    ///                   accumulator and terminal bit.
    /// @param orderDigest Canonical order digest used as the rolloverContract-local state key.
    /// @return state RolloverContract-local rollover state.
    function orderState(bytes32 orderDigest)
        external
        view
        returns (RolloverContractOrderState memory state);

    /// @notice Whether the rolloverContract-local premium replay latch is set for a
    ///         `(orderDigest, filler, subFiller)` triple.
    /// @dev Local rolloverContract replay state only, not Settler-side premium accounting or claimability
    ///      state. Set during premium-phase execution and observable only if the phase succeeds.
    /// @custom:invariant M-11 — rolloverContract-local premium replay latch is success-only and paired
    ///                   with the Settler-side per-record `premiumFired` bit.
    /// @param orderDigest Canonical order digest.
    /// @param filler Filler address.
    /// @param subFiller Resolved sub-filler identity; use the post-auth resolved key, not raw
    ///        wire zero, when indexing direct fills.
    /// @return fired True if the rolloverContract-local latch is set.
    function premiumFiredFor(bytes32 orderDigest, address filler, bytes32 subFiller)
        external
        view
        returns (bool fired);

    /// @notice Initialize a newly cloned rolloverContract with its initial live trust configuration.
    /// @dev Callable only by the CWIA-baked factory and only once. Reads the ERC-7484 registry
    ///      from CWIA immutable args, validates the supplied threshold/attester set, stores it as
    ///      live trust config, mirrors it into the registry, and emits `RolloverContractInitialized`.
    /// @custom:invariant INV-DEFAULT-ATTESTERS-FACTORY-SEEDED — production deployment passes the
    ///                   factory's current trust defaults into this initializer.
    /// @custom:invariant INV-ROLLOVER_CONTRACT-TRUST-ONLY-VIA-FACTORY — initial live trust state is written
    ///                   only by the CWIA-baked factory.
    /// @param initialTrustThreshold Initial live trust threshold.
    /// @param initialTrustAttesters Initial live attester list. MUST be strictly ascending and
    ///        unique (ERC-7484 / Rhinestone); unsorted lists revert.
    function initialize(uint8 initialTrustThreshold, address[] calldata initialTrustAttesters)
        external;

    /// @notice Execute one authorized hook phase for an order.
    /// @dev Callable only by the CWIA-baked factory during
    ///      `IRolloverHookDispatcher.executeIntentHooks`. The rolloverContract verifies the factory's
    ///      transient origin-settler latch, verifies `cptHolderSig` against the cPT holder,
    ///      re-derives `orderDigest` from `orderData`, and cross-checks
    ///      every fill-context field that duplicates order-data semantics. ROLLOVER phase
    ///      executes rollover hooks and returns production accounting; PREMIUM phase executes
    ///      premium hooks and returns zero accounting.
    /// @custom:invariant INV-FILL-CONTEXT-MATCHES-ORDER — duplicated context fields must equal the
    ///                   cPT-holder-signed order data.
    /// @custom:invariant INV-ORDER-DIGEST-RE-DERIVED-ROLLOVER_CONTRACT-SIDE — the rolloverContract re-derives and
    ///                   verifies the dispatched order digest.
    /// @custom:invariant INV-PARAMS-SETTLER-PIN — signed rollover params must pin the approved
    ///                   origin Settler observed through the factory dispatch frame.
    /// @param orderDigest Settler-supplied order digest; re-derived rolloverContract-side from `orderData`.
    /// @param phase Hook phase forwarded by the factory dispatcher.
    /// @param intent `RolloverIntent` payload whose zero-digest hash is committed by `OrderData`.
    /// @param cptHolderSig cPT-holder EIP-712 / ERC-1271 signature over `orderDigest`.
    /// @param fillContext Settler-supplied fill context checked against `orderData`.
    /// @param orderData cPT-holder order data admitted by the Settler; used rolloverContract-side for digest,
    ///        context, and signed rollover-param binding.
    /// @return dstProduced ROLLOVER-phase dstCST produced; zero for PREMIUM phase.
    /// @return srcLeftover ROLLOVER-phase srcCST left unused; zero for PREMIUM phase.
    /// @dev The locally computed srcCST consumed is emitted in `IntentPhaseFired`; the Settler
    ///      derives consumed source amount from `fillAmount - srcLeftover`.
    function executeIntentHooks(
        bytes32 orderDigest,
        RolloverTypes.HookPhase phase,
        RolloverTypes.RolloverIntent calldata intent,
        bytes calldata cptHolderSig,
        RolloverTypes.FillContext calldata fillContext,
        RolloverTypes.OrderData calldata orderData
    ) external returns (uint256 dstProduced, uint256 srcLeftover);

    /// @notice Apply a new live trust configuration from the factory.
    /// @dev Callable only by the CWIA-baked factory. The rolloverContract validates the supplied
    ///      threshold/attester set, writes live trust storage, mirrors the same config into the
    ///      ERC-7484 registry, and emits `TrustConfigSet`. In production this is reached through
    ///      the factory's timelock-released `relayTrustConfig` path.
    /// @custom:invariant INV-ROLLOVER_CONTRACT-TRUST-ONLY-VIA-FACTORY — live trust writes are factory-only.
    /// @custom:invariant INV-TRUST-CONFIG-DELAY — the factory reaches this setter only through
    ///                   the delayed trust-config apply path.
    /// @param liveTrustThreshold New live trust threshold.
    /// @param liveTrustAttesters New complete live attester list. MUST be strictly ascending and
    ///        unique (ERC-7484 / Rhinestone); unsorted lists revert.
    function setTrustConfig(uint8 liveTrustThreshold, address[] calldata liveTrustAttesters)
        external;

    /// @notice Withdraw ERC-20 tokens from the rolloverContract to its owner.
    /// @dev Callable only by the CWIA-baked owner. This is a broad owner sweep: the rolloverContract does
    ///      not enforce a token allowlist, reserved-balance check, lifecycle check, or nonzero
    ///      amount check. Transfers with `SafeERC20.safeTransfer` and emits `OwnerWithdrawn`.
    /// @param withdrawToken ERC-20 token to withdraw.
    /// @param withdrawAmount Token amount to transfer to the owner.
    function withdraw(address withdrawToken, uint256 withdrawAmount) external;
}
