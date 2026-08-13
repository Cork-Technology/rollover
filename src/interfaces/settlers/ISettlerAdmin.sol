// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title ISettlerAdmin
/// @notice Cork-specific Settler admin surface for pause controls and token rescue.
interface ISettlerAdmin {
    /// @notice Emitted when a Settler admin rescues tokens not backing live dstCST liability.
    /// @param token Rescued ERC-20 token.
    /// @param to Rescue recipient.
    /// @param amount Amount rescued.
    event TokenRecovered(IERC20 indexed token, address indexed to, uint256 amount);

    /// @notice Pause state-changing order lifecycle entrypoints.
    /// @dev Only callable by accounts granted pause authority (`PAUSER_ROLE` in `BaseSettler`).
    ///      Pausing does not block views or admin token rescue.
    /// @custom:invariant INV-PAUSE-GATES-ALL-ENTRYPOINTS — pausing gates every state-changing
    ///                   lifecycle entrypoint.
    function pause() external;

    /// @notice Unpause state-changing order lifecycle entrypoints.
    /// @dev Only callable by accounts granted unpause authority (`UNPAUSER_ROLE` in `BaseSettler`).
    ///      Unpausing restores order lifecycle entrypoints gated by `whenNotPaused`.
    /// @custom:invariant INV-PAUSE-GATES-ALL-ENTRYPOINTS — unpausing restores access to gated
    ///                   lifecycle entrypoints.
    function unpause() external;

    /// @notice Read the live Settler-held dstCST residual obligation tracked for `token`.
    /// @custom:invariant INV-DSTCST-LIABILITY-BACKED — Settler token balance must cover tracked
    ///                   live dstCST liabilities unless an external token drain has underfunded it.
    /// @param token Destination CST token.
    /// @return amount Live dstCST liability for `token`.
    function dstCstLiabilityOf(address token) external view returns (uint256 amount);

    /// @notice Read the token balance recoverable without touching tracked dstCST liability.
    /// @dev Returns `IERC20(token).balanceOf(settler) - dstCstLiabilityOf(token)`.
    ///      Reverts if `token` is the zero address or if the Settler balance is already below
    ///      tracked liability for `token`.
    /// @param token ERC-20 token.
    /// @return amount Token balance above tracked dstCST liability.
    function recoverableTokenBalance(address token) external view returns (uint256 amount);

    /// @notice Rescue an amount-bounded ERC-20 balance not backing tracked dstCST liability.
    /// @dev Only callable by `RECOVERY_ROLE`. Recoverable balance is
    ///      `IERC20(token).balanceOf(settler) - dstCstLiabilityOf(token)`. Reverts if `token`
    ///      or `to` is the zero address, if `amount` is zero, if the Settler balance is below
    ///      tracked liability, or if `amount` exceeds recoverable balance. Rescue never
    ///      decrements dstCST liability.
    /// @custom:invariant INV-DSTCST-LIABILITY-BACKED — rescue cannot recover tokens required to
    ///                   back live dstCST residual obligations.
    /// @param token ERC-20 token to rescue.
    /// @param to Recipient of rescued tokens.
    /// @param amount Amount to rescue.
    function recoverToken(IERC20 token, address to, uint256 amount) external;
}
