// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {
    CorkRolloverContractFactory__UnknownRolloverContract
} from "src/errors/CorkRolloverContractFactoryErrors.sol";

import { FillScaffold } from "../../base/FillScaffold.sol";
import { CorkRolloverContractFactory } from "src/CorkRolloverContractFactory.sol";
import { ICorkRolloverContract } from "src/interfaces/rollover/ICorkRolloverContract.sol";
import {
    ICorkRolloverContractFactory
} from "src/interfaces/rollover/ICorkRolloverContractFactory.sol";
import { IRolloverContractLens } from "src/interfaces/rollover/IRolloverContractLens.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice RolloverContractLensTest — pins RolloverContractLens behaviour for the Cork Rollover suite.
contract RolloverContractLensTest is FillScaffold {
    /// @notice Fill.
    uint256 internal constant FILL = 1_000e18;
    /// @notice Dst.

    uint256 internal constant DST = 1_000e18;
    /// @notice Premium.

    uint256 internal constant PREMIUM = 10e18;
    /// @notice Phase 0 terminal bit.

    uint256 internal constant PHASE_0_TERMINAL_BIT = 1 << 0;
    /// @notice Trust delay.

    uint64 internal constant TRUST_DELAY = 1 hours;
    /// @notice Sel rolled.

    bytes4 internal constant SEL_ROLLED = bytes4(keccak256("rolled(bytes32)"));
    /// @notice Sel hook nonces.

    bytes4 internal constant SEL_HOOK_NONCES = bytes4(keccak256("hookNonces(bytes32)"));
    /// @notice Sel premium fired.

    bytes4 internal constant SEL_PREMIUM_FIRED =
        bytes4(keccak256("premiumFiredFor(bytes32,address,bytes32)"));
    /// @notice Sel authorized for.

    bytes4 internal constant SEL_AUTHORIZED_FOR = bytes4(keccak256("authorizedFor(bytes32)"));
    /// @notice Sel pending trust.

    bytes4 internal constant SEL_PENDING_TRUST = bytes4(keccak256("pendingTrustConfig()"));
    /// @notice Sel cork banlist.

    bytes4 internal constant SEL_CORK_BANLIST = bytes4(keccak256("corkBanlist()"));
    /// @notice Sel erc7484 registry.

    bytes4 internal constant SEL_ERC7484_REGISTRY = bytes4(keccak256("erc7484Registry()"));

    function _lens() internal view returns (IRolloverContractLens) {
        return IRolloverContractLens(address(factory));
    }

    function _singletonAttesters(address a) internal pure returns (address[] memory out) {
        out = new address[](1);
        out[0] = a;
    }

    function _pairAttesters(address a, address b) internal pure returns (address[] memory out) {
        out = new address[](2);
        out[0] = a;
        out[1] = b;
    }

    function _runOrderToTerminal()
        internal
        returns (bytes32 orderDigest, RolloverTypes.OrderData memory orderData)
    {
        orderData = _baseOrder();
        orderData.allowPartialFills = false;
        orderData.orderSize = FILL;
        RolloverTypes.RolloverIntent memory intent = _buildIntent(bytes32(0), FILL, DST);
        orderData.rolloverIntentHash = _zeroDigestHash(intent);
        orderDigest = _openOrder(orderData);
        intent.orderDigest = orderDigest;
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);
        _approveFiller(FILL, PREMIUM);
        _doRolloverAs(orderDigest, orderData, intent, FILL, filler);
    }

    function _runOrderToTerminalWithPremium(address fillerAddr, uint256 fillerSrc)
        internal
        returns (bytes32 orderDigest, RolloverTypes.OrderData memory orderData)
    {
        orderData = _baseOrder();
        orderData.allowPartialFills = false;
        orderData.orderSize = FILL;
        RolloverTypes.RolloverIntent memory intent = _buildIntent(bytes32(0), FILL, DST);
        orderData.rolloverIntentHash = _zeroDigestHash(intent);
        orderDigest = _openOrder(orderData);
        intent.orderDigest = orderDigest;
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);

        if (fillerAddr != filler) {
            srcCst.mint(fillerAddr, fillerSrc);
            premiumToken.mint(fillerAddr, PREMIUM);
        }
        vm.startPrank(fillerAddr);
        srcCst.approve(address(settler), FILL);
        srcCst.approve(address(partialSettler), FILL);
        premiumToken.approve(address(settler), PREMIUM);
        premiumToken.approve(address(partialSettler), PREMIUM);
        vm.stopPrank();

        _doRolloverAs(orderDigest, orderData, intent, FILL, fillerAddr);
    }

    /// @notice Pins behaviour: factory order State returns Zeros For Never Filled Digest.
    function test_factory_orderState_returnsZerosForNeverFilledDigest() public view {
        bytes32 unused = bytes32(uint256(0xDEADBEEF));
        ICorkRolloverContract.RolloverContractOrderState memory s =
            _lens().orderState(rolloverContract, unused);
        assertEq(s.rolled, 0, "rolled = 0");
        assertFalse(s.rolloverTerminal, "rolloverTerminal = false");
    }

    /// @notice Pins behaviour: factory order State reflects Rolled And Terminal After Full Fill.
    function test_factory_orderState_reflectsRolledAndTerminalAfterFullFill() public {
        (bytes32 orderDigest,) = _runOrderToTerminal();
        ICorkRolloverContract.RolloverContractOrderState memory s =
            _lens().orderState(rolloverContract, orderDigest);
        assertEq(s.rolled, FILL, "rolled tracks full fill");
        assertTrue(s.rolloverTerminal, "terminal bit set after !allowPartial full fill");
    }

    /// @notice Pins behaviour: factory order State unknown RolloverContract Reverts.
    function testRevert_factory_orderState_unknownRolloverContractReverts() public {
        address bogus = address(0xBADC0FFEE);
        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContractFactory__UnknownRolloverContract.selector, bogus
            )
        );
        _lens().orderState(bogus, bytes32(0));
    }

    /// @notice Under atomic-fill the PREMIUM phase fires inside the same Settler frame
    ///         as ROLLOVER. The lens reflects premiumFired = true immediately after the
    ///         terminal rollover lands.
    function test_factory_premiumFiredFor_falseUntilPremiumLegLands() public {
        (bytes32 orderDigest,) = _runOrderToTerminal();
        assertTrue(
            _lens()
                .premiumFiredFor(
                    rolloverContract, orderDigest, filler, bytes32(uint256(uint160(filler)))
                ),
            "atomic-fill: premiumFired = true after rollover"
        );
    }

    /// @notice Pins behaviour: factory premium Fired For true For Filler That Paid false For Other.
    function test_factory_premiumFiredFor_trueForFillerThatPaid_falseForOther() public {
        (bytes32 orderDigest,) = _runOrderToTerminalWithPremium(filler, FILL);
        assertTrue(
            _lens()
                .premiumFiredFor(
                    rolloverContract, orderDigest, filler, bytes32(uint256(uint160(filler)))
                ),
            "fired = true for paying filler"
        );
        assertFalse(
            _lens()
                .premiumFiredFor(
                    rolloverContract,
                    orderDigest,
                    address(0xF2),
                    bytes32(uint256(uint160(address(0xF2))))
                ),
            "fired = false for unrelated address"
        );
    }

    /// @notice Pins behaviour: factory rolloverContract Config returns Cwia Owner And Factory Addresses.
    function test_factory_rolloverContractConfig_returnsCwiaOwnerAndFactoryAddresses() public view {
        IRolloverContractLens.RolloverContractConfig memory cfg =
            _lens().rolloverContractConfig(rolloverContract);
        assertEq(cfg.owner, cptHolder, "CWIA owner = cptHolder");
        assertEq(cfg.factory, address(factory), "CWIA factory = factory");
    }

    /// @notice Pins behaviour: factory rolloverContract Config returns Registry From Init.
    function test_factory_rolloverContractConfig_returnsRegistryFromInit() public view {
        IRolloverContractLens.RolloverContractConfig memory cfg =
            _lens().rolloverContractConfig(rolloverContract);
        assertEq(cfg.erc7484Registry, address(erc7484), "erc7484Registry mirrors init");
    }

    /// @notice Pins behaviour: factory rolloverContract Config live Trust Seeded From Factory Defaults Before First Apply.
    function test_factory_rolloverContractConfig_liveTrustSeededFromFactoryDefaultsBeforeFirstApply()
        public
        view
    {
        IRolloverContractLens.RolloverContractConfig memory cfg =
            _lens().rolloverContractConfig(rolloverContract);
        assertEq(cfg.liveTrustThreshold, 1, "liveThreshold = factory seed");
        assertEq(cfg.liveTrustAttesters.length, 1, "liveAttesters = factory seed (single)");
        assertEq(cfg.liveTrustAttesters[0], defaultAttester, "liveAttester = factory seed");
    }

    /// @notice Pins behaviour: factory rolloverContract Config live Trust Reflects Last Applied Config.
    function test_factory_rolloverContractConfig_liveTrustReflectsLastAppliedConfig() public {
        address[] memory attesters = _pairAttesters(address(0xA1), address(0xA2));
        vm.prank(cptHolder);
        factory.queueTrustConfig(2, attesters);
        vm.warp(block.timestamp + TRUST_DELAY);
        factory.applyTrustConfig(rolloverContract);

        IRolloverContractLens.RolloverContractConfig memory cfg =
            _lens().rolloverContractConfig(rolloverContract);
        assertEq(cfg.liveTrustThreshold, 2, "liveThreshold mirrors apply");
        assertEq(cfg.liveTrustAttesters.length, 2, "liveAttesters length");
        assertEq(cfg.liveTrustAttesters[0], address(0xA1), "liveAttester[0]");
        assertEq(cfg.liveTrustAttesters[1], address(0xA2), "liveAttester[1]");
    }

    /// @notice Pins behaviour: factory pendingTrustConfig returns zero tuple when nothing queued.
    function test_factory_pendingTrustConfig_zerosWhenNothingQueued() public view {
        (uint8 t, address[] memory a, uint64 eff) = factory.pendingTrustConfig(rolloverContract);
        assertEq(t, 0, "pendingThreshold = 0");
        assertEq(eff, 0, "pendingEffectiveAt = 0");
        assertEq(a.length, 0, "pendingAttesters empty");
    }

    /// @notice Pins behaviour: factory pendingTrustConfig reflects a queued config.
    function test_factory_pendingTrustConfig_reflectsQueuedConfig() public {
        address[] memory attesters = _singletonAttesters(address(0xBEEF));
        uint64 expectedEffectiveAt = uint64(block.timestamp) + TRUST_DELAY;
        vm.prank(cptHolder);
        factory.queueTrustConfig(1, attesters);

        (uint8 t, address[] memory a, uint64 eff) = factory.pendingTrustConfig(rolloverContract);
        assertEq(t, 1, "pendingThreshold mirrors queue");
        assertEq(eff, expectedEffectiveAt, "pendingEffectiveAt = T+DELAY");
        assertEq(a.length, 1, "pendingAttesters length");
        assertEq(a[0], address(0xBEEF), "pendingAttester[0]");
    }

    /// @notice Pins behaviour: live config is unchanged while a pending op is in flight.
    function test_factory_rolloverContractConfig_liveUnchangedWhilePendingQueued() public {
        address[] memory initial = _singletonAttesters(address(0xA1));
        vm.prank(cptHolder);
        factory.queueTrustConfig(1, initial);
        vm.warp(block.timestamp + TRUST_DELAY);
        factory.applyTrustConfig(rolloverContract);

        address[] memory updated = _pairAttesters(address(0xB1), address(0xB2));
        vm.prank(cptHolder);
        factory.queueTrustConfig(2, updated);

        IRolloverContractLens.RolloverContractConfig memory cfg =
            _lens().rolloverContractConfig(rolloverContract);
        assertEq(cfg.liveTrustThreshold, 1, "live unchanged during pending window");
        assertEq(cfg.liveTrustAttesters.length, 1, "live length");
        assertEq(cfg.liveTrustAttesters[0], address(0xA1), "live attester");

        (uint8 t,,) = factory.pendingTrustConfig(rolloverContract);
        assertEq(t, 2, "pending threshold");
    }

    /// @notice Pins behaviour: factory rolloverContract Config unknown RolloverContract Reverts.
    function testRevert_factory_rolloverContractConfig_unknownRolloverContractReverts() public {
        address bogus = address(0xC0FFEE);
        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContractFactory__UnknownRolloverContract.selector, bogus
            )
        );
        _lens().rolloverContractConfig(bogus);
    }

    /// @notice Pins behaviour: factory premium Fired For unknown RolloverContract Reverts.
    function testRevert_factory_premiumFiredFor_unknownRolloverContractReverts() public {
        address bogus = address(0xC0FFEE);
        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContractFactory__UnknownRolloverContract.selector, bogus
            )
        );
        _lens().premiumFiredFor(bogus, bytes32(0), filler, bytes32(0));
    }

    /// @notice Pins behaviour: rolloverContract snapshot returns the live-only trust view.
    function test_rolloverContract_rolloverContractSnapshot_returnsLiveOnlyView() public {
        address[] memory attesters = _singletonAttesters(address(0xCAFE));
        vm.prank(cptHolder);
        factory.queueTrustConfig(1, attesters);

        ICorkRolloverContract.RolloverContractTrustSnapshot memory snap =
            ICorkRolloverContract(rolloverContract).rolloverContractSnapshot();
        assertEq(snap.erc7484Registry, address(erc7484), "snap.erc7484Registry");
        assertEq(snap.liveTrustThreshold, 1, "snap.liveThreshold = factory seed");
        assertEq(snap.liveTrustAttesters.length, 1, "snap.liveAttesters = factory seed (1)");
        assertEq(snap.liveTrustAttesters[0], defaultAttester, "snap.liveAttester[0] = factory seed");

        (uint8 t, address[] memory a, uint64 eff) = factory.pendingTrustConfig(rolloverContract);
        assertEq(t, 1, "factory mirror threshold");
        assertEq(a.length, 1, "factory mirror attester count");
        assertEq(a[0], address(0xCAFE), "factory mirror attester");
        assertEq(eff, uint64(block.timestamp) + TRUST_DELAY, "factory mirror effectiveAt");
    }

    /// @notice Pins behaviour: rolloverContract order State terminal Bit Correctly Derived.
    function test_rolloverContract_orderState_terminalBitCorrectlyDerived() public {
        bytes32 stale = bytes32(uint256(0x1234));
        ICorkRolloverContract.RolloverContractOrderState memory pre =
            ICorkRolloverContract(rolloverContract).orderState(stale);
        assertFalse(pre.rolloverTerminal, "pre-fill terminal=false");

        (bytes32 orderDigest,) = _runOrderToTerminal();
        ICorkRolloverContract.RolloverContractOrderState memory post =
            ICorkRolloverContract(rolloverContract).orderState(orderDigest);
        assertTrue(post.rolloverTerminal, "post-fill terminal=true");
        assertEq(post.rolled, FILL, "post-fill rolled tracks");
    }

    /// @notice Pins behaviour: rolloverContract premium Fired For point Query Works.
    function test_rolloverContract_premiumFiredFor_pointQueryWorks() public {
        (bytes32 orderDigest,) = _runOrderToTerminalWithPremium(filler, FILL);
        assertTrue(
            ICorkRolloverContract(rolloverContract)
                .premiumFiredFor(orderDigest, filler, bytes32(uint256(uint160(filler)))),
            "fired=true paying"
        );
        assertFalse(
            ICorkRolloverContract(rolloverContract)
                .premiumFiredFor(
                    orderDigest, address(0xDEAD), bytes32(uint256(uint160(address(0xDEAD))))
                ),
            "fired=false unrelated"
        );
    }

    /// @notice Pins behaviour: rolloverContract old Views Removed selector Absent.
    function test_rolloverContract_oldViewsRemoved_selectorAbsent() public view {
        bytes4[6] memory removed = [
            SEL_ROLLED,
            SEL_HOOK_NONCES,
            SEL_AUTHORIZED_FOR,
            SEL_PENDING_TRUST,
            SEL_CORK_BANLIST,
            SEL_ERC7484_REGISTRY
        ];
        for (uint256 i = 0; i < removed.length; ++i) {
            bytes memory cd;
            if (
                removed[i] == SEL_PENDING_TRUST || removed[i] == SEL_CORK_BANLIST
                    || removed[i] == SEL_ERC7484_REGISTRY
            ) {
                cd = abi.encodeWithSelector(removed[i]);
            } else {
                cd = abi.encodeWithSelector(removed[i], bytes32(0));
            }
            (bool ok,) = address(rolloverContract).staticcall(cd);
            assertFalse(ok, "removed selector still callable");
        }
    }

    /// @notice Pins behaviour: storage rolloverContract Storage Namespace Slot Unchanged.
    function test_storage_rolloverContractStorageNamespaceSlotUnchanged() public {
        bytes32 expected = 0xb4cefcf1cd721ac7aa7779687f98e0bf77365d8cc544d423bc3152971ed5cc00;
        bytes32 computed = keccak256(
            abi.encode(uint256(keccak256("cork.rollover.rolloverContract")) - 1)
        ) & ~bytes32(uint256(0xff));
        assertEq(computed, expected, "namespace slot derivation drift");

        address[] memory attesters = _singletonAttesters(cptHolder);
        vm.prank(cptHolder);
        factory.queueTrustConfig(1, attesters);
        (,, uint64 eff) = factory.pendingTrustConfig(rolloverContract);
        assertGt(eff, 0, "factory's timelock recorded the queue with non-zero effectiveAt");
    }

    /// @notice Pins behaviour: live Trust Mirror writes On Apply Trust Config.
    function test_liveTrustMirror_writesOnApplyTrustConfig() public {
        address[] memory attesters = _pairAttesters(address(0x11), address(0x22));
        vm.prank(cptHolder);
        factory.queueTrustConfig(2, attesters);
        vm.warp(block.timestamp + TRUST_DELAY);
        factory.applyTrustConfig(rolloverContract);

        ICorkRolloverContract.RolloverContractTrustSnapshot memory snap =
            ICorkRolloverContract(rolloverContract).rolloverContractSnapshot();
        assertEq(snap.liveTrustThreshold, 2, "mirror threshold written");
        assertEq(snap.liveTrustAttesters.length, 2, "mirror length");
        assertEq(snap.liveTrustAttesters[0], address(0x11), "mirror[0]");
        assertEq(snap.liveTrustAttesters[1], address(0x22), "mirror[1]");

        assertEq(erc7484.lastThreshold(rolloverContract), 2, "registry threshold");
        assertEq(erc7484.attestersOf(rolloverContract)[0], address(0x11), "registry attester[0]");
    }

    /// @notice Pins behaviour: live Trust Mirror unchanged By Cancel Or Queue.
    function test_liveTrustMirror_unchangedByCancelOrQueue() public {
        address[] memory baseline = _singletonAttesters(address(0xA1));
        vm.prank(cptHolder);
        factory.queueTrustConfig(1, baseline);
        vm.warp(block.timestamp + TRUST_DELAY);
        factory.applyTrustConfig(rolloverContract);

        address[] memory next = _pairAttesters(address(0xB1), address(0xB2));
        vm.prank(cptHolder);
        factory.queueTrustConfig(2, next);

        ICorkRolloverContract.RolloverContractTrustSnapshot memory midQueue =
            ICorkRolloverContract(rolloverContract).rolloverContractSnapshot();
        assertEq(midQueue.liveTrustThreshold, 1, "mirror unchanged by queue");
        assertEq(midQueue.liveTrustAttesters.length, 1, "mirror unchanged by queue length");
        assertEq(
            midQueue.liveTrustAttesters[0], address(0xA1), "mirror unchanged by queue attester"
        );

        vm.prank(cptHolder);
        factory.cancelTrustConfig();

        ICorkRolloverContract.RolloverContractTrustSnapshot memory afterAbort =
            ICorkRolloverContract(rolloverContract).rolloverContractSnapshot();
        assertEq(afterAbort.liveTrustThreshold, 1, "mirror unchanged by cancel");
        assertEq(afterAbort.liveTrustAttesters[0], address(0xA1), "mirror unchanged by cancel");
    }

    /// @notice Pins behaviour: live Trust Mirror overwrites Prior Applied Set.
    function test_liveTrustMirror_overwritesPriorAppliedSet() public {
        address[] memory v1 = _singletonAttesters(address(0xA1));
        vm.prank(cptHolder);
        factory.queueTrustConfig(1, v1);
        vm.warp(block.timestamp + TRUST_DELAY);
        factory.applyTrustConfig(rolloverContract);

        address[] memory v2 = _pairAttesters(address(0xB1), address(0xB2));
        vm.prank(cptHolder);
        factory.queueTrustConfig(2, v2);
        vm.warp(block.timestamp + TRUST_DELAY);
        factory.applyTrustConfig(rolloverContract);

        ICorkRolloverContract.RolloverContractTrustSnapshot memory snap =
            ICorkRolloverContract(rolloverContract).rolloverContractSnapshot();
        assertEq(snap.liveTrustThreshold, 2, "mirror reflects v2 threshold");
        assertEq(snap.liveTrustAttesters.length, 2, "mirror reflects v2 length");
        assertEq(snap.liveTrustAttesters[0], address(0xB1), "mirror reflects v2[0]");
        assertEq(snap.liveTrustAttesters[1], address(0xB2), "mirror reflects v2[1]");
    }
}
