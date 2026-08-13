// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { BaseTest } from "../base/BaseTest.sol";

/// @notice Pins the public ABI surface of `ICorkRolloverContract` against accidental re-introduction
///         of the transient-slot leakage selector `lastDeliveredPremium(address)`. The
///         function is intentionally NOT part of the external interface — it is only
///         meaningful when read from inside a delegatecalled premium hook, where
///         `LibLastDeliveredPremium.read` is the canonical entry point.
contract ICorkRolloverContractSurfaceTest is BaseTest {
    /// @notice Selector for the removed external view
    ///         `lastDeliveredPremium(address) external view returns (uint256)`.
    bytes4 internal constant REMOVED_SELECTOR = bytes4(keccak256("lastDeliveredPremium(address)"));

    /// @notice A low-level staticcall using the removed selector against a deployed rolloverContract
    ///         must NOT successfully decode a uint256 return value. The rolloverContract has no
    ///         matching dispatch entry, so this either reverts or returns empty calldata —
    ///         either way `success && returndata.length == 32` is false.
    function test_lastDeliveredPremiumSelector_isNotPartOfRolloverContractABI() public view {
        (bool success, bytes memory returndata) =
            rolloverContract.staticcall(abi.encodeWithSelector(REMOVED_SELECTOR, address(0)));
        bool decodedAsUint = success && returndata.length == 32;
        assertFalse(
            decodedAsUint, "lastDeliveredPremium(address) must not be reachable as an external view"
        );
    }
}
