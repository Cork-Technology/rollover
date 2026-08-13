// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";
import { BaseSettler } from "src/BaseSettler.sol";
import { ExactSettler } from "src/ExactSettler.sol";
import { PartialSettler } from "src/PartialSettler.sol";
import {
    Settler__ExactFillerMismatch,
    Settler__FillerAlreadySettled,
    Settler__NoResidualToReclaim,
    Settler__OrderHasFills,
    Settler__OrderInTerminalState,
    Settler__PremiumForMismatch,
    Settler__PremiumNotPaid,
    Settler__PremiumNotSettled,
    Settler__RolloverAmountOutOfBounds
} from "src/errors/SettlerErrors.sol";
import { FillerPayload } from "src/types/FillerTypes.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice Test-only exact settler exposing internal refund hook behavior.
contract ExactRefundHookHarness is ExactSettler {
    /// @param factory_ Nonzero factory address required by the base constructor.
    /// @param corkPoolManager_ Nonzero pool manager address required by the base constructor.
    /// @param admin_ Initial owner/admin/pauser/unpauser address.
    constructor(address factory_, address corkPoolManager_, address admin_)
        ExactSettler(factory_, corkPoolManager_, admin_, admin_, admin_, admin_)
    { }

    /// @notice Marks exact premium as fired for `orderId` through the mode hook.
    /// @param orderId Order digest.
    function exposedMarkPremiumFired(bytes32 orderId) external {
        _recordPremiumPaid(orderId, PremiumPaymentContext(address(0), 0, 0, address(0)), bytes32(0));
    }

    /// @notice Exposes `ExactSettler._recordRolloverAccountingForMode`.
    /// @param orderId Order digest.
    /// @param filler Rollover filler.
    /// @param subFiller Recorded exact sub-filler.
    /// @param dstProduced Destination CST produced.
    /// @param destination Recorded settlement destination.
    function exposedRecordRolloverAccountingForMode(
        bytes32 orderId,
        address filler,
        bytes32 subFiller,
        uint256 dstProduced,
        address destination
    ) external {
        _recordRolloverAccountingForMode(
            orderId, filler, subFiller, dstProduced, 0, destination, dstProduced
        );
    }

    /// @notice Exposes `ExactSettler._loadPremiumPaymentContext`.
    /// @param orderId Order digest.
    /// @param fillerPayload Decoded premium payload.
    /// @return paymentContext Resolved premium payment context.
    function exposedLoadPremiumPaymentContext(bytes32 orderId, FillerPayload memory fillerPayload)
        external
        view
        returns (PremiumPaymentContext memory paymentContext)
    {
        (paymentContext,) = _loadPremiumPaymentContext(orderId, fillerPayload, 1);
    }

    /// @notice Exposes `ExactSettler._settlePaidRolloverRecord`.
    /// @param orderId Order digest.
    /// @param filler Caller-supplied filler identity.
    /// @param status Status supplied to the mode hook.
    /// @param orderData Decoded order data.
    function exposedSettlePaidRolloverRecord(
        bytes32 orderId,
        address filler,
        RolloverTypes.OrderStatus status,
        RolloverTypes.OrderData memory orderData
    ) external {
        _settlePaidRolloverRecord(orderId, filler, bytes32(0), status, orderData);
    }

    /// @notice Exposes `ExactSettler._clearReclaimableResidualForMode`.
    /// @param orderId Order digest.
    /// @param orderData Decoded order data.
    function exposedClearReclaimableResidualForMode(
        bytes32 orderId,
        RolloverTypes.OrderData memory orderData
    ) external {
        _clearReclaimableResidualForMode(orderId, address(0), bytes32(0), orderData);
    }

    /// @notice Exposes `ExactSettler._cancelOrderForMode`.
    /// @param orderId Order digest.
    function exposedCancelOrderForMode(bytes32 orderId) external {
        _cancelOrderForMode(orderId);
    }
}

