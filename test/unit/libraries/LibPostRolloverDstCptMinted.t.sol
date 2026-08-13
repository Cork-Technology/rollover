// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Test } from "forge-std/Test.sol";
import { LibPostRolloverDstCptMinted } from "src/libraries/LibPostRolloverDstCptMinted.sol";

/// @notice Thin harness exposing `LibPostRolloverDstCptMinted` internal helpers.
contract LibPostRolloverDstCptMintedHarness {
    /// @notice Expose `slotFor` for derivation tests.
    /// @param token Token whose slot is being derived.
    /// @return slot Per-token transient slot.
    function slotFor(address token) external pure returns (bytes32 slot) {
        return LibPostRolloverDstCptMinted.slotFor(token);
    }
}

/// @notice Unit tests for `LibPostRolloverDstCptMinted` slot compatibility.
contract LibPostRolloverDstCptMintedTest is Test {
    /// @notice Harness exposing library internals as external entry points.
    LibPostRolloverDstCptMintedHarness internal harness;

    /// @notice Token sentinel used in derivation tests.
    address internal token = address(0xD57C);

    /// @notice Deploy a fresh harness for each test.
    function setUp() public {
        harness = new LibPostRolloverDstCptMintedHarness();
    }

    /// @notice Slot seed uses the minted terminology exposed by the helper library.
    function test_slotFor_usesDstCptMintedSeed() public view {
        bytes32 base = keccak256("cork.rolloverContract.postRolloverDstCptMinted");
        bytes32 expected = keccak256(abi.encodePacked(base, token));
        assertEq(harness.slotFor(token), expected, "slot seed drift");
    }
}
