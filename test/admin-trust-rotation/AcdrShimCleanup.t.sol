// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IAccessControl } from "lib/openzeppelin-contracts/contracts/access/IAccessControl.sol";
import { BaseTest } from "test/base/BaseTest.sol";

/// @notice AcdrShimCleanupTest — pins removal of factory ACDR primitives plus the
///         Phoenix-style owner identity / AccessControl admin split.
contract AcdrShimCleanupTest is BaseTest {
    /// @notice Candidate new admin used by the end-to-end transfer-flow test.
    address internal newAdmin = address(0xBABE);

    /// @notice `owner()` is a Phoenix-style deployment identity, not protocol admin authority.
    function test_owner_PhoenixIdentity_DiffersFromRoleAdmin() public view {
        bytes32 adminRole = factory.DEFAULT_ADMIN_ROLE();
        assertEq(factory.owner(), manager, "owner is deployment identity");
        assertTrue(factory.hasRole(adminRole, address(this)), "default admin role holder");
        assertFalse(factory.hasRole(adminRole, manager), "owner is not role admin");
        assertNotEq(factory.owner(), address(this), "owner/admin split must be visible");
    }

    /// @notice The `pendingOwner()` shim selector is no longer present.
    function test_pendingOwner_SelectorRemoved() public view {
        (bool ok, bytes memory ret) =
            address(factory).staticcall(abi.encodeWithSignature("pendingOwner()"));
        require(
            !(ok && ret.length == 32),
            "pendingOwner() shim must be removed; use AccessControl roles"
        );
    }

    /// @notice The ACDR `defaultAdmin()` selector is no longer present.
    function test_defaultAdmin_SelectorRemoved() public view {
        (bool ok, bytes memory ret) =
            address(factory).staticcall(abi.encodeWithSignature("defaultAdmin()"));
        require(!(ok && ret.length == 32), "defaultAdmin() selector must be removed");
    }

    /// @notice The ACDR `pendingDefaultAdmin()` selector is no longer present.
    function test_pendingDefaultAdmin_SelectorRemoved() public view {
        (bool ok, bytes memory ret) =
            address(factory).staticcall(abi.encodeWithSignature("pendingDefaultAdmin()"));
        require(!(ok && ret.length == 64), "pendingDefaultAdmin() selector must be removed");
    }

    /// @notice The `beginOwnershipTransfer(address)` shim selector is no longer present.
    function test_beginOwnershipTransfer_SelectorRemoved() public {
        (bool ok,) = address(factory)
            .call(abi.encodeWithSignature("beginOwnershipTransfer(address)", newAdmin));
        require(
            !ok, "beginOwnershipTransfer(address) shim must be removed; use grantRole/revokeRole"
        );
    }

    /// @notice The ACDR `beginDefaultAdminTransfer(address)` selector is no longer present.
    function test_beginDefaultAdminTransfer_SelectorRemoved() public {
        (bool ok,) = address(factory)
            .call(abi.encodeWithSignature("beginDefaultAdminTransfer(address)", newAdmin));
        require(!ok, "beginDefaultAdminTransfer(address) selector must be removed");
    }

    /// @notice The `acceptOwnership()` shim selector is no longer present.
    function test_acceptOwnership_SelectorRemoved() public {
        (bool ok,) = address(factory).call(abi.encodeWithSignature("acceptOwnership()"));
        require(!ok, "acceptOwnership() shim must be removed; use grantRole/revokeRole");
    }

    /// @notice The ACDR `acceptDefaultAdminTransfer()` selector is no longer present.
    function test_acceptDefaultAdminTransfer_SelectorRemoved() public {
        (bool ok,) = address(factory).call(abi.encodeWithSignature("acceptDefaultAdminTransfer()"));
        require(!ok, "acceptDefaultAdminTransfer() selector must be removed");
    }

    /// @notice The Phoenix-style owner identity does not inherit factory admin authority.
    function test_ownerIdentityCannotUseAdminControls() public {
        bytes32 revokerRole = factory.SETTLER_REVOKER_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, manager, revokerRole
            )
        );
        vm.prank(manager);
        factory.revokeSettler(address(settler));

        factory.revokeSettler(address(settler));
        assertFalse(factory.approvedSettlers(address(settler)), "role admin can revoke");
    }

    /// @notice End-to-end role-admin rotation uses plain AccessControl grant/revoke.
    function test_DefaultAdminRoleRotation_ViaAccessControl_StillWorks() public {
        bytes32 adminRole = factory.DEFAULT_ADMIN_ROLE();
        bytes32 revokerRole = factory.SETTLER_REVOKER_ROLE();
        factory.grantRole(adminRole, newAdmin);
        assertTrue(factory.hasRole(adminRole, newAdmin), "new admin granted");

        vm.prank(newAdmin);
        factory.grantRole(revokerRole, newAdmin);
        vm.prank(newAdmin);
        factory.revokeRole(revokerRole, address(this));

        vm.prank(newAdmin);
        factory.revokeRole(adminRole, address(this));

        assertFalse(factory.hasRole(adminRole, address(this)), "old admin revoked");
        assertTrue(factory.hasRole(adminRole, newAdmin), "new admin retained");

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), revokerRole
            )
        );
        factory.revokeSettler(address(settler));

        vm.prank(newAdmin);
        factory.revokeSettler(address(settler));
        assertFalse(factory.approvedSettlers(address(settler)), "new admin has authority");
    }
}
