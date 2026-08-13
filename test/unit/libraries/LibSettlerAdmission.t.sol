// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";
import {
    Settler__RolloverParamsSrcCstMismatch,
    Settler__SelfExclusiveFiller,
    Settler__SettlerMismatch,
    Settler__WrongDestinationChain,
    Settler__ZeroOrderSize
} from "src/errors/SettlerErrors.sol";
import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import { LibSettlerAdmission } from "src/libraries/LibSettlerAdmission.sol";
import { Typehashes } from "src/libraries/Typehashes.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice Direct tests for LibSettlerAdmission's extracted admission gates.
contract LibSettlerAdmissionTest is Test {
    /// @notice Expected settler address.
    address internal constant SETTLER = address(0x51);
    /// @notice Expected order user.
    address internal constant USER = address(0xA1);
    /// @notice Source CST token placeholder.
    address internal constant SRC_CST = address(0x1001);
    /// @notice Destination CST token placeholder.
    address internal constant DST_CST = address(0x1002);
    /// @notice Premium token placeholder.
    address internal constant PREMIUM = address(0x1003);

    /// @notice Public wrapper so `expectRevert` observes a lower-depth revert.
    /// @param orderData Decoded Cork order data.
    /// @param order ERC-7683 gasless order envelope.
    /// @param settler Expected settler entrypoint.
    function validateEnvelope(
        RolloverTypes.OrderData memory orderData,
        ERC7683Types.GaslessCrossChainOrder memory order,
        address settler
    ) public view {
        LibSettlerAdmission.validateEnvelope(orderData, order, settler);
    }

    /// @notice Public wrapper so `expectRevert` observes a lower-depth revert.
    /// @param orderData Decoded Cork order data.
    /// @param settler Expected settler entrypoint.
    /// @return srcPoolId Source Phoenix pool id.
    /// @return dstPoolId Destination Phoenix pool id.
    function validateOrderShape(RolloverTypes.OrderData memory orderData, address settler)
        public
        view
        returns (bytes32 srcPoolId, bytes32 dstPoolId)
    {
        return LibSettlerAdmission.validateOrderShape(orderData, settler);
    }

    function _baseOrder() internal view returns (RolloverTypes.OrderData memory orderData) {
        orderData.user = USER;
        orderData.settler = SETTLER;
        orderData.fillerHint = address(0xF1);
        orderData.srcCstToken = SRC_CST;
        orderData.dstCstToken = DST_CST;
        orderData.premiumToken = PREMIUM;
        orderData.rolloverContract = address(0xC1);
        orderData.originChainId = uint64(block.chainid);
        orderData.destinationChainId = uint64(block.chainid);
        orderData.openDeadline = 1_000;
        orderData.fillDeadline = 2_000;
        orderData.orderSalt = 7;
        orderData.orderSize = 100e18;
        orderData.minPremiumPerShare = 1e16;
        orderData.premiumPaymentMode = RolloverTypes.PREMIUM_PAYMENT_MODE_ATOMIC_ONLY;
        orderData.rolloverIntentHash = bytes32(uint256(0xCA));
        orderData.rolloverParams.srcCstToken = SRC_CST;
        orderData.rolloverParams.dstCstToken = DST_CST;
        orderData.rolloverParams.srcPoolId = bytes32(uint256(0xAA));
        orderData.rolloverParams.dstPoolId = bytes32(uint256(0xBB));
        orderData.rolloverParams.settler = SETTLER;
    }

    function _gasless(RolloverTypes.OrderData memory orderData)
        internal
        pure
        returns (ERC7683Types.GaslessCrossChainOrder memory order)
    {
        order.originSettler = orderData.settler;
        order.user = orderData.user;
        order.nonce = orderData.orderSalt;
        order.originChainId = orderData.originChainId;
        order.openDeadline = uint32(orderData.openDeadline);
        order.fillDeadline = uint32(orderData.fillDeadline);
        order.orderDataType = Typehashes.ORDER_DATA_TYPEHASH;
        order.orderData = abi.encode(orderData);
    }

    /// @notice Matching envelope fields pass the extracted envelope gate.
    function test_validateEnvelopeAcceptsMatchingOrder() public {
        vm.warp(100);
        RolloverTypes.OrderData memory orderData = _baseOrder();
        this.validateEnvelope(orderData, _gasless(orderData), SETTLER);
    }

    /// @notice Open-deadline expiry is enforced by BaseSettler, not the stateless envelope gate.
    function test_validateEnvelopeIgnoresOpenDeadline() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        vm.warp(uint256(orderData.openDeadline) + 1);

        this.validateEnvelope(orderData, _gasless(orderData), SETTLER);
    }

    /// @notice Entrypoint-settler mismatch reverts inside the extracted envelope gate.
    function test_validateEnvelopeRevertsWhenOrderDataSettlerDiffersFromEntrypoint() public {
        vm.warp(100);
        RolloverTypes.OrderData memory orderData = _baseOrder();

        vm.expectRevert(Settler__SettlerMismatch.selector);
        this.validateEnvelope(orderData, _gasless(orderData), address(0xBEEF));
    }

    /// @notice Valid local order shape returns the decoded source and destination pool ids.
    function test_validateOrderShapeReturnsPoolIds() public view {
        RolloverTypes.OrderData memory orderData = _baseOrder();

        (bytes32 srcPoolId, bytes32 dstPoolId) = this.validateOrderShape(orderData, SETTLER);

        assertEq(srcPoolId, orderData.rolloverParams.srcPoolId);
        assertEq(dstPoolId, orderData.rolloverParams.dstPoolId);
    }

    /// @notice Wrong destination chain reverts inside the extracted local shape gate.
    function test_validateOrderShapeRevertsOnWrongDestinationChain() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.destinationChainId = uint64(block.chainid) + 1;

        vm.expectRevert(Settler__WrongDestinationChain.selector);
        this.validateOrderShape(orderData, SETTLER);
    }

    /// @notice Zero order size reverts inside the extracted local shape gate.
    function test_validateOrderShapeRevertsOnZeroOrderSize() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = 0;

        vm.expectRevert(Settler__ZeroOrderSize.selector);
        this.validateOrderShape(orderData, SETTLER);
    }

    /// @notice Rollover params source CST mismatch reverts inside the local shape gate.
    function test_validateOrderShapeRevertsOnRolloverParamsSrcMismatch() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.rolloverParams.srcCstToken = address(0xCAFE);

        vm.expectRevert(Settler__RolloverParamsSrcCstMismatch.selector);
        this.validateOrderShape(orderData, SETTLER);
    }

    /// @notice Self-exclusive filler reverts inside the extracted local shape gate.
    function test_validateOrderShapeRevertsOnSelfExclusiveFiller() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.exclusiveFiller = SETTLER;

        vm.expectRevert(Settler__SelfExclusiveFiller.selector);
        this.validateOrderShape(orderData, SETTLER);
    }
}
