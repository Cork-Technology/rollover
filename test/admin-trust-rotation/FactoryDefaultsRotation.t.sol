// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {
    CorkRolloverContractFactory__AddressHasNoCode,
    CorkRolloverContractFactory__DuplicateAttester,
    CorkRolloverContractFactory__InvalidThreshold,
    CorkRolloverContractFactory__TooManyAttesters,
    CorkRolloverContractFactory__ZeroAddress
} from "src/errors/CorkRolloverContractFactoryErrors.sol";

import { IAccessControl } from "lib/openzeppelin-contracts/contracts/access/IAccessControl.sol";
import { ICorkRolloverContract } from "src/interfaces/rollover/ICorkRolloverContract.sol";
import { BaseTest } from "test/base/BaseTest.sol";

/// @notice FactoryDefaultsRotationTest — pins the role-gated factory defaults setter.
///         New rolloverContracts deploy with the latest defaults after `setDefaults`; existing rolloverContracts
///         are unaffected and continue to use the per-rolloverContract trust-config flow.
contract FactoryDefaultsRotationTest is BaseTest {
    /// @notice Replacement registry candidate.
    address internal newRegistry = address(0xBEE7);

    /// @notice Replacement attester A.
    address internal attesterA = address(0xA111);

    /// @notice Replacement attester B.
    address internal attesterB = address(0xB222);

    /// @notice Mirror of the `DefaultsSet` event for `vm.expectEmit`.
    /// @param threshold New live default trust threshold.
    /// @param attesters New live default attester list.
    /// @param registry New live ERC-7484 registry.
    event DefaultsSet(uint8 threshold, address[] attesters, address registry);

    /// @dev Helper — build a fresh replacement attester set.
    function _uniqueAttesters(uint256 n) internal pure returns (address[] memory out) {
        out = new address[](n);
        uint256 baseKey = 0x2000;
        for (uint256 i = 0; i < n; ++i) {
            // Strictly ascending + unique + nonzero, as ERC-7484 / Rhinestone require.
            out[i] = address(uint160(baseKey + i + 1));
        }
    }

    function _newAttesters() internal view returns (address[] memory list) {
        list = new address[](2);
        list[0] = attesterA;
        list[1] = attesterB;
    }

    /// @notice Extend `BaseTest.setUp` with a code-bearing replacement-registry slot.
    function setUp() public virtual override {
        super.setUp();
        vm.etch(newRegistry, hex"6001");
    }

    /// @notice setDefaults reverts when called without defaults-manager authority.
    function test_SetDefaults_OnlyDefaultsManager_RevertsForUnauthorizedCaller() public {
        bytes32 defaultsManagerRole = factory.DEFAULTS_MANAGER_ROLE();
        address[] memory atts = _newAttesters();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                anyone,
                defaultsManagerRole
            )
        );
        vm.prank(anyone);
        factory.setDefaults(1, atts, newRegistry);
    }

    /// @notice setDefaults updates live defaults and emits `DefaultsSet`.
    function test_SetDefaults_UpdatesLiveDefaults_EmitsDefaultsSet() public {
        address[] memory atts = _newAttesters();

        vm.expectEmit(true, true, true, true, address(factory));
        emit DefaultsSet(2, atts, newRegistry);
        factory.setDefaults(2, atts, newRegistry);

        assertEq(factory.DEFAULT_TRUST_THRESHOLD(), 2, "live threshold");
        assertEq(factory.ERC7484_REGISTRY(), newRegistry, "live registry");
        address[] memory live = factory.defaultAttesters();
        assertEq(live.length, 2, "live attesters length");
        assertEq(live[0], attesterA, "live attesters[0]");
        assertEq(live[1], attesterB, "live attesters[1]");
    }

    /// @notice setDefaults overwrites the prior live defaults atomically.
    function test_SetDefaults_OverwritesLiveDefaults() public {
        address[] memory first = _newAttesters();
        factory.setDefaults(1, first, newRegistry);

        address replacementRegistry = address(0xCAFE);
        vm.etch(replacementRegistry, hex"6001");
        address[] memory second = _uniqueAttesters(3);

        factory.setDefaults(2, second, replacementRegistry);

        assertEq(factory.DEFAULT_TRUST_THRESHOLD(), 2, "replacement threshold");
        assertEq(factory.ERC7484_REGISTRY(), replacementRegistry, "replacement registry");
        address[] memory live = factory.defaultAttesters();
        assertEq(live.length, 3, "replacement attesters length");
        assertEq(live[0], second[0], "replacement attester[0]");
        assertEq(live[1], second[1], "replacement attester[1]");
        assertEq(live[2], second[2], "replacement attester[2]");
    }

    /// @notice setDefaults reverts when threshold is zero or exceeds attester length.
    function test_SetDefaults_InvalidThreshold_Reverts() public {
        address[] memory atts = _newAttesters();
        vm.expectRevert(CorkRolloverContractFactory__InvalidThreshold.selector);
        factory.setDefaults(0, atts, newRegistry);

        vm.expectRevert(CorkRolloverContractFactory__InvalidThreshold.selector);
        factory.setDefaults(3, atts, newRegistry);
    }

    /// @notice setDefaults reverts on empty attester list.
    function test_SetDefaults_EmptyAttesters_Reverts() public {
        address[] memory empty = new address[](0);
        vm.expectRevert(CorkRolloverContractFactory__InvalidThreshold.selector);
        factory.setDefaults(1, empty, newRegistry);
    }

    /// @notice setDefaults reverts on a zero-address attester.
    function test_SetDefaults_ZeroAttester_Reverts() public {
        address[] memory atts = new address[](2);
        atts[0] = attesterA;
        atts[1] = address(0);
        vm.expectRevert(CorkRolloverContractFactory__ZeroAddress.selector);
        factory.setDefaults(1, atts, newRegistry);
    }

    /// @notice setDefaults reverts on a duplicate attester.
    function test_SetDefaults_DuplicateAttester_Reverts() public {
        address[] memory atts = new address[](2);
        atts[0] = attesterA;
        atts[1] = attesterA;
        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContractFactory__DuplicateAttester.selector, attesterA
            )
        );
        factory.setDefaults(1, atts, newRegistry);
    }

    /// @notice setDefaults accepts exactly `MAX_TRUST_ATTESTERS` attesters.
    function test_SetDefaults_AcceptsMaxAttesters() public {
        address[] memory atts = _uniqueAttesters(16);
        factory.setDefaults(16, atts, newRegistry);

        assertEq(factory.DEFAULT_TRUST_THRESHOLD(), 16);
        assertEq(factory.defaultAttesters().length, 16);
    }

    /// @notice setDefaults rejects attester lists longer than `MAX_TRUST_ATTESTERS`.
    function test_SetDefaults_TooManyAttesters_Reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContractFactory__TooManyAttesters.selector, uint256(17), uint256(16)
            )
        );
        factory.setDefaults(16, _uniqueAttesters(17), newRegistry);
    }

    /// @notice setDefaults reverts on a zero-address registry.
    function test_SetDefaults_ZeroRegistry_Reverts() public {
        address[] memory atts = _newAttesters();
        vm.expectRevert(CorkRolloverContractFactory__ZeroAddress.selector);
        factory.setDefaults(1, atts, address(0));
    }

    /// @notice setDefaults reverts when the registry candidate has no code.
    function test_SetDefaults_RevertsWhenRegistryHasNoCode() public {
        address eoa = makeAddr("eoaRegistry");
        assertEq(eoa.code.length, 0);
        address[] memory atts = _newAttesters();
        vm.expectRevert(
            abi.encodeWithSelector(CorkRolloverContractFactory__AddressHasNoCode.selector, eoa)
        );
        factory.setDefaults(1, atts, eoa);
    }

    /// @notice A rolloverContract deployed AFTER setDefaults uses the new defaults.
    function test_NewRolloverContract_PostSetDefaults_SeedsWithNewDefaults() public {
        address[] memory atts = _newAttesters();
        factory.setDefaults(2, atts, newRegistry);

        address newUser = address(0xDEAD1);
        vm.prank(newUser);
        address newRolloverContract = factory.deployRolloverContract();

        ICorkRolloverContract.RolloverContractTrustSnapshot memory snap =
            ICorkRolloverContract(newRolloverContract).rolloverContractSnapshot();
        assertEq(
            snap.erc7484Registry, newRegistry, "new rolloverContract registry from new defaults"
        );
        assertEq(snap.liveTrustThreshold, 2, "new rolloverContract threshold from new defaults");
        assertEq(snap.liveTrustAttesters.length, 2, "new rolloverContract attester count");
        assertEq(snap.liveTrustAttesters[0], attesterA, "new rolloverContract attester A");
        assertEq(snap.liveTrustAttesters[1], attesterB, "new rolloverContract attester B");
    }

    /// @notice A rolloverContract deployed BEFORE setDefaults keeps its original live trust state and
    ///         CWIA-baked registry.
    function test_ExistingRolloverContract_PostSetDefaults_UnchangedLiveTrust() public {
        ICorkRolloverContract.RolloverContractTrustSnapshot memory snapBefore =
            ICorkRolloverContract(rolloverContract).rolloverContractSnapshot();

        address[] memory atts = _newAttesters();
        factory.setDefaults(2, atts, newRegistry);

        ICorkRolloverContract.RolloverContractTrustSnapshot memory snapAfter =
            ICorkRolloverContract(rolloverContract).rolloverContractSnapshot();
        assertEq(snapAfter.erc7484Registry, snapBefore.erc7484Registry, "existing registry");
        assertEq(snapAfter.liveTrustThreshold, snapBefore.liveTrustThreshold, "existing threshold");
        assertEq(
            snapAfter.liveTrustAttesters.length,
            snapBefore.liveTrustAttesters.length,
            "existing attester count"
        );
        assertEq(
            snapAfter.liveTrustAttesters[0],
            snapBefore.liveTrustAttesters[0],
            "existing attester[0]"
        );
    }
}
