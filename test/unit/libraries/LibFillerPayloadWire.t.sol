// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";
import { LibAtomicFill } from "src/libraries/LibAtomicFill.sol";
import { LibFillerAuth } from "src/libraries/LibFillerAuth.sol";
import { LibFillerPayload } from "src/libraries/LibFillerPayload.sol";
import { Typehashes } from "src/libraries/Typehashes.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice Wire-format and typehash regression tests for `LibFillerPayload`.
contract LibFillerPayloadWireTest is Test {
    /// @notice `FILLER_AUTH_TYPEHASH` includes `subFiller` in its EIP-712 string.
    function test_fillerAuthTypehash_includesSubFiller() public pure {
        bytes32 expected =
            keccak256("FillerAuth(bytes32 orderDigest,address destination,bytes32 subFiller)");
        assertEq(Typehashes.FILLER_AUTH_TYPEHASH, expected);
    }

    /// @notice Rollover leg encoder matches manual 10-tuple ABI encoding.
    function test_encodeDecode_roundTrip_rolloverLeg() public pure {
        RolloverTypes.RolloverIntent memory intent;
        bytes memory blob = LibFillerPayload.encodeRolloverLeg(
            100e18, address(0xD), intent, 1e18, hex"cd", bytes32(uint256(0xBEEF)), hex"ef"
        );
        assertEq(
            blob,
            _manualRolloverEncode(
                100e18, address(0xD), intent, 1e18, hex"cd", bytes32(uint256(0xBEEF)), hex"ef"
            )
        );
    }

    /// @notice Atomic envelope ABI prefix is `LibAtomicFill.ATOMIC_TAG`.
    function test_encodeAtomicEnvelope_wireTag() public pure {
        bytes memory env = LibFillerPayload.encodeAtomicEnvelope(hex"01", 3, hex"04");
        (uint8 tag,,,) = abi.decode(env, (uint8, bytes, uint256, bytes));
        assertEq(tag, LibAtomicFill.ATOMIC_TAG);
    }

    function _manualRolloverEncode(
        uint256 fillAmount,
        address destination,
        RolloverTypes.RolloverIntent memory intent,
        uint256 minDstPerSrc,
        bytes memory fillerAuthSig,
        bytes32 subFiller,
        bytes memory cptHolderSig
    ) private pure returns (bytes memory) {
        return abi.encode(
            uint8(RolloverTypes.HookPhase.ROLLOVER),
            fillAmount,
            uint256(0),
            destination,
            address(0),
            intent,
            minDstPerSrc,
            fillerAuthSig,
            subFiller,
            cptHolderSig
        );
    }
}
