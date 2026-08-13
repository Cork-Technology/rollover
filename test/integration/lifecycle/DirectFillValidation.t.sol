// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { FillScaffold } from "../../base/FillScaffold.sol";
import { Vm } from "forge-std/Vm.sol";
import { BaseSettler } from "src/BaseSettler.sol";
import { ExactSettler } from "src/ExactSettler.sol";
import {
    Settler__OpenAfterOpenDeadline,
    Settler__OrderInTerminalState,
    Settler__RolloverParamsSettlerMismatch,
    Settler__SamePoolId,
    Settler__ZeroRolloverIntentHash
} from "src/errors/SettlerErrors.sol";
import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice direct-fill (no openFor) path validates order envelope before terminal status check.
contract DirectFillValidationTest is FillScaffold {
    /// @notice Order.
    uint256 internal constant ORDER = 1_000e18;

    /// @notice Mirror of ERC-7683 `Open`.
    /// @param orderId Canonical order id.
    /// @param resolvedOrder Resolved order projection.
    event Open(bytes32 indexed orderId, ERC7683Types.ResolvedCrossChainOrder resolvedOrder);

    /// @inheritdoc BaseTest
    function setUp() public override {
        super.setUp();
        vm.startPrank(filler);
        srcCst.approve(address(settler), type(uint256).max);
        srcCst.approve(address(partialSettler), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice _prepare.
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

    /// @notice _fill.
    function _fill(
        bytes32 orderDigest,
        RolloverTypes.OrderData memory orderData,
        RolloverTypes.RolloverIntent memory intent,
        bytes memory cptHolderSig
    ) internal {
        _doRolloverAs(orderDigest, orderData, intent, ORDER, filler);
    }

    function _expectOpenEvent(
        bytes32 orderDigest,
        ERC7683Types.ResolvedCrossChainOrder memory resolved
    ) internal {
        vm.expectEmit(true, false, false, true, address(settler));
        emit Open(orderDigest, resolved);
    }

    /// @notice reverts when direct unopened rollover rejects same pool.
    function testRevert_directUnopenedRolloverRejectsSamePool() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        orderData.dstCstToken = address(srcCst);
        orderData.rolloverParams.dstCstToken = address(srcCst);
        orderData.rolloverParams.dstPoolId = orderData.rolloverParams.srcPoolId;
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(orderData);

        uint256 fillerBefore = srcCst.balanceOf(filler);
        vm.expectRevert(Settler__SamePoolId.selector);
        _fill(orderDigest, orderData, intent, cptHolderSig);
        assertEq(srcCst.balanceOf(filler), fillerBefore, "validated before source movement");
    }

    /// @notice reverts when direct unopened rollover rejects zero rollover intent hash.
    function testRevert_directUnopenedRolloverRejectsZeroRolloverIntentHash() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        orderData.rolloverIntentHash = bytes32(0);
        bytes32 orderDigest = _orderDigest(orderData);
        RolloverTypes.RolloverIntent memory intent = _buildIntent(orderDigest, ORDER, ORDER);
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);

        vm.expectRevert(Settler__ZeroRolloverIntentHash.selector);
        _fill(orderDigest, orderData, intent, cptHolderSig);
    }

    /// @notice direct-fill rejects mismatched `rolloverParams.settler` at Settler
    ///         admission (INV-PARAMS-SETTLER-PIN-MIRROR). The rolloverContract's downstream
    ///         `CorkRolloverContract__SignedSettlerOriginMismatch` defence-in-depth remains in source
    ///         but is unreachable from the Settler admission path.
    function testRevert_directUnopenedRolloverRejectsWrongSettler() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        orderData.rolloverParams.settler = address(0xBEEF);
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(orderData);

        vm.expectRevert(Settler__RolloverParamsSettlerMismatch.selector);
        _fill(orderDigest, orderData, intent, cptHolderSig);
    }

    /// @notice direct unopened rollover past openDeadline reverts under Reading-B unification.
    ///         openDeadline is the admission ceiling for `None` → non-`None` transitions on
    ///         every path, including direct-fill. Once `Opened`, the order remains fillable
    ///         past `openDeadline` until `fillDeadline` (see OpenDeadlineDirectFill suite).
    function testRevert_directUnopenedRolloverPastOpenDeadlineRejected() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(orderData);

        vm.warp(uint256(orderData.openDeadline) + 1);
        vm.expectRevert(Settler__OpenAfterOpenDeadline.selector);
        _fill(orderDigest, orderData, intent, cptHolderSig);
    }

    /// @notice `open` emits ERC-7683 `Open`.
    function test_open_emitsOpenEvent() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        (bytes32 orderDigest,,) = _prepare(orderData);
        assertEq(uint8(settler.orderStatus(orderDigest)), uint8(RolloverTypes.OrderStatus.None));

        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        ERC7683Types.ResolvedCrossChainOrder memory resolved = settler.resolveFor(g, "");
        bytes memory userSig = _signOrder(cptHolderPk, orderData);

        _expectOpenEvent(orderDigest, resolved);
        settler.openFor(g, userSig, "");
    }

    /// @notice `openFor` emits ERC-7683 `Open`.
    function test_openFor_emitsOpenEvent() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        (bytes32 orderDigest,,) = _prepare(orderData);
        assertEq(uint8(settler.orderStatus(orderDigest)), uint8(RolloverTypes.OrderStatus.None));

        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        ERC7683Types.ResolvedCrossChainOrder memory resolved = settler.resolveFor(g, "");
        bytes memory userSig = _signOrder(cptHolderPk, orderData);

        _expectOpenEvent(orderDigest, resolved);
        settler.openFor(g, userSig, "");
    }

    /// @notice Direct fill from `None` emits ERC-7683 `Open`.
    function test_directFillFromNone_emitsOpenEvent() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(orderData);
        assertEq(uint8(settler.orderStatus(orderDigest)), uint8(RolloverTypes.OrderStatus.None));

        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        ERC7683Types.ResolvedCrossChainOrder memory resolved = settler.resolveFor(g, "");

        _expectOpenEvent(orderDigest, resolved);
        _fill(orderDigest, orderData, intent, cptHolderSig);
    }

    /// @notice Fill on an already-opened order does not emit a second `Open`.
    function test_openedFillDoesNotEmitOpenAgain() public {
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

        vm.recordLogs();
        _fill(orderDigest, orderData, intent, cptHolderSig);

        bytes32 openTopic = keccak256(
            "Open(bytes32,(address,uint256,uint32,uint32,bytes32,(bytes32,uint256,bytes32,uint256)[],(bytes32,uint256,bytes32,uint256)[],(uint64,bytes32,bytes)[]))"
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(settler) && logs[i].topics[0] == openTopic) {
                revert("duplicate Open on already-open fill");
            }
        }
    }

    /// @notice Under atomic-fill the direct (None → Settled) path completes in one
    ///         frame; a follow-up `openFor` on a Settled order reverts with
    ///         `Settler__OrderInTerminalState`. This pins the new terminal semantics.
    function test_directUnopenedRolloverStillSupportsFillThenOpenFor() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(orderData);

        _fill(orderDigest, orderData, intent, cptHolderSig);
        assertEq(uint8(settler.orderStatus(orderDigest)), uint8(RolloverTypes.OrderStatus.Settled));

        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory sig = _signOrder(cptHolderPk, orderData);
        vm.expectRevert(Settler__OrderInTerminalState.selector);
        settler.openFor(g, sig, "");
    }
}
