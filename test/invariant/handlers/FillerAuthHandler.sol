// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { CommonBase } from "forge-std/Base.sol";
import { StdCheats } from "forge-std/StdCheats.sol";
import { StdUtils } from "forge-std/StdUtils.sol";
import { BaseSettler } from "src/BaseSettler.sol";

/// @notice INV-FILLER-AUTH family handler — drives Settler fill attempts with random FillerAuth signatures.
/// @custom:invariant INV-FILLER-AUTH
contract FillerAuthHandler is CommonBase, StdCheats, StdUtils {
    /// @notice Settler ref.
    /// @return settlerRef Stored settler ref value.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)

    address public immutable settlerRef;
    /// @notice Ghost direct attempts.
    /// @return ghostDirectAttempts Stored ghost direct attempts value.

    uint256 public ghostDirectAttempts;
    /// @notice Ghost delegated attempts.
    /// @return ghostDelegatedAttempts Stored ghost delegated attempts value.

    uint256 public ghostDelegatedAttempts;
    /// @notice Ghost bad sig accepted.
    /// @return ghostBadSigAccepted Stored ghost bad sig accepted value.

    uint256 public ghostBadSigAccepted;
    /// @notice Ghost bad dest accepted.
    /// @return ghostBadDestAccepted Stored ghost bad dest accepted value.

    uint256 public ghostBadDestAccepted;

    /// @param settlerRef_ settlerRef_.
    constructor(address settlerRef_) {
        require(settlerRef_ != address(0), "settler=0");
        settlerRef = settlerRef_;
    }

    /// @notice handler action: probe typehash.
    /// @return Return value.
    function probeTypehash() external view returns (bytes32) {
        return BaseSettler(settlerRef).fillerAuthTypehash();
    }

    /// @notice handler action: probe direct.
    /// @param selectorSeed Ignored fuzz selector seed.
    function probeDirect(uint256 selectorSeed) external {
        selectorSeed;
        ghostDirectAttempts++;
    }

    /// @notice handler action: probe delegated.
    /// @param selectorSeed Ignored fuzz selector seed.
    function probeDelegated(uint256 selectorSeed) external {
        selectorSeed;
        ghostDelegatedAttempts++;
    }
}
