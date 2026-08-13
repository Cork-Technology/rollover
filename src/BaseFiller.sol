// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    ReentrancyGuardTransient
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {
    BaseFiller__ExpiryExceedsMaxDuration,
    BaseFiller__JitMarketHashMismatch,
    BaseFiller__JitNotConfigured,
    BaseFiller__JitPoolMismatch,
    BaseFiller__MaxExpiryDurationUnavailable,
    BaseFiller__RateUnavailable,
    BaseFiller__RecipeRejectedConstraint,
    BaseFiller__SettlerMismatch,
    BaseFiller__UnexpectedRateOverride,
    BaseFiller__UnknownSettler,
    BaseFiller__ZeroMaxExpiryDuration,
    BaseFiller__ZeroSettler
} from "src/errors/BaseFillerErrors.sol";
import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import {
    IMarketRecipe,
    RecipeSource
} from "src/interfaces/external/market-registry/IMarketRecipe.sol";
import { IMarketRegistry } from "src/interfaces/external/market-registry/IMarketRegistry.sol";
import { IRateOracle } from "src/interfaces/external/market-registry/IRateOracle.sol";
import { IDefaultCorkController } from "src/interfaces/external/phoenix/IDefaultCorkController.sol";
import { IPoolManager, Market, MarketId } from "src/interfaces/external/phoenix/IPoolManager.sol";
import { ISettler } from "src/interfaces/settlers/ISettler.sol";
import { LibFillerPayload } from "src/libraries/LibFillerPayload.sol";
import { LibRolloverOrder } from "src/libraries/LibRolloverOrder.sol";
import { LibSettlerHashing } from "src/libraries/LibSettlerHashing.sol";
import { Typehashes } from "src/libraries/Typehashes.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @title BaseFiller
/// @notice Reference filler that wraps exact and partial orders through openFor → ROLLOVER →
///         PREMIUM → settle. Pre-funds itself from the caller, computes the required premium from
///         observed dstCST production at the M-08 ceil-rounded floor, and refunds any premium-cap
///         surplus before returning.
/// @custom:security-contact security@cork.tech
contract BaseFiller is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice Immutable exact-mode Settler this filler is bound to.
    /// @return EXACT_SETTLER Stored exact settler value.
    ISettler public immutable EXACT_SETTLER;

    /// @notice Immutable partial-mode Settler this filler is bound to.
    /// @return PARTIAL_SETTLER Stored partial settler value.
    ISettler public immutable PARTIAL_SETTLER;

    /// @notice Phoenix pool manager the destination market is checked for existence against.
    /// @return POOL_MANAGER Stored pool manager value.
    IPoolManager public immutable POOL_MANAGER;

    /// @notice Phoenix controller destination pools are created through. This filler must hold its
    ///         `POOL_CREATOR_ROLE` for market creation to be usable.
    /// @return CONTROLLER Stored controller value.
    IDefaultCorkController public immutable CONTROLLER;

    /// @notice Cork market registry holding the approved-recipe set and the oracle deployers.
    /// @return MARKET_REGISTRY Stored registry value.
    IMarketRegistry public immutable MARKET_REGISTRY;

    /// @notice Market instruction a job carries when the destination pool may not exist yet.
    /// @dev The order separately signs both `rolloverParams.dstPoolId`, which commits to the
    ///      Phoenix `Market`, and `rolloverParams.jitMarketHash`, which commits to every field
    ///      below including the negotiated fees.
    /// @param collateralAsset Pool collateral asset.
    /// @param referenceAsset Pool reference asset.
    /// @param expiryTimestamp Pool expiry, unix seconds; must outlast the order's fill deadline.
    /// @param recipe Approved `IMarketRecipe` contract; an unregistered address is rejected, so
    ///        there is no unverified path.
    /// @param rateOverride FIXED recipes only: the rate the fixed-rate oracle is deployed at.
    /// @param constraint The four rate limits, derived off-chain at order-signing time.
    /// @param additionalData Recipe-specific bytes `verify` reads.
    /// @param swapFeePercentage Negotiated swap fee, 18 decimals (1% = 1e18).
    /// @param unwindSwapFeePercentage Negotiated unwind fee, 18 decimals (1% = 1e18).
    struct JITMarketParams {
        address collateralAsset;
        address referenceAsset;
        uint256 expiryTimestamp;
        address recipe;
        uint256 rateOverride;
        IMarketRegistry.ResolvedConstraint constraint;
        bytes additionalData;
        uint256 swapFeePercentage;
        uint256 unwindSwapFeePercentage;
    }

    /// @notice Caller-supplied job description for a single rollover execution.
    /// @param settler Expected Settler address (must equal `SETTLER`).
    /// @param order ERC-7683 gasless cross-chain order envelope.
    /// @param userSig cPT-holder signature.
    /// @param srcCst Source CST ERC-20.
    /// @param premiumToken Premium-token ERC-20.
    /// @param fillerSrcCst srcCST amount this job provides.
    /// @param intent `RolloverIntent` payload committed by the cPT-holder-signed order.
    /// @param premiumCap Maximum premium the caller is willing to pay.
    /// @param minDstPerSrc dstCST-per-srcCST floor (INV-DSTCST-FLOOR; 0 = opt out). The on-chain
    ///        check is `dstProduced >= floor(srcConsumed × minDstPerSrc / 1e18)`; per-fill drift
    ///        bounded at 1 wei dstCST in the filler's favour when the product is not divisible
    ///        by 1e18 (phoenix-convention Floor rounding, OZ Math.Rounding.Floor).
    /// @param fillerAuthSig Optional exclusive-filler signature (INV-FILLER-AUTH).
    struct FillerJob {
        ISettler settler;
        ERC7683Types.GaslessCrossChainOrder order;
        bytes userSig;
        IERC20 srcCst;
        IERC20 premiumToken;
        uint256 fillerSrcCst;
        RolloverTypes.RolloverIntent intent;
        uint256 premiumCap;
        uint256 minDstPerSrc;

        bytes fillerAuthSig;
    }

    /// @notice Emitted when surplus premium is refunded to the caller after settle.
    /// @param orderDigest Canonical order digest.
    /// @param filler Filler address (`msg.sender`).
    /// @param premiumToken Premium token refunded.
    /// @param amount Refund amount.
    event PremiumRefunded(
        bytes32 indexed orderDigest,
        address indexed filler,
        address indexed premiumToken,
        uint256 amount
    );

    /// @notice Emitted when a fill created the destination pool it was rolling into.
    /// @param poolId Pool id created by this fill.
    /// @param rateOracle Oracle the pool adopted.
    /// @param recipe Recipe that verified the carried constraint.
    event JITMarketCreated(bytes32 indexed poolId, address indexed rateOracle, address recipe);

    /// @notice Bind this filler to exact- and partial-mode Settlers at deployment time.
    /// @dev The three market-creation addresses may all be zero, which leaves this filler on the
    ///      existing-market path only; a job carrying a market instruction then reverts.
    /// @param exactSettler_ Exact-mode Settler address.
    /// @param partialSettler_ Partial-mode Settler address.
    /// @param poolManager_ Phoenix pool manager.
    /// @param controller_ Phoenix controller pools are created through.
    /// @param marketRegistry_ Cork market registry.
    /// @dev Fee policy is negotiated per order and authenticated by the signed JIT commitment.
    constructor(
        ISettler exactSettler_,
        ISettler partialSettler_,
        IPoolManager poolManager_,
        IDefaultCorkController controller_,
        IMarketRegistry marketRegistry_
    ) {
        if (address(exactSettler_) == address(0)) {
            revert BaseFiller__ZeroSettler();
        }
        if (address(partialSettler_) == address(0)) {
            revert BaseFiller__ZeroSettler();
        }
        EXACT_SETTLER = exactSettler_;
        PARTIAL_SETTLER = partialSettler_;
        POOL_MANAGER = poolManager_;
        CONTROLLER = controller_;
        MARKET_REGISTRY = marketRegistry_;
    }

    /// @notice Execute one filler job.
    /// @dev Settler `fill` settles in-frame after premium succeeds. Exact mode terminally settles
    ///      the order; partial mode settles this filler residual only and leaves order-level
    ///      partial state non-terminal.
    /// @custom:invariant INV-SUBFILLER-PROVENANCE — `subFiller` is derived from `msg.sender`
    ///                   and never accepted from caller-supplied input.
    /// @custom:invariant N-INV-HELPER-FUNDING-RESTORES-SNAPSHOTS
    /// @param job Job descriptor.
    function execute(FillerJob calldata job) external nonReentrant {
        _execute(job);
    }

    /// @notice Execute one filler job whose destination pool may not exist yet, creating it first.
    /// @dev Creation must happen before `fill` is entered: the Settler rejects an order whose
    ///      destination CST is not canonical, and the rollover contract resolves the destination
    ///      market before the earliest hook runs, so no hook slot is early enough to do this.
    /// @param job Job descriptor.
    /// @param jitMarket Destination-market instruction; must match both signed market commitments.
    function executeWithMarket(FillerJob calldata job, JITMarketParams calldata jitMarket)
        external
        nonReentrant
    {
        RolloverTypes.OrderData memory orderData = LibRolloverOrder.decodeOrderData(job.order);
        _ensureMarket(
            jitMarket, orderData.rolloverParams.dstPoolId, orderData.rolloverParams.jitMarketHash
        );
        _execute(job);
    }

    /// @notice Hash a complete negotiated JIT market instruction for inclusion in signed order data.
    /// @param params Complete negotiated market instruction.
    /// @return commitment Hash embedded in `RolloverParams.jitMarketHash`.
    function hashJITMarketParams(JITMarketParams calldata params)
        public
        pure
        returns (bytes32 commitment)
    {
        return keccak256(
            abi.encode(
                Typehashes.JIT_MARKET_PARAMS_TYPEHASH,
                params.collateralAsset,
                params.referenceAsset,
                params.expiryTimestamp,
                params.recipe,
                params.rateOverride,
                params.constraint.rateMin,
                params.constraint.rateMax,
                params.constraint.rateChangePerDayMax,
                params.constraint.rateChangeCapacityMax,
                keccak256(params.additionalData),
                params.swapFeePercentage,
                params.unwindSwapFeePercentage
            )
        );
    }

    function _execute(FillerJob calldata job) private {
        bytes32 subFiller = bytes32(uint256(uint160(msg.sender)));
        RolloverTypes.OrderData memory orderData = LibRolloverOrder.decodeOrderData(job.order);
        ISettler settler = _settlerFor(orderData);
        _assertExpectedSettler(settler, job.settler);

        uint256 preBal = job.srcCst.balanceOf(address(this));
        uint256 premiumPreBal = job.premiumToken.balanceOf(address(this));
        job.srcCst.safeTransferFrom(msg.sender, address(this), job.fillerSrcCst);
        job.premiumToken.safeTransferFrom(msg.sender, address(this), job.premiumCap);

        bytes32 orderDigest = _runSettlement(job, settler, orderData, subFiller);

        uint256 postBal = job.srcCst.balanceOf(address(this));
        if (postBal > preBal) {
            job.srcCst.safeTransfer(msg.sender, postBal - preBal);
        }
        uint256 postPremiumBal = job.premiumToken.balanceOf(address(this));
        if (postPremiumBal > premiumPreBal) {
            uint256 refund = postPremiumBal - premiumPreBal;
            job.premiumToken.safeTransfer(msg.sender, refund);
            emit PremiumRefunded(orderDigest, msg.sender, address(job.premiumToken), refund);
        }
    }

    /// @dev Drive the Settler through openFor → atomic fill (admit → rollover → premium →
    ///      settle in one frame) and clear approvals at the end. Computes the canonical
    ///      orderId locally via `LibSettlerHashing.computeOrderDigestMemory` (no `resolve`
    ///      round-trip) and skips `openFor` when the cached order status is already
    ///      `Opened`. Settlement happens inside the atomic `fill` frame; there is no
    ///      second Settler call.
    /// @custom:invariant INV-OPENED-ORDERS-FILLABLE-UNTIL-FILLDEADLINE — helpers skip
    ///                   `openFor` on already-`Opened` orders and derive `orderId`
    ///                   locally without calling `resolve`, so a helper-driven fill
    ///                   past `openDeadline` succeeds on an Opened order.
    /// @custom:invariant INV-ATOMIC-FILL-CANONICAL — emits a single atomic-envelope
    ///                   `fillerData` (`ATOMIC_TAG`) per helper-driven fill; this
    ///                   dispatch path never emits async phase-only payloads.
    /// @custom:invariant INV-SUBFILLER-PROVENANCE
    function _runSettlement(
        FillerJob calldata job,
        ISettler settler,
        RolloverTypes.OrderData memory orderData,
        bytes32 subFiller
    ) internal returns (bytes32 orderDigest) {
        orderDigest = LibSettlerHashing.computeOrderDigestMemory(
            orderData, settler.DOMAIN_SEPARATOR()
        );
        if (settler.orderStatus(orderDigest) != RolloverTypes.OrderStatus.Opened) {
            settler.openFor(job.order, job.userSig, "");
        }

        bytes memory originData = abi.encode(job.order);

        _dispatchAtomicFill(job, settler, orderDigest, originData, subFiller);

        job.srcCst.forceApprove(address(settler), 0);
        job.premiumToken.forceApprove(address(settler), 0);
    }

    /// @dev Compose the atomic-fill envelope and dispatch a single `settler.fill` call.
    ///      Approves srcCST at `fillerSrcCst` and premiumToken at `premiumCap` upfront —
    ///      the Settler recomputes the exact required premium from observed dstCST
    ///      production and pulls only that amount; the surplus stays with the filler and
    ///      is refunded by `execute` from the post-fill balance diff. The inner premium leg
    ///      carries only the intent; Settler derives subject, amount, and sub-filler from the
    ///      rollover leg before dispatch.
    /// @custom:invariant INV-ATOMIC-FILL-CANONICAL — helper dispatch uses one
    ///                   `ATOMIC_TAG` envelope per ERC-7683 `fill(...)` call.
    /// @custom:invariant INV-SUBFILLER-PROVENANCE — `subFiller` derived from `msg.sender`.
    function _dispatchAtomicFill(
        FillerJob calldata job,
        ISettler settler,
        bytes32 orderId,
        bytes memory originData,
        bytes32 subFiller
    ) private {
        job.srcCst.forceApprove(address(settler), job.fillerSrcCst);
        job.premiumToken.forceApprove(address(settler), job.premiumCap);

        bytes memory rolloverData = _buildRolloverInnerBlob(job, subFiller);

        // `job.userSig` is the cPT-holder EIP-712 sig over `orderDigest`; it lives in the
        // envelope's `cptHolderSig` slot so direct-fill admission (None → Opened) can
        // verify it per INV-DIRECT-FILL-CPT-HOLDER-SIG.
        bytes memory atomicFillerData =
            LibFillerPayload.encodeAtomicEnvelope(rolloverData, job.premiumCap, job.userSig);
        settler.fill(orderId, originData, atomicFillerData);
    }

    /// @dev Encodes the 10-tuple ROLLOVER inner-leg `FillerPayload` blob for the atomic
    ///      envelope. The nested `cptHolderSig` slot is left empty — the envelope-level
    ///      `cptHolderSig` carries the cPT-holder attestation under atomic-fill.
    function _buildRolloverInnerBlob(FillerJob calldata job, bytes32 subFiller)
        private
        view
        returns (bytes memory)
    {
        return LibFillerPayload.encodeRolloverLeg(
            job.fillerSrcCst,
            msg.sender,
            job.intent,
            job.minDstPerSrc,
            job.fillerAuthSig,
            subFiller,
            ""
        );
    }

    /// @dev Confirm the complete instruction matches the cPT-holder-signed JIT commitment,
    ///      assemble the destination market, confirm it hashes to the signed `dstPoolId`, and
    ///      create the pool when it does not exist yet. For an existing pool the commitment
    ///      authenticates the instruction but cannot restate already-fixed pool fees; those terms
    ///      govern creation only. The whitelist is disabled because Phoenix gates `deposit` on
    ///      the caller, which is the cPT holder's rollover contract.
    function _ensureMarket(
        JITMarketParams calldata params,
        bytes32 expectedPoolId,
        bytes32 expectedJitMarketHash
    ) private {
        if (address(CONTROLLER) == address(0) || address(MARKET_REGISTRY) == address(0)) {
            revert BaseFiller__JitNotConfigured();
        }

        bytes32 actualJitMarketHash = hashJITMarketParams(params);
        if (actualJitMarketHash != expectedJitMarketHash) {
            revert BaseFiller__JitMarketHashMismatch(expectedJitMarketHash, actualJitMarketHash);
        }

        address oracle = _resolveOracle(params);

        // Field order is load-bearing for the id hash.
        Market memory market = Market({
            collateralAsset: params.collateralAsset,
            referenceAsset: params.referenceAsset,
            expiryTimestamp: params.expiryTimestamp,
            rateMin: params.constraint.rateMin,
            rateMax: params.constraint.rateMax,
            rateChangePerDayMax: params.constraint.rateChangePerDayMax,
            rateChangeCapacityMax: params.constraint.rateChangeCapacityMax,
            rateOracle: oracle
        });
        bytes32 poolId = keccak256(abi.encode(market));
        if (poolId != expectedPoolId) {
            revert BaseFiller__JitPoolMismatch(expectedPoolId, poolId);
        }

        if (_poolExists(poolId)) {
            return;
        }

        _enforceMaxExpiryDuration(params.expiryTimestamp);

        // A pool is permanent, so refuse to anchor one to an oracle currently reporting nothing.
        if (IRateOracle(oracle).rate() == 0) {
            revert BaseFiller__RateUnavailable();
        }

        CONTROLLER.createNewPool(
            IDefaultCorkController.PoolCreationParams({
                pool: market,
                unwindSwapFeePercentage: params.unwindSwapFeePercentage,
                swapFeePercentage: params.swapFeePercentage,
                isWhitelistEnabled: false
            })
        );
        emit JITMarketCreated(poolId, oracle, params.recipe);
    }

    /// @dev Reads the current registry bound fail-closed and rejects a missing pool whose expiry
    ///      exceeds it. The guarded subtraction is equivalent to
    ///      `expiryTimestamp > block.timestamp + maxExpiryDuration` without overflowing the sum.
    ///      Exactly one ABI word is required so reverting and malformed registry implementations
    ///      are mapped to the same typed failure.
    /// @param expiryTimestamp Requested market expiry, in unix seconds.
    function _enforceMaxExpiryDuration(uint256 expiryTimestamp) private view {
        address registry = address(MARKET_REGISTRY);
        bytes4 selector = IMarketRegistry.maxExpiryDuration.selector;
        bool success;
        uint256 returnDataSize;
        uint256 maxExpiryDuration;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, selector)
            success := staticcall(gas(), registry, ptr, 4, ptr, 32)
            returnDataSize := returndatasize()
            maxExpiryDuration := mload(ptr)
        }
        if (!success || returnDataSize != 32) {
            revert BaseFiller__MaxExpiryDurationUnavailable();
        }
        if (maxExpiryDuration == 0) {
            revert BaseFiller__ZeroMaxExpiryDuration();
        }

        uint256 currentTimestamp = block.timestamp;
        if (
            expiryTimestamp > currentTimestamp
                && expiryTimestamp - currentTimestamp > maxExpiryDuration
        ) {
            revert BaseFiller__ExpiryExceedsMaxDuration(
                expiryTimestamp, currentTimestamp, maxExpiryDuration
            );
        }
    }

    /// @dev Membership, then rate kind, then the oracle, then the constraint check. The membership
    ///      gate runs first so an order can never name an arbitrary contract as its recipe and have
    ///      that contract approve its own constraint.
    function _resolveOracle(JITMarketParams calldata params) private returns (address oracle) {
        address recipe = params.recipe;
        if (!MARKET_REGISTRY.isRecipe(recipe)) {
            revert IMarketRegistry.RecipeNotRegistered(recipe);
        }

        RecipeSource src = IMarketRecipe(recipe).source();
        if (src == RecipeSource.FIXED) {
            oracle = MARKET_REGISTRY.deployFixedRateOracle(params.rateOverride);
        } else {
            if (params.rateOverride != 0) {
                revert BaseFiller__UnexpectedRateOverride(recipe);
            }
            oracle = MARKET_REGISTRY.deploy(
                params.collateralAsset,
                params.referenceAsset,
                src == RecipeSource.NAV
                    ? IMarketRegistry.OracleMode.NAV
                    : IMarketRegistry.OracleMode.PRICE
            );
        }

        bool accepted = IMarketRecipe(recipe)
            .verify(
                params.collateralAsset,
                params.referenceAsset,
                oracle,
                params.constraint,
                params.additionalData
            );
        if (!accepted) {
            revert BaseFiller__RecipeRejectedConstraint(recipe);
        }
    }

    /// @dev Phoenix's `market` returns a zeroed struct for an unknown pool; some doubles revert.
    ///      Treat both as "does not exist".
    function _poolExists(bytes32 poolId) private view returns (bool) {
        try POOL_MANAGER.market(MarketId.wrap(poolId)) returns (Market memory existing) {
            return existing.collateralAsset != address(0);
        } catch {
            return false;
        }
    }

    /// @dev Revert unless the supplied Settler equals the immutable `SETTLER`.
    function _settlerFor(RolloverTypes.OrderData memory orderData) private view returns (ISettler) {
        return orderData.allowPartialFills ? PARTIAL_SETTLER : EXACT_SETTLER;
    }

    /// @dev Revert unless the supplied Settler equals the decoded-order mode settler.
    function _assertExpectedSettler(ISettler expected, ISettler actual) private pure {
        if (address(actual) == address(0)) {
            revert BaseFiller__UnknownSettler();
        }
        if (address(actual) != address(expected)) {
            revert BaseFiller__SettlerMismatch(address(expected), address(actual));
        }
    }
}
