// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { CommonBase } from "forge-std/Base.sol";
import { StdCheats } from "forge-std/StdCheats.sol";
import { StdUtils } from "forge-std/StdUtils.sol";

import { PartialSettler } from "src/PartialSettler.sol";

/// @notice N-INV-FILLER-SETTLED-STICKY family handler — drives settle/refund ops while observing per-filler settled flags.
/// @custom:invariant N-INV-FILLER-SETTLED-STICKY
contract FillerSettledStickyHandler is CommonBase, StdCheats, StdUtils {
    /// @notice Settler ref.
    /// @return settlerRef Stored settler ref value.
    PartialSettler public immutable settlerRef;
    /// @notice Observed keys.
    /// @return observedKeys Stored observed keys value.

    bytes32[] public observedKeys;
    /// @notice Observed.
    /// @return observed Stored observed value.

    mapping(bytes32 => bool) public observed;
    /// @notice Key to order id.
    /// @return keyToOrderId Stored key to order id value.

    mapping(bytes32 => bytes32) public keyToOrderId;
    /// @notice Key to filler.
    /// @return keyToFiller Stored key to filler value.

    mapping(bytes32 => address) public keyToFiller;
    /// @notice Ever settled.
    /// @return everSettled Stored ever settled value.

    mapping(bytes32 => bool) public everSettled;
    /// @notice Stickiness violated.
    /// @return stickinessViolated Stored stickiness violated value.

    bool public stickinessViolated;
    /// @notice Double payout violated.
    /// @return doublePayoutViolated Stored double payout violated value.

    bool public doublePayoutViolated;
    /// @notice Ghost observations.
    /// @return ghostObservations Stored ghost observations value.

    uint64 public ghostObservations;
    /// @notice Ghost registrations.
    /// @return ghostRegistrations Stored ghost registrations value.

    uint64 public ghostRegistrations;
    /// @notice Ghost warps.
    /// @return ghostWarps Stored ghost warps value.

    uint64 public ghostWarps;

    /// @param settler_ settler_.
    constructor(PartialSettler settler_) {
        settlerRef = settler_;
    }

    /// @notice handler action: register tuple.
    /// @param orderIdSeed Fuzz seed used to pick an order id from a bounded set.
    /// @param fillerSeed Fuzz seed used to pick a filler from a bounded set.
    function registerTuple(bytes32 orderIdSeed, address fillerSeed) external {
        bytes32 k = keccak256(abi.encode(orderIdSeed, fillerSeed));
        if (observed[k]) {
            return;
        }
        observed[k] = true;
        observedKeys.push(k);
        keyToOrderId[k] = orderIdSeed;
        keyToFiller[k] = fillerSeed;
        if (settlerRef.fillerSlotAccountingOf(
                orderIdSeed, fillerSeed, bytes32(uint256(uint160(fillerSeed)))
            )
            .settled) {
            everSettled[k] = true;
        }
        ghostRegistrations++;
    }

    /// @notice handler action: observe tuple.
    /// @param indexSeed Fuzz seed used to pick an index from a bounded set.
    function observeTuple(uint256 indexSeed) external {
        uint256 n = observedKeys.length;
        if (n == 0) {
            return;
        }
        bytes32 k = observedKeys[bound(indexSeed, 0, n - 1)];
        bool current =
            settlerRef.fillerSlotAccountingOf(
            keyToOrderId[k], keyToFiller[k], bytes32(uint256(uint160(keyToFiller[k])))
        )
        .settled;
        if (everSettled[k] && !current) {
            stickinessViolated = true;
        } else if (current) {
            everSettled[k] = true;
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

    /// @notice handler action: observed count.
    /// @return Return value.
    function observedCount() external view returns (uint256) {
        return observedKeys.length;
    }
}
