// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { ApprovedSettlerHandler } from "../handlers/ApprovedSettlerHandler.sol";

/// @notice INV-SETTLER-APPROVED — continue-on-revert invariant suite: factory settler allowlist authoritatively gates rolloverContract.executeIntentHooks.
/// @dev continue-on-revert mode (companion at test/invariant/failOnRevert/SettlerApproved.t.sol).
/// @custom:invariant INV-SETTLER-APPROVED
contract SettlerApprovedContinueOnRevertTest is BaseTest {
    /// @notice H.
    ApprovedSettlerHandler internal h;

    /// @inheritdoc BaseTest
    function setUp() public override {
        super.setUp();
        h = new ApprovedSettlerHandler(factory, address(this));
        targetContract(address(h));
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = h.approveArbitrary.selector;
        selectors[1] = h.revokeArbitrary.selector;
        selectors[2] = h.approveAsStranger.selector;
        targetSelector(FuzzSelector({ addr: address(h), selectors: selectors }));
    }

    /// @notice invariant: ghost mirror matches live allowlist.
    function invariant_ghostMirrorMatchesLiveAllowlist() public view {
        uint256 n = h.probedCount();
        for (uint256 i = 0; i < n; ++i) {
            address s = h.probed(i);
            assertEq(
                h.factoryRef().approvedSettlers(s),
                h.expectedApproved(s),
                "INV-SETTLER-APPROVED: ghost mirror drift"
            );
        }
    }
}
