// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";
import {
    LibPhoenixShareQuantum__FillAmountNotQuantumAligned,
    LibPhoenixShareQuantum__ResidualNotQuantumAligned
} from "src/errors/LibPhoenixShareQuantumErrors.sol";
import { LibPhoenixShareQuantum } from "src/libraries/LibPhoenixShareQuantum.sol";

/// @notice Harness exposing internal Phoenix share-quantum validation for unit tests.
contract LibPhoenixShareQuantumHarness {
    /// @notice Calls the library quantum-alignment check.
    /// @param fillAmount Source cST fill amount to validate.
    /// @param residual Residual source cST amount to validate.
    /// @param quantum Required source-share quantum.
    function requireFillAndResidualQuantumAligned(
        uint256 fillAmount,
        uint256 residual,
        uint256 quantum
    ) external pure {
        LibPhoenixShareQuantum.requireFillAndResidualQuantumAligned(fillAmount, residual, quantum);
    }
}

/// @notice Unit tests for Phoenix source-share quantum validation helpers.
contract LibPhoenixShareQuantumTest is Test {
    /// @notice Default quantum used by the unit tests.
    uint256 internal constant QUANTUM = 1e12;

    /// @notice Test harness exposing the internal library function.
    LibPhoenixShareQuantumHarness internal harness;

    /// @notice Deploys a fresh harness for each test.
    function setUp() public {
        harness = new LibPhoenixShareQuantumHarness();
    }

    /// @notice Accepts aligned fills when residual is zero.
    function test_requireFillAndResidualQuantumAligned_acceptsZeroResidual() public view {
        harness.requireFillAndResidualQuantumAligned(5 * QUANTUM, 0, QUANTUM);
    }

    /// @notice Accepts aligned fills when residual is also quantum-aligned.
    function test_requireFillAndResidualQuantumAligned_acceptsAlignedResidual() public view {
        harness.requireFillAndResidualQuantumAligned(5 * QUANTUM, 2 * QUANTUM, QUANTUM);
    }

    /// @notice Reverts when fill amount is not quantum-aligned.
    function testRevert_requireFillAndResidualQuantumAligned_misalignedFill() public {
        uint256 fillAmount = 5 * QUANTUM + 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                LibPhoenixShareQuantum__FillAmountNotQuantumAligned.selector, fillAmount, QUANTUM
            )
        );
        harness.requireFillAndResidualQuantumAligned(fillAmount, 0, QUANTUM);
    }

    /// @notice Reverts when residual amount is not quantum-aligned.
    function testRevert_requireFillAndResidualQuantumAligned_misalignedResidual() public {
        uint256 residual = 2 * QUANTUM + 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                LibPhoenixShareQuantum__ResidualNotQuantumAligned.selector, residual, QUANTUM
            )
        );
        harness.requireFillAndResidualQuantumAligned(5 * QUANTUM, residual, QUANTUM);
    }

    /// @notice Reports fill misalignment before residual misalignment.
    function testRevert_requireFillAndResidualQuantumAligned_misalignedFillTakesPrecedence()
        public
    {
        uint256 fillAmount = 5 * QUANTUM + 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                LibPhoenixShareQuantum__FillAmountNotQuantumAligned.selector, fillAmount, QUANTUM
            )
        );
        harness.requireFillAndResidualQuantumAligned(fillAmount, 2 * QUANTUM + 1, QUANTUM);
    }
}
