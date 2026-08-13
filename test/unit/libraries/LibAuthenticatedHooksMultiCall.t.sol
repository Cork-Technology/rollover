// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";
import { LibAuthenticatedHooks } from "src/libraries/LibAuthenticatedHooks.sol";
import { Typehashes } from "src/libraries/Typehashes.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice LibAuthenticatedHooksMultiCallTest — pins LibAuthenticatedHooksMultiCall behaviour for the Cork Rollover suite.
contract LibAuthenticatedHooksMultiCallTest is Test {
    function _mkCall(address target, bytes memory callData)
        internal
        pure
        returns (RolloverTypes.Call memory)
    {
        return RolloverTypes.Call({
            target: target, value: 0, callData: callData, allowFailure: false, isDelegateCall: true
        });
    }

    function _baseIntent() internal view returns (RolloverTypes.RolloverIntent memory intent) {
        RolloverTypes.Call[] memory pre = new RolloverTypes.Call[](3);
        pre[0] = _mkCall(address(0xAA), hex"01");
        pre[1] = _mkCall(address(0xBB), hex"02");
        pre[2] = _mkCall(address(0xCC), hex"03");
        RolloverTypes.Call[] memory mid = new RolloverTypes.Call[](2);
        mid[0] = _mkCall(address(0xDD), hex"04");
        mid[1] = _mkCall(address(0xEE), hex"05");
        intent = RolloverTypes.RolloverIntent({
            rolloverContract: address(0x1234),
            orderDigest: bytes32(0),
            deadline: uint64(block.timestamp + 1 days),
            nonce: 7,
            preRolloverHooks: pre,
            midRolloverHooks: mid,
            postRolloverHooks: new RolloverTypes.Call[](0),
            premiumHooks: new RolloverTypes.Call[](0)
        });
    }

    function _refHashCallArray(RolloverTypes.Call[] memory arr) internal pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](arr.length);
        for (uint256 i = 0; i < arr.length; ++i) {
            hashes[i] = keccak256(
                abi.encode(
                    keccak256(
                        "Call(address target,uint256 value,bytes callData,bool allowFailure,bool isDelegateCall)"
                    ),
                    arr[i].target,
                    arr[i].value,
                    keccak256(arr[i].callData),
                    arr[i].allowFailure,
                    arr[i].isDelegateCall
                )
            );
        }
        return keccak256(abi.encodePacked(hashes));
    }

    function _refIntentHash(RolloverTypes.RolloverIntent memory intent)
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
            _refHashCallArray(intent.preRolloverHooks),
            _refHashCallArray(intent.midRolloverHooks),
            _refHashCallArray(intent.postRolloverHooks),
            _refHashCallArray(intent.premiumHooks)
        );
        return keccak256(bytes.concat(prefix, suffix));
    }

    /// @notice Pins behaviour: intent Hash Equals Reference.
    function test_intentHashEqualsReference() public view {
        RolloverTypes.RolloverIntent memory intent = _baseIntent();
        bytes32 actual = LibAuthenticatedHooks.intentStructHash(intent);
        bytes32 expected = _refIntentHash(intent);
        assertEq(actual, expected, "library must match reference");
    }

    /// @notice Pins behaviour: intent Hash Changes On Byte Flip.
    function test_intentHashChangesOnByteFlip() public view {
        RolloverTypes.RolloverIntent memory a = _baseIntent();
        bytes32 hashA = LibAuthenticatedHooks.intentStructHash(a);

        RolloverTypes.RolloverIntent memory b = _baseIntent();
        b.preRolloverHooks[1].callData = hex"FF";
        bytes32 hashB = LibAuthenticatedHooks.intentStructHash(b);

        assertTrue(hashA != hashB, "byte flip must change the intent hash");
    }

    /// @notice Pins behaviour: intent Hash Changes On Last Element Flip.
    function test_intentHashChangesOnLastElementFlip() public view {
        RolloverTypes.RolloverIntent memory a = _baseIntent();
        bytes32 hashA = LibAuthenticatedHooks.intentStructHash(a);

        RolloverTypes.RolloverIntent memory b = _baseIntent();
        b.preRolloverHooks[2].callData = hex"FF";
        bytes32 hashB = LibAuthenticatedHooks.intentStructHash(b);

        assertTrue(hashA != hashB, "last-element flip must change the intent hash");
    }

    /// @notice Pins behaviour: empty Arrays Hash To Constant.
    function test_emptyArraysHashToConstant() public pure {
        RolloverTypes.RolloverIntent memory intent = RolloverTypes.RolloverIntent({
            rolloverContract: address(0),
            orderDigest: bytes32(0),
            deadline: 0,
            nonce: 0,
            preRolloverHooks: new RolloverTypes.Call[](0),
            midRolloverHooks: new RolloverTypes.Call[](0),
            postRolloverHooks: new RolloverTypes.Call[](0),
            premiumHooks: new RolloverTypes.Call[](0)
        });
        bytes32 actual = LibAuthenticatedHooks.intentStructHash(intent);
        bytes32 expected = _refIntentHash(intent);
        assertEq(actual, expected, "empty intent reference match");
    }
}
