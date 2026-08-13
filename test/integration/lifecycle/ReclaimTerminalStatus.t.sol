// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { FillScaffold } from "../../base/FillScaffold.sol";
import { Vm } from "forge-std/Vm.sol";
import { BaseSettler } from "src/BaseSettler.sol";
import {
    Settler__AsyncPremiumOptInRequired,
    Settler__FillAfterDeadline,
    Settler__OrderNotCancellable,
    Settler__OrderNotReclaimable
} from "src/errors/SettlerErrors.sol";
import { IPartialSettler } from "src/interfaces/settlers/IPartialSettler.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice `Settler.reclaim` defaulter-recoup terminal-status behavior.
///
/// @dev Atomic fills settle in one frame and therefore cannot leave unpaid dstCST residual.
///      cPT-holder-opt-in async premium can leave rollover-only residual until premium fires or
///      reclaim returns the residual to `orderData.rolloverContract` after `fillDeadline`. These tests
///      pin the terminal-state gate and status/event behavior for that cleanup path.
///
/// @custom:invariant INV-FSM-TERMINAL-WRITE-COMPLETE
contract ReclaimTerminalStatusTest is FillScaffold {
    /// @notice Defaulter A.
    address internal defaulterA = address(0xE1);
    /// @notice Defaulter B.
    address internal defaulterB = address(0xE2);
    /// @notice Keeper (permissionless reclaim caller).
    address internal keeper = address(0xCAFE);

    /// @notice Order size for partial-mode fixtures.
    uint256 internal constant ORDER_SIZE = 1_000e18;
    /// @notice Per-fill chunk for partial-mode fixtures.
    uint256 internal constant CHUNK_HALF = 500e18;

    /// @notice Defaulter residual reclaimed.
    /// @param orderId orderId.
    /// @param defaulterFiller defaulterFiller.
    /// @param recipientRolloverContract recipientRolloverContract.
    /// @param amount amount.
    event DefaulterResidualReclaimed(
        bytes32 indexed orderId,
        address indexed defaulterFiller,
        address indexed recipientRolloverContract,
        uint256 amount
    );

    /// @notice Order expired.
    /// @param orderId orderId.
    event OrderExpired(bytes32 indexed orderId);

    /// @notice Order cancelled.
    /// @param orderId orderId.
    event OrderCancelled(bytes32 indexed orderId);

    /// @inheritdoc BaseTest
    function setUp() public override {
        super.setUp();
        address[3] memory parties = [defaulterA, defaulterB, filler];
        for (uint256 i; i < parties.length; ++i) {
            srcCst.mint(parties[i], 1_000_000e18);
            dstCst.mint(parties[i], 1_000_000e18);
            premiumToken.mint(parties[i], 1_000_000e18);
            vm.startPrank(parties[i]);
            srcCst.approve(address(settler), type(uint256).max);
            srcCst.approve(address(partialSettler), type(uint256).max);
            premiumToken.approve(address(settler), type(uint256).max);
            premiumToken.approve(address(partialSettler), type(uint256).max);
            vm.stopPrank();
        }
        vm.label(defaulterA, "defaulterA");
        vm.label(defaulterB, "defaulterB");
        vm.label(keeper, "keeper");
    }

    /// @dev Build an exact-mode order with the given salt.
    function _orderExact(uint256 nonce)
        internal
        view
        returns (RolloverTypes.OrderData memory orderData)
    {
        orderData = _baseOrder();
        orderData.allowPartialFills = false;
        orderData.orderSize = ORDER_SIZE;
        // forge-lint: disable-next-line(unsafe-typecast)
        orderData.orderSalt = uint64(nonce);
    }

    /// @dev Build a partial-mode order with the given salt.
    function _orderPartial(uint256 nonce)
        internal
        view
        returns (RolloverTypes.OrderData memory orderData)
    {
        orderData = _baseOrder();
        orderData = _usePartialSettler(orderData);
        orderData.orderSize = ORDER_SIZE;
        // forge-lint: disable-next-line(unsafe-typecast)
        orderData.orderSalt = uint64(nonce);
    }

    /// @dev Open with a pre-baked intent fixture for the given dst-mint.
    function _openWithDeposit(RolloverTypes.OrderData memory orderData, uint256 dstMint)
        internal
        returns (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        )
    {
        RolloverTypes.RolloverIntent memory probe = _buildIntent(bytes32(0), ORDER_SIZE, dstMint);
        orderData.rolloverIntentHash = _zeroDigestHash(probe);
        orderDigest = _openOrder(orderData);
        intent = _buildIntent(orderDigest, ORDER_SIZE, dstMint);
        cptHolderSig = _signOrder(cptHolderPk, orderData);
    }

    /// @dev Build an order, open it, and prepare an async rollover intent/signature.
    function _openAsyncOrder(RolloverTypes.OrderData memory orderData, uint256 fillAmount)
        internal
        returns (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        )
    {
        orderData.premiumPaymentMode = RolloverTypes.PREMIUM_PAYMENT_MODE_ATOMIC_OR_SEPARATE;
        return _openWithDeposit(orderData, fillAmount);
    }

    /// @dev Async ROLLOVER fill data for separate premium mode.
    function _asyncRolloverData(
        uint256 fillAmount,
        address destination,
        bytes32 subFiller,
        RolloverTypes.RolloverIntent memory intent,
        bytes memory cptHolderSig
    ) internal pure returns (bytes memory) {
        return abi.encode(
            uint8(RolloverTypes.HookPhase.ROLLOVER),
            fillAmount,
            uint256(0),
            destination,
            address(0),
            intent,
            uint256(0),
            bytes(""),
            subFiller,
            cptHolderSig
        );
    }

    /// @dev Async PREMIUM fill data for separate premium mode.
    function _asyncPremiumData(
        address destination,
        address premiumFor,
        bytes32 subFiller,
        RolloverTypes.RolloverIntent memory intent,
        bytes memory cptHolderSig
    ) internal pure returns (bytes memory) {
        return abi.encode(
            uint8(RolloverTypes.HookPhase.PREMIUM),
            uint256(0),
            DEFAULT_PREMIUM_CAP,
            destination,
            premiumFor,
            intent,
            uint256(0),
            bytes(""),
            subFiller,
            cptHolderSig
        );
    }

    /// @dev Execute an async ROLLOVER leg.
    function _fillAsyncRollover(
        RolloverTypes.OrderData memory orderData,
        bytes32 orderDigest,
        address defaulter,
        bytes32 subFiller,
        RolloverTypes.RolloverIntent memory intent,
        bytes memory cptHolderSig
    ) internal {
        vm.prank(defaulter);
        _settlerFor(orderData)
            .fill(
                orderDigest,
                _originData(orderData),
                _asyncRolloverData(CHUNK_HALF, defaulter, subFiller, intent, cptHolderSig)
            );
    }

    /// @dev Execute an async PREMIUM leg.
    function _fillAsyncPremium(
        RolloverTypes.OrderData memory orderData,
        bytes32 orderDigest,
        address premiumFor,
        bytes32 subFiller,
        RolloverTypes.RolloverIntent memory intent
    ) internal {
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);
        vm.prank(premiumFor);
        _settlerFor(orderData)
            .fill(
                orderDigest,
                _originData(orderData),
                _asyncPremiumData(premiumFor, premiumFor, subFiller, intent, cptHolderSig)
            );
    }

    /// @dev Resolve the mode-specific settler interface from order data.
    function _settlerFor(RolloverTypes.OrderData memory orderData)
        internal
        pure
        returns (BaseSettler)
    {
        return BaseSettler(orderData.settler);
    }

    /// @dev Cancel a partial order as the cPT holder.
    function _cancelPartial(RolloverTypes.OrderData memory orderData, bytes32 orderDigest)
        internal
    {
        bytes memory cancelSig = _signCancelFor(
            address(partialSettler), cptHolderPk, orderDigest, orderData.orderSalt
        );
        vm.prank(orderData.user);
        partialSettler.cancel(orderDigest, _originData(orderData), cancelSig);
    }

    /// @dev Returns whether any recorded log carries the given topic0.
    function _logEmitted(Vm.Log[] memory logs, bytes32 topic0) internal pure returns (bool) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == topic0) {
                return true;
            }
        }
        return false;
    }

    /// @notice topic0 for `OrderExpired(bytes32)`.
    bytes32 internal constant ORDER_EXPIRED_TOPIC = keccak256("OrderExpired(bytes32)");
    /// @notice topic0 for `OrderCancelled(bytes32)`.
    bytes32 internal constant ORDER_CANCELLED_TOPIC = keccak256("OrderCancelled(bytes32)");

    /// @notice Under atomic-fill, an exact-mode atomic fill auto-settles the order in one
    ///         frame: post-fill status is `Settled` and premium is fired. The legacy defaulter-
    ///         recoup `reclaim()` path is now blocked at the terminal-state admissibility
    ///         gate (`Settler__OrderNotReclaimable`) because `Settled` is not in the reclaim-
    ///         admissible status set {Expired, Closing, Opened, None}.
    /// @custom:invariant INV-FSM-TERMINAL-WRITE-COMPLETE
    function test_reclaim_exactAtomicSettledOrder_revertsOrderNotReclaimable() public {
        RolloverTypes.OrderData memory orderData = _orderExact(1);
        (bytes32 orderDigest, RolloverTypes.RolloverIntent memory intent,) =
            _openWithDeposit(orderData, ORDER_SIZE);
        _doRolloverAs(orderDigest, orderData, intent, ORDER_SIZE, defaulterA);

        assertEq(
            uint8(settler.orderStatus(orderDigest)),
            uint8(RolloverTypes.OrderStatus.Settled),
            "pre-reclaim: Settled (atomic auto-settle)"
        );

        vm.warp(uint256(orderData.fillDeadline) + 1);
        bytes memory originData = _originData(orderData);

        vm.expectRevert(Settler__OrderNotReclaimable.selector);
        vm.prank(keeper);
        settler.reclaim(orderDigest, defaulterA, bytes32(uint256(uint160(defaulterA))), originData);

        assertEq(
            uint8(settler.orderStatus(orderDigest)),
            uint8(RolloverTypes.OrderStatus.Settled),
            "status remains Settled - reclaim blocked"
        );
    }

    /// @notice Under atomic-fill, a partial-mode atomic fill auto-settles only its slot.
    ///         The order remains `Opened` until aggregate consumed size reaches orderSize,
    ///         but `premiumPaymentMode = 0` still cannot enter the async reclaim surface.
    /// @custom:invariant INV-FSM-TERMINAL-WRITE-COMPLETE
    function test_reclaim_partialAtomicModeOpenedOrder_revertsAsyncPremiumOptInRequired() public {
        RolloverTypes.OrderData memory orderData = _orderPartial(2);
        (bytes32 orderDigest, RolloverTypes.RolloverIntent memory intent,) =
            _openWithDeposit(orderData, CHUNK_HALF);
        _doRolloverAs(orderDigest, orderData, intent, CHUNK_HALF, defaulterA);

        assertEq(
            uint8(partialSettler.orderStatus(orderDigest)),
            uint8(RolloverTypes.OrderStatus.Opened),
            "pre-reclaim: Opened (partial aggregate incomplete)"
        );

        vm.warp(uint256(orderData.fillDeadline) + 1);
        bytes memory originData = _originData(orderData);

        vm.expectRevert(Settler__AsyncPremiumOptInRequired.selector);
        partialSettler.reclaim(
            orderDigest, defaulterA, bytes32(uint256(uint160(defaulterA))), originData
        );

        assertEq(
            uint8(partialSettler.orderStatus(orderDigest)),
            uint8(RolloverTypes.OrderStatus.Opened),
            "status stays Opened - mode 0 reclaim blocked"
        );
    }

    /// @notice Already-Expired async reclaim drains residual without re-emitting `OrderExpired`.
    /// @custom:invariant INV-FSM-TERMINAL-WRITE-COMPLETE
    function test_reclaim_alreadyExpired_doesNotReemit() public {
        RolloverTypes.OrderData memory orderData = _orderPartial(3);
        orderData.premiumPaymentMode = RolloverTypes.PREMIUM_PAYMENT_MODE_ATOMIC_OR_SEPARATE;
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _openAsyncOrder(orderData, CHUNK_HALF);
        bytes32 subFiller = _subFillerKey(defaulterA);
        _fillAsyncRollover(orderData, orderDigest, defaulterA, subFiller, intent, cptHolderSig);

        bytes memory originData = _originData(orderData);
        vm.warp(uint256(orderData.fillDeadline) + 1);

        partialSettler.markExpired(orderDigest, originData);

        assertEq(
            uint8(partialSettler.orderStatus(orderDigest)),
            uint8(RolloverTypes.OrderStatus.Expired),
            "status becomes Expired"
        );

        vm.recordLogs();
        vm.prank(keeper);
        partialSettler.reclaim(orderDigest, defaulterA, subFiller, originData);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            uint8(partialSettler.orderStatus(orderDigest)),
            uint8(RolloverTypes.OrderStatus.Expired),
            "status remains Expired"
        );
        assertFalse(_logEmitted(logs, ORDER_EXPIRED_TOPIC), "OrderExpired must not re-emit");
    }

    /// @notice Direct-fill exact-mode under atomic-fill: the admit step transitions
    ///         `None → Opened` and the atomic frame's settle step then promotes to
    ///         `Settled`, so the post-fill status is `Settled`. `reclaim()` is blocked at
    ///         the reclaim-admissibility gate. The legacy "None → Expired" direct-fill
    ///         defaulter-recoup path that F-15 hardened is unreachable; the F-15 src logic
    ///         remains as defence-in-depth.
    /// @custom:invariant INV-FSM-TERMINAL-WRITE-COMPLETE
    function test_reclaim_directFillExactAtomicSettledOrder_revertsOrderNotReclaimable() public {
        RolloverTypes.OrderData memory orderData = _orderExact(4);
        // Build the intent WITHOUT calling `_openOrder` — direct-fill path.
        RolloverTypes.RolloverIntent memory probe = _buildIntent(bytes32(0), ORDER_SIZE, ORDER_SIZE);
        orderData.rolloverIntentHash = _zeroDigestHash(probe);
        bytes32 orderDigest = _orderDigest(orderData);
        RolloverTypes.RolloverIntent memory intent =
            _buildIntent(orderDigest, ORDER_SIZE, ORDER_SIZE);
        // Direct fill — atomic frame admits and auto-settles in one tx.
        _doRolloverAs(orderDigest, orderData, intent, ORDER_SIZE, defaulterA);

        assertEq(
            uint8(settler.orderStatus(orderDigest)),
            uint8(RolloverTypes.OrderStatus.Settled),
            "pre-reclaim: Settled (atomic auto-settle on direct fill)"
        );

        vm.warp(uint256(orderData.fillDeadline) + 1);
        bytes memory originData = _originData(orderData);

        vm.expectRevert(Settler__OrderNotReclaimable.selector);
        vm.prank(keeper);
        settler.reclaim(orderDigest, defaulterA, bytes32(uint256(uint160(defaulterA))), originData);

        assertEq(
            uint8(settler.orderStatus(orderDigest)),
            uint8(RolloverTypes.OrderStatus.Settled),
            "status stays Settled - reclaim blocked"
        );
    }

    /// @notice #135 regression: exact-mode reclaim of an unpaid async rollover residual still
    ///         finalizes the order as `Expired` and emits `OrderExpired` — the mode-aware reclaim
    ///         terminalization must not alter exact behavior.
    /// @custom:invariant INV-FSM-TERMINAL-WRITE-COMPLETE
    function test_reclaim_exactUnpaidAsyncResidual_finalizesExpired() public {
        RolloverTypes.OrderData memory orderData = _orderExact(5);
        orderData.premiumPaymentMode = RolloverTypes.PREMIUM_PAYMENT_MODE_ATOMIC_OR_SEPARATE;
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _openWithDeposit(orderData, ORDER_SIZE);

        bytes memory rolloverFillData = abi.encode(
            uint8(RolloverTypes.HookPhase.ROLLOVER),
            ORDER_SIZE,
            uint256(0),
            defaulterA,
            address(0),
            intent,
            uint256(0),
            bytes(""),
            bytes32(0),
            cptHolderSig
        );
        vm.prank(defaulterA);
        settler.fill(orderDigest, _originData(orderData), rolloverFillData);

        assertEq(
            uint8(settler.orderStatus(orderDigest)),
            uint8(RolloverTypes.OrderStatus.Opened),
            "async rollover-only leaves order Opened"
        );

        vm.warp(uint256(orderData.fillDeadline) + 1);
        vm.expectEmit(true, false, false, false, address(settler));
        emit OrderExpired(orderDigest);
        vm.prank(keeper);
        settler.reclaim(
            orderDigest, defaulterA, bytes32(uint256(uint160(defaulterA))), _originData(orderData)
        );

        assertEq(
            uint8(settler.orderStatus(orderDigest)),
            uint8(RolloverTypes.OrderStatus.Expired),
            "exact unpaid reclaim finalizes Expired"
        );
        assertEq(
            dstCst.balanceOf(orderData.rolloverContract),
            ORDER_SIZE,
            "unpaid exact residual returned to rollover contract"
        );
    }

    /// @notice cPT-holder cancel moves a partial order with live escrow into Closing.
    function test_partialCancel_withLiveEscrow_entersClosing() public {
        RolloverTypes.OrderData memory orderData = _orderPartial(6);
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _openAsyncOrder(orderData, CHUNK_HALF);

        bytes32 subFiller = _subFillerKey(defaulterA);
        _fillAsyncRollover(orderData, orderDigest, defaulterA, subFiller, intent, cptHolderSig);

        assertEq(
            IPartialSettler(orderData.settler).rolloverAccountingOf(orderDigest).dstCstEscrowed,
            CHUNK_HALF
        );

        _cancelPartial(orderData, orderDigest);

        assertEq(
            uint8(partialSettler.orderStatus(orderDigest)), uint8(RolloverTypes.OrderStatus.Closing)
        );

        vm.expectRevert(Settler__OrderNotCancellable.selector);
        _cancelPartial(orderData, orderDigest);
    }

    /// @notice Paid drain of the final Closing partial residual terminalizes as Cancelled.
    /// @custom:invariant INV-FSM-TERMINAL-WRITE-COMPLETE
    function test_partialCancel_finalPaidResidualDrain_terminalizesCancelled() public {
        RolloverTypes.OrderData memory orderData = _orderPartial(7);
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _openAsyncOrder(orderData, CHUNK_HALF);

        bytes32 subFiller = _subFillerKey(defaulterA);
        _fillAsyncRollover(orderData, orderDigest, defaulterA, subFiller, intent, cptHolderSig);
        _cancelPartial(orderData, orderDigest);

        _fillAsyncPremium(orderData, orderDigest, defaulterA, subFiller, intent);

        assertEq(
            IPartialSettler(orderData.settler).rolloverAccountingOf(orderDigest).dstCstEscrowed,
            0,
            "final paid residual drained"
        );
        assertEq(
            uint8(partialSettler.orderStatus(orderDigest)),
            uint8(RolloverTypes.OrderStatus.Cancelled),
            "drained underfilled Closing order becomes Cancelled"
        );
    }

    /// @notice #135: final unpaid residual reclaim of a Closing partial order emits Cancelled only.
    /// @custom:invariant INV-FSM-TERMINAL-WRITE-COMPLETE
    function test_partialCancel_finalUnpaidResidualReclaim_terminalizesCancelled() public {
        RolloverTypes.OrderData memory orderData = _orderPartial(8);
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _openAsyncOrder(orderData, CHUNK_HALF);

        bytes32 subFiller = _subFillerKey(defaulterA);
        _fillAsyncRollover(orderData, orderDigest, defaulterA, subFiller, intent, cptHolderSig);
        _cancelPartial(orderData, orderDigest);

        vm.warp(orderData.fillDeadline + 1);
        vm.recordLogs();
        vm.prank(keeper);
        partialSettler.reclaim(orderDigest, defaulterA, subFiller, _originData(orderData));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            IPartialSettler(orderData.settler).rolloverAccountingOf(orderDigest).dstCstEscrowed,
            0,
            "final unpaid residual drained"
        );
        assertEq(
            dstCst.balanceOf(orderData.rolloverContract),
            CHUNK_HALF,
            "unpaid residual returned to rollover contract"
        );
        assertEq(
            uint8(partialSettler.orderStatus(orderDigest)),
            uint8(RolloverTypes.OrderStatus.Cancelled),
            "reclaimed final Closing residual becomes Cancelled"
        );
        assertTrue(_logEmitted(logs, ORDER_CANCELLED_TOPIC), "OrderCancelled emitted");
        assertFalse(_logEmitted(logs, ORDER_EXPIRED_TOPIC), "OrderExpired must not be emitted");
    }

    /// @notice #135: non-final unpaid reclaim keeps Closing and emits no terminal event.
    /// @custom:invariant INV-FSM-TERMINAL-WRITE-COMPLETE
    function test_partialCancel_nonFinalResidualReclaim_staysClosing() public {
        RolloverTypes.OrderData memory orderData = _orderPartial(9);
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _openAsyncOrder(orderData, CHUNK_HALF);

        bytes32 subA = _subFillerKey(defaulterA);
        bytes32 subB = _subFillerKey(defaulterB);
        _fillAsyncRollover(orderData, orderDigest, defaulterA, subA, intent, cptHolderSig);
        _fillAsyncRollover(orderData, orderDigest, defaulterB, subB, intent, cptHolderSig);
        _cancelPartial(orderData, orderDigest);

        vm.warp(orderData.fillDeadline + 1);
        vm.recordLogs();
        vm.prank(keeper);
        partialSettler.reclaim(orderDigest, defaulterA, subA, _originData(orderData));
        Vm.Log[] memory firstLogs = vm.getRecordedLogs();

        assertEq(
            uint8(partialSettler.orderStatus(orderDigest)),
            uint8(RolloverTypes.OrderStatus.Closing),
            "non-final reclaim keeps Closing"
        );
        assertFalse(_logEmitted(firstLogs, ORDER_EXPIRED_TOPIC), "no OrderExpired on non-final");
        assertFalse(_logEmitted(firstLogs, ORDER_CANCELLED_TOPIC), "no OrderCancelled on non-final");

        vm.recordLogs();
        vm.prank(keeper);
        partialSettler.reclaim(orderDigest, defaulterB, subB, _originData(orderData));
        Vm.Log[] memory secondLogs = vm.getRecordedLogs();

        assertEq(
            uint8(partialSettler.orderStatus(orderDigest)),
            uint8(RolloverTypes.OrderStatus.Cancelled),
            "final reclaim promotes to Cancelled"
        );
        assertTrue(_logEmitted(secondLogs, ORDER_CANCELLED_TOPIC), "OrderCancelled on final");
        assertFalse(_logEmitted(secondLogs, ORDER_EXPIRED_TOPIC), "no OrderExpired on final");
    }

    /// @notice #135: settle one residual, then reclaim the final residual -> Cancelled.
    /// @custom:invariant INV-FSM-TERMINAL-WRITE-COMPLETE
    function test_partialCancel_settleThenReclaimFinal_terminalizesCancelled() public {
        RolloverTypes.OrderData memory orderData = _orderPartial(10);
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _openAsyncOrder(orderData, CHUNK_HALF);

        bytes32 subA = _subFillerKey(defaulterA);
        bytes32 subB = _subFillerKey(defaulterB);
        _fillAsyncRollover(orderData, orderDigest, defaulterA, subA, intent, cptHolderSig);
        _fillAsyncRollover(orderData, orderDigest, defaulterB, subB, intent, cptHolderSig);
        _cancelPartial(orderData, orderDigest);

        _fillAsyncPremium(orderData, orderDigest, defaulterA, subA, intent);
        assertEq(
            uint8(partialSettler.orderStatus(orderDigest)),
            uint8(RolloverTypes.OrderStatus.Closing),
            "paid non-final slot keeps Closing"
        );

        vm.warp(orderData.fillDeadline + 1);
        vm.prank(keeper);
        partialSettler.reclaim(orderDigest, defaulterB, subB, _originData(orderData));

        assertEq(
            uint8(partialSettler.orderStatus(orderDigest)),
            uint8(RolloverTypes.OrderStatus.Cancelled),
            "settle-then-reclaim-final converges to Cancelled"
        );
    }

    /// @notice Once reclaim is available, later premium settlement is blocked by fillDeadline.
    /// @custom:invariant INV-FSM-TERMINAL-WRITE-COMPLETE
    function test_partialCancel_reclaimThenSettleFinal_blockedByFillDeadline() public {
        RolloverTypes.OrderData memory orderData = _orderPartial(11);
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _openAsyncOrder(orderData, CHUNK_HALF);

        bytes32 subA = _subFillerKey(defaulterA);
        bytes32 subB = _subFillerKey(defaulterB);
        _fillAsyncRollover(orderData, orderDigest, defaulterA, subA, intent, cptHolderSig);
        _fillAsyncRollover(orderData, orderDigest, defaulterB, subB, intent, cptHolderSig);
        _cancelPartial(orderData, orderDigest);

        vm.warp(orderData.fillDeadline + 1);
        vm.prank(keeper);
        partialSettler.reclaim(orderDigest, defaulterA, subA, _originData(orderData));
        assertEq(
            uint8(partialSettler.orderStatus(orderDigest)),
            uint8(RolloverTypes.OrderStatus.Closing),
            "reclaimed non-final slot keeps Closing"
        );

        vm.expectRevert(Settler__FillAfterDeadline.selector);
        _fillAsyncPremium(orderData, orderDigest, defaulterB, subB, intent);
        assertEq(
            uint8(partialSettler.orderStatus(orderDigest)),
            uint8(RolloverTypes.OrderStatus.Closing),
            "failed post-deadline settlement leaves Closing"
        );
    }

    /// @notice #135: non-cancelled partial reclaim still finalizes as Expired.
    /// @custom:invariant INV-FSM-TERMINAL-WRITE-COMPLETE
    function test_partialReclaim_nonCancelled_finalizesExpired() public {
        RolloverTypes.OrderData memory orderData = _orderPartial(12);
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _openAsyncOrder(orderData, CHUNK_HALF);

        bytes32 subFiller = _subFillerKey(defaulterA);
        _fillAsyncRollover(orderData, orderDigest, defaulterA, subFiller, intent, cptHolderSig);
        assertEq(
            uint8(partialSettler.orderStatus(orderDigest)),
            uint8(RolloverTypes.OrderStatus.Opened),
            "order never cancelled"
        );

        vm.warp(orderData.fillDeadline + 1);
        vm.recordLogs();
        vm.prank(keeper);
        partialSettler.reclaim(orderDigest, defaulterA, subFiller, _originData(orderData));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            uint8(partialSettler.orderStatus(orderDigest)),
            uint8(RolloverTypes.OrderStatus.Expired),
            "non-cancelled reclaim finalizes Expired"
        );
        assertTrue(_logEmitted(logs, ORDER_EXPIRED_TOPIC), "OrderExpired emitted");
        assertFalse(_logEmitted(logs, ORDER_CANCELLED_TOPIC), "OrderCancelled must not be emitted");
    }
}
