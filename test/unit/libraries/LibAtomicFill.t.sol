// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Test } from "forge-std/Test.sol";
import { LibAtomicFill } from "src/libraries/LibAtomicFill.sol";

/// @notice Test harness exposing `LibAtomicFill.peekTag`.
contract LibAtomicFillHarness {
    /// @notice Peek the leading atomic-fill dispatch tag.
    /// @param fillerData ABI-encoded filler data blob.
    /// @return tag Leading discriminator, or zero for short blobs.
    function peekTag(bytes calldata fillerData) external pure returns (uint8 tag) {
        return LibAtomicFill.peekTag(fillerData);
    }
}

/// @notice Unit coverage for atomic-fill tag peeking boundaries.
contract LibAtomicFillTest is Test {
    /// @notice Harness exposing the internal library helper.
    LibAtomicFillHarness internal harness;

    /// @notice Deploy a fresh harness.
    function setUp() public {
        harness = new LibAtomicFillHarness();
    }

    /// @notice Pins behaviour: blobs shorter than one ABI word do not decode and return zero.
    function test_peekTag_shortBlob_returnsZero() public view {
        assertEq(harness.peekTag(hex""), 0);
        assertEq(harness.peekTag(hex"00"), 0);
        bytes memory shortBlob = new bytes(31);
        shortBlob[30] = bytes1(uint8(255));
        assertEq(harness.peekTag(shortBlob), 0);
    }
}
