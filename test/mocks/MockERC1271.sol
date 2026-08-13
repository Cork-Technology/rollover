// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";

/// @notice Mock ERC-1271 signer used by signature tests.
contract MockERC1271 is IERC1271 {
    /// @notice Accept.
    /// @return accept Stored accept value.
    bool public accept;
    /// @param accept_ Boolean accept/reject toggle.

    constructor(bool accept_) {
        accept = accept_;
    }
    /// @notice Sets accept.
    /// @param accept_ Boolean accept/reject toggle.

    function setAccept(bool accept_) external {
        accept = accept_;
    }

    /// @notice ERC-1271 isValidSignature mock — returns magic value when `accept`
    /// is true, else a sentinel reject value. Ignores both inputs.
    /// @param hash Ignored hash being validated.
    /// @param signature Ignored signature bytes.
    /// @return ERC-1271 magic value when accepting, else 0xdeadbeef.
    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4) {
        hash;
        signature;
        return accept ? IERC1271.isValidSignature.selector : bytes4(0xdeadbeef);
    }
}
