// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { CorkRolloverContract } from "src/CorkRolloverContract.sol";
import { CorkRolloverContract__NotOwner } from "src/errors/CorkRolloverContractErrors.sol";
import { BaseTest } from "test/base/BaseTest.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { MockCpt } from "test/mocks/MockPhoenix.sol";

/// @notice CorkRolloverContractOwnerWithdrawTest — pins CorkRolloverContractOwnerWithdraw behaviour for the Cork Rollover suite.
contract CorkRolloverContractOwnerWithdrawTest is BaseTest {
    /// @notice Emitted on owner withdrawn.
    /// @param token Token contract.
    /// @param amount Token amount (raw units).
    event OwnerWithdrawn(address indexed token, uint256 amount);

    /// @notice Pins behaviour: owner Sweeps Src Cst After Full Drain.
    function test_OwnerSweepsSrcCstAfterFullDrain() public {
        uint256 amount = 250e18;
        srcCst.mint(rolloverContract, amount);
        assertEq(srcCst.balanceOf(rolloverContract), amount, "seeded");

        vm.expectEmit(true, false, false, true, rolloverContract);
        emit OwnerWithdrawn(address(srcCst), amount);
        vm.prank(cptHolder);
        CorkRolloverContract(rolloverContract).withdraw(address(srcCst), amount);

        assertEq(srcCst.balanceOf(rolloverContract), 0, "rolloverContract drained");
        assertEq(srcCst.balanceOf(cptHolder), amount, "owner received");
    }

    /// @notice Pins behaviour: owner Sweeps Dst Cst After Full Drain.
    function test_OwnerSweepsDstCstAfterFullDrain() public {
        uint256 amount = 175e18;
        dstCst.mint(rolloverContract, amount);

        vm.expectEmit(true, false, false, true, rolloverContract);
        emit OwnerWithdrawn(address(dstCst), amount);
        vm.prank(cptHolder);
        CorkRolloverContract(rolloverContract).withdraw(address(dstCst), amount);

        assertEq(dstCst.balanceOf(rolloverContract), 0, "rolloverContract drained");
        assertEq(dstCst.balanceOf(cptHolder), amount, "owner received");
    }

    /// @notice Pins behaviour: owner Sweeps Premium Token.
    function test_OwnerSweepsPremiumToken() public {
        uint256 amount = 42e18;
        premiumToken.mint(rolloverContract, amount);

        vm.prank(cptHolder);
        CorkRolloverContract(rolloverContract).withdraw(address(premiumToken), amount);

        assertEq(premiumToken.balanceOf(rolloverContract), 0, "rolloverContract drained");
        assertEq(premiumToken.balanceOf(cptHolder), amount, "owner received");
    }

    /// @notice Pins behaviour: owner Sweeps Src Cpt Residual.
    function test_OwnerSweepsSrcCptResidual() public {
        uint256 amount = 88e18;
        MockCpt(address(srcCpt)).mint(rolloverContract, amount);

        vm.prank(cptHolder);
        CorkRolloverContract(rolloverContract).withdraw(address(srcCpt), amount);

        assertEq(
            MockCpt(address(srcCpt)).balanceOf(rolloverContract), 0, "rolloverContract drained"
        );
        assertEq(MockCpt(address(srcCpt)).balanceOf(cptHolder), amount, "owner received");
    }

    /// @notice Pins behaviour: owner Sweeps Dst Cpt Residual.
    function test_OwnerSweepsDstCptResidual() public {
        uint256 amount = 91e18;
        MockCpt(address(dstCpt)).mint(rolloverContract, amount);

        vm.prank(cptHolder);
        CorkRolloverContract(rolloverContract).withdraw(address(dstCpt), amount);

        assertEq(
            MockCpt(address(dstCpt)).balanceOf(rolloverContract), 0, "rolloverContract drained"
        );
        assertEq(MockCpt(address(dstCpt)).balanceOf(cptHolder), amount, "owner received");
    }

    /// @notice Pins behaviour: non Owner Withdraw Reverts.
    function test_NonOwnerWithdrawReverts() public {
        srcCst.mint(rolloverContract, 10e18);
        vm.prank(anyone);
        vm.expectRevert(CorkRolloverContract__NotOwner.selector);
        CorkRolloverContract(rolloverContract).withdraw(address(srcCst), 10e18);
    }

    /// @notice Pins behaviour: withdraw Zero Amount Reverts or Noops.
    function test_WithdrawZeroAmountReverts_orNoops() public {
        uint256 ownerBalBefore = srcCst.balanceOf(cptHolder);
        uint256 rolloverContractBalBefore = srcCst.balanceOf(rolloverContract);

        vm.expectEmit(true, false, false, true, rolloverContract);
        emit OwnerWithdrawn(address(srcCst), 0);
        vm.prank(cptHolder);
        CorkRolloverContract(rolloverContract).withdraw(address(srcCst), 0);

        assertEq(srcCst.balanceOf(cptHolder), ownerBalBefore, "owner unchanged");
        assertEq(
            srcCst.balanceOf(rolloverContract),
            rolloverContractBalBefore,
            "rolloverContract unchanged"
        );
    }

    /// @notice Pins behaviour: withdraw With Live Order Behavior.
    function test_WithdrawWithLiveOrderBehavior() public {
        _openOrder(_baseOrder());

        uint256 amount = 33e18;
        srcCst.mint(rolloverContract, amount);

        vm.prank(cptHolder);
        CorkRolloverContract(rolloverContract).withdraw(address(srcCst), amount);
        assertEq(srcCst.balanceOf(cptHolder), amount, "withdraw allowed during live order");
    }
}
