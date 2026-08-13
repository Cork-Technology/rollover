// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { CommonBase } from "forge-std/Base.sol";
import { StdCheats } from "forge-std/StdCheats.sol";
import { StdUtils } from "forge-std/StdUtils.sol";

import { IPartialSettler } from "src/interfaces/settlers/IPartialSettler.sol";

/// @notice INV-PARTICIPANT-COUNT-MONOTONIC family handler — drives multi-filler fill attempts to probe participantCount monotonicity.
/// @custom:invariant INV-PARTICIPANT-COUNT-MONOTONIC
contract ParticipantCountHandler is CommonBase, StdCheats, StdUtils {
    /// @notice Settler.
    /// @return settler Stored settler value.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)

    IPartialSettler public immutable settler;
    /// @notice Observed orders.
    /// @return observedOrders Stored observed orders value.

    bytes32[] public observedOrders;
    /// @notice Observed.
    /// @return observed Stored observed value.

    mapping(bytes32 => bool) public observed;
    /// @notice Last count.
    /// @return lastCount Stored last count value.

    mapping(bytes32 => uint32) public lastCount;
    /// @notice Ghost observations.
    /// @return ghostObservations Stored ghost observations value.

    uint64 public ghostObservations;
    /// @notice Ghost warps.
    /// @return ghostWarps Stored ghost warps value.

    uint64 public ghostWarps;
    /// @notice Ghost registrations.
    /// @return ghostRegistrations Stored ghost registrations value.

    uint64 public ghostRegistrations;

    /// @param settler_ settler_.
    constructor(IPartialSettler settler_) {
        settler = settler_;
    }

    /// @notice handler action: observe.
    function observe() external {
        ghostObservations++;
    }

    /// @notice handler action: register order id.
    /// @param seed Fuzz seed.
    function registerOrderId(bytes32 seed) external {
        if (observed[seed]) {
            return;
        }
        observed[seed] = true;
        observedOrders.push(seed);
        lastCount[seed] = settler.rolloverAccountingOf(seed).participantSlotCount;
        ghostRegistrations++;
    }

    /// @notice handler action: observe order count.
    /// @param indexSeed Fuzz seed used to pick an index from a bounded set.
    function observeOrderCount(uint256 indexSeed) external {
        uint256 n = observedOrders.length;
        if (n == 0) {
            return;
        }
        uint256 idx = bound(indexSeed, 0, n - 1);
        bytes32 id = observedOrders[idx];
        uint32 live = settler.rolloverAccountingOf(id).participantSlotCount;
        require(live >= lastCount[id], "INV-PARTICIPANT-COUNT-MONOTONIC: regressed");
        lastCount[id] = live;
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
