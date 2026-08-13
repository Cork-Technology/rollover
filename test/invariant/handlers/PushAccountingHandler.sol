// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { CommonBase } from "forge-std/Base.sol";
import { StdCheats } from "forge-std/StdCheats.sol";
import { StdUtils } from "forge-std/StdUtils.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice F-PUSH family handler — drives push-accounting inflow / payout ops for ledger reconciliation.
/// @custom:invariant F-PUSH
contract PushAccountingHandler is CommonBase, StdCheats, StdUtils {
    /// @notice Src cst.
    /// @return srcCst Stored src cst value.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)

    IERC20 public immutable srcCst;
    /// @notice Settler.
    /// @return settler Stored settler value.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)

    address public immutable settler;
    /// @notice Ghost src cst into settler.
    /// @return ghostSrcCstIntoSettler Stored ghost src cst into settler value.

    uint256 public ghostSrcCstIntoSettler;
    /// @notice Ghost src cst out of settler.
    /// @return ghostSrcCstOutOfSettler Stored ghost src cst out of settler value.

    uint256 public ghostSrcCstOutOfSettler;
    /// @notice Ghost observations.
    /// @return ghostObservations Stored ghost observations value.

    uint64 public ghostObservations;
    /// @notice Ghost warps.
    /// @return ghostWarps Stored ghost warps value.

    uint64 public ghostWarps;

    // forge-lint: disable-next-line(missing-zero-check)
    /// @param settler_ settler_.
    /// @param srcCst_ srcCst_.
    // Invariant handler mirrors arbitrary settler configured by the fixture.
    // forge-lint: disable-next-line(missing-zero-check)
    constructor(IERC20 srcCst_, address settler_) {
        srcCst = srcCst_;
        settler = settler_;
    }

    /// @notice handler action: observe.
    function observe() external {
        ghostObservations++;
    }

    /// @notice handler action: warp forward.
    /// @param delta Numeric delta.
    function warpForward(uint64 delta) external {
        uint64 d = uint64(bound(delta, 0, 1 hours));
        vm.warp(block.timestamp + d);
        ghostWarps++;
    }
}
