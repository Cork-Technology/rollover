// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { CommonBase } from "forge-std/Base.sol";
import { StdCheats } from "forge-std/StdCheats.sol";
import { StdUtils } from "forge-std/StdUtils.sol";

/// @notice Suite-owned driver for EVC caller-authorization gate probes.
interface IEvcCallerAuthzDriver {
    /// @notice Drive one `_gateEvc` probe through a caller/frame combination.
    /// @param subSeed Fuzz seed used to derive the job subaccount.
    /// @param frameSeed Fuzz seed used to derive a mismatched EVC on-behalf account.
    /// @param callerSeed Fuzz seed used to derive direct callers.
    /// @param viaEvc True to call as the EVC contract, false for a direct caller.
    /// @param matchingFrame True to report the same EVC on-behalf account as the subaccount.
    /// @param controllerEnabled True to report the controller-enabled bit.
    /// @param controllerMatches True to use the adapter's configured controller in the frame.
    /// @param trailingSuffix True to append attacker-controlled bytes to calldata.
    /// @return accepted True if the gate probe returned without reverting.
    /// @return authorized True if the generated caller/frame tuple satisfies the invariant.
    function driveEvcCallerAuthzProbe(
        uint256 subSeed,
        uint256 frameSeed,
        uint256 callerSeed,
        bool viaEvc,
        bool matchingFrame,
        bool controllerEnabled,
        bool controllerMatches,
        bool trailingSuffix
    ) external returns (bool accepted, bool authorized);
}

/// @notice INV-EVC-CALLER-AUTHORIZED handler — fuzzes direct callers and EVC-origin frames
///         across on-behalf, controller-enabled, controller-address, and calldata-suffix
///         variations. The only accepted probes must originate from the EVC and report a
///         matching controller-enabled frame for the submitted subaccount.
/// @custom:invariant INV-EVC-CALLER-AUTHORIZED
contract EvcCallerAuthzHandler is CommonBase, StdCheats, StdUtils {
    /// @notice End-to-end gate driver implemented by the invariant suite.
    /// @return driver Stored driver.
    IEvcCallerAuthzDriver public immutable driver;

    /// @notice Violation flag for any unauthorized gate acceptance.
    /// @return unauthorizedAccepted True if the gate accepted an unauthorized caller/frame.
    bool public unauthorizedAccepted;
    /// @notice Unexpected valid-frame rejection flag.
    /// @return authorizedRejected True if a valid EVC frame was rejected.
    bool public authorizedRejected;
    /// @notice Count of accepted authorized probes.
    /// @return ghostAuthorizedAccepted Stored counter.
    uint64 public ghostAuthorizedAccepted;
    /// @notice Count of rejected unauthorized probes.
    /// @return ghostUnauthorizedRejected Stored counter.
    uint64 public ghostUnauthorizedRejected;
    /// @notice Count of accepted unauthorized probes.
    /// @return ghostUnauthorizedAccepted Stored counter.
    uint64 public ghostUnauthorizedAccepted;
    /// @notice Count of rejected authorized probes.
    /// @return ghostAuthorizedRejected Stored counter.
    uint64 public ghostAuthorizedRejected;

    /// @param driver_ Suite-owned gate driver.
    constructor(IEvcCallerAuthzDriver driver_) {
        driver = driver_;
    }

    /// @notice handler action: probe a fully fuzzed caller/frame tuple.
    /// @param subSeed Fuzz seed used to derive the job subaccount.
    /// @param frameSeed Fuzz seed used to derive a mismatched EVC on-behalf account.
    /// @param callerSeed Fuzz seed used to derive direct callers.
    /// @param viaEvc True to call as the EVC contract.
    /// @param matchingFrame True to report the subaccount as the EVC on-behalf account.
    /// @param controllerEnabled True to report the controller-enabled bit.
    /// @param controllerMatches True to use the configured controller in the frame.
    /// @param trailingSuffix True to append attacker-controlled bytes to calldata.
    function probeGate(
        uint256 subSeed,
        uint256 frameSeed,
        uint256 callerSeed,
        bool viaEvc,
        bool matchingFrame,
        bool controllerEnabled,
        bool controllerMatches,
        bool trailingSuffix
    ) external {
        try driver.driveEvcCallerAuthzProbe(
            subSeed,
            frameSeed,
            callerSeed,
            viaEvc,
            matchingFrame,
            controllerEnabled,
            controllerMatches,
            trailingSuffix
        ) returns (
            bool accepted, bool authorized
        ) {
            _capture(accepted, authorized);
        } catch {
            authorizedRejected = true;
            ghostAuthorizedRejected++;
        }
    }

    /// @notice handler action: direct callers are rejected even if an otherwise-valid frame exists.
    /// @param subSeed Fuzz seed used to derive the job subaccount.
    /// @param callerSeed Fuzz seed used to derive direct callers.
    /// @param trailingSuffix True to append attacker-controlled bytes to calldata.
    function probeDirectCaller(uint256 subSeed, uint256 callerSeed, bool trailingSuffix) external {
        try driver.driveEvcCallerAuthzProbe(
            subSeed, 0, callerSeed, false, true, true, true, trailingSuffix
        ) returns (
            bool accepted, bool authorized
        ) {
            _capture(accepted, authorized);
        } catch {
            authorizedRejected = true;
            ghostAuthorizedRejected++;
        }
    }

    /// @notice handler action: valid EVC frames are accepted with or without trailing bytes.
    /// @param subSeed Fuzz seed used to derive the job subaccount.
    /// @param trailingSuffix True to append attacker-controlled bytes to calldata.
    function probeAuthorizedEvc(uint256 subSeed, bool trailingSuffix) external {
        try driver.driveEvcCallerAuthzProbe(
            subSeed, 0, 0, true, true, true, true, trailingSuffix
        ) returns (
            bool accepted, bool authorized
        ) {
            _capture(accepted, authorized);
        } catch {
            authorizedRejected = true;
            ghostAuthorizedRejected++;
        }
    }

    /// @notice handler action: EVC-origin calls with bad frame fields are rejected.
    /// @param subSeed Fuzz seed used to derive the job subaccount.
    /// @param frameSeed Fuzz seed used to derive a mismatched EVC on-behalf account.
    /// @param matchingFrame True to report the subaccount as the EVC on-behalf account.
    /// @param controllerEnabled True to report the controller-enabled bit.
    /// @param controllerMatches True to use the configured controller in the frame.
    function probeBadEvcFrame(
        uint256 subSeed,
        uint256 frameSeed,
        bool matchingFrame,
        bool controllerEnabled,
        bool controllerMatches
    ) external {
        try driver.driveEvcCallerAuthzProbe(
            subSeed, frameSeed, 0, true, matchingFrame, controllerEnabled, controllerMatches, false
        ) returns (
            bool accepted, bool authorized
        ) {
            _capture(accepted, authorized);
        } catch {
            authorizedRejected = true;
            ghostAuthorizedRejected++;
        }
    }

    function _capture(bool accepted, bool authorized) internal {
        if (accepted && !authorized) {
            unauthorizedAccepted = true;
            ghostUnauthorizedAccepted++;
        } else if (!accepted && authorized) {
            authorizedRejected = true;
            ghostAuthorizedRejected++;
        } else if (accepted) {
            ghostAuthorizedAccepted++;
        } else {
            ghostUnauthorizedRejected++;
        }
    }
}
