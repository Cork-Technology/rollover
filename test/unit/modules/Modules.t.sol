// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Vm } from "forge-std/Vm.sol";
import { LibLastDeliveredPremium } from "src/libraries/LibLastDeliveredPremium.sol";
import {
    ScopedTransferModule,
    ScopedTransferModule__ZeroAmount,
    ScopedTransferModule__ZeroRecipient
} from "src/modules/ScopedTransferModule.sol";

/// @notice ModulesDelegateHarness — delegatecall harness used to exercise module behaviour
///         past the `OnlyDelegatecall` gate. Bubbles up the underlying revert reason
///         unchanged so `vm.expectRevert` can match the module's own error selectors.
contract ModulesDelegateHarness {
    /// @notice Delegatecall `module` with `data`. Reverts with the underlying reason on failure.
    /// @param module Module address to delegatecall.
    /// @param data ABI-encoded calldata to forward.
    // Delegatecall harness accepts arbitrary module targets by construction.
    function exec(address module, bytes calldata data) external {
        (bool ok, bytes memory ret) = module.delegatecall(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    /// @notice Write a delivered-premium transient value and delegatecall a scoped module in
    ///         the same frame so the module reads this host's transient storage.
    /// @param module Module address to delegatecall.
    /// @param token Token whose delivered-premium slot is being written.
    /// @param amount Amount to write into the transient slot.
    /// @param data ABI-encoded calldata to forward.
    function writeDeliveredPremiumAndExec(
        address module,
        address token,
        uint256 amount,
        bytes calldata data
    ) external {
        require(module != address(0), "module");
        LibLastDeliveredPremium.write(token, amount);
        (bool ok, bytes memory ret) = module.delegatecall(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }
}

/// @notice ModulesUnitTest — pins Modules behaviour for the Cork Rollover suite. Direct
///         calls into deployed modules are blocked by `OnlyDelegatecall`; tests below
///         exercise the modules through a delegating host so module-internal validation
///         and behaviour can be observed end-to-end.
contract ModulesUnitTest is BaseTest {
    /// @notice Event topic used to detect scoped transfer token movement in logs.
    bytes32 private constant SCOPED_TRANSFER_TOKEN_MOVED_TOPIC =
        keccak256("ScopedTransferModuleTokenMoved(address,address,address,uint256)");

    /// @notice Delegating harness used to exercise modules past the OnlyDelegatecall guard.
    ModulesDelegateHarness internal harness;
    /// @notice Scoped transfer module under test.
    ScopedTransferModule internal scopedTransferModule;

    /// @inheritdoc BaseTest
    function setUp() public override {
        super.setUp();
        harness = new ModulesDelegateHarness();
        scopedTransferModule = new ScopedTransferModule();
    }

    function _topicOf(address value) private pure returns (bytes32) {
        return bytes32(uint256(uint160(value)));
    }

    function _hasScopedTransferTokenMovedLog(
        Vm.Log[] memory logs,
        address executor,
        address token,
        address recipient,
        uint256 amount
    ) private pure returns (bool) {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter != executor || logs[i].topics.length != 4
                    || logs[i].topics[0] != SCOPED_TRANSFER_TOKEN_MOVED_TOPIC
                    || logs[i].topics[1] != _topicOf(executor)
                    || logs[i].topics[2] != _topicOf(token)
                    || logs[i].topics[3] != _topicOf(recipient)
            ) {
                continue;
            }

            uint256 loggedAmount = abi.decode(logs[i].data, (uint256));
            if (loggedAmount == amount) {
                return true;
            }
        }
        return false;
    }

    /// @notice Pins behaviour: scoped transfer rejects a zero recipient after delegatecall.
    function testRevert_scopedTransfer_zeroRecipient() public {
        srcCst.mint(address(harness), 10e18);
        vm.expectRevert(ScopedTransferModule__ZeroRecipient.selector);
        harness.exec(
            address(scopedTransferModule),
            abi.encodeCall(
                ScopedTransferModule.execute, (IERC20(address(srcCst)), 1e18, address(0))
            )
        );
        assertEq(srcCst.balanceOf(address(harness)), 10e18);
    }

    /// @notice Pins behaviour: explicit zero transfer amounts are rejected.
    function testRevert_scopedTransfer_explicitZeroAmount() public {
        vm.expectRevert(ScopedTransferModule__ZeroAmount.selector);
        harness.exec(
            address(scopedTransferModule),
            abi.encodeCall(ScopedTransferModule.execute, (IERC20(address(srcCst)), 0, filler))
        );
    }

    /// @notice Pins behaviour: scoped transfer moves only the explicit amount.
    function test_scopedTransfer_explicitAmount_transfersOnlyAmount() public {
        srcCst.mint(address(harness), 10e18);
        uint256 beforeRecipient = srcCst.balanceOf(filler);
        vm.recordLogs();
        harness.exec(
            address(scopedTransferModule),
            abi.encodeCall(ScopedTransferModule.execute, (IERC20(address(srcCst)), 4e18, filler))
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(srcCst.balanceOf(filler) - beforeRecipient, 4e18);
        assertEq(srcCst.balanceOf(address(harness)), 6e18);
        assertTrue(
            _hasScopedTransferTokenMovedLog(logs, address(harness), address(srcCst), filler, 4e18),
            "L-05: scoped transfer explicit token movement provenance event missing"
        );
    }

    /// @notice R-01: sentinel mode no-ops when the delivered-premium slot is empty.
    function test_scopedTransfer_sentinelWithNoDeliveredPremiumNoOps() public {
        srcCst.mint(address(harness), 10e18);
        uint256 beforeRecipient = srcCst.balanceOf(filler);
        vm.recordLogs();
        harness.exec(
            address(scopedTransferModule),
            abi.encodeCall(
                ScopedTransferModule.execute, (IERC20(address(srcCst)), type(uint256).max, filler)
            )
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(srcCst.balanceOf(filler), beforeRecipient);
        assertEq(srcCst.balanceOf(address(harness)), 10e18);
        assertEq(logs.length, 0, "sentinel zero should not emit a movement event");
    }

    /// @notice Pins behaviour: sentinel mode reads the delivered-premium slot and transfers it.
    function test_scopedTransfer_sentinelReadsDeliveredPremiumAndTransfers() public {
        srcCst.mint(address(harness), 10e18);
        uint256 beforeRecipient = srcCst.balanceOf(filler);
        bytes memory callData = abi.encodeCall(
            ScopedTransferModule.execute, (IERC20(address(srcCst)), type(uint256).max, filler)
        );
        vm.recordLogs();
        harness.writeDeliveredPremiumAndExec(
            address(scopedTransferModule), address(srcCst), 7e18, callData
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(srcCst.balanceOf(filler) - beforeRecipient, 7e18);
        assertEq(srcCst.balanceOf(address(harness)), 3e18);
        assertTrue(
            _hasScopedTransferTokenMovedLog(logs, address(harness), address(srcCst), filler, 7e18),
            "L-05: scoped transfer delivered-premium provenance event missing"
        );
    }

    /// @notice Pins behaviour: pre Rollover Module Emits Snapshot.
    function test_preRolloverModuleEmitsSnapshot() public {
        srcCst.mint(address(harness), 50e18);
        vm.recordLogs();
        harness.exec(
            address(preModule),
            abi.encodeCall(preModule.execute, (bytes32(uint256(0xC4)), IERC20(address(srcCst))))
        );

        assertGt(vm.getRecordedLogs().length, 0);
    }

    /// @notice Pins behaviour: mid Rollover Module Emits Observation Event.
    function test_midRolloverModuleEmitsObservationEvent() public {
        srcCst.mint(address(harness), 50e18);
        vm.recordLogs();
        harness.exec(
            address(midModule),
            abi.encodeCall(midModule.execute, (bytes32(uint256(0xC4)), IERC20(address(srcCst))))
        );

        assertGt(vm.getRecordedLogs().length, 0);
    }

    /// @notice Pins behaviour: post Rollover Module Emits Snapshot.
    function test_postRolloverModuleEmitsSnapshot() public {
        srcCst.mint(address(harness), 50e18);
        vm.recordLogs();
        harness.exec(
            address(postModule),
            abi.encodeCall(postModule.execute, (bytes32(uint256(0xC4)), IERC20(address(srcCst))))
        );
        assertGt(vm.getRecordedLogs().length, 0);
    }
}
