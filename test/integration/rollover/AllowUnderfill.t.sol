// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { UnderfillingRolloverModule } from "../../mocks/modules/UnderfillingRolloverModule.sol";
import { BaseSettler } from "src/BaseSettler.sol";
import { CorkRolloverContract } from "src/CorkRolloverContract.sol";
import { ExactSettler as Settler } from "src/ExactSettler.sol";
import {
    CorkRolloverContract__RolloverZeroUnwindMint,
    CorkRolloverContract__SrcCptShortfall
} from "src/errors/CorkRolloverContractErrors.sol";
import { IRolloverContractLens } from "src/interfaces/rollover/IRolloverContractLens.sol";
import { ISettler } from "src/interfaces/settlers/ISettler.sol";
import { Typehashes } from "src/libraries/Typehashes.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice allowUnderfill rollover path — refunds residual dstCST without reverting on shortfall.
contract AllowUnderfillTest is BaseTest {
    /// @notice Underfill module.
    UnderfillingRolloverModule internal underfillModule;

    /// @notice Filler2.
    address internal filler2 = address(0xF2);

    /// @notice Order_size.
    uint256 internal constant ORDER_SIZE = 1_000e18;

    /// @notice Src cst refunded.
    /// @param orderDigest orderDigest.
    /// @param filler filler.
    /// @param subFiller subFiller.
    /// @param reportedSrcLeftover reportedSrcLeftover.
    event SrcCstRefunded(
        bytes32 indexed orderDigest,
        address indexed filler,
        bytes32 indexed subFiller,
        uint256 reportedSrcLeftover
    );

    /// @inheritdoc BaseTest
    function setUp() public override {
        super.setUp();
        underfillModule = new UnderfillingRolloverModule();
        erc7484.setAttestedType(address(underfillModule), Typehashes.MODULE_TYPE_PRE_ROLLOVER_HOOK);
        srcCst.mint(filler2, 1_000_000e18);
        dstCst.mint(filler2, 1_000_000e18);
        premiumToken.mint(filler2, 1_000_000e18);
        vm.label(filler2, "filler2");
        vm.label(address(underfillModule), "underfillModule");

        // Atomic-fill: every fill pulls premium in-frame, so both fillers must
        // approve premiumToken to both settlers.
        vm.startPrank(filler);
        srcCst.approve(address(settler), type(uint256).max);
        srcCst.approve(address(partialSettler), type(uint256).max);
        premiumToken.approve(address(settler), type(uint256).max);
        premiumToken.approve(address(partialSettler), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(filler2);
        srcCst.approve(address(settler), type(uint256).max);
        srcCst.approve(address(partialSettler), type(uint256).max);
        premiumToken.approve(address(settler), type(uint256).max);
        premiumToken.approve(address(partialSettler), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice _order with.
    function _orderWith(bool allowPartialFills, bool allowUnderfill)
        internal
        view
        returns (RolloverTypes.OrderData memory orderData)
    {
        orderData = _baseOrder();
        orderData.allowPartialFills = allowPartialFills;
        if (allowPartialFills) {
            orderData = _usePartialSettler(orderData);
        }
        orderData.allowUnderfill = allowUnderfill;
        orderData.orderSize = ORDER_SIZE;
    }

    /// @notice _intent for.
    function _intentFor(bytes32 orderDigest, uint256, uint256 dstMint)
        internal
        view
        returns (RolloverTypes.RolloverIntent memory)
    {
        RolloverTypes.Call[] memory preHooks = new RolloverTypes.Call[](1);
        preHooks[0] = _hook(
            address(sourceSrcCptModule),
            abi.encodeWithSignature("execute(address,uint256)", address(srcCpt), dstMint)
        );
        RolloverTypes.Call[] memory postHooks = new RolloverTypes.Call[](1);
        postHooks[0] = _hook(
            address(consumeDstCptModule),
            abi.encodeWithSignature("execute(address)", address(dstCpt))
        );
        return _intentWithHooks(
            rolloverContract, orderDigest, preHooks, new RolloverTypes.Call[](0), postHooks
        );
    }

    /// @notice _open with hash.
    function _openWithHash(
        RolloverTypes.OrderData memory orderData,
        uint256 srcRefund,
        uint256 dstMint
    )
        internal
        returns (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        )
    {
        bytes32 dummyDigest = bytes32(0);
        RolloverTypes.RolloverIntent memory probe = _intentFor(dummyDigest, srcRefund, dstMint);
        orderData.rolloverIntentHash = _zeroDigestHash(probe);
        orderDigest = _openOrder(orderData);
        intent = _intentFor(orderDigest, srcRefund, dstMint);
        cptHolderSig = _signOrder(cptHolderPk, orderData);
    }

    /// @notice _do rollover.
    function _doRollover(
        bytes32 orderDigest,
        RolloverTypes.OrderData memory orderData,
        RolloverTypes.RolloverIntent memory intent,
        bytes memory cptHolderSig,
        uint256 fillAmount,
        address fillerAddr
    ) internal {
        bytes memory originData = _originData(orderData);
        bytes memory cptHolderOrderSig = _signOrder(cptHolderPk, orderData);
        bytes memory rolloverLeg = abi.encode(
            uint8(RolloverTypes.HookPhase.ROLLOVER),
            fillAmount,
            uint256(0),
            fillerAddr,
            address(0),
            intent,
            cptHolderSig,
            uint256(0),
            "",
            bytes32(0),
            ""
        );
        bytes memory fillerData =
            abi.encode(uint8(255), rolloverLeg, uint256(1_000_000e18), cptHolderOrderSig);
        vm.prank(fillerAddr);
        ISettler(orderData.settler).fill(orderDigest, originData, fillerData);
    }

    /// @notice cell exact fill no underfill consumes fully.
    function test_cell_exactFill_noUnderfill_consumesFully() public {
        RolloverTypes.OrderData memory orderData = _orderWith(false, false);
        uint256 dstMint = ORDER_SIZE;
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _openWithHash(orderData, 0, dstMint);

        uint256 fillerSrcBefore = srcCst.balanceOf(filler);
        // INV-ATOMIC-FILL-CANONICAL: dstCST forwarded to filler in same frame.
        uint256 fillerDstBefore = dstCst.balanceOf(filler);

        _doRollover(orderDigest, orderData, intent, cptHolderSig, ORDER_SIZE, filler);

        assertEq(fillerSrcBefore - srcCst.balanceOf(filler), ORDER_SIZE, "F-1 exact full");

        assertEq(dstCst.balanceOf(filler) - fillerDstBefore, dstMint, "F-2 exact full");

        assertEq(
            IRolloverContractLens(address(factory))
            .orderState(rolloverContract, orderDigest)
            .rolled,
            ORDER_SIZE,
            "F-3/F-8 rolled"
        );

        assertLe(
            IRolloverContractLens(address(factory))
            .orderState(rolloverContract, orderDigest)
            .rolled,
            orderData.orderSize,
            "F-6 monotonic"
        );

        assertTrue(
            IRolloverContractLens(address(factory))
            .orderState(rolloverContract, orderDigest)
            .rolloverTerminal,
            "F-7 terminal"
        );
    }

    /// @notice cell exact fill no underfill reverts on underspend.
    function test_cell_exactFill_noUnderfill_revertsOnUnderspend() public {
        RolloverTypes.OrderData memory orderData = _orderWith(false, false);

        uint256 srcRefund = 100e18;
        uint256 dstMint = ORDER_SIZE - srcRefund;
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _openWithHash(orderData, srcRefund, dstMint);

        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContract__SrcCptShortfall.selector, ORDER_SIZE, ORDER_SIZE - srcRefund
            )
        );
        _doRollover(orderDigest, orderData, intent, cptHolderSig, ORDER_SIZE, filler);
    }

    /// @notice cell exact fill with underfill refunds leftover and terminal.
    function test_cell_exactFill_withUnderfill_refundsLeftover_andTerminal() public {
        RolloverTypes.OrderData memory orderData = _orderWith(false, true);
        uint256 srcRefund = 250e18;
        uint256 dstMint = ORDER_SIZE - srcRefund;
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _openWithHash(orderData, srcRefund, dstMint);

        uint256 fillerSrcBefore = srcCst.balanceOf(filler);
        // INV-ATOMIC-FILL-CANONICAL: dstCST forwarded to filler in same frame.
        uint256 fillerDstBefore = dstCst.balanceOf(filler);

        vm.expectEmit(true, true, false, true, address(settler));
        emit SrcCstRefunded(orderDigest, filler, bytes32(uint256(uint160(filler))), srcRefund);
        _doRollover(orderDigest, orderData, intent, cptHolderSig, ORDER_SIZE, filler);

        assertEq(
            fillerSrcBefore - srcCst.balanceOf(filler), ORDER_SIZE - srcRefund, "F-1 underfill"
        );

        assertEq(dstCst.balanceOf(filler) - fillerDstBefore, dstMint, "F-2 underfill");

        assertLe(
            IRolloverContractLens(address(factory))
            .orderState(rolloverContract, orderDigest)
            .rolled,
            ORDER_SIZE,
            "F-3 underfill"
        );

        assertEq(
            IRolloverContractLens(address(factory))
            .orderState(rolloverContract, orderDigest)
            .rolled,
            ORDER_SIZE - srcRefund,
            "F-8 actualRolled"
        );

        assertTrue(
            IRolloverContractLens(address(factory))
            .orderState(rolloverContract, orderDigest)
            .rolloverTerminal,
            "F-10 !partial terminal"
        );
    }

    /// @notice cell exact fill with underfill second fill reverts as terminal.
    function test_cell_exactFill_withUnderfill_secondFillRevertsAsTerminal() public {
        RolloverTypes.OrderData memory orderData = _orderWith(false, true);
        uint256 srcRefund = 250e18;
        uint256 dstMint = ORDER_SIZE - srcRefund;
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _openWithHash(orderData, srcRefund, dstMint);

        _doRollover(orderDigest, orderData, intent, cptHolderSig, ORDER_SIZE, filler);

        vm.expectRevert();
        _doRollover(orderDigest, orderData, intent, cptHolderSig, ORDER_SIZE, filler);
    }

    /// @notice Two half fills from distinct fillers complete aggregate src consumption.
    function test_cell_partial_noUnderfill_cumulativeFullFills() public {
        RolloverTypes.OrderData memory orderData = _orderWith(true, false);
        uint256 chunk = ORDER_SIZE / 2;

        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _openWithHash(orderData, 0, chunk);

        _doRollover(orderDigest, orderData, intent, cptHolderSig, chunk, filler);
        assertEq(
            IRolloverContractLens(address(factory))
            .orderState(rolloverContract, orderDigest)
            .rolled,
            chunk,
            "F-8 partial+exact #1"
        );

        _doRollover(orderDigest, orderData, intent, cptHolderSig, chunk, filler2);
        assertEq(
            IRolloverContractLens(address(factory))
            .orderState(rolloverContract, orderDigest)
            .rolled,
            ORDER_SIZE,
            "F-8 partial cumulative reaches orderSize"
        );
        assertEq(
            uint8(partialSettler.orderStatus(orderDigest)),
            uint8(RolloverTypes.OrderStatus.Settled),
            "partial settles once aggregate consumed reaches orderSize and escrow is zero"
        );
    }

    /// @notice cell partial no underfill reverts on underspend.
    function test_cell_partial_noUnderfill_revertsOnUnderspend() public {
        RolloverTypes.OrderData memory orderData = _orderWith(true, false);
        uint256 chunk = ORDER_SIZE / 2;
        uint256 srcRefund = 50e18;
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _openWithHash(orderData, srcRefund, chunk - srcRefund);

        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContract__SrcCptShortfall.selector, chunk, chunk - srcRefund
            )
        );
        _doRollover(orderDigest, orderData, intent, cptHolderSig, chunk, filler);
    }

    /// @notice cell partial with underfill per-fill refund and cumulative second filler.
    function test_cell_partial_withUnderfill_perFillRefund_cumulativeOnActualRolled() public {
        RolloverTypes.OrderData memory orderData = _orderWith(true, true);
        uint256 chunk = ORDER_SIZE / 2;
        uint256 srcRefund = 100e18;
        uint256 dstMint = chunk - srcRefund;

        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _openWithHash(orderData, srcRefund, dstMint);

        uint256 f1SrcBefore = srcCst.balanceOf(filler);
        _doRollover(orderDigest, orderData, intent, cptHolderSig, chunk, filler);
        assertEq(f1SrcBefore - srcCst.balanceOf(filler), chunk - srcRefund, "F-1 #1");

        assertEq(
            IRolloverContractLens(address(factory))
            .orderState(rolloverContract, orderDigest)
            .rolled,
            chunk - srcRefund,
            "F-8 #1"
        );

        uint256 f2SrcBefore = srcCst.balanceOf(filler2);
        _doRollover(orderDigest, orderData, intent, cptHolderSig, chunk, filler2);
        assertEq(f2SrcBefore - srcCst.balanceOf(filler2), chunk - srcRefund, "F-1 #2");

        assertEq(
            IRolloverContractLens(address(factory))
            .orderState(rolloverContract, orderDigest)
            .rolled,
            2 * (chunk - srcRefund),
            "F-8 cumulative on actual rolled"
        );
    }

    /// @notice partial underfill drains escrow but remains open below aggregate orderSize.
    /// @notice Under atomic-fill the dstCST escrow is drained in-frame within the
    ///         Settler.fill() call — there is no separate settle step. The
    ///         post-rollover assertions confirm underfill is per-leg, not partial
    ///         order-level finality below `orderSize`.
    function test_partialUnderfillBelowOrderSizeDrainsEscrowButRemainsOpened() public {
        RolloverTypes.OrderData memory orderData = _orderWith(true, true);
        uint256 chunk = ORDER_SIZE;
        uint256 srcRefund = 200e18;
        uint256 dstMint = chunk - srcRefund;

        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _openWithHash(orderData, srcRefund, dstMint);

        _doRollover(orderDigest, orderData, intent, cptHolderSig, chunk, filler);

        assertEq(
            partialSettler.rolloverAccountingOf(orderDigest).dstCstEscrowed,
            0,
            "F-11 escrow drained"
        );
        assertEq(
            partialSettler.rolloverAccountingOf(orderDigest).srcCstConsumed,
            ORDER_SIZE - srcRefund,
            "aggregate consumed tracks actual underfilled leg"
        );
        assertEq(
            uint8(partialSettler.orderStatus(orderDigest)),
            uint8(RolloverTypes.OrderStatus.Opened),
            "partial underfill below orderSize remains open"
        );
    }

    /// @notice zero dst mint reverts at rolloverContract boundary.
    function test_zeroDstMintRevertsAtRolloverContractBoundary() public {
        RolloverTypes.OrderData memory orderData = _orderWith(false, true);

        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _openWithHash(orderData, ORDER_SIZE, 0);

        vm.expectRevert(CorkRolloverContract__RolloverZeroUnwindMint.selector);
        _doRollover(orderDigest, orderData, intent, cptHolderSig, ORDER_SIZE, filler);
    }

    /// @notice consumed src cst not refunded after deadline.
    function test_consumedSrcCstNotRefundedAfterDeadline() public {
        RolloverTypes.OrderData memory orderData = _orderWith(false, true);
        uint256 srcRefund = 100e18;
        uint256 dstMint = ORDER_SIZE - srcRefund;
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _openWithHash(orderData, srcRefund, dstMint);

        uint256 fillerSrcBefore = srcCst.balanceOf(filler);
        _doRollover(orderDigest, orderData, intent, cptHolderSig, ORDER_SIZE, filler);

        uint256 paid = fillerSrcBefore - srcCst.balanceOf(filler);
        assertEq(paid, ORDER_SIZE - srcRefund, "filler paid actualRolled");

        vm.warp(orderData.fillDeadline + 8 days);

        assertEq(
            srcCst.balanceOf(filler), fillerSrcBefore - paid, "F-9 consumed src non-refundable"
        );
    }

    /// @notice over refund clamps actual rolled to src cpt delta.
    function test_overRefundClampsActualRolledToSrcCptDelta() public {
        RolloverTypes.OrderData memory orderData = _orderWith(false, true);

        uint256 dstMint = 1;
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _openWithHash(orderData, 0, dstMint);

        _doRollover(orderDigest, orderData, intent, cptHolderSig, ORDER_SIZE, filler);

        assertEq(
            IRolloverContractLens(address(factory))
            .orderState(rolloverContract, orderDigest)
            .rolled,
            dstMint,
            "F-3 actualRolled bound"
        );
    }
}
