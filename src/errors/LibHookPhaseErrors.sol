// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

/// @notice Reverts when `value` does not encode a recognised `HookPhase` variant.
/// @param value Out-of-range raw `uint8` supplied by the caller.
error LibHookPhase__OutOfRange(uint8 value);
