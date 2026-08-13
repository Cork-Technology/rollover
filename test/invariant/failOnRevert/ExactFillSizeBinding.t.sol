// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {
    CompromisedSettlerDispatchInvariantBase
} from "../CompromisedSettlerDispatchInvariantBase.sol";

/// @notice INV-EXACT-FILL-SIZE-BINDING — fail-on-revert suite:
///         real Settler.fill admission enforces exact/partial fill-size rules.
/// @dev fail-on-revert mode (companion at test/invariant/continueOnRevert/ExactFillSizeBinding.t.sol).
/// @custom:invariant INV-EXACT-FILL-SIZE-BINDING
contract ExactFillSizeBindingFailOnRevertTest is CompromisedSettlerDispatchInvariantBase {
    /// @notice Sets up the active exact-fill-size handler.
    function setUp() public override {
        super.setUp();
        _setUpExactFillSizeBindingInvariant();
    }

    /// @notice invariant: invalid fill-size tuples never accept.
    function invariant_exactFillSizeBinding_invalidTuplesNeverAccepted() public view {
        assertFalse(
            compromisedHandler.fillSizeInvalidAccepted(),
            "INV-EXACT-FILL-SIZE-BINDING: invalid fill-size tuple accepted"
        );
    }

    /// @notice invariant: invalid fill-size tuples revert at the target admission guard.
    function invariant_exactFillSizeBinding_invalidTuplesUseTargetGuard() public view {
        assertFalse(
            compromisedHandler.fillSizeWrongSelector(),
            "INV-EXACT-FILL-SIZE-BINDING: invalid fill-size tuple wrong selector"
        );
    }

    /// @notice invariant: valid exact/partial fill-size tuples do not unexpectedly revert.
    function invariant_exactFillSizeBinding_validTuplesDoNotRevert() public view {
        assertFalse(
            compromisedHandler.fillSizeValidUnexpectedRevert(),
            "INV-EXACT-FILL-SIZE-BINDING: valid fill-size tuple unexpectedly reverted"
        );
    }
}
