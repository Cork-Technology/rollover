// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { NoAsyncResidualHandler } from "../handlers/NoAsyncResidualHandler.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice INV-NO-ASYNC-RESIDUAL-RECOUP — no orphan dstCST is stranded at the settler.
/// @dev fail-on-revert mode (companion at test/invariant/continueOnRevert/NoAsyncResidual.t.sol).
/// @custom:invariant INV-NO-ASYNC-RESIDUAL-RECOUP
contract NoAsyncResidualFailOnRevertTest is BaseTest {
    /// @notice Residual probe handler.
    NoAsyncResidualHandler internal residualHandler;

    /// @inheritdoc BaseTest
    function setUp() public override {
        super.setUp();
        residualHandler = new NoAsyncResidualHandler(address(settler), IERC20(address(dstCst)));
        targetContract(address(residualHandler));
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = residualHandler.observe.selector;
        selectors[1] = residualHandler.warpForward.selector;
        targetSelector(FuzzSelector({ addr: address(residualHandler), selectors: selectors }));
    }

    /// @notice invariant: no orphan dst cst in baseline.
    function invariant_noOrphanDstCstInBaseline() public view {
        assertEq(
            IERC20(address(dstCst)).balanceOf(address(settler)),
            0,
            "INV-NO-ASYNC-RESIDUAL-RECOUP: orphan dstCST stuck at settler"
        );
    }
}
