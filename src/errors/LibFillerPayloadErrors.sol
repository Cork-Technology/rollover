// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

/// @notice Rollover leg carried a nonzero premium amount.
error FillerPayload__InvalidRolloverShape();

/// @notice Inner leg phase discriminator does not match the expected hook phase.
/// @param expected Expected `HookPhase` value.
/// @param actual Decoded phase byte.
error FillerPayload__InvalidPhase(uint8 expected, uint8 actual);

/// @notice Atomic envelope dispatch tag is not `ATOMIC_TAG`.
error FillerPayload__AtomicTagRequired();
