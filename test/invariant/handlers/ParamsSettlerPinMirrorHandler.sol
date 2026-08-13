// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { CommonBase } from "forge-std/Base.sol";

/// @notice Harness callback implemented by the invariant suites.
interface IParamsSettlerPinMirrorHarness {
    /// @notice Attempt one settler-pin mirror admission scenario.
    /// @param isPartial True for the isPartial Settler, false for exact.
    /// @param directFill True to exercise direct fill from None; false for openFor admission.
    /// @param variant 0 = canonical inner settler, 1 = zero inner settler, 2 = bogus inner settler.
    /// @param saltSeed Fuzz seed folded into orderSalt.
    /// @return accepted True if the admission call returned without revert.
    /// @return canonical True if the attempted tuple was expected to be canonical.
    function attemptParamsSettlerPinMirror(
        bool isPartial,
        bool directFill,
        uint8 variant,
        uint64 saltSeed
    ) external returns (bool accepted, bool canonical);
}

/// @notice INV-PARAMS-SETTLER-PIN-MIRROR handler — fuzzes exact/isPartial
///         openFor and direct-fill admissions with canonical, zero, and bogus
///         `orderData.rolloverParams.settler` values.
/// @custom:invariant INV-PARAMS-SETTLER-PIN-MIRROR
contract ParamsSettlerPinMirrorHandler is CommonBase {
    /// @notice Test harness that owns order construction/signing helpers.
    IParamsSettlerPinMirrorHarness public immutable harness;

    /// @notice Any non-canonical inner settler was accepted.
    bool public ghostMismatchAccepted;
    /// @notice Total attempts.
    uint256 public ghostAttempts;
    /// @notice Canonical attempts accepted.
    uint256 public ghostCanonicalAccepted;
    /// @notice Non-canonical attempts rejected.
    uint256 public ghostMismatchRejected;
    /// @notice Direct-fill branch attempts.
    uint256 public ghostDirectFillAttempts;
    /// @notice openFor branch attempts.
    uint256 public ghostOpenForAttempts;
    /// @notice Exact-mode attempts.
    uint256 public ghostExactAttempts;
    /// @notice Partial-mode attempts.
    uint256 public ghostPartialAttempts;

    /// @param harness_ Harness callback.
    constructor(IParamsSettlerPinMirrorHarness harness_) {
        harness = harness_;
    }

    /// @param variantSeed Fuzz seed selecting the scenario value.
    /// @param directFill Input value under test.
    /// @param saltSeed Fuzz seed selecting the scenario value.

    /// @notice Fuzz one exact-mode admission scenario.
    function attemptExact(uint256 variantSeed, bool directFill, uint64 saltSeed) external {
        _attempt(false, directFill, variantSeed, saltSeed);
    }

    /// @param variantSeed Fuzz seed selecting the scenario value.
    /// @param directFill Input value under test.
    /// @param saltSeed Fuzz seed selecting the scenario value.

    /// @notice Fuzz one isPartial-mode admission scenario.
    function attemptPartial(uint256 variantSeed, bool directFill, uint64 saltSeed) external {
        _attempt(true, directFill, variantSeed, saltSeed);
    }

    function _attempt(bool isPartial, bool directFill, uint256 variantSeed, uint64 saltSeed)
        internal
    {
        ghostAttempts++;
        if (isPartial) {
            ghostPartialAttempts++;
        } else {
            ghostExactAttempts++;
        }
        if (directFill) {
            ghostDirectFillAttempts++;
        } else {
            ghostOpenForAttempts++;
        }

        uint8 variant = uint8(variantSeed % 3);
        (bool accepted, bool canonical) =
            harness.attemptParamsSettlerPinMirror(isPartial, directFill, variant, saltSeed);

        if (canonical && accepted) {
            ghostCanonicalAccepted++;
        } else if (!canonical && accepted) {
            ghostMismatchAccepted = true;
        } else if (!canonical) {
            ghostMismatchRejected++;
        }
    }

    /// @return value Computed test helper value.

    /// @notice No non-canonical inner settler tuple was admitted.
    function noMismatchedInnerSettlerAccepted() external view returns (bool) {
        return !ghostMismatchAccepted;
    }
}
