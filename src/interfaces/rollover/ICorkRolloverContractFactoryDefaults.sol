// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

/// @title ICorkRolloverContractFactoryDefaults
/// @notice Factory-wide defaults and deployment anchors used for newly deployed rolloverContracts.
interface ICorkRolloverContractFactoryDefaults {
    /// @notice Emitted when factory-wide deployment defaults are updated.
    /// @dev Affects future `deployRolloverContract` calls only; existing rolloverContracts keep their current live
    ///      trust config and CWIA-baked registry. Delayed governance, if desired, is supplied by
    ///      assigning DEFAULTS_MANAGER_ROLE to an external governance/timelock contract.
    /// @param threshold New live default trust threshold for future deployments.
    /// @param attesters New live default attester list for future deployments.
    /// @param registry New live ERC-7484 registry for future deployments.
    event DefaultsSet(uint8 threshold, address[] attesters, address registry);

    /// @notice Maximum attester-list length accepted by factory and rolloverContract trust configs.
    /// @dev Public constant getter used by tests, deployment checks, operators, and callers to
    ///      preflight constructor defaults, factory defaults updates, per-rolloverContract trust queues, and
    ///      rolloverContract-side trust writes.
    /// @return maxAttesters Maximum supported attester-list length.
    function MAX_TRUST_ATTESTERS() external view returns (uint256 maxAttesters);

    /// @notice Maximum accepted delay for the external trust-config timelock.
    /// @dev The timelock address is immutable; its configured delay can change only through the
    ///      factory-governed `queueTrustConfigDelayUpdate` / `applyTrustConfigDelayUpdate` path.
    /// @return maxDelay Maximum supported trust-config timelock delay.
    function MAX_TRUST_CONFIG_DELAY() external view returns (uint256 maxDelay);

    /// @notice Return the immutable rolloverContract implementation cloned by this factory.
    /// @dev Deployment anchor read by deployment verifiers and operators. Every rolloverContract deployed
    ///      by this factory is cloned from this implementation; rotation requires a new factory
    ///      and creates a new rolloverContract lineage. The uppercase selector mirrors the public immutable
    ///      getter name.
    /// @custom:invariant INV-NON-ROTATABLE-TRUST-ANCHORS — implementation rotation requires a
    ///                   new factory lineage.
    /// @return implementation RolloverContract implementation address.
    function ROLLOVER_CONTRACT_IMPLEMENTATION() external view returns (address implementation);

    /// @notice Return the current default trust threshold for future rolloverContract deployments.
    /// @dev Read by deployment verification, deployers, operators, and simulation tooling before
    ///      `deployRolloverContract`. Despite the uppercase selector, this is a rotatable storage value
    ///      preserved for ABI compatibility with the original public getter. It can change through
    ///      `setDefaults` gated by DEFAULTS_MANAGER_ROLE. Existing rolloverContracts keep their current live
    ///      trust threshold.
    /// @custom:invariant INV-FACTORY-DEFAULTS-MANAGED — default threshold changes only through
    ///                   DEFAULTS_MANAGER_ROLE.
    /// @return threshold Live default trust threshold.
    function DEFAULT_TRUST_THRESHOLD() external view returns (uint8 threshold);

    /// @notice Return the current ERC-7484 registry for future rolloverContract deployments.
    /// @dev Read by deployment verification, deployers, operators, and simulation tooling before
    ///      `deployRolloverContract`. Despite the uppercase selector, this is a rotatable storage value
    ///      preserved for ABI compatibility with the original public getter. It can change through
    ///      `setDefaults` gated by DEFAULTS_MANAGER_ROLE. Existing rolloverContracts remain bound to the
    ///      registry encoded in their CWIA trailer at deployment.
    /// @custom:invariant INV-FACTORY-DEFAULTS-MANAGED — default registry changes only through
    ///                   DEFAULTS_MANAGER_ROLE.
    /// @return registry Live ERC-7484 registry used for future rolloverContract deployments.
    function ERC7484_REGISTRY() external view returns (address registry);

    /// @notice Return the current default attester list for future rolloverContract deployments.
    /// @dev Read by deployment verification, deployers, operators, and simulation tooling before
    ///      `deployRolloverContract`. Changes through `setDefaults` gated by DEFAULTS_MANAGER_ROLE.
    ///      Existing rolloverContracts keep their current live trust attester list unless changed through
    ///      the per-rolloverContract trust-config flow.
    /// @custom:invariant INV-FACTORY-DEFAULTS-MANAGED — default attesters change only through
    ///                   DEFAULTS_MANAGER_ROLE.
    /// @return attesters Live default attester list used for future rolloverContract deployments.
    function defaultAttesters() external view returns (address[] memory attesters);

    /// @notice Set replacement factory defaults for future rolloverContract deployments.
    /// @dev Only callable by DEFAULTS_MANAGER_ROLE. Validates threshold, attesters, and registry
    ///      code, then updates live defaults atomically. Does not mutate any existing rolloverContract.
    ///      Assign DEFAULTS_MANAGER_ROLE to external governance/timelock if delayed defaults
    ///      changes are desired.
    /// @custom:invariant INV-FACTORY-DEFAULTS-MANAGED — factory-wide defaults rotate only through
    ///                   DEFAULTS_MANAGER_ROLE.
    /// @param defaultTrustThreshold New default trust threshold.
    /// @param defaultTrustAttesters New complete default attester list. MUST be strictly
    ///        ascending and unique (ERC-7484 / Rhinestone); unsorted lists revert.
    /// @param defaultRegistry New ERC-7484 registry for future rolloverContract deployments.
    function setDefaults(
        uint8 defaultTrustThreshold,
        address[] calldata defaultTrustAttesters,
        address defaultRegistry
    ) external;
}
