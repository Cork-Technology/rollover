// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { SettlerPauseHandler } from "../handlers/SettlerPauseHandler.sol";

/// @notice INV-PAUSE-GATES-ALL-ENTRYPOINTS — fail-on-revert invariant suite: every external state-changing Settler entrypoint is gated by whenNotPaused.
/// @dev fail-on-revert mode (companion at test/invariant/continueOnRevert/SettlerPauseGates.t.sol).
/// @custom:invariant INV-PAUSE-GATES-ALL-ENTRYPOINTS
contract SettlerPauseGatesFailOnRevertTest is BaseTest {
    /// @notice Pause handler.
    SettlerPauseHandler internal pauseHandler;

    /// @inheritdoc BaseTest
    function setUp() public override {
        super.setUp();
        pauseHandler = new SettlerPauseHandler(settler, address(this), address(this));
        targetContract(address(pauseHandler));
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = pauseHandler.doPause.selector;
        selectors[1] = pauseHandler.doUnpause.selector;
        selectors[2] = pauseHandler.probeOpen.selector;
        selectors[3] = pauseHandler.probeOpenFor.selector;
        selectors[4] = pauseHandler.probeFill.selector;
        selectors[5] = pauseHandler.probeReclaim.selector;
        selectors[6] = pauseHandler.probeMarkExpired.selector;
        selectors[7] = pauseHandler.probeCancel.selector;
        selectors[8] = pauseHandler.probeViews.selector;
        targetSelector(FuzzSelector({ addr: address(pauseHandler), selectors: selectors }));
    }

    /// @notice invariant: no accepted call while paused.
    function invariant_noAcceptedCallWhilePaused() public view {
        assertFalse(
            pauseHandler.acceptedAnyCallWhilePaused(),
            "INV-PAUSE-GATES-ALL-ENTRYPOINTS: entrypoint accepted call while paused"
        );
    }

    /// @notice invariant: views reachable while paused.
    function invariant_viewsReachableWhilePaused() public view {
        assertFalse(
            pauseHandler.viewBlockedWhilePaused(),
            "INV-PAUSE-GATES-ALL-ENTRYPOINTS: view reverted while paused"
        );
    }
}
