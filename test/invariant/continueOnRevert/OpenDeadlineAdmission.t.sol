// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { OpenDeadlineInvariantBase } from "../OpenDeadlineInvariantBase.sol";

/// @notice INV-OPENDEADLINE-ADMISSION-CEILING — continue-on-revert invariant suite:
///         no path may admit a None-status order after its signed openDeadline.
/// @dev continue-on-revert mode (companion at test/invariant/failOnRevert/OpenDeadlineAdmission.t.sol).
/// @custom:invariant INV-OPENDEADLINE-ADMISSION-CEILING
contract OpenDeadlineAdmissionContinueOnRevertTest is OpenDeadlineInvariantBase {
    /// @notice Sets up the active open-deadline admission invariant handler.
    function setUp() public override {
        super.setUp();
        _setUpOpenDeadlineInvariant();
    }

    /// @notice invariant: post-openDeadline admissions never accept or change status.
    function invariant_openDeadline_postDeadlineAdmissionsDoNotTransition() public view {
        assertFalse(
            openDeadlineHandler.postDeadlineAdmissionViolated(),
            "INV-OPENDEADLINE-ADMISSION-CEILING: post-deadline admission accepted (loose)"
        );
    }

    /// @notice invariant: handler-authored pre-deadline admissions should not reject.
    function invariant_openDeadline_preDeadlineAdmissionsAccepted() public view {
        assertFalse(
            openDeadlineHandler.unexpectedPreDeadlineReject(),
            "INV-OPENDEADLINE-ADMISSION-CEILING: pre-deadline admission unexpectedly rejected (loose)"
        );
    }
}
