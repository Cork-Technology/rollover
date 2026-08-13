// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { MockERC7484 } from "../../mocks/MockERC7484.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { Test } from "forge-std/Test.sol";
import { CorkRolloverContract } from "src/CorkRolloverContract.sol";
import { CorkRolloverContractFactory } from "src/CorkRolloverContractFactory.sol";
import { ICorkRolloverContract } from "src/interfaces/rollover/ICorkRolloverContract.sol";
import { IRolloverContractLens } from "src/interfaces/rollover/IRolloverContractLens.sol";

/// @notice FactoryImmutablesPropagateToRolloverContractTest — pins FactoryImmutablesPropagateToRolloverContract behaviour for the Cork Rollover suite.
contract FactoryImmutablesPropagateToRolloverContractTest is Test {
    /// @notice ERC-7201 namespaced storage slot for `RolloverContractStorage` (matches CorkRolloverContract.ROLLOVER_CONTRACT_STORAGE_SLOT).
    bytes32 private constant ROLLOVER_CONTRACT_STORAGE_SLOT =
        0xb4cefcf1cd721ac7aa7779687f98e0bf77365d8cc544d423bc3152971ed5cc00;

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

    /// @notice Pins behaviour: initialize Sets Registry.
    function test_initializeSetsRegistry() public {
        CorkRolloverContract impl = new CorkRolloverContract();
        MockERC7484 erc7484 = new MockERC7484();
        address[] memory defaults = new address[](1);
        defaults[0] = address(0xDEFA);
        TimelockController tl = _deployTrustConfigTimelockForNextFactory();
        CorkRolloverContractFactory factory = new CorkRolloverContractFactory(
            address(impl),
            address(erc7484),
            1,
            defaults,
            address(tl),
            address(this),
            address(this),
            address(this),
            address(this),
            address(this)
        );

        address cptHolder = makeAddr("cptHolder");
        vm.prank(cptHolder);
        address rolloverContract = factory.deployRolloverContract();

        IRolloverContractLens.RolloverContractConfig memory cfg =
            IRolloverContractLens(address(factory)).rolloverContractConfig(rolloverContract);
        assertEq(cfg.owner, cptHolder, "owner");
        assertEq(cfg.factory, address(factory), "factory");
        assertEq(cfg.erc7484Registry, address(erc7484), "erc7484");
        assertEq(cfg.liveTrustThreshold, 1, "live threshold seeded");
        assertEq(cfg.liveTrustAttesters.length, 1, "live attester count seeded");
        assertEq(cfg.liveTrustAttesters[0], address(0xDEFA), "live attester seeded");
    }

    /// @notice Pins behaviour: registry is CWIA-immutable in trailer, surfaced via rolloverContractSnapshot,
    ///         and the namespaced `RolloverContractStorage` layout has exactly 5 fields. The
    ///         three pendingTrust* fields moved to the factory's `TimelockController`; a
    ///         reintroduced field would either shift +3/+4 or extend to +5.
    /// @dev Canonical live-only layout (mirrors `CorkRolloverContract.RolloverContractStorage`):
    ///        +0  hookNonces                  (mapping → zero at init)
    ///        +1  rolled                      (mapping → zero at init)
    ///        +2  premiumFiredFor             (mapping → zero at init)
    ///        +3  liveTrustThreshold (u8)     (seeded = 1)
    ///        +4  liveTrustAttesters          (array length; seeded = 1)
    function test_initializeBakesRegistryIntoTrailer() public {
        CorkRolloverContract impl = new CorkRolloverContract();
        MockERC7484 erc7484 = new MockERC7484();
        address[] memory defaults = new address[](1);
        defaults[0] = address(0xDEFA);
        TimelockController tl = _deployTrustConfigTimelockForNextFactory();
        CorkRolloverContractFactory factory = new CorkRolloverContractFactory(
            address(impl),
            address(erc7484),
            1,
            defaults,
            address(tl),
            address(this),
            address(this),
            address(this),
            address(this),
            address(this)
        );

        address cptHolder = makeAddr("cptHolder-bake");
        vm.prank(cptHolder);
        address rolloverContract = factory.deployRolloverContract();

        // rolloverContractSnapshot sources registry via trailer-decode (`_registry()`), not storage.
        ICorkRolloverContract.RolloverContractTrustSnapshot memory snap =
            ICorkRolloverContract(rolloverContract).rolloverContractSnapshot();
        assertEq(snap.erc7484Registry, address(erc7484), "registry surfaced via trailer");

        // Layout fingerprint: read slots +0..+4 covering every namespaced field.
        bytes32[5] memory slots;
        for (uint256 i = 0; i < 5; ++i) {
            slots[i] =
                vm.load(rolloverContract, bytes32(uint256(ROLLOVER_CONTRACT_STORAGE_SLOT) + i));
        }

        // Slots +0..+2: mappings — always zero (storage held in keccak buckets, not the base slot).
        assertEq(slots[0], bytes32(0), "slot +0 hookNonces mapping base zero");
        assertEq(slots[1], bytes32(0), "slot +1 rolled mapping base zero");
        assertEq(slots[2], bytes32(0), "slot +2 premiumFiredFor mapping base zero");

        // Slot +3: liveTrustThreshold (seeded = 1).
        assertEq(uint256(slots[3]), 1, "slot +3 liveTrustThreshold seeded to 1");

        // Slot +4: liveTrustAttesters array length (seeded = 1 default attester).
        assertEq(uint256(slots[4]), 1, "slot +4 liveTrustAttesters length seeded to 1");

        // Layout-bound check: no 6th namespaced slot should be non-zero.
        bytes32 slot5 =
            vm.load(rolloverContract, bytes32(uint256(ROLLOVER_CONTRACT_STORAGE_SLOT) + 5));
        assertEq(slot5, bytes32(0), "no 6th namespaced slot - layout has exactly 5 fields");
    }
}
