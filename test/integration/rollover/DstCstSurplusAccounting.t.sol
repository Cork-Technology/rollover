// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { DstIntegrityAndDocsTest } from "../../unit/settler/DstIntegrityAndDocs.t.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    Settler__InsufficientRecoverableBalance,
    Settler__ZeroAddress,
    Settler__ZeroAmount
} from "src/errors/SettlerErrors.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";
import { SettlerTypes } from "src/types/SettlerTypes.sol";

/// @notice L-01 / GH-100 — dstCST above live liability is admin-rescuable.
contract DstCstSurplusAccountingTest is DstIntegrityAndDocsTest {
    /// @notice Mirror of `BaseSettler.TokenRecovered`.
    /// @param token Rescued ERC-20 token.
    /// @param to Rescue recipient.
    /// @param amount Amount rescued.
    event TokenRecovered(IERC20 indexed token, address indexed to, uint256 amount);

    /// @notice In-call hostile dstCST delivery is recoverable without inflating fill accounting.
    function test_inCallSurplusRecoverableWithoutInflatingAccounting() public {
        uint256 honestMint = ORDER_SIZE;
        uint256 divertToSettler = 100e18;
        address recipient = makeAddr("dst-rescue-recipient");

        RolloverTypes.OrderData memory orderData = _orderExact(901);
        RolloverTypes.RolloverIntent memory probe =
            _intentHostileDeliver(bytes32(0), honestMint, divertToSettler);

        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _openWithIntent(orderData, probe);

        uint256 settlerDstBefore = dstCst.balanceOf(address(settler));
        uint256 fillerDstBefore = dstCst.balanceOf(filler);

        _fillRollover(orderDigest, orderData, intent, cptHolderSig);

        SettlerTypes.ExactRolloverAccounting memory rec = settler.rolloverAccountingOf(orderDigest);
        assertEq(
            rec.dstCstProduced, honestMint, "rollover accounting uses reported production only"
        );
        assertEq(
            dstCst.balanceOf(filler) - fillerDstBefore, honestMint, "filler gets reported only"
        );
        assertGe(
            dstCst.balanceOf(address(settler)),
            settlerDstBefore + divertToSettler,
            "surplus on settler balance"
        );
        assertEq(settler.dstCstLiabilityOf(address(dstCst)), 0, "atomic fill drains liability");
        assertEq(settler.recoverableTokenBalance(address(dstCst)), divertToSettler);

        vm.expectEmit(true, true, false, true, address(settler));
        emit TokenRecovered(IERC20(address(dstCst)), recipient, divertToSettler);
        settler.recoverToken(IERC20(address(dstCst)), recipient, divertToSettler);

        assertEq(dstCst.balanceOf(recipient), divertToSettler, "recipient recovered");
    }

    /// @notice Pre-existing dstCST before the measured call is ignored by fill accounting but recoverable.
    function test_preExistingDonationRecoverableAndIgnoredByAccounting() public {
        uint256 donation = 7e18;
        address recipient = makeAddr("preexisting-dst-recipient");
        RolloverTypes.OrderData memory orderData = _orderExact(902);
        RolloverTypes.RolloverIntent memory probe = _buildIntent(bytes32(0), ORDER_SIZE, ORDER_SIZE);

        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _openWithIntent(orderData, probe);

        dstCst.mint(address(settler), donation);
        _fillRollover(orderDigest, orderData, intent, cptHolderSig);

        assertEq(dstCst.balanceOf(address(settler)), donation, "pre-fill dust remains unledgered");
        assertEq(settler.recoverableTokenBalance(address(dstCst)), donation);
        settler.recoverToken(IERC20(address(dstCst)), recipient, donation);
        assertEq(dstCst.balanceOf(recipient), donation, "recipient recovered pre-fill dust");
    }

    /// @notice Direct dstCST donations are recoverable when no liability exists.
    function test_directDstCstRescueWhenNoLiabilityExists() public {
        uint256 donation = 13e18;
        address recipient = makeAddr("direct-dst-recipient");

        dstCst.mint(address(settler), donation);
        settler.recoverToken(IERC20(address(dstCst)), recipient, donation);

        assertEq(dstCst.balanceOf(recipient), donation);
        assertEq(settler.recoverableTokenBalance(address(dstCst)), 0);
    }

    /// @notice Non-admin callers cannot recover tokens.
    function testRevert_nonAdminCannotRecoverToken() public {
        dstCst.mint(address(settler), 1);
        vm.prank(anyone);
        vm.expectRevert();
        settler.recoverToken(IERC20(address(dstCst)), anyone, 1);
    }

    /// @notice Rescue cannot exceed balance above liability.
    function testRevert_recoverCannotExceedRecoverable() public {
        dstCst.mint(address(settler), 10);
        vm.expectRevert(Settler__InsufficientRecoverableBalance.selector);
        settler.recoverToken(IERC20(address(dstCst)), anyone, 11);
    }

    /// @notice Zero rescue token, recipient, and amount revert.
    function testRevert_recoverZeroTokenRecipientOrAmount() public {
        vm.expectRevert(Settler__ZeroAddress.selector);
        settler.recoverToken(IERC20(address(0)), anyone, 1);

        vm.expectRevert(Settler__ZeroAddress.selector);
        settler.recoverToken(IERC20(address(dstCst)), address(0), 1);

        vm.expectRevert(Settler__ZeroAmount.selector);
        settler.recoverToken(IERC20(address(dstCst)), anyone, 0);
    }

    /// @notice Partial-mode in-call dstCST surplus is recoverable without inflating filler accounting.
    function test_partialMode_inCallSurplusRecoverableWithoutInflatingFillerAccounting() public {
        uint256 honestMint = 500e18;
        uint256 fillAmount = 500e18;
        uint256 divertToSettler = 25e18;
        address recipient = makeAddr("partial-dst-recipient");

        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.allowPartialFills = true;
        orderData.settler = address(partialSettler);
        orderData.rolloverParams.settler = address(partialSettler);

        RolloverTypes.RolloverIntent memory probe =
            _intentHostileDeliverPartial(bytes32(0), honestMint, divertToSettler);
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _openWithIntent(orderData, probe);

        _doRolloverAs(orderDigest, orderData, intent, fillAmount, filler);

        bytes32 subFiller = bytes32(uint256(uint160(filler)));
        SettlerTypes.FillerRolloverAccounting memory rec =
        partialSettler.fillerSlotAccountingOf(orderDigest, filler, subFiller).rollover;
        assertEq(rec.dstCstProduced, honestMint, "partial slot uses reported production only");
        assertEq(partialSettler.dstCstLiabilityOf(address(dstCst)), 0);
        assertEq(partialSettler.recoverableTokenBalance(address(dstCst)), divertToSettler);
        partialSettler.recoverToken(IERC20(address(dstCst)), recipient, divertToSettler);
        assertEq(dstCst.balanceOf(recipient), divertToSettler);
    }

    function _intentHostileDeliverPartial(
        bytes32 orderDigest,
        uint256 mintToRolloverContract,
        uint256 divertToSettler
    ) internal view returns (RolloverTypes.RolloverIntent memory) {
        RolloverTypes.Call[] memory pre = new RolloverTypes.Call[](1);
        pre[0] = _hook(
            address(sourceSrcCptModule),
            abi.encodeWithSignature(
                "execute(address,uint256)", address(srcCpt), mintToRolloverContract
            )
        );
        RolloverTypes.Call[] memory post = new RolloverTypes.Call[](2);
        post[0] = _hook(
            address(hostileDeliver),
            abi.encodeWithSignature(
                "execute(address,uint256,address,uint256)",
                address(dstCst),
                divertToSettler + 1,
                address(partialSettler),
                divertToSettler
            )
        );
        post[1] = _hook(
            address(consumeDstCptModule),
            abi.encodeWithSignature("execute(address)", address(dstCpt))
        );
        return
            _intentWithHooks(rolloverContract, orderDigest, pre, new RolloverTypes.Call[](0), post);
    }
}
