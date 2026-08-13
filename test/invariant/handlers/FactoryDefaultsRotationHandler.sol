// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";
import { CorkRolloverContractFactory } from "src/CorkRolloverContractFactory.sol";
import { ICorkRolloverContract } from "src/interfaces/rollover/ICorkRolloverContract.sol";

/// @notice INV-FACTORY-DEFAULTS-MANAGED handler — fuzzes setDefaults/deploy
///         interleavings for factory-wide default trust config rotation.
/// @custom:invariant INV-FACTORY-DEFAULTS-MANAGED
contract FactoryDefaultsRotationHandler is Test {
    /// @notice Factory under test.
    /// @return factory Stored factory.
    CorkRolloverContractFactory public immutable factory;
    /// @notice Admin address allowed to set defaults.
    /// @return owner Stored owner.
    address public immutable owner;
    /// @notice RolloverContract deployed before any handler-authored defaults update.
    /// @return existingRolloverContract Stored rolloverContract.
    address public immutable existingRolloverContract;

    /// @notice Ghost live threshold expected in the factory defaults.
    /// @return expectedThreshold Stored threshold.
    uint8 public expectedThreshold;
    /// @notice Ghost live registry expected in the factory defaults.
    /// @return expectedRegistry Stored registry.
    address public expectedRegistry;
    /// @notice Ghost live default attester set.
    address[] internal expectedAttesters;
    /// @notice Existing rolloverContract's threshold at handler construction.
    /// @return existingThreshold Stored threshold.
    uint8 public existingThreshold;
    /// @notice Existing rolloverContract's registry at handler construction.
    /// @return existingRegistry Stored registry.
    address public existingRegistry;
    /// @notice Existing rolloverContract's attester set at handler construction.
    address[] internal existingAttesters;

    /// @notice Violation flag: live defaults diverged from the ghost model.
    /// @return liveDefaultsDiverged Stored flag.
    bool public liveDefaultsDiverged;
    /// @notice Violation flag: a newly deployed rolloverContract did not seed from live defaults.
    /// @return deployedRolloverContractSeedMismatch Stored flag.
    bool public deployedRolloverContractSeedMismatch;
    /// @notice Violation flag: an existing rolloverContract changed after defaults update.
    /// @return existingRolloverContractChanged Stored flag.
    bool public existingRolloverContractChanged;
    /// @notice Violation flag: valid setDefaults input rejected.
    /// @return validSetRejected Stored flag.
    bool public validSetRejected;
    /// @notice Violation flag: deployRolloverContract rejected for a fresh user.
    /// @return freshDeployRejected Stored flag.
    bool public freshDeployRejected;

    /// @notice Count of successful defaults updates.
    /// @return ghostSets Stored counter.
    uint64 public ghostSets;
    /// @notice Count of fresh rolloverContract deployment probes.
    /// @return ghostDeploys Stored counter.
    uint64 public ghostDeploys;

    /// @param factory_ Factory under test.
    /// @param owner_ Default admin authorized to set defaults.
    /// @param existingRolloverContract_ RolloverContract that must retain its deployment-time trust config.
    constructor(
        CorkRolloverContractFactory factory_,
        address owner_,
        address existingRolloverContract_
    ) {
        factory = factory_;
        owner = owner_;
        existingRolloverContract = existingRolloverContract_;
        expectedThreshold = factory_.DEFAULT_TRUST_THRESHOLD();
        expectedRegistry = factory_.ERC7484_REGISTRY();
        address[] memory live = factory_.defaultAttesters();
        _copyIntoExpected(live);

        ICorkRolloverContract.RolloverContractTrustSnapshot memory snap =
            ICorkRolloverContract(existingRolloverContract_).rolloverContractSnapshot();
        existingThreshold = snap.liveTrustThreshold;
        existingRegistry = snap.erc7484Registry;
        _copyIntoExisting(snap.liveTrustAttesters);
    }

    /// @notice handler action: set valid defaults and update the ghost model immediately.
    /// @param thresholdSeed Fuzz seed for threshold selection.
    /// @param lengthSeed Fuzz seed for attester-list length.
    function setValidDefaults(uint8 thresholdSeed, uint8 lengthSeed) external {
        uint8 length = uint8(bound(lengthSeed, 1, 3));
        uint8 threshold = uint8(bound(thresholdSeed, 1, length));
        address[] memory attesters = _freshAttesters(length);
        address registry = _freshRegistry();

        vm.prank(owner);
        try factory.setDefaults(threshold, attesters, registry) {
            expectedThreshold = threshold;
            expectedRegistry = registry;
            _copyIntoExpected(attesters);
            ghostSets++;
        } catch {
            validSetRejected = true;
        }

        _checkLiveDefaults();
        _checkExistingRolloverContractUnchanged();
    }

    /// @notice handler action: deploy a fresh rolloverContract and assert it seeds from current defaults.
    function deployFreshRolloverContract() external {
        address user = address(uint160(0xD000 + ghostDeploys + 1));
        ghostDeploys++;

        vm.prank(user);
        try factory.deployRolloverContract() returns (address deployed) {
            _checkRolloverContractSeed(deployed);
        } catch {
            freshDeployRejected = true;
        }

        _checkLiveDefaults();
        _checkExistingRolloverContractUnchanged();
    }

    /// @notice Memory copy of expected live attesters for suite assertions.
    /// @return out Expected attester list.
    function expectedAttestersList() external view returns (address[] memory out) {
        out = _copy(expectedAttesters);
    }

    function _freshAttesters(uint8 length) internal view returns (address[] memory attesters) {
        attesters = new address[](length);
        uint256 baseKey = 0xA100 + uint256(ghostSets) * 16;
        for (uint256 i; i < length; ++i) {
            attesters[i] = vm.addr(baseKey + i + 1);
        }
        // ERC-7484 requires strictly-ascending, unique attesters. vm.addr() outputs are
        // unique but unordered; sort ascending (insertion sort over a <=3 element list).
        for (uint256 i = 1; i < attesters.length; ++i) {
            address key = attesters[i];
            uint256 j = i;
            while (j > 0 && attesters[j - 1] > key) {
                attesters[j] = attesters[j - 1];
                --j;
            }
            attesters[j] = key;
        }
    }

    function _freshRegistry() internal returns (address registry) {
        registry = address(uint160(0xB100 + ghostSets + 1));
        vm.etch(registry, hex"00");
    }

    function _checkRolloverContractSeed(address deployed) internal {
        ICorkRolloverContract.RolloverContractTrustSnapshot memory snap =
            ICorkRolloverContract(deployed).rolloverContractSnapshot();
        if (snap.erc7484Registry != expectedRegistry) {
            deployedRolloverContractSeedMismatch = true;
        }
        if (snap.liveTrustThreshold != expectedThreshold) {
            deployedRolloverContractSeedMismatch = true;
        }
        if (!_sameMemoryStorage(snap.liveTrustAttesters, expectedAttesters)) {
            deployedRolloverContractSeedMismatch = true;
        }
    }

    function _checkLiveDefaults() internal {
        if (factory.DEFAULT_TRUST_THRESHOLD() != expectedThreshold) {
            liveDefaultsDiverged = true;
        }
        if (factory.ERC7484_REGISTRY() != expectedRegistry) {
            liveDefaultsDiverged = true;
        }
        if (!_sameMemoryStorage(factory.defaultAttesters(), expectedAttesters)) {
            liveDefaultsDiverged = true;
        }
    }

    function _checkExistingRolloverContractUnchanged() internal {
        ICorkRolloverContract.RolloverContractTrustSnapshot memory snap =
            ICorkRolloverContract(existingRolloverContract).rolloverContractSnapshot();
        if (snap.erc7484Registry != existingRegistry) {
            existingRolloverContractChanged = true;
        }
        if (snap.liveTrustThreshold != existingThreshold) {
            existingRolloverContractChanged = true;
        }
        if (!_sameMemoryStorage(snap.liveTrustAttesters, existingAttesters)) {
            existingRolloverContractChanged = true;
        }
    }

    function _copyIntoExpected(address[] memory src) internal {
        delete expectedAttesters;
        for (uint256 i; i < src.length; ++i) {
            expectedAttesters.push(src[i]);
        }
    }

    function _copyIntoExisting(address[] memory src) internal {
        delete existingAttesters;
        for (uint256 i; i < src.length; ++i) {
            existingAttesters.push(src[i]);
        }
    }

    function _copy(address[] storage src) internal view returns (address[] memory out) {
        out = new address[](src.length);
        for (uint256 i; i < src.length; ++i) {
            out[i] = src[i];
        }
    }

    function _sameMemoryStorage(address[] memory a, address[] storage b)
        internal
        view
        returns (bool)
    {
        if (a.length != b.length) {
            return false;
        }
        for (uint256 i; i < a.length; ++i) {
            if (a[i] != b[i]) {
                return false;
            }
        }
        return true;
    }
}
