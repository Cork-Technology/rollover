// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";
import { CorkRolloverContract } from "src/CorkRolloverContract.sol";
import { ICorkRolloverContract } from "src/interfaces/rollover/ICorkRolloverContract.sol";

/// @notice Handler that bombards a rolloverContract with attempts to write trust state directly,
///         bypassing the factory. Every attempt MUST revert; live state MUST stay frozen.
contract FactorySoleTrustWriterHandler is Test {
    /// @notice Target rolloverContract.
    address public immutable target;

    /// @notice Live threshold snapshot expected after every handler call.
    uint8 public expectedThreshold;

    /// @notice Live attester list snapshot expected after every handler call.
    address[] public expectedAttesters;

    /// @notice Count of revert observations (every attempted bypass must revert).
    uint64 public ghostReverts;

    /// @notice Wire the handler to a target rolloverContract and snapshot its current live config.
    /// @param target_ RolloverContract address under attack.
    /// @param threshold_ Live threshold at deploy time (expected to remain frozen).
    /// @param attesters_ Live attester list at deploy time (expected to remain frozen).
    // Invariant handler mirrors arbitrary target rolloverContract configured by the fixture.
    // forge-lint: disable-next-line(missing-zero-check)
    constructor(address target_, uint8 threshold_, address[] memory attesters_) {
        target = target_;
        expectedThreshold = threshold_;
        for (uint256 i = 0; i < attesters_.length; ++i) {
            expectedAttesters.push(attesters_[i]);
        }
    }

    /// @notice Memory copy of the expected attester list (for invariant assertions).
    /// @return out Memory copy of `expectedAttesters`.
    function expectedAttestersList() external view returns (address[] memory out) {
        out = new address[](expectedAttesters.length);
        for (uint256 i = 0; i < expectedAttesters.length; ++i) {
            out[i] = expectedAttesters[i];
        }
    }

    /// @notice Attempt direct rolloverContract.setTrustConfig from a random EOA.
    /// @param callerSeed Seed used to derive the calling EOA.
    /// @param threshold Raw fuzz threshold (bounded to `[1, atLen]`).
    /// @param listSeed Raw fuzz seed for attester-list length (bounded to `[1, 3]`).
    function attemptDirectSet(uint256 callerSeed, uint8 threshold, uint8 listSeed) external {
        // forge-lint: disable-next-line(unsafe-typecast)
        address caller = address(uint160(uint256(keccak256(abi.encode("caller", callerSeed)))) | 1);
        uint8 atLen = uint8(bound(listSeed, 1, 3));
        uint8 th = uint8(bound(threshold, 1, atLen));
        address[] memory att = new address[](atLen);
        for (uint256 i = 0; i < atLen; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast)
            att[i] = address(uint160(0xD000 + i + 1));
        }
        vm.prank(caller);
        try ICorkRolloverContract(target).setTrustConfig(th, att) {
            revert("BYPASS: rolloverContract.setTrustConfig accepted a non-factory caller");
        } catch {
            ghostReverts++;
        }
    }

    /// @notice Attempt rolloverContract self-call (calls rolloverContract from the rolloverContract address itself).
    /// @param threshold Raw fuzz threshold (bounded to `[1, 3]`).
    function attemptSelfCall(uint8 threshold) external {
        uint8 th = uint8(bound(threshold, 1, 3));
        address[] memory att = new address[](1);
        att[0] = address(0xEEE);
        vm.prank(target);
        try ICorkRolloverContract(target).setTrustConfig(th, att) {
            revert("BYPASS: rolloverContract self-call accepted");
        } catch {
            ghostReverts++;
        }
    }
}
