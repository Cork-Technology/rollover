// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

/// @title LibLastDeliveredPremium
/// @author Cork Technology
/// @notice Slot-derivation + tload/tstore helpers for the per-token "just-delivered premium"
///         transient register that `CorkRolloverContract._handlePhasePremium` writes for the duration
///         of a single PREMIUM hook frame.
/// @dev This library is the integration contract between the rolloverContract and any delegatecalled
///      premium hook module that wants to consume the just-delivered amount without the cPT holder
///      having to know the exact figure at intent-signing time. Modules MUST execute via
///      `delegatecall` from the rolloverContract — `address(this)` must be the rolloverContract so that `tload`
///      reads the rolloverContract's transient storage and not the module's.
///
///      The slot is an **information channel**, not an authorization channel: writing it
///      from a delegatecalled hook does NOT bypass `CorkRolloverContract`'s
///      `INV-PREMIUM-HOOKS-CANNOT-SWEEP-STANDING-BALANCE` post-hook balance trip-wire. The
///      trip-wire is the load-bearing safety; this library is purely a "what amount just
///      arrived" register.
/// @custom:security-contact security@cork.tech
library LibLastDeliveredPremium {
    /// @notice Base seed for the per-token transient slot. The actual per-token slot is
    ///         `keccak256(abi.encodePacked(_BASE, token))`. The literal string is preserved
    ///         from the prior in-rolloverContract definition so any external indexer or tooling that
    ///         encoded the slot derivation continues to resolve to the same byte sequence.
    bytes32 internal constant _BASE = keccak256("cork.rolloverContract.lastDeliveredPremium");

    /// @notice Compute the per-token transient slot used by the rolloverContract's
    ///         `_handlePhasePremium` write site and any delegatecalled hook reading it.
    /// @param token Token whose slot is being derived.
    /// @return s Per-token transient slot.
    function slotFor(address token) internal pure returns (bytes32 s) {
        s = keccak256(abi.encodePacked(_BASE, token));
    }

    /// @notice Read the current value of the per-token slot from the executing contract's
    ///         transient storage. Returns zero when the slot has not been written in the
    ///         current transaction.
    /// @dev Inlines the slot derivation to avoid an extra memory load. Callers that need the
    ///      raw slot can call `slotFor` directly.
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
    /// @dev Inlines the slot derivation to avoid an extra memory load. Writing from a
    ///      delegatecalled hook does NOT bypass the rolloverContract's post-hook balance trip-wire;
    ///      the slot is an information channel only.
    /// @param token Token whose slot is being written.
    /// @param amount Value to write into the per-token slot.
    function write(address token, uint256 amount) internal {
        bytes32 s = keccak256(abi.encodePacked(_BASE, token));
        assembly ("memory-safe") {
            tstore(s, amount)
        }
    }
}
