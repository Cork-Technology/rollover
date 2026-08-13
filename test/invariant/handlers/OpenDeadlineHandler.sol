// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { CommonBase } from "forge-std/Base.sol";
import { StdCheats } from "forge-std/StdCheats.sol";
import { StdUtils } from "forge-std/StdUtils.sol";

/// @notice Suite-owned driver for open-deadline admission probes.
interface IOpenDeadlineDriver {
    /// @notice Drive one admission attempt around a fuzzed `openDeadline`.
    /// @param saltSeed Fuzz seed mixed into the order salt.
    /// @param deadlineSeed Fuzz seed for the open-deadline offset.
    /// @param warpSeed Fuzz seed for the warp offset from order creation.
    /// @param pathSeed Fuzz seed selecting open/openFor/direct-fill.
    /// @param isPartial True to use PartialSettler, false to use ExactSettler.
    /// @return accepted True if the admission call returned without reverting.
    /// @return shouldAdmit True if the call was not past `openDeadline`.
    /// @return statusBefore Order status before the admission attempt.
    /// @return statusAfter Order status after the admission attempt.
    function driveOpenDeadlineAdmission(
        uint256 saltSeed,
        uint64 deadlineSeed,
        uint64 warpSeed,
        uint8 pathSeed,
        bool isPartial
    ) external returns (bool accepted, bool shouldAdmit, uint8 statusBefore, uint8 statusAfter);
}

/// @notice INV-OPENDEADLINE-ADMISSION-CEILING handler — fuzzes `open`, `openFor`,
///         and direct-fill admission around `openDeadline` for exact and partial modes.
/// @custom:invariant INV-OPENDEADLINE-ADMISSION-CEILING
contract OpenDeadlineHandler is CommonBase, StdCheats, StdUtils {
    /// @notice End-to-end deadline driver implemented by the invariant suite.
    /// @return driver Stored driver.
    IOpenDeadlineDriver public immutable driver;

    /// @notice Violation flag for any post-openDeadline admission acceptance or status change.
    /// @return postDeadlineAdmissionViolated True if the deadline ceiling was falsified.
    bool public postDeadlineAdmissionViolated;
    /// @notice Unexpected reject flag for a pre-deadline handler-authored admission.
    /// @return unexpectedPreDeadlineReject True if a valid pre-deadline admission rejected.
    bool public unexpectedPreDeadlineReject;
    /// @notice Count of pre-deadline admissions accepted by the Settler.
    /// @return ghostPreDeadlineAccepted Stored counter.
    uint64 public ghostPreDeadlineAccepted;
    /// @notice Count of post-deadline admissions rejected by the Settler.
    /// @return ghostPostDeadlineRejected Stored counter.
    uint64 public ghostPostDeadlineRejected;
    /// @notice Count of post-deadline admissions accepted by the Settler.
    /// @return ghostPostDeadlineAccepted Stored counter.
    uint64 public ghostPostDeadlineAccepted;
    /// @notice Count of pre-deadline admissions rejected by the Settler.
    /// @return ghostPreDeadlineRejected Stored counter.
    uint64 public ghostPreDeadlineRejected;

    /// @param driver_ Suite-owned admission driver.
    constructor(IOpenDeadlineDriver driver_) {
        driver = driver_;
    }

    /// @notice handler action: fuzz one exact-mode admission.
    /// @param saltSeed Fuzz seed mixed into the order salt.
    /// @param deadlineSeed Fuzz seed for the open-deadline offset.
    /// @param warpSeed Fuzz seed for the warp offset.
    /// @param pathSeed Fuzz seed selecting open/openFor/direct-fill.
    function probeExactAdmission(
        uint256 saltSeed,
        uint64 deadlineSeed,
        uint64 warpSeed,
        uint8 pathSeed
    ) external {
        _probe(saltSeed, deadlineSeed, warpSeed, pathSeed, false);
    }

    /// @notice handler action: fuzz one partial-mode admission.
    /// @param saltSeed Fuzz seed mixed into the order salt.
    /// @param deadlineSeed Fuzz seed for the open-deadline offset.
    /// @param warpSeed Fuzz seed for the warp offset.
    /// @param pathSeed Fuzz seed selecting open/openFor/direct-fill.
    function probePartialAdmission(
        uint256 saltSeed,
        uint64 deadlineSeed,
        uint64 warpSeed,
        uint8 pathSeed
    ) external {
        _probe(saltSeed, deadlineSeed, warpSeed, pathSeed, true);
    }

    function _probe(
        uint256 saltSeed,
        uint64 deadlineSeed,
        uint64 warpSeed,
        uint8 pathSeed,
        bool isPartial
    ) internal {
        try driver.driveOpenDeadlineAdmission(
            saltSeed, deadlineSeed, warpSeed, pathSeed, isPartial
        ) returns (
            bool accepted, bool shouldAdmit, uint8 statusBefore, uint8 statusAfter
        ) {
            _capture(accepted, shouldAdmit, statusBefore, statusAfter);
        } catch {
            unexpectedPreDeadlineReject = true;
            ghostPreDeadlineRejected++;
        }
    }

    function _capture(bool accepted, bool shouldAdmit, uint8 statusBefore, uint8 statusAfter)
        internal
    {
        bool transitioned = statusBefore == 0 && statusAfter != 0;
        if (!shouldAdmit && (accepted || transitioned)) {
            postDeadlineAdmissionViolated = true;
            ghostPostDeadlineAccepted++;
        } else if (shouldAdmit && !accepted) {
            unexpectedPreDeadlineReject = true;
            ghostPreDeadlineRejected++;
        } else if (shouldAdmit) {
            ghostPreDeadlineAccepted++;
        } else {
            ghostPostDeadlineRejected++;
        }
    }
}
