// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { CorkRolloverContract } from "src/CorkRolloverContract.sol";
import { CorkRolloverContractFactory } from "src/CorkRolloverContractFactory.sol";
import { ModuleType } from "src/interfaces/external/erc7484/IERC7484.sol";
import { ICorkRolloverContract } from "src/interfaces/rollover/ICorkRolloverContract.sol";

/// @notice CorkRolloverContractCptHolderOverrideTest — cPT holder trust-config overrides land via the factory-bound
///         external trust-config `TimelockController`.
contract CorkRolloverContractCptHolderOverrideTest is BaseTest {
    /// @notice Trust-config timelock window configured on the test timelock.
    uint256 internal constant DELAY = 1 hours;

    function _singletonAttesters(address a) internal pure returns (address[] memory out) {
        out = new address[](1);
        out[0] = a;
    }

    /// @notice Pins behaviour: cPT holder queue + permissionless apply replaces the factory-seed defaults.
    function test_CptHolderOverrideViaQueueApplyReplacesDefaults() public {
        address newAttester = address(0xBEEF);
        address[] memory newSet = _singletonAttesters(newAttester);

        vm.prank(cptHolder);
        factory.queueTrustConfig(1, newSet);
        vm.warp(block.timestamp + DELAY + 1);
        factory.applyTrustConfig(rolloverContract);

        ICorkRolloverContract.RolloverContractTrustSnapshot memory snap =
            ICorkRolloverContract(rolloverContract).rolloverContractSnapshot();
        assertEq(snap.liveTrustAttesters.length, 1, "live attester count post-override");
        assertEq(snap.liveTrustAttesters[0], newAttester, "live attester post-override");
        assertEq(
            erc7484.attestersOf(rolloverContract)[0], newAttester, "registry attester post-override"
        );

        assertTrue(snap.liveTrustAttesters[0] != defaultAttester, "seed replaced by override");
    }

    /// @notice Pins behaviour: rolloverContract has no `restoreDefaults` escape hatch.
    function test_CptHolderCannotRestoreDefaultsAfterOverride() public {
        (bool ok,) = rolloverContract.call(abi.encodeWithSignature("restoreDefaults()"));
        assertFalse(ok, "restoreDefaults() must not resolve");
        (bool ok2,) = rolloverContract.call(
            abi.encodeWithSignature("restoreDefaults(uint8,address[])", 1, new address[](0))
        );
        assertFalse(ok2, "restoreDefaults(uint8,address[]) must not resolve either");
    }

    /// @notice Pins behaviour: applying before the timelock delay reverts (TimelockController).
    function test_OverrideRespectsExistingTrustConfigDelay() public {
        address[] memory newSet = _singletonAttesters(address(0xBEEF));
        vm.prank(cptHolder);
        factory.queueTrustConfig(1, newSet);

        vm.warp(block.timestamp + DELAY - 1);
        // Timelock reverts with TimelockUnexpectedOperationState before Ready.
        vm.expectPartialRevert(TimelockController.TimelockUnexpectedOperationState.selector);
        factory.applyTrustConfig(rolloverContract);
    }

    /// @notice Pins behaviour: applied override persists across subsequent rolloverContract snapshots.
    function test_OverrideSurvivesAcrossMultipleHookPhases() public {
        address override_ = address(0x5E7);
        address[] memory newSet = _singletonAttesters(override_);
        vm.prank(cptHolder);
        factory.queueTrustConfig(1, newSet);
        vm.warp(block.timestamp + DELAY + 1);
        factory.applyTrustConfig(rolloverContract);

        for (uint256 i = 0; i < 4; ++i) {
            ICorkRolloverContract.RolloverContractTrustSnapshot memory s =
                ICorkRolloverContract(rolloverContract).rolloverContractSnapshot();
            assertEq(s.liveTrustAttesters[0], override_, "override persists across phases");
        }

        ModuleType m = ModuleType.wrap(0);
        m;
    }
}
