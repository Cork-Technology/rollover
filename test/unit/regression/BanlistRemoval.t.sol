// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";
import { CorkRolloverContract } from "src/CorkRolloverContract.sol";

/// @notice BanlistRemovalTest — pins BanlistRemoval behaviour for the Cork Rollover suite.
contract BanlistRemovalTest is Test {
    /// @notice Pins behaviour: module Blocked Error No Longer Exists.
    function test_ModuleBlockedErrorNoLongerExists() public view {
        string memory src = vm.readFile("src/CorkRolloverContract.sol");
        require(
            !_contains(src, "CorkRolloverContract__ModuleBlocked"),
            "CorkRolloverContract__ModuleBlocked must be deleted from src/CorkRolloverContract.sol"
        );
    }

    /// @notice Pins behaviour: no Banlist Gate In Execute Intent Calls.
    function test_NoBanlistGateInExecuteIntentCalls() public view {
        string memory src = vm.readFile("src/CorkRolloverContract.sol");
        require(!_contains(src, "banlist.isBlocked"), "banlist.isBlocked() call must be deleted");
        require(!_contains(src, "ICorkBanlist"), "ICorkBanlist import must be deleted");
        require(!_contains(src, "corkBanlist;"), "corkBanlist storage field must be deleted");
    }

    /// @notice Pins behaviour: cork Banlist Interface File Deleted.
    function test_CorkBanlistInterfaceFileDeleted() public {
        (bool ok, bytes memory ret) = address(vm)
            .call(abi.encodeWithSignature("readFile(string)", "src/interfaces/ICorkBanlist.sol"));

        if (ok) {
            require(ret.length == 0, "src/interfaces/ICorkBanlist.sol must be deleted");
        }
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
