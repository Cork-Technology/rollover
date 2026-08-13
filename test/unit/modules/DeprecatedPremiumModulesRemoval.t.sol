// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

/// @title RemovedFullBalancePremiumModulesTest
/// @notice M-05 TDD boundary: removed full-balance premium modules must not remain
///         reachable as new-order source/docs once remediation removes them.
contract RemovedFullBalancePremiumModulesTest is Test {
    /// @notice M-05 pins removal of full-balance premium module sources.
    function test_M05_fullBalancePremiumModules_removedFromSource() public view {
        assertFalse(
            _sourceFileExists("src/modules/TransferAllModule.sol"),
            "TransferAllModule.sol must be removed for new-order hooks"
        );
        assertFalse(
            _sourceFileExists("src/modules/SplitModule.sol"),
            "SplitModule.sol must be removed for new-order hooks"
        );
        assertFalse(
            _sourceFileExists("src/modules/ApproveAllModule.sol"),
            "ApproveAllModule.sol must remain removed for new-order hooks"
        );
    }

    /// @notice M-05 pins docs away from active full-balance premium modules and toward
    ///         scoped premium modules only.
    function test_M05_docsDirectNewPremiumIntentsToScopedModulesOnly() public view {
        string memory modulesDoc = vm.readFile("docs/spec/md/units/modules.md");
        string memory deployDoc = vm.readFile("docs/DEPLOY.md");

        assertTrue(_contains(modulesDoc, "M-05"), "modules docs must identify M-05");
        assertTrue(_contains(modulesDoc, "removed"), "modules docs must mark old modules removed");
        assertTrue(_contains(modulesDoc, "obsolete"), "modules docs must mark old modules obsolete");
        assertTrue(
            _contains(modulesDoc, "ScopedTransferModule")
                && _contains(modulesDoc, "ScopedSplitModule"),
            "modules docs must direct new intents to scoped modules"
        );
        assertFalse(
            _contains(modulesDoc, "| `src/modules/TransferAllModule.sol` | drains |"),
            "modules docs must not list TransferAllModule as an active source module"
        );
        assertFalse(
            _contains(modulesDoc, "Drains rolloverContract's full balance"),
            "modules docs must not describe active full-balance premium drains"
        );
        assertFalse(
            _contains(modulesDoc, "`TransferAllModule.execute(IERC20 token, address to)`"),
            "modules docs must not list TransferAllModule as an active entrypoint"
        );

        assertTrue(_contains(deployDoc, "M-05"), "deploy docs must identify M-05");
        assertTrue(
            _contains(deployDoc, "ScopedTransferModule")
                && _contains(deployDoc, "ScopedSplitModule"),
            "deploy docs must route new premium intents to scoped modules"
        );
        assertTrue(
            _contains(deployDoc, "removed full-balance premium modules"),
            "deploy docs must document removal of full-balance premium modules"
        );
    }

    /// @notice Helper for source deletion assertions; external so try/catch can capture
    ///         the Foundry file-read revert when a file is absent.
    /// @param path Source path to read.
    /// @return True when the source file exists and is non-empty.
    function readSourceFile(string calldata path) external view returns (bool) {
        bytes memory data = vm.readFileBinary(path);
        return data.length > 0;
    }

    function _sourceFileExists(string memory path) private view returns (bool) {
        try this.readSourceFile(path) returns (bool exists) {
            return exists;
        } catch {
            return false;
        }
    }

    function _contains(string memory haystack, string memory needle) private pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0) {
            return true;
        }
        if (n.length > h.length) {
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
