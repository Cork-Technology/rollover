// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { FillScaffold } from "../../base/FillScaffold.sol";
import { CorkRolloverContract } from "src/CorkRolloverContract.sol";
import {
    CorkRolloverContract__IntentHashMismatch
} from "src/errors/CorkRolloverContractErrors.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice RolloverIntentHashBindingTest — pins RolloverIntentHashBinding behaviour for the Cork Rollover suite.
contract RolloverIntentHashBindingTest is FillScaffold {
    /// @notice Fill.
    uint256 internal constant FILL = 1_000e18;
    /// @notice Dst.

    uint256 internal constant DST = 1_000e18;

    function _buildSecondIntent(bytes32 orderDigest)
        internal
        view
        returns (RolloverTypes.RolloverIntent memory)
    {
        return RolloverTypes.RolloverIntent({
            rolloverContract: rolloverContract,
            orderDigest: orderDigest,
            deadline: uint64(block.timestamp + 2 days),
            nonce: 1,
            preRolloverHooks: new RolloverTypes.Call[](0),
            midRolloverHooks: new RolloverTypes.Call[](0),
            postRolloverHooks: new RolloverTypes.Call[](0),
            premiumHooks: new RolloverTypes.Call[](0)
        });
    }

    /// @notice Pins behaviour: happy Path.
    function test_happyPath() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.allowPartialFills = false;
        orderData.orderSize = FILL;
        RolloverTypes.RolloverIntent memory intentA = _buildIntent(bytes32(0), FILL, DST);
        orderData.rolloverIntentHash = _zeroDigestHash(intentA);
        bytes32 orderDigest = _openOrder(orderData);
        intentA.orderDigest = orderDigest;
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);

        _approveFiller(FILL, 0);
        _doRolloverAs(orderDigest, orderData, intentA, FILL, filler);
    }

    /// @notice Pins behaviour: swapped Intent Reverts.
    function testRevert_swappedIntentReverts() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.allowPartialFills = false;
        orderData.orderSize = FILL;

        RolloverTypes.RolloverIntent memory intentA = _buildIntent(bytes32(0), FILL, DST);
        orderData.rolloverIntentHash = _zeroDigestHash(intentA);
        bytes32 orderDigest = _openOrder(orderData);

        RolloverTypes.RolloverIntent memory intentB = _buildSecondIntent(orderDigest);
        bytes memory cptHolderSigB = _signOrder(cptHolderPk, orderData);

        _approveFiller(FILL, 0);
        vm.expectRevert(CorkRolloverContract__IntentHashMismatch.selector);
        _doRolloverAs(orderDigest, orderData, intentB, FILL, filler);
    }

    /// @notice Pins behaviour: tampered Intent Reverts.
    function testRevert_tamperedIntentReverts() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.allowPartialFills = false;
        orderData.orderSize = FILL;
        RolloverTypes.RolloverIntent memory intent = _buildIntent(bytes32(0), FILL, DST);
        orderData.rolloverIntentHash = _zeroDigestHash(intent);
        bytes32 orderDigest = _openOrder(orderData);
        intent.orderDigest = orderDigest;

        intent.deadline = intent.deadline - 1;
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);

        _approveFiller(FILL, 0);
        vm.expectRevert(CorkRolloverContract__IntentHashMismatch.selector);
        _doRolloverAs(orderDigest, orderData, intent, FILL, filler);
    }
}
