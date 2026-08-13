// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Vm } from "forge-std/Vm.sol";
import { LibLastDeliveredPremium } from "src/libraries/LibLastDeliveredPremium.sol";
import {
    ScopedSplitModule,
    ScopedSplitModule__BpsOutOfRange,
    ScopedSplitModule__EmptyRecipients,
    ScopedSplitModule__LengthMismatch,
    ScopedSplitModule__ZeroAmount
} from "src/modules/ScopedSplitModule.sol";

/// @title ScopedSplitModuleHost
/// @notice Tiny delegatecall harness that bubbles up the underlying revert reason so
///         callers can `vm.expectRevert` against the module's own error selectors. The
///         module's `execute` requires a delegatecall frame (`OnlyDelegatecall`); direct
///         calls to the deployed module address are covered separately by
///         `OnlyDelegatecall.t.sol`.
contract ScopedSplitModuleHost {
    /// @notice Delegatecall `module` with `data`. Reverts with the underlying reason on
    ///         failure so error selectors propagate to the test.
    /// @param module Module address to delegatecall.
    /// @param data ABI-encoded calldata to forward.
    // forge-lint: disable-next-line(missing-zero-check)
    function exec(address module, bytes calldata data) external {
        (bool ok, bytes memory ret) = module.delegatecall(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    /// @notice Write a delivered-premium transient amount, then delegatecall `module`.
    /// @param module Module address to delegatecall.
    /// @param token Token whose delivered-premium slot is written.
    /// @param amount Delivered premium amount to write.
    /// @param data ABI-encoded calldata to forward.
    function execWithDelivered(address module, address token, uint256 amount, bytes calldata data)
        external
    {
        LibLastDeliveredPremium.write(token, amount);
        (bool ok, bytes memory ret) = module.delegatecall(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }
}

/// @title ScopedSplitModuleRevertsTest
/// @notice Pins input-validation reverts inside `ScopedSplitModule.execute`. Targets the
///         four uncovered BRDA arms at L65 (`__LengthMismatch`), L68
///         (`__EmptyRecipients`), L77 (`__BpsOutOfRange(value)`), and L82
///         (`__BpsOutOfRange(0)` sum mismatch), lifting the contract from 33.3% → 100%
///         branch coverage. See `audits/forge-coverage-extend/phase-b2-test-proposals.md`
///         §1.1.
contract ScopedSplitModuleRevertsTest is BaseTest {
    /// @notice Event topic used to detect scoped split token movement in logs.
    bytes32 private constant SCOPED_SPLIT_TOKEN_MOVED_TOPIC =
        keccak256("ScopedSplitModuleTokenMoved(address,address,address,uint256)");

    /// @notice ScopedSplitModule under test (constructed fresh per test).
    ScopedSplitModule internal scopedSplit;
    /// @notice Delegatecall host used to exercise the module past the `OnlyDelegatecall`
    ///         guard.
    ScopedSplitModuleHost internal host;

    /// @notice Pre-fund the harness with the source-CST token so that any pre-revert
    ///         state reads inside `execute` succeed. All four reverts under test fire
    ///         before any token I/O, so the funding is defence-in-depth.
    /// @inheritdoc BaseTest
    function setUp() public override {
        super.setUp();
        scopedSplit = new ScopedSplitModule();
        host = new ScopedSplitModuleHost();
        srcCst.mint(address(host), 100e18);
    }

    function _topicOf(address value) private pure returns (bytes32) {
        return bytes32(uint256(uint160(value)));
    }

    function _hasScopedSplitTokenMovedLog(
        Vm.Log[] memory logs,
        address executor,
        address token,
        address recipient,
        uint256 amount
    ) private pure returns (bool) {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter != executor || logs[i].topics.length != 4
                    || logs[i].topics[0] != SCOPED_SPLIT_TOKEN_MOVED_TOPIC
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

    /// @notice Pins behaviour: `recipients.length != bps.length` reverts
    ///         `__LengthMismatch`. Covers `src/modules/ScopedSplitModule.sol:L65`.
    function testRevert_scopedSplit_lengthMismatch() public {
        address[] memory recips = new address[](2);
        recips[0] = filler;
        recips[1] = anyone;
        uint16[] memory bps = new uint16[](3);
        bps[0] = 3000;
        bps[1] = 3000;
        bps[2] = 4000;

        vm.expectRevert(ScopedSplitModule__LengthMismatch.selector);
        host.exec(
            address(scopedSplit),
            abi.encodeCall(ScopedSplitModule.execute, (IERC20(address(srcCst)), 1e18, recips, bps))
        );
    }

    /// @notice Pins behaviour: empty `recipients` and `bps` revert `__EmptyRecipients`.
    ///         Covers `src/modules/ScopedSplitModule.sol:L68`.
    function testRevert_scopedSplit_emptyRecipients() public {
        address[] memory recips = new address[](0);
        uint16[] memory bps = new uint16[](0);

        vm.expectRevert(ScopedSplitModule__EmptyRecipients.selector);
        host.exec(
            address(scopedSplit),
            abi.encodeCall(ScopedSplitModule.execute, (IERC20(address(srcCst)), 1e18, recips, bps))
        );
    }

    /// @notice Pins behaviour: a `bps` entry of `0` or `> BPS_TOTAL` reverts
    ///         `__BpsOutOfRange(value)`. Runs both arms (zero and overflow) as a
    ///         table-test. Covers `src/modules/ScopedSplitModule.sol:L77`.
    function testRevert_scopedSplit_bpsOutOfRange_zeroAndOverflow() public {
        address[] memory recips = new address[](2);
        recips[0] = filler;
        recips[1] = anyone;

        // Case A: bps[0] == 0
        uint16[] memory bpsZero = new uint16[](2);
        bpsZero[0] = 0;
        bpsZero[1] = 10_000;
        vm.expectRevert(
            abi.encodeWithSelector(ScopedSplitModule__BpsOutOfRange.selector, uint16(0))
        );
        host.exec(
            address(scopedSplit),
            abi.encodeCall(
                ScopedSplitModule.execute, (IERC20(address(srcCst)), 1e18, recips, bpsZero)
            )
        );

        // Case B: bps[1] > BPS_TOTAL
        uint16[] memory bpsOver = new uint16[](2);
        bpsOver[0] = 5000;
        bpsOver[1] = 10_001;
        vm.expectRevert(
            abi.encodeWithSelector(ScopedSplitModule__BpsOutOfRange.selector, uint16(10_001))
        );
        host.exec(
            address(scopedSplit),
            abi.encodeCall(
                ScopedSplitModule.execute, (IERC20(address(srcCst)), 1e18, recips, bpsOver)
            )
        );
    }

    /// @notice Pins behaviour: `bps` sum `!= BPS_TOTAL` reverts `__BpsOutOfRange(0)`.
    ///         Covers `src/modules/ScopedSplitModule.sol:L82`.
    function testRevert_scopedSplit_bpsSumMismatch() public {
        address[] memory recips = new address[](2);
        recips[0] = filler;
        recips[1] = anyone;
        uint16[] memory bps = new uint16[](2);
        bps[0] = 1000;
        bps[1] = 2000; // sum 3000 != 10_000

        vm.expectRevert(
            abi.encodeWithSelector(ScopedSplitModule__BpsOutOfRange.selector, uint16(0))
        );
        host.exec(
            address(scopedSplit),
            abi.encodeCall(ScopedSplitModule.execute, (IERC20(address(srcCst)), 1e18, recips, bps))
        );
    }

    /// @notice Pins behaviour: explicit zero `amount` reverts `__ZeroAmount`.
    function testRevert_scopedSplit_zeroExplicitAmount() public {
        address[] memory recips = new address[](1);
        recips[0] = filler;
        uint16[] memory bps = new uint16[](1);
        bps[0] = 10_000;

        vm.expectRevert(ScopedSplitModule__ZeroAmount.selector);
        host.exec(
            address(scopedSplit),
            abi.encodeCall(ScopedSplitModule.execute, (IERC20(address(srcCst)), 0, recips, bps))
        );
    }

    /// @notice R-01: delivered sentinel with an empty transient slot no-ops after shape validation.
    function test_scopedSplit_deliveredSentinelZeroAmountNoOpsWithValidShape() public {
        address[] memory recips = new address[](1);
        recips[0] = filler;
        uint16[] memory bps = new uint16[](1);
        bps[0] = 10_000;

        uint256 fillerBefore = srcCst.balanceOf(filler);
        vm.recordLogs();
        host.exec(
            address(scopedSplit),
            abi.encodeCall(
                ScopedSplitModule.execute, (IERC20(address(srcCst)), type(uint256).max, recips, bps)
            )
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(srcCst.balanceOf(filler), fillerBefore);
        assertEq(srcCst.balanceOf(address(host)), 100e18);
        assertEq(logs.length, 0, "sentinel zero should not emit movement events");
    }

    /// @notice R-01: sentinel zero remains subject to split shape validation.
    function testRevert_scopedSplit_deliveredSentinelZeroStillValidatesShape() public {
        address[] memory recips = new address[](2);
        recips[0] = filler;
        recips[1] = anyone;
        uint16[] memory bps = new uint16[](1);
        bps[0] = 10_000;

        vm.expectRevert(ScopedSplitModule__LengthMismatch.selector);
        host.exec(
            address(scopedSplit),
            abi.encodeCall(
                ScopedSplitModule.execute, (IERC20(address(srcCst)), type(uint256).max, recips, bps)
            )
        );
    }

    /// @notice Verifies explicit-amount split transfers weighted shares and last-recipient dust.
    function test_scopedSplit_explicitAmountDistributesRoundingDust() public {
        address[] memory recips = new address[](2);
        recips[0] = filler;
        recips[1] = anyone;
        uint16[] memory bps = new uint16[](2);
        bps[0] = 3333;
        bps[1] = 6667;

        uint256 fillerBefore = srcCst.balanceOf(filler);
        uint256 anyoneBefore = srcCst.balanceOf(anyone);

        vm.recordLogs();
        host.exec(
            address(scopedSplit),
            abi.encodeCall(ScopedSplitModule.execute, (IERC20(address(srcCst)), 101, recips, bps))
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(srcCst.balanceOf(filler) - fillerBefore, 33, "first weighted share");
        assertEq(srcCst.balanceOf(anyone) - anyoneBefore, 68, "last recipient receives dust");
        assertTrue(
            _hasScopedSplitTokenMovedLog(logs, address(host), address(srcCst), filler, 33),
            "L-05: scoped split first-recipient provenance event missing"
        );
        assertTrue(
            _hasScopedSplitTokenMovedLog(logs, address(host), address(srcCst), anyone, 68),
            "L-05: scoped split dust-recipient provenance event missing"
        );
    }

    /// @notice Verifies delivered sentinel reads the host transient slot during delegatecall.
    function test_scopedSplit_deliveredSentinelDistributesTransientAmount() public {
        address[] memory recips = new address[](2);
        recips[0] = filler;
        recips[1] = anyone;
        uint16[] memory bps = new uint16[](2);
        bps[0] = 5000;
        bps[1] = 5000;

        uint256 fillerBefore = srcCst.balanceOf(filler);
        uint256 anyoneBefore = srcCst.balanceOf(anyone);

        vm.recordLogs();
        host.execWithDelivered(
            address(scopedSplit),
            address(srcCst),
            77,
            abi.encodeCall(
                ScopedSplitModule.execute, (IERC20(address(srcCst)), type(uint256).max, recips, bps)
            )
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(srcCst.balanceOf(filler) - fillerBefore, 38, "first sentinel share");
        assertEq(srcCst.balanceOf(anyone) - anyoneBefore, 39, "last sentinel share gets dust");
        assertTrue(
            _hasScopedSplitTokenMovedLog(logs, address(host), address(srcCst), filler, 38),
            "L-05: scoped split first delivered-premium provenance event missing"
        );
        assertTrue(
            _hasScopedSplitTokenMovedLog(logs, address(host), address(srcCst), anyone, 39),
            "L-05: scoped split dust delivered-premium provenance event missing"
        );
    }
}
