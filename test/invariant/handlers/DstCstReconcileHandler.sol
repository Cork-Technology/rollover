// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { CommonBase } from "forge-std/Base.sol";
import { StdCheats } from "forge-std/StdCheats.sol";
import { StdUtils } from "forge-std/StdUtils.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IPartialSettler } from "src/interfaces/settlers/IPartialSettler.sol";

/// @notice INV-DST-CST-RECONCILES family handler — drives per-order dstCST inflow vs payout reconciliation probes.
/// @custom:invariant INV-DST-CST-RECONCILES
contract DstCstReconcileHandler is CommonBase, StdCheats, StdUtils {
    /// @notice Settler.
    /// @return settler Stored settler value.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)

    IPartialSettler public immutable settler;
    /// @notice Dst cst.
    /// @return dstCst Stored dst cst value.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)

    IERC20 public immutable dstCst;
    /// @notice Observed orders.
    /// @return observedOrders Stored observed orders value.

    bytes32[] public observedOrders;
    /// @notice Observed.
    /// @return observed Stored observed value.

    mapping(bytes32 => bool) public observed;
    /// @notice Ghost observations.
    /// @return ghostObservations Stored ghost observations value.

    uint64 public ghostObservations;
    /// @notice Ghost warps.
    /// @return ghostWarps Stored ghost warps value.

    uint64 public ghostWarps;
    /// @notice Ghost registrations.
    /// @return ghostRegistrations Stored ghost registrations value.

    uint64 public ghostRegistrations;

    /// @param dstCst_ dstCst_.
    /// @param settler_ settler_.
    constructor(IPartialSettler settler_, IERC20 dstCst_) {
        settler = settler_;
        dstCst = dstCst_;
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

    /// @notice handler action: sum partial escrow.
    /// @return total Total value.
    function sumPartialEscrow() external view returns (uint256 total) {
        uint256 n = observedOrders.length;
        for (uint256 i = 0; i < n; ++i) {
            total += settler.rolloverAccountingOf(observedOrders[i]).dstCstEscrowed;
        }
    }
}
