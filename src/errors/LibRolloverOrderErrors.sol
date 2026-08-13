// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

/// @notice Reverts when the order envelope carries an unexpected `orderDataType`.
error LibRolloverOrder__BadOrderType();

/// @notice Reverts when `orderData` is not the canonical ABI encoding of decoded `OrderData`.
error LibRolloverOrder__NonCanonicalOrderData();
