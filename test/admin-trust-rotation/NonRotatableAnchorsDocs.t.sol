// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Test } from "forge-std/Test.sol";

/// @notice NonRotatableAnchorsDocsTest — pins the documentation surface for immutable anchors.
///         Four immutable trust anchors stay immutable BY DESIGN; this test
///         locks down the INV row in `docs/INVARIANTS.md` and confirms no setter accidentally
///         got introduced on the four anchors.
contract NonRotatableAnchorsDocsTest is Test {
    /// @notice The `INV-NON-ROTATABLE-TRUST-ANCHORS` ledger entry exists in docs/INVARIANTS.md.
    function test_INV_NonRotatableTrustAnchors_DocsExist() public view {
        string memory ledger = vm.readFile("docs/INVARIANTS.md");
        require(
            _contains(ledger, "### INV-NON-ROTATABLE-TRUST-ANCHORS"),
            "docs/INVARIANTS.md must declare INV-NON-ROTATABLE-TRUST-ANCHORS heading"
        );
    }

    /// @notice The `INV-FACTORY-DEFAULTS-MANAGED` ledger entry exists in docs/INVARIANTS.md.
    function test_INV_FactoryDefaultsManaged_DocsExist() public view {
        string memory ledger = vm.readFile("docs/INVARIANTS.md");
        require(
            _contains(ledger, "### INV-FACTORY-DEFAULTS-MANAGED"),
            "docs/INVARIANTS.md must declare INV-FACTORY-DEFAULTS-MANAGED heading"
        );
    }

    /// @notice The four non-rotatable immutables retain their `immutable` keyword in src/.
    function test_NonRotatableAnchors_RemainImmutable() public view {
        string memory baseSettler = vm.readFile("src/BaseSettler.sol");
        require(
            _contains(baseSettler, "address public immutable ROLLOVER_CONTRACT_FACTORY"),
            "BaseSettler.ROLLOVER_CONTRACT_FACTORY must remain public immutable"
        );
        require(
            _contains(baseSettler, "address public immutable CORK_POOL_MANAGER"),
            "BaseSettler.CORK_POOL_MANAGER must remain public immutable"
        );

        string memory factorySrc = vm.readFile("src/CorkRolloverContractFactory.sol");
        require(
            _contains(factorySrc, "address public immutable ROLLOVER_CONTRACT_IMPLEMENTATION"),
            "CorkRolloverContractFactory.ROLLOVER_CONTRACT_IMPLEMENTATION must remain immutable"
        );
        require(
            _contains(factorySrc, "address public immutable trustConfigTimelock"),
            "CorkRolloverContractFactory.trustConfigTimelock must remain immutable"
        );
    }

    /// @notice NatSpec for the four anchors references the INV row (light-touch sanity check).
    function test_NonRotatableAnchors_NatSpec_References_INV() public view {
        string memory baseSettler = vm.readFile("src/BaseSettler.sol");
        require(
            _contains(baseSettler, "INV-NON-ROTATABLE-TRUST-ANCHORS"),
            "BaseSettler must cite INV-NON-ROTATABLE-TRUST-ANCHORS in NatSpec"
        );
        string memory factorySrc = vm.readFile("src/CorkRolloverContractFactory.sol");
        require(
            _contains(factorySrc, "INV-NON-ROTATABLE-TRUST-ANCHORS"),
            "CorkRolloverContractFactory must cite INV-NON-ROTATABLE-TRUST-ANCHORS in NatSpec"
        );
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
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
}
