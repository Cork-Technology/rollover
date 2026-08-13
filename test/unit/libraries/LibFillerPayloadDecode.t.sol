// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { LibFillerPayloadHarness } from "../../mocks/LibFillerPayloadHarness.sol";
import { Test } from "forge-std/Test.sol";
import {
    FillerPayload__AtomicTagRequired,
    FillerPayload__InvalidPhase,
    FillerPayload__InvalidRolloverShape
} from "src/errors/LibFillerPayloadErrors.sol";
import { LibAtomicFill } from "src/libraries/LibAtomicFill.sol";
import { LibFillerAuth } from "src/libraries/LibFillerAuth.sol";
import { LibFillerPayload } from "src/libraries/LibFillerPayload.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice Unit tests for `LibFillerPayload` decode validation and wire round-trips.
contract LibFillerPayloadDecodeTest is Test {
    /// @notice Harness exposing library decode entrypoints.
    LibFillerPayloadHarness internal harness;

    /// @notice Shared rollover intent fixture for encoded blobs.
    RolloverTypes.RolloverIntent internal intent;

    /// @notice Deploy the decode harness.
    function setUp() public {
        harness = new LibFillerPayloadHarness();
    }

    /// @notice Rollover decoder rejects an under-shaped blob.
    /// @dev Rollover decode expects the full `FillerPayload` shape. Feeding a one-field
    ///      blob to the rollover decoder fails at ABI decode.
    function test_decodeRollover_underShapedBlob_reverts() public {
        bytes memory blob = abi.encode(intent);
        vm.expectRevert();
        harness.decodeRolloverPayload(blob);
    }

    /// @notice Rollover decode rejects a nonzero premium field.
    function test_decodeRollover_nonzeroPremium_reverts() public {
        bytes memory blob =
            _manualEncode(uint8(RolloverTypes.HookPhase.ROLLOVER), 1, 1, address(0), address(0));
        vm.expectRevert(FillerPayload__InvalidRolloverShape.selector);
        harness.decodeRolloverPayload(blob);
    }

    /// @notice Rollover decode rejects a nonzero `premiumFor` field.
    function test_decodeRollover_nonzeroPremiumFor_reverts() public {
        bytes memory blob = _manualEncode(
            uint8(RolloverTypes.HookPhase.ROLLOVER), 1, 0, address(0), address(0xBEEF)
        );
        vm.expectRevert(FillerPayload__InvalidRolloverShape.selector);
        harness.decodeRolloverPayload(blob);
    }

    /// @notice Atomic envelope decode rejects a non-`ATOMIC_TAG` discriminator.
    function test_decodeAtomicEnvelope_nonAtomicTag_reverts() public {
        bytes memory env = abi.encode(uint8(1), hex"01", uint256(3), hex"04");
        vm.expectRevert(FillerPayload__AtomicTagRequired.selector);
        harness.decodeAtomicEnvelopeValidated(env);
    }

    /// @notice Atomic envelope encode/decode round-trips rollover leg, cap, and cPT-holder sig.
    function test_atomicEnvelope_fullRoundTrip() public view {
        bytes memory rollover = LibFillerPayload.encodeRolloverLeg(
            100e18, address(0xD), intent, 1e18, hex"cd", bytes32(uint256(0xBEEF)), hex"ef"
        );
        bytes memory env = LibFillerPayload.encodeAtomicEnvelope(rollover, 3, hex"04");
        (bytes memory r, uint256 cap, bytes memory cptHolderPayload) =
            harness.decodeAtomicEnvelopeValidated(env);
        assertEq(r, rollover);
        assertEq(cap, 3);
        assertEq(cptHolderPayload, hex"04");
        (uint8 tag,,,) = abi.decode(env, (uint8, bytes, uint256, bytes));
        assertEq(tag, LibAtomicFill.ATOMIC_TAG);
    }

    function _manualEncode(
        uint8 phase,
        uint256 fillOrPremium,
        uint256 premiumField,
        address destination,
        address premiumFor
    ) private view returns (bytes memory) {
        return _manualEncodeFull(
            phase, fillOrPremium, premiumField, destination, premiumFor, 0, bytes32(0), bytes("")
        );
    }

    function _manualEncodeFull(
        uint8 phase,
        uint256 fillOrPremium,
        uint256 premiumField,
        address destination,
        address premiumFor,
        uint256 minDstPerSrc,
        bytes32 subFiller,
        bytes memory cptHolderSig
    ) private view returns (bytes memory) {
        return abi.encode(
            phase,
            fillOrPremium,
            premiumField,
            destination,
            premiumFor,
            intent,
            minDstPerSrc,
            bytes(""),
            subFiller,
            cptHolderSig
        );
    }
}
