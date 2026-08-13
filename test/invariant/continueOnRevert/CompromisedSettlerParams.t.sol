// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {
    CompromisedSettlerDispatchInvariantBase
} from "../CompromisedSettlerDispatchInvariantBase.sol";

/// @notice INV-PARAMS-MATCH-ORDER — continue-on-revert suite:
///         compromised approved Settler runtime params tampering is rejected.
/// @dev continue-on-revert mode (companion at test/invariant/failOnRevert/CompromisedSettlerParams.t.sol).
/// @custom:invariant INV-PARAMS-MATCH-ORDER
contract CompromisedSettlerParamsContinueOnRevertTest is CompromisedSettlerDispatchInvariantBase {
    /// @notice Sets up the active compromised-settler params-tamper handler.
    function setUp() public override {
        super.setUp();
        _setUpCompromisedSettlerParamsInvariant();
    }

    /// @notice invariant: runtime params-tampered dispatches never accept.
    function invariant_paramsMatchOrder_tamperedParamsNeverAccepted() public view {
        assertFalse(
            compromisedHandler.paramsTamperAccepted(),
            "INV-PARAMS-MATCH-ORDER: tampered params accepted (loose)"
        );
    }

    /// @notice invariant: runtime params tampering reverts at the params binding guard.
    function invariant_paramsMatchOrder_tamperedParamsRevertsAtBindingGuard() public view {
        assertFalse(
            compromisedHandler.paramsTamperWrongSelector(),
            "INV-PARAMS-MATCH-ORDER: tampered params wrong selector (loose)"
        );
    }
}
