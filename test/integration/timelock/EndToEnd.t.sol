// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {
    CorkRolloverContractFactory__NoQueuedTrustConfig
} from "src/errors/CorkRolloverContractFactoryErrors.sol";

import { BaseTest } from "../../base/BaseTest.sol";
import { CorkRolloverContractFactory } from "src/CorkRolloverContractFactory.sol";
import { ICorkRolloverContract } from "src/interfaces/rollover/ICorkRolloverContract.sol";
import { IRolloverContractLens } from "src/interfaces/rollover/IRolloverContractLens.sol";

/// @notice EndToEndTimelockTest — pins the full queue→pending→apply lifecycle through the
///         external per-rolloverContract trust-config `TimelockController`, plus the helper-only invariant grep.
contract EndToEndTimelockTest is BaseTest {
    /// @notice Trust-config window configured on the test timelock.
    uint256 internal constant DELAY = 1 hours;

    /// @notice Build a 1-element attester list.
    /// @param a Sole attester address.
    /// @return out Memory list `[a]`.
    function _singleton(address a) internal pure returns (address[] memory out) {
        out = new address[](1);
        out[0] = a;
    }

    /// @notice Full lifecycle: cPT holder queues, filler observes pending, warp, permissionless apply.
    function test_fullQueueApplyCycle() public {
        address[] memory att = _singleton(address(0xCAFE));

        // 1. cPT holder queues via factory.
        vm.prank(cptHolder);
        factory.queueTrustConfig(1, att);

        // 2. Filler reads pendingTrustConfig — sees the 1h-deferred config.
        (uint8 t, address[] memory pendingList, uint64 eff) =
            factory.pendingTrustConfig(rolloverContract);
        assertEq(t, 1, "filler sees queued threshold");
        assertEq(pendingList[0], address(0xCAFE), "filler sees queued attester");
        // DELAY is a small test constant, so the uint64 cast cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(eff, uint64(block.timestamp) + uint64(DELAY), "filler sees effectiveAt = T+DELAY");

        // 3. Warp past delay.
        vm.warp(block.timestamp + DELAY);

        // 4. Permissionless apply (any address).
        vm.prank(anyone);
        factory.applyTrustConfig(rolloverContract);

        // 5. Post-state: live config reflects the new set; mirror cleared.
        IRolloverContractLens.RolloverContractConfig memory cfg =
            IRolloverContractLens(address(factory)).rolloverContractConfig(rolloverContract);
        assertEq(cfg.liveTrustThreshold, 1, "live threshold applied");
        assertEq(cfg.liveTrustAttesters[0], address(0xCAFE), "live attester applied");
        (,, uint64 effAfter) = factory.pendingTrustConfig(rolloverContract);
        assertEq(effAfter, 0, "mirror cleared post-apply");
    }

    /// @notice cPT holder cancels a pending op then re-queues with a fresh clock and applies.
    function test_cptHolderCancelsBeforeApply() public {
        address[] memory att = _singleton(address(0xBAD));
        vm.prank(cptHolder);
        factory.queueTrustConfig(1, att);

        vm.prank(cptHolder);
        factory.cancelTrustConfig();

        (uint8 t, address[] memory a, uint64 eff) = factory.pendingTrustConfig(rolloverContract);
        assertEq(t, 0);
        assertEq(a.length, 0);
        assertEq(eff, 0);

        // Re-queue with fresh clock.
        address[] memory good = _singleton(address(0xA1));
        vm.prank(cptHolder);
        factory.queueTrustConfig(1, good);
        vm.warp(block.timestamp + DELAY);
        factory.applyTrustConfig(rolloverContract);

        ICorkRolloverContract.RolloverContractTrustSnapshot memory snap =
            ICorkRolloverContract(rolloverContract).rolloverContractSnapshot();
        assertEq(snap.liveTrustAttesters[0], address(0xA1), "second queue applied cleanly");
    }

    /// @notice Re-queueing while a prior op is pending kills it and starts a fresh delay.
    function test_overwriteRestartsClock() public {
        address[] memory a = _singleton(address(0xA1));
        vm.prank(cptHolder);
        factory.queueTrustConfig(1, a);

        vm.warp(block.timestamp + 30 minutes);
        address[] memory b = _singleton(address(0xB1));
        vm.prank(cptHolder);
        factory.queueTrustConfig(1, b);

        (,, uint64 eff) = factory.pendingTrustConfig(rolloverContract);
        // DELAY is a small test constant, so the uint64 cast cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(eff, uint64(block.timestamp) + uint64(DELAY), "second op effectiveAt = now+DELAY");

        // Old op is dead. The permissionless crank loads the latest pending mirror and applies it.
        vm.warp(block.timestamp + DELAY);
        factory.applyTrustConfig(rolloverContract);
        ICorkRolloverContract.RolloverContractTrustSnapshot memory snap =
            ICorkRolloverContract(rolloverContract).rolloverContractSnapshot();
        assertEq(snap.liveTrustAttesters[0], address(0xB1), "second queue applied after overwrite");

        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContractFactory__NoQueuedTrustConfig.selector, rolloverContract
            )
        );
        factory.applyTrustConfig(rolloverContract);
    }

    /// @notice Meta-grep: trust-config and delay-update helpers MUST be the only timelock
    ///         schedule call sites in the factory source.
    ///         (INV-SCHEDULE-VIA-HELPERS-ONLY)
    function test_invFactoryQueueChecksOwner_grep() public view {
        string memory src = vm.readFile("src/CorkRolloverContractFactory.sol");
        bytes memory factoryScheduleNeedle =
            bytes(".schedule(address(this), 0, data, bytes32(0), salt,");
        bytes memory delayScheduleNeedle =
            bytes(".schedule(trustConfigTimelock, 0, data, bytes32(0), salt,");
        bytes memory scheduleNeedle = bytes("tl.schedule(");

        assertEq(
            _countOccurrences(bytes(src), factoryScheduleNeedle),
            1,
            "INV-SCHEDULE-VIA-HELPERS-ONLY: trust-config schedule appears exactly once"
        );
        assertEq(
            _countOccurrences(bytes(src), delayScheduleNeedle),
            1,
            "INV-SCHEDULE-VIA-HELPERS-ONLY: delay-update schedule appears exactly once"
        );
        assertEq(
            _countOccurrences(bytes(src), scheduleNeedle),
            2,
            "INV-SCHEDULE-VIA-HELPERS-ONLY: only two factory schedule call sites"
        );
    }

    /// @notice Count non-overlapping occurrences of `needle` in `haystack`.
    /// @param haystack Bytes to scan.
    /// @param needle Bytes to find.
    /// @return count Number of non-overlapping matches.
    function _countOccurrences(bytes memory haystack, bytes memory needle)
        private
        pure
        returns (uint256 count)
    {
        if (needle.length == 0 || haystack.length < needle.length) {
            return 0;
        }
        for (uint256 i = 0; i <= haystack.length - needle.length; ++i) {
            bool match_ = true;
            for (uint256 j = 0; j < needle.length; ++j) {
                if (haystack[i + j] != needle[j]) {
                    match_ = false;
                    break;
                }
            }
            if (match_) {
                count++;
            }
        }
    }
}
