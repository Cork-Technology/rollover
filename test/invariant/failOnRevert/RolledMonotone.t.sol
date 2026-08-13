// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { RolledMonotoneHandler } from "../handlers/RolledMonotoneHandler.sol";
import { ICorkRolloverContract } from "src/interfaces/rollover/ICorkRolloverContract.sol";

/// @notice N-INV-ROLLED-MONOTONE-AND-BOUNDED — fail-on-revert invariant suite: rolled-quantity ledger is monotone non-decreasing and bounded by orderSize.
/// @dev fail-on-revert mode (companion at test/invariant/continueOnRevert/RolledMonotone.t.sol).
/// @custom:invariant N-INV-ROLLED-MONOTONE-AND-BOUNDED
contract RolledMonotoneFailOnRevertTest is BaseTest {
    /// @notice Rolled handler.
    RolledMonotoneHandler internal rolledHandler;

    /// @inheritdoc BaseTest
    function setUp() public override {
        super.setUp();
        rolledHandler = new RolledMonotoneHandler(ICorkRolloverContract(rolloverContract));
        targetContract(address(rolledHandler));
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = rolledHandler.registerOrderId.selector;
        selectors[1] = rolledHandler.observeOrderState.selector;
        selectors[2] = rolledHandler.setOrderSize.selector;
        selectors[3] = rolledHandler.warpForward.selector;
        targetSelector(FuzzSelector({ addr: address(rolledHandler), selectors: selectors }));
    }

    /// @notice invariant: rolled is monotone.
    function invariant_rolledIsMonotone() public view {
        assertFalse(
            rolledHandler.monotoneViolated(),
            "N-INV-ROLLED-MONOTONE-AND-BOUNDED: rolled accumulator decreased"
        );
    }

    /// @notice invariant: rolled bounded by order size.
    function invariant_rolledBoundedByOrderSize() public view {
        assertFalse(
            rolledHandler.boundViolated(),
            "N-INV-ROLLED-MONOTONE-AND-BOUNDED: rolled exceeded orderSize bound"
        );
    }

    /// @notice invariant: terminal bit is sticky.
    function invariant_terminalBitIsSticky() public view {
        assertFalse(
            rolledHandler.terminalBitCleared(),
            "N-INV-ROLLED-MONOTONE-AND-BOUNDED: terminal bit regressed from set to unset"
        );
    }
}
