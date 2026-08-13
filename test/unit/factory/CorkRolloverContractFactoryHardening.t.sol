// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { CorkRolloverContractFactory } from "src/CorkRolloverContractFactory.sol";

/// @notice CorkRolloverContractFactoryHardeningTest — pins CorkRolloverContractFactoryHardening behaviour for the Cork Rollover suite.
contract CorkRolloverContractFactoryHardeningTest is BaseTest {
    /// @notice Access control bad confirmation.
    bytes4 internal constant ACCESS_CONTROL_BAD_CONFIRMATION =
        bytes4(keccak256("AccessControlBadConfirmation()"));

    /// @notice Pins behaviour: default admin follows inherited AccessControl self-renounce.
    function test_defaultAdminCanSelfRenounce() public {
        bytes32 adminRole = factory.DEFAULT_ADMIN_ROLE();
        assertTrue(factory.hasRole(adminRole, address(this)), "default admin before");

        factory.renounceRole(adminRole, address(this));

        assertFalse(factory.hasRole(adminRole, address(this)), "default admin renounced");
    }

    /// @notice Pins behaviour: non Default Role Holder Can Self Renounce.
    function test_nonDefaultRoleHolderCanSelfRenounce() public {
        bytes32 futureRole = keccak256("FUTURE_ROLE");
        address operator = makeAddr("operator");

        factory.grantRole(futureRole, operator);
        assertTrue(factory.hasRole(futureRole, operator), "role granted");

        vm.prank(operator);
        factory.renounceRole(futureRole, operator);

        assertFalse(factory.hasRole(futureRole, operator), "role renounced");
    }

    /// @notice Pins behaviour: reverts when non Default Role Cannot Be Renounced For Another Account.
    function testRevert_nonDefaultRoleCannotBeRenouncedForAnotherAccount() public {
        bytes32 futureRole = keccak256("FUTURE_ROLE");
        address operator = makeAddr("operator");
        address attacker = makeAddr("attacker");

        factory.grantRole(futureRole, operator);

        vm.prank(attacker);
        vm.expectRevert(ACCESS_CONTROL_BAD_CONFIRMATION);
        factory.renounceRole(futureRole, operator);
    }

    // setRolloverPeriod / effectRolloverPeriod / protocolConfig tests were removed with
    // the rolloverPeriod governance surface and ProtocolConfig lens entry.
    // Selector-removal pins live in test/audit-cleanup/RolloverPeriodSurfaceRemoved.t.sol.
}
