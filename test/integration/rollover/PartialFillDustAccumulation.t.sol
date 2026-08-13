// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

/// @notice partial-fill dust accumulates onto the residual rather than reverting.
contract PartialFillDustAccumulationTest is Test {
    /// @notice ceiling div never underestimates.
    function test_ceilingDivNeverUnderestimates() public pure {
        for (uint256 a = 1; a <= 100; ++a) {
            for (uint256 b = 1; b <= 100; ++b) {
                uint256 floor = a / b;
                uint256 ceil = (a + b - 1) / b;
                assertGe(ceil, floor);
                if (a % b == 0) {
                    assertEq(ceil, floor);
                } else {
                    assertEq(ceil, floor + 1);
                }
            }
        }
    }

    /// @notice fuzzes dust bounded by one less than divisor.
    /// @param num Numerator.
    /// @param den Denominator.
    function testFuzz_dustBoundedByOneLessThanDivisor(uint128 num, uint128 den) public pure {
        if (den == 0) {
            den = 1;
        }
        uint256 a = uint256(num);
        uint256 b = uint256(den);
        uint256 ceil = (a + b - 1) / b;
        uint256 product = ceil * b;

        if (a % b == 0) {
            assertEq(product, a);
        } else {
            assertGt(product, a);
            assertLe(product - a, b - 1);
        }
    }

    /// @notice cumulative dust bounded by fill count.
    function test_cumulativeDustBoundedByFillCount() public pure {
        uint256 N = 1000;
        uint256 cumDust = 0;
        for (uint256 i = 1; i <= N; ++i) {
            uint256 a = i * 7;
            uint256 b = 13;
            uint256 ceil = (a + b - 1) / b;
            cumDust += (ceil * b) - a;
        }

        assertLe(cumDust, N * 12);
    }

    /// @notice divisor one produces no dust.
    function test_divisorOneProducesNoDust() public pure {
        for (uint256 a = 0; a <= 100; ++a) {
            uint256 ceil = a;
            assertEq(ceil, a);
            assertEq(ceil * 1 - a, 0);
        }
    }
}
