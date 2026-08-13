// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { FillScaffold } from "../../base/FillScaffold.sol";
import { MockCpt } from "../../mocks/MockPhoenix.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    CorkRolloverContract__ModuleTypeMismatch,
    CorkRolloverContract__RolloverZeroUnwindMint,
    CorkRolloverContract__SrcCptShortfall
} from "src/errors/CorkRolloverContractErrors.sol";
import { Typehashes } from "src/libraries/Typehashes.sol";
import { OwnerTokenPullModule } from "src/modules/OwnerTokenPullModule.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @title OwnerTokenPullPreHookTest
/// @notice Integration coverage for owner-held srcCPT delivery through the production
///         pre-rollover hook and real Settler rollover path.
contract OwnerTokenPullPreHookTest is FillScaffold {
    /// @notice Standard order size used by exact-fill owner-pull scenarios.
    uint256 internal constant ORDER = 1_000e18;

    /// @notice Production pre-rollover hook under test.
    OwnerTokenPullModule internal ownerPull;
    /// @notice Non-sibling CPT used to prove wrong-token pulls do not satisfy srcCPT delivery.
    MockCpt internal wrongCpt;

    /// @notice Deploy and attest the owner-pull hook fixture.
    function setUp() public override {
        super.setUp();
        ownerPull = new OwnerTokenPullModule();
        wrongCpt = new MockCpt("wrongCPT", "WCPT");
        erc7484.setAttestedType(address(ownerPull), Typehashes.MODULE_TYPE_PRE_ROLLOVER_HOOK);
    }

    /// @notice Builds a base order configured for this owner-pull integration test.
    /// @param salt Unique order salt.
    /// @param allowUnderfill Whether the order permits partial delivery.
    /// @return orderData Configured order data.
    function _order(uint64 salt, bool allowUnderfill)
        internal
        view
        returns (RolloverTypes.OrderData memory orderData)
    {
        orderData = _baseOrder();
        orderData.orderSalt = salt;
        orderData.orderSize = ORDER;
        orderData.allowUnderfill = allowUnderfill;
        orderData.rolloverParams.minCaReceived = 0;
        orderData.rolloverParams.minSharesOut = 0;
    }

    /// @notice Builds the rollover intent with owner-pull pre-hook and dstCPT consumption post-hook.
    /// @param orderDigest Digest bound into the intent.
    /// @param token Token encoded into the owner-pull hook calldata.
    /// @param amount Amount encoded into the owner-pull hook calldata.
    /// @param moduleAllowUnderfill Whether the module treats `amount` as a maximum.
    /// @return Intent containing pre and post hooks.
    function _intentFor(
        bytes32 orderDigest,
        IERC20 token,
        uint256 amount,
        bool moduleAllowUnderfill
    ) internal view returns (RolloverTypes.RolloverIntent memory) {
        RolloverTypes.Call[] memory pre = new RolloverTypes.Call[](1);
        pre[0] = _hook(
            address(ownerPull),
            abi.encodeCall(OwnerTokenPullModule.execute, (token, amount, moduleAllowUnderfill))
        );
        RolloverTypes.Call[] memory post = new RolloverTypes.Call[](1);
        post[0] = _hook(
            address(consumeDstCptModule),
            abi.encodeWithSignature("execute(address)", address(dstCpt))
        );
        return
            _intentWithHooks(rolloverContract, orderDigest, pre, new RolloverTypes.Call[](0), post);
    }

    /// @notice Opens an order whose signed pre-hook pulls `amount` of `token` from the owner.
    /// @param salt Unique order salt.
    /// @param allowUnderfill Whether the order permits partial delivery.
    /// @param token Token encoded into owner-pull hook calldata.
    /// @param amount Amount encoded into owner-pull hook calldata.
    /// @param moduleAllowUnderfill Whether the module treats `amount` as a maximum.
    /// @return orderDigest EIP-712 order digest.
    /// @return orderData Opened order data.
    /// @return intent Signed rollover intent matching the opened order.
    function _openOwnerPullOrder(
        uint64 salt,
        bool allowUnderfill,
        IERC20 token,
        uint256 amount,
        bool moduleAllowUnderfill
    )
        internal
        returns (
            bytes32 orderDigest,
            RolloverTypes.OrderData memory orderData,
            RolloverTypes.RolloverIntent memory intent
        )
    {
        orderData = _order(salt, allowUnderfill);
        RolloverTypes.RolloverIntent memory probe =
            _intentFor(bytes32(0), token, amount, moduleAllowUnderfill);
        orderData.rolloverIntentHash = _zeroDigestHash(probe);
        orderDigest = _openOrder(orderData);
        intent = _intentFor(orderDigest, token, amount, moduleAllowUnderfill);
    }

    /// @notice Mints owner-held srcCPT and approves the rollover contract for a chosen allowance.
    /// @param ownerBalance srcCPT balance minted to the cPT holder.
    /// @param allowance srcCPT allowance granted to the rollover contract.
    function _fundAndApproveOwner(uint256 ownerBalance, uint256 allowance) internal {
        srcCpt.mint(cptHolder, ownerBalance);
        vm.prank(cptHolder);
        srcCpt.approve(rolloverContract, allowance);
    }

    /// @notice Exact fill succeeds through Settler using owner-held srcCPT delivered by the pre-hook.
    function test_exactFill_ownerPullPreHook_burnsOwnerFundedSrcCpt() public {
        _fundAndApproveOwner(ORDER, ORDER);
        (
            bytes32 orderDigest,
            RolloverTypes.OrderData memory orderData,
            RolloverTypes.RolloverIntent memory intent
        ) = _openOwnerPullOrder(1_101, false, IERC20(address(srcCpt)), ORDER, false);

        uint256 ownerBefore = srcCpt.balanceOf(cptHolder);
        uint256 rolloverSrcCptBefore = srcCpt.balanceOf(rolloverContract);

        _doRolloverAs(orderDigest, orderData, intent, ORDER, filler);

        assertEq(srcCpt.balanceOf(cptHolder), ownerBefore - ORDER, "owner srcCPT burned");
        assertEq(srcCpt.balanceOf(rolloverContract), rolloverSrcCptBefore, "srcCPT contained");
        assertEq(srcCst.balanceOf(rolloverContract), 0, "srcCST returned to entry snapshot");
        assertEq(settler.rolloverAccountingOf(orderDigest).dstCstProduced, ORDER, "dst produced");
    }

    /// @notice Exact module mode reverts when less than the signed amount is pullable.
    function test_underfillFalse_signedMaxOnlyPartlyAvailableRevertsAtExactPull() public {
        uint256 available = 700e18;
        _fundAndApproveOwner(available, available);
        (
            bytes32 orderDigest,
            RolloverTypes.OrderData memory orderData,
            RolloverTypes.RolloverIntent memory intent
        ) = _openOwnerPullOrder(1_102, false, IERC20(address(srcCpt)), ORDER, false);

        uint256 ownerBefore = srcCpt.balanceOf(cptHolder);
        uint256 rolloverSrcCptBefore = srcCpt.balanceOf(rolloverContract);
        uint256 rolloverSrcCstBefore = srcCst.balanceOf(rolloverContract);

        vm.expectRevert();
        _doRolloverAs(orderDigest, orderData, intent, ORDER, filler);

        assertEq(srcCpt.balanceOf(cptHolder), ownerBefore, "owner unchanged");
        assertEq(srcCpt.balanceOf(rolloverContract), rolloverSrcCptBefore, "no srcCPT residue");
        assertEq(srcCst.balanceOf(rolloverContract), rolloverSrcCstBefore, "no srcCST residue");
    }

    /// @notice Pulling the wrong token does not satisfy `_unwindLeg` srcCPT delivery accounting.
    function test_wrongTokenSignedDoesNotSatisfySrcCptDelivery() public {
        wrongCpt.mint(cptHolder, ORDER);
        vm.prank(cptHolder);
        wrongCpt.approve(rolloverContract, ORDER);
        (
            bytes32 orderDigest,
            RolloverTypes.OrderData memory orderData,
            RolloverTypes.RolloverIntent memory intent
        ) = _openOwnerPullOrder(1_103, false, IERC20(address(wrongCpt)), ORDER, false);

        vm.expectRevert(
            abi.encodeWithSelector(CorkRolloverContract__SrcCptShortfall.selector, ORDER, 0)
        );
        _doRolloverAs(orderDigest, orderData, intent, ORDER, filler);

        assertEq(srcCpt.balanceOf(rolloverContract), 0, "no useful srcCPT delivered");
        assertEq(wrongCpt.balanceOf(rolloverContract), 0, "wrong-token pull reverted");
    }

    /// @notice Underfill-disabled rollover semantics still reject smaller signed positive delivery.
    function test_underfillFalse_smallerSignedPullRevertsAtSrcCptShortfall() public {
        uint256 delivered = 700e18;
        _fundAndApproveOwner(delivered, delivered);
        (
            bytes32 orderDigest,
            RolloverTypes.OrderData memory orderData,
            RolloverTypes.RolloverIntent memory intent
        ) = _openOwnerPullOrder(1_104, false, IERC20(address(srcCpt)), delivered, false);

        vm.expectRevert(
            abi.encodeWithSelector(CorkRolloverContract__SrcCptShortfall.selector, ORDER, delivered)
        );
        _doRolloverAs(orderDigest, orderData, intent, ORDER, filler);

        assertEq(srcCpt.balanceOf(cptHolder), delivered, "owner pull reverted");
        assertEq(srcCpt.balanceOf(rolloverContract), 0, "no srcCPT residue");
    }

    /// @notice Underfill-enabled module mode pulls what is available and rollover accounts actual burn.
    function test_underfillTrue_signedMaxOnlyPartlyAvailableRollsActualPulledAmount() public {
        uint256 delivered = 700e18;
        _fundAndApproveOwner(delivered, delivered);
        (
            bytes32 orderDigest,
            RolloverTypes.OrderData memory orderData,
            RolloverTypes.RolloverIntent memory intent
        ) = _openOwnerPullOrder(1_105, true, IERC20(address(srcCpt)), ORDER, true);

        uint256 ownerBefore = srcCpt.balanceOf(cptHolder);
        uint256 fillerSrcBefore = srcCst.balanceOf(filler);
        uint256 rolloverSrcCptBefore = srcCpt.balanceOf(rolloverContract);
        uint256 rolloverDstCptBefore = dstCpt.balanceOf(rolloverContract);

        _doRolloverAs(orderDigest, orderData, intent, ORDER, filler);

        assertEq(srcCpt.balanceOf(cptHolder), ownerBefore - delivered, "owner srcCPT consumed");
        assertEq(srcCst.balanceOf(filler), fillerSrcBefore - delivered, "src leftover returned");
        assertEq(srcCpt.balanceOf(rolloverContract), rolloverSrcCptBefore, "srcCPT contained");
        assertEq(dstCpt.balanceOf(rolloverContract), rolloverDstCptBefore, "dstCPT contained");
        assertEq(
            settler.rolloverAccountingOf(orderDigest).dstCstProduced, delivered, "actual rolled"
        );
    }

    /// @notice A partial wrong-token underfill pull still does not satisfy sibling srcCPT delivery.
    function test_wrongTokenPartialPullDoesNotSatisfySrcCptDelivery() public {
        uint256 pullable = 700e18;
        wrongCpt.mint(cptHolder, pullable);
        vm.prank(cptHolder);
        wrongCpt.approve(rolloverContract, pullable);
        (
            bytes32 orderDigest,
            RolloverTypes.OrderData memory orderData,
            RolloverTypes.RolloverIntent memory intent
        ) = _openOwnerPullOrder(1_108, true, IERC20(address(wrongCpt)), ORDER, true);

        vm.expectRevert(CorkRolloverContract__RolloverZeroUnwindMint.selector);
        _doRolloverAs(orderDigest, orderData, intent, ORDER, filler);

        assertEq(srcCpt.balanceOf(rolloverContract), 0, "no useful srcCPT delivered");
        assertEq(wrongCpt.balanceOf(rolloverContract), 0, "wrong-token pull reverted");
    }

    /// @notice A module attested to the wrong bucket is rejected during prevalidation.
    function test_wrongModuleTypeRevertsDuringPrevalidation() public {
        erc7484.setAttestedType(address(ownerPull), Typehashes.MODULE_TYPE_EXECUTOR);
        _fundAndApproveOwner(ORDER, ORDER);
        (
            bytes32 orderDigest,
            RolloverTypes.OrderData memory orderData,
            RolloverTypes.RolloverIntent memory intent
        ) = _openOwnerPullOrder(1_106, false, IERC20(address(srcCpt)), ORDER, false);

        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContract__ModuleTypeMismatch.selector,
                address(ownerPull),
                Typehashes.MODULE_TYPE_PRE_ROLLOVER_HOOK
            )
        );
        _doRolloverAs(orderDigest, orderData, intent, ORDER, filler);
    }

    /// @notice A non-owner approval cannot replace the rollover contract owner as transfer source.
    function test_nonOwnerApprovalIsIrrelevantSourceRemainsRolloverOwner() public {
        address nonOwner = makeAddr("nonOwner");
        srcCpt.mint(cptHolder, ORDER);
        srcCpt.mint(nonOwner, ORDER);
        vm.prank(nonOwner);
        srcCpt.approve(rolloverContract, ORDER);
        (
            bytes32 orderDigest,
            RolloverTypes.OrderData memory orderData,
            RolloverTypes.RolloverIntent memory intent
        ) = _openOwnerPullOrder(1_107, false, IERC20(address(srcCpt)), ORDER, false);

        vm.expectRevert();
        _doRolloverAs(orderDigest, orderData, intent, ORDER, filler);
        assertEq(srcCpt.balanceOf(nonOwner), ORDER, "non-owner approval unused");

        vm.prank(cptHolder);
        srcCpt.approve(rolloverContract, ORDER);
        _doRolloverAs(orderDigest, orderData, intent, ORDER, filler);

        assertEq(srcCpt.balanceOf(cptHolder), 0, "owner is source");
        assertEq(srcCpt.balanceOf(nonOwner), ORDER, "non-owner still untouched");
    }
}
