// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../base/BaseTest.sol";
import { FactoryInvariantHandler } from "./FactoryInvariantHandler.sol";

/// @notice Factory admin lockdown and settler-allowlist invariants under fuzzed admin probes.
/// @custom:invariant INV-SETTLER-APPROVED
/// @custom:invariant INV-DEFAULT-ATTESTERS-FACTORY-SEEDED
contract FactoryInvariantTest is BaseTest {
    /// @notice Fhandler.
    FactoryInvariantHandler internal fHandler;

    /// @inheritdoc BaseTest
    function setUp() public override {
        super.setUp();

        fHandler = new FactoryInvariantHandler(factory, address(this));
        targetContract(address(fHandler));
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = fHandler.approveArbitrarySettler.selector;
        selectors[1] = fHandler.revokeArbitrarySettler.selector;
        selectors[2] = fHandler.probeApproveAsStranger.selector;
        selectors[3] = fHandler.probeRenounce.selector;
        targetSelector(FuzzSelector({ addr: address(fHandler), selectors: selectors }));
    }

    /// @notice invariant: rollover contract of mapping stable across non deploy ops.
    function invariant_rolloverContractOfMappingStableAcrossNonDeployOps() public view {
        assertEq(
            factory.rolloverContractOf(cptHolder),
            rolloverContract,
            "LOCK-01: rolloverContractOf must remain stable"
        );

        assertEq(
            factory.rolloverContractOf(address(0xDEAD)),
            address(0),
            "LOCK-01: unknown user maps to 0"
        );
    }

    /// @notice invariant: settler allowlist reflects admin operations only.
    function invariant_settlerAllowlistReflectsAdminOperationsOnly() public view {
        assertTrue(
            factory.isDeployedRolloverContract(rolloverContract),
            "LOCK-02: rolloverContract deployment flag must be unaffected"
        );
    }

    /// @notice invariant: default admin remains constant throughout campaign.
    function invariant_defaultAdminRemainsConstantThroughoutCampaign() public view {
        assertTrue(
            factory.hasRole(factory.DEFAULT_ADMIN_ROLE(), address(this)),
            "LOCK-02: default admin role must remain constant"
        );
    }
}
