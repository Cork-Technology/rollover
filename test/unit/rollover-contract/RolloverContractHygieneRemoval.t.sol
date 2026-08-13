// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";
import { CorkRolloverContract } from "src/CorkRolloverContract.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice RolloverContractHygieneRemovalTest — pins RolloverContractHygieneRemoval behaviour for the Cork Rollover suite.
contract RolloverContractHygieneRemovalTest is Test {
    /// @notice RolloverContract impl.
    CorkRolloverContract internal rolloverContractImpl;
    /// @notice Test fixture setup.

    function setUp() public {
        rolloverContractImpl = new CorkRolloverContract();
    }

    /// @notice Pins behaviour: removed execute Hooks selector Absent.
    function test_removed_executeHooks_selectorAbsent() public {
        RolloverTypes.Call[] memory empty = new RolloverTypes.Call[](0);
        (bool ok, bytes memory ret) = address(rolloverContractImpl)
            .call(
                abi.encodeWithSignature("executeHooks((address,uint256,bytes,bool,bool)[])", empty)
            );
        assertFalse(ok, "executeHooks selector must not dispatch after deletion");
        assertEq(ret.length, 0, "selector-miss returns empty data (no typed revert)");
    }

    /// @notice Pins behaviour: removed orphan Symbols absent From Src.
    function test_removed_orphanSymbols_absentFromSrc() public view {
        string memory exactSettlerSrc = vm.readFile("src/ExactSettler.sol");
        string memory partialSettlerSrc = vm.readFile("src/PartialSettler.sol");
        string memory baseFillerSrc = vm.readFile("src/BaseFiller.sol");
        string memory evcSrc = vm.readFile("src/EvcRolloverAdapter.sol");
        string memory rolloverContractSrc = vm.readFile("src/CorkRolloverContract.sol");

        _assertAbsent(exactSettlerSrc, "error Settler__BadOrderType", "ExactSettler.sol");
        _assertAbsent(partialSettlerSrc, "error Settler__BadOrderType", "PartialSettler.sol");
        _assertAbsent(exactSettlerSrc, "error Settler__DecimalTruncates", "ExactSettler.sol");
        _assertAbsent(partialSettlerSrc, "error Settler__DecimalTruncates", "PartialSettler.sol");
        _assertAbsent(exactSettlerSrc, "error Settler__IntentHashMismatch", "ExactSettler.sol");
        _assertAbsent(partialSettlerSrc, "error Settler__IntentHashMismatch", "PartialSettler.sol");
        _assertAbsent(exactSettlerSrc, "error Settler__PolarityMismatch", "ExactSettler.sol");
        _assertAbsent(partialSettlerSrc, "error Settler__PolarityMismatch", "PartialSettler.sol");

        _assertAbsent(baseFillerSrc, "error BaseFiller__FillFailed", "BaseFiller.sol");
        _assertAbsent(baseFillerSrc, "error BaseFiller__LeftoverRefundFailed", "BaseFiller.sol");

        _assertAbsent(
            evcSrc, "error EvcRolloverAdapter__LeftoverRefundFailed", "EvcRolloverAdapter.sol"
        );
        _assertAbsent(
            evcSrc, "error EvcRolloverAdapter__SettlerPathMismatch", "EvcRolloverAdapter.sol"
        );

        _assertAbsent(rolloverContractSrc, "event ModuleBlocked(", "CorkRolloverContract.sol");
    }

    /// @notice Pins behaviour: removed call Failed Error absent delegatecall Failed Survives.
    function test_removed_callFailedError_absent_delegatecallFailedSurvives() public view {
        string memory rolloverContractSrc = vm.readFile("src/CorkRolloverContract.sol");
        string memory rolloverContractErrorsSrc =
            vm.readFile("src/errors/CorkRolloverContractErrors.sol");
        _assertAbsent(
            rolloverContractSrc,
            "error CorkRolloverContract__CallFailed",
            "CorkRolloverContract.sol"
        );

        require(
            _contains(rolloverContractErrorsSrc, "error CorkRolloverContract__DelegatecallFailed"),
            "CorkRolloverContract__DelegatecallFailed must survive"
        );
    }

    function _assertAbsent(string memory haystack, string memory needle, string memory file)
        internal
        pure
    {
        require(
            !_contains(haystack, needle),
            string.concat("orphan symbol still present in ", file, ": ", needle)
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
