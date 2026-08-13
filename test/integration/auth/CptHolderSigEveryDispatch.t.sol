// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { FillScaffold } from "../../base/FillScaffold.sol";
import {
    CorkRolloverContract__BadIntentSignature
} from "src/errors/CorkRolloverContractErrors.sol";
import { ISettler } from "src/interfaces/settlers/ISettler.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice Owner authorization: every RolloverContract hook dispatch verifies the cPT holder's
///         `OrderData` signature. There is no alternate authorization path.
contract CptHolderSigEveryDispatchTest is FillScaffold {
    /// @notice Rollover fill amount for the test order.
    uint256 internal constant FILL = 1_000e18;
    /// @notice Destination amount in the rollover intent.
    uint256 internal constant DST = 1_000e18;
    /// @notice Premium token pull amount approved for the filler.
    uint256 internal constant PREMIUM = 10e18;

    /// @notice Opened orders still need the cPT-holder signature on every hook dispatch.
    function testRevert_openedOrderFirstFillWithoutCptHolderSigReverts() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.allowPartialFills = false;
        orderData.orderSize = FILL;
        RolloverTypes.RolloverIntent memory intent = _buildIntent(bytes32(0), FILL, DST);
        orderData.rolloverIntentHash = _zeroDigestHash(intent);
        bytes32 orderDigest = _openOrder(orderData);
        intent.orderDigest = orderDigest;

        _approveFiller(FILL, PREMIUM);
        bytes memory fillerData = _atomicFillerData(
            FILL, DEFAULT_PREMIUM_CAP, intent, filler, _subFillerKey(filler), bytes("")
        );

        vm.prank(filler);
        vm.expectRevert(CorkRolloverContract__BadIntentSignature.selector);
        ISettler(orderData.settler).fill(orderDigest, _originData(orderData), fillerData);
    }

    /// @notice Owner authorization checks the cPT-holder signature over `orderDigest`.
    function testRevert_ownerAuthRejectsBadCptHolderSignature() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.allowPartialFills = false;
        orderData.orderSize = FILL;
        RolloverTypes.RolloverIntent memory intent = _buildIntent(bytes32(0), FILL, DST);
        orderData.rolloverIntentHash = _zeroDigestHash(intent);
        bytes32 orderDigest = _openOrder(orderData);
        intent.orderDigest = orderDigest;

        (, uint256 strangerPk) = makeAddrAndKey("stranger-cpt-holder");
        bytes memory badCptHolderSig = _signOrder(strangerPk, orderData);
        _approveFiller(FILL, PREMIUM);
        bytes memory fillerData = _atomicFillerData(
            FILL, DEFAULT_PREMIUM_CAP, intent, filler, _subFillerKey(filler), badCptHolderSig
        );

        vm.prank(filler);
        vm.expectRevert(CorkRolloverContract__BadIntentSignature.selector);
        ISettler(orderData.settler).fill(orderDigest, _originData(orderData), fillerData);
    }

    /// @notice Atomic fill threads the envelope cPT-holder signature through the synthesized
    ///         PREMIUM payload so both RolloverContract dispatches can verify it.
    function test_atomicPremiumUsesEnvelopeCptHolderSig() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.allowPartialFills = false;
        orderData.orderSize = FILL;
        RolloverTypes.RolloverIntent memory intent = _buildIntent(bytes32(0), FILL, DST);
        orderData.rolloverIntentHash = _zeroDigestHash(intent);
        bytes32 orderDigest = _openOrder(orderData);
        intent.orderDigest = orderDigest;
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);

        _approveFiller(FILL, PREMIUM);

        _doAtomicFillAs(
            orderDigest,
            orderData,
            intent,
            FILL,
            filler,
            filler,
            _subFillerKey(filler),
            DEFAULT_PREMIUM_CAP
        );
    }

    /// @notice A direct PREMIUM dispatch without a cPT-holder signature cannot rely on any
    ///         prior authorization state.
    function testRevert_premiumDispatchWithoutCptHolderSigReverts() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.allowPartialFills = false;
        orderData.orderSize = FILL;
        RolloverTypes.RolloverIntent memory intent = _buildIntent(bytes32(0), FILL, DST);
        orderData.rolloverIntentHash = _zeroDigestHash(intent);
        bytes32 orderDigest = _openOrder(orderData);
        intent.orderDigest = orderDigest;

        RolloverTypes.FillContext memory fillContext = _fillContext({
            filler_: filler,
            fillAmount: FILL,
            rolloverIntentHash: orderData.rolloverIntentHash,
            fillDeadline: orderData.fillDeadline,
            allowPartialFills: orderData.allowPartialFills,
            orderSize: orderData.orderSize,
            originSettler: address(settler),
            premiumToken_: orderData.premiumToken,
            premium: 0
        });

        vm.prank(address(settler));
        vm.expectRevert(CorkRolloverContract__BadIntentSignature.selector);
        factory.executeIntentHooks(
            rolloverContract,
            orderDigest,
            RolloverTypes.HookPhase.PREMIUM,
            intent,
            bytes(""),
            fillContext,
            orderData
        );
    }
}
