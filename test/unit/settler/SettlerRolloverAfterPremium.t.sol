// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { FillScaffold } from "../../base/FillScaffold.sol";
import { BaseSettler } from "src/BaseSettler.sol";
import { Settler__PremiumAlreadyFiredRollover } from "src/errors/SettlerErrors.sol";
import { LibFillerPayload } from "src/libraries/LibFillerPayload.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice SettlerRolloverAfterPremiumTest — pins SettlerRolloverAfterPremium behaviour for the Cork Rollover suite.
contract SettlerRolloverAfterPremiumTest is FillScaffold {
    /// @notice Order.
    uint256 internal constant ORDER = 2_000e18;
    /// @notice Leg.

    uint256 internal constant LEG = 1_000e18;
    /// @notice Dst.

    uint256 internal constant DST = 1_000e18;
    /// @notice Floor.

    uint256 internal constant FLOOR = 1e16;
    /// @notice Premium.

    uint256 internal constant PREMIUM = (DST * FLOOR + 1e18 - 1) / 1e18;

    /// @notice Pins behaviour: partial Rollover After Premium By Filler Reverts.
    function test_partialRolloverAfterPremiumByFillerReverts() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData = _usePartialSettler(orderData);
        orderData.orderSize = ORDER;
        orderData.minPremiumPerShare = FLOOR;

        RolloverTypes.RolloverIntent memory intent = _buildIntent(bytes32(0), LEG, DST);
        orderData.rolloverIntentHash = _zeroDigestHash(intent);
        bytes32 orderDigest = _openOrder(orderData);
        intent.orderDigest = orderDigest;
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);

        _approveFiller(LEG * 2, PREMIUM);

        _doRolloverAs(orderDigest, orderData, intent, LEG, filler);

        bytes memory originData = _originData(orderData);
        bytes memory cptHolderOrderSig = _signOrder(cptHolderPk, orderData);
        bytes memory rolloverLeg = LibFillerPayload.encodeRolloverLeg(
            LEG, filler, intent, 0, bytes(""), bytes32(0), bytes("")
        );
        bytes memory rolloverFillerData = LibFillerPayload.encodeAtomicEnvelope(
            rolloverLeg, uint256(1_000_000e18), cptHolderOrderSig
        );

        vm.prank(filler);
        vm.expectRevert(Settler__PremiumAlreadyFiredRollover.selector);
        partialSettler.fill(orderDigest, originData, rolloverFillerData);
    }
}
