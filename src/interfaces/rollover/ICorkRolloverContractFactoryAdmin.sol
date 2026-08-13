// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

/// @title ICorkRolloverContractFactoryAdmin
/// @notice Protocol-operator controls for the factory Settler dispatch allowlist.
interface ICorkRolloverContractFactoryAdmin {
    /// @notice Emitted when a Settler dispatch approval flag is set to true.
    /// @dev Approval is idempotent; this event may be emitted for an already-approved Settler.
    /// @param settler Settler contract address whose approval flag was set.
    event SettlerApproved(address indexed settler);

    /// @notice Emitted when a Settler dispatch approval flag is set to false.
    /// @dev Revocation is idempotent; this event may be emitted for an already-unapproved
    ///      Settler.
    /// @param settler Settler contract address whose approval flag was cleared.
    event SettlerRevoked(address indexed settler);

    /// @notice Approve `settler` for future factory-to-rolloverContract hook dispatch.
    /// @dev Only callable by `SETTLER_APPROVER_ROLE`. Rejects the zero address and addresses
    ///      with no code; it does not verify that `settler` implements a specific Settler
    ///      interface. Calling again for an already-approved address leaves it approved.
    /// @custom:invariant INV-SETTLER-APPROVED — only approved Settlers can dispatch rolloverContract hooks.
    /// @param settler Address to approve for future dispatch.
    function approveSettler(address settler) external;

    /// @notice Clear factory dispatch approval for `settler`.
    /// @dev Only callable by `SETTLER_REVOKER_ROLE`. Idempotently marks `settler`
    ///      unapproved; no current-approval, nonzero, or code check is required. Acts as an
    ///      instant kill-switch for future factory-to-rolloverContract dispatch from `settler`.
    /// @custom:invariant INV-SETTLER-APPROVED — revocation makes future dispatch from `settler`
    ///                   fail before rolloverContract execution.
    /// @param settler Address whose dispatch approval is cleared.
    function revokeSettler(address settler) external;

    /// @notice Read whether `settler` is approved for factory-to-rolloverContract dispatch.
    /// @dev Live default-deny allowlist state checked by `executeIntentHooks`.
    /// @custom:invariant INV-SETTLER-APPROVED — exposes the Settler dispatch allowlist used by
    ///                   the factory gate.
    /// @param settler Address to query.
    /// @return approved True if `settler` is currently approved.
    function approvedSettlers(address settler) external view returns (bool approved);
}
