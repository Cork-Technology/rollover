// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { OnlyDelegatecall } from "src/modules/OnlyDelegatecall.sol";

/// @title PostRolloverReferenceModule
/// @notice Reference post-rollover hook that emits a balance snapshot after `deposit`. Intended
///         as a minimal, no-op example demonstrating the post-hook interface.
/// @dev DELEGATE-CALL ONLY. Direct calls to the deployed module address revert
///      `OnlyDelegatecall__DirectCallForbidden`. The reference modules are delegate-call
///      hook targets; do not send tokens to the deployed address.
/// @custom:security-contact security@cork.tech
contract PostRolloverReferenceModule is OnlyDelegatecall {
    /// @notice Emitted once per post-rollover-hook invocation.
    /// @param rolloverContract Address that ran the hook.
    /// @param orderDigest Canonical order digest.
    /// @param token Observed token.
    /// @param balance Observed balance at hook entry.
    /// @param timestamp Block timestamp at hook entry.
    event PostRolloverSnapshot(
        address indexed rolloverContract,
        bytes32 indexed orderDigest,
        address indexed token,
        uint256 balance,
        uint256 timestamp
    );

    /// @notice Snapshot the caller's balance for `token` and emit it.
    /// @param orderDigest Canonical order digest.
    /// @param token Token whose balance is sampled.
    /// @custom:invariant INV-REFERENCE-MODULES-DELEGATECALL-ONLY
    function execute(bytes32 orderDigest, IERC20 token) external onlyDelegatecall {
        emit PostRolloverSnapshot(
            address(this),
            orderDigest,
            address(token),
            token.balanceOf(address(this)),
            block.timestamp
        );
    }
}
