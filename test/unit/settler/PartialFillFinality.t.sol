// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { FillScaffold } from "../../base/FillScaffold.sol";
import { BaseSettler } from "src/BaseSettler.sol";
import { Settler__RolloverAmountOutOfBounds } from "src/errors/SettlerErrors.sol";
import { IPartialSettler } from "src/interfaces/settlers/IPartialSettler.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice Regression tests for INV-PARTIAL-AGGREGATE-SRC-CONSUMED partial-fill finality.
contract PartialFillFinalityTest is FillScaffold {
    /// @notice Total srcCST size for partial-fill orders in this suite.
    uint256 internal constant ORDER_SIZE = 1_000e18;
    /// @notice Per-fill chunk below `ORDER_SIZE` for multi-fill scenarios.
    uint256 internal constant CHUNK = 400e18;

    function _partialOrder(uint64 salt)
        internal
        view
        returns (RolloverTypes.OrderData memory orderData, bytes32 orderDigest)
    {
        orderData = _usePartialSettler(_baseOrder());
        orderData.orderSize = ORDER_SIZE;
        orderData.orderSalt = salt;
        RolloverTypes.RolloverIntent memory probe = _buildIntent(bytes32(0), ORDER_SIZE, ORDER_SIZE);
        orderData.rolloverIntentHash = _zeroDigestHash(probe);
        orderDigest = _orderDigest(orderData);
    }

    /// @notice A single under-sized partial leaves the order Opened.
    function test_underSizedPartial_doesNotTerminalizeOrder() public {
        (RolloverTypes.OrderData memory orderData, bytes32 orderDigest) = _partialOrder(1);
        RolloverTypes.RolloverIntent memory intent =
            _buildIntent(orderDigest, ORDER_SIZE, ORDER_SIZE);
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);

        _approveFiller(CHUNK, DEFAULT_PREMIUM_CAP);
        _doRolloverAs(orderDigest, orderData, intent, CHUNK, filler);

        assertEq(
            uint8(partialSettler.orderStatus(orderDigest)),
            uint8(RolloverTypes.OrderStatus.Opened),
            "under-sized partial stays Opened"
        );
        assertEq(
            IPartialSettler(address(partialSettler))
            .rolloverAccountingOf(orderDigest)
            .srcCstConsumed,
            CHUNK
        );
    }

    /// @notice Two partial fills from different fillers aggregate while still below order size.
    function test_secondPartialFill_joinsWhileAggregateBelowOrderSize() public {
        (RolloverTypes.OrderData memory orderData, bytes32 orderDigest) = _partialOrder(2);
        RolloverTypes.RolloverIntent memory intent =
            _buildIntent(orderDigest, ORDER_SIZE, ORDER_SIZE);
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);

        address fillerB = address(0xB0B);
        srcCst.mint(fillerB, ORDER_SIZE);
        premiumToken.mint(fillerB, 1_000_000e18);
        vm.startPrank(fillerB);
        srcCst.approve(address(partialSettler), type(uint256).max);
        premiumToken.approve(address(partialSettler), type(uint256).max);
        vm.stopPrank();

        _approveFiller(CHUNK, DEFAULT_PREMIUM_CAP);
        _doRolloverAs(orderDigest, orderData, intent, CHUNK, filler);
        _doRolloverAs(orderDigest, orderData, intent, CHUNK, fillerB);

        assertEq(
            uint8(partialSettler.orderStatus(orderDigest)), uint8(RolloverTypes.OrderStatus.Opened)
        );
        assertEq(
            IPartialSettler(address(partialSettler))
            .rolloverAccountingOf(orderDigest)
            .srcCstConsumed,
            2 * CHUNK
        );
    }

    /// @notice Aggregate srcCST consumption cannot exceed `orderSize`.
    function test_aggregateCannotExceedOrderSize() public {
        (RolloverTypes.OrderData memory orderData, bytes32 orderDigest) = _partialOrder(3);
        RolloverTypes.RolloverIntent memory intent =
            _buildIntent(orderDigest, ORDER_SIZE, ORDER_SIZE);
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);

        _approveFiller(ORDER_SIZE, DEFAULT_PREMIUM_CAP);
        _doRolloverAs(orderDigest, orderData, intent, CHUNK, filler);

        uint256 overshoot = ORDER_SIZE - CHUNK + 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                Settler__RolloverAmountOutOfBounds.selector, ORDER_SIZE, CHUNK + overshoot
            )
        );
        _doRolloverAs(orderDigest, orderData, intent, overshoot, filler);
    }

    /// @notice Full aggregate consumption settles the order when escrow drains.
    function test_fullAggregateConsumption_terminalizesWhenEscrowDrains() public {
        (RolloverTypes.OrderData memory orderData, bytes32 orderDigest) = _partialOrder(4);
        RolloverTypes.RolloverIntent memory intent =
            _buildIntent(orderDigest, ORDER_SIZE, ORDER_SIZE);
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);

        _approveFiller(ORDER_SIZE, DEFAULT_PREMIUM_CAP);
        _doRolloverAs(orderDigest, orderData, intent, ORDER_SIZE, filler);

        assertEq(
            IPartialSettler(address(partialSettler))
            .rolloverAccountingOf(orderDigest)
            .srcCstConsumed,
            ORDER_SIZE
        );
        assertEq(
            uint8(partialSettler.orderStatus(orderDigest)), uint8(RolloverTypes.OrderStatus.Settled)
        );
        assertEq(partialSettler.rolloverAccountingOf(orderDigest).dstCstEscrowed, 0);
    }

    /// @notice Under-filled partial with drained escrow: cPT-holder cancel clears unfilled remainder.
    function test_underfilledPartial_escrowDrained_cptHolderCancelCancelled() public {
        (RolloverTypes.OrderData memory orderData, bytes32 orderDigest) = _partialOrder(5);
        RolloverTypes.RolloverIntent memory intent =
            _buildIntent(orderDigest, ORDER_SIZE, ORDER_SIZE);
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);

        _approveFiller(CHUNK, DEFAULT_PREMIUM_CAP);
        _doRolloverAs(orderDigest, orderData, intent, CHUNK, filler);

        assertEq(partialSettler.rolloverAccountingOf(orderDigest).dstCstEscrowed, 0);
        assertLt(
            IPartialSettler(address(partialSettler))
            .rolloverAccountingOf(orderDigest)
            .srcCstConsumed,
            ORDER_SIZE
        );
        assertEq(
            uint8(partialSettler.orderStatus(orderDigest)), uint8(RolloverTypes.OrderStatus.Opened)
        );

        bytes memory cancelSig =
            _signCancelFor(address(partialSettler), cptHolderPk, orderDigest, orderData.orderSalt);
        vm.prank(orderData.user);
        partialSettler.cancel(orderDigest, _originData(orderData), cancelSig);

        assertEq(
            uint8(partialSettler.orderStatus(orderDigest)),
            uint8(RolloverTypes.OrderStatus.Cancelled)
        );
    }
}
