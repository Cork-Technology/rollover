// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { ICorkRolloverContract } from "src/interfaces/rollover/ICorkRolloverContract.sol";

/// @title IRolloverContractLens
/// @notice Factory read-through lens for factory-deployed rolloverContract state and configuration.
interface IRolloverContractLens {
    /// @notice Factory-verified rolloverContract identity and live trust configuration.
    /// @dev Combines CWIA immutable args (`owner`, `factory`, `erc7484Registry`) with the
    ///      rolloverContract's live trust storage (`liveTrustThreshold`, `liveTrustAttesters`). Pending
    ///      trust config is held on the factory; read it via
    ///      `ICorkRolloverContractFactory.pendingTrustConfig(rolloverContract)`.
    /// @param owner cPT holder owner baked into the rolloverContract clone.
    /// @param factory Factory address baked into the rolloverContract clone.
    /// @param erc7484Registry ERC-7484 registry baked into the rolloverContract clone.
    /// @param liveTrustThreshold Active trust threshold currently applied to module checks.
    /// @param liveTrustAttesters Active trust attester set currently applied to module checks.
    struct RolloverContractConfig {
        address owner;
        address factory;
        address erc7484Registry;
        uint8 liveTrustThreshold;
        address[] liveTrustAttesters;
    }

    /// @notice Read rolloverContract-local rollover state for a factory-deployed rolloverContract.
    /// @dev Reverts if `rolloverContract` was not deployed by this factory. Returns the rolloverContract's local
    ///      accumulator and terminal bit for `orderDigest`. This is not Settler lifecycle status.
    ///      Unseen orders return the zero/default state.
    /// @custom:invariant N-INV-ROLLED-MONOTONE-AND-BOUNDED — exposes the rolloverContract-local rolled
    ///                   accumulator and terminal bit.
    /// @param rolloverContract Factory-deployed rolloverContract address.
    /// @param orderDigest Canonical order digest used as the rolloverContract-local state key.
    /// @return state RolloverContract-local rollover state.
    function orderState(address rolloverContract, bytes32 orderDigest)
        external
        view
        returns (ICorkRolloverContract.RolloverContractOrderState memory state);

    /// @notice Read the rolloverContract-local premium replay latch through the factory lens.
    /// @dev Reverts if `rolloverContract` was not deployed by this factory. This is local rolloverContract replay
    ///      state keyed by `(orderDigest, filler, subFiller)`, not Settler-side premium
    ///      accounting or claimability state.
    /// @custom:invariant M-11 — exposes the rolloverContract-local premium replay latch for off-chain
    ///                   observability.
    /// @param rolloverContract Factory-deployed rolloverContract address.
    /// @param orderDigest Canonical order digest.
    /// @param filler Filler address.
    /// @param subFiller Resolved sub-filler identity; use the post-auth resolved key, not raw
    ///        wire zero, when indexing direct fills.
    /// @return fired True if the rolloverContract-local premium latch is set.
    function premiumFiredFor(
        address rolloverContract,
        bytes32 orderDigest,
        address filler,
        bytes32 subFiller
    ) external view returns (bool fired);

    /// @notice Read factory-verified rolloverContract identity and live trust configuration.
    /// @dev Reverts if `rolloverContract` was not deployed by this factory. The returned snapshot combines
    ///      CWIA immutable args (`owner`, `factory`, `erc7484Registry`) with current live trust
    ///      storage (`liveTrustThreshold`, `liveTrustAttesters`). Pending trust config remains on
    ///      `ICorkRolloverContractFactory.pendingTrustConfig(rolloverContract)`.
    /// @param rolloverContract Factory-deployed rolloverContract address.
    /// @return config Factory-verified rolloverContract identity and live trust snapshot.
    function rolloverContractConfig(address rolloverContract)
        external
        view
        returns (RolloverContractConfig memory config);
}
