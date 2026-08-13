// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

/// @notice Shared helpers for tests that pin source text with `vm.readFile`.
abstract contract SourceShapeAssertions is Test {
    /// @notice Asserts that `haystack` contains `needle`.
    function assertSourceContains(
        string memory haystack,
        string memory needle,
        string memory context
    ) internal pure {
        require(
            sourceContains(haystack, needle),
            string.concat("missing: ", context, " - needle: ", needle)
        );
    }

    /// @notice Asserts that `haystack` does not contain `needle`.
    function assertSourceNotContains(
        string memory haystack,
        string memory needle,
        string memory context
    ) internal pure {
        require(
            !sourceContains(haystack, needle),
            string.concat("forbidden present: ", context, " - needle: ", needle)
        );
    }

    /// @notice Asserts that `needle` appears after `startNeedle` and before `endNeedle`.
    function assertSourceContainsBetween(
        string memory haystack,
        string memory startNeedle,
        string memory endNeedle,
        string memory needle,
        string memory context
    ) internal pure {
        bytes memory h = bytes(haystack);
        uint256 start = sourceIndexOf(h, bytes(startNeedle), 0);
        require(start != type(uint256).max, string.concat("missing start: ", context));

        uint256 end = sourceIndexOf(h, bytes(endNeedle), start);
        require(end != type(uint256).max, string.concat("missing end: ", context));

        require(
            sourceContainsBetween(h, bytes(needle), start, end),
            string.concat("missing between: ", context, " - needle: ", needle)
        );
    }

    /// @notice Returns true if `haystack` contains `needle`.
    function sourceContains(string memory haystack, string memory needle)
        internal
        pure
        returns (bool)
    {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0) {
            return true;
        }
        if (n.length > h.length) {
            return false;
        }
        for (uint256 i = 0; i + n.length <= h.length; ++i) {
            bool ok = true;
            for (uint256 j = 0; j < n.length; ++j) {
                if (h[i + j] != n[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) {
                return true;
            }
        }
        return false;
    }

    /// @notice Return the first index of `needle` in `haystack` at or after `from`.
    function sourceIndexOf(bytes memory haystack, bytes memory needle, uint256 from)
        internal
        pure
        returns (uint256)
    {
        if (needle.length == 0 || needle.length > haystack.length || from > haystack.length) {
            return type(uint256).max;
        }
        for (uint256 i = from; i + needle.length <= haystack.length; ++i) {
            bool matches = true;
            for (uint256 j = 0; j < needle.length; ++j) {
                if (haystack[i + j] != needle[j]) {
                    matches = false;
                    break;
                }
            }
            if (matches) {
                return i;
            }
        }
        return type(uint256).max;
    }

    /// @notice Return whether `needle` appears in `haystack[start:end]`.
    function sourceContainsBetween(
        bytes memory haystack,
        bytes memory needle,
        uint256 start,
        uint256 end
    ) internal pure returns (bool) {
        if (
            needle.length == 0 || end > haystack.length || start > end
                || needle.length > end - start
        ) {
            return false;
        }
        for (uint256 i = start; i + needle.length <= end; ++i) {
            bool matches = true;
            for (uint256 j = 0; j < needle.length; ++j) {
                if (haystack[i + j] != needle[j]) {
                    matches = false;
                    break;
                }
            }
            if (matches) {
                return true;
            }
        }
        return false;
    }
}
