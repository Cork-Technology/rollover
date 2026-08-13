// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { DefaulterReclaimHandler } from "../handlers/DefaulterReclaimHandler.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice INV-DEFAULTER-RECOUP — continue-on-revert invariant suite: no orphan defaulter dstCST is stranded at the settler.
/// @dev continue-on-revert mode (companion at test/invariant/failOnRevert/DefaulterRecoup.t.sol).
/// @custom:invariant INV-DEFAULTER-RECOUP
contract DefaulterRecoupContinueOnRevertTest is BaseTest {
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

    /// @notice invariant: settler dst cst stays zero across bounded ops.
    function invariant_settlerDstCstStaysZeroAcrossBoundedOps() public view {
        assertEq(
            IERC20(address(dstCst)).balanceOf(address(settler)),
            0,
            "INV-DEFAULTER-RECOUP: dstCST stranded at settler"
        );
    }
}
