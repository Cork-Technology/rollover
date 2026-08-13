// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";
import { CorkRolloverContractFactory } from "src/CorkRolloverContractFactory.sol";
import { ICorkRolloverContract } from "src/interfaces/rollover/ICorkRolloverContract.sol";

/// @notice Handler that randomly queues / cancels / applies trust-config ops on a rolloverContract,
///         exercising the factory mirror + timelock invariant.
contract PendingTimelockMirrorHandler is Test {
    /// @notice Factory under test (queue / cancel / apply target).
    CorkRolloverContractFactory internal immutable factoryRef;
    /// @notice RolloverContract whose trust-config the handler mutates.
    address internal immutable rolloverContract;
    /// @notice cPT holder used as the `vm.prank` source for owner-gated calls.
    address internal immutable owner_;

    /// @notice Threshold of the most recently successful queue (ghost mirror).
    uint8 public lastQueuedThreshold;
    /// @notice Attesters of the most recently successful queue (ghost mirror).
    address[] public lastQueuedAttesters;
    /// @notice True iff the last successful queue has not yet been applied or canceled.
    bool public lastQueuedAlive;

    /// @notice Count of successful queue calls.
    uint64 public ghostQueues;
    /// @notice Count of successful cancel calls.
    uint64 public ghostCancels;
    /// @notice Count of successful apply calls.
    uint64 public ghostApplies;
    /// @notice Count of warp calls executed by the handler.
    uint64 public ghostWarps;

    /// @notice Wire the handler to a deployed factory and one of its rolloverContracts.
    /// @param factory_ Factory under test.
    /// @param rolloverContract_ RolloverContract address (must be `isFactoryRolloverContract`).
    /// @param owner__ cPT holder address (CWIA trailer).
    // Invariant handler mirrors arbitrary cPT holder configured by the fixture.
    // forge-lint: disable-next-line(missing-zero-check)
    constructor(CorkRolloverContractFactory factory_, address rolloverContract_, address owner__) {
        factoryRef = factory_;
        rolloverContract = rolloverContract_;
        owner_ = owner__;
    }

    /// @notice Attempt a queue with bounded random `(threshold, attesterLen)`.
    /// @param threshold Raw fuzz threshold (bounded to `[1, atLen]`).
    /// @param attesterSeed Raw fuzz seed for attester-list length (bounded to `[1, 3]`).
    function queue(uint8 threshold, uint8 attesterSeed) external {
        uint8 atLen = uint8(bound(attesterSeed, 1, 3));
        uint8 th = uint8(bound(threshold, 1, atLen));
        address[] memory att = new address[](atLen);
        for (uint256 i = 0; i < atLen; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast)
            att[i] = address(uint160(0xE100 + i + 1));
        }
        vm.prank(owner_);
        try factoryRef.queueTrustConfig(th, att) {
            ghostQueues++;
            lastQueuedThreshold = th;
            delete lastQueuedAttesters;
            for (uint256 i = 0; i < att.length; ++i) {
                lastQueuedAttesters.push(att[i]);
            }
            lastQueuedAlive = true;
        } catch { }
    }

    /// @notice Attempt to cancel any currently-queued op.
    function cancel() external {
        vm.prank(owner_);
        try factoryRef.cancelTrustConfig() {
            ghostCancels++;
            lastQueuedAlive = false;
        } catch { }
    }

    /// @notice Attempt to apply the most recently queued op (replays mirrored args).
    function apply_() external {
        if (!lastQueuedAlive || lastQueuedAttesters.length == 0) {
            return;
        }
        try factoryRef.applyTrustConfig(rolloverContract) {
            ghostApplies++;
            lastQueuedAlive = false;
        } catch { }
    }

    /// @notice Advance EVM time by a bounded delta `[0, 4h]`.
    /// @param delta Raw fuzz delta (bounded to `[0, 4 hours]`).
    function warp(uint64 delta) external {
        uint64 d = uint64(bound(delta, 0, 4 hours));
        vm.warp(block.timestamp + d);
        ghostWarps++;
    }
}
