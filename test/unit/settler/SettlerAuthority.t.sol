// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExactSettler as Settler } from "src/ExactSettler.sol";

/// @notice SettlerAuthorityTest — pins SettlerAuthority behaviour for the Cork Rollover suite.
contract SettlerAuthorityTest is BaseTest {
    /// @notice Default admin role.
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    /// @notice AccessControl role allowed to pause the Settler.

    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    /// @notice AccessControl role allowed to unpause the Settler.

    bytes32 internal constant UNPAUSER_ROLE = keccak256("UNPAUSER_ROLE");
    /// @notice AccessControl role allowed to recover non-liability-backed tokens.
    bytes32 internal constant RECOVERY_ROLE = keccak256("RECOVERY_ROLE");
    /// @notice Roleless deployer.

    address internal rolelessDeployer = address(0xD0);
    /// @notice Phoenix-style owner identity.
    address internal ensOwnerAuthority = address(0xE450);
    /// @notice Default admin authority.
    address internal adminAuthority = address(0xAD);
    /// @notice Pause authority.
    address internal pauseAuthority = address(0xAA);
    /// @notice Unpause authority.
    address internal unpauseAuthority = address(0xBB);
    /// @notice Operator.

    address internal operator = address(0x0A);

    /// @notice Pins behaviour: constructor grants explicit role authorities, not deployer.
    function test_constructor_grantsExplicitAuthoritiesNotDeployer() public {
        vm.startPrank(rolelessDeployer);
        Settler ownedSettler = new Settler(
            address(factory),
            address(this),
            ensOwnerAuthority,
            adminAuthority,
            pauseAuthority,
            unpauseAuthority
        );
        vm.stopPrank();

        assertEq(ownedSettler.owner(), ensOwnerAuthority, "ens owner");
        assertTrue(ownedSettler.hasRole(DEFAULT_ADMIN_ROLE, adminAuthority), "admin");
        assertTrue(ownedSettler.hasRole(RECOVERY_ROLE, adminAuthority), "recovery");
        assertTrue(ownedSettler.hasRole(PAUSER_ROLE, pauseAuthority), "pauser");
        assertTrue(ownedSettler.hasRole(UNPAUSER_ROLE, unpauseAuthority), "unpauser");
        assertFalse(ownedSettler.hasRole(DEFAULT_ADMIN_ROLE, ensOwnerAuthority), "owner admin");
        assertFalse(ownedSettler.hasRole(RECOVERY_ROLE, ensOwnerAuthority), "owner recovery");
        assertFalse(ownedSettler.hasRole(PAUSER_ROLE, ensOwnerAuthority), "owner pauser");
        assertFalse(ownedSettler.hasRole(UNPAUSER_ROLE, ensOwnerAuthority), "owner unpauser");
        assertFalse(ownedSettler.hasRole(DEFAULT_ADMIN_ROLE, rolelessDeployer), "deployer admin");
        assertFalse(ownedSettler.hasRole(RECOVERY_ROLE, rolelessDeployer), "deployer recovery");
        assertFalse(ownedSettler.hasRole(PAUSER_ROLE, rolelessDeployer), "deployer pauser");
        assertFalse(ownedSettler.hasRole(UNPAUSER_ROLE, rolelessDeployer), "deployer unpauser");
    }

    /// @notice Pins behaviour: admin manages roles while pause authorities operate the switch.
    function test_explicitAuthoritiesAdministerAndUsePauseRoles() public {
        vm.startPrank(rolelessDeployer);
        Settler ownedSettler = new Settler(
            address(factory),
            address(this),
            ensOwnerAuthority,
            adminAuthority,
            pauseAuthority,
            unpauseAuthority
        );
        vm.stopPrank();

        vm.prank(adminAuthority);
        ownedSettler.grantRole(PAUSER_ROLE, operator);
        assertTrue(ownedSettler.hasRole(PAUSER_ROLE, operator), "operator pauser");

        vm.prank(operator);
        ownedSettler.pause();

        vm.prank(unpauseAuthority);
        ownedSettler.unpause();

        vm.prank(adminAuthority);
        ownedSettler.revokeRole(PAUSER_ROLE, operator);
        assertFalse(ownedSettler.hasRole(PAUSER_ROLE, operator), "operator revoked");
    }

    /// @notice Pins behaviour: roleless deployer does not inherit role powers.
    function test_deployerCannotAdministerOrPauseWhenRolesDiffer() public {
        vm.startPrank(rolelessDeployer);
        Settler ownedSettler = new Settler(
            address(factory),
            address(this),
            ensOwnerAuthority,
            adminAuthority,
            pauseAuthority,
            unpauseAuthority
        );
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                rolelessDeployer,
                DEFAULT_ADMIN_ROLE
            )
        );
        vm.prank(rolelessDeployer);
        ownedSettler.grantRole(PAUSER_ROLE, operator);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                rolelessDeployer,
                PAUSER_ROLE
            )
        );
        vm.prank(rolelessDeployer);
        ownedSettler.pause();
    }

    /// @notice Pins behaviour: ownership transfers without migrating protocol roles.
    function test_transferOwnership_updatesOwnerWithoutGrantingRoles() public {
        Settler ownedSettler = new Settler(
            address(factory),
            address(this),
            ensOwnerAuthority,
            adminAuthority,
            pauseAuthority,
            unpauseAuthority
        );
        address newOwner = address(0xB0B);

        vm.prank(ensOwnerAuthority);
        ownedSettler.transferOwnership(newOwner);

        assertEq(ownedSettler.owner(), newOwner, "owner transferred");
        assertFalse(ownedSettler.hasRole(DEFAULT_ADMIN_ROLE, newOwner), "new owner admin");
        assertFalse(ownedSettler.hasRole(RECOVERY_ROLE, newOwner), "new owner recovery");
        assertFalse(ownedSettler.hasRole(PAUSER_ROLE, newOwner), "new owner pauser");
        assertFalse(ownedSettler.hasRole(UNPAUSER_ROLE, newOwner), "new owner unpauser");
        assertTrue(ownedSettler.hasRole(DEFAULT_ADMIN_ROLE, adminAuthority), "admin retained");
        assertTrue(ownedSettler.hasRole(RECOVERY_ROLE, adminAuthority), "recovery retained");
        assertTrue(ownedSettler.hasRole(PAUSER_ROLE, pauseAuthority), "pauser retained");
        assertTrue(ownedSettler.hasRole(UNPAUSER_ROLE, unpauseAuthority), "unpauser retained");
    }

    /// @notice Pins behaviour: Ownable renounce does not revoke AccessControl authorities.
    function test_renounceOwnership_clearsOwnerWithoutRevokingRoles() public {
        Settler ownedSettler = new Settler(
            address(factory),
            address(this),
            ensOwnerAuthority,
            adminAuthority,
            pauseAuthority,
            unpauseAuthority
        );

        vm.prank(ensOwnerAuthority);
        ownedSettler.renounceOwnership();

        assertEq(ownedSettler.owner(), address(0), "owner cleared");
        assertTrue(ownedSettler.hasRole(DEFAULT_ADMIN_ROLE, adminAuthority), "admin retained");
        assertTrue(ownedSettler.hasRole(RECOVERY_ROLE, adminAuthority), "recovery retained");
        assertTrue(ownedSettler.hasRole(PAUSER_ROLE, pauseAuthority), "pauser retained");
        assertTrue(ownedSettler.hasRole(UNPAUSER_ROLE, unpauseAuthority), "unpauser retained");
    }
}
