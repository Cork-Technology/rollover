// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { CommonBase } from "forge-std/Base.sol";
import { StdCheats } from "forge-std/StdCheats.sol";
import { StdUtils } from "forge-std/StdUtils.sol";

import { CorkRolloverContractFactory } from "src/CorkRolloverContractFactory.sol";

/// @notice drives factory approveSettler / revokeSettler / stranger-approval / renounce probes.
contract FactoryInvariantHandler is CommonBase, StdCheats, StdUtils {
    /// @notice Factory ref.
    /// @return factoryRef Stored factory ref value.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)

    CorkRolloverContractFactory public immutable factoryRef;
    /// @notice Factory owner.
    /// @return factoryOwner Stored factory owner value.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)

    address public immutable factoryOwner;
    /// @notice Probed settlers.
    /// @return probedSettlers Stored probed settlers value.

    address[] public probedSettlers;
    /// @notice Seen.
    /// @return seen Stored seen value.

    mapping(address => bool) public seen;
    /// @notice Expected approved.
    /// @return expectedApproved Stored expected approved value.

    mapping(address => bool) public expectedApproved;
    /// @notice Ghost approvals.
    /// @return ghostApprovals Stored ghost approvals value.

    uint256 public ghostApprovals;
    /// @notice Ghost revocations.
    /// @return ghostRevocations Stored ghost revocations value.

    uint256 public ghostRevocations;
    /// @notice Ghost non owner probes.
    /// @return ghostNonOwnerProbes Stored ghost non owner probes value.

    uint256 public ghostNonOwnerProbes;

    // forge-lint: disable-next-line(missing-zero-check)
    /// @param owner_ owner_.
    /// @param f f.
    // Invariant handler mirrors arbitrary factory owner configured by the fixture.
    // forge-lint: disable-next-line(missing-zero-check)
    constructor(CorkRolloverContractFactory f, address owner_) {
        factoryRef = f;
        factoryOwner = owner_;
    }
    /// @notice Sets tlers count.
    /// @return Return value.

    function settlersCount() external view returns (uint256) {
        return probedSettlers.length;
    }
    /// @notice Approve arbitrary settler.
    /// @param seed Fuzz seed.

    function approveArbitrarySettler(uint256 seed) external {
        address s = address(uint160(uint256(keccak256(abi.encode("apv", seed)))) | 1);
        if (!seen[s]) {
            probedSettlers.push(s);
            seen[s] = true;
        }
        vm.prank(factoryOwner);
        try factoryRef.approveSettler(s) {
            expectedApproved[s] = true;
            ghostApprovals++;
        } catch { }
    }
    /// @notice Revoke arbitrary settler.
    /// @param seed Fuzz seed.

    function revokeArbitrarySettler(uint256 seed) external {
        if (probedSettlers.length == 0) {
            return;
        }
        address s = probedSettlers[seed % probedSettlers.length];
        vm.prank(factoryOwner);
        try factoryRef.revokeSettler(s) {
            expectedApproved[s] = false;
            ghostRevocations++;
        } catch { }
    }
    /// @notice Probe approve as stranger.
    /// @param seed Fuzz seed.

    function probeApproveAsStranger(uint256 seed) external {
        address stranger = address(uint160(uint256(keccak256(abi.encode("nob", seed)))) | 1);
        address tgt = address(uint160(uint256(keccak256(abi.encode("tgt", seed)))) | 1);
        vm.prank(stranger);
        try factoryRef.approveSettler(tgt) { }
        catch {
            ghostNonOwnerProbes++;
        }
    }
    /// @notice Probe renounce.

    function probeRenounce() external {
        vm.prank(factoryOwner);
        try factoryRef.renounceOwnership() { } catch { }
    }
}
