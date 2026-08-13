// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

/// @title RolloverTypes
/// @notice Canonical enums and structs shared across the Cork Rollover protocol — hook intents,
///         order data, and dispatch context. Every signer, hasher, and verifier reads the same
///         Cork-specific shapes from this file.
library RolloverTypes {
    /// @notice Signed `OrderData.premiumPaymentMode` value for the atomic-only lifecycle.
    uint8 internal constant PREMIUM_PAYMENT_MODE_ATOMIC_ONLY = 0;

    /// @notice Signed `OrderData.premiumPaymentMode` value allowing cPT-holder-opt-in async premium.
    /// @dev Phase-tagged `fill` async routing and `reclaim` require this mode; `0` keeps
    ///      atomic-only admission.
    uint8 internal constant PREMIUM_PAYMENT_MODE_ATOMIC_OR_SEPARATE = 1;

    /// @notice Canonical order lifecycle status (see BS-ST-20).
    /// @dev Transitions are gated by the Settler state machine; the polarity-equivalent revert
    ///      is `Settler__OrderInTerminalState`.
    enum OrderStatus {
        None,
        Opened,
        Settled,
        Expired,
        Cancelled,
        Closing
    }

    /// @notice Hook phase discriminator dispatched by `Settler.fill`.
    enum HookPhase {
        ROLLOVER,
        PREMIUM
    }

    /// @notice EIP-712 `Call` struct describing one rolloverContract hook invocation.
    /// @param target Hook target address. The rolloverContract requires deployed code at this address.
    /// @param value Native value requested for the call. Current rolloverContract hooks must encode zero.
    /// @param callData Calldata forwarded to the hook target.
    /// @param allowFailure Failure-tolerance flag. Current rolloverContract hooks must encode false.
    /// @param isDelegateCall Dispatch mode flag. Current rolloverContract hooks must encode true.
    struct Call {
        address target;
        uint256 value;
        bytes callData;
        bool allowFailure;
        bool isDelegateCall;
    }

    /// @notice EIP-712 `RolloverParams` struct nested inside cPT-holder-signed `OrderData`.
    /// @param srcCstToken Source CST token address that the rolloverContract burns during `unwindMint`.
    /// @param dstCstToken Destination CST token address that the rolloverContract receives from `deposit`.
    /// @param minCaReceived Minimum collateral-asset amount required from the source `unwindMint`.
    /// @param minSharesOut Minimum dstCST shares required from the destination `deposit`.
    /// @param srcPoolId Phoenix pool id for the source leg.
    /// @param dstPoolId Phoenix pool id for the destination leg.
    /// @param settler Signed Settler address pinned to the factory origin-settler latch.
    /// @param jitMarketHash Optional commitment to the negotiated just-in-time market creation
    ///        parameters; zero means this order does not authorize market creation.
    struct RolloverParams {
        address srcCstToken;
        address dstCstToken;
        uint256 minCaReceived;
        uint256 minSharesOut;
        bytes32 srcPoolId;
        bytes32 dstPoolId;
        address settler;
        bytes32 jitMarketHash;
    }

    /// @notice EIP-712 `RolloverIntent` payload committed by cPT-holder-signed `OrderData`.
    /// @param rolloverContract RolloverContract clone that must execute the intent.
    /// @param orderDigest Canonical order digest bound into the signed intent.
    /// @param deadline Last timestamp at which the rolloverContract may execute any phase of the intent.
    /// @param nonce cPT holder-supplied nonce for off-chain uniqueness and auditability.
    /// @param preRolloverHooks Hook list run before the source `unwindMint`.
    /// @param midRolloverHooks Hook list run between source `unwindMint` and destination `deposit`.
    /// @param postRolloverHooks Hook list run after destination `deposit` and token forwarding.
    /// @param premiumHooks Hook list run during the PREMIUM phase after premium delivery.
    struct RolloverIntent {
        address rolloverContract;
        bytes32 orderDigest;
        uint64 deadline;
        uint64 nonce;
        Call[] preRolloverHooks;
        Call[] midRolloverHooks;
        Call[] postRolloverHooks;
        Call[] premiumHooks;
    }

    /// @notice EIP-712 `OrderData` payload (carried inside the ERC-7683 envelope's `orderData`).
    /// @param user cPT holder address; must equal the rolloverContract's immutable owner.
    /// @param settler Settler contract that owns the order lifecycle.
    /// @param fillerHint Off-chain filler hint (not enforced on-chain).
    /// @param exclusiveFiller If non-zero, gates `fill` per INV-FILLER-AUTH.
    /// @param srcCstToken Source CST token address.
    /// @param dstCstToken Destination CST token address.
    /// @param premiumToken ERC-20 token used to pay the filler premium.
    /// @param rolloverContract cPT holder rolloverContract that authored and executes the hook intent.
    /// @param originChainId ERC-7683 origin chain id.
    /// @param destinationChainId ERC-7683 destination chain id.
    /// @param openDeadline Last block timestamp at which `open` / `openFor` is valid.
    /// @param fillDeadline Last block timestamp at which `fill` is valid.
    /// @param orderSalt cPT holder-supplied salt (binds `CancelOrder` and uniqueness).
    /// @param orderSize Total srcCST size the order targets.
    /// @param minPremiumPerShare Raw premium-token base units owed per `1e18` dstCST produced
    ///        (M-08 ceil-rounded floor). The Settler computes
    ///        `ceil(dstCstProduced * minPremiumPerShare / 1e18)` and transfers that result
    ///        directly as raw `premiumToken` units; signers must pre-scale this value for
    ///        non-18-decimal premium tokens.
    /// @param allowPartialFills When true, the order accepts multiple partial fills.
    /// @param allowUnderfill When true, a leg may consume less than its requested fill amount and
    ///        refund srcCST; partial order-level finality still requires aggregate consumption.
    /// @param premiumPaymentMode cPT-holder-signed premium lifecycle mode: `0` =
    ///        `PREMIUM_PAYMENT_MODE_ATOMIC_ONLY`, `1` =
    ///        `PREMIUM_PAYMENT_MODE_ATOMIC_OR_SEPARATE`; larger values are rejected at admission.
    /// @param rolloverIntentHash Canonical zero-digest hash of the cPT holder intent.
    /// @param rolloverParams Signed rollover parameters consumed by the rolloverContract in ROLLOVER phase.
    /// @dev Field groups (Settler EIP-712 domain wire order - DO NOT REORDER POST-LAUNCH;
    ///      reorder invalidates every in-flight cPT-holder-signed `OrderData` digest AND breaks
    ///      `rolloverIntentHash` continuity across deployed rolloverContracts):
    ///      (1) Parties      - `user`, `settler`, `fillerHint`, `exclusiveFiller`
    ///      (2) Tokens       - `srcCstToken`, `dstCstToken`, `premiumToken`, `rolloverContract`
    ///      (3) Routing      - `originChainId`, `destinationChainId`
    ///      (4) Deadlines    - `openDeadline`, `fillDeadline`, `orderSalt`
    ///      (5) Economic     - `orderSize`, `minPremiumPerShare`
    ///      (6) Flags        - `allowPartialFills`, `allowUnderfill`, `premiumPaymentMode`
    ///      (7) Intent bind  - `rolloverIntentHash`, `rolloverParams`
    /// @custom:invariant INV-WIRE-ORDER-STABILITY - OrderData field order is frozen post-launch.
    struct OrderData {
        // --- Parties ---
        address user;
        address settler;
        address fillerHint;
        address exclusiveFiller;
        // --- Tokens ---
        address srcCstToken;
        address dstCstToken;
        address premiumToken;
        address rolloverContract;
        // --- Routing ---
        uint64 originChainId;
        uint64 destinationChainId;
        // --- Deadlines / replay protection ---
        uint64 openDeadline;
        uint64 fillDeadline;
        uint64 orderSalt;
        // --- Economic terms ---
        uint256 orderSize;
        uint256 minPremiumPerShare;
        // --- Flags ---
        bool allowPartialFills;
        bool allowUnderfill;
        uint8 premiumPaymentMode;
        // --- Intent binding ---
        bytes32 rolloverIntentHash;
        RolloverParams rolloverParams;
    }

    /// @notice Settler → RolloverContract dispatch context carried through every phase invocation.
    /// @param filler Filler whose rollover or premium subject is being executed.
    /// @param fillAmount srcCST amount requested for this phase; nonzero only for ROLLOVER.
    /// @param rolloverIntentHash Canonical order-independent intent hash bound by `OrderData`.
    /// @param fillDeadline cPT-holder-signed order fill deadline mirrored from `OrderData`.
    /// @param allowPartialFills cPT-holder-signed partial-fill flag mirrored from `OrderData`.
    /// @param allowUnderfill cPT-holder-signed underfill flag mirrored from `OrderData`.
    /// @param orderSize cPT-holder-signed total srcCST order size mirrored from `OrderData`.
    /// @param originSettler Settler that originated the dispatch, pinned by the factory latch.
    /// @param premiumToken Premium-token address mirrored from `OrderData` during PREMIUM.
    /// @param premium Premium-token amount delivered for this phase; nonzero only for PREMIUM.
    /// @param subFiller Resolved sub-filler identity from the atomic frame (`LibFillerAuth`
    ///        substitutes wire-zero to `bytes32(uint256(uint160(msg.sender)))`). Partial-mode
    ///        settler accounting keys by `(orderDigest, filler, subFiller)`; exact-mode settler
    ///        storage ignores it; rolloverContract `premiumFiredFor` / `PremiumFired` always use this field.
    struct FillContext {
        address filler;
        uint256 fillAmount;
        bytes32 rolloverIntentHash;
        uint64 fillDeadline;
        bool allowPartialFills;
        bool allowUnderfill;
        uint256 orderSize;
        address originSettler;
        address premiumToken;
        uint256 premium;
        bytes32 subFiller;
    }
}
