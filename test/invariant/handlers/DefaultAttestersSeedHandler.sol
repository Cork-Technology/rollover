// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { CommonBase } from "forge-std/Base.sol";
import { StdCheats } from "forge-std/StdCheats.sol";
import { StdUtils } from "forge-std/StdUtils.sol";

import { MockERC7484 } from "../../mocks/MockERC7484.sol";
import { CorkRolloverContractFactory } from "src/CorkRolloverContractFactory.sol";
import { ICorkRolloverContract } from "src/interfaces/rollover/ICorkRolloverContract.sol";

/// @notice INV-DEFAULT-ATTESTERS-FACTORY-SEEDED family handler — drives factory default-attester reads against the seeded baseline.
/// @custom:invariant INV-DEFAULT-ATTESTERS-FACTORY-SEEDED
contract DefaultAttestersSeedHandler is CommonBase, StdCheats, StdUtils {
    /// @notice Factory ref.
    /// @return factoryRef Stored factory ref value.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)

    CorkRolloverContractFactory public immutable factoryRef;
    /// @notice Registry ref.
    /// @return registryRef Stored registry ref value.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)

    MockERC7484 public immutable registryRef;
    /// @notice Registered rolloverContracts.
    /// @return registeredRolloverContracts Stored registered rolloverContracts value.

    address[] public registeredRolloverContracts;
    /// @notice Registered.
    /// @return registered Stored registered value.

    mapping(address => bool) public registered;
    /// @notice Owner of.
    /// @return ownerOf Stored owner of value.

    mapping(address => address) public ownerOf;
    /// @notice Snapshotted default threshold.
    /// @return snapshottedDefaultThreshold Stored snapshotted default threshold value.

    mapping(address => uint8) public snapshottedDefaultThreshold;

    /// @notice _snapshotted default attesters.
    mapping(address => address[]) internal _snapshottedDefaultAttesters;
    /// @notice First apply timestamp.
    /// @return firstApplyTimestamp Stored first apply timestamp value.

    mapping(address => uint64) public firstApplyTimestamp;
    /// @notice Pre override seed drift detected.
    /// @return preOverrideSeedDriftDetected Stored pre override seed drift detected value.

    bool public preOverrideSeedDriftDetected;
    /// @notice Ghost registrations.
    /// @return ghostRegistrations Stored ghost registrations value.

    uint64 public ghostRegistrations;
    /// @notice Ghost observations.
    /// @return ghostObservations Stored ghost observations value.

    uint64 public ghostObservations;
    /// @notice Ghost queues.
    /// @return ghostQueues Stored ghost queues value.

    uint64 public ghostQueues;
    /// @notice Ghost applies.
    /// @return ghostApplies Stored ghost applies value.

    uint64 public ghostApplies;
    /// @notice Ghost deploys.
    /// @return ghostDeploys Stored ghost deploys value.

    uint64 public ghostDeploys;
    /// @notice Ghost warps.
    /// @return ghostWarps Stored ghost warps value.

    uint64 public ghostWarps;

    /// @notice Most recently queued threshold per rolloverContract (mirrors the factory's pending op).
    mapping(address => uint8) public ghostLastQueueThresholdFor;

    /// @notice Most recently queued attester list per rolloverContract (mirrors the factory's pending op).
    mapping(address => address[]) public ghostLastQueueAttestersFor;

    /// @param registry_ registry_.
    /// @param factory_ factory_.
    constructor(CorkRolloverContractFactory factory_, MockERC7484 registry_) {
        factoryRef = factory_;
        registryRef = registry_;
    }

    /// @notice handler action: register rolloverContract.
    /// @param rolloverContractAddr Cork rolloverContract address.
    /// @param ownerAddr Owner address.
    function registerRolloverContract(address rolloverContractAddr, address ownerAddr) external {
        if (registered[rolloverContractAddr]) {
            return;
        }
        registered[rolloverContractAddr] = true;
        registeredRolloverContracts.push(rolloverContractAddr);
        ownerOf[rolloverContractAddr] = ownerAddr;
        snapshottedDefaultThreshold[rolloverContractAddr] = factoryRef.DEFAULT_TRUST_THRESHOLD();
        address[] memory defs = factoryRef.defaultAttesters();
        for (uint256 i = 0; i < defs.length; ++i) {
            _snapshottedDefaultAttesters[rolloverContractAddr].push(defs[i]);
        }
        ghostRegistrations++;
    }

    /// @notice handler action: deploy rolloverContract.
    /// @param ownerSeed Fuzz seed used to pick an owner from a bounded set.
    function deployRolloverContract(uint256 ownerSeed) external {
        address pranker = address(uint160(uint256(keccak256(abi.encode("dep", ownerSeed)))) | 1);

        vm.prank(pranker);
        try factoryRef.deployRolloverContract() returns (address newRolloverContract) {
            ghostDeploys++;
            if (!registered[newRolloverContract]) {
                registered[newRolloverContract] = true;
                registeredRolloverContracts.push(newRolloverContract);
                ownerOf[newRolloverContract] = pranker;
                snapshottedDefaultThreshold[newRolloverContract] =
                    factoryRef.DEFAULT_TRUST_THRESHOLD();
                address[] memory defs = factoryRef.defaultAttesters();
                for (uint256 i = 0; i < defs.length; ++i) {
                    _snapshottedDefaultAttesters[newRolloverContract].push(defs[i]);
                }
                ghostRegistrations++;
            }
        } catch { }
    }

    /// @notice handler action: observe seed consistency.
    /// @param indexSeed Fuzz seed used to pick an index from a bounded set.
    function observeSeedConsistency(uint256 indexSeed) external {
        uint256 n = registeredRolloverContracts.length;
        if (n == 0) {
            return;
        }
        address cAddr = registeredRolloverContracts[bound(indexSeed, 0, n - 1)];
        ghostObservations++;
        if (firstApplyTimestamp[cAddr] != 0) {
            return;
        }

        ICorkRolloverContract.RolloverContractTrustSnapshot memory snap =
            ICorkRolloverContract(cAddr).rolloverContractSnapshot();
        uint8 seedThreshold = snapshottedDefaultThreshold[cAddr];
        address[] storage seedAttesters = _snapshottedDefaultAttesters[cAddr];

        if (snap.liveTrustThreshold != seedThreshold) {
            preOverrideSeedDriftDetected = true;
            return;
        }

        if (snap.liveTrustAttesters.length != seedAttesters.length) {
            preOverrideSeedDriftDetected = true;
            return;
        }
        for (uint256 i = 0; i < seedAttesters.length; ++i) {
            if (snap.liveTrustAttesters[i] != seedAttesters[i]) {
                preOverrideSeedDriftDetected = true;
                return;
            }
        }

        if (registryRef.lastThreshold(cAddr) != seedThreshold) {
            preOverrideSeedDriftDetected = true;
            return;
        }
        address[] memory regAttesters = registryRef.attestersOf(cAddr);
        if (regAttesters.length != seedAttesters.length) {
            preOverrideSeedDriftDetected = true;
            return;
        }
        for (uint256 i = 0; i < seedAttesters.length; ++i) {
            if (regAttesters[i] != seedAttesters[i]) {
                preOverrideSeedDriftDetected = true;
                return;
            }
        }
    }

    /// @notice handler action: queue trust.
    /// @param indexSeed Fuzz seed used to pick an index from a bounded set.
    /// @param threshold Trust threshold (number of attesters required).
    /// @param attesterSeed Fuzz seed used to pick an attester from a bounded set.
    function queueTrust(uint256 indexSeed, uint8 threshold, uint8 attesterSeed) external {
        uint256 n = registeredRolloverContracts.length;
        if (n == 0) {
            return;
        }
        address cAddr = registeredRolloverContracts[bound(indexSeed, 0, n - 1)];
        uint8 atLen = uint8(bound(attesterSeed, 1, 3));
        uint8 th = uint8(bound(threshold, 1, atLen));
        address[] memory at = new address[](atLen);
        for (uint256 i = 0; i < atLen; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast)
            at[i] = address(uint160(0xB000 + i + 1));
        }
        vm.prank(ownerOf[cAddr]);
        try factoryRef.queueTrustConfig(th, at) {
            ghostQueues++;
            ghostLastQueueAttestersFor[cAddr] = at;
            ghostLastQueueThresholdFor[cAddr] = th;
        } catch { }
    }

    /// @notice handler action: apply trust.
    /// @param indexSeed Fuzz seed used to pick an index from a bounded set.
    function applyTrust(uint256 indexSeed) external {
        uint256 n = registeredRolloverContracts.length;
        if (n == 0) {
            return;
        }
        address cAddr = registeredRolloverContracts[bound(indexSeed, 0, n - 1)];
        uint8 th = ghostLastQueueThresholdFor[cAddr];
        if (th == 0 || ghostLastQueueAttestersFor[cAddr].length == 0) {
            return;
        }
        try factoryRef.applyTrustConfig(cAddr) {
            ghostApplies++;
            if (firstApplyTimestamp[cAddr] == 0) {
                // forge-lint: disable-next-line(unsafe-typecast)
                firstApplyTimestamp[cAddr] = uint64(block.timestamp);
            }
        } catch { }
    }

    /// @notice handler action: warp forward.
    /// @param delta Numeric delta.
    function warpForward(uint64 delta) external {
        uint64 d = uint64(bound(delta, 0, 4 hours));
        vm.warp(block.timestamp + d);
        ghostWarps++;
    }

    /// @notice handler action: registered count.
    /// @return Return value.
    function registeredCount() external view returns (uint256) {
        return registeredRolloverContracts.length;
    }

    /// @notice handler action: snapshotted default attester at.
    /// @param rolloverContractAddr Cork rolloverContract address.
    /// @param i Loop index.
    /// @return Return value.
    function snapshottedDefaultAttesterAt(address rolloverContractAddr, uint256 i)
        external
        view
        returns (address)
    {
        return _snapshottedDefaultAttesters[rolloverContractAddr][i];
    }
}
