// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";
import {
    blocksCancel,
    blocksReclaim,
    blocksRollover,
    isHardTerminal,
    isMarkExpiredStatus
} from "src/types/SettlerTypes.sol";

/// @notice Unit tests for Settler order-status predicate helpers.
contract SettlerTypesTest is Test {
    /// @notice Verifies hard-terminal status classification.
    function test_isHardTerminal() external pure {
        assertFalse(isHardTerminal(RolloverTypes.OrderStatus.None));
        assertFalse(isHardTerminal(RolloverTypes.OrderStatus.Opened));
        assertTrue(isHardTerminal(RolloverTypes.OrderStatus.Settled));
        assertTrue(isHardTerminal(RolloverTypes.OrderStatus.Expired));
        assertTrue(isHardTerminal(RolloverTypes.OrderStatus.Cancelled));
        assertFalse(isHardTerminal(RolloverTypes.OrderStatus.Closing));
    }

    /// @notice Verifies rollover-blocking status classification.
    function test_blocksRollover() external pure {
        assertFalse(blocksRollover(RolloverTypes.OrderStatus.None));
        assertFalse(blocksRollover(RolloverTypes.OrderStatus.Opened));
        assertTrue(blocksRollover(RolloverTypes.OrderStatus.Settled));
        assertTrue(blocksRollover(RolloverTypes.OrderStatus.Expired));
        assertTrue(blocksRollover(RolloverTypes.OrderStatus.Cancelled));
        assertTrue(blocksRollover(RolloverTypes.OrderStatus.Closing));
    }

    /// @notice Verifies reclaim-blocking status classification.
    function test_blocksReclaim() external pure {
        assertFalse(blocksReclaim(RolloverTypes.OrderStatus.None));
        assertFalse(blocksReclaim(RolloverTypes.OrderStatus.Opened));
        assertTrue(blocksReclaim(RolloverTypes.OrderStatus.Settled));
        assertFalse(blocksReclaim(RolloverTypes.OrderStatus.Expired));
        assertTrue(blocksReclaim(RolloverTypes.OrderStatus.Cancelled));
        assertFalse(blocksReclaim(RolloverTypes.OrderStatus.Closing));
    }

    /// @notice Verifies cancel-blocking status classification.
    function test_blocksCancel() external pure {
        assertFalse(blocksCancel(RolloverTypes.OrderStatus.None));
        assertFalse(blocksCancel(RolloverTypes.OrderStatus.Opened));
        assertTrue(blocksCancel(RolloverTypes.OrderStatus.Settled));
        assertTrue(blocksCancel(RolloverTypes.OrderStatus.Expired));
        assertTrue(blocksCancel(RolloverTypes.OrderStatus.Cancelled));
        assertTrue(blocksCancel(RolloverTypes.OrderStatus.Closing));
    }

    /// @notice Verifies mark-expired admissible status classification.
    function test_isMarkExpiredStatus() external pure {
        assertFalse(isMarkExpiredStatus(RolloverTypes.OrderStatus.None));
        assertTrue(isMarkExpiredStatus(RolloverTypes.OrderStatus.Opened));
        assertFalse(isMarkExpiredStatus(RolloverTypes.OrderStatus.Settled));
        assertFalse(isMarkExpiredStatus(RolloverTypes.OrderStatus.Expired));
        assertFalse(isMarkExpiredStatus(RolloverTypes.OrderStatus.Cancelled));
        assertTrue(isMarkExpiredStatus(RolloverTypes.OrderStatus.Closing));
    }
}
