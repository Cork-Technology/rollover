// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { FillScaffold } from "../../base/FillScaffold.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { CorkRolloverContract__SrcCptShortfall } from "src/errors/CorkRolloverContractErrors.sol";
import { Typehashes } from "src/libraries/Typehashes.sol";
import { OwnerTokenPullModule } from "src/modules/OwnerTokenPullModule.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @title OwnerPullStaticAmountPartialPoC
/// @notice Regression coverage for the corrected owner-pull design: the rollover core does not
///         parse or cap OwnerTokenPullModule calldata; useful delivery is governed by the real
///         sibling srcCPT delta observed by `_unwindLeg`.
contract OwnerPullStaticAmountPartialPoC is FillScaffold {
    /// @notice Total partial-fill order size.
    uint256 internal constant ORDER = 1_000e18;
    /// @notice First partial fill amount.
    uint256 internal constant HALF = 500e18;

    /// @notice Independent second filler retained from the original allowance-grief trace.
    address internal filler2 = address(0xF2);
    /// @notice Owner-pull module under audit.
    OwnerTokenPullModule internal ownerPull;

    /// @notice Deploy and attest the owner-pull hook, then fund a second filler.
    function setUp() public override {
        super.setUp();

        ownerPull = new OwnerTokenPullModule();
        erc7484.setAttestedType(address(ownerPull), Typehashes.MODULE_TYPE_PRE_ROLLOVER_HOOK);

        srcCst.mint(filler2, 1_000_000e18);
        premiumToken.mint(filler2, 1_000_000e18);

        vm.startPrank(filler2);
        srcCst.approve(address(partialSettler), type(uint256).max);
        premiumToken.approve(address(partialSettler), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice No core owner-pull cap exists: over-delivered srcCPT is pulled, the partial fill
    ///         burns the fill amount, and rollover accounting returns the source-side excess.
    function test_partialFillSignedOrderSizedPullSucceedsAndReturnsExcessSrcCpt() public {
        srcCpt.mint(cptHolder, ORDER);
        vm.prank(cptHolder);
        srcCpt.approve(rolloverContract, ORDER);

        RolloverTypes.OrderData memory orderData = _usePartialSettler(_baseOrder());
        orderData.orderSalt = 0xA11CE;
        orderData.orderSize = ORDER;
        orderData.rolloverParams.minCaReceived = 0;
        orderData.rolloverParams.minSharesOut = 0;

        RolloverTypes.RolloverIntent memory probe =
            _intentFor(bytes32(0), IERC20(address(srcCpt)), ORDER);
        orderData.rolloverIntentHash = _zeroDigestHash(probe);
        bytes32 orderDigest = _openOrder(orderData);
        RolloverTypes.RolloverIntent memory intent =
            _intentFor(orderDigest, IERC20(address(srcCpt)), ORDER);

        _doRolloverAs(orderDigest, orderData, intent, HALF, filler);

        assertEq(srcCpt.balanceOf(cptHolder), ORDER - HALF, "excess srcCPT returned");
        assertEq(srcCpt.allowance(cptHolder, rolloverContract), 0, "signed allowance spent");
        assertEq(srcCpt.balanceOf(rolloverContract), 0, "rollover srcCPT contained");
        assertEq(
            partialSettler.rolloverAccountingOf(orderDigest).srcCstConsumed,
            HALF,
            "fill-sized source accounting"
        );
        assertEq(
            partialSettler.fillerSlotAccountingOf(
                    orderDigest, filler, bytes32(uint256(uint160(filler)))
                ).rollover.dstCstProduced,
            HALF,
            "fill-sized dst accounting"
        );
    }

    /// @notice With underfill disabled, a smaller positive srcCPT delivery still reverts through
    ///         the sibling srcCPT shortfall check rather than an owner-pull calldata cap.
    function testRevert_smallerPullUnderfillFalseRevertsAtSrcCptShortfall() public {
        srcCpt.mint(cptHolder, HALF);
        vm.prank(cptHolder);
        srcCpt.approve(rolloverContract, HALF);

        RolloverTypes.OrderData memory orderData = _usePartialSettler(_baseOrder());
        orderData.orderSalt = 0xA11CF;
        orderData.orderSize = ORDER;
        orderData.rolloverParams.minCaReceived = 0;
        orderData.rolloverParams.minSharesOut = 0;

        RolloverTypes.RolloverIntent memory probe =
            _intentFor(bytes32(0), IERC20(address(srcCpt)), HALF);
        orderData.rolloverIntentHash = _zeroDigestHash(probe);
        bytes32 orderDigest = _openOrder(orderData);
        RolloverTypes.RolloverIntent memory intent =
            _intentFor(orderDigest, IERC20(address(srcCpt)), HALF);

        vm.expectRevert(
            abi.encodeWithSelector(CorkRolloverContract__SrcCptShortfall.selector, ORDER, HALF)
        );
        _doRolloverAs(orderDigest, orderData, intent, ORDER, filler);

        assertEq(srcCpt.balanceOf(cptHolder), HALF, "owner cPT unchanged");
        assertEq(srcCpt.balanceOf(rolloverContract), 0, "rollover srcCPT contained");
    }

    /// @notice Build an intent with the owner-pull pre-hook and dstCPT consumption post-hook.
    /// @param orderDigest Digest bound into the intent.
    /// @param token Token encoded into owner-pull calldata.
    /// @param amount Amount encoded into owner-pull calldata.
    /// @return Intent containing the owner-pull pre-hook.
    function _intentFor(bytes32 orderDigest, IERC20 token, uint256 amount)
        internal
        view
        returns (RolloverTypes.RolloverIntent memory)
    {
        RolloverTypes.Call[] memory pre = new RolloverTypes.Call[](1);
        pre[0] = _hook(
            address(ownerPull), abi.encodeCall(OwnerTokenPullModule.execute, (token, amount, false))
        );

        RolloverTypes.Call[] memory post = new RolloverTypes.Call[](1);
        post[0] = _hook(
            address(consumeDstCptModule),
            abi.encodeWithSignature("execute(address)", address(dstCpt))
        );

        return
            _intentWithHooks(rolloverContract, orderDigest, pre, new RolloverTypes.Call[](0), post);
    }
}
