// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { CorkRolloverContract } from "src/CorkRolloverContract.sol";
import { CorkRolloverContractFactory } from "src/CorkRolloverContractFactory.sol";
import {
    CorkRolloverContract__InvalidTrustAttesterOrder,
    CorkRolloverContract__NotFactory,
    CorkRolloverContract__TooManyAttesters
} from "src/errors/CorkRolloverContractErrors.sol";
import { ICorkRolloverContract } from "src/interfaces/rollover/ICorkRolloverContract.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice TrustConfigViaFactoryTest — pins the rolloverContract-side trust-config invariants:
///         `setTrustConfig` is factory-only; `owner()` view; live-only storage layout.
contract TrustConfigViaFactoryTest is BaseTest {
    /// @notice ERC-7201 namespaced storage slot for `RolloverContractStorage`.
    bytes32 private constant ROLLOVER_CONTRACT_STORAGE_SLOT =
        0xb4cefcf1cd721ac7aa7779687f98e0bf77365d8cc544d423bc3152971ed5cc00;

    function _singleton(address a) internal pure returns (address[] memory out) {
        out = new address[](1);
        out[0] = a;
    }

    function _uniqueAttesters(uint256 n) internal pure returns (address[] memory out) {
        out = new address[](n);
        uint256 baseKey = 0x5000;
        for (uint256 i = 0; i < n; ++i) {
            // Strictly ascending + unique + nonzero, as ERC-7484 / Rhinestone require.
            out[i] = address(uint160(baseKey + i + 1));
        }
    }

    /// @notice RolloverContract setTrustConfig rejects direct cPT holder (cPT-holder) calls.
    function testRevert_setTrustConfig_revertsForDirectEOA() public {
        address[] memory att = _singleton(address(0xA1));
        vm.prank(cptHolder);
        vm.expectRevert(CorkRolloverContract__NotFactory.selector);
        ICorkRolloverContract(rolloverContract).setTrustConfig(1, att);
    }

    /// @notice RolloverContract setTrustConfig rejects arbitrary callers.
    function testRevert_setTrustConfig_revertsForRandomCaller() public {
        address[] memory att = _singleton(address(0xA1));
        vm.prank(anyone);
        vm.expectRevert(CorkRolloverContract__NotFactory.selector);
        ICorkRolloverContract(rolloverContract).setTrustConfig(1, att);
    }

    /// @notice RolloverContract executeIntentHooks rejects direct non-factory callers.
    function testRevert_executeIntentHooks_revertsForDirectCaller() public {
        bytes32 orderDigest = bytes32(uint256(1));
        RolloverTypes.RolloverIntent memory intent = _emptyIntent(rolloverContract, orderDigest);
        RolloverTypes.OrderData memory orderData = _baseOrder();
        RolloverTypes.FillContext memory fillContext = _fillContext({
            filler_: filler,
            fillAmount: 0,
            rolloverIntentHash: bytes32(0),
            fillDeadline: uint64(block.timestamp + 1 days),
            allowPartialFills: false,
            orderSize: 0,
            originSettler: address(settler),
            premiumToken_: address(premiumToken),
            premium: 0
        });

        vm.prank(anyone);
        vm.expectRevert(CorkRolloverContract__NotFactory.selector);
        ICorkRolloverContract(rolloverContract)
            .executeIntentHooks(
                orderDigest,
                RolloverTypes.HookPhase.ROLLOVER,
                intent,
                bytes(""),
                fillContext,
                orderData
            );
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

    /// @notice setTrustConfig defensively rejects unsorted (descending) attesters.
    function testRevert_setTrustConfig_revertsForUnsortedAttesters() public {
        address[] memory att = _pair(address(0xB2), address(0xB1));
        vm.prank(address(factory));
        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContract__InvalidTrustAttesterOrder.selector,
                address(0xB2),
                address(0xB1)
            )
        );
        ICorkRolloverContract(rolloverContract).setTrustConfig(2, att);
    }

    /// @notice setTrustConfig via factory accepts strictly-ascending multi-attester lists.
    function test_setTrustConfig_acceptsSortedAttesters() public {
        address[] memory att = _pair(address(0xB1), address(0xB2));
        vm.prank(address(factory));
        ICorkRolloverContract(rolloverContract).setTrustConfig(2, att);
        ICorkRolloverContract.RolloverContractTrustSnapshot memory snap =
            ICorkRolloverContract(rolloverContract).rolloverContractSnapshot();
        assertEq(snap.liveTrustAttesters[0], address(0xB1), "sorted attester[0]");
        assertEq(snap.liveTrustAttesters[1], address(0xB2), "sorted attester[1]");
    }

    /// @notice RolloverContract setTrustConfig succeeds when pranked as the factory and writes live state.
    function test_setTrustConfig_succeedsViaFactory() public {
        address[] memory att = _singleton(address(0xBEEF));
        vm.prank(address(factory));
        ICorkRolloverContract(rolloverContract).setTrustConfig(1, att);

        ICorkRolloverContract.RolloverContractTrustSnapshot memory snap =
            ICorkRolloverContract(rolloverContract).rolloverContractSnapshot();
        assertEq(snap.liveTrustThreshold, 1, "live threshold");
        assertEq(snap.liveTrustAttesters.length, 1, "live attester count");
        assertEq(snap.liveTrustAttesters[0], address(0xBEEF), "live attester");
        assertEq(erc7484.lastThreshold(rolloverContract), 1, "registry threshold");
        assertEq(erc7484.attestersOf(rolloverContract)[0], address(0xBEEF), "registry attester");
    }

    /// @notice setTrustConfig via factory accepts exactly `MAX_TRUST_ATTESTERS` attesters.
    function test_setTrustConfig_acceptsMaxAttesters() public {
        address[] memory att = _uniqueAttesters(16);
        vm.prank(address(factory));
        ICorkRolloverContract(rolloverContract).setTrustConfig(16, att);
        assertEq(
            ICorkRolloverContract(rolloverContract).rolloverContractSnapshot().liveTrustAttesters
                .length,
            16
        );
    }

    /// @notice setTrustConfig via factory rejects attester lists longer than the cap.
    function testRevert_setTrustConfig_revertsForTooManyAttesters() public {
        vm.prank(address(factory));
        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContract__TooManyAttesters.selector, uint256(17), uint256(16)
            )
        );
        ICorkRolloverContract(rolloverContract).setTrustConfig(16, _uniqueAttesters(17));
    }

    /// @notice cPT holder() returns the CWIA trailer owner across multiple rolloverContracts.
    function test_owner_returnsCwiaOwner() public {
        assertEq(
            ICorkRolloverContract(rolloverContract).owner(), cptHolder, "owner matches cwia trailer"
        );

        address alice = makeAddr("alice");
        vm.prank(alice);
        address aliceRolloverContract = factory.deployRolloverContract();
        assertEq(ICorkRolloverContract(aliceRolloverContract).owner(), alice, "owner is per-clone");
    }

    /// @notice `_liveTrustHash` scope is live-only; pending trust config lives on the factory.
    function test_liveTrustHash_excludesDeletedPendingFields() public view {
        // Current layout: slot +3 = liveTrustThreshold, slot +4 = liveTrustAttesters length.
        // Slot +5 must be zero (no pending* storage on the rolloverContract).
        bytes32 slot5 =
            vm.load(rolloverContract, bytes32(uint256(ROLLOVER_CONTRACT_STORAGE_SLOT) + 5));
        assertEq(slot5, bytes32(0), "no 6th namespaced slot after pending* deletion");
    }

    /// @notice Storage-layout fingerprint pinned to the locked live-only trust shape.
    function test_namespaceStorageLayout_pinnedToLocked() public view {
        // Slots +0..+2 are mappings — keccak-bucketed, base slot zero at init.
        for (uint256 i = 0; i < 3; ++i) {
            bytes32 sl =
                vm.load(rolloverContract, bytes32(uint256(ROLLOVER_CONTRACT_STORAGE_SLOT) + i));
            assertEq(sl, bytes32(0), "mapping base slot zero at init");
        }
        // Slot +3: liveTrustThreshold (seeded = 1 from factory defaults).
        bytes32 slot3 =
            vm.load(rolloverContract, bytes32(uint256(ROLLOVER_CONTRACT_STORAGE_SLOT) + 3));
        assertEq(uint256(slot3), 1, "slot +3 == liveTrustThreshold = 1");
        // Slot +4: liveTrustAttesters length = 1 (factory default attester seeded).
        bytes32 slot4 =
            vm.load(rolloverContract, bytes32(uint256(ROLLOVER_CONTRACT_STORAGE_SLOT) + 4));
        assertEq(uint256(slot4), 1, "slot +4 == liveTrustAttesters length = 1");
        // Slot +5: must be zero — the struct has exactly 5 fields.
        bytes32 slot5 =
            vm.load(rolloverContract, bytes32(uint256(ROLLOVER_CONTRACT_STORAGE_SLOT) + 5));
        assertEq(slot5, bytes32(0), "no field at slot +5 (struct has 5 entries)");
    }
}
