// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";

/// @notice Dsr2cAsymmetryDocumentationTest — pins the post-heri-fix asymmetry between
///         dstCST (DSR-2b, security-load-bearing) and caDst (DSR-2c, cPT-holder discretion wider
///         bracket) via structural NatSpec assertions on `src/CorkRolloverContract.sol` and a paired
///         row on `docs/INVARIANTS.md`.
contract Dsr2cAsymmetryDocumentationTest is BaseTest {
    /// @notice `src/CorkRolloverContract.sol` must carry an explicit DSR-2c `@custom:invariant` tag
    ///         that names the pre-pre-hook anchor and the wider-bracket semantics.
    function test_natspec_dsr2c_documents_wider_bracket() public view {
        string memory src = vm.readFile("src/CorkRolloverContract.sol");
        assertTrue(
            _contains(src, "DSR-2c"),
            "src/CorkRolloverContract.sol must declare a DSR-2c @custom:invariant tag"
        );
        assertTrue(
            _contains(src, "pre-pre-hook"),
            "DSR-2c NatSpec must spell out the pre-pre-hook caDstBefore anchor"
        );
        assertTrue(
            _contains(src, "accepted-03"),
            "DSR-2c NatSpec must cite the accepted-03 cPT-holder discretion threat model"
        );
        assertTrue(
            _contains(src, "Asymmetric with DSR-2b"),
            "DSR-2c NatSpec must cross-reference DSR-2b explicitly"
        );
    }

    /// @notice DSR-2b's NatSpec must also acknowledge the asymmetry from its side.
    function test_natspec_dsr2b_cross_references_dsr2c() public view {
        string memory src = vm.readFile("src/CorkRolloverContract.sol");
        assertTrue(
            _contains(src, "DSR-2b"),
            "src/CorkRolloverContract.sol must keep the DSR-2b invariant tag"
        );
        // DSR-2b row mentions DSR-2c (asymmetric pair) somewhere in the same file.
        assertTrue(_contains(src, "DSR-2c"), "DSR-2b must cross-reference DSR-2c by tag");
    }

    /// @notice `docs/INVARIANTS.md` must carry a DSR-2c row that names the
    ///         pre-pre-hook anchor and the asymmetry vs DSR-2b.
    function test_invariants_ledger_documents_dsr2c() public view {
        string memory ledger = vm.readFile("docs/INVARIANTS.md");
        assertTrue(_contains(ledger, "DSR-2c"), "docs/INVARIANTS.md must carry a DSR-2c row");
        assertTrue(
            _contains(ledger, "pre-pre-hook"),
            "DSR-2c ledger row must spell out the pre-pre-hook anchor"
        );
        assertTrue(_contains(ledger, "accepted-03"), "DSR-2c ledger row must cite accepted-03");
    }

    /// @dev Naive substring search — only used against doc-and-source bytes.
    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0 || n.length > h.length) {
            return false;
        }
        for (uint256 i = 0; i <= h.length - n.length; ++i) {
            bool match_ = true;
            for (uint256 j = 0; j < n.length; ++j) {
                if (h[i + j] != n[j]) {
                    match_ = false;
                    break;
                }
            }
            if (match_) {
                return true;
            }
        }
        return false;
    }
}
