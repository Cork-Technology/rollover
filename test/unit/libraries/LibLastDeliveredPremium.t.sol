// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Test } from "forge-std/Test.sol";
import { LibLastDeliveredPremium } from "src/libraries/LibLastDeliveredPremium.sol";

/// @notice Thin harness exposing `LibLastDeliveredPremium` internal helpers as external
///         entry points. Library calls execute in the harness's storage context, so the
///         transient slot under test lives on this contract.
contract LibLastDeliveredPremiumHarness {
    /// @notice Expose `slotFor` for derivation tests.
    /// @param token Token whose slot is being derived.
    /// @return slot Per-token transient slot.
    function slotFor(address token) external pure returns (bytes32 slot) {
        return LibLastDeliveredPremium.slotFor(token);
    }

    /// @notice Expose `read` for slot-read tests.
    /// @param token Token whose slot is being read.
    /// @return amount Current value stored in the transient slot.
    function read(address token) external view returns (uint256 amount) {
        return LibLastDeliveredPremium.read(token);
    }

    /// @notice Expose `write` for slot-write tests.
    /// @param token Token whose slot is being written.
    /// @param amount Value to store in the transient slot.
    function write(address token, uint256 amount) external {
        LibLastDeliveredPremium.write(token, amount);
    }

    /// @notice Atomic write-then-read in the same external call (same tx) so callers can
    ///         exercise the round-trip semantics without relying on cross-call transient
    ///         persistence guarantees that forge-std cannot cheat into being predictable.
    /// @param token Token whose slot is being written and immediately read.
    /// @param amount Value to write.
    /// @return roundtrip Value read back from the slot after the write.
    function writeAndReadInSameTx(address token, uint256 amount)
        external
        returns (uint256 roundtrip)
    {
        LibLastDeliveredPremium.write(token, amount);
        roundtrip = LibLastDeliveredPremium.read(token);
    }

    /// @notice Atomic two-token write + per-token read in the same call so the per-token
    ///         keying property can be asserted without inter-call transient assumptions.
    /// @param tokenA First token.
    /// @param tokenB Second token (distinct from `tokenA`).
    /// @param amountA Value to write into `tokenA`'s slot.
    /// @param amountB Value to write into `tokenB`'s slot.
    /// @return readA Value read back from `tokenA`'s slot.
    /// @return readB Value read back from `tokenB`'s slot.
    function writeTwoAndReadInSameTx(
        address tokenA,
        address tokenB,
        uint256 amountA,
        uint256 amountB
    ) external returns (uint256 readA, uint256 readB) {
        LibLastDeliveredPremium.write(tokenA, amountA);
        LibLastDeliveredPremium.write(tokenB, amountB);
        readA = LibLastDeliveredPremium.read(tokenA);
        readB = LibLastDeliveredPremium.read(tokenB);
    }

    /// @notice Atomic write, write-zero, read in the same call to assert that writing zero
    ///         clears the slot (read returns zero) in the same transaction.
    /// @param token Token whose slot is being written and cleared.
    /// @param amount Value to write before the clear.
    /// @return afterClear Value read after the clear write.
    function writeThenZeroThenRead(address token, uint256 amount)
        external
        returns (uint256 afterClear)
    {
        LibLastDeliveredPremium.write(token, amount);
        LibLastDeliveredPremium.write(token, 0);
        afterClear = LibLastDeliveredPremium.read(token);
    }
}

/// @notice Unit tests for `LibLastDeliveredPremium` — slot derivation determinism, per-token
///         keying, and write/read round-trip semantics against a thin harness contract.
contract LibLastDeliveredPremiumTest is Test {
    /// @notice Harness exposing library internals as external entry points.
    LibLastDeliveredPremiumHarness internal harness;

    /// @notice First token sentinel used in keying tests.
    address internal tokenA = address(0xA1);
    /// @notice Second token sentinel, distinct from `tokenA`.
    address internal tokenB = address(0xB2);

    /// @notice Deploy a fresh harness for each test.
    function setUp() public {
        harness = new LibLastDeliveredPremiumHarness();
    }

    /// @notice T-LIB-1 — slot derivation is deterministic per token and distinct across
    ///         tokens. Pins the per-token keying invariant.
    function test_slotFor_isDeterministicAndDistinctPerToken() public view {
        bytes32 slotA1 = harness.slotFor(tokenA);
        bytes32 slotA2 = harness.slotFor(tokenA);
        bytes32 slotBb = harness.slotFor(tokenB);
        assertEq(slotA1, slotA2, "slotFor(tokenA) must be deterministic");
        assertTrue(slotA1 != slotBb, "slotFor must distinguish tokens");
    }

    /// @notice T-LIB-2 — the derived slot equals
    ///         `keccak256(abi.encodePacked(keccak256("cork.rolloverContract.lastDeliveredPremium"), token))`.
    ///         Pins the wire format so a future refactor cannot silently shift the slot.
    function test_slotFor_matchesInlinedDerivation() public view {
        bytes32 base = keccak256("cork.rolloverContract.lastDeliveredPremium");
        bytes32 expected = keccak256(abi.encodePacked(base, tokenA));
        assertEq(harness.slotFor(tokenA), expected, "slot derivation drift");
    }

    /// @notice T-LIB-3 — a fresh harness with no prior write reads zero.
    function test_read_returnsZeroBeforeAnyWrite() public view {
        assertEq(harness.read(tokenA), 0, "fresh slot must read zero");
    }

    /// @notice T-LIB-4 — write/read round-trip in the same call returns the written value.
    function test_writeThenRead_roundtripsAmount() public {
        uint256 amount = 123;
        assertEq(
            harness.writeAndReadInSameTx(tokenA, amount), amount, "round-trip must preserve value"
        );
    }

    /// @notice T-LIB-6 — writes to different tokens do not bleed; each per-token slot is
    ///         independent.
    function test_write_isPerTokenIsolated() public {
        (uint256 readA, uint256 readB) = harness.writeTwoAndReadInSameTx(tokenA, tokenB, 7, 9);
        assertEq(readA, 7, "tokenA slot");
        assertEq(readB, 9, "tokenB slot");
    }

    /// @notice T-LIB-7 — writing zero clears the slot (read returns zero in the same tx).
    function test_writeZero_clearsSlot() public {
        assertEq(harness.writeThenZeroThenRead(tokenA, 100), 0, "write-zero must clear");
    }
}
