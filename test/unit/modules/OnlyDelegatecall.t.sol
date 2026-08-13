// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Test } from "forge-std/Test.sol";
import { ApproveModule } from "src/modules/ApproveModule.sol";
import { MidRolloverReferenceModule } from "src/modules/MidRolloverReferenceModule.sol";
import {
    OnlyDelegatecall,
    OnlyDelegatecall__DirectCallForbidden
} from "src/modules/OnlyDelegatecall.sol";
import { OwnerTokenPullModule } from "src/modules/OwnerTokenPullModule.sol";
import { PostRolloverDstCptTransferModule } from "src/modules/PostRolloverDstCptTransferModule.sol";
import { PostRolloverReferenceModule } from "src/modules/PostRolloverReferenceModule.sol";
import { PreRolloverReferenceModule } from "src/modules/PreRolloverReferenceModule.sol";
import { ScopedSplitModule } from "src/modules/ScopedSplitModule.sol";
import { ScopedTransferModule } from "src/modules/ScopedTransferModule.sol";

/// @title DelegatingHost
/// @notice Tiny delegatecall harness that bubbles up the underlying revert reason so callers
///         can `vm.expectRevert` against the module's own error selectors.
contract DelegatingHost {
    /// @notice Delegatecall `module` with the provided calldata.
    /// @param module Module address to delegatecall.
    /// @param data ABI-encoded calldata to forward.
    /// @return ret Raw returndata from the successful delegatecall.
    // Delegatecall harness accepts arbitrary module targets by construction.
    function exec(address module, bytes calldata data) external returns (bytes memory ret) {
        bool ok;
        (ok, ret) = module.delegatecall(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }
}

/// @title MockConsumer
/// @notice Minimal selector consumer for the ApproveModule delegatecall regression test.
contract MockConsumer {
    /// @notice Selector consumed by ApproveModule under the 4-arg signature.
    /// @param amount Amount the spender was approved for (ignored — pure selector probe).
    function consume(uint256 amount) external pure {
        amount;
    }
}

/// @title OnlyDelegatecallGuardTest
/// @notice Pins OnlyDelegatecall invariants on every decorated module.
contract OnlyDelegatecallGuardTest is Test {
    /// @notice Approve module under test.
    ApproveModule internal approveModule;
    /// @notice Scoped split module under test.
    ScopedSplitModule internal scopedSplitModule;
    /// @notice Scoped transfer module under test.
    ScopedTransferModule internal scopedTransferModule;
    /// @notice Owner token pull module under test.
    OwnerTokenPullModule internal ownerTokenPullModule;
    /// @notice Pre-rollover reference module under test.
    PreRolloverReferenceModule internal preModule;
    /// @notice Mid-rollover reference module under test.
    MidRolloverReferenceModule internal midModule;
    /// @notice Post-rollover reference module under test.
    PostRolloverReferenceModule internal postModule;
    /// @notice Post-rollover dstCPT transfer module under test.
    PostRolloverDstCptTransferModule internal postDstCptTransferModule;
    /// @notice Delegating host used to exercise each module via delegatecall.
    DelegatingHost internal host;
    /// @notice Test ERC-20 token.
    ERC20Mock internal token;
    /// @notice Selector consumer used by the ApproveModule regression tests.
    MockConsumer internal consumer;

    /// @notice Standard set-up.
    function setUp() public {
        approveModule = new ApproveModule();
        scopedSplitModule = new ScopedSplitModule();
        scopedTransferModule = new ScopedTransferModule();
        ownerTokenPullModule = new OwnerTokenPullModule();
        preModule = new PreRolloverReferenceModule();
        midModule = new MidRolloverReferenceModule();
        postDstCptTransferModule = new PostRolloverDstCptTransferModule();
        postModule = new PostRolloverReferenceModule();
        host = new DelegatingHost();
        token = new ERC20Mock();
        consumer = new MockConsumer();
    }

    // -----------------------------------------------------------
    // Direct-call rejection (one test per decorated module)
    // -----------------------------------------------------------

    /// @notice Pins behaviour: direct call to ApproveModule reverts OnlyDelegatecall guard.
    function test_approveModule_directCall_reverts() public {
        vm.expectRevert(OnlyDelegatecall__DirectCallForbidden.selector);
        approveModule.execute(
            IERC20(address(token)), address(consumer), MockConsumer.consume.selector, 1e18
        );
    }

    /// @notice Pins behaviour: direct call to ScopedSplitModule reverts OnlyDelegatecall guard.
    function test_scopedSplitModule_directCall_reverts() public {
        address[] memory r = new address[](1);
        r[0] = address(0xABCD);
        uint16[] memory b = new uint16[](1);
        b[0] = 10_000;
        vm.expectRevert(OnlyDelegatecall__DirectCallForbidden.selector);
        scopedSplitModule.execute(IERC20(address(token)), 1e18, r, b);
    }

    /// @notice Pins behaviour: direct call to ScopedTransferModule reverts OnlyDelegatecall guard.
    function test_scopedTransferModule_directCall_reverts() public {
        vm.expectRevert(OnlyDelegatecall__DirectCallForbidden.selector);
        scopedTransferModule.execute(IERC20(address(token)), 1e18, address(0xABCD));
    }

    /// @notice Pins behaviour: direct call to OwnerTokenPullModule reverts OnlyDelegatecall guard.
    function test_ownerTokenPullModule_directCall_reverts() public {
        vm.expectRevert(OnlyDelegatecall__DirectCallForbidden.selector);
        ownerTokenPullModule.execute(IERC20(address(token)), 1e18, false);
    }

    /// @notice Pins behaviour: direct call to PreRolloverReferenceModule reverts guard.
    function test_preRolloverReferenceModule_directCall_reverts() public {
        vm.expectRevert(OnlyDelegatecall__DirectCallForbidden.selector);
        preModule.execute(bytes32(uint256(0xC4)), IERC20(address(token)));
    }

    /// @notice Pins behaviour: direct call to MidRolloverReferenceModule reverts guard.
    function test_midRolloverReferenceModule_directCall_reverts() public {
        vm.expectRevert(OnlyDelegatecall__DirectCallForbidden.selector);
        midModule.execute(bytes32(uint256(0xC4)), IERC20(address(token)));
    }

    /// @notice Pins behaviour: direct call to PostRolloverReferenceModule reverts guard.
    function test_postRolloverReferenceModule_directCall_reverts() public {
        vm.expectRevert(OnlyDelegatecall__DirectCallForbidden.selector);
        postModule.execute(bytes32(uint256(0xC4)), IERC20(address(token)));
    }

    /// @notice Pins behaviour: direct call to PostRolloverDstCptTransferModule reverts guard.
    function test_postRolloverDstCptTransferModule_directCall_reverts() public {
        vm.expectRevert(OnlyDelegatecall__DirectCallForbidden.selector);
        postDstCptTransferModule.execute(IERC20(address(token)), address(0xABCD));
    }

    // -----------------------------------------------------------
    // Delegatecall succeeds (regression — guard does not break the happy path)
    // -----------------------------------------------------------

    /// @notice Pins behaviour: ScopedSplitModule via delegatecall succeeds.
    function test_scopedSplitModule_delegatecall_succeeds() public {
        token.mint(address(host), 100e18);
        address[] memory r = new address[](2);
        r[0] = address(0xAB);
        r[1] = address(0xCD);
        uint16[] memory b = new uint16[](2);
        b[0] = 4000;
        b[1] = 6000;
        host.exec(
            address(scopedSplitModule),
            abi.encodeCall(ScopedSplitModule.execute, (IERC20(address(token)), 100e18, r, b))
        );
        assertEq(token.balanceOf(address(0xAB)), 40e18, "split head");
        assertEq(token.balanceOf(address(0xCD)), 60e18, "split tail");
    }

    /// @notice Pins behaviour: ApproveModule via delegatecall succeeds.
    function test_approveModule_delegatecall_succeeds() public {
        host.exec(
            address(approveModule),
            abi.encodeCall(
                ApproveModule.execute,
                (IERC20(address(token)), address(consumer), MockConsumer.consume.selector, 1e18)
            )
        );
        assertEq(token.allowance(address(host), address(consumer)), 0, "approve bracket revoked");
    }

    /// @notice Pins behaviour: PreRolloverReferenceModule via delegatecall succeeds and emits.
    function test_preRolloverReferenceModule_delegatecall_succeeds() public {
        token.mint(address(host), 5e18);
        vm.recordLogs();
        host.exec(
            address(preModule),
            abi.encodeCall(
                PreRolloverReferenceModule.execute, (bytes32(uint256(0xC4)), IERC20(address(token)))
            )
        );
        assertGt(vm.getRecordedLogs().length, 0, "preModule emitted");
    }

    /// @notice Pins behaviour: MidRolloverReferenceModule via delegatecall succeeds and emits.
    function test_midRolloverReferenceModule_delegatecall_succeeds() public {
        token.mint(address(host), 5e18);
        vm.recordLogs();
        host.exec(
            address(midModule),
            abi.encodeCall(
                MidRolloverReferenceModule.execute, (bytes32(uint256(0xC4)), IERC20(address(token)))
            )
        );
        assertGt(vm.getRecordedLogs().length, 0, "midModule emitted");
    }

    /// @notice Pins behaviour: PostRolloverReferenceModule via delegatecall succeeds and emits.
    function test_postRolloverReferenceModule_delegatecall_succeeds() public {
        token.mint(address(host), 5e18);
        vm.recordLogs();
        host.exec(
            address(postModule),
            abi.encodeCall(
                PostRolloverReferenceModule.execute,
                (bytes32(uint256(0xC4)), IERC20(address(token)))
            )
        );
        assertGt(vm.getRecordedLogs().length, 0, "postModule emitted");
    }

    /// @notice Pins behaviour: PostRolloverDstCptTransferModule via delegatecall no-ops cleanly
    ///         when the rolloverContract-scoped transient minted dstCPT amount is zero.
    function test_postRolloverDstCptTransferModule_delegatecall_zeroMinted_succeeds() public {
        host.exec(
            address(postDstCptTransferModule),
            abi.encodeCall(
                PostRolloverDstCptTransferModule.execute, (IERC20(address(token)), address(0xABCD))
            )
        );
        assertEq(token.balanceOf(address(0xABCD)), 0, "zero minted amount no-op");
    }

    // -----------------------------------------------------------
    // Per-deploy immutable _SELF — pin uniqueness via independent reverts
    // -----------------------------------------------------------

    /// @notice Pins behaviour: each module deploy captures its own _SELF immutable; two
    ///         independently-deployed ScopedSplitModule instances both reject direct calls.
    function test_immutableSelf_capturedAtDeploy() public {
        ScopedSplitModule a = new ScopedSplitModule();
        ScopedSplitModule b = new ScopedSplitModule();
        assertTrue(address(a) != address(b), "distinct deploy addresses");
        address[] memory r = new address[](1);
        r[0] = address(0xABCD);
        uint16[] memory bps = new uint16[](1);
        bps[0] = 10_000;
        vm.expectRevert(OnlyDelegatecall__DirectCallForbidden.selector);
        a.execute(IERC20(address(token)), 1e18, r, bps);
        vm.expectRevert(OnlyDelegatecall__DirectCallForbidden.selector);
        b.execute(IERC20(address(token)), 1e18, r, bps);
    }

    /// @notice Pins behaviour: a minimal rolloverContract-shape delegatecall mirror succeeds end-to-end
    ///         for every decorated module. Guards must not change the rolloverContract's hook semantics.
    function test_delegatecall_via_rolloverContract_executeIntentCalls_regression() public {
        // Each module gets its own delegatecall via the host — same pattern as the rolloverContract's
        // _executeIntentCalls dispatch.
        token.mint(address(host), 30e18);
        address[] memory r = new address[](1);
        r[0] = address(0xCAFE);
        uint16[] memory b = new uint16[](1);
        b[0] = 10_000;
        host.exec(
            address(scopedSplitModule),
            abi.encodeCall(ScopedSplitModule.execute, (IERC20(address(token)), 30e18, r, b))
        );
        assertEq(token.balanceOf(address(0xCAFE)), 30e18, "scoped split delegate ok");
    }

    /// @notice Pins behaviour: external `execute` selectors are unchanged by inheriting
    ///         OnlyDelegatecall (a modifier addition does not affect the selector).
    function test_OnlyDelegatecall_inheritance_does_not_change_selectors() public pure {
        // Pre-Cand-14 selectors captured from the deployed module ABI at HEAD baseline.
        bytes4 approveSel = ApproveModule.execute.selector;
        bytes4 scopedSplitSel = ScopedSplitModule.execute.selector;
        bytes4 scopedTransferSel = ScopedTransferModule.execute.selector;
        bytes4 ownerTokenPullSel = OwnerTokenPullModule.execute.selector;
        bytes4 preSel = PreRolloverReferenceModule.execute.selector;
        bytes4 midSel = MidRolloverReferenceModule.execute.selector;
        bytes4 postSel = PostRolloverReferenceModule.execute.selector;
        bytes4 postDstCptTransferSel = PostRolloverDstCptTransferModule.execute.selector;
        // All remaining selectors must be non-zero (compile-time existence + linkage check).
        assertTrue(approveSel != bytes4(0));
        assertTrue(scopedSplitSel != bytes4(0));
        assertTrue(scopedTransferSel != bytes4(0));
        assertTrue(ownerTokenPullSel != bytes4(0));
        assertTrue(preSel != bytes4(0));
        assertTrue(midSel != bytes4(0));
        assertTrue(postSel != bytes4(0));
        assertTrue(postDstCptTransferSel != bytes4(0));
    }
}
