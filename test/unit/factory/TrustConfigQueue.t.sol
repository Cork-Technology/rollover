// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {
    CorkRolloverContractFactory__CallerHasNoRolloverContract,
    CorkRolloverContractFactory__DuplicateAttester,
    CorkRolloverContractFactory__InvalidThreshold,
    CorkRolloverContractFactory__InvalidTrustConfigTimelockDelay,
    CorkRolloverContractFactory__MismatchedApplyArgs,
    CorkRolloverContractFactory__NoQueuedTrustConfig,
    CorkRolloverContractFactory__NoQueuedTrustConfigDelayUpdate,
    CorkRolloverContractFactory__NotTimelock,
    CorkRolloverContractFactory__TooManyAttesters,
    CorkRolloverContractFactory__UnexpectedTrustConfigRelay,
    CorkRolloverContractFactory__UnsortedAttesters,
    CorkRolloverContractFactory__ZeroAddress
} from "src/errors/CorkRolloverContractFactoryErrors.sol";

import { BaseTest } from "../../base/BaseTest.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { Vm } from "forge-std/Vm.sol";
import { CorkRolloverContractFactory } from "src/CorkRolloverContractFactory.sol";
import { ICorkRolloverContract } from "src/interfaces/rollover/ICorkRolloverContract.sol";

