// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { SrcDeltaDonationToleranceTest } from "./SrcDeltaDonationTolerance.t.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    Settler__InsufficientRecoverableBalance,
    Settler__ZeroAddress,
    Settler__ZeroAmount
} from "src/errors/SettlerErrors.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice A-02 / GH-100 — srcCST donations are ignored by fill accounting and admin-rescuable.
contract SrcCstSurplusAccountingTest is SrcDeltaDonationToleranceTest {
    /// @notice Mirror of `BaseSettler.TokenRecovered`.
    /// @param token Rescued ERC-20 token.
    /// @param to Rescue recipient.
    /// @param amount Amount rescued.
    event TokenRecovered(IERC20 indexed token, address indexed to, uint256 amount);

    /// @notice Surplus srcCST stays on the settler and is generic recoverable balance.
    function test_srcDonationIgnoredByFillAccountingAndRecoverable() public {
        uint256 actualRolled = 750e18;
        uint256 donation = 10e18;
        address recipient = makeAddr("src-rescue-recipient");
        RolloverTypes.OrderData memory orderData = _orderUnderfill(901);
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _openWithIntent(orderData, actualRolled, donation);

        uint256 before = srcCst.balanceOf(address(settler));
        _doRolloverAs(orderDigest, orderData, intent, ORDER, filler);
        assertGe(srcCst.balanceOf(address(settler)), before + donation, "parked on settler");
        assertEq(settler.rolloverAccountingOf(orderDigest).dstCstProduced, actualRolled);
        assertEq(settler.recoverableTokenBalance(address(srcCst)), donation);

        vm.expectEmit(true, true, false, true, address(settler));
        emit TokenRecovered(IERC20(address(srcCst)), recipient, donation);
        settler.recoverToken(IERC20(address(srcCst)), recipient, donation);

        assertEq(srcCst.balanceOf(recipient), donation, "recipient recovered donation");
        assertEq(settler.recoverableTokenBalance(address(srcCst)), 0, "recoverable cleared");
    }

    /// @notice Direct srcCST donations are recoverable because srcCST has no tracked liability.
    function test_directSrcCstRescue() public {
        uint256 donation = 42e18;
        address recipient = makeAddr("direct-src-recipient");

        srcCst.mint(address(settler), donation);
        settler.recoverToken(IERC20(address(srcCst)), recipient, donation);

        assertEq(srcCst.balanceOf(recipient), donation, "recipient recovered");
    }

    /// @notice Non-admin callers cannot rescue generic token balances.
    function testRevert_nonAdminCannotRecoverToken() public {
        srcCst.mint(address(settler), 1);
        vm.prank(anyone);
        vm.expectRevert();
        settler.recoverToken(IERC20(address(srcCst)), anyone, 1);
    }

    /// @notice Rescue cannot exceed balance above liability.
    function testRevert_recoverCannotExceedRecoverable() public {
        srcCst.mint(address(settler), 10);
        vm.expectRevert(Settler__InsufficientRecoverableBalance.selector);
        settler.recoverToken(IERC20(address(srcCst)), anyone, 11);
    }

    /// @notice Zero rescue token, recipient, and amount revert.
    function testRevert_recoverZeroTokenRecipientOrAmount() public {
        vm.expectRevert(Settler__ZeroAddress.selector);
        settler.recoverToken(IERC20(address(0)), anyone, 1);

        vm.expectRevert(Settler__ZeroAddress.selector);
        settler.recoverToken(IERC20(address(srcCst)), address(0), 1);

        vm.expectRevert(Settler__ZeroAmount.selector);
        settler.recoverToken(IERC20(address(srcCst)), anyone, 0);
    }
}