/// @notice Test-only partial settler exposing internal mode-hook behavior.
contract PartialHookHarness is PartialSettler {
    /// @param factory_ Nonzero factory address required by the base constructor.
    /// @param corkPoolManager_ Nonzero pool manager address required by the base constructor.
    /// @param admin_ Initial owner/admin/pauser/unpauser address.
    constructor(address factory_, address corkPoolManager_, address admin_)
        PartialSettler(factory_, corkPoolManager_, admin_, admin_, admin_, admin_)
    { }

    /// @notice Exposes `PartialSettler._recordRolloverAccountingForMode`.
    /// @param orderId Order digest.
    /// @param filler Rollover filler.
    /// @param subFiller Partial sub-filler key.
    /// @param dstProduced Destination CST produced.
    /// @param srcProvided Source CST consumed.
    /// @param destination Recorded settlement destination.
    /// @param orderSize Signed order size.
    function exposedRecordRolloverAccountingForMode(
        bytes32 orderId,
        address filler,
        bytes32 subFiller,
        uint256 dstProduced,
        uint256 srcProvided,
        address destination,
        uint256 orderSize
    ) external {
        _recordRolloverAccountingForMode(
            orderId, filler, subFiller, dstProduced, srcProvided, destination, orderSize
        );
    }

    /// @notice Test-only liability mirror for direct internal-hook fixtures.
    /// @param token Destination CST token.
    /// @param liabilityAmount Liability amount to seed.
    function exposedIncreaseDstCstLiability(address token, uint256 liabilityAmount) external {
        dstCstLiability[token] += liabilityAmount;
    }

    /// @notice Marks partial premium as fired for a filler slot.
    /// @param orderId Order digest.
    /// @param filler Rollover filler.
    /// @param subFiller Partial sub-filler key.
    function exposedMarkPremiumFired(bytes32 orderId, address filler, bytes32 subFiller) external {
        _recordPremiumPaid(orderId, PremiumPaymentContext(filler, 0, 0, address(0)), subFiller);
    }

    /// @notice Exposes `PartialSettler._loadPremiumPaymentContext`.
    /// @param orderId Order digest.
    /// @param fillerPayload Decoded premium payload.
    /// @return paymentContext Resolved premium payment context.
    function exposedLoadPremiumPaymentContext(bytes32 orderId, FillerPayload memory fillerPayload)
        external
        view
        returns (PremiumPaymentContext memory paymentContext)
    {
        (paymentContext,) = _loadPremiumPaymentContext(orderId, fillerPayload, 1);
    }

    /// @notice Exposes `PartialSettler._settlePaidRolloverRecord`.
    /// @param orderId Order digest.
    /// @param filler Rollover filler.
    /// @param subFiller Partial sub-filler key.
    /// @param status Status supplied to the mode hook.
    /// @param orderData Decoded order data.
    function exposedSettlePaidRolloverRecord(
        bytes32 orderId,
        address filler,
        bytes32 subFiller,
        RolloverTypes.OrderStatus status,
        RolloverTypes.OrderData memory orderData
    ) external {
        _settlePaidRolloverRecord(orderId, filler, subFiller, status, orderData);
    }

    /// @notice Exposes `PartialSettler._clearReclaimableResidualForMode`.
    /// @param orderId Order digest.
    /// @param filler Rollover filler.
    /// @param subFiller Partial sub-filler key.
    /// @param orderData Decoded order data.
    function exposedClearReclaimableResidualForMode(
        bytes32 orderId,
        address filler,
        bytes32 subFiller,
        RolloverTypes.OrderData memory orderData
    ) external {
        _clearReclaimableResidualForMode(orderId, filler, subFiller, orderData);
    }
}

