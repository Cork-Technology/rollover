// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { MockERC7484 } from "../../mocks/MockERC7484.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { Test } from "forge-std/Test.sol";
import { CorkRolloverContract } from "src/CorkRolloverContract.sol";
import { CorkRolloverContractFactory } from "src/CorkRolloverContractFactory.sol";
import {
    CorkRolloverContractFactory__AlreadyDeployed
} from "src/errors/CorkRolloverContractFactoryErrors.sol";
import { ICorkRolloverContract } from "src/interfaces/rollover/ICorkRolloverContract.sol";
import { IRolloverContractLens } from "src/interfaces/rollover/IRolloverContractLens.sol";

/// @notice Pins deterministic CREATE2 deployment for per-owner rolloverContract clones.
contract CorkRolloverContractFactoryDeterministicTest is Test {
    /// @notice Test admin account for factory ownership and timelock admin roles.
    address internal constant ADMIN = address(0xA11CE);
    /// @notice Test manager account passed to the factory constructor.
    address internal constant MANAGER = address(0xB0B);
    /// @notice Default attester used to initialize newly deployed rollover contracts.
    address internal constant DEFAULT_ATTESTER = address(0xA771);

    /// @notice Shared rollover contract implementation used by test factories.
    CorkRolloverContract internal impl;
    /// @notice Shared mock ERC-7484 registry used by test factories.
    MockERC7484 internal erc7484;

    /// @notice Deploys the shared implementation and registry fixtures.
    function setUp() public {
        impl = new CorkRolloverContract();
        erc7484 = new MockERC7484();
    }

    /// @notice A predicted owner clone address matches deployment and initializes clone state.
    function test_predictMatchesDeployAndCloneInitializes() public {
        CorkRolloverContractFactory factory = _newFactory();
        address owner = makeAddr("owner");

        address predicted = factory.predictRolloverContractOf(owner);

        vm.prank(owner);
        address deployed = factory.deployRolloverContract();

        assertEq(deployed, predicted, "deploy lands at predicted address");
        assertEq(factory.rolloverContractOf(owner), predicted, "owner lookup");
        assertTrue(factory.isDeployedRolloverContract(predicted), "deployed flag");

        ICorkRolloverContract rollover = ICorkRolloverContract(predicted);
        assertEq(rollover.owner(), owner, "clone owner");
        assertEq(rollover.factory(), address(factory), "clone factory");

        ICorkRolloverContract.RolloverContractTrustSnapshot memory snapshot =
            rollover.rolloverContractSnapshot();
        assertEq(snapshot.erc7484Registry, address(erc7484), "clone registry");
        assertEq(snapshot.liveTrustThreshold, 1, "default threshold");
        assertEq(snapshot.liveTrustAttesters.length, 1, "default attester length");
        assertEq(snapshot.liveTrustAttesters[0], DEFAULT_ATTESTER, "default attester");
    }

    /// @notice Prior deployments for unrelated owners do not shift a target owner prediction.
    function test_targetPredictionAndDeploymentIgnoreUnrelatedPriorDeployments() public {
        CorkRolloverContractFactory factory = _newFactory();
        address targetOwner = makeAddr("targetOwner");
        address predictedBefore = factory.predictRolloverContractOf(targetOwner);

        _deployFor(factory, makeAddr("priorOwnerA"));
        _deployFor(factory, makeAddr("priorOwnerB"));
        _deployFor(factory, makeAddr("priorOwnerC"));

        address predictedAfter = factory.predictRolloverContractOf(targetOwner);
        assertEq(predictedAfter, predictedBefore, "prediction remains stable");

        vm.prank(targetOwner);
        address deployed = factory.deployRolloverContract();

        assertEq(deployed, predictedBefore, "target deploy ignores prior clone count");
        assertEq(factory.rolloverContractOf(targetOwner), predictedBefore, "target lookup");
        assertTrue(factory.isDeployedRolloverContract(predictedBefore), "target flag");
    }

    /// @notice Distinct owners predict and deploy to distinct rollover contract addresses.
    function test_distinctOwnersHaveDistinctPredictedAndDeployedAddresses() public {
        CorkRolloverContractFactory factory = _newFactory();
        address ownerA = makeAddr("ownerA");
        address ownerB = makeAddr("ownerB");

        address predictedA = factory.predictRolloverContractOf(ownerA);
        address predictedB = factory.predictRolloverContractOf(ownerB);

        assertNotEq(predictedA, predictedB, "predictions differ");

        address deployedA = _deployFor(factory, ownerA);
        address deployedB = _deployFor(factory, ownerB);

        assertEq(deployedA, predictedA, "owner A deploy");
        assertEq(deployedB, predictedB, "owner B deploy");
        assertNotEq(deployedA, deployedB, "deployed addresses differ");
    }

    /// @notice A same-owner redeploy still reverts and leaves factory state unchanged.
    function test_redeployBySameOwnerStillRevertsAndStateStaysCorrect() public {
        CorkRolloverContractFactory factory = _newFactory();
        address owner = makeAddr("owner");
        address predicted = factory.predictRolloverContractOf(owner);

        address deployed = _deployFor(factory, owner);
        assertEq(deployed, predicted, "first deploy");

        vm.expectRevert(
            abi.encodeWithSelector(CorkRolloverContractFactory__AlreadyDeployed.selector, owner)
        );
        vm.prank(owner);
        factory.deployRolloverContract();

        assertEq(factory.rolloverContractOf(owner), predicted, "owner lookup unchanged");
        assertTrue(factory.isDeployedRolloverContract(predicted), "deployed flag unchanged");
    }

    /// @notice Prediction is independent of chain id when factory inputs are unchanged.
    function test_predictionDoesNotDependOnChainId() public {
        address owner = makeAddr("sameOwner");

        uint256 snapshot = vm.snapshotState();
        vm.chainId(1);
        address mainnetPrediction = _newFactory().predictRolloverContractOf(owner);
        vm.revertToState(snapshot);

        vm.chainId(2);
        address otherChainPrediction = _newFactory().predictRolloverContractOf(owner);

        assertEq(otherChainPrediction, mainnetPrediction, "same inputs predict same address");
    }

    /// @notice Registry rotation changes prediction for an owner without an existing clone.
    function test_registryRotationChangesPredictionForUndeployedOwner() public {
        CorkRolloverContractFactory factory = _newFactory();
        address owner = makeAddr("registryRotationOwner");
        address predictionBefore = factory.predictRolloverContractOf(owner);

        MockERC7484 newRegistry = new MockERC7484();
        address[] memory defaults = new address[](1);
        defaults[0] = DEFAULT_ATTESTER;

        vm.prank(ADMIN);
        factory.setDefaults(1, defaults, address(newRegistry));

        address predictionAfter = factory.predictRolloverContractOf(owner);
        assertNotEq(predictionAfter, predictionBefore, "registry changes CWIA initcode");

        vm.prank(owner);
        address deployed = factory.deployRolloverContract();

        assertEq(deployed, predictionAfter, "deploy lands at rotated-registry prediction");

        ICorkRolloverContract.RolloverContractTrustSnapshot memory snapshot =
            ICorkRolloverContract(deployed).rolloverContractSnapshot();
        assertEq(snapshot.erc7484Registry, address(newRegistry), "snapshot registry");

        IRolloverContractLens.RolloverContractConfig memory config =
            factory.rolloverContractConfig(deployed);
        assertEq(config.erc7484Registry, address(newRegistry), "config registry");
    }

    /// @notice Deploys a rollover contract from the requested owner address.
    function _deployFor(CorkRolloverContractFactory factory, address owner)
        internal
        returns (address deployed)
    {
        vm.prank(owner);
        deployed = factory.deployRolloverContract();
    }

    /// @notice Deploys a factory using the shared implementation and registry fixtures.
    function _newFactory() internal returns (CorkRolloverContractFactory factory) {
        address[] memory defaults = new address[](1);
        defaults[0] = DEFAULT_ATTESTER;
        TimelockController trustConfigTimelock = _deployTrustConfigTimelockForNextFactory();

        factory = new CorkRolloverContractFactory(
            address(impl),
            address(erc7484),
            1,
            defaults,
            address(trustConfigTimelock),
            MANAGER,
            ADMIN,
            ADMIN,
            ADMIN,
            ADMIN
        );
    }

    /// @notice Deploys a timelock whose proposer/executor is the next factory address.
    function _deployTrustConfigTimelockForNextFactory()
        internal
        returns (TimelockController controller)
    {
        uint64 nonce = vm.getNonce(address(this));
        address predictedFactory = vm.computeCreateAddress(address(this), nonce + 1);
        address[] memory factoryOnly = _singleton(predictedFactory);

        controller = new TimelockController(1 hours, factoryOnly, factoryOnly, ADMIN);
    }

    /// @notice Returns a one-element address array.
    function _singleton(address value) internal pure returns (address[] memory out) {
        out = new address[](1);
        out[0] = value;
    }
}
