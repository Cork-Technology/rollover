// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { FillScaffold } from "../../base/FillScaffold.sol";
import { BaseSettler } from "src/BaseSettler.sol";
import { CorkRolloverContract } from "src/CorkRolloverContract.sol";
import {
    CorkRolloverContract__PremiumAlreadyFiredForFiller
} from "src/errors/CorkRolloverContractErrors.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice premiumFiller transient binding is per-rolloverContract-per-call and cleared after dispatch.
contract PremiumFillerBindingTest is FillScaffold {
    /// @notice Fill.
    uint256 internal constant FILL = 1_000e18;

    /// @notice Dst.
    uint256 internal constant DST = 1_000e18;

    /// @notice Premium.
    uint256 internal constant PREMIUM = 10e18;

    /// @notice _prepare order.
    function _prepareOrder(uint64 nonce, bool allowPartial, uint256 orderSize)
        internal
        returns (
            bytes32 orderDigest,
            RolloverTypes.OrderData memory orderData,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        )
    {
        orderData = _baseOrder();
        orderData.orderSalt = nonce;
        if (allowPartial) {
            orderData = _usePartialSettler(orderData);
        } else {
            orderData.allowPartialFills = false;
        }
        orderData.orderSize = orderSize;
        intent = _buildIntent(bytes32(0), FILL, DST);
        orderData.rolloverIntentHash = _zeroDigestHash(intent);
        orderDigest = _openOrder(orderData);
        intent.orderDigest = orderDigest;
        cptHolderSig = _signOrder(cptHolderPk, orderData);
    }

    /// @notice _fund and approve.
    function _fundAndApprove(address fillerAddr, uint256 srcAmount, uint256 premium) internal {
        if (fillerAddr != filler) {
            srcCst.mint(fillerAddr, srcAmount);
            premiumToken.mint(fillerAddr, premium);
        }
        vm.startPrank(fillerAddr);
        srcCst.approve(address(settler), srcAmount);
        srcCst.approve(address(partialSettler), srcAmount);
        premiumToken.approve(address(settler), premium);
        premiumToken.approve(address(partialSettler), premium);
        vm.stopPrank();
    }

    /// @notice same rolloverContract different order different filler premiums succeed in one tx.
    function test_sameRolloverContractDifferentOrderDifferentFillerPremiumsSucceedInOneTx() public {
        address fillerB = address(0xB0B);

        (
            bytes32 orderDigestA,
            RolloverTypes.OrderData memory orderDataA,
            RolloverTypes.RolloverIntent memory intentA,
            bytes memory cptHolderSigA
        ) = _prepareOrder(1, false, FILL);

        (
            bytes32 orderDigestB,
            RolloverTypes.OrderData memory orderDataB,
            RolloverTypes.RolloverIntent memory intentB,
            bytes memory cptHolderSigB
        ) = _prepareOrder(2, false, FILL);

        _fundAndApprove(filler, FILL, PREMIUM);
        _fundAndApprove(fillerB, FILL, PREMIUM);

        _doRolloverAs(orderDigestA, orderDataA, intentA, FILL, filler);

        _doRolloverAs(orderDigestB, orderDataB, intentB, FILL, fillerB);

        assertTrue(
            CorkRolloverContract(rolloverContract)
                .premiumFiredFor(orderDigestA, filler, bytes32(uint256(uint160(filler)))),
            "A premium fired"
        );
        assertTrue(
            CorkRolloverContract(rolloverContract)
                .premiumFiredFor(orderDigestB, fillerB, bytes32(uint256(uint160(fillerB)))),
            "B premium fired"
        );
    }

    /// @notice Two fillers on the same partial order each pay premium independently when
    ///         aggregate consumption has not yet reached `orderSize`.
    function test_samePartialOrderDifferentFillersCanPayPremiumAfterRolloverRecordsExist() public {
        address fillerB = address(0xB0B);
        uint256 half = FILL / 2;

        (
            bytes32 orderDigest,
            RolloverTypes.OrderData memory orderData,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepareOrder(3, true, FILL);

        _fundAndApprove(filler, half, PREMIUM);
        _fundAndApprove(fillerB, half, PREMIUM);

        _doRolloverAs(orderDigest, orderData, intent, half, filler);

        assertTrue(
            CorkRolloverContract(rolloverContract)
                .premiumFiredFor(orderDigest, filler, bytes32(uint256(uint160(filler)))),
            "A premium fired"
        );
        assertFalse(
            CorkRolloverContract(rolloverContract)
                .premiumFiredFor(orderDigest, fillerB, bytes32(uint256(uint160(fillerB)))),
            "B bit clear pre-second-fill"
        );

        _doRolloverAs(orderDigest, orderData, intent, half, fillerB);

        assertTrue(
            CorkRolloverContract(rolloverContract)
                .premiumFiredFor(orderDigest, fillerB, bytes32(uint256(uint160(fillerB)))),
            "B premium fired after second fill"
        );
        assertEq(
            uint8(partialSettler.orderStatus(orderDigest)),
            uint8(RolloverTypes.OrderStatus.Settled),
            "half+half partial fills reach orderSize and terminalize"
        );
    }

    /// @notice reverts when duplicate same order same filler premium reverts at rolloverContract.
    function testRevert_duplicateSameOrderSameFillerPremiumRevertsAtRolloverContract() public {
        (
            bytes32 orderDigest,
            RolloverTypes.OrderData memory orderData,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepareOrder(4, false, FILL);

        _fundAndApprove(filler, FILL, PREMIUM * 2);

        _doRolloverAs(orderDigest, orderData, intent, FILL, filler);

        RolloverTypes.FillContext memory fillContext = _fillContext(
            filler,
            0,
            orderData.rolloverIntentHash,
            orderData.fillDeadline,
            false,
            FILL,
            address(settler),
            address(premiumToken),
            PREMIUM
        );

        vm.expectRevert(CorkRolloverContract__PremiumAlreadyFiredForFiller.selector);
        vm.prank(address(settler));
        factory.executeIntentHooks(
            rolloverContract,
            orderDigest,
            RolloverTypes.HookPhase.PREMIUM,
            intent,
            _signOrder(cptHolderPk, orderData),
            fillContext,
            orderData
        );
    }
}
