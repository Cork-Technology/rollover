// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { FillScaffold } from "../../base/FillScaffold.sol";
import { Vm } from "forge-std/Vm.sol";
import { CorkRolloverContract } from "src/CorkRolloverContract.sol";
import { IRolloverContractLens } from "src/interfaces/rollover/IRolloverContractLens.sol";
import { LibAtomicFill } from "src/libraries/LibAtomicFill.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice Regression pins for `CorkRolloverContract.PremiumFired` ABI and indexed `subFiller` (topic3).
///         Fails if the event drops `subFiller`, emits the wrong value, or mis-indexes topics.
contract PremiumFiredEventTest is FillScaffold {
    /// @notice Exact-order fill amount.
    uint256 internal constant FILL = 1_000e18;
    /// @notice Destination amount in the rollover intent.
    uint256 internal constant DST = 1_000e18;
    /// @notice Partial-fill chunk size for shared-filler scenarios.
    uint256 internal constant CHUNK = 333e18;
    /// @notice Generic hook phase completion selector.
    bytes32 internal constant HOOK_PHASE_EXECUTED_TOPIC =
        keccak256("HookPhaseExecuted(bytes32,uint8)");

    /// @notice Routed premium beneficiary for partial shared-filler tests.
    address internal alice = address(0xA11CE);
    /// @notice Filler account that fills on behalf of `alice`.
    address internal sharedFiller = address(0x5AED);

    /// @notice Mirror of `CorkRolloverContract.PremiumFired` for `vm.expectEmit` assertions.
    /// @param orderDigest Order digest for the premium leg.
    /// @param filler Filler that paid premium.
    /// @param subFiller Resolved or routed sub-filler key (indexed topic3).
    /// @param premium Premium amount pulled.
    event PremiumFired(
        bytes32 indexed orderDigest,
        address indexed filler,
        bytes32 indexed subFiller,
        uint256 premium
    );

    function _lens() internal view returns (IRolloverContractLens) {
        return IRolloverContractLens(address(factory));
    }

    function _resolvedSelfKey(address account) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(account)));
    }

    function _hasHookPhaseExecuted(
        Vm.Log[] memory logs,
        bytes32 orderDigest,
        RolloverTypes.HookPhase phase
    ) internal view returns (bool) {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == rolloverContract && logs[i].topics.length == 2
                    && logs[i].topics[0] == HOOK_PHASE_EXECUTED_TOPIC
                    && logs[i].topics[1] == orderDigest
                    && abi.decode(logs[i].data, (uint8)) == uint8(phase)
            ) {
                return true;
            }
        }
        return false;
    }

    function _prepareExactOrder(uint64 nonce)
        internal
        returns (
            bytes32 orderDigest,
            RolloverTypes.OrderData memory orderData,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        )
    {
        orderData = _baseOrder();
        orderData.orderSalt = nonce;
        orderData.allowPartialFills = false;
        orderData.orderSize = FILL;
        intent = _buildIntent(bytes32(0), FILL, DST);
        orderData.rolloverIntentHash = _zeroDigestHash(intent);
        orderDigest = _openOrder(orderData);
        intent.orderDigest = orderDigest;
        cptHolderSig = _signOrder(cptHolderPk, orderData);
    }

    function _preparePartialOrder(uint64 nonce)
        internal
        returns (
            bytes32 orderDigest,
            RolloverTypes.OrderData memory orderData,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        )
    {
        orderData = _baseOrder();
        orderData = _usePartialSettler(orderData);
        orderData.orderSalt = nonce;
        orderData.orderSize = FILL;
        intent = _buildIntent(bytes32(0), FILL, DST);
        orderData.rolloverIntentHash = _zeroDigestHash(intent);
        orderDigest = _openOrder(orderData);
        intent.orderDigest = orderDigest;
        cptHolderSig = _signOrder(cptHolderPk, orderData);
    }

    function _fundSharedFiller() internal {
        srcCst.mint(sharedFiller, 1_000_000e18);
        premiumToken.mint(sharedFiller, 1_000_000e18);
        vm.startPrank(sharedFiller);
        srcCst.approve(address(partialSettler), type(uint256).max);
        premiumToken.approve(address(partialSettler), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice Direct exact atomic fill: wire `subFiller == 0`; event topic3 is the resolved self-key.
    function test_exactDirect_emitsPremiumFired_withResolvedSubFillerTopic() public {
        (
            bytes32 orderDigest,
            RolloverTypes.OrderData memory orderData,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepareExactOrder(1);

        bytes32 resolvedSubFiller = _resolvedSelfKey(filler);
        uint256 premium = LibAtomicFill.computeRequiredPremium(FILL, orderData.minPremiumPerShare);

        _approveFiller(FILL, premium);

        vm.expectEmit(true, true, true, true, rolloverContract);
        emit PremiumFired(orderDigest, filler, resolvedSubFiller, premium);

        _doAtomicFillAs(
            orderDigest, orderData, intent, FILL, filler, filler, bytes32(0), DEFAULT_PREMIUM_CAP
        );
    }

    /// @notice I-01: generic successful-hook telemetry must include the PREMIUM phase.
    function test_I01_exactDirect_emitsGenericHookPhaseTelemetryForPremium() public {
        (
            bytes32 orderDigest,
            RolloverTypes.OrderData memory orderData,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepareExactOrder(4);

        uint256 premium = LibAtomicFill.computeRequiredPremium(FILL, orderData.minPremiumPerShare);

        _approveFiller(FILL, premium);

        vm.recordLogs();
        _doAtomicFillAs(
            orderDigest, orderData, intent, FILL, filler, filler, bytes32(0), DEFAULT_PREMIUM_CAP
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(
            _hasHookPhaseExecuted(logs, orderDigest, RolloverTypes.HookPhase.PREMIUM),
            "missing HookPhaseExecuted PREMIUM"
        );
    }

    /// @notice Exact fill: rolloverContract latch, factory lens, and event agree on resolved `subFiller`.
    function test_exactDirect_lensCoherence_matchesEventSubFiller() public {
        (
            bytes32 orderDigest,
            RolloverTypes.OrderData memory orderData,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepareExactOrder(2);

        bytes32 resolvedSubFiller = _resolvedSelfKey(filler);
        uint256 premium = LibAtomicFill.computeRequiredPremium(FILL, orderData.minPremiumPerShare);

        _approveFiller(FILL, premium);

        _doAtomicFillAs(
            orderDigest, orderData, intent, FILL, filler, filler, bytes32(0), DEFAULT_PREMIUM_CAP
        );

        assertTrue(
            CorkRolloverContract(rolloverContract)
                .premiumFiredFor(orderDigest, filler, resolvedSubFiller),
            "rolloverContract latch uses resolved subFiller"
        );
        assertTrue(
            _lens().premiumFiredFor(rolloverContract, orderDigest, filler, resolvedSubFiller),
            "factory lens uses resolved subFiller"
        );
        assertFalse(
            CorkRolloverContract(rolloverContract).premiumFiredFor(orderDigest, filler, bytes32(0)),
            "wire-zero is not a latch key"
        );
        assertFalse(
            _lens()
                .premiumFiredFor(
                    rolloverContract,
                    orderDigest,
                    filler,
                    bytes32(uint256(uint160(address(0xBEEF))))
                ),
            "unrelated subFiller remains false"
        );
    }

    /// @notice Partial shared filler: topic3 is the routed subFiller, not wire-zero or filler alone.
    function test_partialSharedFiller_emitsPremiumFired_withRoutedSubFillerTopic() public {
        (
            bytes32 orderDigest,
            RolloverTypes.OrderData memory orderData,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _preparePartialOrder(3);

        bytes32 routedSubFiller = _resolvedSelfKey(alice);
        uint256 premium = LibAtomicFill.computeRequiredPremium(CHUNK, orderData.minPremiumPerShare);

        _fundSharedFiller();

        vm.expectEmit(true, true, true, true, rolloverContract);
        emit PremiumFired(orderDigest, sharedFiller, routedSubFiller, premium);

        _doAtomicFillAs(
            orderDigest,
            orderData,
            intent,
            CHUNK,
            sharedFiller,
            sharedFiller,
            routedSubFiller,
            DEFAULT_PREMIUM_CAP
        );

        assertFalse(
            CorkRolloverContract(rolloverContract)
                .premiumFiredFor(orderDigest, sharedFiller, bytes32(0)),
            "shared filler latch is not keyed by wire-zero"
        );
        assertFalse(
            CorkRolloverContract(rolloverContract)
                .premiumFiredFor(orderDigest, sharedFiller, _resolvedSelfKey(sharedFiller)),
            "shared filler latch is not keyed by filler self-key alone"
        );
        assertTrue(
            _lens().premiumFiredFor(rolloverContract, orderDigest, sharedFiller, routedSubFiller),
            "lens agrees with routed subFiller"
        );
    }
}
