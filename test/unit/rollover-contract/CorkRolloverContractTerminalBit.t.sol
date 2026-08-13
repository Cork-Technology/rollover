// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { FillScaffold } from "../../base/FillScaffold.sol";
import { BaseSettler } from "src/BaseSettler.sol";
import { CorkRolloverContract } from "src/CorkRolloverContract.sol";
import { Settler__OrderInTerminalState } from "src/errors/SettlerErrors.sol";
import { ICorkRolloverContract } from "src/interfaces/rollover/ICorkRolloverContract.sol";
import { IRolloverContractLens } from "src/interfaces/rollover/IRolloverContractLens.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice CorkRolloverContractTerminalBitTest — pins CorkRolloverContractTerminalBit behaviour for the Cork Rollover suite.
contract CorkRolloverContractTerminalBitTest is FillScaffold {
    /// @notice Half.
    uint256 internal constant HALF = 1_000e18;
    /// @notice Dst per leg.

    uint256 internal constant DST_PER_LEG = 1_000e18;
    /// @notice Order.

    uint256 internal constant ORDER = 2_000e18;
    /// @notice Phase 0 terminal bit.

    uint256 internal constant PHASE_0_TERMINAL_BIT = 1 << 0;

    function _setupPartialOrder()
        internal
        returns (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        )
    {
        orderData = _baseOrder();
        orderData = _usePartialSettler(orderData);
        orderData.orderSize = ORDER;

        intent = _buildIntent(bytes32(0), HALF, DST_PER_LEG);
        orderData.rolloverIntentHash = _zeroDigestHash(intent);
        orderDigest = _openOrder(orderData);
        intent.orderDigest = orderDigest;
        cptHolderSig = _signOrder(cptHolderPk, orderData);

        _approveFiller(ORDER, 0);
    }

    /// @notice Pins behaviour: partial Fill Leaves Terminal Bit Unset.
    function test_partialFillLeavesTerminalBitUnset() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupPartialOrder();

        _doRolloverAs(orderDigest, orderData, intent, HALF, filler);

        ICorkRolloverContract.RolloverContractOrderState memory s =
            IRolloverContractLens(address(factory)).orderState(rolloverContract, orderDigest);
        assertEq(s.rolled, HALF, "rolled tracks partial fill");
        assertFalse(s.rolloverTerminal, "terminal must NOT be set on partial");
    }

    /// @notice Pins behaviour: rolloverContract `rolloverTerminal` bit latches when a single atomic
    ///         fill drives `rolled == orderSize`. Under atomic-fill this is observable in
    ///         one frame when the filler is funded for the full order; the multi-filler
    ///         cumulative path is gated by the Settler terminal-state guard (a single
    ///         sub-filler auto-settles the order during its atomic frame).
    function test_finalFillSetsTerminalBit() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData = _usePartialSettler(orderData);
        orderData.orderSize = ORDER;

        // Intent supports a full-ORDER unwind in one atomic frame.
        RolloverTypes.RolloverIntent memory intent = _buildIntent(bytes32(0), ORDER, ORDER);
        orderData.rolloverIntentHash = _zeroDigestHash(intent);
        bytes32 orderDigest = _openOrder(orderData);
        intent.orderDigest = orderDigest;
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);

        _approveFiller(ORDER, 0);
        _doRolloverAs(orderDigest, orderData, intent, ORDER, filler);

        ICorkRolloverContract.RolloverContractOrderState memory s =
            IRolloverContractLens(address(factory)).orderState(rolloverContract, orderDigest);
        assertEq(s.rolled, ORDER, "rolled == orderSize");
        assertTrue(
            s.rolloverTerminal, "rolloverTerminal must latch on cumulative-reaches-orderSize"
        );
    }

    /// @notice Second half-fill completes aggregate consumption and terminalizes the order;
    ///         a third fill reverts at the Settler terminal-state gate.
    function testRevert_replayAfterTerminalRevertsPhaseAlreadyConsumed() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupPartialOrder();

        address fillerB = address(0xF2);
        srcCst.mint(fillerB, HALF);
        premiumToken.mint(fillerB, 1_000_000e18);
        vm.startPrank(fillerB);
        srcCst.approve(address(settler), type(uint256).max);
        srcCst.approve(address(partialSettler), type(uint256).max);
        premiumToken.approve(address(settler), type(uint256).max);
        premiumToken.approve(address(partialSettler), type(uint256).max);
        vm.stopPrank();

        _doRolloverAs(orderDigest, orderData, intent, HALF, filler);

        assertEq(
            uint8(partialSettler.orderStatus(orderDigest)),
            uint8(RolloverTypes.OrderStatus.Opened),
            "first half-fill keeps order Opened"
        );

        _doRolloverAs(orderDigest, orderData, intent, HALF, fillerB);

        assertEq(
            uint8(partialSettler.orderStatus(orderDigest)),
            uint8(RolloverTypes.OrderStatus.Settled),
            "aggregate consumption terminalizes"
        );

        vm.expectRevert(Settler__OrderInTerminalState.selector);
        _doRolloverAs(orderDigest, orderData, intent, HALF, fillerB);
    }

    /// @notice Pins behaviour: reverts when overfill Ceiling.
    function testRevert_overfillCeiling() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupPartialOrder();

        _doRolloverAs(orderDigest, orderData, intent, HALF, filler);

        uint256 over = ORDER + 1;
        srcCst.mint(filler, over);
        vm.startPrank(filler);
        srcCst.approve(address(settler), over);
        srcCst.approve(address(partialSettler), over);
        vm.stopPrank();

        vm.expectRevert();
        _doRolloverAs(orderDigest, orderData, intent, over, filler);
    }
}
