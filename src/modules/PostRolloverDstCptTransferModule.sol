// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { LibPostRolloverDstCptMinted } from "src/libraries/LibPostRolloverDstCptMinted.sol";
import { OnlyDelegatecall } from "src/modules/OnlyDelegatecall.sol";

/// @notice Reverts when `recipient` is the zero address.
error PostRolloverDstCptTransferModule__ZeroRecipient();

/// @title PostRolloverDstCptTransferModule
/// @author Cork Technology
/// @notice Standard post-rollover hook that transfers exactly the rolloverContract-scoped,
///         newly minted dstCPT amount to a caller-selected cPT roller/recipient.
/// @dev Intended for `Typehashes.MODULE_TYPE_POST_ROLLOVER_HOOK` attestation. The module never
///      reads or sweeps `dstCpt.balanceOf(address(this))`; it reads only the transient
///      `dstCptAfterDeposit - dstCptBeforeDeposit` amount written by `CorkRolloverContract` for the
///      current post-rollover frame. If that amount is zero, the hook no-ops so zero-output
///      post-hook frames do not fail spuriously. Direct calls to the deployed module address
///      revert `OnlyDelegatecall__DirectCallForbidden`.
/// @custom:invariant INV-CPT-CONTAINED — final `CorkRolloverContract__DstCptNotRestored` guard,
///                   not this information-channel module, enforces restoration to the entry
///                   dstCPT snapshot.
/// @custom:security-contact security@cork.tech
contract PostRolloverDstCptTransferModule is OnlyDelegatecall {
    using SafeERC20 for IERC20;

    /// @notice Emitted when the delegatecall host routes the newly minted dstCPT amount.
    /// @param executor Delegatecall host whose balance funded the transfer.
    /// @param dstCpt Destination cPT token moved by the module.
    /// @param recipient cPT roller/recipient receiving the newly minted dstCPT amount.
    /// @param amount Transient-scoped amount transferred.
    event PostRolloverDstCptTransferred(
        address indexed executor, address indexed dstCpt, address indexed recipient, uint256 amount
    );

    /// @notice Transfer the post-rollover minted dstCPT amount for `dstCpt` to `recipient`.
    /// @dev The amount is read from `LibPostRolloverDstCptMinted` in delegatecall context; this
    ///      deliberately supports nonzero standing dstCPT on the rolloverContract by routing only
    ///      the minted amount observed after `deposit`.
    /// @param dstCpt Destination cPT token minted by the just-finished destination-pool deposit.
    /// @param recipient cPT roller/recipient that receives the newly minted dstCPT amount.
    /// @custom:invariant INV-REFERENCE-MODULES-DELEGATECALL-ONLY
    function execute(IERC20 dstCpt, address recipient) external onlyDelegatecall {
        if (recipient == address(0)) {
            revert PostRolloverDstCptTransferModule__ZeroRecipient();
        }
        uint256 amount = LibPostRolloverDstCptMinted.read(address(dstCpt));
        if (amount == 0) {
            return;
        }
        dstCpt.safeTransfer(recipient, amount);
        emit PostRolloverDstCptTransferred(address(this), address(dstCpt), recipient, amount);
    }
}
