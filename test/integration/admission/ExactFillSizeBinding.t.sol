// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { FillScaffold } from "../../base/FillScaffold.sol";
import { BaseSettler } from "src/BaseSettler.sol";
import { ExactSettler } from "src/ExactSettler.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice Pins INV-EXACT-FILL-SIZE-BINDING.
///
///         Two admission/post-exec rules:
///         (1) BaseSettler admission gate (both modes):
///             `1 <= payload.fillAmount <= orderData.orderSize`.
///         (2) ExactSettler mode admission (`!allowUnderfill` exact only):
///             `fillAmount == orderSize`, paired with the post-exec
///             `srcLeftover == 0` check. Closes Pashov F-01 dust-fill grief class.
///
///         Tests FAIL on origin/main HEAD (admission gate + post-exec hook do not exist).
///         Tests PASS after src impl ships.
/// @custom:invariant INV-EXACT-FILL-SIZE-BINDING
contract ExactFillSizeBindingTest is FillScaffold {
    /// @notice Order size used across admission tests.
    uint256 internal constant ORDER = 1_000e18;
    /// @notice 4-byte selector for `Settler__RolloverAmountOutOfBounds(uint256,uint256)`.
    bytes4 internal constant SEL_ROLLOVER_AMOUNT_OUT_OF_BOUNDS =
        bytes4(keccak256("Settler__RolloverAmountOutOfBounds(uint256,uint256)"));
    /// @notice 4-byte selector for `Settler__ExactFillRequiresFullOrderSize(uint256,uint256)`.
    bytes4 internal constant SEL_EXACT_REQUIRES_FULL_SIZE =
        bytes4(keccak256("Settler__ExactFillRequiresFullOrderSize(uint256,uint256)"));

    /// @inheritdoc BaseTest
    function setUp() public override {
        super.setUp();
        _approveFiller(type(uint256).max, type(uint256).max);
    }

    /// @notice Build intent + cptHolderSig for a freshly-prepared order.
    /// @param orderData OrderData under test (mutated to set `rolloverIntentHash`).
    /// @return orderDigest EIP-712 order digest.
    /// @return intent RolloverIntent bound to `orderDigest`.
    /// @return cptHolderSig cPT holder signature over `OrderData`.
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

    /// @notice Exact !allowUnderfill: dust fill (fillAmount=1) reverts at admission.
    /// @dev Pashov F-01 dust-fill grief reproduction.
    function testRevert_exactNoUnderfill_dustFill_reverts() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        orderData.allowUnderfill = false;
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(orderData);

        vm.expectRevert(abi.encodeWithSelector(SEL_EXACT_REQUIRES_FULL_SIZE, ORDER, uint256(1)));
        _doRolloverAs(orderDigest, orderData, intent, 1, filler);
    }

    /// @notice Exact !allowUnderfill: full-size fill succeeds.
    function test_exactNoUnderfill_fullSize_succeeds() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        orderData.allowUnderfill = false;
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(orderData);

        _doRolloverAs(orderDigest, orderData, intent, ORDER, filler);
        assertEq(settler.rolloverAccountingOf(orderDigest).dstCstProduced, ORDER);
    }

    /// @notice Exact !allowUnderfill: overfill reverts at the universal BaseSettler gate.
    function testRevert_exactNoUnderfill_overfill_reverts() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        orderData.allowUnderfill = false;
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(orderData);

        vm.expectRevert(abi.encodeWithSelector(SEL_ROLLOVER_AMOUNT_OUT_OF_BOUNDS, ORDER, ORDER + 1));
        _doRolloverAs(orderDigest, orderData, intent, ORDER + 1, filler);
    }

    /// @notice Exact allowUnderfill: half-size fill succeeds (post-exec check is gated).
    function test_exactWithUnderfill_partialAmount_succeeds() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        orderData.allowUnderfill = true;
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(orderData);

        _doRolloverAs(orderDigest, orderData, intent, ORDER / 2, filler);
        // dstProduced equals fillAmount with the mock rolloverContract.
        assertEq(settler.rolloverAccountingOf(orderDigest).dstCstProduced, ORDER / 2);
    }

    /// @notice Exact allowUnderfill: overfill still reverts at admission (rule 1 universal).
    function testRevert_exactWithUnderfill_overfill_reverts() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        orderData.allowUnderfill = true;
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(orderData);

        vm.expectRevert(abi.encodeWithSelector(SEL_ROLLOVER_AMOUNT_OUT_OF_BOUNDS, ORDER, ORDER + 1));
        _doRolloverAs(orderDigest, orderData, intent, ORDER + 1, filler);
    }

    /// @notice Exact allowUnderfill: full-size fill succeeds (regression).
    function test_exactWithUnderfill_fullSize_succeeds() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        orderData.allowUnderfill = true;
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(orderData);

        _doRolloverAs(orderDigest, orderData, intent, ORDER, filler);
        assertEq(settler.rolloverAccountingOf(orderDigest).dstCstProduced, ORDER);
    }

    /// @notice Partial-mode: dust fill (fillAmount=1) succeeds (no per-fill orderSize equality).
    function test_partial_smallFill_succeeds() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData = _usePartialSettler(orderData);
        orderData.orderSize = ORDER;
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(orderData);

        _doRolloverAs(orderDigest, orderData, intent, 1, filler);
        assertEq(
            partialSettler.fillerSlotAccountingOf(
                    orderDigest, filler, bytes32(uint256(uint160(filler)))
                ).rollover.dstCstProduced,
            1
        );
    }

    /// @notice Partial-mode: overfill reverts at the universal BaseSettler admission gate.
    function testRevert_partial_overfill_reverts() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData = _usePartialSettler(orderData);
        orderData.orderSize = ORDER;
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(orderData);

        vm.expectRevert(abi.encodeWithSelector(SEL_ROLLOVER_AMOUNT_OUT_OF_BOUNDS, ORDER, ORDER + 1));
        _doRolloverAs(orderDigest, orderData, intent, ORDER + 1, filler);
    }

    /// @notice Pashov F-01 dust-fill grief reproduction: attacker latches order with dust →
    ///         admission revert; honest filler full-size fill succeeds.
    function test_dustFillGrief_attackerLatchesOrder_neverSucceeds() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        orderData.allowUnderfill = false;
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(orderData);

        // Attacker tries dust-fill (1 wei) → reverts at admission.
        address attacker = address(0xBADBAD);
        srcCst.mint(attacker, 100e18);
        vm.prank(attacker);
        srcCst.approve(address(settler), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(SEL_EXACT_REQUIRES_FULL_SIZE, ORDER, uint256(1)));
        _doRolloverAs(orderDigest, orderData, intent, 1, attacker);

        // Order still fillable; honest filler succeeds with full size.
        _doRolloverAs(orderDigest, orderData, intent, ORDER, filler);
        assertEq(settler.rolloverAccountingOf(orderDigest).filler, filler);
    }

    /// @notice On admission revert, no order-status latch is created.
    function test_exactRecord_notLatched_onAdmissionRevert() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        orderData.allowUnderfill = false;
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(orderData);

        vm.expectRevert(abi.encodeWithSelector(SEL_EXACT_REQUIRES_FULL_SIZE, ORDER, uint256(1)));
        _doRolloverAs(orderDigest, orderData, intent, 1, filler);

        // Storage stays clean.
        assertEq(uint8(settler.orderStatus(orderDigest)), uint8(RolloverTypes.OrderStatus.None));
        assertEq(settler.rolloverAccountingOf(orderDigest).dstCstProduced, 0);
    }
}
