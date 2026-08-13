// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { LibHookPhase__OutOfRange } from "src/errors/LibHookPhaseErrors.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @title LibHookPhase
/// @notice Safe `uint8 → HookPhase` conversion used at every Settler/RolloverContract phase boundary.
library LibHookPhase {
    /// @notice Convert a raw `uint8` into a `RolloverTypes.HookPhase`, reverting on overflow.
    /// @param value Raw phase discriminator.
    /// @return phase Validated `HookPhase` variant.
    function from(uint8 value) internal pure returns (RolloverTypes.HookPhase phase) {
        if (value > uint8(RolloverTypes.HookPhase.PREMIUM)) {
            revert LibHookPhase__OutOfRange(value);
        }
        return RolloverTypes.HookPhase(value);
    }
}
