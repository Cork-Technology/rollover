// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice ERC-7484 module-type discriminator (wrapped `uint256`).
type ModuleType is uint256;

/// @title IERC7484
/// @notice Minimal ERC-7484 attester-registry surface consumed by Cork.
/// @dev Cork uses `check` to attest hook modules before execution and `trustAttesters` to
///      configure the smart-account-scoped attester set during rolloverContract `initialize`.
interface IERC7484 {
    /// @notice Reverts if `module` is not attested by the registry under `moduleType` against
    ///         the calling smart-account's trust configuration.
    /// @param module Address of the hook module under attestation.
    /// @param moduleType Module-type discriminator (see `Typehashes.MODULE_TYPE_*`).
    function check(address module, ModuleType moduleType) external view;

    /// @notice Reverts if `module` is not attested by the supplied attester set and threshold.
    /// @dev Per ERC-7484 / Rhinestone the explicit `attesters` list MUST be strictly ascending
    ///      and unique; the registry reverts otherwise.
    /// @param module Address of the hook module under attestation.
    /// @param moduleType Module-type discriminator.
    /// @param attesters Explicit attester set supplied by the caller (strictly ascending + unique).
    /// @param threshold Minimum number of valid attesters required.
    function check(
        address module,
        ModuleType moduleType,
        address[] calldata attesters,
        uint256 threshold
    ) external view;

    /// @notice Configure the calling smart-account's attester set and quorum threshold.
    /// @dev Per ERC-7484 / Rhinestone the `attesters` list MUST be strictly ascending and unique;
    ///      the registry reverts otherwise. Cork validates this fail-fast before forwarding here.
    /// @param threshold Minimum number of attesters required to validate a module.
    /// @param attesters Address list of trusted attesters (strictly ascending + unique).
    function trustAttesters(uint8 threshold, address[] calldata attesters) external;
}
