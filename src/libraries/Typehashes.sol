// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { ModuleType } from "src/interfaces/external/erc7484/IERC7484.sol";

/// @title Typehashes
/// @notice Canonical EIP-712 typehashes and ERC-7484 module-type discriminators used across the
///         Cork Rollover protocol. Keeping them in a single library guarantees every signer,
///         hasher, and verifier sees identical wire-format strings.
library Typehashes {
    /// @notice EIP-712 typehash for `OrderData` (composite type that nests `RolloverParams`).
    /// @dev Field-group key documented at `RolloverTypes.OrderData` (Parties / Tokens / Routing /
    ///      Deadlines / Economic / Flags / Intent bind). DO NOT REORDER POST-LAUNCH: reorder
    ///      invalidates every in-flight cPT-holder-signed `OrderData` digest AND breaks
    ///      `rolloverIntentHash` continuity across deployed rolloverContracts. Any schema change must
    ///      move in lock-step with the Settler EIP-712 domain/version strategy.
    /// @custom:invariant INV-WIRE-ORDER-STABILITY - typehash preimage is frozen post-launch.
    bytes32 internal constant ORDER_DATA_TYPEHASH = keccak256(
        "OrderData(address user,address settler,address fillerHint,address exclusiveFiller,address srcCstToken,address dstCstToken,address premiumToken,address rolloverContract,uint64 originChainId,uint64 destinationChainId,uint64 openDeadline,uint64 fillDeadline,uint64 orderSalt,uint256 orderSize,uint256 minPremiumPerShare,bool allowPartialFills,bool allowUnderfill,uint8 premiumPaymentMode,bytes32 rolloverIntentHash,RolloverParams rolloverParams)RolloverParams(address srcCstToken,address dstCstToken,uint256 minCaReceived,uint256 minSharesOut,bytes32 srcPoolId,bytes32 dstPoolId,address settler,bytes32 jitMarketHash)"
    );

    /// @notice EIP-712 typehash for `RolloverParams`.
    /// @dev Nested inside `ORDER_DATA_TYPEHASH`; shares the post-launch invalidation cost. DO NOT
    ///      REORDER POST-LAUNCH for the same reason as `OrderData`.
    /// @custom:invariant INV-WIRE-ORDER-STABILITY - typehash preimage is frozen post-launch.
    bytes32 internal constant ROLLOVER_PARAMS_TYPEHASH = keccak256(
        "RolloverParams(address srcCstToken,address dstCstToken,uint256 minCaReceived,uint256 minSharesOut,bytes32 srcPoolId,bytes32 dstPoolId,address settler,bytes32 jitMarketHash)"
    );

    /// @notice Commitment typehash for cPT-holder/filler-negotiated JIT market parameters.
    bytes32 internal constant JIT_MARKET_PARAMS_TYPEHASH = keccak256(
        "JITMarketParams(address collateralAsset,address referenceAsset,uint256 expiryTimestamp,address recipe,uint256 rateOverride,uint256 rateMin,uint256 rateMax,uint256 rateChangePerDayMax,uint256 rateChangeCapacityMax,bytes additionalData,uint256 swapFeePercentage,uint256 unwindSwapFeePercentage)"
    );

    /// @notice EIP-712 typehash for the `FillerAuth(orderDigest, destination, subFiller)` struct
    ///         (INV-FILLER-AUTH + INV-PARTIAL-SUBFILLER-KEYING). Destination-binding defeats
    ///         griefing replays; subFiller-binding scopes the authorisation to a single
    ///         partial-mode sub-filler slot so a routed contract can't substitute another
    ///         user's identity into the same signature.
    bytes32 internal constant FILLER_AUTH_TYPEHASH =
        keccak256("FillerAuth(bytes32 orderDigest,address destination,bytes32 subFiller)");

    /// @notice EIP-712 typehash for source-level `RolloverIntent` hook arrays.
    /// @dev The signed wire type name is now `RolloverIntent`; changing this preimage
    ///      changes committed `rolloverIntentHash` values.
    bytes32 internal constant ROLLOVER_INTENT_TYPEHASH = keccak256(
        "RolloverIntent(address rolloverContract,bytes32 orderDigest,uint64 deadline,uint64 nonce,Call[] preRolloverHooks,Call[] midRolloverHooks,Call[] postRolloverHooks,Call[] premiumHooks)Call(address target,uint256 value,bytes callData,bool allowFailure,bool isDelegateCall)"
    );

    /// @notice ERC-7484 module-type discriminator for pre-rollover hooks.
    ModuleType internal constant MODULE_TYPE_PRE_ROLLOVER_HOOK = ModuleType.wrap(0xc0c0_0001);

    /// @notice ERC-7484 module-type discriminator for mid-rollover hooks.
    ModuleType internal constant MODULE_TYPE_MID_ROLLOVER_HOOK = ModuleType.wrap(0xc0c0_0002);

    /// @notice ERC-7484 module-type discriminator for post-rollover hooks.
    ModuleType internal constant MODULE_TYPE_POST_ROLLOVER_HOOK = ModuleType.wrap(0xc0c0_0003);

    /// @notice ERC-7484 module-type discriminator for premium (executor) hooks.
    ModuleType internal constant MODULE_TYPE_EXECUTOR = ModuleType.wrap(0xc0c0_0004);

    /// @notice EIP-712 typehash for ERC-7683 `Output`.
    bytes32 internal constant OUTPUT_TYPEHASH =
        keccak256("Output(bytes32 token,uint256 amount,bytes32 recipient,uint256 chainId)");

    /// @notice EIP-712 typehash for the cPT-holder-cancel struct `CancelOrder(orderId, orderSalt)`.
    bytes32 internal constant CANCEL_ORDER_TYPEHASH =
        keccak256("CancelOrder(bytes32 orderId,uint64 orderSalt)");

    /// @notice EIP-712 domain typehash.
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
}