/// @notice Unit coverage for internal settler hooks that are otherwise only reached by virtual dispatch.
contract SettlerInternalHookCoverageTest is Test {
    /// @notice Verifies exact premium payment context rejects a mismatched premium filler.
    function testRevert_exactLoadPremiumPaymentContext_rejectsMismatchedFiller() public {
        ExactRefundHookHarness harness =
            new ExactRefundHookHarness(address(0xFACADE), address(0xC0FE), address(this));
        bytes32 orderId = bytes32(uint256(3));
        address recorded = address(0xA11CE);
        address supplied = address(0xB0B);
        FillerPayload memory payload;
        payload.premiumFor = supplied;

        harness.exposedRecordRolloverAccountingForMode(orderId, recorded, bytes32(0), 1, recorded);

        vm.expectRevert(Settler__PremiumForMismatch.selector);
        harness.exposedLoadPremiumPaymentContext(orderId, payload);
    }

    /// @notice Verifies exact settlement rejects hard-terminal status before storage reads.
    function testRevert_exactSettlePaidRolloverRecord_terminalStatus() public {
        ExactRefundHookHarness harness =
            new ExactRefundHookHarness(address(0xFACADE), address(0xC0FE), address(this));
        RolloverTypes.OrderData memory orderData;

        vm.expectRevert(Settler__OrderInTerminalState.selector);
        harness.exposedSettlePaidRolloverRecord(
            bytes32(uint256(4)), address(0xA11CE), RolloverTypes.OrderStatus.Settled, orderData
        );
    }

    /// @notice Verifies exact settlement rejects a rollover record before premium fires.
    function testRevert_exactSettlePaidRolloverRecord_premiumNotSettled() public {
        ExactRefundHookHarness harness =
            new ExactRefundHookHarness(address(0xFACADE), address(0xC0FE), address(this));
        bytes32 orderId = bytes32(uint256(5));
        RolloverTypes.OrderData memory orderData;

        harness.exposedRecordRolloverAccountingForMode(
            orderId, address(0xA11CE), bytes32(0), 1, address(0xA11CE)
        );

        vm.expectRevert(Settler__PremiumNotSettled.selector);
        harness.exposedSettlePaidRolloverRecord(
            orderId, address(0xA11CE), RolloverTypes.OrderStatus.Opened, orderData
        );
    }

    /// @notice Verifies exact settlement rejects the wrong caller-supplied filler.
    function testRevert_exactSettlePaidRolloverRecord_wrongFiller() public {
        ExactRefundHookHarness harness =
            new ExactRefundHookHarness(address(0xFACADE), address(0xC0FE), address(this));
        bytes32 orderId = bytes32(uint256(6));
        address recorded = address(0xA11CE);
        address supplied = address(0xB0B);
        RolloverTypes.OrderData memory orderData;

        harness.exposedRecordRolloverAccountingForMode(orderId, recorded, bytes32(0), 1, recorded);
        harness.exposedMarkPremiumFired(orderId);

        vm.expectRevert(
            abi.encodeWithSelector(Settler__ExactFillerMismatch.selector, recorded, supplied)
        );
        harness.exposedSettlePaidRolloverRecord(
            orderId, supplied, RolloverTypes.OrderStatus.Opened, orderData
        );
    }

    /// @notice Verifies exact reclaim rejects after premium has fired.
    function testRevert_exactClearReclaimableResidualForMode_afterPremiumFired() public {
        ExactRefundHookHarness harness =
            new ExactRefundHookHarness(address(0xFACADE), address(0xC0FE), address(this));
        bytes32 orderId = bytes32(uint256(7));
        RolloverTypes.OrderData memory orderData;

        harness.exposedRecordRolloverAccountingForMode(
            orderId, address(0xA11CE), bytes32(0), 1, address(0xA11CE)
        );
        harness.exposedMarkPremiumFired(orderId);

        vm.expectRevert(Settler__NoResidualToReclaim.selector);
        harness.exposedClearReclaimableResidualForMode(orderId, orderData);
    }

    /// @notice Verifies exact cancel rejects orders with an existing fill record.
    function testRevert_exactCancelOrderForMode_orderHasFills() public {
        ExactRefundHookHarness harness =
            new ExactRefundHookHarness(address(0xFACADE), address(0xC0FE), address(this));
        bytes32 orderId = bytes32(uint256(8));

        harness.exposedRecordRolloverAccountingForMode(
            orderId, address(0xA11CE), bytes32(0), 1, address(0xA11CE)
        );

        vm.expectRevert(Settler__OrderHasFills.selector);
        harness.exposedCancelOrderForMode(orderId);
    }

    /// @notice Verifies partial aggregate accounting rejects source overfill.
    function testRevert_partialRecordRolloverLeg_aggregateOverfill() public {
        PartialHookHarness harness =
            new PartialHookHarness(address(0xFACADE), address(0xC0FE), address(this));
        bytes32 orderId = bytes32(uint256(10));
        address filler = address(0xA11CE);
        bytes32 subFiller = bytes32(uint256(1));
        address destination = address(0xD157);

        harness.exposedRecordRolloverAccountingForMode(
            orderId, filler, subFiller, 1, 8, destination, 10
        );

        vm.expectRevert(abi.encodeWithSelector(Settler__RolloverAmountOutOfBounds.selector, 10, 11));
        harness.exposedRecordRolloverAccountingForMode(
            orderId, filler, subFiller, 1, 3, destination, 10
        );
    }

    /// @notice Verifies partial settlement rejects hard-terminal status.
    function testRevert_partialSettlePaidRolloverRecord_terminalStatus() public {
        PartialHookHarness harness =
            new PartialHookHarness(address(0xFACADE), address(0xC0FE), address(this));
        RolloverTypes.OrderData memory orderData;

        vm.expectRevert(Settler__OrderInTerminalState.selector);
        harness.exposedSettlePaidRolloverRecord(
            bytes32(uint256(11)),
            address(0xA11CE),
            bytes32(uint256(1)),
            RolloverTypes.OrderStatus.Settled,
            orderData
        );
    }

    /// @notice Finding #16: partial settlement uses `isHardTerminal`, so it rejects every hard
    ///         terminal status — including `Expired` — for parity with exact mode.
    function testRevert_partialSettlePaidRolloverRecord_rejectsAllHardTerminalStatuses() public {
        PartialHookHarness harness =
            new PartialHookHarness(address(0xFACADE), address(0xC0FE), address(this));
        RolloverTypes.OrderData memory orderData;
        bytes32 orderId = bytes32(uint256(110));
        address filler = address(0xA11CE);
        bytes32 subFiller = bytes32(uint256(1));

        RolloverTypes.OrderStatus[3] memory terminal = [
            RolloverTypes.OrderStatus.Expired,
            RolloverTypes.OrderStatus.Cancelled,
            RolloverTypes.OrderStatus.Settled
        ];
        for (uint256 i; i < terminal.length; ++i) {
            vm.expectRevert(Settler__OrderInTerminalState.selector);
            harness.exposedSettlePaidRolloverRecord(
                orderId, filler, subFiller, terminal[i], orderData
            );
        }
    }

    /// @notice Verifies partial settlement rejects unpaid premium.
    function testRevert_partialSettlePaidRolloverRecord_premiumNotPaid() public {
        PartialHookHarness harness =
            new PartialHookHarness(address(0xFACADE), address(0xC0FE), address(this));
        bytes32 orderId = bytes32(uint256(12));
        address filler = address(0xA11CE);
        bytes32 subFiller = bytes32(uint256(1));
        RolloverTypes.OrderData memory orderData;

        harness.exposedRecordRolloverAccountingForMode(orderId, filler, subFiller, 1, 1, filler, 10);

        vm.expectRevert(Settler__PremiumNotPaid.selector);
        harness.exposedSettlePaidRolloverRecord(
            orderId, filler, subFiller, RolloverTypes.OrderStatus.Opened, orderData
        );
    }

    /// @notice Verifies partial settlement rejects an already-settled filler slot.
    function testRevert_partialSettlePaidRolloverRecord_alreadySettled() public {
        PartialHookHarness harness =
            new PartialHookHarness(address(0xFACADE), address(0xC0FE), address(this));
        bytes32 orderId = bytes32(uint256(13));
        address filler = address(0xA11CE);
        bytes32 subFiller = bytes32(uint256(1));
        RolloverTypes.OrderData memory orderData;
        orderData.orderSize = 10;

        harness.exposedRecordRolloverAccountingForMode(orderId, filler, subFiller, 0, 1, filler, 10);
        harness.exposedMarkPremiumFired(orderId, filler, subFiller);
        harness.exposedSettlePaidRolloverRecord(
            orderId, filler, subFiller, RolloverTypes.OrderStatus.Opened, orderData
        );

        vm.expectRevert(Settler__FillerAlreadySettled.selector);
        harness.exposedSettlePaidRolloverRecord(
            orderId, filler, subFiller, RolloverTypes.OrderStatus.Opened, orderData
        );
    }

    /// @notice Verifies partial reclaim rejects after premium has fired.
    function testRevert_partialClearReclaimableResidualForMode_afterPremiumFired() public {
        PartialHookHarness harness =
            new PartialHookHarness(address(0xFACADE), address(0xC0FE), address(this));
        bytes32 orderId = bytes32(uint256(14));
        address filler = address(0xA11CE);
        bytes32 subFiller = bytes32(uint256(1));
        RolloverTypes.OrderData memory orderData;

        harness.exposedRecordRolloverAccountingForMode(orderId, filler, subFiller, 1, 1, filler, 10);
        harness.exposedMarkPremiumFired(orderId, filler, subFiller);

        vm.expectRevert(Settler__NoResidualToReclaim.selector);
        harness.exposedClearReclaimableResidualForMode(orderId, filler, subFiller, orderData);
    }

    /// @notice Verifies partial premium payment context rejects reclaimed filler slots.
    function testRevert_partialLoadPremiumPaymentContext_alreadySettled() public {
        PartialHookHarness harness =
            new PartialHookHarness(address(0xFACADE), address(0xC0FE), address(this));
        bytes32 orderId = bytes32(uint256(15));
        address filler = address(0xA11CE);
        bytes32 subFiller = bytes32(uint256(1));
        RolloverTypes.OrderData memory orderData;
        orderData.dstCstToken = address(new TransferFreeToken());
        orderData.rolloverContract = address(0xCE11A);
        FillerPayload memory payload;
        payload.premiumFor = filler;
        payload.subFiller = subFiller;

        harness.exposedRecordRolloverAccountingForMode(orderId, filler, subFiller, 1, 1, filler, 10);
        TransferFreeToken(orderData.dstCstToken).mint(address(harness), 1);
        harness.exposedIncreaseDstCstLiability(orderData.dstCstToken, 1);
        harness.exposedClearReclaimableResidualForMode(orderId, filler, subFiller, orderData);

        vm.expectRevert(Settler__FillerAlreadySettled.selector);
        harness.exposedLoadPremiumPaymentContext(orderId, payload);
    }
}

/// @notice Minimal ERC-20-like token for transfer-only internal hook tests.
contract TransferFreeToken {
    /// @notice Token balances.
    mapping(address account => uint256 balance) public balanceOf;

    /// @notice Mint tokens for hook transfer setup.
    /// @param to Recipient address.
    /// @param amount Token amount.
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    /// @notice Transfer tokens from the caller to `to`.
    /// @param to Recipient address.
    /// @param amount Token amount.
    /// @return ok True when transfer succeeds.
    function transfer(address to, uint256 amount) external returns (bool ok) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
