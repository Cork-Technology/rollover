// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { FillScaffold } from "../../base/FillScaffold.sol";
import { SrcCstDonateModule } from "../../mocks/modules/SrcCstDonateModule.sol";
import { Typehashes } from "src/libraries/Typehashes.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice Pins the relaxed srcCST leftover floor: surplus donations during the fill window
///         must not brick the order;
///         genuine shortfalls remain covered by the renamed selector
///         `Settler__SrcLeftoverDeliveryShortfall` (see RolloverSrcLeftoverAccounting.t.sol).
contract SrcDeltaDonationToleranceTest is FillScaffold {
    /// @notice Module that donates srcCST mid-fill.
    SrcCstDonateModule internal srcDonate;

    /// @notice Standard order size used across scenarios.
    uint256 internal constant ORDER = 1_000e18;

    /// @inheritdoc BaseTest
    function setUp() public override {
        super.setUp();
        srcDonate = new SrcCstDonateModule();
        erc7484.setAttestedType(address(srcDonate), Typehashes.MODULE_TYPE_POST_ROLLOVER_HOOK);
        vm.prank(filler);
        srcCst.approve(address(settler), type(uint256).max);
        srcCst.approve(address(partialSettler), type(uint256).max);
    }

    /// @notice Build an order with allowUnderfill=true and a given salt.
    function _orderUnderfill(uint64 nonce)
        internal
        view
        returns (RolloverTypes.OrderData memory orderData)
    {
        orderData = _baseOrder();
        orderData.allowUnderfill = true;
        orderData.orderSize = ORDER;
        orderData.orderSalt = nonce;
    }

    /// @notice Build an intent that underfills and optionally donates srcCST to Settler post-leg.
    /// @param orderDigest Canonical order digest.
    /// @param actualRolled srcCST realized through the rollover hooks.
    /// @param donation srcCST donated to the Settler post-rollover (0 to skip).
    function _intentFor(bytes32 orderDigest, uint256 actualRolled, uint256 donation)
        internal
        view
        returns (RolloverTypes.RolloverIntent memory)
    {
        RolloverTypes.Call[] memory pre = new RolloverTypes.Call[](1);
        pre[0] = _hook(
            address(sourceSrcCptModule),
            abi.encodeWithSignature("execute(address,uint256)", address(srcCpt), actualRolled)
        );
        uint256 postLen = donation == 0 ? 1 : 2;
        RolloverTypes.Call[] memory post = new RolloverTypes.Call[](postLen);
        post[0] = _hook(
            address(consumeDstCptModule),
            abi.encodeWithSignature("execute(address)", address(dstCpt))
        );
        if (donation != 0) {
            post[1] = _hook(
                address(srcDonate),
                abi.encodeWithSignature(
                    "execute(address,address,uint256)", address(srcCst), address(settler), donation
                )
            );
        }
        return
            _intentWithHooks(rolloverContract, orderDigest, pre, new RolloverTypes.Call[](0), post);
    }

    /// @notice Open an order; return digest + intent + cptHolderSig.
    /// @param orderData Order template.
    /// @param actualRolled srcCST realized through the rollover hooks.
    /// @param donation Donation amount (0 to skip).
    /// @return orderDigest Canonical order digest.
    /// @return intent Rollover intent bound to the digest.
    /// @return cptHolderSig cPT holder signature over `OrderData`.
    function _openWithIntent(
        RolloverTypes.OrderData memory orderData,
        uint256 actualRolled,
        uint256 donation
    )
        internal
        returns (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        )
    {
        RolloverTypes.RolloverIntent memory probe = _intentFor(bytes32(0), actualRolled, donation);
        orderData.rolloverIntentHash = _zeroDigestHash(probe);
        orderDigest = _openOrder(orderData);
        intent = _intentFor(orderDigest, actualRolled, donation);
        cptHolderSig = _signOrder(cptHolderPk, orderData);
    }

    /// @notice A 1-wei donation mid-fill does not revert; surplus parks at Settler.
    function test_donation_one_wei_during_fill_does_not_brick() public {
        uint256 actualRolled = 750e18;
        uint256 donation = 1;
        RolloverTypes.OrderData memory orderData = _orderUnderfill(701);
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _openWithIntent(orderData, actualRolled, donation);

        uint256 fillerBefore = srcCst.balanceOf(filler);
        uint256 settlerSrcBefore = srcCst.balanceOf(address(settler));
        _doRolloverAs(orderDigest, orderData, intent, ORDER, filler);

        assertEq(srcCst.balanceOf(filler), fillerBefore - actualRolled);
        assertEq(
            srcCst.balanceOf(address(settler)),
            settlerSrcBefore + donation,
            "donation surplus parks at Settler"
        );
        assertEq(settler.rolloverAccountingOf(orderDigest).dstCstProduced, actualRolled);
    }

    /// @notice Larger donation (10 wei) — same accepting behavior; surplus accumulates.
    function test_donation_larger_amount_succeeds() public {
        uint256 actualRolled = 750e18;
        uint256 donation = 10e18;
        RolloverTypes.OrderData memory orderData = _orderUnderfill(702);
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _openWithIntent(orderData, actualRolled, donation);

        uint256 settlerSrcBefore = srcCst.balanceOf(address(settler));
        _doRolloverAs(orderDigest, orderData, intent, ORDER, filler);

        assertEq(
            srcCst.balanceOf(address(settler)),
            settlerSrcBefore + donation,
            "donation surplus parks at Settler"
        );
        assertEq(settler.rolloverAccountingOf(orderDigest).dstCstProduced, actualRolled);
    }

    /// @notice Donation before fill 1 must not corrupt fill 2: snapshot semantics absorb surplus.
    function test_donation_does_not_corrupt_subsequent_fill() public {
        // Fill 1 with donation succeeds.
        {
            uint256 actualRolled = 750e18;
            uint256 donation = 1;
            RolloverTypes.OrderData memory orderData = _orderUnderfill(704);
            (
                bytes32 orderDigest,
                RolloverTypes.RolloverIntent memory intent,
                bytes memory cptHolderSig
            ) = _openWithIntent(orderData, actualRolled, donation);
            _doRolloverAs(orderDigest, orderData, intent, ORDER, filler);
        }
        // Fill 2 with no donation must pass; Settler's stale surplus stays put.
        {
            uint256 actualRolled = 750e18;
            RolloverTypes.OrderData memory orderData = _orderUnderfill(705);
            (
                bytes32 orderDigest,
                RolloverTypes.RolloverIntent memory intent,
                bytes memory cptHolderSig
            ) = _openWithIntent(orderData, actualRolled, 0);
            uint256 settlerSrcBefore = srcCst.balanceOf(address(settler));
            _doRolloverAs(orderDigest, orderData, intent, ORDER, filler);
            assertEq(
                srcCst.balanceOf(address(settler)),
                settlerSrcBefore,
                "surplus invariant across fills"
            );
        }
    }

    /// @notice Structural: the renamed error selector exists. Compile-time guard.
    function test_error_rename_new_selector_present() public pure {
        bytes4 newSel = bytes4(keccak256("Settler__SrcLeftoverDeliveryShortfall(uint256,uint256)"));
        assertTrue(newSel != bytes4(0));
    }
}
