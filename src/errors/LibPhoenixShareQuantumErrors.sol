// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

/// @notice Reverts when an order size is not aligned to Phoenix's minimum share quantum.
/// @param orderSize Order size that failed the alignment check.
/// @param quantum Required source-share quantum.
error LibPhoenixShareQuantum__OrderSizeNotQuantumAligned(uint256 orderSize, uint256 quantum);

/// @notice Reverts when a fill amount is not aligned to Phoenix's minimum share quantum.
/// @param fillAmount Fill amount that failed the alignment check.
/// @param quantum Required source-share quantum.
error LibPhoenixShareQuantum__FillAmountNotQuantumAligned(uint256 fillAmount, uint256 quantum);

/// @notice Reverts when a non-zero partial residual is not aligned to Phoenix's minimum share quantum.
/// @param residual Remaining order size after the attempted fill.
/// @param quantum Required source-share quantum.
error LibPhoenixShareQuantum__ResidualNotQuantumAligned(uint256 residual, uint256 quantum);

/// @notice Reverts when source collateral decimals cannot be represented as 18-decimal shares.
/// @param decimals Source collateral decimals.
error LibPhoenixShareQuantum__UnsupportedCollateralDecimals(uint8 decimals);
