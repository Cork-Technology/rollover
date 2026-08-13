// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {
    CompromisedSettlerDispatchInvariantBase
} from "../CompromisedSettlerDispatchInvariantBase.sol";

/// @notice INV-FILL-CONTEXT-MATCHES-ORDER — continue-on-revert invariant suite:
///         compromised approved Settler fillContext tampering is rejected field-by-field.
/// @dev continue-on-revert mode (companion at test/invariant/failOnRevert/CompromisedSettlerFillContext.t.sol).
/// @custom:invariant INV-FILL-CONTEXT-MATCHES-ORDER
contract CompromisedSettlerFillContextContinueOnRevertTest is
    CompromisedSettlerDispatchInvariantBase
{
    /// @notice Sets up the active compromised-settler fillContext-tamper handler.
    function setUp() public override {
        super.setUp();
        _setUpCompromisedSettlerDispatchInvariant();
    }

    /// @notice invariant: fillContext-tampered dispatches never accept.
    function invariant_fillContextMatchesOrder_tamperedFillContextNeverAccepted() public view {
        assertFalse(
            compromisedHandler.fillContextTamperAccepted(),
            "INV-FILL-CONTEXT-MATCHES-ORDER: tampered fillContext accepted (loose)"
        );
    }

    /// @notice invariant: each fillContext-tampered field reverts at its expected binding selector.
    function invariant_fillContextMatchesOrder_tamperedFillContextRevertsAtBindingGuard()
        public
        view
    {
        assertFalse(
            compromisedHandler.fillContextTamperWrongSelector(),
            "INV-FILL-CONTEXT-MATCHES-ORDER: tampered fillContext wrong selector (loose)"
        );
    }
}
