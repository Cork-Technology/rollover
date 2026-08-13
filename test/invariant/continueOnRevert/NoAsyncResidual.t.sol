// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { NoAsyncResidualHandler } from "../handlers/NoAsyncResidualHandler.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice INV-NO-ASYNC-RESIDUAL-RECOUP — no orphan dstCST is stranded at the settler.
/// @dev continue-on-revert mode (companion at test/invariant/failOnRevert/NoAsyncResidual.t.sol).
/// @custom:invariant INV-NO-ASYNC-RESIDUAL-RECOUP
contract NoAsyncResidualContinueOnRevertTest is BaseTest {
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

    /// @notice invariant: settler dst cst stays zero across bounded ops.
    function invariant_settlerDstCstStaysZeroAcrossBoundedOps() public view {
        assertEq(
            IERC20(address(dstCst)).balanceOf(address(settler)),
            0,
            "INV-NO-ASYNC-RESIDUAL-RECOUP: dstCST stranded at settler"
        );
    }
}
