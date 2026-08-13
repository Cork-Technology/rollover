// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { FillerSettledStickyHandler } from "../handlers/FillerSettledStickyHandler.sol";

/// @notice N-INV-FILLER-SETTLED-STICKY — fail-on-revert invariant suite: per-filler settled flag is monotone — never flips back to false.
/// @dev fail-on-revert mode (companion at test/invariant/continueOnRevert/FillerSettledSticky.t.sol).
/// @custom:invariant N-INV-FILLER-SETTLED-STICKY
contract FillerSettledStickyFailOnRevertTest is BaseTest {
    /// @notice Sticky handler.
    FillerSettledStickyHandler internal stickyHandler;

    /// @inheritdoc BaseTest
    function setUp() public override {
        super.setUp();
        stickyHandler = new FillerSettledStickyHandler(partialSettler);
        targetContract(address(stickyHandler));
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = stickyHandler.registerTuple.selector;
        selectors[1] = stickyHandler.observeTuple.selector;
        selectors[2] = stickyHandler.warpForward.selector;
        targetSelector(FuzzSelector({ addr: address(stickyHandler), selectors: selectors }));
    }

    /// @notice invariant: settled latch is sticky.
    function invariant_settledLatchIsSticky() public view {
        assertFalse(
            stickyHandler.stickinessViolated(),
            "N-INV-FILLER-SETTLED-STICKY: fillerSettled regressed from true to false"
        );
    }

    /// @notice invariant: no double payout per filler.
    function invariant_noDoublePayoutPerFiller() public view {
        assertFalse(
            stickyHandler.doublePayoutViolated(),
            "N-INV-FILLER-SETTLED-STICKY: same (orderId, filler) paid twice"
        );
    }
}
