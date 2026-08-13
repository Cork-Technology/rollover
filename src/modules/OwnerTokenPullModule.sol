// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ICorkRolloverContract } from "src/interfaces/rollover/ICorkRolloverContract.sol";
import { OnlyDelegatecall } from "src/modules/OnlyDelegatecall.sol";

/// @notice Reverts when `OwnerTokenPullModule.execute` receives the zero token address.
error OwnerTokenPullModule__ZeroToken();

/// @notice Reverts when `OwnerTokenPullModule.execute` receives a zero pull amount.
error OwnerTokenPullModule__ZeroAmount();

/// @notice Reverts when underfill mode cannot pull any positive token amount.
error OwnerTokenPullModule__NothingPullable();

/// @title Owner Token Pull Module
/// @author Cork Team
/// @custom:security-contact security@cork.tech
/// @notice Pre-rollover hook that pulls an explicit ERC-20 amount from the rolloverContract owner.
/// @dev DELEGATE-CALL ONLY. During delegatecall, `address(this)` is the rolloverContract
///      host; the token source is always `ICorkRolloverContract(address(this)).owner()`
///      and the destination is always the host.
contract OwnerTokenPullModule is OnlyDelegatecall {
    using SafeERC20 for IERC20;

    /// @notice Emitted when a delegatecall host pulls owner-held tokens into itself.
    /// @param executor Delegatecall host that receives the pulled tokens.
    /// @param token ERC-20 token pulled from the owner.
    /// @param owner Owner account used as the transfer source.
    /// @param amount Token amount pulled.
    event OwnerTokenPulled(
        address indexed executor, address indexed token, address indexed owner, uint256 amount
    );

    /// @notice Pull `amount` of `token` from the delegatecall host's owner into the host.
    /// @dev Intended for `Typehashes.MODULE_TYPE_PRE_ROLLOVER_HOOK` attestation. The module
    ///      deliberately has no arbitrary `from`, `to`, spender, approval, or callback
    ///      parameter; the signed hook controls only token identity, explicit amount, and whether
    ///      `amount` is exact or a maximum.
    /// @param token ERC-20 token to pull from the rolloverContract owner.
    /// @param amount Nonzero token amount to pull, or maximum token amount when underfill is enabled.
    /// @param allowUnderfill Whether to pull the smaller positive owner balance/allowance if needed.
    /// @custom:invariant INV-REFERENCE-MODULES-DELEGATECALL-ONLY
    function execute(IERC20 token, uint256 amount, bool allowUnderfill) external onlyDelegatecall {
        address executor = address(this);
        if (address(token) == address(0)) {
            revert OwnerTokenPullModule__ZeroToken();
        }
        if (amount == 0) {
            revert OwnerTokenPullModule__ZeroAmount();
        }
        address owner = ICorkRolloverContract(executor).owner();
        uint256 pullAmount = amount;
        if (allowUnderfill) {
            uint256 ownerBalance = token.balanceOf(owner);
            uint256 allowance = token.allowance(owner, executor);
            if (pullAmount > ownerBalance) {
                pullAmount = ownerBalance;
            }
            if (pullAmount > allowance) {
                pullAmount = allowance;
            }
            if (pullAmount == 0) {
                revert OwnerTokenPullModule__NothingPullable();
            }
        }
        token.safeTransferFrom(owner, executor, pullAmount);
        emit OwnerTokenPulled(executor, address(token), owner, pullAmount);
    }
}
