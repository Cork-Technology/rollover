// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { FillScaffold } from "../base/FillScaffold.sol";
import { BaseSettler } from "src/BaseSettler.sol";
import { ExactSettler as Settler } from "src/ExactSettler.sol";
import { Settler__OrderNotExpirable } from "src/errors/SettlerErrors.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice Settler FSM transitions and rescue-removal idempotency — pins terminal-state guards against operator mutations.
contract SettlerFsmAndRescueIdempotencyTest is FillScaffold {
    /// @notice _settle order.
    function _settleOrder()
        internal
        returns (bytes32 digest, RolloverTypes.OrderData memory orderData)
    {
        orderData = _baseOrder();
        orderData.allowPartialFills = false;
        orderData.orderSize = 1_000e18;

        RolloverTypes.RolloverIntent memory probe =
            _buildIntent(bytes32(0), orderData.orderSize, orderData.orderSize);
        orderData.rolloverIntentHash = _zeroDigestHash(probe);
        digest = _openOrder(orderData);

        RolloverTypes.RolloverIntent memory intent =
            _buildIntent(digest, orderData.orderSize, orderData.orderSize);
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);

        _approveFiller(orderData.orderSize, type(uint128).max);
        // Under atomic-fill the rollover+premium+settle happens in one Settler.fill() frame.
        _doRolloverAs(digest, orderData, intent, orderData.orderSize, filler);
    }

    /// @notice reverts when markExpired on terminal order.
    function testRevert_markExpiredOnTerminalOrder() public {
        (bytes32 digest, RolloverTypes.OrderData memory orderData) = _settleOrder();

        assertEq(
            uint8(settler.orderStatus(digest)),
            uint8(RolloverTypes.OrderStatus.Settled),
            "order must be Settled before the second finalise attempt"
        );

        vm.warp(orderData.fillDeadline + 1);

        vm.expectRevert(Settler__OrderNotExpirable.selector);
        settler.markExpired(digest, _originData(orderData));
    }
}
