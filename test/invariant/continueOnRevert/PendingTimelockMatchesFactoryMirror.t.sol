// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { PendingTimelockMirrorHandler } from "../handlers/PendingTimelockMirrorHandler.sol";

/// @notice INV-PENDING-MIRRORS-TIMELOCK — continue-on-revert invariant suite:
///         the factory's `pendingConfig[lastSalt[c]]` view always returns the same
///         threshold/attester shape that the timelock's queued op would execute.
/// @dev Companion at test/invariant/failOnRevert/PendingTimelockMatchesFactoryMirror.t.sol.
/// @custom:invariant INV-PENDING-MIRRORS-TIMELOCK
contract PendingTimelockMatchesFactoryMirrorContinueOnRevertTest is BaseTest {
    /// @notice Handler that randomly queues / cancels / applies trust-config ops.
    PendingTimelockMirrorHandler internal handler;

    /// @inheritdoc BaseTest
    function setUp() public override {
        super.setUp();
        handler = new PendingTimelockMirrorHandler(factory, rolloverContract, cptHolder);
        targetContract(address(handler));
    }

    /// @notice Factory pendingTrustConfig mirror follows the handler's live-op latch.
    function invariant_pendingMirrorMatchesHandlerLatch() public view {
        (uint8 t, address[] memory atts,) = factory.pendingTrustConfig(rolloverContract);
        if (handler.lastQueuedAlive()) {
            assertEq(t, handler.lastQueuedThreshold(), "mirror threshold drift (loose)");
            assertGt(atts.length, 0, "mirror should not be empty while pending op alive (loose)");
        } else {
            assertEq(t, 0, "mirror should be empty after cancel/apply (loose)");
            assertEq(atts.length, 0, "mirror attesters should be empty (loose)");
        }
    }
}
