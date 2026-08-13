// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { Typehashes } from "src/libraries/Typehashes.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @title LibAuthenticatedHooks
/// @notice EIP-712 hashing helpers for `RolloverIntent` payloads. The struct hash is built so that
///         zeroing the `orderDigest` field yields the canonical intent hash committed by
///         `OrderData.rolloverIntentHash`: verifying phases check the cPT-holder signature over
///         `OrderData` on every RolloverContract dispatch.
library LibAuthenticatedHooks {
    /// @dev Hash a single `Call` struct per EIP-712 encoding rules.
    function _hashCall(RolloverTypes.Call memory c) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256(
                    "Call(address target,uint256 value,bytes callData,bool allowFailure,bool isDelegateCall)"
                ),
                c.target,
                c.value,
                keccak256(c.callData),
                c.allowFailure,
                c.isDelegateCall
            )
        );
    }

    /// @dev Hash a `Call[]` array per EIP-712 dynamic-array encoding rules.
    function _hashCallArray(RolloverTypes.Call[] memory arr) internal pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](arr.length);
        for (uint256 i = 0; i < arr.length; ++i) {
            hashes[i] = _hashCall(arr[i]);
        }
        return keccak256(abi.encodePacked(hashes));
    }

    /// @dev Compute the `RolloverIntent` EIP-712 struct hash. Split prefix/suffix to keep the
    ///      stack within compiler limits.
    function _structHash(RolloverTypes.RolloverIntent memory intent)
        internal
        pure
        returns (bytes32)
    {
        bytes memory prefix = abi.encode(
            Typehashes.ROLLOVER_INTENT_TYPEHASH,
            intent.rolloverContract,
            intent.orderDigest,
            intent.deadline,
            intent.nonce
        );
        bytes memory suffix = abi.encode(
            _hashCallArray(intent.preRolloverHooks),
            _hashCallArray(intent.midRolloverHooks),
            _hashCallArray(intent.postRolloverHooks),
            _hashCallArray(intent.premiumHooks)
        );
        return keccak256(bytes.concat(prefix, suffix));
    }

    /// @notice Compute the `RolloverIntent` struct hash for the supplied intent.
    /// @dev Callers that need the order-independent intent hash must pass an intent whose
    ///      `orderDigest` field has already been zeroed.
    /// @param intent `RolloverIntent` payload.
    /// @return Struct hash for the supplied intent.
    function intentStructHash(RolloverTypes.RolloverIntent memory intent)
        internal
        pure
        returns (bytes32)
    {
        return _structHash(intent);
    }
}
