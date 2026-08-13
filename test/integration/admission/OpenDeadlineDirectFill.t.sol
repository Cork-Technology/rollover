// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { FillScaffold } from "../../base/FillScaffold.sol";
import { BaseSettler } from "src/BaseSettler.sol";
import {
    Settler__FillAfterDeadline,
    Settler__OpenAfterOpenDeadline
} from "src/errors/SettlerErrors.sol";
import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice Pins INV-OPENDEADLINE-ADMISSION-CEILING and
///         INV-OPENED-ORDERS-FILLABLE-UNTIL-FILLDEADLINE for the BaseSettler half:
///         past openDeadline, no path may admit an order from `None` to any
///         non-`None` status (Reading B). Once `Opened`, the order remains fillable
///         via direct `fill` until `fillDeadline`, regardless of `openDeadline`.
contract OpenDeadlineDirectFillTest is FillScaffold {
    /// @notice Order size used across admission tests.
    uint256 internal constant ORDER = 1_000e18;

    /// @inheritdoc BaseTest
    function setUp() public override {
        super.setUp();
        vm.startPrank(filler);
        srcCst.approve(address(settler), type(uint256).max);
        srcCst.approve(address(partialSettler), type(uint256).max);
        vm.stopPrank();
    }

    function _prepare(RolloverTypes.OrderData memory orderData)
        internal
        view
        returns (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        )
    {
        RolloverTypes.RolloverIntent memory probe = _buildIntent(bytes32(0), ORDER, ORDER);
        orderData.rolloverIntentHash = _zeroDigestHash(probe);
        orderDigest = _orderDigest(orderData);
        intent = _buildIntent(orderDigest, ORDER, ORDER);
        cptHolderSig = _signOrder(cptHolderPk, orderData);
    }

    /// @notice direct-fill at `None` status PAST `openDeadline` is now rejected (Reading B
    ///         unification). Closes the direct-fill admission bypass.
    function testRevert_directFill_pastOpenDeadline_None_status() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(orderData);

        vm.warp(uint256(orderData.openDeadline) + 1);

        vm.expectRevert(Settler__OpenAfterOpenDeadline.selector);
        _doRolloverAs(orderDigest, orderData, intent, ORDER, filler);
    }

    /// @notice direct-fill at `None` status BEFORE `openDeadline` still succeeds (regression).
    function test_directFill_beforeOpenDeadline_None_status_succeeds() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(orderData);

        _doRolloverAs(orderDigest, orderData, intent, ORDER, filler);
        assertEq(settler.rolloverAccountingOf(orderDigest).dstCstProduced, ORDER);
    }

    /// @notice already-`Opened` order remains fillable past `openDeadline` (until `fillDeadline`).
    ///         openFor admits before the deadline; fill executes after.
    function test_directFill_alreadyOpened_pastOpenDeadline_succeeds() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(orderData);

        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory userSig = _signOrder(cptHolderPk, orderData);
        settler.openFor(g, userSig, "");
        assertEq(uint8(settler.orderStatus(orderDigest)), uint8(RolloverTypes.OrderStatus.Opened));

        vm.warp(uint256(orderData.openDeadline) + 1);
        _doRolloverAs(orderDigest, orderData, intent, ORDER, filler);
        assertEq(settler.rolloverAccountingOf(orderDigest).dstCstProduced, ORDER);
    }

    /// @notice direct-fill past `fillDeadline` still reverts (fillDeadline gate unchanged).
    function testRevert_directFill_pastFillDeadline() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(orderData);

        vm.warp(uint256(orderData.fillDeadline) + 1);

        vm.expectRevert(Settler__FillAfterDeadline.selector);
        _doRolloverAs(orderDigest, orderData, intent, ORDER, filler);
    }

    /// @notice openFor past `openDeadline` still reverts; the admission-side gate remains intact.
    function testRevert_openFor_pastOpenDeadline() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory sig = _signOrder(cptHolderPk, orderData);

        vm.warp(uint256(orderData.openDeadline) + 1);
        vm.expectRevert(Settler__OpenAfterOpenDeadline.selector);
        settler.openFor(g, sig, "");
    }
}
