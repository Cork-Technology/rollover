// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";
import { LibAuthenticatedHooks } from "src/libraries/LibAuthenticatedHooks.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice ZeroDigestCanonicalFormTest — pins ZeroDigestCanonicalForm behaviour for the Cork Rollover suite.
contract ZeroDigestCanonicalFormTest is Test {
    function _intent(bytes32 orderDigest)
        internal
        pure
        returns (RolloverTypes.RolloverIntent memory)
    {
        return RolloverTypes.RolloverIntent({
            rolloverContract: address(0xCAFE),
            orderDigest: orderDigest,
            deadline: 1_000_000,
            nonce: 7,
            preRolloverHooks: new RolloverTypes.Call[](0),
            midRolloverHooks: new RolloverTypes.Call[](0),
            postRolloverHooks: new RolloverTypes.Call[](0),
            premiumHooks: new RolloverTypes.Call[](0)
        });
    }

    /// @notice Pins behaviour: zero Digest Hash Is Order Digest Invariant.
    function test_zeroDigestHashIsOrderDigestInvariant() public pure {
        RolloverTypes.RolloverIntent memory a = _intent(bytes32(0));
        RolloverTypes.RolloverIntent memory b = _intent(bytes32(0));

        bytes32 ha = LibAuthenticatedHooks.intentStructHash(a);
        bytes32 hb = LibAuthenticatedHooks.intentStructHash(b);
        assertEq(ha, hb, "deterministic");
    }

    /// @notice Pins behaviour: zero Digest Hash Changes If Other Fields Change.
    function test_zeroDigestHashChangesIfOtherFieldsChange() public pure {
        RolloverTypes.RolloverIntent memory a = _intent(bytes32(0));
        RolloverTypes.RolloverIntent memory b = _intent(bytes32(0));
        b.nonce = 8;
        bytes32 ha = LibAuthenticatedHooks.intentStructHash(a);
        bytes32 hb = LibAuthenticatedHooks.intentStructHash(b);
        assertTrue(ha != hb, "nonce delta changes hash");
    }
}
