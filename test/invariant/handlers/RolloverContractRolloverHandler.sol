// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { CommonBase } from "forge-std/Base.sol";
import { StdCheats } from "forge-std/StdCheats.sol";
import { StdUtils } from "forge-std/StdUtils.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice INV-CPT-CONTAINED family handler — drives bounded time-warps to observe rolloverContract CPT residency.
/// @custom:invariant INV-CPT-CONTAINED
contract RolloverContractRolloverHandler is CommonBase, StdCheats, StdUtils {
    /// @notice RolloverContract.
    /// @return rolloverContract Stored rolloverContract value.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)

    address public immutable rolloverContract;
    /// @notice Src cpt.
    /// @return srcCpt Stored src cpt value.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)

    IERC20 public immutable srcCpt;
    /// @notice Dst cpt.
    /// @return dstCpt Stored dst cpt value.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)

    IERC20 public immutable dstCpt;
    /// @notice Ghost observations.
    /// @return ghostObservations Stored ghost observations value.

    uint64 public ghostObservations;
    /// @notice Ghost warps.
    /// @return ghostWarps Stored ghost warps value.

    uint64 public ghostWarps;

    // forge-lint: disable-next-line(missing-zero-check)
    /// @param dstCpt_ dstCpt_.
    /// @param srcCpt_ srcCpt_.
    /// @param rolloverContract_ rolloverContract_.
    // Invariant handler mirrors arbitrary rolloverContract configured by the fixture.
    // forge-lint: disable-next-line(missing-zero-check)
    constructor(address rolloverContract_, IERC20 srcCpt_, IERC20 dstCpt_) {
        rolloverContract = rolloverContract_;
        srcCpt = srcCpt_;
        dstCpt = dstCpt_;
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
