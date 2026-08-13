// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { CommonBase } from "forge-std/Base.sol";
import { StdCheats } from "forge-std/StdCheats.sol";
import { StdUtils } from "forge-std/StdUtils.sol";

import { ISettler } from "src/interfaces/settlers/ISettler.sol";

/// @notice BS-ST-20 family handler — drives OrderStatus transitions and time-warps.
/// @custom:invariant BS-ST-20
contract OrderStateMachineHandler is CommonBase, StdCheats, StdUtils {
    /// @notice Settler.
    /// @return settler Stored settler value.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)

    ISettler public immutable settler;
    /// @notice Observed orders.
    /// @return observedOrders Stored observed orders value.

    bytes32[] public observedOrders;
    /// @notice Observed.
    /// @return observed Stored observed value.

    mapping(bytes32 => bool) public observed;
    /// @notice First non none status.
    /// @return firstNonNoneStatus Stored first non none status value.

    mapping(bytes32 => uint8) public firstNonNoneStatus;
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
    constructor(ISettler settler_) {
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
        uint8 s = uint8(settler.orderStatus(seed));
        if (s != 0) {
            firstNonNoneStatus[seed] = s;
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
        return observedOrders.length;
    }

    /// @notice handler action: is terminal.
    /// @param s String value or scratch value.
    /// @return Return value.
    function isTerminal(uint8 s) external pure returns (bool) {
        return s == 2 || s == 3 || s == 4;
    }
}
