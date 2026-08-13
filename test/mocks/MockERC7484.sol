// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { IERC7484, ModuleType } from "src/interfaces/external/erc7484/IERC7484.sol";

/// @notice Mock of the Rhinestone-style ERC-7484 module registry for rolloverContract attestation tests.
contract MockERC7484 is IERC7484 {
    /// @notice Reverts when mock erc7484 not attested.
    /// @param module Module address (Rhinestone-style external module).
    error MockERC7484__NotAttested(address module);
    /// @notice Reverts when mock erc7484 module type mismatch.
    /// @param module Module address (Rhinestone-style external module).
    /// @param expected Expected value.
    /// @param actual Actual observed value.

    error MockERC7484__ModuleTypeMismatch(address module, uint256 expected, uint256 actual);
    /// @notice Reverts when mock erc7484 rejected.
    /// @param module Module address (Rhinestone-style external module).

    error MockERC7484__Rejected(address module);
    /// @notice Reverts when explicit-attester quorum is not reached.
    /// @param module Module address.
    /// @param required Required threshold.
    /// @param actual Matching attestations counted.
    error MockERC7484__ThresholdNotMet(address module, uint256 required, uint256 actual);
    /// @notice Reverts when an attester list is not strictly ascending (Rhinestone parity).
    /// @param previous Attester at index `i - 1`.
    /// @param current Attester at index `i` that is not greater than `previous`.
    error MockERC7484__UnsortedAttesters(address previous, address current);
    /// @notice Rejected.
    /// @return rejected Stored rejected value.

    mapping(address => bool) public rejected;
    /// @notice Last threshold.
    /// @return lastThreshold Stored last threshold value.

    mapping(address => uint8) public lastThreshold;
    /// @notice  attesters.

    mapping(address => address[]) internal _attesters;
    /// @notice Rejected for.
    /// @return rejectedFor Stored rejected for value.

    mapping(address => mapping(address => bool)) public rejectedFor;
    /// @notice  attested type.

    mapping(address => uint256) internal _attestedType;
    /// @notice Per-attester attested module type.

    mapping(address => mapping(address => uint256)) internal _attestedTypeFor;
    /// @notice Whether explicit per-attester attestations are configured for a module.

    mapping(address => bool) internal _explicitConfigured;
    /// @notice Sets rejected.
    /// @param module Module address (Rhinestone-style external module).
    /// @param yes Boolean toggle (true if applicable).

    function setRejected(address module, bool yes) external {
        rejected[module] = yes;
    }
    /// @notice Sets rejected for.
    /// @param smartAccount Smart-account address (ERC-7484 consumer).
    /// @param module Module address (Rhinestone-style external module).
    /// @param yes Boolean toggle (true if applicable).

    function setRejectedFor(address smartAccount, address module, bool yes) external {
        rejectedFor[smartAccount][module] = yes;
    }
    /// @notice Sets attested type.
    /// @param module Module address (Rhinestone-style external module).
    /// @param moduleType ERC-7484 module type (uint256 enum).

    function setAttestedType(address module, ModuleType moduleType) external {
        _attestedType[module] = ModuleType.unwrap(moduleType);
    }

    /// @notice Sets an explicit attester-specific attestation.
    /// @param attester Attester address.
    /// @param module Module address (Rhinestone-style external module).
    /// @param moduleType ERC-7484 module type (uint256 enum).
    function setAttestedTypeFor(address attester, address module, ModuleType moduleType) external {
        _explicitConfigured[module] = true;
        _attestedTypeFor[attester][module] = ModuleType.unwrap(moduleType);
    }

    /// @notice Clears an explicit attester-specific attestation.
    /// @param attester Attester address.
    /// @param module Module address (Rhinestone-style external module).
    function clearAttestedTypeFor(address attester, address module) external {
        _attestedTypeFor[attester][module] = 0;
    }
    /// @notice Check.
    /// @param module Module address (Rhinestone-style external module).
    /// @param moduleType ERC-7484 module type (uint256 enum).

    function check(address module, ModuleType moduleType) external view {
        if (rejected[module]) {
            revert MockERC7484__Rejected(module);
        }
        if (rejectedFor[msg.sender][module]) {
            revert MockERC7484__Rejected(module);
        }
        uint256 actual = _attestedType[module];
        if (actual == 0) {
            revert MockERC7484__NotAttested(module);
        }
        if (actual != ModuleType.unwrap(moduleType)) {
            revert MockERC7484__ModuleTypeMismatch(module, ModuleType.unwrap(moduleType), actual);
        }
    }

    /// @inheritdoc IERC7484
    function check(
        address module,
        ModuleType moduleType,
        address[] calldata attesters,
        uint256 threshold
    ) external view {
        if (rejected[module]) {
            revert MockERC7484__Rejected(module);
        }
        if (rejectedFor[msg.sender][module]) {
            revert MockERC7484__Rejected(module);
        }
        for (uint256 i = 1; i < attesters.length; ++i) {
            if (attesters[i] <= attesters[i - 1]) {
                revert MockERC7484__UnsortedAttesters(attesters[i - 1], attesters[i]);
            }
        }
        uint256 expected = ModuleType.unwrap(moduleType);
        if (!_explicitConfigured[module]) {
            uint256 actual = _attestedType[module];
            if (actual == 0) {
                revert MockERC7484__NotAttested(module);
            }
            if (actual != expected) {
                revert MockERC7484__ModuleTypeMismatch(module, expected, actual);
            }
            if (threshold > attesters.length) {
                revert MockERC7484__ThresholdNotMet(module, threshold, attesters.length);
            }
            return;
        }
        uint256 count;
        for (uint256 i = 0; i < attesters.length; ++i) {
            if (_attestedTypeFor[attesters[i]][module] == expected) {
                ++count;
            }
        }
        if (count < threshold) {
            revert MockERC7484__ThresholdNotMet(module, threshold, count);
        }
    }
    /// @notice Trust attesters.
    /// @param threshold Trust threshold (number of attesters required).
    /// @param attesters Per-rolloverContract attester set.

    function trustAttesters(uint8 threshold, address[] calldata attesters) external {
        for (uint256 i = 1; i < attesters.length; ++i) {
            if (attesters[i] <= attesters[i - 1]) {
                revert MockERC7484__UnsortedAttesters(attesters[i - 1], attesters[i]);
            }
        }
        lastThreshold[msg.sender] = threshold;
        delete _attesters[msg.sender];
        for (uint256 i = 0; i < attesters.length; ++i) {
            _attesters[msg.sender].push(attesters[i]);
        }
    }
    /// @notice Attesters of.
    /// @param smartAccount Smart-account address (ERC-7484 consumer).
    /// @return Return value.

    function attestersOf(address smartAccount) external view returns (address[] memory) {
        return _attesters[smartAccount];
    }
}
