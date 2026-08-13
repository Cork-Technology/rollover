// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IEVC } from "src/EvcRolloverAdapter.sol";

/// @notice Faithful mock of the Ethereum Vault Connector for EvcRolloverAdapter tests.
///         Targets see `msg.sender == address(MockEVC)`; calldata is forwarded unchanged.
///         Context is exposed via `getCurrentOnBehalfOfAccount(controllerToCheck)`.
contract MockEVC is IEVC {
    /// @notice Transient on-behalf-of subaccount reported to the adapter.
    address internal _onBehalf;
    /// @notice Transient controller-enabled flag reported to the adapter.
    bool internal _enabled;
    /// @notice Controller address wired into the transient frame.
    address internal _currentController;
    /// @notice Registered owner for each EVC account (used by `getAccountOwner`).
    mapping(address account => address owner) internal _accountOwner;
    /// @notice Whether an account owner has been explicitly registered.
    mapping(address account => bool registered) internal _accountOwnerRegistered;

    /// @notice Set the registered owner for an EVC account / subaccount. Test
    ///         fixtures use this to model the Permit2 signer resolution that
    ///         `EvcRolloverAdapter._pullJobFundsAndAuthorize` performs.
    /// @param account Account to register.
    /// @param owner Registered owner.
    function setAccountOwner(address account, address owner) external {
        _accountOwner[account] = owner;
        _accountOwnerRegistered[account] = true;
    }

    /// @inheritdoc IEVC
    function getAccountOwner(address account) external view returns (address owner) {
        require(_accountOwnerRegistered[account], "MockEVC: account owner not registered");
        owner = _accountOwner[account];
    }

    /// @notice Canonical Euler EVC revert when no on-behalf-of frame is authenticated.
    ///         The real EVC throws this internally before returning; tests rely on
    ///         the same revert semantics so the adapter's defensive
    ///         `onBehalf == address(0)` branch is provably unreachable in
    ///         production.
    /// @dev Selector matches `euler-xyz/ethereum-vault-connector` so production
    ///      revert assertions remain faithful against the mock.
    // forge-lint: disable-next-line(screaming-snake-case-immutable, mixed-case-variable)
    error EVC_OnBehalfOfAccountNotAuthenticated();

    /// @notice Forward `data` to `target` under a transient on-behalf-of frame.
    /// @param onBehalf Subaccount the mock reports while dispatching.
    /// @param controller Controller address wired into the transient frame.
    /// @param target Target contract.
    /// @param data ABI-encoded call payload (forwarded unchanged).
    /// @return ok Whether the subcall succeeded.
    /// @return ret Returndata bubbled from `target`.
    // Test EVC frames deliberately accept arbitrary mock participants.
    // forge-lint: disable-next-line(missing-zero-check)
    function proxy(address onBehalf, address controller, address target, bytes calldata data)
        external
        returns (bool ok, bytes memory ret)
    {
        _onBehalf = onBehalf;
        _enabled = true;
        _currentController = controller;
        (ok, ret) = target.call(data);
        _onBehalf = address(0);
        _enabled = false;
        _currentController = address(0);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    /// @notice Read the configured on-behalf-of frame for `controllerToCheck`.
    /// @param controllerToCheck Controller address queried by the adapter.
    /// @return onBehalfOfAccount Configured subaccount when the controller matches.
    /// @return controllerEnabled Whether the controller is enabled for that subaccount.
    function getCurrentOnBehalfOfAccount(address controllerToCheck)
        external
        view
        returns (address onBehalfOfAccount, bool controllerEnabled)
    {
        // Canonical Euler EVC reverts with `EVC_OnBehalfOfAccountNotAuthenticated`
        // whenever no on-behalf-of frame is authenticated. Mirroring that here
        // keeps the test pyramid faithful against the real EVC and proves the
        // adapter's `onBehalf == address(0)` defensive branch is unreachable in
        // production.
        if (_onBehalf == address(0)) {
            revert EVC_OnBehalfOfAccountNotAuthenticated();
        }
        if (controllerToCheck != _currentController) {
            bool controllerEnabled_ = false;
            return (address(0), controllerEnabled_);
        }
        return (_onBehalf, _enabled);
    }

    /// @notice Set the on-behalf-of frame without dispatching a call.
    /// @param onBehalf Subaccount to report.
    /// @param enabled Whether the controller is enabled.
    /// @param controller Controller address for subsequent `getCurrentOnBehalfOfAccount` queries.
    // Test EVC frames deliberately accept arbitrary mock participants.
    // forge-lint: disable-next-line(missing-zero-check)
    function setFrame(address onBehalf, bool enabled, address controller) external {
        _onBehalf = onBehalf;
        _enabled = enabled;
        _currentController = controller;
    }

    /// @notice Deprecated alias — sets onBehalf + enabled; controller must be set via setFrame first.
    /// @param onBehalf Subaccount to report.
    /// @param enabled Whether the controller is enabled.
    // Test EVC frames deliberately accept arbitrary mock participants.
    // forge-lint: disable-next-line(missing-zero-check)
    function set(address onBehalf, bool enabled) external {
        require(_currentController != address(0), "MockEVC: set controller via setFrame first");
        _onBehalf = onBehalf;
        _enabled = enabled;
    }
}
