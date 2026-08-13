// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice CorkRolloverContractFactoryStrengthenedTest — pins CorkRolloverContractFactoryStrengthened behaviour for the Cork Rollover suite.
contract CorkRolloverContractFactoryStrengthenedTest is BaseTest {
    // effectRolloverPeriod / setRolloverPeriod tests were removed with the
    // rolloverPeriod governance surface. Selector-removal pins live in
    // test/audit-cleanup/RolloverPeriodSurfaceRemoved.t.sol.

    /// @notice Phoenix-style owner renounce clears only the deployment identity.
    function test_renounceOwnershipWithRevokedSettlerOnlyClearsOwnerIdentity() public {
        factory.revokeSettler(address(settler));
        vm.prank(manager);
        factory.renounceOwnership();
        assertEq(factory.owner(), address(0), "owner identity cleared");
        assertTrue(
            factory.hasRole(factory.DEFAULT_ADMIN_ROLE(), address(this)), "protocol admin retained"
        );
    }

    /// @notice Non-owner callers cannot renounce the Phoenix-style owner identity.
    function testRevert_renounceOwnershipByNonOwnerReverts() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, anyone));
        vm.prank(anyone);
        factory.renounceOwnership();
    }
}
