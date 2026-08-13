// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { PendingTimelockMirrorHandler } from "../handlers/PendingTimelockMirrorHandler.sol";

/// @notice INV-PENDING-MIRRORS-TIMELOCK — the factory's `pendingConfig[lastSalt[c]]` view
///         always returns the same (threshold, attesters) that the timelock's queued op
///         would execute. After any queue/cancel/apply sequence, the mirror state is
///         either (a) cleared (no live op) or (b) reflects the most recent queue.
contract PendingTimelockMatchesFactoryMirrorTest is BaseTest {
    /// @notice Handler that randomly queues / cancels / applies trust-config ops.
    PendingTimelockMirrorHandler internal handler;

    /// @inheritdoc BaseTest
    function setUp() public override {
        super.setUp();
        handler = new PendingTimelockMirrorHandler(factory, rolloverContract, cptHolder);
        targetContract(address(handler));
    }

    /// @notice After any sequence, if the handler's `lastQueuedAlive` flag is set, the
    ///         factory's pendingTrustConfig view returns the matching (threshold, attesters).
    ///         When `lastQueuedAlive == false`, the mirror returns a zero tuple.
    function invariant_pendingMirrorMatchesHandlerLatch() public view {
        (uint8 t, address[] memory atts,) = factory.pendingTrustConfig(rolloverContract);
        if (handler.lastQueuedAlive()) {
            assertEq(t, handler.lastQueuedThreshold(), "mirror threshold drift");
            assertGt(atts.length, 0, "mirror should not be empty while pending op alive");
        } else {
            assertEq(t, 0, "mirror should be empty after cancel/apply");
            assertEq(atts.length, 0, "mirror attesters should be empty");
        }
    }
}
