// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../base/BaseTest.sol";
import { BaseSettler } from "src/BaseSettler.sol";
import { ExactSettler as Settler } from "src/ExactSettler.sol";
import {
    Settler__BadUserSignature,
    Settler__DstCstEqualsPremiumToken,
    Settler__MarkExpiredBeforeFillDeadline,
    Settler__OpenAfterOpenDeadline,
    Settler__OrderNotCancellable,
    Settler__SrcCstEqualsPremiumToken,
    Settler__WrongOriginChain,
    Settler__ZeroPremiumRate
} from "src/errors/SettlerErrors.sol";
import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";
import { SettlerTypes } from "src/types/SettlerTypes.sol";

/// @notice Settler mutation-kill suite — pins resolve/open/fill/settle/cancel behaviour against operator mutations.
contract SettlerMutationTest is BaseTest {
    /// @notice resolve returns populated order fields.
    function test_resolveReturnsPopulatedOrderFields() public view {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        ERC7683Types.ResolvedCrossChainOrder memory r = settler.resolveFor(g, "");
        assertEq(r.user, cptHolder);
        assertEq(r.fillInstructions.length, 1);
        assertGt(r.maxSpent.length, 0);
        assertGt(r.minReceived.length, 0);
    }

    /// @notice open transitions status to opened.
    function test_openTransitionsStatusToOpened() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        bytes32 digest = _openOrder(orderData);
        assertEq(uint8(settler.orderStatus(digest)), uint8(RolloverTypes.OrderStatus.Opened));
    }

    /// @notice reverts when open for rejected for bad user signature.
    function testRevert_openForRejectedForBadUserSignature() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        (, uint256 evePk) = makeAddrAndKey("eveMut5");
        bytes memory sig = _signOrder(evePk, orderData);
        bytes memory empty;
        vm.expectRevert(Settler__BadUserSignature.selector);
        settler.openFor(g, sig, empty);
    }

    /// @notice reverts when open rejected after open deadline.
    function testRevert_openRejectedAfterOpenDeadline() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory sig = _signOrder(cptHolderPk, orderData);
        vm.warp(orderData.openDeadline + 1);
        vm.expectRevert(Settler__OpenAfterOpenDeadline.selector);
        vm.prank(cptHolder);
        settler.openFor(g, sig, "");
    }

    /// @notice reverts when open rejected for wrong origin chain.
    function testRevert_openRejectedForWrongOriginChain() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.originChainId = 99999;
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory sig = _signOrder(cptHolderPk, orderData);
        vm.expectRevert(Settler__WrongOriginChain.selector);
        vm.prank(cptHolder);
        settler.openFor(g, sig, "");
    }

    /// @notice reverts when open rejected when src cst matches premium token.
    function testRevert_openRejectedWhenSrcCstMatchesPremiumToken() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.premiumToken = orderData.srcCstToken;
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory sig = _signOrder(cptHolderPk, orderData);
        vm.expectRevert(Settler__SrcCstEqualsPremiumToken.selector);
        vm.prank(cptHolder);
        settler.openFor(g, sig, "");
    }

    /// @notice reverts when open rejected when dst cst matches premium token.
    function testRevert_openRejectedWhenDstCstMatchesPremiumToken() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.premiumToken = orderData.dstCstToken;
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory sig = _signOrder(cptHolderPk, orderData);
        vm.expectRevert(Settler__DstCstEqualsPremiumToken.selector);
        vm.prank(cptHolder);
        settler.openFor(g, sig, "");
    }

    /// @notice reverts when cancelled order remains terminal on second cancel.
    function testRevert_cancelledOrderRemainsTerminalOnSecondCancel() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        bytes32 digest = _openOrder(orderData);
        bytes memory sig =
            _signCancelFor(orderData.settler, cptHolderPk, digest, orderData.orderSalt);
        bytes memory originData = _originData(orderData);
        settler.cancel(digest, originData, sig);
        vm.expectRevert(Settler__OrderNotCancellable.selector);
        settler.cancel(digest, originData, sig);
    }

    /// @notice exact order does not write partial polarity slots.
    function test_exactOrderDoesNotWritePartialPolaritySlots() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.allowPartialFills = false;
        bytes32 digest = _openOrder(orderData);
        assertEq(partialSettler.rolloverAccountingOf(digest).dstCstEscrowed, 0);
        assertEq(partialSettler.rolloverAccountingOf(digest).participantSlotCount, 0);
    }

    /// @notice partial order does not write exact polarity slots.
    function test_partialOrderDoesNotWriteExactPolaritySlots() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData = _usePartialSettler(orderData);
        orderData.orderSalt = 4242;
        bytes32 digest = _openOrder(orderData);
        SettlerTypes.ExactRolloverAccounting memory ef = settler.rolloverAccountingOf(digest);
        assertEq(ef.dstCstProduced, 0);
    }

    /// @notice reverts when markExpired rejected before fill deadline.
    function testRevert_markExpiredRejectedBeforeFillDeadline() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        bytes32 digest = _openOrder(orderData);
        vm.expectRevert(Settler__MarkExpiredBeforeFillDeadline.selector);
        settler.markExpired(digest, _originData(orderData));
    }

    /// @notice reverts when cancel signature binds to specific order id.
    function testRevert_cancelSignatureBindsToSpecificOrderId() public {
        RolloverTypes.OrderData memory odA = _baseOrder();
        bytes32 digestA = _openOrder(odA);

        bytes memory sigA = _signCancelFor(odA.settler, cptHolderPk, digestA, odA.orderSalt);
        bytes32 digestB = bytes32(uint256(digestA) ^ 0xFFFF);
        vm.expectRevert();
        settler.cancel(digestB, _originData(odA), sigA);
    }

    /// @notice Settler ownership is transferable and remains separate from protocol roles.
    function test_settlerTransferOwnership_DoesNotGrantProtocolRoles() public {
        address newOwner = address(0xBEEF);
        (bool ok,) =
            address(settler).call(abi.encodeWithSignature("transferOwnership(address)", newOwner));
        assertTrue(ok, "transferOwnership callable");
        assertEq(settler.owner(), newOwner, "owner transferred");
        assertFalse(settler.hasRole(settler.DEFAULT_ADMIN_ROLE(), newOwner), "no admin grant");
        assertFalse(settler.hasRole(settler.RECOVERY_ROLE(), newOwner), "no recovery grant");
        assertFalse(settler.hasRole(keccak256("PAUSER_ROLE"), newOwner), "no pauser grant");
        assertFalse(settler.hasRole(keccak256("UNPAUSER_ROLE"), newOwner), "no unpauser grant");
    }

    /// @notice reverts when open rejected for zero premium rate.
    function testRevert_openRejectedForZeroPremiumRate() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.minPremiumPerShare = 0;
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory sig = _signOrder(cptHolderPk, orderData);
        vm.expectRevert(Settler__ZeroPremiumRate.selector);
        vm.prank(cptHolder);
        settler.openFor(g, sig, "");
    }

    /// @notice open for on already opened is idempotent.
    function test_openForOnAlreadyOpenedIsIdempotent() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        bytes32 digest = _openOrder(orderData);
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory sig = _signOrder(cptHolderPk, orderData);
        bytes memory empty;

        settler.openFor(g, sig, empty);
        assertEq(uint8(settler.orderStatus(digest)), uint8(RolloverTypes.OrderStatus.Opened));
    }

    /// @notice reverts when open rejected when open deadline exceeds fill deadline.
    function testRevert_openRejectedWhenOpenDeadlineExceedsFillDeadline() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();

        orderData.fillDeadline = orderData.openDeadline - 1;
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory sig = _signOrder(cptHolderPk, orderData);
        vm.expectRevert();
        vm.prank(cptHolder);
        settler.openFor(g, sig, "");
    }
}
