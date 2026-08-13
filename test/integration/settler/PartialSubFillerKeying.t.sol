// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { FillScaffold } from "../../base/FillScaffold.sol";
import { Vm } from "forge-std/Vm.sol";
import { BaseSettler } from "src/BaseSettler.sol";
import { PartialSettler } from "src/PartialSettler.sol";
import { Settler__PremiumAlreadyFiredRollover } from "src/errors/SettlerErrors.sol";
import { ISettler } from "src/interfaces/settlers/ISettler.sol";
import { LibFillerAuth } from "src/libraries/LibFillerAuth.sol";
import { Typehashes } from "src/libraries/Typehashes.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice Pins INV-PARTIAL-SUBFILLER-KEYING and INV-SUBFILLER-PROVENANCE.
///
///         Partial-mode accounting keys by `(orderDigest, msg.sender, subFiller)`.
///         When a shared filler contract (BaseFiller, EvcRolloverAdapter) routes for multiple
///         users, each user's per-rollover state is independent. `subFiller` is derived from
///         the upstream caller identity (BaseFiller: `msg.sender`; EvcAdapter: `job.subaccount`).
///         Direct-EOA fills send `subFiller = bytes32(0)`; the decoder substitutes
///         `bytes32(uint256(uint160(msg.sender)))` so direct-EOA self-keys to its own address.
///
///         FillerAuth EIP-712 typehash includes `subFiller`.
/// @custom:invariant INV-PARTIAL-SUBFILLER-KEYING
/// @custom:invariant INV-SUBFILLER-PROVENANCE
contract PartialSubFillerKeyingTest is FillScaffold {
    /// @notice Legacy CorkRolloverContract.RolloverLegSettled event selector.
    bytes32 internal constant ROLLOVER_LEG_SETTLED_TOPIC =
        keccak256("RolloverLegSettled(bytes32,address,uint256)");

    /// @notice Enriched CorkRolloverContract rollover telemetry expected by L-03 remediation.
    bytes32 internal constant ROLLOVER_LEG_SETTLED_WITH_SUBFILLER_TOPIC =
        keccak256("RolloverLegSettledWithSubFiller(bytes32,address,bytes32,uint256)");

    /// @notice Legacy CorkRolloverContract.IntentPhaseFired event selector.
    bytes32 internal constant INTENT_PHASE_FIRED_TOPIC = keccak256(
        "IntentPhaseFired(bytes32,uint8,address,uint256,uint256,uint256,bool,uint256,uint256)"
    );

    /// @notice Enriched CorkRolloverContract phase telemetry expected by L-03 remediation.
    bytes32 internal constant INTENT_PHASE_FIRED_WITH_SUBFILLER_TOPIC = keccak256(
        "IntentPhaseFiredWithSubFiller(bytes32,address,bytes32,uint8,uint256,uint256,uint256,bool,uint256,uint256)"
    );

    /// @notice Legacy BaseSettler.DefaulterResidualReclaimed event selector.
    bytes32 internal constant DEFAULTER_RESIDUAL_RECLAIMED_TOPIC =
        keccak256("DefaulterResidualReclaimed(bytes32,address,address,uint256)");

    /// @notice Enriched BaseSettler reclaim telemetry expected by L-03 remediation.
    bytes32 internal constant DEFAULTER_RESIDUAL_RECLAIMED_WITH_SUBFILLER_TOPIC = keccak256(
        "DefaulterResidualReclaimedWithSubFiller(bytes32,address,bytes32,address,uint256)"
    );

    /// @notice Sub-filler A.
    address internal alice = address(0xA11CE);
    /// @notice Sub-filler B.
    address internal bob = address(0xB0B);
    /// @notice Sub-filler C.
    address internal carol = address(0xCA401E);
    /// @notice Stand-in shared "filler contract" address used as msg.sender in 10-tuple fills.
    address internal sharedFiller = address(0x5AED);

    /// @notice Default order size for partial-mode fixtures.
    uint256 internal constant ORDER_SIZE = 1_000e18;
    /// @notice Default per-fill chunk for partial-mode fixtures.
    uint256 internal constant CHUNK = 333e18;

    /// @inheritdoc BaseTest
    function setUp() public override {
        super.setUp();

        // Default `filler` (from BaseTest) routes through both Settlers; approve both.
        _approveFiller(type(uint256).max, type(uint256).max);

        // Mint + approve for sharedFiller (the simulated routed BaseFiller proxy).
        srcCst.mint(sharedFiller, 1_000_000e18);
        premiumToken.mint(sharedFiller, 1_000_000e18);
        vm.startPrank(sharedFiller);
        srcCst.approve(address(partialSettler), type(uint256).max);
        premiumToken.approve(address(partialSettler), type(uint256).max);
        vm.stopPrank();

        address[3] memory eoas = [alice, bob, carol];
        for (uint256 i; i < eoas.length; ++i) {
            srcCst.mint(eoas[i], 1_000_000e18);
            premiumToken.mint(eoas[i], 1_000_000e18);
            vm.startPrank(eoas[i]);
            srcCst.approve(address(partialSettler), type(uint256).max);
            premiumToken.approve(address(partialSettler), type(uint256).max);
            vm.stopPrank();
        }

        vm.label(alice, "alice");
        vm.label(bob, "bob");
        vm.label(carol, "carol");
        vm.label(sharedFiller, "sharedFiller");
    }

    /// @notice Build a partial order with `nonce`-keyed orderSalt.
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

    /// @notice Build intent + cptHolderSig for the order under test.
    function _prepare(RolloverTypes.OrderData memory orderData)
        internal
        view
        returns (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        )
    {
        RolloverTypes.RolloverIntent memory probe = _buildIntent(bytes32(0), ORDER_SIZE, ORDER_SIZE);
        orderData.rolloverIntentHash = _zeroDigestHash(probe);
        orderDigest = _orderDigest(orderData);
        intent = _buildIntent(orderDigest, ORDER_SIZE, ORDER_SIZE);
        cptHolderSig = _signOrder(cptHolderPk, orderData);
    }

    /// @dev Encode a 10-tuple rollover fillerData blob with explicit subFiller. Used by
    ///      this test suite to exercise the current wire format directly. The `cptHolderSig` is
    ///      the cPT-holder EIP-712 sig over `orderDigest` verified on the `status==None` branch.
    function _rolloverFillerData10(
        uint256 fillAmount,
        address destination,
        bytes32 subFiller,
        RolloverTypes.RolloverIntent memory intent,
        bytes memory cptHolderSig
    ) internal pure returns (bytes memory) {
        bytes memory rolloverLeg = _psfkRolloverLeg(fillAmount, destination, subFiller, intent);
        destination;
        cptHolderSig;
        return abi.encode(uint8(255), rolloverLeg, uint256(1_000_000e18), cptHolderSig);
    }

    function _psfkRolloverLeg(
        uint256 fillAmount,
        address destination,
        bytes32 subFiller,
        RolloverTypes.RolloverIntent memory intent
    ) private pure returns (bytes memory) {
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
            bytes("")
        );
    }

    /// @dev Encode a phase-tagged async rollover payload with cPT-holder signature for
    ///      direct-fill admission from status None.
    function _rolloverOnlyFillerData10(
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

    /// @dev Encode a 10-tuple premium fillerData blob with explicit subFiller.
    function _premiumFillerData10(
        uint256 premium,
        address destination,
        address premiumFor,
        bytes32 subFiller,
        RolloverTypes.RolloverIntent memory intent,
        bytes memory cptHolderSig
    ) internal pure returns (bytes memory) {
        bytes memory empty;
        return abi.encode(
            uint8(RolloverTypes.HookPhase.PREMIUM),
            uint256(0),
            premium,
            destination,
            premiumFor,
            intent,
            uint256(0),
            empty,
            subFiller,
            cptHolderSig
        );
    }

    /// @dev Drive a ROLLOVER fill from `caller` with explicit `subFiller`. Computes the
    ///      Cand-11 cPT-holder sig over `orderDigest` from `orderData` (`orderData.user == cptHolder`).
    function _doRollover10(
        bytes32 orderDigest,
        RolloverTypes.OrderData memory orderData,
        RolloverTypes.RolloverIntent memory intent,
        bytes memory cptHolderSig,
        uint256 fillAmount,
        address caller,
        bytes32 subFiller
    ) internal {
        bytes memory originData = _originData(orderData);
        bytes memory fd = _rolloverFillerData10(fillAmount, caller, subFiller, intent, cptHolderSig);
        vm.prank(caller);
        ISettler(orderData.settler).fill(orderDigest, originData, fd);
    }

    /// @dev Drive a PREMIUM fill from `caller` with explicit `subFiller`.
    function _doPremium10(
        bytes32 orderDigest,
        RolloverTypes.OrderData memory orderData,
        RolloverTypes.RolloverIntent memory intent,
        bytes memory cptHolderSig,
        uint256 premium,
        address caller,
        bytes32 subFiller
    ) internal {
        bytes memory originData = _originData(orderData);
        bytes memory fd =
            _premiumFillerData10(premium, caller, caller, subFiller, intent, cptHolderSig);
        vm.prank(caller);
        ISettler(orderData.settler).fill(orderDigest, originData, fd);
    }

    /// @dev Drive an async ROLLOVER-only fill from `caller` with explicit `subFiller`.
    function _doRolloverOnly10(
        bytes32 orderDigest,
        RolloverTypes.OrderData memory orderData,
        RolloverTypes.RolloverIntent memory intent,
        bytes memory cptHolderSig,
        uint256 fillAmount,
        address caller,
        bytes32 subFiller
    ) internal {
        bytes memory originData = _originData(orderData);
        bytes memory fd =
            _rolloverOnlyFillerData10(fillAmount, caller, subFiller, intent, cptHolderSig);
        vm.prank(caller);
        ISettler(orderData.settler).fill(orderDigest, originData, fd);
    }

    function _hasTopic(Vm.Log[] memory logs, address emitter, bytes32 topic)
        private
        pure
        returns (bool)
    {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == emitter && logs[i].topics.length > 0
                    && logs[i].topics[0] == topic
            ) {
                return true;
            }
        }
        return false;
    }

    function _hasSubFillerTopic(
        Vm.Log[] memory logs,
        address emitter,
        bytes32 topic,
        bytes32 subFiller
    ) private pure returns (bool) {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == emitter && logs[i].topics.length > 3
                    && logs[i].topics[0] == topic && logs[i].topics[3] == subFiller
            ) {
                return true;
            }
        }
        return false;
    }

    // ───────────────────────────────────────────────────────────────────────
    // INV-PARTIAL-SUBFILLER-KEYING
    // ───────────────────────────────────────────────────────────────────────

    /// @notice Three subFiller identities routed through the same `msg.sender == sharedFiller`
    ///         each occupy an independent Settler slot and rolloverContract premium latch.
    function test_threeUsers_sameSharedFiller_allSucceed() public {
        RolloverTypes.OrderData memory orderData = _orderPartial(1);
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(orderData);

        _doRollover10(
            orderDigest,
            orderData,
            intent,
            cptHolderSig,
            CHUNK,
            sharedFiller,
            bytes32(uint256(uint160(alice)))
        );

        _doRollover10(
            orderDigest,
            orderData,
            intent,
            cptHolderSig,
            CHUNK,
            sharedFiller,
            bytes32(uint256(uint160(bob)))
        );

        assertEq(
            partialSettler.rolloverAccountingOf(orderDigest).participantSlotCount,
            2,
            "two (filler, subFiller) pairs"
        );
        assertEq(
            uint8(partialSettler.orderStatus(orderDigest)),
            uint8(RolloverTypes.OrderStatus.Opened),
            "under-sized partial fills keep order Opened"
        );
    }

    /// @notice Under atomic-fill, rollover-and-premium are glued in one frame. After the
    ///         first atomic fill on (sharedFiller, alice) the rolloverContract latch is set; a
    ///         second atomic fill on the same msg.sender (with any subFiller) is rejected
    ///         by the rolloverContract premium-fired latch.
    function test_premiumThenRollover_sameSubFiller_revertsAlreadyFired() public {
        RolloverTypes.OrderData memory orderData = _orderPartial(2);
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(orderData);

        bytes32 aliceSF = bytes32(uint256(uint160(alice)));
        _doRollover10(orderDigest, orderData, intent, cptHolderSig, CHUNK, sharedFiller, aliceSF);

        vm.expectRevert(bytes4(keccak256("Settler__PremiumAlreadyFiredRollover()")));
        _doRollover10(orderDigest, orderData, intent, cptHolderSig, CHUNK, sharedFiller, aliceSF);
    }

    /// @notice Direct EOA fill with subFiller=bytes32(0): decoder substitutes msg.sender.
    function test_direct_eoa_subFillerZeroDefault_succeeds() public {
        RolloverTypes.OrderData memory orderData = _orderPartial(3);
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(orderData);

        _doRollover10(orderDigest, orderData, intent, cptHolderSig, CHUNK, alice, bytes32(0));

        // The implicit subFiller is bytes32(alice). The slot accounting at
        // (orderDigest, alice, bytes32(alice)) should report the production.
        bytes32 aliceSF = bytes32(uint256(uint160(alice)));
        uint256 produced =
            partialSettler.fillerSlotAccountingOf(orderDigest, alice, aliceSF).rollover
            .dstCstProduced;
        assertEq(produced, CHUNK, "direct EOA self-keys to bytes32(msg.sender)");
    }

    /// @notice Atomic fill settles only the rollover leg's subFiller slot.
    function test_atomicFill_settlesOnlyRecordedSubFiller() public {
        RolloverTypes.OrderData memory orderData = _orderPartial(4);
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(orderData);

        bytes32 aliceSF = bytes32(uint256(uint160(alice)));
        bytes32 bobSF = bytes32(uint256(uint160(bob)));

        // Under atomic-fill the atomic envelope pays premium and settles in-frame.
        _doRollover10(orderDigest, orderData, intent, cptHolderSig, CHUNK, sharedFiller, aliceSF);

        // Atomic-fill: alice's slot is already settled; explicit settle is unnecessary but
        // the (sharedFiller, aliceSF) lens already reflects settled state.
        assertTrue(
            partialSettler.fillerSlotAccountingOf(orderDigest, sharedFiller, aliceSF).settled
        );
        assertFalse(partialSettler.fillerSlotAccountingOf(orderDigest, sharedFiller, bobSF).settled);
    }

    /// @notice Under atomic-fill each partial fill auto-settles its (msg.sender,
    ///         subFiller) slot. The order remains fillable until aggregate consumed
    ///         srcCST reaches `orderSize`; participantCount tracks distinct slots.
    function test_participantCount_uniquePairs() public {
        RolloverTypes.OrderData memory orderData = _orderPartial(6);
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(orderData);

        _doRollover10(
            orderDigest,
            orderData,
            intent,
            cptHolderSig,
            CHUNK / 3,
            sharedFiller,
            bytes32(uint256(uint160(alice)))
        );

        _doRollover10(orderDigest, orderData, intent, cptHolderSig, CHUNK / 3, alice, bytes32(0));

        assertEq(partialSettler.rolloverAccountingOf(orderDigest).participantSlotCount, 2);
        assertEq(
            uint8(partialSettler.orderStatus(orderDigest)), uint8(RolloverTypes.OrderStatus.Opened)
        );
    }

    /// @notice L-03: partial shared-filler rollover telemetry must preserve the legacy
    ///         RolloverContract events and also emit enriched events keyed by `subFiller`.
    function test_L03_partialRolloverTelemetry_includesSubFillerWithoutBreakingLegacyEvents()
        public
    {
        RolloverTypes.OrderData memory orderData = _orderPartial(7);
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(orderData);
        bytes32 aliceSF = bytes32(uint256(uint160(alice)));

        vm.recordLogs();
        _doRollover10(orderDigest, orderData, intent, cptHolderSig, CHUNK, sharedFiller, aliceSF);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(
            _hasTopic(logs, rolloverContract, ROLLOVER_LEG_SETTLED_TOPIC),
            "legacy RolloverLegSettled remains emitted"
        );
        assertTrue(
            _hasTopic(logs, rolloverContract, INTENT_PHASE_FIRED_TOPIC),
            "legacy IntentPhaseFired remains emitted"
        );
        assertTrue(
            _hasSubFillerTopic(
                logs, rolloverContract, ROLLOVER_LEG_SETTLED_WITH_SUBFILLER_TOPIC, aliceSF
            ),
            "enriched rollover telemetry includes subFiller"
        );
        assertTrue(
            _hasSubFillerTopic(
                logs, rolloverContract, INTENT_PHASE_FIRED_WITH_SUBFILLER_TOPIC, aliceSF
            ),
            "enriched phase telemetry includes subFiller"
        );
    }

    /// @notice L-03: partial reclaim telemetry must preserve the legacy reclaim event and
    ///         also emit an enriched event keyed by the reclaimed `subFiller` slot.
    function test_L03_partialReclaimTelemetry_includesSubFillerWithoutBreakingLegacyEvent() public {
        RolloverTypes.OrderData memory orderData = _orderPartial(8);
        orderData.premiumPaymentMode = RolloverTypes.PREMIUM_PAYMENT_MODE_ATOMIC_OR_SEPARATE;
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(orderData);
        bytes32 aliceSF = bytes32(uint256(uint160(alice)));

        _doRolloverOnly10(
            orderDigest, orderData, intent, cptHolderSig, CHUNK, sharedFiller, aliceSF
        );

        vm.warp(orderData.fillDeadline + 1);
        vm.recordLogs();
        ISettler(orderData.settler)
            .reclaim(orderDigest, sharedFiller, aliceSF, _originData(orderData));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(
            _hasTopic(logs, address(partialSettler), DEFAULTER_RESIDUAL_RECLAIMED_TOPIC),
            "legacy DefaulterResidualReclaimed remains emitted"
        );
        assertTrue(
            _hasSubFillerTopic(
                logs,
                address(partialSettler),
                DEFAULTER_RESIDUAL_RECLAIMED_WITH_SUBFILLER_TOPIC,
                aliceSF
            ),
            "enriched reclaim telemetry includes subFiller"
        );
    }

    // ───────────────────────────────────────────────────────────────────────
    // FILLER_AUTH typehash binds subFiller
    // ───────────────────────────────────────────────────────────────────────

    /// @notice FillerAuth typehash includes the subFiller dimension.
    function test_fillerAuthTypehash_includesSubFiller() public pure {
        bytes32 expected =
            keccak256("FillerAuth(bytes32 orderDigest,address destination,bytes32 subFiller)");
        assertEq(Typehashes.FILLER_AUTH_TYPEHASH, expected, "typehash extended");
    }

    /// @notice Regression: exact-mode fill with subFiller=bytes32(0) succeeds with no
    ///         observable behaviour change.
    function test_exactMode_unaffected_by_subFillerField() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER_SIZE;
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(orderData);

        // Exact mode happy path via FillScaffold's current atomic payload encoder.
        _doRolloverAs(orderDigest, orderData, intent, ORDER_SIZE, filler);
        assertEq(settler.rolloverAccountingOf(orderDigest).dstCstProduced, ORDER_SIZE);
    }
}
