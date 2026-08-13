// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {
    IMarketRecipe,
    RecipeSource
} from "src/interfaces/external/market-registry/IMarketRecipe.sol";
import { IMarketRegistry } from "src/interfaces/external/market-registry/IMarketRegistry.sol";
import { IRateOracle } from "src/interfaces/external/market-registry/IRateOracle.sol";

/// @notice Mock rate oracle with a settable rate, so tests can drive the "oracle reports nothing"
///         branch of just-in-time market creation.
contract MockRateOracle is IRateOracle {
    /// @notice Rate currently returned by this oracle.
    uint256 internal _rate;

    /// @param rate_ Initial rate, scaled to 1e18.
    constructor(uint256 rate_) {
        _rate = rate_;
    }

    /// @notice Set the rate this oracle reports.
    /// @param rate_ New rate, scaled to 1e18.
    function setRate(uint256 rate_) external {
        _rate = rate_;
    }

    /// @notice Current rate.
    /// @return The rate, scaled to 1e18.
    function rate() external view returns (uint256) {
        return _rate;
    }
}

/// @notice Mock market recipe with knobs for the rate kind it declares and whether it stands
///         behind the constraint it is handed.
/// @dev `verify` is `view` in the interface, so the recipe cannot record what it was called with.
///      `requiredOracle` and `requiredAdditionalData` invert that: the test pins what it expects
///      the filler to pass and reads the answer back through the accept/reject result.
contract MockMarketRecipe is IMarketRecipe {
    /// @notice Rate kind this recipe declares.
    /// @return source Stored rate kind.
    RecipeSource public source;

    /// @notice Whether the recipe stands behind constraints at all.
    /// @return accept Stored accept flag.
    bool public accept = true;

    /// @notice When non-zero, only this oracle address is accepted.
    /// @return requiredOracle Stored required-oracle value.
    address public requiredOracle;

    /// @notice When set, only additional data hashing to this value is accepted.
    /// @return requiredAdditionalDataHash Stored required additional-data hash.
    bytes32 public requiredAdditionalDataHash;

    /// @notice When non-zero, only this collateral asset is accepted.
    /// @return requiredCollateralAsset Stored required collateral asset.
    address public requiredCollateralAsset;

    /// @notice When non-zero, only this reference asset is accepted.
    /// @return requiredReferenceAsset Stored required reference asset.
    address public requiredReferenceAsset;

    /// @notice When non-zero, only a constraint carrying this lower rate limit is accepted.
    /// @return requiredRateMin Stored required lower rate limit.
    uint256 public requiredRateMin;

    /// @param source_ Rate kind this recipe declares.
    constructor(RecipeSource source_) {
        source = source_;
    }

    /// @notice Set whether this recipe accepts constraints.
    /// @param accept_ New accept flag.
    function setAccept(bool accept_) external {
        accept = accept_;
    }

    /// @notice Pin the oracle address this recipe expects to be handed.
    /// @param oracle Oracle address, or zero to stop checking.
    function setRequiredOracle(address oracle) external {
        requiredOracle = oracle;
    }

    /// @notice Pin the additional data this recipe expects to be handed.
    /// @param additionalData Expected bytes; empty stops checking.
    function setRequiredAdditionalData(bytes calldata additionalData) external {
        requiredAdditionalDataHash =
            additionalData.length == 0 ? bytes32(0) : keccak256(additionalData);
    }

    /// @notice Pin the assets this recipe expects to be handed.
    /// @param ca Expected collateral asset; zero stops checking.
    /// @param ref Expected reference asset; zero stops checking.
    function setRequiredAssets(address ca, address ref) external {
        requiredCollateralAsset = ca;
        requiredReferenceAsset = ref;
    }

    /// @notice Pin the lower rate limit this recipe expects the constraint to carry.
    /// @param rateMin Expected lower rate limit; zero stops checking.
    function setRequiredRateMin(uint256 rateMin) external {
        requiredRateMin = rateMin;
    }

    /// @notice Check a submitted constraint.
    /// @param ca Collateral asset.
    /// @param ref Reference asset.
    /// @param rateOracle Live rate oracle the caller produced.
    /// @param constraint Constraint the order carries.
    /// @param additionalData Recipe-specific bytes carried in the order.
    /// @return True when the recipe accepts.
    function verify(
        address ca,
        address ref,
        address rateOracle,
        IMarketRegistry.ResolvedConstraint calldata constraint,
        bytes calldata additionalData
    ) external view returns (bool) {
        if (!accept) {
            return false;
        }
        if (requiredOracle != address(0) && rateOracle != requiredOracle) {
            return false;
        }
        if (requiredCollateralAsset != address(0) && ca != requiredCollateralAsset) {
            return false;
        }
        if (requiredReferenceAsset != address(0) && ref != requiredReferenceAsset) {
            return false;
        }
        if (requiredRateMin != 0 && constraint.rateMin != requiredRateMin) {
            return false;
        }
        if (
            requiredAdditionalDataHash != bytes32(0)
                && keccak256(additionalData) != requiredAdditionalDataHash
        ) {
            return false;
        }
        return true;
    }
}

