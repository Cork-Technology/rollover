// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { ApproveModuleNoResidualHandler } from "../handlers/ApproveModuleNoResidualHandler.sol";
import { Test } from "forge-std/Test.sol";

/// @notice INV-APPROVE-MODULE-NO-RESIDUAL — continue-on-revert invariant suite:
///         delegate-invoked ApproveModule.execute leaves no host-to-spender residual allowance.
/// @dev Companion at test/invariant/failOnRevert/ApproveModuleNoResidual.t.sol.
/// @custom:invariant INV-APPROVE-MODULE-NO-RESIDUAL
contract ApproveModuleNoResidualContinueOnRevertTest is Test {
    /// @notice Handler under test.
    ApproveModuleNoResidualHandler internal handler;

    /// @notice Wire the handler and targeted selectors.
    function setUp() public {
        handler = new ApproveModuleNoResidualHandler();
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.executeBracket.selector;
        selectors[1] = handler.executeZeroSpender.selector;
        selectors[2] = handler.observeAllPairs.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    /// @notice No observed token/spender pair may retain allowance after a module execution.
    /// @custom:invariant INV-APPROVE-MODULE-NO-RESIDUAL
    function invariant_noResidualAllowanceAfterApproveModule() public view {
        assertFalse(
            handler.residualAllowanceObserved(),
            "INV-APPROVE-MODULE-NO-RESIDUAL: residual allowance observed"
        );
    }
}
