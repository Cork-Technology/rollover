// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { FactoryDefaultsRotationInvariantBase } from "../FactoryDefaultsRotationInvariantBase.sol";

/// @notice INV-FACTORY-DEFAULTS-MANAGED — fail-on-revert invariant suite:
///         factory-wide defaults rotate through DEFAULTS_MANAGER_ROLE and seed new rolloverContracts.
/// @dev fail-on-revert mode (companion at test/invariant/continueOnRevert/FactoryDefaultsRotation.t.sol).
/// @custom:invariant INV-FACTORY-DEFAULTS-MANAGED
contract FactoryDefaultsRotationFailOnRevertTest is FactoryDefaultsRotationInvariantBase {
    /// @notice Sets up the active factory-defaults rotation invariant handler.
    function setUp() public override {
        super.setUp();
        _setUpFactoryDefaultsRotationInvariant();
    }

    /// @notice invariant: live defaults match the ghost model after every action.
    function invariant_factoryDefaults_liveGhostMatches() public view {
        assertFalse(
            defaultsHandler.liveDefaultsDiverged(),
            "INV-FACTORY-DEFAULTS-MANAGED: live defaults diverged"
        );
    }

    /// @notice invariant: fresh rolloverContracts seed from current live defaults.
    function invariant_factoryDefaults_newRolloverContractsSeedLiveDefaults() public view {
        assertFalse(
            defaultsHandler.deployedRolloverContractSeedMismatch(),
            "INV-FACTORY-DEFAULTS-MANAGED: deployed rolloverContract seed mismatch"
        );
        assertFalse(
            defaultsHandler.freshDeployRejected(),
            "INV-FACTORY-DEFAULTS-MANAGED: fresh deploy rejected"
        );
    }

    /// @notice invariant: pre-existing rolloverContracts retain their initialized trust config.
    function invariant_factoryDefaults_existingRolloverContractsUnaffected() public view {
        assertFalse(
            defaultsHandler.existingRolloverContractChanged(),
            "INV-FACTORY-DEFAULTS-MANAGED: existing rolloverContract changed"
        );
    }

    /// @notice invariant: handler-authored valid defaults updates do not reject.
    function invariant_factoryDefaults_validSetsAccepted() public view {
        assertFalse(
            defaultsHandler.validSetRejected(), "INV-FACTORY-DEFAULTS-MANAGED: valid set rejected"
        );
    }
}
