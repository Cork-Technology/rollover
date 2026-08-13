// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { CommonBase } from "forge-std/Base.sol";
import { StdCheats } from "forge-std/StdCheats.sol";
import { StdUtils } from "forge-std/StdUtils.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice INV-DST-CST-REACHABLE family handler — drives observe/warp ops while tracking settler dstCST balance.
/// @custom:invariant INV-DST-CST-REACHABLE
contract DstCstReachabilityHandler is CommonBase, StdCheats, StdUtils {
    /// @notice Dst cst.
    /// @return dstCst Stored dst cst value.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)

    IERC20 public immutable dstCst;
    /// @notice Settler.
    /// @return settler Stored settler value.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)

    address public immutable settler;
    /// @notice RolloverContract.
    /// @return rolloverContract Stored rolloverContract value.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)

    address public immutable rolloverContract;
    /// @notice Ghost produced.
    /// @return ghostProduced Stored ghost produced value.

    uint256 public ghostProduced;
    /// @notice Ghost credited.
    /// @return ghostCredited Stored ghost credited value.

    uint256 public ghostCredited;

    // forge-lint: disable-next-line(missing-zero-check)
    /// @param rolloverContract_ rolloverContract_.
    /// @param settler_ settler_.
    /// @param dstCst_ dstCst_.
    // Invariant handler mirrors arbitrary settler and rolloverContract configured by the fixture.
    // forge-lint: disable-next-line(missing-zero-check)
    constructor(IERC20 dstCst_, address settler_, address rolloverContract_) {
        dstCst = dstCst_;
        settler = settler_;
        rolloverContract = rolloverContract_;
    }
    /// @notice Ghost observations.
    /// @return ghostObservations Stored ghost observations value.

    uint64 public ghostObservations;

    /// @notice handler action: observe.
    function observe() external {
        ghostObservations++;
    }
}
