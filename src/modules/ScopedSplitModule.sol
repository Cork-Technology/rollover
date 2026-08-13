// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { LibLastDeliveredPremium } from "src/libraries/LibLastDeliveredPremium.sol";
import { OnlyDelegatecall } from "src/modules/OnlyDelegatecall.sol";

/// @notice Reverts when a basis-point weight is zero or exceeds `BPS_TOTAL`.
/// @param bps The offending basis-point value.
error ScopedSplitModule__BpsOutOfRange(uint16 bps);

/// @notice Reverts when `recipients` and `bps` arrays have different lengths.
error ScopedSplitModule__LengthMismatch();

/// @notice Reverts when the recipient list is empty.
error ScopedSplitModule__EmptyRecipients();

/// @notice Reverts when the resolved `amount` (after transient-read) is zero.
error ScopedSplitModule__ZeroAmount();

/// @title ScopedSplitModule
/// @notice Amount-scoped split module: distributes an EXPLICIT `amount` of `token` across
///         `recipients` weighted by `bps`, instead of reading the caller's full live balance.
///         Designed for delegatecall execution from `CorkRolloverContract.fill`'s premium-hook frame.
/// @dev Pass `amount == type(uint256).max` to read the just-delivered premium amount from
///      the rolloverContract's per-token transient slot via `LibLastDeliveredPremium.read` — useful
///      when the cPT holder signs an intent before the exact premium amount is known.
/// @custom:invariant INV-ATTESTED-MODULES-ARE-AMOUNT-SCOPED — every new module attested
///                   under `MODULE_TYPE_EXECUTOR` MUST take an explicit `amount`; full-balance
///                   reads are forbidden in new modules.
/// @dev DELEGATE-CALL ONLY. Direct calls to the deployed module address revert
///      `OnlyDelegatecall__DirectCallForbidden`. The reference modules are delegate-call
///      hook targets; do not send tokens to the deployed address.
/// @custom:security-contact security@cork.tech
contract ScopedSplitModule is OnlyDelegatecall {
    using SafeERC20 for IERC20;

    /// @notice Emitted for each delegatecall-host transfer made by the scoped split.
    /// @param executor Delegatecall host whose balance funded the transfer.
    /// @param token Token moved by the module.
    /// @param recipient Transfer recipient.
    /// @param amount Amount transferred.
    event ScopedSplitModuleTokenMoved(
        address indexed executor, address indexed token, address indexed recipient, uint256 amount
    );

    /// @notice Total basis points (10_000 = 100%).
    uint16 internal constant BPS_TOTAL = 10_000;

    /// @notice Sentinel value for `amount` meaning "read the just-delivered premium from the
    ///         rolloverContract's transient slot for `token`".
    uint256 internal constant USE_DELIVERED_SENTINEL = type(uint256).max;

    /// @notice Split `amount` of `token` to `recipients` weighted by `bps`.
    /// @dev `bps` must sum to exactly `BPS_TOTAL`; each entry must lie in `(0, BPS_TOTAL]`.
    ///      Rounding dust accrues to the last recipient. When `amount == USE_DELIVERED_SENTINEL`
    ///      the module reads the just-delivered premium amount from the rolloverContract's per-token
    ///      transient slot via `LibLastDeliveredPremium.read`. Delegatecall context is
    ///      required for the `tload` to hit the rolloverContract's transient storage rather than the
    ///      module's.
    /// @param token ERC-20 token to distribute.
    /// @param amount Explicit amount, or `type(uint256).max` to read the transient slot.
    /// @param recipients Recipient addresses.
    /// @param bps Per-recipient basis-point weights; must sum to 10_000.
    /// @custom:invariant INV-REFERENCE-MODULES-DELEGATECALL-ONLY
    function execute(
        IERC20 token,
        uint256 amount,
        address[] calldata recipients,
        uint16[] calldata bps
    ) external onlyDelegatecall {
        if (recipients.length != bps.length) {
            revert ScopedSplitModule__LengthMismatch();
        }
        if (recipients.length == 0) {
            revert ScopedSplitModule__EmptyRecipients();
        }
        bool useDeliveredAmount = amount == USE_DELIVERED_SENTINEL;
        if (!useDeliveredAmount && amount == 0) {
            revert ScopedSplitModule__ZeroAmount();
        }

        uint256 sum;
        for (uint256 i = 0; i < bps.length; ++i) {
            if (bps[i] == 0 || bps[i] > BPS_TOTAL) {
                revert ScopedSplitModule__BpsOutOfRange(bps[i]);
            }
            sum += bps[i];
        }
        if (sum != BPS_TOTAL) {
            revert ScopedSplitModule__BpsOutOfRange(0);
        }

        if (useDeliveredAmount) {
            amount = LibLastDeliveredPremium.read(address(token));
            if (amount == 0) {
                return;
            }
        }

        uint256 distributed;
        for (uint256 i = 0; i < recipients.length - 1; ++i) {
            uint256 share = (amount * bps[i]) / BPS_TOTAL;
            distributed += share;
            token.safeTransfer(recipients[i], share);
            emit ScopedSplitModuleTokenMoved(address(this), address(token), recipients[i], share);
        }

        uint256 tailShare = amount - distributed;
        token.safeTransfer(recipients[recipients.length - 1], tailShare);
        emit ScopedSplitModuleTokenMoved(
            address(this), address(token), recipients[recipients.length - 1], tailShare
        );
    }
}
