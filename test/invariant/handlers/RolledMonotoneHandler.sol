// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { CommonBase } from "forge-std/Base.sol";
import { StdCheats } from "forge-std/StdCheats.sol";
import { StdUtils } from "forge-std/StdUtils.sol";

import { ICorkRolloverContract } from "src/interfaces/rollover/ICorkRolloverContract.sol";

/// @notice N-INV-ROLLED-MONOTONE-AND-BOUNDED family handler — drives rollover dispatches to probe rolled-quantity monotonicity and bound.
/// @custom:invariant N-INV-ROLLED-MONOTONE-AND-BOUNDED
contract RolledMonotoneHandler is CommonBase, StdCheats, StdUtils {
    /// @notice RolloverContract ref.
    /// @return rolloverContractRef Stored rolloverContract ref value.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)

    ICorkRolloverContract public immutable rolloverContractRef;
    /// @notice Observed orders.
    /// @return observedOrders Stored observed orders value.

    bytes32[] public observedOrders;
    /// @notice Observed.
    /// @return observed Stored observed value.

    mapping(bytes32 => bool) public observed;
    /// @notice Last observed rolled.
    /// @return lastObservedRolled Stored last observed rolled value.

    mapping(bytes32 => uint256) public lastObservedRolled;
    /// @notice Terminal bit observed.
    /// @return terminalBitObserved Stored terminal bit observed value.

    mapping(bytes32 => bool) public terminalBitObserved;
    /// @notice Snapshotted order size.
    /// @return snapshottedOrderSize Stored snapshotted order size value.

    mapping(bytes32 => uint256) public snapshottedOrderSize;
    /// @notice Snapshotted.
    /// @return snapshotted Stored snapshotted value.

    mapping(bytes32 => bool) public snapshotted;
    /// @notice Monotone violated.
    /// @return monotoneViolated Stored monotone violated value.

    bool public monotoneViolated;
    /// @notice Bound violated.
    /// @return boundViolated Stored bound violated value.

    bool public boundViolated;
    /// @notice Terminal bit cleared.
    /// @return terminalBitCleared Stored terminal bit cleared value.

    bool public terminalBitCleared;
    /// @notice Ghost observations.
    /// @return ghostObservations Stored ghost observations value.

    uint64 public ghostObservations;
    /// @notice Ghost registrations.
    /// @return ghostRegistrations Stored ghost registrations value.

    uint64 public ghostRegistrations;
    /// @notice Ghost warps.
    /// @return ghostWarps Stored ghost warps value.

    uint64 public ghostWarps;
    /// @notice Ghost bound sets.
    /// @return ghostBoundSets Stored ghost bound sets value.

    uint64 public ghostBoundSets;

    /// @param rolloverContract_ rolloverContract_.
    constructor(ICorkRolloverContract rolloverContract_) {
        rolloverContractRef = rolloverContract_;
    }

    /// @notice handler action: register order id.
    /// @param seed Fuzz seed.
    function registerOrderId(bytes32 seed) external {
        if (observed[seed]) {
            return;
        }
        observed[seed] = true;
        observedOrders.push(seed);
        ICorkRolloverContract.RolloverContractOrderState memory v =
            rolloverContractRef.orderState(seed);
        lastObservedRolled[seed] = v.rolled;
        terminalBitObserved[seed] = v.rolloverTerminal;
        ghostRegistrations++;
    }

    /// @notice handler action: observe order state.
    /// @param indexSeed Fuzz seed used to pick an index from a bounded set.
    function observeOrderState(uint256 indexSeed) external {
        uint256 n = observedOrders.length;
        if (n == 0) {
            return;
        }
        bytes32 id = observedOrders[bound(indexSeed, 0, n - 1)];
        ICorkRolloverContract.RolloverContractOrderState memory v =
            rolloverContractRef.orderState(id);

        if (v.rolled < lastObservedRolled[id]) {
            monotoneViolated = true;
        } else {
            lastObservedRolled[id] = v.rolled;
        }

        if (snapshotted[id] && v.rolled > snapshottedOrderSize[id]) {
            boundViolated = true;
        }

        if (terminalBitObserved[id] && !v.rolloverTerminal) {
            terminalBitCleared = true;
        } else if (v.rolloverTerminal) {
            terminalBitObserved[id] = true;
        }

        ghostObservations++;
    }

    /// @notice handler action: set order size.
    /// @param indexSeed Fuzz seed used to pick an index from a bounded set.
    /// @param sizeSeed Fuzz seed used to pick a size from a bounded set.
    function setOrderSize(uint256 indexSeed, uint256 sizeSeed) external {
        uint256 n = observedOrders.length;
        if (n == 0) {
            return;
        }
        bytes32 id = observedOrders[bound(indexSeed, 0, n - 1)];
        ICorkRolloverContract.RolloverContractOrderState memory v =
            rolloverContractRef.orderState(id);
        uint256 floor = v.rolled;
        uint256 size = bound(sizeSeed, floor, type(uint128).max);
        snapshottedOrderSize[id] = size;
        snapshotted[id] = true;
        ghostBoundSets++;
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
        return observedOrders.length;
    }
}
