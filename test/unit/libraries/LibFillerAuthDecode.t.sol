// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";
import { LibFillerAuth } from "src/libraries/LibFillerAuth.sol";
import { FillerPayload } from "src/types/FillerTypes.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice Harness exposing the internal filler-data decoder for hostile calldata tests.
contract LibFillerAuthDecodeHarness {
    /// @notice Decode filler data and return representative scalar fields.
    /// @param fillerData Canonical 10-tuple filler data.
    /// @return phaseU8 Decoded hook phase.
    /// @return fillAmount Decoded rollover amount.
    /// @return destination Decoded settlement destination.
    /// @return premiumFor Decoded premium target filler.
    /// @return minDstPerSrc Decoded mint-rate floor.
    /// @return fillerAuthSig Decoded filler auth signature.
    function decode(bytes calldata fillerData)
        external
        view
        returns (
            uint8 phaseU8,
            uint256 fillAmount,
            address destination,
            address premiumFor,
            uint256 minDstPerSrc,
            bytes memory fillerAuthSig
        )
    {
        FillerPayload memory payload = LibFillerAuth.decodePayload(fillerData);
        return (
            payload.phaseU8,
            payload.fillAmount,
            payload.destination,
            payload.premiumFor,
            payload.minDstPerSrc,
            payload.fillerAuthSig
        );
    }
}

/// @notice Hostile decoder coverage for the canonical 10-tuple filler-data ABI.
contract LibFillerAuthDecodeTest is Test {
    /// @notice Decoder harness.
    LibFillerAuthDecodeHarness internal harness;

    /// @notice Destination used by canonical payloads.
    address internal constant DESTINATION = address(0xD357);

    /// @notice Premium target filler used by canonical payloads.
    address internal constant PREMIUM_FOR = address(0xF111);

    /// @notice Sets up the harness.
    function setUp() public {
        harness = new LibFillerAuthDecodeHarness();
    }

    /// @notice Canonical 10-tuple payloads decode successfully.
    function test_decodeCanonicalTenTuple() public view {
        bytes memory fillerAuthSig = hex"1234";
        bytes memory payload = _canonicalPayload(fillerAuthSig);

        (
            uint8 phaseU8,
            uint256 fillAmount,
            address destination,
            address premiumFor,
            uint256 minDstPerSrc,
            bytes memory decodedSig
        ) = harness.decode(payload);

        assertEq(phaseU8, uint8(RolloverTypes.HookPhase.PREMIUM));
        assertEq(fillAmount, 123);
        assertEq(destination, DESTINATION);
        assertEq(premiumFor, PREMIUM_FOR);
        assertEq(minDstPerSrc, 456);
        assertEq(decodedSig, fillerAuthSig);
    }

    /// @notice Legacy 9-tuple payloads are no longer accepted.
    function testRevert_decodeLegacyNineTuple() public {
        bytes memory legacyPayload = abi.encode(
            uint8(RolloverTypes.HookPhase.PREMIUM),
            uint256(123),
            uint256(7),
            DESTINATION,
            _emptyIntent(),
            uint256(456),
            hex"1234",
            ""
        );

        vm.expectRevert();
        harness.decode(legacyPayload);
    }

    /// @notice Truncated canonical payloads revert through abi.decode.
    function testRevert_decodeTruncatedPayload() public {
        bytes memory payload = _canonicalPayload(hex"1234");
        assembly {
            mstore(payload, 0x100)
        }

        vm.expectRevert();
        harness.decode(payload);
    }

    /// @notice Malformed dynamic offsets revert through abi.decode.
    function testRevert_decodeMalformedOffset() public {
        bytes memory payload = _canonicalPayload(hex"1234");
        assembly {
            mstore(add(add(payload, 0x20), 0xe0), 0xffff)
        }

        vm.expectRevert();
        harness.decode(payload);
    }

    /// @notice Payloads with a malformed dynamic tail length revert through abi.decode.
    function testRevert_decodeWrongTailLength() public {
        bytes memory payload = _canonicalPayload(hex"1234");
        assembly {
            mstore(add(add(payload, 0x20), 0x100), 0x120)
            mstore(add(add(payload, 0x20), 0x120), 0xffff)
        }

        vm.expectRevert();
        harness.decode(payload);
    }

    function _canonicalPayload(bytes memory fillerAuthSig) internal pure returns (bytes memory) {
        return abi.encode(
            uint8(RolloverTypes.HookPhase.PREMIUM),
            uint256(123),
            uint256(7),
            DESTINATION,
            PREMIUM_FOR,
            _emptyIntent(),
            uint256(456),
            fillerAuthSig,
            bytes32(0),
            ""
        );
    }

    function _emptyIntent() internal pure returns (RolloverTypes.RolloverIntent memory intent) {
        intent.rolloverContract = address(0xC311);
    }
}
