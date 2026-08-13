// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { PushAccountingHandler } from "../handlers/PushAccountingHandler.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice F-PUSH — continue-on-revert invariant suite: Settler push-accounting ledger reconciles inflows against payout legs.
/// @dev continue-on-revert mode (companion at test/invariant/failOnRevert/PushAccounting.t.sol).
/// @custom:invariant F-PUSH
contract PushAccountingContinueOnRevertTest is BaseTest {
    /// @notice Push handler.
    PushAccountingHandler internal pushHandler;

    /// @inheritdoc BaseTest
    function setUp() public override {
        super.setUp();
        pushHandler = new PushAccountingHandler(IERC20(address(srcCst)), address(settler));
        targetContract(address(pushHandler));
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = pushHandler.observe.selector;
        selectors[1] = pushHandler.warpForward.selector;
        targetSelector(FuzzSelector({ addr: address(pushHandler), selectors: selectors }));
    }

    /// @notice invariant: settler src cst stays at ghost net.
    function invariant_settlerSrcCstStaysAtGhostNet() public view {
        uint256 live = IERC20(address(srcCst)).balanceOf(address(settler));
        uint256 inAmt = pushHandler.ghostSrcCstIntoSettler();
        uint256 outAmt = pushHandler.ghostSrcCstOutOfSettler();
        assertGe(inAmt, outAmt, "F-PUSH: ghost-out exceeds ghost-in (loose)");
        assertEq(live, inAmt - outAmt, "F-PUSH: settler srcCST drift (loose)");
    }
}
