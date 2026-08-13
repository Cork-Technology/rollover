// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { CommonBase } from "forge-std/Base.sol";
import { StdCheats } from "forge-std/StdCheats.sol";
import { StdUtils } from "forge-std/StdUtils.sol";

import { CorkRolloverContractFactory } from "src/CorkRolloverContractFactory.sol";

/// @notice INV-FACTORY-QUEUE-CHECKS-OWNER handler — drives queue/cancel trust-config
///         paths with factory rolloverContracts, non-factory targets, owners, and non-owners.
/// @custom:invariant INV-FACTORY-QUEUE-CHECKS-OWNER
contract FactoryQueueChecksOwnerHandler is CommonBase, StdCheats, StdUtils {
    /// @notice Factory under test.
    CorkRolloverContractFactory public immutable factoryRef;

    /// @notice Factory-deployed rolloverContract corpus.
    address[] public rolloverContracts;
    /// @notice Owner for each `rolloverContracts[i]`.
    address[] public owners;

    /// @notice Known factory-rolloverContract mirror.
    mapping(address => bool) public knownFactoryRolloverContract;
    /// @notice Known owner for factory-deployed rolloverContracts.
    mapping(address => address) public knownOwner;

    /// @notice True if an unauthorized schedule/cancel succeeded.
    bool public unauthorizedSucceeded;
    /// @notice True if a no-rolloverContract caller schedule/cancel succeeded.
    bool public noRolloverContractCallerSucceeded;

    /// @notice Successful owner queue count.
    uint256 public ghostOwnerQueueSuccesses;
    /// @notice Successful owner cancel count.
    uint256 public ghostOwnerCancelSuccesses;
    /// @notice Unauthorized queue/cancel attempts that reverted.
    uint256 public ghostUnauthorizedReverts;
    /// @notice No-rolloverContract caller queue/cancel attempts that reverted.
    uint256 public ghostNoRolloverContractCallerReverts;
    /// @notice Fresh factory rolloverContracts deployed by the handler.
    uint256 public ghostDeployedRolloverContracts;

    /// @param factory_ Factory under test.
    /// @param initialRolloverContract Factory-deployed rolloverContract from the fixture.
    /// @param initialOwner Owner of `initialRolloverContract`.
    constructor(
        CorkRolloverContractFactory factory_,
        address initialRolloverContract,
        address initialOwner
    ) {
        factoryRef = factory_;
        _registerRolloverContract(initialRolloverContract, initialOwner);
    }

    /// @notice Deploy a fresh factory rolloverContract for a fuzz-derived owner and register it.
    /// @param ownerSeed Fuzz seed used to derive the owner.
    function deployFactoryRolloverContract(uint256 ownerSeed) external {
        address owner = _deriveAddress("factory-queue-owner", ownerSeed, address(0));
        if (factoryRef.rolloverContractOf(owner) != address(0)) {
            return;
        }

        vm.prank(owner);
        address rolloverContract = factoryRef.deployRolloverContract();
        _registerRolloverContract(rolloverContract, owner);
        ghostDeployedRolloverContracts++;
    }

    /// @notice Queue a valid trust config as the known cPT holder.
    /// @param indexSeed Fuzz seed selecting the factory rolloverContract.
    /// @param configSeed Fuzz seed selecting threshold/attesters.
    function queueAsOwner(uint256 indexSeed, uint256 configSeed) external {
        (address rolloverContract, address owner) = _selectRolloverContract(indexSeed);
        (uint8 threshold, address[] memory attesters) = _validConfig(configSeed);

        vm.prank(owner);
        try factoryRef.queueTrustConfig(threshold, attesters) {
            if (
                !knownFactoryRolloverContract[rolloverContract]
                    || knownOwner[rolloverContract] != owner
            ) {
                unauthorizedSucceeded = true;
            }
            ghostOwnerQueueSuccesses++;
        } catch {
            unauthorizedSucceeded = true;
        }
    }

    /// @notice Attempt to queue a valid trust config from a non-owner.
    /// @param indexSeed Fuzz seed selecting the factory rolloverContract.
    /// @param callerSeed Fuzz seed selecting the non-owner.
    /// @param configSeed Fuzz seed selecting threshold/attesters.
    function queueAsNonOwner(uint256 indexSeed, uint256 callerSeed, uint256 configSeed) external {
        (, address owner) = _selectRolloverContract(indexSeed);
        address caller = _deriveAddress("factory-queue-non-owner", callerSeed, owner);
        (uint8 threshold, address[] memory attesters) = _validConfig(configSeed);

        vm.prank(caller);
        try factoryRef.queueTrustConfig(threshold, attesters) {
            unauthorizedSucceeded = true;
        } catch {
            ghostUnauthorizedReverts++;
        }
    }

    /// @notice Attempt to queue a valid trust config from a caller with no deployed rolloverContract.
    /// @param callerSeed Fuzz seed selecting the caller.
    /// @param targetSeed Fuzz seed selecting the non-factory target.
    /// @param configSeed Fuzz seed selecting threshold/attesters.
    function queueNonFactory(uint256 callerSeed, uint256 targetSeed, uint256 configSeed) external {
        _nonFactoryTarget(targetSeed);
        address caller = _deriveAddress("factory-queue-non-factory-caller", callerSeed, address(0));
        (uint8 threshold, address[] memory attesters) = _validConfig(configSeed);

        vm.prank(caller);
        try factoryRef.queueTrustConfig(threshold, attesters) {
            noRolloverContractCallerSucceeded = true;
        } catch {
            ghostNoRolloverContractCallerReverts++;
        }
    }

    /// @notice Ensure a pending owner-queued op exists, then cancel it as owner.
    /// @param indexSeed Fuzz seed selecting the factory rolloverContract.
    /// @param configSeed Fuzz seed selecting threshold/attesters if a queue is needed.
    function cancelAsOwner(uint256 indexSeed, uint256 configSeed) external {
        (address rolloverContract, address owner) = _selectRolloverContract(indexSeed);
        _ensureQueued(rolloverContract, owner, configSeed);

        vm.prank(owner);
        try factoryRef.cancelTrustConfig() {
            if (
                !knownFactoryRolloverContract[rolloverContract]
                    || knownOwner[rolloverContract] != owner
            ) {
                unauthorizedSucceeded = true;
            }
            ghostOwnerCancelSuccesses++;
        } catch {
            unauthorizedSucceeded = true;
        }
    }

    /// @notice Ensure a pending owner-queued op exists, then attempt cancel as non-owner.
    /// @param indexSeed Fuzz seed selecting the factory rolloverContract.
    /// @param callerSeed Fuzz seed selecting the non-owner.
    /// @param configSeed Fuzz seed selecting threshold/attesters if a queue is needed.
    function cancelAsNonOwner(uint256 indexSeed, uint256 callerSeed, uint256 configSeed) external {
        (address rolloverContract, address owner) = _selectRolloverContract(indexSeed);
        _ensureQueued(rolloverContract, owner, configSeed);
        address caller = _deriveAddress("factory-cancel-non-owner", callerSeed, owner);

        vm.prank(caller);
        try factoryRef.cancelTrustConfig() {
            unauthorizedSucceeded = true;
        } catch {
            ghostUnauthorizedReverts++;
        }
    }

    /// @notice Attempt to cancel from a caller with no deployed rolloverContract.
    /// @param callerSeed Fuzz seed selecting the caller.
    /// @param targetSeed Fuzz seed selecting the non-factory target.
    function cancelNonFactory(uint256 callerSeed, uint256 targetSeed) external {
        _nonFactoryTarget(targetSeed);
        address caller = _deriveAddress("factory-cancel-non-factory-caller", callerSeed, address(0));

        vm.prank(caller);
        try factoryRef.cancelTrustConfig() {
            noRolloverContractCallerSucceeded = true;
        } catch {
            ghostNoRolloverContractCallerReverts++;
        }
    }

    /// @notice Whether all observed successful queue/cancel paths were authorized.
    /// @return True if no unauthorized or non-factory success has been seen.
    function allSuccessfulTrustConfigOpsAuthorized() external view returns (bool) {
        return !unauthorizedSucceeded && !noRolloverContractCallerSucceeded;
    }

    /// @notice Whether both successful owner queue and cancel paths were exercised.
    /// @return True if the handler observed at least one owner queue and owner cancel.
    function ownerPathsExercised() external view returns (bool) {
        return ghostOwnerQueueSuccesses != 0 && ghostOwnerCancelSuccesses != 0;
    }

    function _registerRolloverContract(address rolloverContract, address owner) internal {
        if (knownFactoryRolloverContract[rolloverContract]) {
            return;
        }
        knownFactoryRolloverContract[rolloverContract] = true;
        knownOwner[rolloverContract] = owner;
        rolloverContracts.push(rolloverContract);
        owners.push(owner);
    }

    function _selectRolloverContract(uint256 indexSeed)
        internal
        view
        returns (address rolloverContract, address owner)
    {
        uint256 index = bound(indexSeed, 0, rolloverContracts.length - 1);
        rolloverContract = rolloverContracts[index];
        owner = owners[index];
    }

    function _ensureQueued(address rolloverContract, address owner, uint256 configSeed) internal {
        (,, uint64 effectiveAt) = factoryRef.pendingTrustConfig(rolloverContract);
        if (effectiveAt != 0) {
            return;
        }
        (uint8 threshold, address[] memory attesters) = _validConfig(configSeed);
        vm.prank(owner);
        factoryRef.queueTrustConfig(threshold, attesters);
        ghostOwnerQueueSuccesses++;
    }

    function _validConfig(uint256 configSeed)
        internal
        pure
        returns (uint8 threshold, address[] memory attesters)
    {
        bool twoAttesters = (configSeed & 1) == 1;
        if (twoAttesters) {
            attesters = new address[](2);
            address a0 =
                address(uint160(uint256(keccak256(abi.encode("attester-a", configSeed))) | 1));
            address a1 =
                address(uint160(uint256(keccak256(abi.encode("attester-b", configSeed))) | 1));
            if (a1 == a0) {
                a1 = address(uint160(a0) + 1);
            }
            // ERC-7484 requires strictly-ascending attesters; order the synthesized pair.
            (attesters[0], attesters[1]) = a0 < a1 ? (a0, a1) : (a1, a0);
            threshold = uint8(bound(configSeed >> 1, 1, 2));
        } else {
            attesters = new address[](1);
            attesters[0] =
                address(uint160(uint256(keccak256(abi.encode("attester", configSeed))) | 1));
            threshold = 1;
        }
    }

    function _nonFactoryTarget(uint256 targetSeed) internal view returns (address target) {
        target = _deriveAddress("factory-queue-non-factory-target", targetSeed, address(0));
        if (factoryRef.isDeployedRolloverContract(target)) {
            target = _deriveAddress("factory-queue-non-factory-target-alt", targetSeed, address(0));
        }
    }

    function _deriveAddress(string memory domain, uint256 seed, address avoid)
        internal
        pure
        returns (address derived)
    {
        derived = address(uint160(uint256(keccak256(abi.encode(domain, seed))) | 1));
        if (derived == avoid) {
            derived = address(uint160(derived) + 1);
        }
    }
}