/// @notice Mock market registry holding the approved-recipe set and handing back oracles the test
///         pre-registered.
/// @dev Oracles are pre-registered rather than deployed on demand so the pool id — which hashes the
///      oracle address — is computable in the test before the fill runs.
contract MockMarketRegistry is IMarketRegistry {
    /// @notice Reverts when a test drives an oracle path it never registered an oracle for.
    error MockMarketRegistry__OracleNotPreset();

    /// @notice Reverts when the maximum-expiry getter is configured to fail.
    error MockMarketRegistry__MaxExpiryDurationUnavailable();

    /// @notice Response behavior exposed by the maximum-expiry-duration getter.
    enum MaxExpiryDurationResponse {
        Value,
        Revert,
        Malformed
    }

    /// @notice Number of pair-oracle deployments requested.
    /// @return deployCallCount Stored pair-oracle call count.
    uint256 public deployCallCount;

    /// @notice Number of fixed-rate-oracle deployments requested.
    /// @return deployFixedCallCount Stored fixed-oracle call count.
    uint256 public deployFixedCallCount;

    /// @notice Maximum duration a newly created market may run.
    uint256 internal _maxExpiryDuration = type(uint256).max;

    /// @notice Response behavior of `maxExpiryDuration`.
    /// @return maxExpiryDurationResponse Stored response behavior.
    MaxExpiryDurationResponse public maxExpiryDurationResponse;

    /// @notice Oracle mode of the most recent pair-oracle deployment.
    /// @return lastMode Stored oracle mode.
    OracleMode public lastMode;

    /// @notice Collateral asset of the most recent pair-oracle deployment.
    /// @return lastCollateralAsset Stored collateral asset.
    address public lastCollateralAsset;

    /// @notice Reference asset of the most recent pair-oracle deployment.
    /// @return lastReferenceAsset Stored reference asset.
    address public lastReferenceAsset;

    /// @notice Rate of the most recent fixed-rate-oracle deployment.
    /// @return lastFixedRate Stored fixed rate.
    uint256 public lastFixedRate;

    /// @notice Approved recipe status keyed by recipe address.
    mapping(address recipe => bool registered) internal _recipes;
    /// @notice Pair-oracle addresses keyed by collateral and reference asset pair.
    mapping(bytes32 pairKey => address oracle) internal _pairOracles;
    /// @notice Fixed-rate oracle addresses keyed by rate.
    mapping(uint256 rate => address oracle) internal _fixedOracles;

    /// @notice Set the maximum duration a newly created market may run.
    /// @param duration New duration, in seconds.
    function setMaxExpiryDuration(uint256 duration) external {
        _maxExpiryDuration = duration;
    }

    /// @notice Set the response behavior of `maxExpiryDuration`.
    /// @param response New response behavior.
    function setMaxExpiryDurationResponse(MaxExpiryDurationResponse response) external {
        maxExpiryDurationResponse = response;
    }

    /// @notice Add or remove a recipe from the approved set.
    /// @param recipe Recipe address.
    /// @param registered Whether the recipe is approved.
    function setRecipe(address recipe, bool registered) external {
        _recipes[recipe] = registered;
    }

    /// @notice Pre-register the oracle a pair deployment returns.
    /// @param ca Collateral asset.
    /// @param ref Reference asset.
    /// @param mode Oracle mode.
    /// @param oracle Oracle address to return.
    function setPairOracle(address ca, address ref, OracleMode mode, address oracle) external {
        _pairOracles[_pairKey(ca, ref, mode)] = oracle;
    }

    /// @notice Pre-register the oracle a fixed-rate deployment returns.
    /// @param rate The fixed rate, scaled to 1e18.
    /// @param oracle Oracle address to return.
    function setFixedOracle(uint256 rate, address oracle) external {
        _fixedOracles[rate] = oracle;
    }

    /// @notice Deploy (or return) the rate oracle for a pair.
    /// @param ca Collateral asset.
    /// @param ref Reference asset.
    /// @param mode Oracle mode.
    /// @return wrapper The rate oracle address.
    function deploy(address ca, address ref, OracleMode mode) external returns (address wrapper) {
        ++deployCallCount;
        lastCollateralAsset = ca;
        lastReferenceAsset = ref;
        lastMode = mode;
        wrapper = _pairOracles[_pairKey(ca, ref, mode)];
        if (wrapper == address(0)) {
            revert MockMarketRegistry__OracleNotPreset();
        }
    }

    /// @notice Deploy (or return) the fixed-rate oracle for `rate`.
    /// @param rate The fixed rate, scaled to 1e18.
    /// @return oracle The fixed-rate oracle address.
    function deployFixedRateOracle(uint256 rate) external returns (address oracle) {
        ++deployFixedCallCount;
        lastFixedRate = rate;
        oracle = _fixedOracles[rate];
        if (oracle == address(0)) {
            revert MockMarketRegistry__OracleNotPreset();
        }
    }

    /// @notice Return the configured maximum market expiry duration.
    /// @dev The failure modes let callers prove they reject reverting and malformed responses.
    /// @return duration Maximum duration, in seconds.
    function maxExpiryDuration() external view returns (uint256 duration) {
        MaxExpiryDurationResponse response = maxExpiryDurationResponse;
        if (response == MaxExpiryDurationResponse.Revert) {
            revert MockMarketRegistry__MaxExpiryDurationUnavailable();
        }
        if (response == MaxExpiryDurationResponse.Malformed) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        return _maxExpiryDuration;
    }

    /// @notice Whether an address is an approved recipe.
    /// @param recipe The address to test.
    /// @return True when registered.
    function isRecipe(address recipe) external view returns (bool) {
        return _recipes[recipe];
    }

    function _pairKey(address ca, address ref, OracleMode mode) internal pure returns (bytes32) {
        return keccak256(abi.encode(ca, ref, mode));
    }
}
