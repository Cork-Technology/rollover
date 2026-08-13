// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { Vm } from "forge-std/Vm.sol";

import { BaseTest } from "../base/BaseTest.sol";

/// @notice Pins the deletion of the entire `rolloverPeriod` governance surface from
///         `CorkRolloverContractFactory`. The brief proved zero production
///         readers; only the writer + lens view were live. After the src/ commit these
///         selectors, the matching event topics, and the `protocolConfig()` lens entry
///         must all be unreachable from the public ABI.
///
///         Surface in scope:
///         - `setRolloverPeriod(uint64)`
///         - `effectRolloverPeriod()`
///         - `RolloverPeriodScheduled(uint64,uint256)` event
///         - `RolloverPeriodEffected(uint64)` event
///         - `IRolloverContractLens.protocolConfig()` view + `ProtocolConfig` struct
contract RolloverPeriodSurfaceRemovedTest is BaseTest {
    /// @notice The `setRolloverPeriod(uint64)` selector must not be callable on the
    ///         deployed factory. After deletion the dispatcher has no match — the
    ///         fallback reverts and the raw `call` returns `false`.
    function test_setRolloverPeriod_SelectorRemoved() public {
        bytes4 sel = bytes4(keccak256("setRolloverPeriod(uint64)"));
        (bool ok,) = address(factory).call(abi.encodeWithSelector(sel, uint64(1 hours)));
        assertFalse(ok, "setRolloverPeriod must be removed from the public ABI");
    }

    /// @notice The `effectRolloverPeriod()` selector must not be callable on the
    ///         deployed factory.
    function test_effectRolloverPeriod_SelectorRemoved() public {
        bytes4 sel = bytes4(keccak256("effectRolloverPeriod()"));
        (bool ok,) = address(factory).call(abi.encodeWithSelector(sel));
        assertFalse(ok, "effectRolloverPeriod must be removed from the public ABI");
    }

    /// @notice The `protocolConfig()` lens view must not be callable on the deployed
    ///         factory. With every field of `ProtocolConfig` being a rolloverPeriod
    ///         entry, the entire view is dropped per the brief.
    function test_protocolConfig_LensSelectorRemoved() public {
        bytes4 sel = bytes4(keccak256("protocolConfig()"));
        (bool ok,) = address(factory).call(abi.encodeWithSelector(sel));
        assertFalse(ok, "protocolConfig lens view must be removed");
    }

    /// @notice Pin: the rolloverPeriod-related event topics are unused. The factory
    ///         must not emit them anywhere. Because Foundry has no clean "no-emit"
    ///         primitive over the lifetime of a contract, we record-and-assert that
    ///         no log topic matches either rolloverPeriod event signature for any
    ///         transaction that touches the factory in this test.
    function test_RolloverPeriodScheduled_EventTopicRemoved() public {
        bytes32 scheduledTopic = keccak256("RolloverPeriodScheduled(uint64,uint256)");
        bytes32 effectedTopic = keccak256("RolloverPeriodEffected(uint64)");
        vm.recordLogs();
        // Exercise a normal factory mutation to ensure logs ARE being captured.
        // Revoke + re-approve the existing Settler — both emit SettlerRevoked /
        // SettlerApproved events (so the captured-logs array is non-empty).
        factory.revokeSettler(address(settler));
        factory.approveSettler(address(settler));
        Vm.Log[] memory entries = vm.getRecordedLogs();
        for (uint256 i = 0; i < entries.length; ++i) {
            for (uint256 t = 0; t < entries[i].topics.length; ++t) {
                assertTrue(
                    entries[i].topics[t] != scheduledTopic,
                    "RolloverPeriodScheduled topic must be unreachable"
                );
                assertTrue(
                    entries[i].topics[t] != effectedTopic,
                    "RolloverPeriodEffected topic must be unreachable"
                );
            }
        }
    }
}
