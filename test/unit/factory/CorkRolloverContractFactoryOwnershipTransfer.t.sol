// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { IAccessControl } from "lib/openzeppelin-contracts/contracts/access/IAccessControl.sol";
import { CorkRolloverContractFactory } from "src/CorkRolloverContractFactory.sol";
import { BaseTest } from "test/base/BaseTest.sol";

/// @notice CorkRolloverContractFactoryOwnershipTransferTest — pins factory AccessControl admin rotation.
contract CorkRolloverContractFactoryOwnershipTransferTest is BaseTest {
    /// @notice New default admin.
    address internal newAdmin = address(0xBABE);

    /// @notice Pins behaviour: non-admin cannot grant the default admin role.
    function test_GrantDefaultAdminByNonAdminReverts() public {
        bytes32 adminRole = factory.DEFAULT_ADMIN_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, anyone, adminRole
            )
        );
        vm.prank(anyone);
        factory.grantRole(adminRole, newAdmin);
    }

    /// @notice Pins behaviour: default admin role can be granted immediately.
    function test_GrantDefaultAdminRole() public {
        bytes32 adminRole = factory.DEFAULT_ADMIN_ROLE();
        factory.grantRole(adminRole, newAdmin);
        assertTrue(factory.hasRole(adminRole, newAdmin), "new admin granted");
    }

    /// @notice Pins behaviour: post-grant/revoke default-admin authority shifted.
    function test_PostRoleRotationDefaultAdminAuthorityShifted() public {
        bytes32 adminRole = factory.DEFAULT_ADMIN_ROLE();
        factory.grantRole(adminRole, newAdmin);
        vm.prank(newAdmin);
        factory.revokeRole(adminRole, address(this));

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), adminRole
            )
        );
        factory.grantRole(adminRole, address(0xDEAD));

        vm.prank(newAdmin);
        factory.grantRole(adminRole, address(0xCAFE));
        assertTrue(factory.hasRole(adminRole, address(0xCAFE)), "new admin has authority");
    }
}
