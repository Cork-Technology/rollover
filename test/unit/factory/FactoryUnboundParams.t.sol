// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { BaseSettler } from "src/BaseSettler.sol";
import { ExactSettler as Settler } from "src/ExactSettler.sol";
import {
    Settler__BadUserSignature,
    Settler__PartialFillsNotSupported
} from "src/errors/SettlerErrors.sol";
import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice FactoryUnboundParamsTest — pins FactoryUnboundParams behaviour for the Cork Rollover suite.
contract FactoryUnboundParamsTest is BaseTest {
    /// @notice Pins behaviour: signature Replay With Inflated Order Size Reverts.
    function test_signatureReplayWithInflatedOrderSizeReverts() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory sig = _signOrder(cptHolderPk, orderData);

        orderData.orderSize = orderData.orderSize * 10;
        g.orderData = abi.encode(orderData);

        bytes memory empty;
        vm.expectRevert(Settler__BadUserSignature.selector);
        settler.openFor(g, sig, empty);
    }

    /// @notice Pins behaviour: tampered Rollover Param Reverts.
    function test_tamperedRolloverParamReverts() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory sig = _signOrder(cptHolderPk, orderData);

        orderData.rolloverParams.minSharesOut = 999_999e18;
        g.orderData = abi.encode(orderData);

        bytes memory empty;
        vm.expectRevert(Settler__BadUserSignature.selector);
        settler.openFor(g, sig, empty);
    }

    /// @notice Pins behaviour: tampered Min Premium Reverts.
    function test_tamperedMinPremiumReverts() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory sig = _signOrder(cptHolderPk, orderData);

        orderData.minPremiumPerShare = 1;
        g.orderData = abi.encode(orderData);

        bytes memory empty;
        vm.expectRevert(Settler__BadUserSignature.selector);
        settler.openFor(g, sig, empty);
    }

    /// @notice Pins behaviour: tampered Polarity Reverts.
    function test_tamperedPolarityReverts() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory sig = _signOrder(cptHolderPk, orderData);

        orderData.allowPartialFills = !orderData.allowPartialFills;
        g.orderData = abi.encode(orderData);

        bytes memory empty;
        vm.expectRevert(abi.encodeWithSignature("Settler__PartialFillsNotSupported()"));
        settler.openFor(g, sig, empty);
    }

    /// @notice Pins behaviour: untampered Signature Accepted.
    function test_untamperedSignatureAccepted() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory sig = _signOrder(cptHolderPk, orderData);
        bytes memory empty;
        settler.openFor(g, sig, empty);
        bytes32 digest = _orderDigest(orderData);
        assertEq(uint8(settler.orderStatus(digest)), uint8(RolloverTypes.OrderStatus.Opened));
    }

    /// @notice Pins behaviour: double Open Same Digest Is Idempotent.
    function test_doubleOpenSameDigestIsIdempotent() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory sig = _signOrder(cptHolderPk, orderData);
        bytes memory empty;
        bytes32 digest = _orderDigest(orderData);
        settler.openFor(g, sig, empty);
        assertEq(uint8(settler.orderStatus(digest)), uint8(RolloverTypes.OrderStatus.Opened));

        settler.openFor(g, sig, empty);
        assertEq(uint8(settler.orderStatus(digest)), uint8(RolloverTypes.OrderStatus.Opened));
    }
}
