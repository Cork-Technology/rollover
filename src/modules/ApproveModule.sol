// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { OnlyDelegatecall } from "src/modules/OnlyDelegatecall.sol";

/// @notice Reverts when the spender's entrypoint call reverts. Returndata is capped.
/// @param data Returndata from the failed spender call (at most `RETURNDATA_CAP` bytes).
error ApproveModule__SpenderCallFailed(bytes data);

/// @notice Reverts when the spender address is zero.
error ApproveModule__ZeroSpender();

/// @title ApproveModule
/// @notice Reference hook module that issues an approve+call+revoke atomic bracket from the
///         calling rolloverContract. The allowance is granted via `SafeERC20.forceApprove`, the spender's
///         entrypoint is invoked synchronously, and the allowance is revoked — all in one
///         delegatecall frame.
/// @dev DELEGATE-CALL ONLY. Approval compatibility and USDT-style zero-first retry semantics
///      come from OpenZeppelin `SafeERC20`; this module does not implement bespoke bounded
///      approval returndata handling. Spender-call failures bubble as
///      `ApproveModule__SpenderCallFailed` with returndata capped at `RETURNDATA_CAP` bytes.
/// @custom:security-contact security@cork.tech
contract ApproveModule is OnlyDelegatecall {
    using SafeERC20 for IERC20;

    /// @notice Maximum revert returndata copied from failed spender calls.
    uint256 internal constant RETURNDATA_CAP = 256;

    /// @notice Emitted after an approve-call-revoke bracket completes successfully.
    /// @param executor Delegatecall host whose token allowance was bracketed.
    /// @param token ERC-20 token whose allowance was granted then revoked.
    /// @param spender Spender approved and called by the bracket.
    /// @param selector Selector invoked on `spender`.
    /// @param amount Allowance amount granted for the spender call.
    event ApproveModuleExecuted(
        address indexed executor,
        address indexed token,
        address indexed spender,
        bytes4 selector,
        uint256 amount
    );

    /// @notice Approve `spender` for `amount` of `token`, invoke `spender.selector(amount)`,
    ///         then revoke the allowance. Atomic — if the spender call reverts, the entire
    ///         bracket reverts and no allowance persists.
    /// @dev Designed for delegatecall execution from a delegating host (rolloverContract) inside a
    ///      `RolloverIntent` hook list. `address(this)` resolves to the host in delegatecall,
    ///      so the host's allowance to `spender` is what is granted and revoked.
    /// @param token ERC-20 token whose allowance is granted then revoked.
    /// @param spender Spender address to approve and call.
    /// @param selector 4-byte function selector on `spender` to invoke.
    /// @param amount Allowance amount granted before the call.
    /// @custom:invariant INV-APPROVE-MODULE-NO-RESIDUAL
    /// @custom:invariant INV-REFERENCE-MODULES-DELEGATECALL-ONLY
    function execute(IERC20 token, address spender, bytes4 selector, uint256 amount)
        external
        onlyDelegatecall
    {
        if (spender == address(0)) {
            revert ApproveModule__ZeroSpender();
        }
        token.forceApprove(spender, amount);
        _spenderCallBounded(spender, selector, amount);
        token.forceApprove(spender, 0);
        emit ApproveModuleExecuted(address(this), address(token), spender, selector, amount);
    }

    /// @dev Invoke `spender` with bounded returndata handling on failure only.
    function _spenderCallBounded(address spender, bytes4 selector, uint256 amount) private {
        bool ok;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, selector)
            mstore(add(ptr, 4), amount)
            ok := call(gas(), spender, 0, ptr, 36, 0, 0)
        }
        if (!ok) {
            bytes memory reason = _copyCappedReturndata();
            revert ApproveModule__SpenderCallFailed(reason);
        }
    }

    function _copyCappedReturndata() private pure returns (bytes memory reason) {
        assembly ("memory-safe") {
            let cap := RETURNDATA_CAP
            let size := returndatasize()
            if gt(size, cap) {
                size := cap
            }
            reason := mload(0x40)
            mstore(reason, size)
            returndatacopy(add(reason, 0x20), 0, size)
            mstore(add(add(reason, 0x20), size), 0)
            mstore(0x40, and(add(add(reason, add(size, 0x20)), 0x1f), not(0x1f)))
        }
    }
}
