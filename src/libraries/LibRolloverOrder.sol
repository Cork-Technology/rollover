// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {
    LibRolloverOrder__BadOrderType,
    LibRolloverOrder__NonCanonicalOrderData
} from "src/errors/LibRolloverOrderErrors.sol";
import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import { Typehashes } from "src/libraries/Typehashes.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @title LibRolloverOrder
/// @notice ERC-7683 ↔ Cork order-data marshalling helpers. Decodes the gasless cross-chain
///         order envelope into Cork's `OrderData` and projects ERC-7683-shaped outputs.
library LibRolloverOrder {
    /// @notice ERC-7683 `orderDataType` for Cork rollover `OrderData`.
    /// @dev ERC-7683 defines this field as the EIP-712 typehash of the implementation-specific
    ///      order-data schema.
    bytes32 internal constant CORK_ORDER_DATA_TYPE = Typehashes.ORDER_DATA_TYPEHASH;

    /// @notice Canonical ABI byte length of the static-only Cork `OrderData` schema.
    uint256 internal constant ORDER_DATA_ABI_LENGTH = 864;

    /// @notice Decode the ERC-7683 envelope's `orderData` blob into Cork's `OrderData` struct.
    /// @param gOrder Gasless cross-chain order envelope.
    /// @return orderData Decoded Cork `OrderData`.
    function decodeOrderData(ERC7683Types.GaslessCrossChainOrder calldata gOrder)
        internal
        pure
        returns (RolloverTypes.OrderData memory orderData)
    {
        if (gOrder.orderDataType != CORK_ORDER_DATA_TYPE) {
            revert LibRolloverOrder__BadOrderType();
        }
        orderData = abi.decode(gOrder.orderData, (RolloverTypes.OrderData));
        _requireCanonicalOrderData(gOrder.orderData);
    }

    /// @notice Decode the ERC-7683 on-chain envelope's `orderData` blob into Cork `OrderData`.
    /// @param order On-chain cross-chain order envelope.
    /// @return orderData Decoded Cork `OrderData`.
    function decodeOrderData(ERC7683Types.OnchainCrossChainOrder calldata order)
        internal
        pure
        returns (RolloverTypes.OrderData memory orderData)
    {
        if (order.orderDataType != CORK_ORDER_DATA_TYPE) {
            revert LibRolloverOrder__BadOrderType();
        }
        orderData = abi.decode(order.orderData, (RolloverTypes.OrderData));
        _requireCanonicalOrderData(order.orderData);
    }

    /// @notice Decode a memory ERC-7683 envelope's `orderData` blob into Cork's `OrderData`.
    /// @param gOrder Gasless cross-chain order envelope.
    /// @return orderData Decoded Cork `OrderData`.
    function decodeOrderDataMemory(ERC7683Types.GaslessCrossChainOrder memory gOrder)
        internal
        pure
        returns (RolloverTypes.OrderData memory orderData)
    {
        if (gOrder.orderDataType != CORK_ORDER_DATA_TYPE) {
            revert LibRolloverOrder__BadOrderType();
        }
        orderData = abi.decode(gOrder.orderData, (RolloverTypes.OrderData));
        _requireCanonicalOrderData(gOrder.orderData);
    }

    /// @dev Reject ABI blobs that decode but are not canonical for the static-only schema.
    function _requireCanonicalOrderData(bytes memory rawOrderData) private pure {
        if (rawOrderData.length != ORDER_DATA_ABI_LENGTH) {
            revert LibRolloverOrder__NonCanonicalOrderData();
        }
    }

    /// @notice Project Cork `OrderData` into ERC-7683 `Output[]` arrays for `resolve` callers.
    /// @dev `maxSpent[0]` describes the filler-funded srcCST transfer into the rollover
    ///      contract, so its recipient is the rollover contract. `minReceived[0]` exposes
    ///      the cPT-holder-signed dstCST floor, but the final filler destination is unknown
    ///      until fill data is supplied; the recipient is therefore the zero sentinel.
    ///      Per ERC-7683, `Output.amount` is denominated in `Output.token` units; sourcing
    ///      the dstCST floor from `orderSize` (srcCST units) would mislead off-chain solvers
    ///      in cross-decimal pools. `minSharesOut == 0` means unbounded slippage explicitly
    ///      authorized by the cPT holder (the on-chain admission/fill flow does not consume
    ///      `minReceived`).
    /// @param orderData Decoded Cork `OrderData`.
    /// @return maxSpent Maximum-spent output array (srcCST side).
    /// @return minReceived Minimum-received output array (dstCST side).
    /// @custom:invariant `maxSpent[0].recipient == orderData.rolloverContract`.
    /// @custom:invariant `minReceived[0].recipient == bytes32(0)`.
    /// @custom:invariant `minReceived[0].amount == orderData.rolloverParams.minSharesOut`.
    function projectOutputs(RolloverTypes.OrderData memory orderData)
        internal
        pure
        returns (ERC7683Types.Output[] memory maxSpent, ERC7683Types.Output[] memory minReceived)
    {
        maxSpent = new ERC7683Types.Output[](1);
        maxSpent[0] = ERC7683Types.Output({
            token: bytes32(uint256(uint160(orderData.srcCstToken))),
            amount: orderData.orderSize,
            recipient: bytes32(uint256(uint160(orderData.rolloverContract))),
            chainId: orderData.originChainId
        });
        minReceived = new ERC7683Types.Output[](1);
        minReceived[0] = ERC7683Types.Output({
            token: bytes32(uint256(uint160(orderData.dstCstToken))),
            amount: orderData.rolloverParams.minSharesOut,
            recipient: bytes32(0),
            chainId: orderData.destinationChainId
        });
    }

    /// @notice Project Cork order data into ERC-7683 resolved-order form.
    /// @param orderData Decoded Cork order data.
    /// @param order Original gasless cross-chain order envelope.
    /// @param orderDigest Canonical settler order digest.
    /// @return resolved ERC-7683 resolved order.
    function buildResolvedOrder(
        RolloverTypes.OrderData memory orderData,
        ERC7683Types.GaslessCrossChainOrder memory order,
        bytes32 orderDigest
    ) internal pure returns (ERC7683Types.ResolvedCrossChainOrder memory resolved) {
        (ERC7683Types.Output[] memory maxSpent, ERC7683Types.Output[] memory minReceived) =
            projectOutputs(orderData);
        ERC7683Types.FillInstruction[] memory fillInstructions =
            new ERC7683Types.FillInstruction[](1);
        fillInstructions[0] = ERC7683Types.FillInstruction({
            destinationChainId: orderData.destinationChainId,
            destinationSettler: bytes32(uint256(uint160(orderData.settler))),
            originData: abi.encode(order)
        });
        resolved = ERC7683Types.ResolvedCrossChainOrder({
            user: order.user,
            originChainId: order.originChainId,
            openDeadline: order.openDeadline,
            fillDeadline: order.fillDeadline,
            orderId: orderDigest,
            maxSpent: maxSpent,
            minReceived: minReceived,
            fillInstructions: fillInstructions
        });
    }
}
