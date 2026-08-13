// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { CommonBase } from "forge-std/Base.sol";
import { StdCheats } from "forge-std/StdCheats.sol";
import { StdUtils } from "forge-std/StdUtils.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice INV-DEFAULTER-RECOUP family handler — drives observe/warp ops to probe stranded defaulter dstCST at the settler.
/// @custom:invariant INV-DEFAULTER-RECOUP
contract DefaulterReclaimHandler is CommonBase, StdCheats, StdUtils {
    /// @notice Settler.
    /// @return settler Stored settler value.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)

    address public immutable settler;
    /// @notice Dst cst.
    /// @return dstCst Stored dst cst value.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)

    IERC20 public immutable dstCst;
    /// @notice Ghost observations.
    /// @return ghostObservations Stored ghost observations value.

    uint64 public ghostObservations;
    /// @notice Ghost warps.
    /// @return ghostWarps Stored ghost warps value.

    uint64 public ghostWarps;

    // forge-lint: disable-next-line(missing-zero-check)
    /// @param dstCst_ dstCst_.
    /// @param settler_ settler_.
    // Invariant handler mirrors arbitrary settler configured by the fixture.
    // forge-lint: disable-next-line(missing-zero-check)
    constructor(address settler_, IERC20 dstCst_) {
        settler = settler_;
        dstCst = dstCst_;
    }

    /// @notice handler action: observe.
    function observe() external {
        ghostObservations++;
    }

    /// @notice handler action: warp forward.
    /// @param delta Numeric delta.
    function warpForward(uint64 delta) external {
        uint64 d = uint64(bound(delta, 0, 3 days));
        vm.warp(block.timestamp + d);
        ghostWarps++;
    }
}
