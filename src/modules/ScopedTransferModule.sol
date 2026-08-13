// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { LibLastDeliveredPremium } from "src/libraries/LibLastDeliveredPremium.sol";
import { OnlyDelegatecall } from "src/modules/OnlyDelegatecall.sol";

/// @notice Reverts when the resolved `amount` (after transient-read) is zero.
error ScopedTransferModule__ZeroAmount();

/// @notice Reverts when `to` is the zero address.
error ScopedTransferModule__ZeroRecipient();

/// @title ScopedTransferModule
/// @notice Amount-scoped replacement for `TransferAllModule`: transfers an EXPLICIT `amount`
///         of `token` to `to`, instead of reading the caller's full live balance. Designed
///         for delegatecall execution from `CorkRolloverContract.fill`'s premium-hook frame.
/// @dev Pass `amount == type(uint256).max` to read the just-delivered premium amount from
///      the rolloverContract's per-token transient slot via `LibLastDeliveredPremium.read`.
/// @custom:invariant INV-ATTESTED-MODULES-ARE-AMOUNT-SCOPED — every new module attested
///                   under `MODULE_TYPE_EXECUTOR` MUST take an explicit `amount`; full-balance
///                   reads are forbidden in new modules.
/// @dev DELEGATE-CALL ONLY. Direct calls to the deployed module address revert
///      `OnlyDelegatecall__DirectCallForbidden`. The reference modules are delegate-call
///      hook targets; do not send tokens to the deployed address.
/// @custom:security-contact security@cork.tech
contract ScopedTransferModule is OnlyDelegatecall {
    using SafeERC20 for IERC20;

    /// @notice Emitted when the delegatecall host transfers an amount-scoped token payout.
    /// @param executor Delegatecall host whose balance funded the transfer.
    /// @param token Token moved by the module.
    /// @param recipient Transfer recipient.
    /// @param amount Amount transferred.
    event ScopedTransferModuleTokenMoved(
        address indexed executor, address indexed token, address indexed recipient, uint256 amount
    );

    /// @notice Sentinel value for `amount` meaning "read the just-delivered premium from the
    ///         rolloverContract's transient slot for `token`".
    uint256 internal constant USE_DELIVERED_SENTINEL = type(uint256).max;

    /// @notice Transfer `amount` of `token` to `to`.
    /// @dev When `amount == USE_DELIVERED_SENTINEL` the module reads the just-delivered
    ///      premium amount from the rolloverContract's per-token transient slot via
    ///      `LibLastDeliveredPremium.read`. Delegatecall context is required for the
    ///      `tload` to hit the rolloverContract's transient storage rather than the module's.
    /// @param token ERC-20 token to transfer.
    /// @param amount Explicit amount, or `type(uint256).max` to read the transient slot.
    /// @param to Recipient address.
    /// @custom:invariant INV-REFERENCE-MODULES-DELEGATECALL-ONLY
    function execute(IERC20 token, uint256 amount, address to) external onlyDelegatecall {
        if (to == address(0)) {
            revert ScopedTransferModule__ZeroRecipient();
        }
        if (amount == USE_DELIVERED_SENTINEL) {
            amount = LibLastDeliveredPremium.read(address(token));
            if (amount == 0) {
                return;
            }
        } else if (amount == 0) {
            revert ScopedTransferModule__ZeroAmount();
        }
        token.safeTransfer(to, amount);
        emit ScopedTransferModuleTokenMoved(address(this), address(token), to, amount);
    }
}
