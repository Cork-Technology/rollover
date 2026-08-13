// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { DstCstReachabilityHandler } from "../handlers/DstCstReachabilityHandler.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice INV-DST-CST-REACHABLE — fail-on-revert invariant suite: every dstCST minted to settler has a reachable claim path.
/// @dev fail-on-revert mode (companion at test/invariant/continueOnRevert/DstCstReachable.t.sol).
/// @custom:invariant INV-DST-CST-REACHABLE
contract DstCstReachableFailOnRevertTest is BaseTest {
    /// @notice Dst handler.
    DstCstReachabilityHandler internal dstHandler;

    /// @inheritdoc BaseTest
    function setUp() public override {
        super.setUp();
        dstHandler = new DstCstReachabilityHandler(
            IERC20(address(dstCst)), address(settler), address(rolloverContract)
        );
        targetContract(address(dstHandler));
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = dstHandler.observe.selector;
        targetSelector(FuzzSelector({ addr: address(dstHandler), selectors: selectors }));
    }

    /// @notice invariant: dst cst conserved.
    function invariant_dstCstConserved() public view {
        assertEq(
            dstHandler.ghostProduced(),
            dstHandler.ghostCredited(),
            "INV-DST-CST-REACHABLE: produced != credited"
        );
    }
}
