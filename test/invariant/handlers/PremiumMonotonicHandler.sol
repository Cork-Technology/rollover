// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { CommonBase } from "forge-std/Base.sol";
import { StdCheats } from "forge-std/StdCheats.sol";
import { StdUtils } from "forge-std/StdUtils.sol";

import { ICorkRolloverContract } from "src/interfaces/rollover/ICorkRolloverContract.sol";

/// @notice INV-PREMIUM-FIRED-MONOTONIC family handler — observes rolloverContract-side
///         `premiumFiredFor` set-only monotonicity. Under atomic-fill both Settler and rolloverContract
///         premium latches commit or revert together; this handler snapshots the rolloverContract latch.
/// @custom:invariant INV-PREMIUM-FIRED-MONOTONIC
contract PremiumMonotonicHandler is CommonBase, StdCheats, StdUtils {
    /// @notice RolloverContract.
    /// @return rolloverContract Stored rolloverContract value.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)

    ICorkRolloverContract public immutable rolloverContract;

    /// @notice Pair.
    struct Pair {
        bytes32 digest;
        address filler;
    }
    /// @notice Observed (digest, filler) pairs registered during the run.
    Pair[] public observedPairs;
    /// @notice Registered.
    /// @return registered Stored registered value.

    mapping(bytes32 => mapping(address => bool)) public registered;
    /// @notice Fired snapshot.
    /// @return firedSnapshot Stored fired snapshot value.

    mapping(bytes32 => mapping(address => bool)) public firedSnapshot;
    /// @notice Ghost observations.
    /// @return ghostObservations Stored ghost observations value.

    uint64 public ghostObservations;
    /// @notice Ghost warps.
    /// @return ghostWarps Stored ghost warps value.

    uint64 public ghostWarps;
    /// @notice Ghost registrations.
    /// @return ghostRegistrations Stored ghost registrations value.

    uint64 public ghostRegistrations;

    /// @param rolloverContract_ rolloverContract_.
    constructor(ICorkRolloverContract rolloverContract_) {
        rolloverContract = rolloverContract_;
    }

    /// @notice handler action: observe.
    function observe() external {
        ghostObservations++;
    }

    /// @notice handler action: register pair.
    /// @param digestSeed Fuzz seed used to pick an order digest from a bounded set.
    /// @param fillerSeed Fuzz seed used to pick a filler from a bounded set.
    function registerPair(bytes32 digestSeed, address fillerSeed) external {
        if (registered[digestSeed][fillerSeed]) {
            return;
        }
        registered[digestSeed][fillerSeed] = true;
        observedPairs.push(Pair({ digest: digestSeed, filler: fillerSeed }));
        if (rolloverContract.premiumFiredFor(
                digestSeed, fillerSeed, bytes32(uint256(uint160(fillerSeed)))
            )) {
            firedSnapshot[digestSeed][fillerSeed] = true;
        }
        ghostRegistrations++;
    }

    /// @notice handler action: warp forward.
    /// @param delta Numeric delta.
    function warpForward(uint64 delta) external {
        uint64 d = uint64(bound(delta, 0, 1 hours));
        vm.warp(block.timestamp + d);
        ghostWarps++;
    }

    /// @notice handler action: observed count.
    /// @return Return value.
    function observedCount() external view returns (uint256) {
        return observedPairs.length;
    }
}