/// @notice TrustConfigQueueTest — pins the external per-rolloverContract trust-config timelock flow
///         (queue / apply / cancel / pendingTrustConfig).
contract TrustConfigQueueTest is BaseTest {
    /// @notice Trust-config window configured on the test timelock.
    uint256 internal constant DELAY = 1 hours;

    /// @notice Mirror of `CorkRolloverContractFactory.TrustConfigQueued` for log counting / `expectEmit`.
    /// @param rolloverContract Target rolloverContract.
    /// @param opId Timelock operation id.
    /// @param threshold Queued trust threshold.
    /// @param attesters Queued attester list.
    /// @param effectiveAt Earliest apply timestamp.
    event TrustConfigQueued(
        address indexed rolloverContract,
        bytes32 indexed opId,
        uint8 threshold,
        address[] attesters,
        uint64 effectiveAt
    );

    /// @notice Mirror of `CorkRolloverContractFactory.TrustConfigCanceled` for log counting / `expectEmit`.
    /// @param rolloverContract Target rolloverContract.
    /// @param opId Timelock operation id that was cancelled.
    /// @param canceler Account that cancelled the op.
    event TrustConfigCanceled(
        address indexed rolloverContract, bytes32 indexed opId, address indexed canceler
    );

    /// @notice Mirror of `CorkRolloverContractFactory.TrustConfigApplied` for `expectEmit`.
    /// @param rolloverContract Target rolloverContract.
    /// @param opId Timelock operation id that was applied.
    /// @param threshold Applied trust threshold.
    /// @param attesters Applied attester list.
    event TrustConfigApplied(
        address indexed rolloverContract, bytes32 indexed opId, uint8 threshold, address[] attesters
    );

    /// @notice Mirror of `CorkRolloverContractFactory.TrustConfigDelayUpdateQueued`.
    /// @param opId Timelock operation id.
    /// @param newDelay Queued replacement delay.
    /// @param effectiveAt Earliest apply timestamp.
    event TrustConfigDelayUpdateQueued(bytes32 indexed opId, uint256 newDelay, uint64 effectiveAt);

    /// @notice Mirror of `CorkRolloverContractFactory.TrustConfigDelayUpdateCanceled`.
    /// @param opId Timelock operation id that was cancelled.
    /// @param canceler Account that cancelled the op.
    event TrustConfigDelayUpdateCanceled(bytes32 indexed opId, address indexed canceler);

    /// @notice Mirror of `CorkRolloverContractFactory.TrustConfigDelayUpdateApplied`.
    /// @param opId Timelock operation id that was applied.
    /// @param newDelay Newly live delay.
    event TrustConfigDelayUpdateApplied(bytes32 indexed opId, uint256 newDelay);

    /// @notice Build a 1-element attester list.
    /// @param a Sole attester address.
    /// @return out Memory list `[a]`.
    function _singleton(address a) internal pure returns (address[] memory out) {
        out = new address[](1);
        out[0] = a;
    }

    /// @notice Build a 2-element attester list.
    /// @param a First attester address.
    /// @param b Second attester address.
    /// @return out Memory list `[a, b]`.
    function _pair(address a, address b) internal pure returns (address[] memory out) {
        out = new address[](2);
        out[0] = a;
        out[1] = b;
    }

    function _uniqueAttesters(uint256 n) internal pure returns (address[] memory out) {
        out = new address[](n);
        uint256 baseKey = 0x3000;
        for (uint256 i = 0; i < n; ++i) {
            // Strictly ascending + unique + nonzero, as ERC-7484 / Rhinestone require.
            out[i] = address(uint160(baseKey + i + 1));
        }
    }

    function _setFactoryDefaults(uint8 threshold, address[] memory attesters) internal {
        factory.setDefaults(threshold, attesters, address(erc7484));
    }

    /// @notice Unauthorized callers cannot queue delay updates.
    function test_queueTrustConfigDelayUpdate_revertsForUnauthorizedCaller() public {
        bytes32 role = factory.TRUST_CONFIG_DELAY_MANAGER_ROLE();
        vm.prank(anyone);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, anyone, role
            )
        );
        factory.queueTrustConfigDelayUpdate(2 hours);
    }

    /// @notice Unauthorized callers cannot cancel delay updates.
    function test_cancelTrustConfigDelayUpdate_revertsForUnauthorizedCaller() public {
        factory.queueTrustConfigDelayUpdate(2 hours);

        bytes32 role = factory.TRUST_CONFIG_DELAY_MANAGER_ROLE();
        vm.prank(anyone);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, anyone, role
            )
        );
        factory.cancelTrustConfigDelayUpdate();
    }

    /// @notice Delay manager can queue, cancel, replace, and apply delay updates.
    function test_delayManagerCanQueueCancelReplaceAndApplyDelayUpdate() public {
        bytes32 firstOpId = _delayUpdateOpId(2 hours, 0);
        vm.expectEmit(true, true, true, true, address(factory));
        // DELAY is a small test constant, so the uint64 cast cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        emit TrustConfigDelayUpdateQueued(firstOpId, 2 hours, uint64(block.timestamp + DELAY));
        factory.queueTrustConfigDelayUpdate(2 hours);

        (bool queued, uint256 newDelay, uint64 effectiveAt) =
            factory.pendingTrustConfigDelayUpdate();
        assertTrue(queued, "delay update queued");
        assertEq(newDelay, 2 hours, "queued delay");
        // DELAY is a small test constant, so the uint64 cast cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(effectiveAt, uint64(block.timestamp + DELAY), "queued effectiveAt");

        vm.expectEmit(true, true, true, true, address(factory));
        emit TrustConfigDelayUpdateCanceled(firstOpId, address(this));
        factory.cancelTrustConfigDelayUpdate();

        (queued, newDelay, effectiveAt) = factory.pendingTrustConfigDelayUpdate();
        assertFalse(queued, "delay update cleared");
        assertEq(newDelay, 0, "cleared delay");
        assertEq(effectiveAt, 0, "cleared effectiveAt");
        assertEq(trustConfigTimelock.getTimestamp(firstOpId), 0, "timelock op canceled");

        bytes32 secondOpId = _delayUpdateOpId(30 minutes, 1);
        factory.queueTrustConfigDelayUpdate(30 minutes);

        vm.warp(block.timestamp + 10 minutes);
        bytes32 thirdOpId = _delayUpdateOpId(3 hours, 2);
        vm.expectEmit(true, true, true, true, address(factory));
        emit TrustConfigDelayUpdateCanceled(secondOpId, address(this));
        factory.queueTrustConfigDelayUpdate(3 hours);

        (queued, newDelay, effectiveAt) = factory.pendingTrustConfigDelayUpdate();
        assertTrue(queued, "replacement queued");
        assertEq(newDelay, 3 hours, "replacement delay");
        // DELAY is a small test constant, so the uint64 cast cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(effectiveAt, uint64(block.timestamp + DELAY), "replacement effectiveAt");
        assertEq(trustConfigTimelock.getTimestamp(secondOpId), 0, "replaced op canceled");

        vm.warp(block.timestamp + DELAY);
        vm.expectEmit(true, true, true, true, address(factory));
        emit TrustConfigDelayUpdateApplied(thirdOpId, 3 hours);
        factory.applyTrustConfigDelayUpdate();

        assertEq(trustConfigTimelock.getMinDelay(), 3 hours, "delay updated");
        (queued, newDelay, effectiveAt) = factory.pendingTrustConfigDelayUpdate();
        assertFalse(queued, "pending cleared after apply");
        assertEq(newDelay, 0, "pending delay cleared after apply");
        assertEq(effectiveAt, 0, "pending timestamp cleared after apply");
    }

    /// @notice Queued zero-delay updates remain visibly queued despite `newDelay == 0`.
    function test_pendingTrustConfigDelayUpdate_returnsQueuedZeroDelay() public {
        factory.queueTrustConfigDelayUpdate(0);

        (bool queued, uint256 newDelay, uint64 effectiveAt) =
            factory.pendingTrustConfigDelayUpdate();
        assertTrue(queued, "zero delay update queued");
        assertEq(newDelay, 0, "queued delay is zero");
        // DELAY is a small test constant, so the uint64 cast cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(effectiveAt, uint64(block.timestamp + DELAY), "queued zero delay effectiveAt");
    }

    /// @notice Delay manager cancel recovers the mirror after an external canceller unsets the op.
    function test_cancelTrustConfigDelayUpdate_recoversAfterExternalTimelockCancel() public {
        address extraCanceller = makeAddr("extra-delay-canceller");
        factory.queueTrustConfigDelayUpdate(2 hours);

        bytes32 firstOpId = _delayUpdateOpId(2 hours, 0);
        _grantExtraCanceller(extraCanceller);
        vm.prank(extraCanceller);
        trustConfigTimelock.cancel(firstOpId);

        (bool queued, uint256 newDelay, uint64 effectiveAt) =
            factory.pendingTrustConfigDelayUpdate();
        assertTrue(queued, "factory mirror remains before manager cleanup");
        assertEq(newDelay, 2 hours, "factory mirror delay remains before cleanup");
        assertEq(effectiveAt, 0, "external cancel unsets timelock timestamp");

        vm.expectEmit(true, true, true, true, address(factory));
        emit TrustConfigDelayUpdateCanceled(firstOpId, address(this));
        factory.cancelTrustConfigDelayUpdate();

        (queued, newDelay, effectiveAt) = factory.pendingTrustConfigDelayUpdate();
        assertFalse(queued, "mirror cleared after manager cleanup");
        assertEq(newDelay, 0, "delay cleared after manager cleanup");
        assertEq(effectiveAt, 0, "effectiveAt cleared after manager cleanup");

        bytes32 secondOpId = _delayUpdateOpId(3 hours, 1);
        factory.queueTrustConfigDelayUpdate(3 hours);
        assertGt(trustConfigTimelock.getTimestamp(secondOpId), 0, "fresh delay update requeued");
    }

    /// @notice Requeueing a delay update cancels the old op; only the new op can apply.
    function test_requeueTrustConfigDelayUpdate_cancelsOldOpAndAppliesNewOp() public {
        factory.queueTrustConfigDelayUpdate(2 hours);
        bytes32 oldSalt = _delayUpdateSalt(0);
        bytes memory oldData = _delayUpdateData(2 hours);
        bytes32 oldOpId = _delayUpdateOpId(2 hours, 0);

        factory.queueTrustConfigDelayUpdate(3 hours);
        assertEq(trustConfigTimelock.getTimestamp(oldOpId), 0, "old delay op canceled");

        vm.warp(block.timestamp + DELAY);
        vm.prank(address(factory));
        vm.expectPartialRevert(TimelockController.TimelockUnexpectedOperationState.selector);
        trustConfigTimelock.execute(address(trustConfigTimelock), 0, oldData, bytes32(0), oldSalt);

        factory.applyTrustConfigDelayUpdate();
        assertEq(trustConfigTimelock.getMinDelay(), 3 hours, "new delay op applied");
    }

    /// @notice Factory-only executor wiring blocks direct delay execution by non-Factory callers.
    function test_directTrustConfigDelayUpdateExecuteRevertsButCanonicalApplySucceeds() public {
        factory.queueTrustConfigDelayUpdate(2 hours);
        bytes32 salt = _delayUpdateSalt(0);
        bytes memory data = _delayUpdateData(2 hours);

        vm.warp(block.timestamp + DELAY);
        vm.prank(anyone);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        trustConfigTimelock.execute(address(trustConfigTimelock), 0, data, bytes32(0), salt);

        factory.applyTrustConfigDelayUpdate();
        assertEq(trustConfigTimelock.getMinDelay(), 2 hours, "canonical apply updates delay");
    }

    /// @notice Applying a delay update before the configured delay reverts at the timelock.
    function test_applyTrustConfigDelayUpdate_revertsBeforeDelay() public {
        factory.queueTrustConfigDelayUpdate(2 hours);
        vm.warp(block.timestamp + DELAY - 1);
        vm.expectPartialRevert(TimelockController.TimelockUnexpectedOperationState.selector);
        factory.applyTrustConfigDelayUpdate();
    }

    /// @notice Applying a delay update with nothing queued reverts before timelock execution.
    function test_applyTrustConfigDelayUpdate_revertsWhenNothingQueued() public {
        vm.expectRevert(CorkRolloverContractFactory__NoQueuedTrustConfigDelayUpdate.selector);
        factory.applyTrustConfigDelayUpdate();
    }

    /// @notice Queueing a delay above `MAX_TRUST_CONFIG_DELAY` reverts at queue time.
    function test_queueTrustConfigDelayUpdate_revertsWhenNewDelayAboveMax() public {
        uint256 maxDelay = factory.MAX_TRUST_CONFIG_DELAY();
        vm.expectRevert(CorkRolloverContractFactory__InvalidTrustConfigTimelockDelay.selector);
        factory.queueTrustConfigDelayUpdate(maxDelay + 1);
    }

    /// @notice Delay recovery can queue a bounded decrease even when the live delay is above policy.
    function test_queueTrustConfigDelayUpdate_succeedsWhenCurrentDelayAboveMax() public {
        uint256 aboveMaxDelay = factory.MAX_TRUST_CONFIG_DELAY() + 1;
        _forceTrustConfigTimelockDelay(aboveMaxDelay);

        bytes32 opId = _delayUpdateOpId(1 hours, 0);
        factory.queueTrustConfigDelayUpdate(1 hours);

        (bool queued, uint256 newDelay, uint64 effectiveAt) =
            factory.pendingTrustConfigDelayUpdate();
        assertTrue(queued, "recovery delay update queued");
        assertEq(newDelay, 1 hours, "bounded recovery delay");
        assertEq(
            effectiveAt,
            uint64(block.timestamp) + uint64(aboveMaxDelay),
            "raw live delay schedules recovery"
        );
        assertGt(trustConfigTimelock.getTimestamp(opId), 0, "timelock recovery op queued");
    }

    /// @notice Normal trust-config queues still fail closed when the live delay is above policy.
    function test_queueTrustConfig_revertsWhenCurrentDelayAboveMax() public {
        _forceTrustConfigTimelockDelay(factory.MAX_TRUST_CONFIG_DELAY() + 1);
        address[] memory att = _singleton(address(0xA1));

        vm.prank(cptHolder);
        vm.expectRevert(CorkRolloverContractFactory__InvalidTrustConfigTimelockDelay.selector);
        factory.queueTrustConfig(1, att);
    }

    /// @notice Factory-default trust-config queues still fail closed when the live delay is above policy.
    function test_queueFactoryDefaultTrustConfig_revertsWhenCurrentDelayAboveMax() public {
        _forceTrustConfigTimelockDelay(factory.MAX_TRUST_CONFIG_DELAY() + 1);

        vm.prank(cptHolder);
        vm.expectRevert(CorkRolloverContractFactory__InvalidTrustConfigTimelockDelay.selector);
        factory.queueFactoryDefaultTrustConfig();
    }

    /// @notice Delay updates affect future trust-config queues, not already scheduled ops.
    function test_delayUpdateAffectsFutureTrustConfigQueuesOnly() public {
        address[] memory first = _singleton(address(0xA111));
        vm.prank(cptHolder);
        factory.queueTrustConfig(1, first);
        (,, uint64 firstEffectiveAt) = factory.pendingTrustConfig(rolloverContract);
        // DELAY is a small test constant, so the uint64 cast cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(firstEffectiveAt, uint64(block.timestamp + DELAY), "first queue uses old delay");

        factory.queueTrustConfigDelayUpdate(2 hours);
        vm.warp(block.timestamp + DELAY);
        factory.applyTrustConfigDelayUpdate();

        (,, uint64 stillFirstEffectiveAt) = factory.pendingTrustConfig(rolloverContract);
        assertEq(stillFirstEffectiveAt, firstEffectiveAt, "existing op timestamp unchanged");
        factory.applyTrustConfig(rolloverContract);

        address[] memory second = _singleton(address(0xA222));
        vm.prank(cptHolder);
        factory.queueTrustConfig(1, second);
        (,, uint64 secondEffectiveAt) = factory.pendingTrustConfig(rolloverContract);
        assertEq(
            secondEffectiveAt, uint64(block.timestamp + 2 hours), "future queue uses new delay"
        );
    }

    /// @notice Setting the trust-config timelock delay to zero works for future queues.
    function test_setTrustConfigDelayToZeroWorksForFutureQueues() public {
        factory.queueTrustConfigDelayUpdate(0);
        vm.warp(block.timestamp + DELAY);
        factory.applyTrustConfigDelayUpdate();
        assertEq(trustConfigTimelock.getMinDelay(), 0, "delay set to zero");

        address[] memory att = _singleton(address(0xA0A0));
        vm.prank(cptHolder);
        factory.queueTrustConfig(1, att);

        (,, uint64 effectiveAt) = factory.pendingTrustConfig(rolloverContract);
        assertEq(effectiveAt, uint64(block.timestamp), "zero-delay queue effective now");
        factory.applyTrustConfig(rolloverContract);

        ICorkRolloverContract.RolloverContractTrustSnapshot memory snap =
            ICorkRolloverContract(rolloverContract).rolloverContractSnapshot();
        assertEq(snap.liveTrustAttesters[0], address(0xA0A0), "zero-delay config applied");
    }

    /// @notice Queueing from an address with no factory-deployed rolloverContract reverts.
    function test_queueTrustConfig_revertsForCallerWithNoRolloverContract() public {
        address[] memory att = _singleton(address(0xA1));
        vm.prank(anyone);
        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContractFactory__CallerHasNoRolloverContract.selector, anyone
            )
        );
        factory.queueTrustConfig(1, att);
    }

    /// @notice Owner can queue the current factory defaults without supplying config params.
    function test_queueFactoryDefaultTrustConfig_ownerCanQueueCurrentDefaults() public {
        vm.prank(cptHolder);
        factory.queueFactoryDefaultTrustConfig();

        (uint8 t, address[] memory atts, uint64 eff) = factory.pendingTrustConfig(rolloverContract);
        assertEq(t, 1, "default threshold queued");
        assertEq(atts.length, 1, "default attester length queued");
        assertEq(atts[0], defaultAttester, "default attester queued");
        // DELAY is a small test constant, so the uint64 cast cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(eff, uint64(block.timestamp) + uint64(DELAY), "default queue delay");
    }

    /// @notice Default-path queueing from an address with no factory-deployed rolloverContract reverts.
    function test_queueFactoryDefaultTrustConfig_revertsForCallerWithNoRolloverContract() public {
        vm.prank(anyone);
        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContractFactory__CallerHasNoRolloverContract.selector, anyone
            )
        );
        factory.queueFactoryDefaultTrustConfig();
    }

    /// @notice The default path queues the factory defaults that are live at queue time.
    function test_queueFactoryDefaultTrustConfig_queuesCurrentFactoryDefaults() public {
        address[] memory defaults = _pair(address(0xD01), address(0xD02));
        _setFactoryDefaults(2, defaults);

        vm.prank(cptHolder);
        factory.queueFactoryDefaultTrustConfig();

        (uint8 t, address[] memory atts,) = factory.pendingTrustConfig(rolloverContract);
        assertEq(t, 2, "queued default threshold");
        assertEq(atts.length, 2, "queued default attester length");
        assertEq(atts[0], address(0xD01), "queued default attester[0]");
        assertEq(atts[1], address(0xD02), "queued default attester[1]");
    }

    /// @notice Applying a default-queued config writes those defaults to the rolloverContract.
    function test_applyTrustConfig_appliesFactoryDefaultQueuedConfig() public {
        address[] memory defaults = _pair(address(0xD11), address(0xD12));
        _setFactoryDefaults(2, defaults);

        vm.prank(cptHolder);
        factory.queueFactoryDefaultTrustConfig();
        bytes32 opId = _trustOpId(rolloverContract, 2, defaults, 0);
        vm.warp(block.timestamp + DELAY);

        vm.expectEmit(true, true, true, true, address(factory));
        emit TrustConfigApplied(rolloverContract, opId, 2, defaults);
        factory.applyTrustConfig(rolloverContract);

        ICorkRolloverContract.RolloverContractTrustSnapshot memory snap =
            ICorkRolloverContract(rolloverContract).rolloverContractSnapshot();
        assertEq(snap.liveTrustThreshold, 2, "default threshold applied");
        assertEq(snap.liveTrustAttesters.length, 2, "default attester length applied");
        assertEq(snap.liveTrustAttesters[0], address(0xD11), "default attester[0] applied");
        assertEq(snap.liveTrustAttesters[1], address(0xD12), "default attester[1] applied");
        assertEq(erc7484.lastThreshold(rolloverContract), 2, "registry default threshold");
        assertEq(
            erc7484.attestersOf(rolloverContract)[1], address(0xD12), "registry default attester"
        );
    }

    /// @notice Default-path requeue cancels and replaces an existing custom pending config.
    function test_queueFactoryDefaultTrustConfig_replacesExistingCustomPendingConfig() public {
        address[] memory custom = _singleton(address(0xC01));
        vm.prank(cptHolder);
        factory.queueTrustConfig(1, custom);
        bytes32 priorOpId = _trustOpId(rolloverContract, 1, custom, 0);

        address[] memory defaults = _pair(address(0xD21), address(0xD22));
        _setFactoryDefaults(2, defaults);

        vm.expectEmit(true, true, true, true, address(factory));
        emit TrustConfigCanceled(rolloverContract, priorOpId, cptHolder);
        vm.prank(cptHolder);
        factory.queueFactoryDefaultTrustConfig();

        (uint8 t, address[] memory atts,) = factory.pendingTrustConfig(rolloverContract);
        assertEq(t, 2, "default replacement threshold");
        assertEq(atts.length, 2, "default replacement length");
        assertEq(atts[0], address(0xD21), "default replacement attester[0]");
        assertEq(atts[1], address(0xD22), "default replacement attester[1]");
    }

    /// @notice Custom queueing can replace an existing default-path pending config.
    function test_queueTrustConfig_replacesExistingFactoryDefaultPendingConfig() public {
        address[] memory defaults = _pair(address(0xD31), address(0xD32));
        _setFactoryDefaults(2, defaults);
        vm.prank(cptHolder);
        factory.queueFactoryDefaultTrustConfig();
        bytes32 priorOpId = _trustOpId(rolloverContract, 2, defaults, 0);

        address[] memory custom = _singleton(address(0xC31));
        vm.expectEmit(true, true, true, true, address(factory));
        emit TrustConfigCanceled(rolloverContract, priorOpId, cptHolder);
        vm.prank(cptHolder);
        factory.queueTrustConfig(1, custom);

        (uint8 t, address[] memory atts,) = factory.pendingTrustConfig(rolloverContract);
        assertEq(t, 1, "custom replacement threshold");
        assertEq(atts.length, 1, "custom replacement length");
        assertEq(atts[0], address(0xC31), "custom replacement attester");
    }

    /// @notice Default-path queueing snapshots defaults; later defaults changes do not alter it.
    function test_queueFactoryDefaultTrustConfig_snapshotsDefaultsAtQueueTime() public {
        address[] memory queuedDefaults = _pair(address(0xD41), address(0xD42));
        _setFactoryDefaults(2, queuedDefaults);
        vm.prank(cptHolder);
        factory.queueFactoryDefaultTrustConfig();

        address[] memory laterDefaults = _singleton(address(0xD43));
        _setFactoryDefaults(1, laterDefaults);

        (uint8 t, address[] memory atts,) = factory.pendingTrustConfig(rolloverContract);
        assertEq(t, 2, "snapshot threshold remains queued");
        assertEq(atts.length, 2, "snapshot attester length remains queued");
        assertEq(atts[0], address(0xD41), "snapshot attester[0] remains queued");
        assertEq(atts[1], address(0xD42), "snapshot attester[1] remains queued");

        vm.warp(block.timestamp + DELAY);
        factory.applyTrustConfig(rolloverContract);

        ICorkRolloverContract.RolloverContractTrustSnapshot memory snap =
            ICorkRolloverContract(rolloverContract).rolloverContractSnapshot();
        assertEq(snap.liveTrustThreshold, 2, "snapshot threshold applied");
        assertEq(snap.liveTrustAttesters.length, 2, "snapshot attester length applied");
        assertEq(snap.liveTrustAttesters[0], address(0xD41), "snapshot attester[0] applied");
        assertEq(snap.liveTrustAttesters[1], address(0xD42), "snapshot attester[1] applied");
    }

    /// @notice Owner cancellation works for a config queued through the default path.
    function test_cancelTrustConfig_cancelsFactoryDefaultQueuedConfig() public {
        address[] memory defaults = _pair(address(0xD51), address(0xD52));
        _setFactoryDefaults(2, defaults);
        vm.prank(cptHolder);
        factory.queueFactoryDefaultTrustConfig();
        bytes32 opId = _trustOpId(rolloverContract, 2, defaults, 0);

        vm.expectEmit(true, true, true, true, address(factory));
        emit TrustConfigCanceled(rolloverContract, opId, cptHolder);
        vm.prank(cptHolder);
        factory.cancelTrustConfig();

        (uint8 t, address[] memory atts, uint64 eff) = factory.pendingTrustConfig(rolloverContract);
        assertEq(t, 0, "default pending threshold cleared");
        assertEq(atts.length, 0, "default pending attesters cleared");
        assertEq(eff, 0, "default pending effectiveAt cleared");
    }

    /// @notice A cPT holder cannot affect another rolloverContract because queueing derives from caller.
    function test_queueFactoryDefaultTrustConfig_ownerCannotAffectAnotherRolloverContractPendingConfig()
        public
    {
        address otherOwner = makeAddr("other-owner");
        vm.prank(otherOwner);
        address otherRolloverContract = factory.deployRolloverContract();

        address[] memory defaults = _pair(address(0xD61), address(0xD62));
        _setFactoryDefaults(2, defaults);
        vm.prank(otherOwner);
        factory.queueFactoryDefaultTrustConfig();

        vm.prank(cptHolder);
        factory.queueFactoryDefaultTrustConfig();

        (uint8 t, address[] memory atts,) = factory.pendingTrustConfig(otherRolloverContract);
        assertEq(t, 2, "other rolloverContract pending threshold unchanged");
        assertEq(atts.length, 2, "other rolloverContract pending length unchanged");
        assertEq(atts[0], address(0xD61), "other rolloverContract pending attester[0] unchanged");
        assertEq(atts[1], address(0xD62), "other rolloverContract pending attester[1] unchanged");
    }

    /// @notice Queue writes `effectiveAt = block.timestamp + DELAY`.
    function test_queueTrustConfig_setsEffectiveAtToMinDelay() public {
        address[] memory att = _singleton(address(0xA1));
        vm.prank(cptHolder);
        factory.queueTrustConfig(1, att);

        (,, uint64 eff) = factory.pendingTrustConfig(rolloverContract);
        // DELAY is a small test constant, so the uint64 cast cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(eff, uint64(block.timestamp) + uint64(DELAY), "effectiveAt = T + DELAY");
    }

    /// @notice First queue emits `TrustConfigQueued` only (no implicit cancel).
    function test_queueTrustConfig_firstQueue_emitsQueuedOnly() public {
        address[] memory att = _singleton(address(0xA1));
        vm.recordLogs();
        vm.prank(cptHolder);
        factory.queueTrustConfig(1, att);

        bytes32 queuedTopic = keccak256("TrustConfigQueued(address,bytes32,uint8,address[],uint64)");
        bytes32 canceledTopic = keccak256("TrustConfigCanceled(address,bytes32,address)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 queued;
        uint256 canceled;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(factory)) {
                continue;
            }
            if (logs[i].topics[0] == queuedTopic) {
                queued++;
            }
            if (logs[i].topics[0] == canceledTopic) {
                canceled++;
            }
        }
        assertEq(queued, 1, "first queue emits TrustConfigQueued");
        assertEq(canceled, 0, "first queue must not emit TrustConfigCanceled");
    }

    /// @notice Re-queueing while a prior op is pending cancels it and restarts the clock.
    function test_queueTrustConfig_overwriteCancelsPriorOp() public {
        address[] memory firstSet = _singleton(address(0xA1));
        vm.prank(cptHolder);
        factory.queueTrustConfig(1, firstSet);

        // First op is currently the lastSalt entry.
        (uint8 t1,,) = factory.pendingTrustConfig(rolloverContract);
        assertEq(t1, 1, "first queue visible");

        bytes32 priorOpId = _trustOpId(rolloverContract, 1, firstSet, 0);

        vm.warp(block.timestamp + 30 minutes);
        address[] memory secondSet = _pair(address(0xB1), address(0xB2));

        vm.recordLogs();
        vm.expectEmit(true, true, true, true, address(factory));
        emit TrustConfigCanceled(rolloverContract, priorOpId, cptHolder);
        vm.prank(cptHolder);
        factory.queueTrustConfig(2, secondSet);

        bytes32 queuedTopic = keccak256("TrustConfigQueued(address,bytes32,uint8,address[],uint64)");
        bytes32 canceledTopic = keccak256("TrustConfigCanceled(address,bytes32,address)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 queued;
        uint256 canceled;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(factory)) {
                continue;
            }
            if (logs[i].topics[0] == queuedTopic) {
                queued++;
            }
            if (logs[i].topics[0] == canceledTopic) {
                canceled++;
            }
        }
        assertEq(canceled, 1, "re-queue emits TrustConfigCanceled for prior op");
        assertEq(queued, 1, "re-queue emits TrustConfigQueued for new op");

        (uint8 t2, address[] memory atts, uint64 eff) = factory.pendingTrustConfig(rolloverContract);
        assertEq(t2, 2, "second queue threshold");
        assertEq(atts.length, 2, "second queue length");
        assertEq(atts[1], address(0xB2), "second queue attester[1]");
        // DELAY is a small test constant, so the uint64 cast cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(eff, uint64(block.timestamp) + uint64(DELAY), "fresh clock on overwrite");
    }

    /// @notice Applying before `effectiveAt` reverts via the timelock.
    function test_applyTrustConfig_revertsBeforeDelay() public {
        address[] memory att = _singleton(address(0xA1));
        vm.prank(cptHolder);
        factory.queueTrustConfig(1, att);
        vm.warp(block.timestamp + DELAY - 1);
        vm.expectPartialRevert(TimelockController.TimelockUnexpectedOperationState.selector);
        factory.applyTrustConfig(rolloverContract);
    }

    /// @notice Applying at `effectiveAt` writes the new live config + registry mirror.
    function test_applyTrustConfig_succeedsAtDelay() public {
        address[] memory att = _singleton(address(0xC1));
        vm.prank(cptHolder);
        factory.queueTrustConfig(1, att);
        bytes32 opId = _trustOpId(rolloverContract, 1, att, 0);
        vm.warp(block.timestamp + DELAY);

        vm.expectEmit(true, true, true, true, address(factory));
        emit TrustConfigApplied(rolloverContract, opId, 1, att);
        factory.applyTrustConfig(rolloverContract);

        ICorkRolloverContract.RolloverContractTrustSnapshot memory snap =
            ICorkRolloverContract(rolloverContract).rolloverContractSnapshot();
        assertEq(snap.liveTrustThreshold, 1, "live threshold applied");
        assertEq(snap.liveTrustAttesters[0], address(0xC1), "live attester applied");
        assertEq(erc7484.lastThreshold(rolloverContract), 1, "registry threshold");
        assertEq(erc7484.attestersOf(rolloverContract)[0], address(0xC1), "registry attester");
    }

    /// @notice After apply, the factory's pending-mirror returns the zero-tuple.
    function test_applyTrustConfig_clearsMirrorStorage() public {
        address[] memory att = _singleton(address(0xD1));
        vm.prank(cptHolder);
        factory.queueTrustConfig(1, att);
        vm.warp(block.timestamp + DELAY);
        factory.applyTrustConfig(rolloverContract);

        (uint8 t, address[] memory a, uint64 eff) = factory.pendingTrustConfig(rolloverContract);
        assertEq(t, 0, "mirror threshold cleared");
        assertEq(a.length, 0, "mirror attesters cleared");
        assertEq(eff, 0, "mirror effectiveAt cleared");
    }

    /// @notice Apply loads threshold and attesters from the pending mirror.
    function test_applyTrustConfig_usesPendingMirror() public {
        address[] memory queued = _singleton(address(0xE1));
        vm.prank(cptHolder);
        factory.queueTrustConfig(1, queued);
        vm.warp(block.timestamp + DELAY);

        factory.applyTrustConfig(rolloverContract);

        ICorkRolloverContract.RolloverContractTrustSnapshot memory snap =
            ICorkRolloverContract(rolloverContract).rolloverContractSnapshot();
        assertEq(snap.liveTrustThreshold, 1, "live threshold from mirror");
        assertEq(snap.liveTrustAttesters[0], address(0xE1), "live attester from mirror");
    }

    /// @notice Apply is permissionless: any address can drive the queued op after delay.
    function test_applyTrustConfig_isPermissionless() public {
        address[] memory att = _singleton(address(0xF1));
        vm.prank(cptHolder);
        factory.queueTrustConfig(1, att);
        vm.warp(block.timestamp + DELAY);

        vm.prank(anyone);
        factory.applyTrustConfig(rolloverContract);

        ICorkRolloverContract.RolloverContractTrustSnapshot memory snap =
            ICorkRolloverContract(rolloverContract).rolloverContractSnapshot();
        assertEq(snap.liveTrustAttesters[0], address(0xF1), "applied by random caller");
    }

    /// @notice Direct relay calls are rejected unless they originate from the trust-config timelock.
    function test_relayTrustConfig_revertsForNonTimelockCaller() public {
        address[] memory att = _singleton(address(0xA1));

        vm.prank(cptHolder);
        vm.expectRevert(
            abi.encodeWithSelector(CorkRolloverContractFactory__NotTimelock.selector, cptHolder)
        );
        factory.relayTrustConfig(rolloverContract, bytes32(0), 1, att);
    }

    /// @notice Timelock-originated relay calls revert when the factory has no matching pending mirror.
    function test_relayTrustConfig_revertsFromTimelockWhenNoPendingConfig() public {
        address[] memory att = _singleton(address(0xA1));
        TimelockController tl = TimelockController(payable(factory.trustConfigTimelock()));
        _grantOpenTimelockAccess(tl);

        bytes32 salt = keccak256("raw-no-pending");
        bytes memory data = abi.encodeWithSelector(
            CorkRolloverContractFactory.relayTrustConfig.selector,
            rolloverContract,
            salt,
            uint8(1),
            att
        );
        vm.prank(anyone);
        tl.schedule(address(factory), 0, data, bytes32(0), salt, DELAY);

        vm.warp(block.timestamp + DELAY);
        vm.prank(anyone);
        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContractFactory__NoQueuedTrustConfig.selector, rolloverContract
            )
        );
        tl.execute(address(factory), 0, data, bytes32(0), salt);
    }

    /// @notice Timelock-originated relay calls revert when calldata does not match the pending mirror.
    function test_relayTrustConfig_revertsFromTimelockOnMismatchedPendingConfig() public {
        address[] memory queued = _singleton(address(0xA1));
        vm.prank(cptHolder);
        factory.queueTrustConfig(1, queued);

        address[] memory wrong = _singleton(address(0xA2));
        TimelockController tl = TimelockController(payable(factory.trustConfigTimelock()));
        _grantOpenTimelockAccess(tl);

        bytes32 salt = keccak256("raw-mismatch");
        bytes memory data = abi.encodeWithSelector(
            CorkRolloverContractFactory.relayTrustConfig.selector,
            rolloverContract,
            salt,
            uint8(1),
            wrong
        );
        vm.prank(anyone);
        tl.schedule(address(factory), 0, data, bytes32(0), salt, DELAY);

        vm.warp(block.timestamp + DELAY);
        vm.prank(anyone);
        vm.expectPartialRevert(CorkRolloverContractFactory__MismatchedApplyArgs.selector);
        tl.execute(address(factory), 0, data, bytes32(0), salt);
    }

    /// @notice Extra timelock proposers cannot mutate rolloverContract trust without a matching factory queue.
    function test_hostileExtraProposerCannotMutateWithoutMatchingFactoryPendingConfig() public {
        address[] memory hostile = _singleton(address(0xBAD));
        TimelockController tl = TimelockController(payable(factory.trustConfigTimelock()));
        _grantOpenTimelockAccess(tl);

        bytes32 salt = keccak256("hostile");
        bytes memory data = abi.encodeWithSelector(
            CorkRolloverContractFactory.relayTrustConfig.selector,
            rolloverContract,
            salt,
            uint8(1),
            hostile
        );
        vm.prank(anyone);
        tl.schedule(address(factory), 0, data, bytes32(0), salt, DELAY);

        vm.warp(block.timestamp + DELAY);
        vm.prank(anyone);
        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContractFactory__NoQueuedTrustConfig.selector, rolloverContract
            )
        );
        tl.execute(address(factory), 0, data, bytes32(0), salt);

        ICorkRolloverContract.RolloverContractTrustSnapshot memory snap =
            ICorkRolloverContract(rolloverContract).rolloverContractSnapshot();
        assertEq(snap.liveTrustAttesters[0], defaultAttester, "live trust unchanged");
    }

    /// @notice Direct execution of the exact factory-scheduled op fails without `applyTrustConfig`.
    function test_directExecutionOfFactoryScheduledOpRevertsWithoutApplyGuard() public {
        address[] memory att = _singleton(address(0xA11CE));
        vm.prank(cptHolder);
        factory.queueTrustConfig(1, att);
        _grantOpenTimelockAccess(trustConfigTimelock);

        bytes32 salt = _trustSalt(rolloverContract, 0);
        bytes memory data = _trustData(rolloverContract, salt, 1, att);
        bytes32 opId = _trustOpId(rolloverContract, 1, att, 0);

        vm.warp(block.timestamp + DELAY);
        vm.prank(anyone);
        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContractFactory__UnexpectedTrustConfigRelay.selector, bytes32(0), opId
            )
        );
        trustConfigTimelock.execute(address(factory), 0, data, bytes32(0), salt);

        ICorkRolloverContract.RolloverContractTrustSnapshot memory snap =
            ICorkRolloverContract(rolloverContract).rolloverContractSnapshot();
        assertEq(snap.liveTrustAttesters[0], defaultAttester, "live trust unchanged");
    }

    /// @notice Extra proposers cannot execute an exact-match relay with an alternate salt.
    function test_extraProposerExactMatchAlternateSaltDirectExecuteFails() public {
        address[] memory att = _singleton(address(0xB0B));
        vm.prank(cptHolder);
        factory.queueTrustConfig(1, att);

        TimelockController tl = TimelockController(payable(factory.trustConfigTimelock()));
        _grantOpenTimelockAccess(tl);
        bytes32 salt = keccak256("alternate-salt");
        bytes memory data = _trustData(rolloverContract, salt, 1, att);

        vm.prank(anyone);
        tl.schedule(address(factory), 0, data, bytes32(0), salt, DELAY);

        vm.warp(block.timestamp + DELAY);
        vm.prank(anyone);
        vm.expectPartialRevert(CorkRolloverContractFactory__MismatchedApplyArgs.selector);
        tl.execute(address(factory), 0, data, bytes32(0), salt);

        ICorkRolloverContract.RolloverContractTrustSnapshot memory snap =
            ICorkRolloverContract(rolloverContract).rolloverContractSnapshot();
        assertEq(snap.liveTrustAttesters[0], defaultAttester, "live trust unchanged");
    }

    /// @notice A pre-scheduled predicted exact-match relay before owner queue is not executable.
    function test_extraProposerPreSchedulesExactMatchBeforeOwnerQueueDirectExecuteFails() public {
        address[] memory att = _singleton(address(0xC0DE));
        TimelockController tl = TimelockController(payable(factory.trustConfigTimelock()));
        _grantOpenTimelockAccess(tl);

        bytes32 attackerSalt = _trustSalt(rolloverContract, 0);
        bytes memory attackerData = _trustData(rolloverContract, attackerSalt, 1, att);
        vm.prank(anyone);
        tl.schedule(address(factory), 0, attackerData, bytes32(0), attackerSalt, DELAY);

        vm.warp(block.timestamp + 30 minutes);
        vm.prank(cptHolder);
        factory.queueTrustConfig(1, att);

        (,, uint64 eff) = factory.pendingTrustConfig(rolloverContract);
        assertEq(uint256(eff), block.timestamp + DELAY, "owner queue restarts delay");

        vm.warp(block.timestamp + 30 minutes);
        vm.prank(anyone);
        vm.expectPartialRevert(TimelockController.TimelockUnexpectedOperationState.selector);
        tl.execute(address(factory), 0, attackerData, bytes32(0), attackerSalt);

        vm.warp(block.timestamp + 30 minutes);
        vm.prank(anyone);
        factory.applyTrustConfig(rolloverContract);
        ICorkRolloverContract.RolloverContractTrustSnapshot memory snap =
            ICorkRolloverContract(rolloverContract).rolloverContractSnapshot();
        assertEq(snap.liveTrustAttesters[0], address(0xC0DE), "canonical apply succeeds");
    }

    /// @notice Cancel from an address with no factory-deployed rolloverContract reverts.
    function test_cancelTrustConfig_revertsForNonOwner() public {
        address[] memory att = _singleton(address(0xA1));
        vm.prank(cptHolder);
        factory.queueTrustConfig(1, att);

        vm.prank(anyone);
        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContractFactory__CallerHasNoRolloverContract.selector, anyone
            )
        );
        factory.cancelTrustConfig();
    }

    /// @notice Cancel clears the factory mirror and the timelock op; re-queue restarts.
    function test_cancelTrustConfig_clearsMirrorAndCancelsTimelock() public {
        address[] memory att = _singleton(address(0xA1));
        vm.prank(cptHolder);
        factory.queueTrustConfig(1, att);

        bytes32 opId = _trustOpId(rolloverContract, 1, att, 0);
        vm.expectEmit(true, true, true, true, address(factory));
        emit TrustConfigCanceled(rolloverContract, opId, cptHolder);
        vm.prank(cptHolder);
        factory.cancelTrustConfig();

        (uint8 t, address[] memory a, uint64 eff) = factory.pendingTrustConfig(rolloverContract);
        assertEq(t, 0, "mirror threshold cleared");
        assertEq(a.length, 0, "mirror attesters cleared");
        assertEq(eff, 0, "mirror effectiveAt cleared");

        // Re-queueing after cancel works (fresh clock).
        address[] memory next = _singleton(address(0xB1));
        vm.prank(cptHolder);
        factory.queueTrustConfig(1, next);
        (uint8 t2,,) = factory.pendingTrustConfig(rolloverContract);
        assertEq(t2, 1, "re-queued after cancel");
    }

    /// @notice Owner cancel recovers the factory mirror after an external canceller unsets
    ///         the timelock op directly.
    function test_cancelTrustConfig_recoversAfterExternalTimelockCancel() public {
        address extraCanceller = makeAddr("extra-canceller");
        address[] memory att = _singleton(address(0xA1));
        vm.prank(cptHolder);
        factory.queueTrustConfig(1, att);

        bytes32 opId = _trustOpId(rolloverContract, 1, att, 0);
        _grantExtraCanceller(extraCanceller);
        vm.prank(extraCanceller);
        trustConfigTimelock.cancel(opId);

        (uint8 pendingThreshold, address[] memory pendingAttesters, uint64 effectiveAt) =
            factory.pendingTrustConfig(rolloverContract);
        assertEq(pendingThreshold, 1, "factory mirror remains before owner cleanup");
        assertEq(pendingAttesters.length, 1, "factory mirror attesters remain before cleanup");
        assertEq(pendingAttesters[0], address(0xA1), "factory mirror attester remains");
        assertEq(effectiveAt, 0, "external cancel unsets timelock timestamp");

        vm.expectEmit(true, true, true, true, address(factory));
        emit TrustConfigCanceled(rolloverContract, opId, cptHolder);
        vm.prank(cptHolder);
        factory.cancelTrustConfig();

        (uint8 t, address[] memory atts, uint64 eff) = factory.pendingTrustConfig(rolloverContract);
        assertEq(t, 0, "mirror threshold cleared");
        assertEq(atts.length, 0, "mirror attesters cleared");
        assertEq(eff, 0, "mirror effectiveAt cleared");
    }

    /// @notice Owner requeue recovers after an external direct cancel and schedules the new
    ///         config with a fresh delay.
    function test_queueTrustConfig_recoversAfterExternalTimelockCancel() public {
        address extraCanceller = makeAddr("extra-canceller");
        address[] memory first = _singleton(address(0xA1));
        vm.prank(cptHolder);
        factory.queueTrustConfig(1, first);

        bytes32 firstOpId = _trustOpId(rolloverContract, 1, first, 0);
        _grantExtraCanceller(extraCanceller);
        vm.prank(extraCanceller);
        trustConfigTimelock.cancel(firstOpId);

        vm.warp(block.timestamp + 30 minutes);
        address[] memory second = _pair(address(0xB1), address(0xB2));
        vm.expectEmit(true, true, true, true, address(factory));
        emit TrustConfigCanceled(rolloverContract, firstOpId, cptHolder);
        vm.prank(cptHolder);
        factory.queueTrustConfig(2, second);

        (uint8 t, address[] memory atts, uint64 eff) = factory.pendingTrustConfig(rolloverContract);
        assertEq(t, 2, "second threshold queued");
        assertEq(atts.length, 2, "second attester length queued");
        assertEq(atts[0], address(0xB1), "second attester[0] queued");
        assertEq(atts[1], address(0xB2), "second attester[1] queued");
        // DELAY is a small test constant, so the uint64 cast cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(eff, uint64(block.timestamp) + uint64(DELAY), "fresh delay after requeue");
        assertEq(trustConfigTimelock.getTimestamp(firstOpId), 0, "first op remains unset");
    }

    /// @notice Applying after an external direct cancel fails at the timelock, then owner
    ///         cleanup restores liveness.
    function test_applyTrustConfig_revertsAfterExternalTimelockCancelThenOwnerCanRecover() public {
        address extraCanceller = makeAddr("extra-canceller");
        address[] memory att = _singleton(address(0xA1));
        vm.prank(cptHolder);
        factory.queueTrustConfig(1, att);

        bytes32 opId = _trustOpId(rolloverContract, 1, att, 0);
        _grantExtraCanceller(extraCanceller);
        vm.prank(extraCanceller);
        trustConfigTimelock.cancel(opId);

        vm.expectPartialRevert(TimelockController.TimelockUnexpectedOperationState.selector);
        factory.applyTrustConfig(rolloverContract);

        vm.prank(cptHolder);
        factory.cancelTrustConfig();
        (uint8 t, address[] memory atts, uint64 eff) = factory.pendingTrustConfig(rolloverContract);
        assertEq(t, 0, "mirror threshold cleared after recovery");
        assertEq(atts.length, 0, "mirror attesters cleared after recovery");
        assertEq(eff, 0, "mirror effectiveAt cleared after recovery");
    }

    /// @notice Cancel/requeue leaves old operations unusable and only applies the new rolloverContract op.
    function test_cancelRequeueOldOperationCannotApply() public {
        address[] memory first = _singleton(address(0xAA01));
        vm.prank(cptHolder);
        factory.queueTrustConfig(1, first);
        bytes32 oldSalt = _trustSalt(rolloverContract, 0);
        bytes memory oldData = _trustData(rolloverContract, oldSalt, 1, first);

        vm.prank(cptHolder);
        factory.cancelTrustConfig();

        address[] memory second = _singleton(address(0xAA02));
        vm.prank(cptHolder);
        factory.queueTrustConfig(1, second);
        _grantOpenTimelockAccess(trustConfigTimelock);

        vm.warp(block.timestamp + DELAY);
        vm.prank(anyone);
        vm.expectPartialRevert(TimelockController.TimelockUnexpectedOperationState.selector);
        trustConfigTimelock.execute(address(factory), 0, oldData, bytes32(0), oldSalt);

        factory.applyTrustConfig(rolloverContract);
        ICorkRolloverContract.RolloverContractTrustSnapshot memory snap =
            ICorkRolloverContract(rolloverContract).rolloverContractSnapshot();
        assertEq(snap.liveTrustAttesters[0], address(0xAA02), "new queue applied");
    }

    /// @notice Requeueing the same config resets delay and the stale op cannot apply early.
    function test_requeueSameConfigResetsDelayAndStaleOpCannotApplyEarly() public {
        address[] memory att = _singleton(address(0x5151));
        vm.prank(cptHolder);
        factory.queueTrustConfig(1, att);

        vm.warp(block.timestamp + 30 minutes);
        bytes32 oldSalt = _trustSalt(rolloverContract, 0);
        bytes memory oldData = _trustData(rolloverContract, oldSalt, 1, att);

        vm.prank(cptHolder);
        factory.queueTrustConfig(1, att);
        _grantOpenTimelockAccess(trustConfigTimelock);

        vm.warp(block.timestamp + 30 minutes);
        vm.prank(anyone);
        vm.expectPartialRevert(TimelockController.TimelockUnexpectedOperationState.selector);
        trustConfigTimelock.execute(address(factory), 0, oldData, bytes32(0), oldSalt);

        vm.expectPartialRevert(TimelockController.TimelockUnexpectedOperationState.selector);
        factory.applyTrustConfig(rolloverContract);

        vm.warp(block.timestamp + 30 minutes);
        factory.applyTrustConfig(rolloverContract);
        ICorkRolloverContract.RolloverContractTrustSnapshot memory snap =
            ICorkRolloverContract(rolloverContract).rolloverContractSnapshot();
        assertEq(snap.liveTrustAttesters[0], address(0x5151), "fresh queue applied");
    }

    /// @notice Queue rejects threshold = 0 at queue time (not at apply time).
    function test_queueTrustConfig_revertsForZeroThreshold() public {
        address[] memory att = _singleton(address(0xA1));
        vm.prank(cptHolder);
        vm.expectRevert(CorkRolloverContractFactory__InvalidThreshold.selector);
        factory.queueTrustConfig(0, att);
    }

    /// @notice Queue rejects an empty attester list at queue time.
    function test_queueTrustConfig_revertsForEmptyAttesterList() public {
        address[] memory empty = new address[](0);
        vm.prank(cptHolder);
        vm.expectRevert(CorkRolloverContractFactory__InvalidThreshold.selector);
        factory.queueTrustConfig(1, empty);
    }

    /// @notice Queue rejects `threshold > attesters.length` at queue time.
    function test_queueTrustConfig_revertsWhenThresholdExceedsListLength() public {
        address[] memory att = _singleton(address(0xA1));
        vm.prank(cptHolder);
        vm.expectRevert(CorkRolloverContractFactory__InvalidThreshold.selector);
        factory.queueTrustConfig(2, att);
    }

    /// @notice Queue rejects a zero-address attester at queue time.
    function test_queueTrustConfig_revertsForZeroAddressAttester() public {
        address[] memory att = _pair(address(0xA1), address(0));
        vm.prank(cptHolder);
        vm.expectRevert(CorkRolloverContractFactory__ZeroAddress.selector);
        factory.queueTrustConfig(1, att);
    }

    /// @notice Queue rejects unsorted (descending) attesters before any timelock op is scheduled.
    function test_queueTrustConfig_revertsForUnsortedAttesters() public {
        address[] memory att = _pair(address(0xB2), address(0xB1));
        vm.prank(cptHolder);
        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContractFactory__UnsortedAttesters.selector,
                address(0xB2),
                address(0xB1)
            )
        );
        factory.queueTrustConfig(2, att);

        // Nothing scheduled: pending mirror remains empty.
        (uint8 t, address[] memory a, uint64 eff) = factory.pendingTrustConfig(rolloverContract);
        assertEq(t, 0, "no pending threshold after rejected queue");
        assertEq(a.length, 0, "no pending attesters after rejected queue");
        assertEq(eff, 0, "no pending effectiveAt after rejected queue");
    }

    /// @notice A strictly-ascending multi-attester config queues and applies successfully.
    function test_queueAndApplyTrustConfig_succeedsForSortedAttesters() public {
        address[] memory att = _pair(address(0xB1), address(0xB2));
        vm.prank(cptHolder);
        factory.queueTrustConfig(2, att);
        vm.warp(block.timestamp + DELAY);
        factory.applyTrustConfig(rolloverContract);

        ICorkRolloverContract.RolloverContractTrustSnapshot memory snap =
            ICorkRolloverContract(rolloverContract).rolloverContractSnapshot();
        assertEq(snap.liveTrustThreshold, 2, "sorted live threshold");
        assertEq(snap.liveTrustAttesters.length, 2, "sorted live length");
        assertEq(snap.liveTrustAttesters[0], address(0xB1), "sorted live attester[0]");
        assertEq(snap.liveTrustAttesters[1], address(0xB2), "sorted live attester[1]");
    }

    /// @notice Recovery: an unsorted queue never schedules, leaving live config intact; the owner
    ///         can then queue+apply a sorted config.
    function test_unsortedQueueLeavesLiveConfigIntactAndSortedRequeueRecovers() public {
        // Unsorted queue reverts and schedules nothing.
        address[] memory bad = _pair(address(0xC2), address(0xC1));
        vm.prank(cptHolder);
        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContractFactory__UnsortedAttesters.selector,
                address(0xC2),
                address(0xC1)
            )
        );
        factory.queueTrustConfig(2, bad);

        // Old live config (seeded default attester) is unchanged.
        ICorkRolloverContract.RolloverContractTrustSnapshot memory beforeSnap =
            ICorkRolloverContract(rolloverContract).rolloverContractSnapshot();
        assertEq(
            beforeSnap.liveTrustAttesters[0], defaultAttester, "live trust unchanged after revert"
        );

        // Sorted requeue + apply recovers liveness.
        address[] memory good = _pair(address(0xC1), address(0xC2));
        vm.prank(cptHolder);
        factory.queueTrustConfig(2, good);
        vm.warp(block.timestamp + DELAY);
        factory.applyTrustConfig(rolloverContract);

        ICorkRolloverContract.RolloverContractTrustSnapshot memory snap =
            ICorkRolloverContract(rolloverContract).rolloverContractSnapshot();
        assertEq(snap.liveTrustAttesters[0], address(0xC1), "recovered live attester[0]");
        assertEq(snap.liveTrustAttesters[1], address(0xC2), "recovered live attester[1]");
    }

    /// @notice Queue rejects duplicate attesters at queue time.
    function test_queueTrustConfig_revertsForDuplicateAttester() public {
        address[] memory att = _pair(address(0xA1), address(0xA1));
        vm.prank(cptHolder);
        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContractFactory__DuplicateAttester.selector, address(0xA1)
            )
        );
        factory.queueTrustConfig(1, att);
    }

    /// @notice Queue accepts exactly `MAX_TRUST_ATTESTERS` attesters.
    function test_queueTrustConfig_acceptsMaxAttesters() public {
        address[] memory att = _uniqueAttesters(16);
        vm.prank(cptHolder);
        factory.queueTrustConfig(16, att);
        (uint8 t, address[] memory a,) = factory.pendingTrustConfig(rolloverContract);
        assertEq(t, 16);
        assertEq(a.length, 16);
    }

    /// @notice Queue rejects attester lists longer than `MAX_TRUST_ATTESTERS`.
    function test_queueTrustConfig_revertsForTooManyAttesters() public {
        vm.prank(cptHolder);
        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContractFactory__TooManyAttesters.selector, uint256(17), uint256(16)
            )
        );
        factory.queueTrustConfig(16, _uniqueAttesters(17));
    }

    /// @notice With no queued op, `pendingTrustConfig` returns `(0, [], 0)`.
    function test_pendingTrustConfig_returnsZeroTupleWhenNothingQueued() public view {
        (uint8 t, address[] memory a, uint64 eff) = factory.pendingTrustConfig(rolloverContract);
        assertEq(t, 0);
        assertEq(a.length, 0);
        assertEq(eff, 0);
    }

    /// @notice Unknown rolloverContracts also have no queued salt, so the pending view returns `(0, [], 0)`.
    function test_pendingTrustConfig_unknownRolloverContractReturnsZeroTuple() public view {
        (uint8 t, address[] memory a, uint64 eff) = factory.pendingTrustConfig(address(0xBEEF));
        assertEq(t, 0);
        assertEq(a.length, 0);
        assertEq(eff, 0);
    }

    /// @dev Timelock op id for a queued trust config at `nonce` (factory salt scheme).
    function _trustOpId(
        address rolloverContract_,
        uint8 threshold,
        address[] memory attesters,
        uint256 nonce
    ) internal view returns (bytes32) {
        bytes32 salt = _trustSalt(rolloverContract_, nonce);
        bytes memory data = _trustData(rolloverContract_, salt, threshold, attesters);
        return TimelockController(payable(factory.trustConfigTimelock()))
            .hashOperation(address(factory), 0, data, bytes32(0), salt);
    }

    function _trustSalt(address rolloverContract_, uint256 nonce) internal pure returns (bytes32) {
        return keccak256(abi.encode(rolloverContract_, nonce));
    }

    function _trustData(
        address rolloverContract_,
        bytes32 salt,
        uint8 threshold,
        address[] memory attesters
    ) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            CorkRolloverContractFactory.relayTrustConfig.selector,
            rolloverContract_,
            salt,
            threshold,
            attesters
        );
    }

    /// @dev Timelock op id for a queued trust-config delay update at `nonce`.
    function _delayUpdateOpId(uint256 newDelay, uint256 nonce) internal view returns (bytes32) {
        bytes32 salt = _delayUpdateSalt(nonce);
        return trustConfigTimelock.hashOperation(
            address(trustConfigTimelock), 0, _delayUpdateData(newDelay), bytes32(0), salt
        );
    }

    function _delayUpdateSalt(uint256 nonce) internal pure returns (bytes32) {
        return keccak256(
            // nonce is supplied by tests as a small literal matching the factory uint64 nonce.
            // forge-lint: disable-next-line(unsafe-typecast)
            abi.encode(keccak256("cork.factory.trust-config-delay-update"), uint64(nonce))
        );
    }

    function _delayUpdateData(uint256 newDelay) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(TimelockController.updateDelay.selector, newDelay);
    }

    function _forceTrustConfigTimelockDelay(uint256 newDelay) internal {
        bytes32 salt = keccak256("force-delay-update");
        bytes memory data = _delayUpdateData(newDelay);

        trustConfigTimelock.grantRole(trustConfigTimelock.PROPOSER_ROLE(), address(this));
        trustConfigTimelock.grantRole(trustConfigTimelock.EXECUTOR_ROLE(), address(this));
        trustConfigTimelock.schedule(address(trustConfigTimelock), 0, data, bytes32(0), salt, DELAY);

        vm.warp(block.timestamp + DELAY);
        trustConfigTimelock.execute(address(trustConfigTimelock), 0, data, bytes32(0), salt);
        assertEq(trustConfigTimelock.getMinDelay(), newDelay, "forced delay update");
    }

    function _grantOpenTimelockAccess(TimelockController tl) internal {
        tl.grantRole(tl.PROPOSER_ROLE(), anyone);
        tl.grantRole(tl.EXECUTOR_ROLE(), anyone);
    }

    function _grantExtraCanceller(address canceler) internal {
        trustConfigTimelock.grantRole(trustConfigTimelock.CANCELLER_ROLE(), canceler);
    }

    /// @notice `pendingTrustConfig` round-trips the queued (threshold, attesters, effectiveAt).
    function test_pendingTrustConfig_roundtrips() public {
        address[] memory att = _pair(address(0x11), address(0x22));
        vm.prank(cptHolder);
        factory.queueTrustConfig(2, att);

        (uint8 t, address[] memory a, uint64 eff) = factory.pendingTrustConfig(rolloverContract);
        assertEq(t, 2, "threshold roundtrip");
        assertEq(a.length, 2, "list length roundtrip");
        assertEq(a[0], address(0x11), "attester[0] roundtrip");
        assertEq(a[1], address(0x22), "attester[1] roundtrip");
        // DELAY is a small test constant, so the uint64 cast cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(eff, uint64(block.timestamp) + uint64(DELAY), "effectiveAt roundtrip");
    }
}
