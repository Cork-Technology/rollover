// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { FillScaffold } from "../../base/FillScaffold.sol";
import { CorkRolloverContract } from "src/CorkRolloverContract.sol";
import {
    CorkRolloverContract__OrderDigestMismatch
} from "src/errors/CorkRolloverContractErrors.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice IntentReplayAcrossOrdersTest — pins IntentReplayAcrossOrders behaviour for the Cork Rollover suite.
contract IntentReplayAcrossOrdersTest is FillScaffold {
    /// @notice Fill.
    uint256 internal constant FILL = 1_000e18;
    /// @notice Dst.

    uint256 internal constant DST = 1_000e18;

    /// @notice Pins behaviour: intent Replay Across Orders Reverts.
    function testRevert_intentReplayAcrossOrdersReverts() public {
        RolloverTypes.OrderData memory orderA = _baseOrder();
        orderA.allowPartialFills = false;
        orderA.orderSize = FILL;
        orderA.orderSalt = 1;
        RolloverTypes.RolloverIntent memory intentA = _buildIntent(bytes32(0), FILL, DST);
        orderA.rolloverIntentHash = _zeroDigestHash(intentA);
        bytes32 orderDigestA = _openOrder(orderA);
        intentA.orderDigest = orderDigestA;

        RolloverTypes.OrderData memory orderB = _baseOrder();
        orderB.allowPartialFills = false;
        orderB.orderSize = FILL;
        orderB.orderSalt = 2;
        orderB.rolloverIntentHash = _zeroDigestHash(intentA);
        bytes32 orderDigestB = _openOrder(orderB);
        assertTrue(orderDigestA != orderDigestB, "orders must have distinct digests");

        _approveFiller(FILL, 0);

        vm.expectRevert(CorkRolloverContract__OrderDigestMismatch.selector);
        _doRolloverAs(orderDigestB, orderB, intentA, FILL, filler);
    }
}
