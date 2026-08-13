// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { FillScaffold } from "../base/FillScaffold.sol";
import {
    ExactResidualReconciliationHandler,
    IExactResidualReconciliationDriver
} from "./handlers/ExactResidualReconciliationHandler.sol";
import { ISettler } from "src/interfaces/settlers/ISettler.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";
import { SettlerTypes } from "src/types/SettlerTypes.sol";

/// @notice Shared exact residual reconciliation invariant driver.
abstract contract ExactResidualReconciliationInvariantBase is
    FillScaffold,
    IExactResidualReconciliationDriver
{
    /// @notice Exact order size used by handler-authored records.
    uint256 internal constant EXACT_RESIDUAL_FILL = 100e18;

    /// @notice Salt base reserved for exact residual records.
    uint64 internal constant EXACT_RESIDUAL_SALT_BASE = 120_000;

    /// @notice External premium payer.
    address internal sponsor = address(0x5A0);

    /// @notice Handler under test.
    ExactResidualReconciliationHandler internal exactResidualHandler;

    /// @notice Ghost exact residual record.
    struct ExactResidualRecord {
        /// @notice Order digest.
        bytes32 orderDigest;
        /// @notice Ghost-copy order data decoded by the invariant harness.
        RolloverTypes.OrderData orderData;
        /// @notice Encoded async premium payload for this order.
        bytes premiumData;
        /// @notice First observed `dstCstProduced`.
        uint256 firstProduced;
        /// @notice Current expected unpaid exact residual.
        uint256 expectedResidual;
        /// @notice Whether premium settlement or reclaim drained the residual.
        bool drained;
    }

    /// @notice Records observed by the handler.
    ExactResidualRecord[] internal exactResidualRecords;

    function _setUpExactResidualInvariant() internal {
        _approveFiller(type(uint256).max, type(uint256).max);
        srcCst.mint(sponsor, 1_000_000e18);
        premiumToken.mint(sponsor, 1_000_000e18);
        vm.prank(sponsor);
        premiumToken.approve(address(settler), type(uint256).max);

        exactResidualHandler = new ExactResidualReconciliationHandler(
            IExactResidualReconciliationDriver(address(this))
        );
        targetContract(address(exactResidualHandler));

        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = exactResidualHandler.asyncRollover.selector;
        selectors[1] = exactResidualHandler.premiumSettle.selector;
        selectors[2] = exactResidualHandler.reclaim.selector;
        selectors[3] = exactResidualHandler.atomicFill.selector;
        selectors[4] = exactResidualHandler.observe.selector;
        targetSelector(FuzzSelector({ addr: address(exactResidualHandler), selectors: selectors }));
    }

    /// @inheritdoc IExactResidualReconciliationDriver
    function driveExactAsyncRollover(uint64 saltSeed) external returns (bool ok) {
        require(msg.sender == address(exactResidualHandler), "ExactResidual: only handler");
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepareExactResidualOrder(saltSeed, true);

        vm.prank(filler);
        ISettler(orderData.settler)
            .fill(
                orderDigest,
                _originData(orderData),
                _rolloverPhaseData(EXACT_RESIDUAL_FILL, filler, bytes32(0), intent, cptHolderSig)
            );

        uint256 produced = settler.rolloverAccountingOf(orderDigest).dstCstProduced;
        exactResidualRecords.push(
            ExactResidualRecord({
                orderDigest: orderDigest,
                orderData: orderData,
                premiumData: _premiumPhaseData(
                    address(0), filler, bytes32(0), intent, cptHolderSig
                ),
                firstProduced: produced,
                expectedResidual: produced,
                drained: false
            })
        );
        return produced != 0;
    }

    /// @inheritdoc IExactResidualReconciliationDriver
    function driveExactPremiumSettle(uint256 indexSeed) external returns (bool ok) {
        require(msg.sender == address(exactResidualHandler), "ExactResidual: only handler");
        (bool found, uint256 index) = _selectLivePremiumResidual(indexSeed);
        if (!found) {
            return true;
        }
        ExactResidualRecord storage rec = exactResidualRecords[index];
        vm.prank(sponsor);
        ISettler(rec.orderData.settler)
            .fill(rec.orderDigest, _originData(rec.orderData), rec.premiumData);
        rec.expectedResidual = 0;
        rec.drained = true;
        return true;
    }

    /// @inheritdoc IExactResidualReconciliationDriver
    function driveExactReclaim(uint256 indexSeed) external returns (bool ok) {
        require(msg.sender == address(exactResidualHandler), "ExactResidual: only handler");
        (bool found, uint256 index) = _selectLiveResidual(indexSeed);
        if (!found) {
            return true;
        }
        ExactResidualRecord storage rec = exactResidualRecords[index];
        vm.warp(rec.orderData.fillDeadline + 1);
        ISettler(rec.orderData.settler)
            .reclaim(rec.orderDigest, filler, bytes32(0), _originData(rec.orderData));
        rec.expectedResidual = 0;
        rec.drained = true;
        return true;
    }

    /// @inheritdoc IExactResidualReconciliationDriver
    function driveExactAtomicFill(uint64 saltSeed) external returns (bool ok) {
        require(msg.sender == address(exactResidualHandler), "ExactResidual: only handler");
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepareExactResidualOrder(saltSeed, false);

        _doRolloverAs(orderDigest, orderData, intent, EXACT_RESIDUAL_FILL, filler);
        uint256 produced = settler.rolloverAccountingOf(orderDigest).dstCstProduced;
        exactResidualRecords.push(
            ExactResidualRecord({
                orderDigest: orderDigest,
                orderData: orderData,
                premiumData: bytes(""),
                firstProduced: produced,
                expectedResidual: 0,
                drained: true
            })
        );
        return produced != 0;
    }

    /// @inheritdoc IExactResidualReconciliationDriver
    function observeExactResiduals()
        external
        view
        returns (
            uint256 residualSum,
            uint256 settlerBalance,
            bool producedSetOnce,
            bool residualBounded
        )
    {
        require(msg.sender == address(exactResidualHandler), "ExactResidual: only handler");
        producedSetOnce = true;
        residualBounded = true;
        uint256 n = exactResidualRecords.length;
        for (uint256 i; i < n; ++i) {
            ExactResidualRecord storage rec = exactResidualRecords[i];
            SettlerTypes.ExactRolloverAccounting memory live =
                settler.rolloverAccountingOf(rec.orderDigest);
            if (live.dstCstProduced != rec.firstProduced) {
                producedSetOnce = false;
            }
            if (rec.expectedResidual > rec.firstProduced) {
                residualBounded = false;
            }
            residualSum += rec.expectedResidual;
        }
        settlerBalance = dstCst.balanceOf(address(settler));
    }

    function _prepareExactResidualOrder(uint64 saltSeed, bool asyncPremium)
        internal
        view
        returns (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        )
    {
        orderData = _baseOrder();
        orderData.orderSize = EXACT_RESIDUAL_FILL;
        orderData.premiumPaymentMode = asyncPremium
            ? RolloverTypes.PREMIUM_PAYMENT_MODE_ATOMIC_OR_SEPARATE
            : RolloverTypes.PREMIUM_PAYMENT_MODE_ATOMIC_ONLY;
        orderData.orderSalt = uint64(
            uint256(EXACT_RESIDUAL_SALT_BASE) + exactResidualRecords.length
                + uint256(saltSeed % 1024) * 10_000
        );
        RolloverTypes.RolloverIntent memory probe =
            _buildIntent(bytes32(0), EXACT_RESIDUAL_FILL, EXACT_RESIDUAL_FILL);
        orderData.rolloverIntentHash = _zeroDigestHash(probe);
        orderDigest = _orderDigest(orderData);
        intent = _buildIntent(orderDigest, EXACT_RESIDUAL_FILL, EXACT_RESIDUAL_FILL);
        cptHolderSig = _signOrder(cptHolderPk, orderData);
    }

    function _selectLiveResidual(uint256 indexSeed)
        internal
        view
        returns (bool found, uint256 index)
    {
        uint256 n = exactResidualRecords.length;
        if (n == 0) {
            return (false, 0);
        }
        uint256 start = bound(indexSeed, 0, n - 1);
        for (uint256 i; i < n; ++i) {
            uint256 candidate = (start + i) % n;
            if (!exactResidualRecords[candidate].drained) {
                return (true, candidate);
            }
        }
        return (false, 0);
    }

    function _selectLivePremiumResidual(uint256 indexSeed)
        internal
        view
        returns (bool found, uint256 index)
    {
        uint256 n = exactResidualRecords.length;
        if (n == 0) {
            return (false, 0);
        }
        uint256 start = bound(indexSeed, 0, n - 1);
        for (uint256 i; i < n; ++i) {
            uint256 candidate = (start + i) % n;
            ExactResidualRecord storage rec = exactResidualRecords[candidate];
            if (!rec.drained && block.timestamp <= rec.orderData.fillDeadline) {
                return (true, candidate);
            }
        }
        return (false, 0);
    }

    function _rolloverPhaseData(
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

    function _premiumPhaseData(
        address destination,
        address premiumFor,
        bytes32 subFiller,
        RolloverTypes.RolloverIntent memory intent,
        bytes memory cptHolderSig
    ) internal pure returns (bytes memory) {
        return abi.encode(
            uint8(RolloverTypes.HookPhase.PREMIUM),
            uint256(0),
            uint256(1_000_000e18),
            destination,
            premiumFor,
            intent,
            uint256(0),
            bytes(""),
            subFiller,
            cptHolderSig
        );
    }
}
