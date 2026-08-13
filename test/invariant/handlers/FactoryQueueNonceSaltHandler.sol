// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { CommonBase } from "forge-std/Base.sol";
import { StdCheats } from "forge-std/StdCheats.sol";
import { StdUtils } from "forge-std/StdUtils.sol";

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { CorkRolloverContractFactory } from "src/CorkRolloverContractFactory.sol";

/// @notice N-INV-FACTORY-QUEUE-NONCE-SALT-UNIQUE handler — verifies queue salts
///         advance monotonically and operation ids are never reused for a rolloverContract.
/// @custom:invariant N-INV-FACTORY-QUEUE-NONCE-SALT-UNIQUE
contract FactoryQueueNonceSaltHandler is CommonBase, StdCheats, StdUtils {
    /// @notice Factory under test.
    CorkRolloverContractFactory public immutable factoryRef;

    /// @notice External per-rolloverContract trust-config timelock.
    TimelockController public immutable timelockRef;

    /// @notice Factory-deployed rolloverContracts.
    address[] public rolloverContracts;

    /// @notice Owner for each rolloverContract.
    address[] public owners;

    /// @notice Next expected queue nonce per rolloverContract.
    mapping(address => uint64) public expectedNonce;

    /// @notice Seen timelock operation ids.
    mapping(bytes32 => bool) public seenOpId;

    /// @notice True if the expected nonce-derived op id was not scheduled.
    bool public unexpectedOpId;

    /// @notice True if a successful queue reused a prior op id.
    bool public reusedOpId;

    /// @notice Successful queue count.
    uint256 public ghostQueueSuccesses;

    /// @notice Fresh factory rolloverContracts deployed by this handler.
    uint256 public ghostDeployedRolloverContracts;

    /// @param factory_ Factory under test.
    /// @param initialRolloverContract Initial factory-deployed rolloverContract.
    /// @param initialOwner Initial cPT holder.
    constructor(
        CorkRolloverContractFactory factory_,
        address initialRolloverContract,
        address initialOwner
    ) {
        factoryRef = factory_;
        timelockRef = TimelockController(payable(factory_.trustConfigTimelock()));
        _registerRolloverContract(initialRolloverContract, initialOwner);
    }

    /// @notice Deploy a fresh rolloverContract so the invariant exercises independent nonce streams.
    /// @param ownerSeed Fuzz seed used to derive the owner.
    function deployFactoryRolloverContract(uint256 ownerSeed) external {
        address owner = _deriveAddress("factory-queue-nonce-owner", ownerSeed, address(0));
        if (factoryRef.rolloverContractOf(owner) != address(0)) {
            return;
        }

        vm.prank(owner);
        address rolloverContract = factoryRef.deployRolloverContract();
        _registerRolloverContract(rolloverContract, owner);
        ghostDeployedRolloverContracts++;
    }

    /// @notice Queue or overwrite a trust config and compare the emitted op id to ghost nonce.
    /// @param indexSeed Fuzz seed selecting the rolloverContract.
    /// @param configSeed Fuzz seed selecting threshold and attesters.
    function queueAsOwner(uint256 indexSeed, uint256 configSeed) external {
        (address rolloverContract, address owner) = _selectRolloverContract(indexSeed);
        (uint8 threshold, address[] memory attesters) = _validConfig(configSeed);

        uint64 nonce = expectedNonce[rolloverContract];
        bytes32 expectedSalt = keccak256(abi.encode(rolloverContract, nonce));
        bytes32 expectedOpId = _opId(rolloverContract, threshold, attesters, expectedSalt);

        vm.prank(owner);
        try factoryRef.queueTrustConfig(threshold, attesters) {
            expectedNonce[rolloverContract] = nonce + 1;
            ghostQueueSuccesses++;
            if (timelockRef.getTimestamp(expectedOpId) == 0) {
                unexpectedOpId = true;
            }
            if (seenOpId[expectedOpId]) {
                reusedOpId = true;
            }
            seenOpId[expectedOpId] = true;
        } catch {
            unexpectedOpId = true;
        }
    }

    /// @notice Whether every successful queue used the ghost nonce-derived salt.
    /// @return True if no mismatch was observed.
    function allQueuedOpIdsMatchedExpectedNonce() external view returns (bool) {
        return !unexpectedOpId;
    }

    /// @notice Whether every successful queue produced a unique operation id.
    /// @return True if no operation id was reused.
    function allQueuedOpIdsUnique() external view returns (bool) {
        return !reusedOpId;
    }

    function _registerRolloverContract(address rolloverContract, address owner) internal {
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

    function _opId(
        address rolloverContract,
        uint8 threshold,
        address[] memory attesters,
        bytes32 salt
    ) internal view returns (bytes32) {
        bytes memory data = abi.encodeWithSelector(
            factoryRef.relayTrustConfig.selector, rolloverContract, salt, threshold, attesters
        );
        return timelockRef.hashOperation(address(factoryRef), 0, data, bytes32(0), salt);
    }

    function _validConfig(uint256 configSeed)
        internal
        pure
        returns (uint8 threshold, address[] memory attesters)
    {
        bool twoAttesters = (configSeed & 1) == 1;
        if (twoAttesters) {
            attesters = new address[](2);
            address a0 = address(
                uint160(uint256(keccak256(abi.encode("nonce-attester-a", configSeed))) | 1)
            );
            address a1 = address(
                uint160(uint256(keccak256(abi.encode("nonce-attester-b", configSeed))) | 1)
            );
            if (a1 == a0) {
                a1 = address(uint160(a0) + 1);
            }
            // ERC-7484 requires strictly-ascending attesters; order the synthesized pair.
            (attesters[0], attesters[1]) = a0 < a1 ? (a0, a1) : (a1, a0);
            threshold = uint8(bound(configSeed >> 1, 1, 2));
        } else {
            attesters = new address[](1);
            attesters[0] =
                address(uint160(uint256(keccak256(abi.encode("nonce-attester", configSeed))) | 1));
            threshold = 1;
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
