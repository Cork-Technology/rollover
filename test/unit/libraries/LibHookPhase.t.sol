// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Test } from "forge-std/Test.sol";
import { LibHookPhase__OutOfRange } from "src/errors/LibHookPhaseErrors.sol";
import { LibHookPhase } from "src/libraries/LibHookPhase.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice Test harness exposing `LibHookPhase.from`.
contract LibHookPhaseHarness {
    /// @notice Convert a raw phase value into a hook phase.
    /// @param value Raw phase discriminator.
    /// @return phase Validated hook phase.
    function from(uint8 value) external pure returns (RolloverTypes.HookPhase phase) {
        return LibHookPhase.from(value);
    }
}

/// @notice Unit coverage for raw hook-phase conversion boundaries.
contract LibHookPhaseTest is Test {
    /// @notice Harness exposing the internal library helper.
    LibHookPhaseHarness internal harness;

    /// @notice Deploy a fresh harness.
    function setUp() public {
        harness = new LibHookPhaseHarness();
    }

    /// @notice Pins behaviour: rollover and premium phase values convert successfully.
    function test_hookPhaseFrom_acceptsRolloverAndPremium() public view {
        assertEq(uint8(harness.from(0)), uint8(RolloverTypes.HookPhase.ROLLOVER));
        assertEq(uint8(harness.from(1)), uint8(RolloverTypes.HookPhase.PREMIUM));
    }

    /// @notice Pins behaviour: out-of-range raw values are rejected with the supplied value.
    function test_hookPhaseFrom_outOfRange_revertsWithValue() public {
        _expectOutOfRange(2);
        _expectOutOfRange(4);
        _expectOutOfRange(type(uint8).max);
    }

    /// @notice Assert a raw value reverts with `LibHookPhase__OutOfRange(value)`.
    /// @param value Raw out-of-range phase value.
    function _expectOutOfRange(uint8 value) internal {
        vm.expectRevert(abi.encodeWithSelector(LibHookPhase__OutOfRange.selector, value));
        harness.from(value);
    }
}
