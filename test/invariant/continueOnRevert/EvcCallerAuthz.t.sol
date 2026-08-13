// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { EvcCallerAuthzInvariantBase } from "../EvcCallerAuthzInvariantBase.sol";

/// @notice INV-EVC-CALLER-AUTHORIZED — continue-on-revert invariant suite:
///         only EVC-origin calls with matching controller-enabled frames pass the gate.
/// @dev continue-on-revert mode (companion at test/invariant/failOnRevert/EvcCallerAuthz.t.sol).
/// @custom:invariant INV-EVC-CALLER-AUTHORIZED
contract EvcCallerAuthzContinueOnRevertTest is EvcCallerAuthzInvariantBase {
    /// @notice Sets up the active EVC caller-authorization invariant handler.
    function setUp() public override {
        super.setUp();
        _setUpEvcCallerAuthzInvariant();
    }

    /// @notice invariant: unauthorized caller/frame tuples never pass the gate.
    function invariant_evcCallerAuthz_unauthorizedNeverAccepted() public view {
        assertFalse(
            evcAuthzHandler.unauthorizedAccepted(),
            "INV-EVC-CALLER-AUTHORIZED: unauthorized EVC gate tuple accepted (loose)"
        );
    }

    /// @notice invariant: valid EVC-origin matching frames are not rejected.
    function invariant_evcCallerAuthz_authorizedFramesAccepted() public view {
        assertFalse(
            evcAuthzHandler.authorizedRejected(),
            "INV-EVC-CALLER-AUTHORIZED: authorized EVC gate tuple rejected (loose)"
        );
    }
}
