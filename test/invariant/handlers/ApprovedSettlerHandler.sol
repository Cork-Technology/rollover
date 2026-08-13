// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { CommonBase } from "forge-std/Base.sol";
import { StdCheats } from "forge-std/StdCheats.sol";
import { StdUtils } from "forge-std/StdUtils.sol";

import { CorkRolloverContractFactory } from "src/CorkRolloverContractFactory.sol";

/// @notice INV-SETTLER-APPROVED family handler — drives factory approve/revoke + rolloverContract dispatch attempts under the allowlist gate.
/// @custom:invariant INV-SETTLER-APPROVED
contract ApprovedSettlerHandler is CommonBase, StdCheats, StdUtils {
    /// @notice Factory ref.
    /// @return factoryRef Stored factory ref value.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)

    CorkRolloverContractFactory public immutable factoryRef;
    /// @notice Factory owner.
    /// @return factoryOwner Stored factory owner value.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)

    address public immutable factoryOwner;
    /// @notice Probed.
    /// @return probed Stored probed value.

    address[] public probed;
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
    /// @notice Ghost rejected non admin.
    /// @return ghostRejectedNonAdmin Stored ghost rejected non admin value.

    uint256 public ghostRejectedNonAdmin;

    /// @param owner_ owner_.
    /// @param f f.
    constructor(CorkRolloverContractFactory f, address owner_) {
        require(owner_ != address(0), "owner=0");
        factoryRef = f;
        factoryOwner = owner_;
    }

    /// @notice handler action: probed count.
    /// @return Return value.
    function probedCount() external view returns (uint256) {
        return probed.length;
    }

    /// @notice handler action: approve arbitrary.
    /// @param seed Fuzz seed.
    function approveArbitrary(uint256 seed) external {
        address s = address(uint160(uint256(keccak256(abi.encode("apv", seed)))) | 1);
        if (!seen[s]) {
            probed.push(s);
            seen[s] = true;
        }
        vm.prank(factoryOwner);
        try factoryRef.approveSettler(s) {
            expectedApproved[s] = true;
            ghostApprovals++;
        } catch { }
    }

    /// @notice handler action: revoke arbitrary.
    /// @param seed Fuzz seed.
    function revokeArbitrary(uint256 seed) external {
        if (probed.length == 0) {
            return;
        }
        address s = probed[seed % probed.length];
        vm.prank(factoryOwner);
        try factoryRef.revokeSettler(s) {
            expectedApproved[s] = false;
            ghostRevocations++;
        } catch { }
    }

    /// @notice handler action: approve as stranger.
    /// @param seed Fuzz seed.
    function approveAsStranger(uint256 seed) external {
        address stranger = address(uint160(uint256(keccak256(abi.encode("str", seed)))) | 2);
        address tgt = address(uint160(uint256(keccak256(abi.encode("tgt", seed)))) | 1);
        vm.prank(stranger);
        try factoryRef.approveSettler(tgt) { }
        catch {
            ghostRejectedNonAdmin++;
        }
    }
}
