// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {
    CorkRolloverContractFactory__AlreadyDeployed
} from "src/errors/CorkRolloverContractFactoryErrors.sol";

import { CommonBase } from "forge-std/Base.sol";
import { StdCheats } from "forge-std/StdCheats.sol";
import { StdUtils } from "forge-std/StdUtils.sol";

import { CorkRolloverContractFactory } from "src/CorkRolloverContractFactory.sol";

/// @notice N-INV-ROLLOVER-CONTRACT-OF-IMMUTABLE-AFTER-SET handler — random-actor driver
///         over `CorkRolloverContractFactory.deployRolloverContract`. Caches the first observed
///         non-zero `rolloverContractOf[user]` value per user and asserts (a) the slot
///         never rotates to a different non-zero value across subsequent
///         blocks / handler steps, (b) the slot never drops back to zero,
///         (c) a re-attempt of `deployRolloverContract` for an already-bound user
///         reverts with `CorkRolloverContractFactory__AlreadyDeployed`, and (d) the
///         corollary `isDeployedRolloverContract[rolloverContract]` mirror stays true.
/// @custom:invariant N-INV-ROLLOVER-CONTRACT-OF-IMMUTABLE-AFTER-SET
contract FactoryRolloverContractOfHandler is CommonBase, StdCheats, StdUtils {
    /// @notice Factory under observation.
    /// @return factoryRef Stored factory ref.
    CorkRolloverContractFactory public immutable factoryRef;

    /// @notice Registered (pranked) actors that have attempted `deployRolloverContract`.
    /// @return actors Stored actor array.
    address[] public actors;
    /// @notice Whether an actor has been registered.
    /// @return registered True if actor is in `actors`.
    mapping(address => bool) public registered;

    /// @notice First observed non-zero rolloverContract per actor (set-once ghost).
    /// @return firstSeenRolloverContract Stored first non-zero rolloverContract address.
    mapping(address => address) public firstSeenRolloverContract;
    /// @notice Whether a non-zero rolloverContract has been observed for this actor.
    /// @return everNonZero True once a non-zero observation has been recorded.
    mapping(address => bool) public everNonZero;

    /// @notice Set-once / non-zero / corollary violation flag.
    /// @return violated True if any invariant arm has been falsified.
    bool public violated;

    /// @notice Ghost: number of successful first-time `deployRolloverContract` calls.
    /// @return ghostDeploys Stored counter.
    uint64 public ghostDeploys;
    /// @notice Ghost: number of `deployRolloverContract` re-attempts that correctly reverted.
    /// @return ghostRedeployReverts Stored counter.
    uint64 public ghostRedeployReverts;
    /// @notice Ghost: number of observe calls performed.
    /// @return ghostObservations Stored counter.
    uint64 public ghostObservations;
    /// @notice Ghost: number of warp calls performed.
    /// @return ghostWarps Stored counter.
    uint64 public ghostWarps;

    /// @param factory_ Factory under observation.
    constructor(CorkRolloverContractFactory factory_) {
        factoryRef = factory_;
    }

    /// @notice handler action: deploy a rolloverContract for a fresh actor derived from
    ///         the fuzz seed. Registers the actor and captures the first
    ///         non-zero `rolloverContractOf` observation. If the derived actor is
    ///         already bound, this is a no-op (the bound-actor path is
    ///         exercised by `deployRolloverContractForBoundActor`).
    /// @param actorSeed Fuzz seed used to derive the actor address.
    function deployRolloverContractForNewActor(uint256 actorSeed) external {
        address actor = _deriveActor(actorSeed);
        if (factoryRef.rolloverContractOf(actor) != address(0)) {
            // Already-bound actor — observe the slot but do not attempt to
            // re-deploy here (the bound-actor branch covers that).
            _captureObservation(actor);
            return;
        }
        if (!registered[actor]) {
            registered[actor] = true;
            actors.push(actor);
        }
        vm.prank(actor);
        address rolloverContract = factoryRef.deployRolloverContract();
        _captureObservation(actor);
        // Corollary: the value returned from deployRolloverContract matches the freshly
        // cached firstSeen, and isDeployedRolloverContract mirror is true.
        if (
            rolloverContract != firstSeenRolloverContract[actor]
                || !factoryRef.isDeployedRolloverContract(rolloverContract)
        ) {
            violated = true;
        }
        ghostDeploys++;
    }

    /// @notice handler action: re-attempt `deployRolloverContract` for a previously
    ///         bound actor. Expects revert with `__AlreadyDeployed`. Flags
    ///         `violated` if the call unexpectedly succeeds.
    /// @param indexSeed Fuzz seed used to pick a previously-registered actor.
    function deployRolloverContractForBoundActor(uint256 indexSeed) external {
        uint256 n = actors.length;
        if (n == 0) {
            return;
        }
        address actor = actors[bound(indexSeed, 0, n - 1)];
        if (factoryRef.rolloverContractOf(actor) == address(0)) {
            return;
        }
        vm.prank(actor);
        try factoryRef.deployRolloverContract() returns (address) {
            // Re-deploy succeeded — set-once invariant falsified.
            violated = true;
        } catch (bytes memory reason) {
            // Expected: revert with CorkRolloverContractFactory__AlreadyDeployed.
            // forge-lint: disable-next-line(unsafe-typecast)
            if (bytes4(reason) != CorkRolloverContractFactory__AlreadyDeployed.selector) {
                violated = true;
            } else {
                ghostRedeployReverts++;
            }
        }
        _captureObservation(actor);
    }

    /// @notice handler action: observe `rolloverContractOf[actor]` for a registered
    ///         actor without mutating state. Catches any slot rotation that
    ///         would happen via a future external write path.
    /// @param indexSeed Fuzz seed used to pick a registered actor.
    function observeActor(uint256 indexSeed) external {
        uint256 n = actors.length;
        if (n == 0) {
            return;
        }
        address actor = actors[bound(indexSeed, 0, n - 1)];
        _captureObservation(actor);
        ghostObservations++;
    }

    /// @notice handler action: warp time forward to expose any time-dependent
    ///         rewrites to the slot.
    /// @param delta Fuzz seed for warp delta (bounded to 1 hour).
    function warpForward(uint64 delta) external {
        uint64 d = uint64(bound(delta, 0, 1 hours));
        vm.warp(block.timestamp + d);
        ghostWarps++;
    }

    /// @notice Reads `rolloverContractOf[actor]` and updates the set-once ghost state.
    ///         Marks `violated = true` if the slot has either rotated to a
    ///         different non-zero value or dropped back to zero after a
    ///         prior non-zero observation, or if the `isDeployedRolloverContract`
    ///         mirror has been cleared.
    /// @param actor Registered actor address.
    function _captureObservation(address actor) internal {
        address current = factoryRef.rolloverContractOf(actor);
        if (everNonZero[actor]) {
            if (current == address(0)) {
                violated = true;
            } else if (current != firstSeenRolloverContract[actor]) {
                violated = true;
            } else if (!factoryRef.isDeployedRolloverContract(current)) {
                violated = true;
            }
        } else if (current != address(0)) {
            firstSeenRolloverContract[actor] = current;
            everNonZero[actor] = true;
        }
    }

    /// @notice Derives a deterministic non-zero EOA address from the fuzz seed.
    /// @param actorSeed Fuzz seed.
    /// @return actor Derived address (never `address(0)`).
    function _deriveActor(uint256 actorSeed) internal pure returns (address actor) {
        // Map the seed into an address; OR with 1 to guarantee non-zero.
        actor = address(uint160(uint256(keccak256(abi.encode("actor", actorSeed))) | 1));
    }

    /// @notice handler view: number of registered actors.
    /// @return Length of `actors`.
    function actorCount() external view returns (uint256) {
        return actors.length;
    }
}
