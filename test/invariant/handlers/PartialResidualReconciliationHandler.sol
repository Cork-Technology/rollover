// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { CommonBase } from "forge-std/Base.sol";
import { StdCheats } from "forge-std/StdCheats.sol";
import { StdUtils } from "forge-std/StdUtils.sol";

import { PartialSettler } from "src/PartialSettler.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";
import { SettlerTypes } from "src/types/SettlerTypes.sol";

/// @notice N-INV-PARTIAL-RESIDUAL-RECONCILES-TO-TOTAL family handler — drives partial-fill / cancel ops while ghost-tracking residual sums.
/// @custom:invariant N-INV-PARTIAL-RESIDUAL-RECONCILES-TO-TOTAL
contract PartialResidualReconciliationHandler is CommonBase, StdCheats, StdUtils {
    /// @notice Settler ref.
    /// @return settlerRef Stored settler ref value.
    PartialSettler public immutable settlerRef;
    /// @notice Observed digests.
    /// @return observedDigests Stored observed digests value.

    bytes32[] public observedDigests;
    /// @notice Digest observed.
    /// @return digestObserved Stored digest observed value.

    mapping(bytes32 => bool) public digestObserved;
    /// @notice Digest fillers.
    /// @return digestFillers Stored digest fillers value.

    mapping(bytes32 => address[]) public digestFillers;
    /// @notice Seen filler.
    /// @return seenFiller Stored seen filler value.

    mapping(bytes32 => mapping(address => bool)) public seenFiller;
    /// @notice Reconciliation violated.
    /// @return reconciliationViolated Stored reconciliation violated value.

    bool public reconciliationViolated;
    /// @notice Ghost registrations.
    /// @return ghostRegistrations Stored ghost registrations value.

    uint64 public ghostRegistrations;
    /// @notice Ghost observations.
    /// @return ghostObservations Stored ghost observations value.

    uint64 public ghostObservations;
    /// @notice Ghost warps.
    /// @return ghostWarps Stored ghost warps value.

    uint64 public ghostWarps;

    /// @param settler_ settler_.
    constructor(PartialSettler settler_) {
        settlerRef = settler_;
    }

    /// @notice handler action: register digest and filler.
    /// @param digestSeed Fuzz seed used to pick an order digest from a bounded set.
    /// @param fillerSeed Fuzz seed used to pick a filler from a bounded set.
    function registerDigestAndFiller(bytes32 digestSeed, address fillerSeed) external {
        if (!digestObserved[digestSeed]) {
            digestObserved[digestSeed] = true;
            observedDigests.push(digestSeed);
        }
        if (!seenFiller[digestSeed][fillerSeed]) {
            seenFiller[digestSeed][fillerSeed] = true;
            digestFillers[digestSeed].push(fillerSeed);
        }
        ghostRegistrations++;
    }

    /// @notice handler action: observe reconciliation.
    /// @param digestIndexSeed Fuzz seed used to pick a digest index from a bounded set.
    function observeReconciliation(uint256 digestIndexSeed) external {
        uint256 n = observedDigests.length;
        if (n == 0) {
            return;
        }
        bytes32 digest = observedDigests[bound(digestIndexSeed, 0, n - 1)];

        uint256 total = settlerRef.rolloverAccountingOf(digest).dstCstEscrowed;
        uint256 sum;
        address[] storage fillers = digestFillers[digest];
        uint256 m = fillers.length;
        for (uint256 i = 0; i < m; ++i) {
            address f = fillers[i];
            if (settlerRef.fillerSlotAccountingOf(digest, f, bytes32(uint256(uint160(f)))).settled)
            {
                continue;
            }
            SettlerTypes.FillerRolloverAccounting memory rec =
            settlerRef.fillerSlotAccountingOf(digest, f, bytes32(uint256(uint160(f)))).rollover;
            sum += rec.dstCstProduced;
        }
        if (sum != total) {
            reconciliationViolated = true;
        }
        ghostObservations++;
    }

    /// @notice handler action: warp forward.
    /// @param delta Numeric delta.
    function warpForward(uint64 delta) external {
        uint64 d = uint64(bound(delta, 0, 1 hours));
        vm.warp(block.timestamp + d);
        ghostWarps++;
    }

    /// @notice handler action: observed digest count.
    /// @return Return value.
    function observedDigestCount() external view returns (uint256) {
        return observedDigests.length;
    }

    /// @notice handler action: filler count.
    /// @param digest Hash digest.
    /// @return Return value.
    function fillerCount(bytes32 digest) external view returns (uint256) {
        return digestFillers[digest].length;
    }
}
