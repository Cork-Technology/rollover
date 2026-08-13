// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { RolloverContractRolloverHandler } from "../handlers/RolloverContractRolloverHandler.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice INV-CPT-CONTAINED — fail-on-revert invariant suite: rolloverContract holds zero srcCPT/dstCPT across a rollover bracket.
/// @dev fail-on-revert mode (companion at test/invariant/continueOnRevert/RolloverContractCptContained.t.sol).
/// @custom:invariant INV-CPT-CONTAINED
contract RolloverContractCptContainedFailOnRevertTest is BaseTest {
    /// @notice Cpt handler.
    RolloverContractRolloverHandler internal cptHandler;

    /// @inheritdoc BaseTest
    function setUp() public override {
        super.setUp();
        cptHandler = new RolloverContractRolloverHandler(
            rolloverContract, IERC20(address(srcCpt)), IERC20(address(dstCpt))
        );
        targetContract(address(cptHandler));
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = cptHandler.observe.selector;
        selectors[1] = cptHandler.warpForward.selector;
        targetSelector(FuzzSelector({ addr: address(cptHandler), selectors: selectors }));
    }

    /// @notice invariant: rolloverContract holds zero cpt.
    function invariant_rolloverContractHoldsZeroCpt() public view {
        assertEq(
            IERC20(address(srcCpt)).balanceOf(rolloverContract),
            0,
            "INV-CPT-CONTAINED: rolloverContract holds residual srcCPT"
        );
        assertEq(
            IERC20(address(dstCpt)).balanceOf(rolloverContract),
            0,
            "INV-CPT-CONTAINED: rolloverContract holds residual dstCPT"
        );
    }
}
