// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { MockERC7484 } from "../../mocks/MockERC7484.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { CorkRolloverContract } from "src/CorkRolloverContract.sol";
import { CorkRolloverContractFactory } from "src/CorkRolloverContractFactory.sol";
import {
    CorkRolloverContract__EmptyDefaultAttesters,
    CorkRolloverContract__InvalidThreshold,
    CorkRolloverContract__InvalidTrustAttesterOrder,
    CorkRolloverContract__RegistryZero,
    CorkRolloverContract__TooManyAttesters
} from "src/errors/CorkRolloverContractErrors.sol";
import { ModuleType } from "src/interfaces/external/erc7484/IERC7484.sol";
import { ICorkRolloverContract } from "src/interfaces/rollover/ICorkRolloverContract.sol";

/// @notice CorkRolloverContractDefaultsInitTest — pins CorkRolloverContractDefaultsInit behaviour for the Cork Rollover suite.
contract CorkRolloverContractDefaultsInitTest is Test {
    /// @notice Impl.
    CorkRolloverContract internal impl;
    /// @notice Erc7484.

    MockERC7484 internal erc7484;
    /// @notice Factory.

    CorkRolloverContractFactory internal factory;
    /// @notice Att a.

    address internal constant ATT_A = address(0xA1);
    /// @notice Att b.

    address internal constant ATT_B = address(0xA2);
    /// @notice Test fixture setup.

    function setUp() public {
        impl = new CorkRolloverContract();
        erc7484 = new MockERC7484();
        address[] memory defaults = new address[](2);
        defaults[0] = ATT_A;
        defaults[1] = ATT_B;
        TimelockController trustConfigTimelock = _deployTrustConfigTimelockForNextFactory();
        factory = new CorkRolloverContractFactory(
            address(impl),
            address(erc7484),
            2,
            defaults,
            address(trustConfigTimelock),
            address(this),
            address(this),
            address(this),
            address(this),
            address(this)
        );
    }

    function _deployTrustConfigTimelockForNextFactory()
        internal
        returns (TimelockController controller)
    {
        uint64 nonce = vm.getNonce(address(this));
        address predictedFactory = vm.computeCreateAddress(address(this), nonce + 1);
        address[] memory proposers = new address[](1);
        proposers[0] = predictedFactory;
        address[] memory executors = new address[](1);
        executors[0] = predictedFactory;
        controller = new TimelockController(1 hours, proposers, executors, address(this));
    }

    function _deploy() internal returns (address rolloverContract) {
        address cptHolder = makeAddr("cptHolder");
        vm.prank(cptHolder);
        rolloverContract = factory.deployRolloverContract();
    }

    /// @notice Pins behaviour: initialize Seeds Live Trust From Factory Defaults.
    function test_InitializeSeedsLiveTrustFromFactoryDefaults() public {
        address rolloverContract = _deploy();
        ICorkRolloverContract.RolloverContractTrustSnapshot memory snap =
            ICorkRolloverContract(rolloverContract).rolloverContractSnapshot();
        assertEq(snap.liveTrustThreshold, 2, "liveThreshold = factory seed");
        assertEq(snap.liveTrustAttesters.length, 2, "liveAttesters length = factory seed");
        assertEq(snap.liveTrustAttesters[0], ATT_A, "liveAttester[0] = factory seed");
        assertEq(snap.liveTrustAttesters[1], ATT_B, "liveAttester[1] = factory seed");
    }

    /// @notice Pins behaviour: initialize Calls Trust Attesters On Rhinestone.
    function test_InitializeCallsTrustAttestersOnRhinestone() public {
        address rolloverContract = _deploy();

        assertEq(erc7484.lastThreshold(rolloverContract), 2, "registry threshold from init");
        address[] memory recorded = erc7484.attestersOf(rolloverContract);
        assertEq(recorded.length, 2, "registry attesters length from init");
        assertEq(recorded[0], ATT_A, "registry attester[0] from init");
        assertEq(recorded[1], ATT_B, "registry attester[1] from init");
    }
    /// @notice Emitted on rolloverContract initialized.
    /// @param registry ERC-7484 attester registry contract.
    /// @param threshold Trust threshold (number of attesters required).
    /// @param attesters Per-rolloverContract attester set.

    event RolloverContractInitialized(address registry, uint8 threshold, address[] attesters);

    /// @notice Pins behaviour: initialize Emits RolloverContract Initialized.
    function test_InitializeEmitsRolloverContractInitialized() public {
        address cptHolder = makeAddr("cptHolder-emit");
        address[] memory expectedAttesters = new address[](2);
        expectedAttesters[0] = ATT_A;
        expectedAttesters[1] = ATT_B;

        vm.recordLogs();
        vm.prank(cptHolder);
        address rolloverContract = factory.deployRolloverContract();
        Vm.Log[] memory entries = vm.getRecordedLogs();

        bool found;
        for (uint256 i = 0; i < entries.length; ++i) {
            if (entries[i].emitter != rolloverContract) {
                continue;
            }
            if (
                entries[i].topics[0]
                    != keccak256("RolloverContractInitialized(address,uint8,address[])")
            ) {
                continue;
            }
            (address registry, uint8 threshold, address[] memory attesters) =
                abi.decode(entries[i].data, (address, uint8, address[]));
            assertEq(registry, address(erc7484), "evt.registry");
            assertEq(threshold, 2, "evt.threshold");
            assertEq(attesters.length, 2, "evt.attesters.length");
            assertEq(attesters[0], ATT_A, "evt.attesters[0]");
            assertEq(attesters[1], ATT_B, "evt.attesters[1]");
            found = true;
            break;
        }
        require(found, "RolloverContractInitialized event must surface");
    }

    /// @notice Pins behaviour: initialize Rejects Zero Registry.
    function test_InitializeRejectsZeroRegistry() public {
        CorkRolloverContract freshImpl = new CorkRolloverContract();
        address cptHolder = makeAddr("cptHolder-zero");
        // CWIA trailer with address(0) baked as registry — initialize reads it via _registry().
        bytes memory args = abi.encodePacked(cptHolder, address(this), address(0));
        address freshRolloverContract = Clones.cloneWithImmutableArgs(address(freshImpl), args);
        address[] memory defaults = new address[](1);
        defaults[0] = ATT_A;
        vm.expectRevert(CorkRolloverContract__RegistryZero.selector);
        ICorkRolloverContract(freshRolloverContract).initialize(1, defaults);
    }

    /// @notice Pins behaviour: initialize Rejects Empty Defaults.
    function test_InitializeRejectsEmptyDefaults() public {
        CorkRolloverContract freshImpl = new CorkRolloverContract();
        address cptHolder = makeAddr("cptHolder-empty");
        bytes memory args = abi.encodePacked(cptHolder, address(this), address(erc7484));
        address freshRolloverContract = Clones.cloneWithImmutableArgs(address(freshImpl), args);
        address[] memory empty = new address[](0);
        vm.expectRevert(CorkRolloverContract__EmptyDefaultAttesters.selector);
        ICorkRolloverContract(freshRolloverContract).initialize(1, empty);
    }

    /// @notice Pins behaviour: initialize Rejects Zero Default Attester.
    function test_InitializeRejectsZeroDefaultAttester() public {
        CorkRolloverContract freshImpl = new CorkRolloverContract();
        address cptHolder = makeAddr("cptHolder-zero-attester");
        bytes memory args = abi.encodePacked(cptHolder, address(this), address(erc7484));
        address freshRolloverContract = Clones.cloneWithImmutableArgs(address(freshImpl), args);
        address[] memory defaults = new address[](1);
        defaults[0] = address(0);
        vm.expectRevert(CorkRolloverContract__InvalidThreshold.selector);
        ICorkRolloverContract(freshRolloverContract).initialize(1, defaults);
    }

    function _uniqueAttesters(uint256 n) internal pure returns (address[] memory out) {
        out = new address[](n);
        uint256 baseKey = 0x4000;
        for (uint256 i = 0; i < n; ++i) {
            // Strictly ascending + unique + nonzero, as ERC-7484 / Rhinestone require.
            out[i] = address(uint160(baseKey + i + 1));
        }
    }

    /// @notice initialize accepts exactly `MAX_TRUST_ATTESTERS` attesters.
    function test_InitializeAcceptsMaxAttesters() public {
        CorkRolloverContract freshImpl = new CorkRolloverContract();
        address cptHolder = makeAddr("cptHolder-max");
        bytes memory args = abi.encodePacked(cptHolder, address(this), address(erc7484));
        address freshRolloverContract = Clones.cloneWithImmutableArgs(address(freshImpl), args);
        vm.prank(address(this));
        ICorkRolloverContract(freshRolloverContract).initialize(16, _uniqueAttesters(16));
        ICorkRolloverContract.RolloverContractTrustSnapshot memory snap =
            ICorkRolloverContract(freshRolloverContract).rolloverContractSnapshot();
        assertEq(snap.liveTrustAttesters.length, 16);
    }

    /// @notice initialize rejects attester lists longer than `MAX_TRUST_ATTESTERS`.
    function test_InitializeRejectsTooManyAttesters() public {
        CorkRolloverContract freshImpl = new CorkRolloverContract();
        address cptHolder = makeAddr("cptHolder-too-many");
        bytes memory args = abi.encodePacked(cptHolder, address(this), address(erc7484));
        address freshRolloverContract = Clones.cloneWithImmutableArgs(address(freshImpl), args);
        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContract__TooManyAttesters.selector, uint256(17), uint256(16)
            )
        );
        vm.prank(address(this));
        ICorkRolloverContract(freshRolloverContract).initialize(16, _uniqueAttesters(17));
    }

    /// @notice initialize defensively rejects unsorted (descending) default attesters.
    function test_InitializeRejectsUnsortedDefaultAttesters() public {
        CorkRolloverContract freshImpl = new CorkRolloverContract();
        address holder = makeAddr("cptHolder-unsorted");
        bytes memory args = abi.encodePacked(holder, address(this), address(erc7484));
        address freshRolloverContract = Clones.cloneWithImmutableArgs(address(freshImpl), args);
        address[] memory defaults = new address[](2);
        defaults[0] = ATT_B; // 0xA2
        defaults[1] = ATT_A; // 0xA1 - descending
        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContract__InvalidTrustAttesterOrder.selector, ATT_B, ATT_A
            )
        );
        ICorkRolloverContract(freshRolloverContract).initialize(2, defaults);
    }

    /// @notice Pins behaviour: initialize Rejects Duplicate Default Attester.
    function test_InitializeRejectsDuplicateDefaultAttester() public {
        CorkRolloverContract freshImpl = new CorkRolloverContract();
        address cptHolder = makeAddr("cptHolder-duplicate-attester");
        bytes memory args = abi.encodePacked(cptHolder, address(this), address(erc7484));
        address freshRolloverContract = Clones.cloneWithImmutableArgs(address(freshImpl), args);
        address[] memory defaults = new address[](2);
        defaults[0] = ATT_A;
        defaults[1] = ATT_A;
        vm.expectRevert(CorkRolloverContract__InvalidThreshold.selector);
        ICorkRolloverContract(freshRolloverContract).initialize(2, defaults);
    }

    /// @notice Pins behaviour: initialize Is One Shot.
    function test_InitializeIsOneShot() public {
        address rolloverContract = _deploy();
        address[] memory defaults = new address[](1);
        defaults[0] = ATT_A;

        vm.prank(address(factory));
        vm.expectRevert();
        ICorkRolloverContract(rolloverContract).initialize(1, defaults);
    }

    /// @notice Pins behaviour: first Hook Call Passes Via Defaults.
    function test_FirstHookCallPassesViaDefaults() public {
        address rolloverContract = _deploy();
        address module = address(0xCAFE);

        erc7484.setAttestedType(module, _moduleTypeExecutor());

        vm.prank(rolloverContract);
        erc7484.check(module, _moduleTypeExecutor());
    }

    function _moduleTypeExecutor() internal pure returns (ModuleType) {
        return ModuleType.wrap(uint256(keccak256("CorkExecutorModuleV1")));
    }
}
