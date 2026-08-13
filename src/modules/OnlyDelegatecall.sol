// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

/// @notice Reverts when a decorated function is invoked outside a delegatecall frame.
error OnlyDelegatecall__DirectCallForbidden();

/// @title OnlyDelegatecall
/// @notice Abstract base that rejects direct calls to the deployed contract. Modules
///         inheriting this base may only execute via delegatecall from a delegating host
///         (e.g., `CorkRolloverContract._executeIntentCalls`). The deploy address is cached in an
///         immutable at construction; under delegatecall `address(this)` is the host, so
///         `address(this) == _SELF` proves a direct call.
/// @custom:security-contact security@cork.tech
abstract contract OnlyDelegatecall {
    /// @notice Cached deploy-time address of THIS contract. In a delegatecall frame
    ///         `address(this)` is the host, so the two values differ.
    address private immutable _SELF;

    constructor() {
        _SELF = address(this);
    }

    /// @notice Reverts if the call is NOT a delegatecall (i.e., `address(this) == _SELF`).
    /// @custom:invariant INV-REFERENCE-MODULES-DELEGATECALL-ONLY
    modifier onlyDelegatecall() {
        if (address(this) == _SELF) {
            revert OnlyDelegatecall__DirectCallForbidden();
        }
        _;
    }
}
