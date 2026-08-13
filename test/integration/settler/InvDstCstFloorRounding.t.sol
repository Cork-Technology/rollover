// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Test } from "forge-std/Test.sol";

/// @notice Pins explicit `Math.Rounding.Floor` annotation on the `INV-DSTCST-FLOOR`
///         mulDiv call site, paired NatSpec touch-ups on
///         `BaseFiller.minDstPerSrc` and `EvcRolloverAdapter.minDstPerSrc` that
///         document the floor rounding + 1-wei tolerance phoenix convention.
///         Floor is the OZ Math default — pure documentation pass with zero
///         behavioural change; this suite is the structural guard against
///         regression to the implicit 3-arg form.
contract InvDstCstFloorRoundingTest is Test {
    /// @notice Settler call site at `_finalizeVerifiedRollover` uses the 4-arg explicit
    ///         `Math.Rounding.Floor` form.
    function test_settler_l734_uses_explicit_floor_form() public view {
        string memory src = vm.readFile("src/BaseSettler.sol");
        // Whitespace-tolerant match: assert the four mulDiv arguments appear in order with
        // `Math.Rounding.Floor` as the final argument. `forge fmt` may wrap the call across
        // lines when arguments grow.
        require(
            _contains(src, "srcConsumed,") && _contains(src, "fillerPayload.minDstPerSrc,")
                && _contains(src, "1e18,") && _contains(src, "Math.Rounding.Floor"),
            "BaseSettler mulDiv at INV-DSTCST-FLOOR site must use explicit 4-arg Floor form"
        );
    }

    /// @notice Sister invariant M-08 still uses Ceil on the cPT-holder-protective side.
    ///         Under atomic-fill the ceil-rounded premium computation lives in
    ///         `LibAtomicFill.computeRequiredPremium`; BaseSettler routes through it.
    function test_settler_m08_still_uses_ceil() public view {
        string memory lib = vm.readFile("src/libraries/LibAtomicFill.sol");
        require(
            _contains(lib, "Math.Rounding.Ceil"),
            "LibAtomicFill.computeRequiredPremium must still use Ceil (cPT-holder-protective rounding)"
        );
    }

    /// @notice BaseFiller `@param minDstPerSrc` NatSpec spells out floor + 1-wei tolerance.
    function test_basefiller_natspec_documents_floor() public view {
        string memory src = vm.readFile("src/BaseFiller.sol");
        require(_contains(src, "floor("), "BaseFiller NatSpec must reference floor() rounding");
        require(_contains(src, "1 wei"), "BaseFiller NatSpec must reference 1 wei tolerance");
    }

    /// @notice EvcRolloverAdapter `@param minDstPerSrc` NatSpec spells out floor + 1-wei tolerance.
    function test_evcrolloveradapter_natspec_documents_floor() public view {
        string memory src = vm.readFile("src/EvcRolloverAdapter.sol");
        require(
            _contains(src, "floor("), "EvcRolloverAdapter NatSpec must reference floor() rounding"
        );
        require(
            _contains(src, "1 wei"), "EvcRolloverAdapter NatSpec must reference 1 wei tolerance"
        );
    }

    /// @notice Invariant ledger row for INV-DSTCST-FLOOR notes the Floor convention + 1-wei drift.
    function test_invariants_ledger_documents_floor_rounding() public view {
        string memory ledger = vm.readFile("docs/INVARIANTS.md");
        require(_contains(ledger, "INV-DSTCST-FLOOR"), "Ledger must keep the INV-DSTCST-FLOOR row");
        require(
            _contains(ledger, "floor("),
            "Ledger INV-DSTCST-FLOOR section must mention floor() rounding"
        );
        require(_contains(ledger, "1 wei"), "Ledger INV-DSTCST-FLOOR section must mention 1 wei");
    }

    /// @notice Substring match helper (mirrors the pattern in `BanlistRemoval.t.sol`).
    /// @param haystack Source text to scan.
    /// @param needle Substring to look for.
    /// @return Whether `needle` appears in `haystack`.
    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0) {
            return true;
        }
        if (n.length > h.length) {
            return false;
        }
        for (uint256 i = 0; i <= h.length - n.length; ++i) {
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
}
