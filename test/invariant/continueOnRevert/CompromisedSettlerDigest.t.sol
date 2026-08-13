// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {
    CompromisedSettlerDispatchInvariantBase
} from "../CompromisedSettlerDispatchInvariantBase.sol";

/// @notice INV-ORDER-DIGEST-RE-DERIVED-ROLLOVER_CONTRACT-SIDE — continue-on-revert suite:
///         compromised approved Settler digest/orderData tampering is rejected.
/// @dev continue-on-revert mode (companion at test/invariant/failOnRevert/CompromisedSettlerDigest.t.sol).
/// @custom:invariant INV-ORDER-DIGEST-RE-DERIVED-ROLLOVER_CONTRACT-SIDE
contract CompromisedSettlerDigestContinueOnRevertTest is CompromisedSettlerDispatchInvariantBase {
    /// @notice Sets up the active compromised-settler digest-tamper handler.
    function setUp() public override {
        super.setUp();
        _setUpCompromisedSettlerDigestInvariant();
    }

    /// @notice invariant: digest/orderData-tampered dispatches never accept.
    function invariant_orderDigestReDerived_tamperedDigestNeverAccepted() public view {
        assertFalse(
            compromisedHandler.digestTamperAccepted(),
            "INV-ORDER-DIGEST-RE-DERIVED-ROLLOVER_CONTRACT-SIDE: tampered digest accepted (loose)"
        );
    }

    /// @notice invariant: digest/orderData tampering reverts at the digest guard.
    function invariant_orderDigestReDerived_tamperedDigestRevertsAtBindingGuard() public view {
        assertFalse(
            compromisedHandler.digestTamperWrongSelector(),
            "INV-ORDER-DIGEST-RE-DERIVED-ROLLOVER_CONTRACT-SIDE: tampered digest wrong selector (loose)"
        );
    }
}
