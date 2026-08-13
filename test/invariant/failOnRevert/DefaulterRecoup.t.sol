// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { DefaulterReclaimHandler } from "../handlers/DefaulterReclaimHandler.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice INV-DEFAULTER-RECOUP — fail-on-revert invariant suite: no orphan defaulter dstCST is stranded at the settler.
/// @dev fail-on-revert mode (companion at test/invariant/continueOnRevert/DefaulterRecoup.t.sol).
/// @custom:invariant INV-DEFAULTER-RECOUP
contract DefaulterRecoupFailOnRevertTest is BaseTest {
    /// @notice Defaulter handler.
    DefaulterReclaimHandler internal defaulterHandler;

    /// @inheritdoc BaseTest
    function setUp() public override {
        super.setUp();
        defaulterHandler = new DefaulterReclaimHandler(address(settler), IERC20(address(dstCst)));
        targetContract(address(defaulterHandler));
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = defaulterHandler.observe.selector;
        selectors[1] = defaulterHandler.warpForward.selector;
        targetSelector(FuzzSelector({ addr: address(defaulterHandler), selectors: selectors }));
    }

    /// @notice invariant: no orphan defaulter dst cst in baseline.
    function invariant_noOrphanDefaulterDstCstInBaseline() public view {
        assertEq(
            IERC20(address(dstCst)).balanceOf(address(settler)),
            0,
            "INV-DEFAULTER-RECOUP: orphan defaulter dstCST stuck at settler"
        );
    }
}
