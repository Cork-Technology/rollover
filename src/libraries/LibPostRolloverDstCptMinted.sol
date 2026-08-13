// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

/// @title LibPostRolloverDstCptMinted
/// @author Cork Technology
/// @notice Slot-derivation + tload/tstore helpers for the per-token "newly minted dstCPT"
///         transient register that `CorkRolloverContract._finalizeRolloverLeg` writes for the
///         duration of a single POST_ROLLOVER hook frame.
/// @dev This library is the integration boundary between the rolloverContract and delegatecalled
///      post-rollover modules that route the deposit-minted dstCPT without sweeping standing
///      dstCPT. Modules MUST execute via delegatecall from the rolloverContract — `address(this)`
///      must be the rolloverContract so that `tload` reads the rolloverContract's transient
///      storage and not the module's.
///
///      The slot is an **information channel**, not an authorization channel: the final
///      `CorkRolloverContract__DstCptNotRestored` balance guard remains the load-bearing invariant
///      that rejects missing, under-routed, over-routed, or standing-balance-sweeping hooks.
/// @custom:security-contact security@cork.tech
library LibPostRolloverDstCptMinted {
    /// @notice Base seed for the per-token transient slot. The actual per-token slot is
    ///         `keccak256(abi.encodePacked(_BASE, token))`.
    /// @dev Pre-deployment slot seed; keep in sync with the minted terminology used by the
    ///      rolloverContract write site and post-rollover modules.
    bytes32 internal constant _BASE = keccak256("cork.rolloverContract.postRolloverDstCptMinted");

    /// @notice Compute the per-token transient slot used by the rolloverContract's
    ///         `_finalizeRolloverLeg` write site and any delegatecalled post hook reading it.
    /// @param token Token whose slot is being derived.
    /// @return s Per-token transient slot.
    function slotFor(address token) internal pure returns (bytes32 s) {
        s = keccak256(abi.encodePacked(_BASE, token));
    }

    /// @notice Read the current value of the per-token slot from the executing contract's
    ///         transient storage. Returns zero when the slot has not been written in the
    ///         current transaction.
    /// @param token Token whose slot is being read.
    /// @return amount Value currently stored at the per-token slot.
    function read(address token) internal view returns (uint256 amount) {
        bytes32 s = keccak256(abi.encodePacked(_BASE, token));
        assembly ("memory-safe") {
            amount := tload(s)
        }
    }

    /// @notice Write `amount` into the per-token slot in the executing contract's transient
    ///         storage. Writing zero clears the slot.
    /// @param token Token whose slot is being written.
    /// @param amount Value to write into the per-token slot.
    function write(address token, uint256 amount) internal {
        bytes32 s = keccak256(abi.encodePacked(_BASE, token));
        assembly ("memory-safe") {
            tstore(s, amount)
        }
    }
}
