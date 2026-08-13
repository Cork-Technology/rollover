// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

/// @notice Reverts when the caller passes the zero address as the Settler.
error BaseFiller__UnknownSettler();

/// @notice Reverts when an immutable Settler argument is zero at deployment.
error BaseFiller__ZeroSettler();

/// @notice Reverts when the job's `settler` does not equal the immutable `SETTLER`.
/// @param expected Expected Settler (`SETTLER`).
/// @param actual Settler supplied in the job.
error BaseFiller__SettlerMismatch(address expected, address actual);

/// @notice Reverts when a job carries a market instruction but this filler was deployed
///         without the market-creation wiring.
error BaseFiller__JitNotConfigured();

/// @notice Reverts when the registry's maximum-expiry-duration getter reverts or returns malformed
///         data, because a missing pool cannot be created without a trustworthy current bound.
error BaseFiller__MaxExpiryDurationUnavailable();

/// @notice Reverts when the registry reports a zero maximum expiry duration for a missing pool.
error BaseFiller__ZeroMaxExpiryDuration();

/// @notice Reverts when a missing pool's expiry is farther in the future than the registry permits.
/// @param expiryTimestamp Requested market expiry, in unix seconds.
/// @param currentTimestamp Timestamp at which the creation bound was evaluated, in unix seconds.
/// @param maxExpiryDuration Maximum permitted duration from `currentTimestamp`, in seconds.
error BaseFiller__ExpiryExceedsMaxDuration(
    uint256 expiryTimestamp, uint256 currentTimestamp, uint256 maxExpiryDuration
);

/// @notice Reverts when the rate oracle reports zero at the moment the pool would be created.
error BaseFiller__RateUnavailable();

/// @notice Reverts when a non-FIXED recipe is handed a rate override it would never read.
/// @param recipe Recipe that takes no override.
error BaseFiller__UnexpectedRateOverride(address recipe);

/// @notice Reverts when the recipe rejects the constraint the order carries.
/// @param recipe Recipe that rejected the constraint.
error BaseFiller__RecipeRejectedConstraint(address recipe);

/// @notice Reverts when the market assembled from the job does not hash to the signed destination
///         pool id.
/// @param expected Signed `rolloverParams.dstPoolId`.
/// @param derived Pool id derived from the job's market instruction.
error BaseFiller__JitPoolMismatch(bytes32 expected, bytes32 derived);

/// @notice Reverts when the supplied JIT instruction differs from the cPT-holder-signed commitment.
/// @param expected Commitment carried by the signed order.
/// @param actual Commitment derived from the supplied JIT instruction.
error BaseFiller__JitMarketHashMismatch(bytes32 expected, bytes32 actual);
