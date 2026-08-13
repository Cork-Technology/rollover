// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {
    Settler__DstCstEqualsPremiumToken,
    Settler__FillDeadlineMismatch,
    Settler__InvalidPremiumPaymentMode,
    Settler__OpenDeadlineAfterFillDeadline,
    Settler__OpenDeadlineMismatch,
    Settler__OrderSaltMismatch,
    Settler__OriginChainIdMismatch,
    Settler__OriginSettlerMismatch,
    Settler__RolloverParamsDstCstMismatch,
    Settler__RolloverParamsSettlerMismatch,
    Settler__RolloverParamsSrcCstMismatch,
    Settler__SamePoolId,
    Settler__SelfExclusiveFiller,
    Settler__SettlerMismatch,
    Settler__SrcCstEqualsPremiumToken,
    Settler__UserMismatch,
    Settler__WrongDestinationChain,
    Settler__WrongOriginChain,
    Settler__ZeroDstCstToken,
    Settler__ZeroOrderSize,
    Settler__ZeroPremiumRate,
    Settler__ZeroPremiumToken,
    Settler__ZeroRolloverIntentHash,
    Settler__ZeroSrcCstToken
} from "src/errors/SettlerErrors.sol";
import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice Stateless admission checks shared by open/openFor and direct-fill first admission.
library LibSettlerAdmission {
    /// @notice Validate the ERC-7683 envelope fields against decoded Cork order data.
    /// @param orderData Decoded Cork order data.
    /// @param order ERC-7683 gasless order envelope.
    /// @param settler Settler entrypoint expected in `orderData`.
    function validateEnvelope(
        RolloverTypes.OrderData memory orderData,
        ERC7683Types.GaslessCrossChainOrder memory order,
        address settler
    ) internal pure {
        if (order.originSettler != orderData.settler) {
            revert Settler__OriginSettlerMismatch();
        }
        if (order.user != orderData.user) {
            revert Settler__UserMismatch();
        }
        if (order.nonce != orderData.orderSalt) {
            revert Settler__OrderSaltMismatch();
        }
        if (order.originChainId != orderData.originChainId) {
            revert Settler__OriginChainIdMismatch();
        }
        if (orderData.openDeadline != order.openDeadline) {
            revert Settler__OpenDeadlineMismatch();
        }
        if (orderData.fillDeadline != order.fillDeadline) {
            revert Settler__FillDeadlineMismatch();
        }
        if (orderData.settler != settler) {
            revert Settler__SettlerMismatch();
        }
    }

    /// @notice Validate local order shape and return source/destination Phoenix pool ids.
    /// @param orderData Decoded Cork order data.
    /// @param settler Settler entrypoint used to reject self-exclusive orders.
    /// @return srcPoolId Source Phoenix pool id.
    /// @return dstPoolId Destination Phoenix pool id.
    function validateOrderShape(RolloverTypes.OrderData memory orderData, address settler)
        internal
        view
        returns (bytes32 srcPoolId, bytes32 dstPoolId)
    {
        if (orderData.openDeadline > orderData.fillDeadline) {
            revert Settler__OpenDeadlineAfterFillDeadline();
        }
        if (orderData.originChainId != uint64(block.chainid)) {
            revert Settler__WrongOriginChain();
        }
        if (orderData.destinationChainId != uint64(block.chainid)) {
            revert Settler__WrongDestinationChain();
        }
        if (orderData.orderSize == 0) {
            revert Settler__ZeroOrderSize();
        }
        if (orderData.minPremiumPerShare == 0) {
            revert Settler__ZeroPremiumRate();
        }
        if (orderData.premiumPaymentMode > RolloverTypes.PREMIUM_PAYMENT_MODE_ATOMIC_OR_SEPARATE) {
            revert Settler__InvalidPremiumPaymentMode();
        }
        if (orderData.srcCstToken == address(0)) {
            revert Settler__ZeroSrcCstToken();
        }
        if (orderData.dstCstToken == address(0)) {
            revert Settler__ZeroDstCstToken();
        }
        if (orderData.premiumToken == address(0)) {
            revert Settler__ZeroPremiumToken();
        }
        if (orderData.srcCstToken == orderData.premiumToken) {
            revert Settler__SrcCstEqualsPremiumToken();
        }
        if (orderData.dstCstToken == orderData.premiumToken) {
            revert Settler__DstCstEqualsPremiumToken();
        }

        srcPoolId = orderData.rolloverParams.srcPoolId;
        dstPoolId = orderData.rolloverParams.dstPoolId;
        if (srcPoolId == dstPoolId) {
            revert Settler__SamePoolId();
        }
        if (orderData.rolloverParams.srcCstToken != orderData.srcCstToken) {
            revert Settler__RolloverParamsSrcCstMismatch();
        }
        if (orderData.rolloverParams.dstCstToken != orderData.dstCstToken) {
            revert Settler__RolloverParamsDstCstMismatch();
        }
        if (orderData.rolloverParams.settler != orderData.settler) {
            revert Settler__RolloverParamsSettlerMismatch();
        }
        if (orderData.rolloverIntentHash == bytes32(0)) {
            revert Settler__ZeroRolloverIntentHash();
        }
        if (orderData.exclusiveFiller == settler) {
            revert Settler__SelfExclusiveFiller();
        }
    }
}
