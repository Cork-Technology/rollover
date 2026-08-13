// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {
    CorkRolloverContractFactory__AddressHasNoCode,
    CorkRolloverContractFactory__DuplicateAttester,
    CorkRolloverContractFactory__EmptyDefaultAttesters,
    CorkRolloverContractFactory__InvalidDefaultThreshold,
    CorkRolloverContractFactory__InvalidTrustConfigTimelockDelay,
    CorkRolloverContractFactory__TooManyAttesters,
    CorkRolloverContractFactory__TrustConfigTimelockCannotExecute,
    CorkRolloverContractFactory__TrustConfigTimelockMissingRole,
    CorkRolloverContractFactory__TrustConfigTimelockOpenExecutor,
    CorkRolloverContractFactory__UnsortedAttesters,
    CorkRolloverContractFactory__ZeroAddress
} from "src/errors/CorkRolloverContractFactoryErrors.sol";

import { MockERC7484 } from "../../mocks/MockERC7484.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { Test } from "forge-std/Test.sol";
import { CorkRolloverContract } from "src/CorkRolloverContract.sol";
import { CorkRolloverContractFactory } from "src/CorkRolloverContractFactory.sol";

/// @notice CorkRolloverContractFactoryDefaultsTest — pins CorkRolloverContractFactoryDefaults behaviour for the Cork Rollover suite.
contract CorkRolloverContractFactoryDefaultsTest is Test {
    /// @notice Impl.
    CorkRolloverContract internal impl;
    /// @notice Erc7484.

    MockERC7484 internal erc7484;
    /// @notice Test fixture setup.

    function setUp() public {
        impl = new CorkRolloverContract();
        erc7484 = new MockERC7484();
    }

    function _attesters(address a) internal pure returns (address[] memory out) {
        out = new address[](1);
        out[0] = a;
    }

    function _attesters(address a, address b) internal pure returns (address[] memory out) {
        out = new address[](2);
        out[0] = a;
        out[1] = b;
    }

    function _uniqueAttesters(uint256 n) internal pure returns (address[] memory out) {
        out = new address[](n);
        uint256 baseKey = 0x1000;
        for (uint256 i = 0; i < n; ++i) {
            // Strictly ascending + unique + nonzero, as ERC-7484 / Rhinestone require.
            out[i] = address(uint160(baseKey + i + 1));
        }
    }

    function _deployTrustConfigTimelockForNextFactory()
        internal
        returns (TimelockController controller)
    {
        return _deployTrustConfigTimelockForNextFactory(1 hours, true, true, true, false);
    }

    function _deployTrustConfigTimelockForNextFactory(
        uint256 minDelay,
        bool proposer,
        bool canceller,
        bool executor,
        bool openExecutor
    ) internal returns (TimelockController controller) {
        uint64 nonce = vm.getNonce(address(this));
        address predictedFactory = vm.computeCreateAddress(address(this), nonce + 1);

        address[] memory proposers = proposer ? _singleton(predictedFactory) : new address[](0);
        address[] memory executors;
        if (executor && openExecutor) {
            executors = new address[](2);
            executors[0] = predictedFactory;
            executors[1] = address(0);
        } else if (openExecutor) {
            executors = _singleton(address(0));
        } else if (executor) {
            executors = _singleton(predictedFactory);
        } else {
            executors = new address[](0);
        }

        controller = new TimelockController(minDelay, proposers, executors, address(this));
        if (canceller && !controller.hasRole(controller.CANCELLER_ROLE(), predictedFactory)) {
            controller.grantRole(controller.CANCELLER_ROLE(), predictedFactory);
        }
        if (!canceller && controller.hasRole(controller.CANCELLER_ROLE(), predictedFactory)) {
            controller.revokeRole(controller.CANCELLER_ROLE(), predictedFactory);
        }
    }

    function _singleton(address value) internal pure returns (address[] memory out) {
        out = new address[](1);
        out[0] = value;
    }

    function _newFactory(address trustConfigTimelock_)
        internal
        returns (CorkRolloverContractFactory factory)
    {
        factory = _newFactoryWithDefaults(
            trustConfigTimelock_,
            1,
            _attesters(address(0xA1)),
            address(this),
            address(this),
            address(this),
            address(this)
        );
    }

    function _newFactoryWithDefaults(
        address trustConfigTimelock_,
        uint8 threshold,
        address[] memory attesters,
        address factoryAdmin,
        address defaultsManager,
        address settlerApprover,
        address settlerRevoker
    ) internal returns (CorkRolloverContractFactory factory) {
        factory = new CorkRolloverContractFactory(
            address(impl),
            address(erc7484),
            threshold,
            attesters,
            trustConfigTimelock_,
            address(this),
            factoryAdmin,
            defaultsManager,
            settlerApprover,
            settlerRevoker
        );
    }

    /// @notice Pins behaviour: constructor Reverts On Empty Default Attesters.
    function test_ConstructorRevertsOnEmptyDefaultAttesters() public {
        address[] memory empty = new address[](0);
        TimelockController tl = _deployTrustConfigTimelockForNextFactory();
        vm.expectRevert(CorkRolloverContractFactory__EmptyDefaultAttesters.selector);
        new CorkRolloverContractFactory(
            address(impl),
            address(erc7484),
            1,
            empty,
            address(tl),
            address(this),
            address(this),
            address(this),
            address(this),
            address(this)
        );
    }

    /// @notice Pins behaviour: constructor Reverts On Zero Threshold.
    function test_ConstructorRevertsOnZeroThreshold() public {
        TimelockController tl = _deployTrustConfigTimelockForNextFactory();
        vm.expectRevert(CorkRolloverContractFactory__InvalidDefaultThreshold.selector);
        _newFactoryWithDefaults(
            address(tl),
            0,
            _attesters(address(0xA1)),
            address(this),
            address(this),
            address(this),
            address(this)
        );
    }

    /// @notice Pins behaviour: constructor Reverts On Threshold Exceeding Attester Count.
    function test_ConstructorRevertsOnThresholdExceedingAttesterCount() public {
        TimelockController tl = _deployTrustConfigTimelockForNextFactory();
        vm.expectRevert(CorkRolloverContractFactory__InvalidDefaultThreshold.selector);
        _newFactoryWithDefaults(
            address(tl),
            2,
            _attesters(address(0xA1)),
            address(this),
            address(this),
            address(this),
            address(this)
        );
    }

    /// @notice Pins behaviour: constructor Reverts On Zero Address In Attesters.
    function test_ConstructorRevertsOnZeroAddressInAttesters() public {
        TimelockController tl = _deployTrustConfigTimelockForNextFactory();
        vm.expectRevert(CorkRolloverContractFactory__ZeroAddress.selector);
        _newFactoryWithDefaults(
            address(tl),
            1,
            _attesters(address(0)),
            address(this),
            address(this),
            address(this),
            address(this)
        );
    }

    /// @notice Pins behaviour: constructor Reverts On Duplicate Attesters.
    function test_ConstructorRevertsOnDuplicateAttesters() public {
        address dup = address(0xA1);
        TimelockController tl = _deployTrustConfigTimelockForNextFactory();
        vm.expectRevert(
            abi.encodeWithSelector(CorkRolloverContractFactory__DuplicateAttester.selector, dup)
        );
        _newFactoryWithDefaults(
            address(tl),
            2,
            _attesters(dup, dup),
            address(this),
            address(this),
            address(this),
            address(this)
        );
    }

    /// @notice Constructor rejects unsorted (descending) default attesters.
    function test_ConstructorRevertsOnUnsortedAttesters() public {
        TimelockController tl = _deployTrustConfigTimelockForNextFactory();
        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContractFactory__UnsortedAttesters.selector,
                address(0xA2),
                address(0xA1)
            )
        );
        _newFactoryWithDefaults(
            address(tl),
            2,
            _attesters(address(0xA2), address(0xA1)),
            address(this),
            address(this),
            address(this),
            address(this)
        );
    }

    /// @notice setDefaults rejects unsorted (descending) attesters.
    function test_SetDefaults_RevertsOnUnsortedAttesters() public {
        TimelockController tl = _deployTrustConfigTimelockForNextFactory();
        CorkRolloverContractFactory f = _newFactory(address(tl));
        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContractFactory__UnsortedAttesters.selector,
                address(0xB2),
                address(0xB1)
            )
        );
        f.setDefaults(2, _attesters(address(0xB2), address(0xB1)), address(erc7484));
    }

    /// @notice setDefaults accepts strictly-ascending multi-attester defaults.
    function test_SetDefaults_AcceptsSortedAttesters() public {
        TimelockController tl = _deployTrustConfigTimelockForNextFactory();
        CorkRolloverContractFactory f = _newFactory(address(tl));
        f.setDefaults(2, _attesters(address(0xB1), address(0xB2)), address(erc7484));
        address[] memory got = f.defaultAttesters();
        assertEq(got.length, 2, "sorted defaults length");
        assertEq(got[0], address(0xB1), "sorted defaults[0]");
        assertEq(got[1], address(0xB2), "sorted defaults[1]");
    }

    /// @notice Constructor accepts exactly `MAX_TRUST_ATTESTERS` unique attesters.
    function test_ConstructorAcceptsMaxAttesters() public {
        TimelockController tl = _deployTrustConfigTimelockForNextFactory();
        CorkRolloverContractFactory f = new CorkRolloverContractFactory(
            address(impl),
            address(erc7484),
            16,
            _uniqueAttesters(16),
            address(tl),
            address(this),
            address(this),
            address(this),
            address(this),
            address(this)
        );
        assertEq(f.MAX_TRUST_ATTESTERS(), 16);
        assertEq(f.defaultAttesters().length, 16);
    }

    /// @notice Constructor rejects attester lists longer than `MAX_TRUST_ATTESTERS`.
    function test_ConstructorRevertsOnTooManyAttesters() public {
        TimelockController tl = _deployTrustConfigTimelockForNextFactory();
        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContractFactory__TooManyAttesters.selector, uint256(17), uint256(16)
            )
        );
        _newFactoryWithDefaults(
            address(tl),
            16,
            _uniqueAttesters(17),
            address(this),
            address(this),
            address(this),
            address(this)
        );
    }

    /// @notice Pins behaviour: constructor Stores Defaults And Exposes Via Getter.
    function test_ConstructorStoresDefaultsAndExposesViaGetter() public {
        address[] memory ds = _attesters(address(0xBABE), address(0xCAFE));
        TimelockController tl = _deployTrustConfigTimelockForNextFactory();
        CorkRolloverContractFactory f = new CorkRolloverContractFactory(
            address(impl),
            address(erc7484),
            2,
            ds,
            address(tl),
            address(this),
            address(this),
            address(this),
            address(this),
            address(this)
        );
        address[] memory got = f.defaultAttesters();
        assertEq(got.length, 2);
        assertEq(got[0], address(0xBABE), "default attester[0]");
        assertEq(got[1], address(0xCAFE), "default attester[1]");
        assertEq(f.DEFAULT_TRUST_THRESHOLD(), 2);
    }

    /// @notice Pins behaviour: constructor Cork Banlist Arg Removed.
    function test_ConstructorCorkBanlistArgRemoved() public {
        bytes memory oldAbi = abi.encodeWithSignature(
            "newCorkRolloverContractFactory(address,address,address,address)",
            address(impl),
            address(0xB1),
            address(erc7484),
            address(this)
        );
        (bool ok,) = address(impl).call(oldAbi);
        assertFalse(ok, "old 4-arg ctor selector must not resolve");
    }

    /// @notice Constructor rejects a zero trust-config timelock address.
    function test_ConstructorRevertsOnZeroTrustConfigTimelock() public {
        vm.expectRevert(CorkRolloverContractFactory__ZeroAddress.selector);
        _newFactory(address(0));
    }

    /// @notice Constructor rejects a trust-config timelock address with no code.
    function test_ConstructorRevertsOnCodelessTrustConfigTimelock() public {
        address eoa = makeAddr("timelock-eoa");
        vm.expectRevert(
            abi.encodeWithSelector(CorkRolloverContractFactory__AddressHasNoCode.selector, eoa)
        );
        _newFactory(eoa);
    }

    /// @notice Constructor accepts a trust-config timelock with zero delay.
    function test_ConstructorAcceptsZeroTrustConfigTimelockDelay() public {
        TimelockController tl = _deployTrustConfigTimelockForNextFactory(0, true, true, true, false);
        CorkRolloverContractFactory f = _newFactory(address(tl));
        assertEq(f.trustConfigTimelock(), address(tl));
        assertEq(tl.getMinDelay(), 0);
    }

    /// @notice Constructor accepts exactly `MAX_TRUST_CONFIG_DELAY`.
    function test_ConstructorAcceptsMaxTrustConfigTimelockDelay() public {
        TimelockController tl =
            _deployTrustConfigTimelockForNextFactory(4 hours, true, true, true, false);
        CorkRolloverContractFactory f = _newFactory(address(tl));
        assertEq(f.MAX_TRUST_CONFIG_DELAY(), 4 hours);
        assertEq(f.trustConfigTimelock(), address(tl));
    }

    /// @notice Constructor rejects a trust-config timelock above the protocol cap.
    function test_ConstructorRevertsOnTrustConfigTimelockDelayAboveMax() public {
        TimelockController tl =
            _deployTrustConfigTimelockForNextFactory(4 hours + 1, true, true, true, false);
        vm.expectRevert(CorkRolloverContractFactory__InvalidTrustConfigTimelockDelay.selector);
        _newFactory(address(tl));
    }

    /// @notice Constructor rejects a trust-config timelock missing factory proposer rights.
    function test_ConstructorRevertsWhenTrustConfigTimelockMissingProposerRole() public {
        TimelockController tl =
            _deployTrustConfigTimelockForNextFactory(1 hours, false, true, true, false);
        vm.expectPartialRevert(CorkRolloverContractFactory__TrustConfigTimelockMissingRole.selector);
        _newFactory(address(tl));
    }

    /// @notice Constructor rejects a trust-config timelock missing factory canceller rights.
    function test_ConstructorRevertsWhenTrustConfigTimelockMissingCancellerRole() public {
        TimelockController tl =
            _deployTrustConfigTimelockForNextFactory(1 hours, true, false, true, false);
        vm.expectPartialRevert(CorkRolloverContractFactory__TrustConfigTimelockMissingRole.selector);
        _newFactory(address(tl));
    }

    /// @notice Constructor rejects a trust-config timelock the factory cannot execute through.
    function test_ConstructorRevertsWhenTrustConfigTimelockCannotExecute() public {
        TimelockController tl =
            _deployTrustConfigTimelockForNextFactory(1 hours, true, true, false, false);
        vm.expectPartialRevert(
            CorkRolloverContractFactory__TrustConfigTimelockCannotExecute.selector
        );
        _newFactory(address(tl));
    }

    /// @notice Constructor rejects open-executor-only trust-config timelock wiring.
    function test_ConstructorRevertsOnOpenExecutorOnlyTrustConfigTimelock() public {
        TimelockController tl =
            _deployTrustConfigTimelockForNextFactory(1 hours, true, true, false, true);
        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContractFactory__TrustConfigTimelockCannotExecute.selector,
                vm.computeCreateAddress(address(this), vm.getNonce(address(this)))
            )
        );
        _newFactory(address(tl));
    }

    /// @notice Constructor rejects trust-config timelock wiring with both Factory and open executor.
    function test_ConstructorRevertsOnFactoryAndOpenExecutorTrustConfigTimelock() public {
        TimelockController tl =
            _deployTrustConfigTimelockForNextFactory(1 hours, true, true, true, true);
        vm.expectRevert(CorkRolloverContractFactory__TrustConfigTimelockOpenExecutor.selector);
        _newFactory(address(tl));
    }

    /// @notice Constructor grants factory roles to explicit role-holder parameters.
    function test_ConstructorGrantsFactoryRolesToPassedRoleHolders() public {
        address admin = makeAddr("factory-admin");
        address defaultsManager = makeAddr("defaults-manager");
        address approver = makeAddr("settler-approver");
        address revoker = makeAddr("settler-revoker");
        TimelockController tl = _deployTrustConfigTimelockForNextFactory();

        CorkRolloverContractFactory f = _newFactoryWithDefaults(
            address(tl), 1, _attesters(address(0xA1)), admin, defaultsManager, approver, revoker
        );

        assertTrue(f.hasRole(f.DEFAULT_ADMIN_ROLE(), admin), "factory admin role");
        assertTrue(f.hasRole(f.DEFAULTS_MANAGER_ROLE(), defaultsManager), "defaults manager");
        assertTrue(f.hasRole(f.SETTLER_APPROVER_ROLE(), approver), "settler approver");
        assertTrue(f.hasRole(f.SETTLER_REVOKER_ROLE(), revoker), "settler revoker");
        assertTrue(
            f.hasRole(f.TRUST_CONFIG_DELAY_MANAGER_ROLE(), admin), "delay manager defaults admin"
        );
        assertFalse(f.hasRole(f.DEFAULT_ADMIN_ROLE(), address(this)), "no implicit deployer admin");
    }
}
