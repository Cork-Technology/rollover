// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { IDestinationSettler } from "src/interfaces/external/erc7683/IDestinationSettler.sol";
import { IOriginSettler } from "src/interfaces/external/erc7683/IOriginSettler.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @title ISettler
/// @notice Shared Settler lifecycle, metadata, and ERC-7683 entrypoints.
interface ISettler is IOriginSettler, IDestinationSettler {
    /// @notice Emitted when an order reaches terminal `Settled` status.
    /// @dev Exact mode emits after the single rollover record is premium-paid and settled;
    ///      partial mode emits when aggregate partial consumption is complete and all live dstCST
    ///      escrow has drained.
    /// @param orderId Canonical order digest / ERC-7683 order id.
    event OrderSettled(bytes32 indexed orderId);

    /// @notice Emitted when an order is permissionlessly marked terminal `Expired`.
    /// @dev Does not imply token movement; unpaid dstCST residual recovery is handled by
    ///      `reclaim`.
    /// @param orderId Canonical order digest / ERC-7683 order id.
    event OrderExpired(bytes32 indexed orderId);

    /// @notice Emitted when cPT holder cancellation moves an order to terminal `Cancelled`.
    /// @dev Partial-mode cancellation can emit `IPartialSettler.OrderClosing` instead when live
    ///      dstCST escrow remains.
    /// @param orderId Canonical order digest / ERC-7683 order id.
    event OrderCancelled(bytes32 indexed orderId);

    /// @notice Emitted when Settler-side ROLLOVER accounting is accepted for a fill leg.
    /// @param orderDigest Canonical order digest / ERC-7683 order id.
    /// @param filler Rollover filler (`msg.sender`).
    /// @param subFiller Resolved sub-filler identity (partial-mode slot key; exact-mode ignored
    ///        in settler storage; rolloverContract events/latch use the resolved value).
    /// @param srcCstProvided Source CST consumed after subtracting rolloverContract-reported leftover.
    /// @param dstCstProduced RolloverContract-reported dstCST production accepted by the Settler.
    event RolloverLegFilled(
        bytes32 indexed orderDigest,
        address indexed filler,
        bytes32 indexed subFiller,
        uint256 srcCstProvided,
        uint256 dstCstProduced
    );

    /// @notice Emitted when Settler-side PREMIUM accounting is accepted for a rollover subject.
    /// @param orderDigest Canonical order digest / ERC-7683 order id.
    /// @param premiumPayer Address that supplied premium tokens.
    /// @param rolloverFiller Rollover filler whose record was paid.
    /// @param subFiller Resolved sub-filler identity (partial-mode slot key; exact-mode ignored
    ///        in settler storage; rolloverContract events/latch use the resolved value).
    /// @param premium Premium-token amount paid for the rollover subject.
    event PremiumLegFilled(
        bytes32 indexed orderDigest,
        address indexed premiumPayer,
        address indexed rolloverFiller,
        bytes32 subFiller,
        uint256 premium
    );

    /// @notice Emitted when unpaid dstCST residual is reclaimed to the cPT holder rolloverContract.
    /// @dev Exact mode emits only this event; partial mode also emits
    ///      `IPartialSettler.DefaulterResidualReclaimedWithSubFiller` with the full slot key.
    /// @param orderId Canonical order digest / ERC-7683 order id.
    /// @param defaulterFiller Filler whose unpaid residual is reclaimed.
    /// @param recipientRolloverContract RolloverContract that receives the reclaimed residual.
    /// @param amount Destination CST amount reclaimed.
    event DefaulterResidualReclaimed(
        bytes32 indexed orderId,
        address indexed defaulterFiller,
        address indexed recipientRolloverContract,
        uint256 amount
    );

    /// @notice Emitted when ROLLOVER source CST leftover is returned to the fill caller.
    /// @dev The emitted amount is the rolloverContract-reported leftover accepted after Settler
    ///      balance-delta reconciliation. `filler` is the immediate caller of `fill`; when a
    ///      helper contract or adapter fills the order, that helper receives this refund and owns
    ///      any upstream tail-refund policy.
    /// @param orderDigest Canonical order digest / ERC-7683 order id.
    /// @param filler Immediate fill caller and refund recipient.
    /// @param subFiller Resolved sub-filler identity (partial-mode slot key; exact-mode ignored
    ///        in settler storage).
    /// @param reportedSrcLeftover Source CST amount reported by the rolloverContract and refunded by the
    ///        Settler.
    event SrcCstRefunded(
        bytes32 indexed orderDigest,
        address indexed filler,
        bytes32 indexed subFiller,
        uint256 reportedSrcLeftover
    );

    /// @notice Execute the destination-side filler leg of an order.
    /// @dev Cork's tag-routed entrypoint satisfies the ERC-7683 destination-side `fill`
    ///      declaration.
    /// @custom:invariant BS-ST-20 — fill follows the canonical order-status state machine.
    /// @custom:invariant INV-FILLER-AUTH — successful ROLLOVER slot creation satisfies
    ///                   exclusive-filler or delegated filler authorization; async PREMIUM
    ///                   uses recorded-slot semantics and does not live-check FillerAuth.
    /// @custom:invariant INV-FILL-TAG-DISPATCH — filler payload tags select atomic,
    ///                   rollover, or premium dispatch.
    /// @custom:invariant INV-ATOMIC-FILL-CANONICAL — atomic fills run admit, rollover, premium,
    ///                   and settlement in one frame.
    /// @custom:invariant N-INV-LIFECYCLE-ORIGINDATA-DIGEST-BINDING — `originData` must
    ///                   re-derive to the supplied order id before mutation.
    /// @param orderId Canonical order identifier.
    /// @param originData ABI-encoded order envelope.
    /// @param fillerData ABI-encoded filler-supplied payload.
    function fill(bytes32 orderId, bytes calldata originData, bytes calldata fillerData)
        external
        override(IDestinationSettler);

    /// @notice EIP-712 domain separator used for order digests and filler-auth signatures.
    /// @return The settler's EIP-712 domain separator.
    // forge-lint: disable-next-line(mixed-case-function)
    function DOMAIN_SEPARATOR() external view returns (bytes32);

    /// @notice Identity view — hand-edited semver of the Settler implementation.
    /// @dev Bump rule: minor on backwards-compatible storage-layout change; major on ABI break.
    /// @return Semantic version string.
    function version() external pure returns (string memory);

    /// @notice Returns Cork's filler-authorization struct typehash.
    /// @dev Cork-specific signer metadata, not an ERC-7683 view. Filler authorization digests
    ///      use this struct typehash under the EIP-712 domain returned by `DOMAIN_SEPARATOR()`.
    /// @return typehash `FillerAuth(bytes32 orderDigest,address destination,bytes32 subFiller)`.
    function fillerAuthTypehash() external pure returns (bytes32 typehash);

    /// @notice Reclaim unpaid dstCST residual from an async-premium opt-in rollover slot.
    /// @dev Permissionless after `fillDeadline` for orders that opted into
    ///      `PREMIUM_PAYMENT_MODE_ATOMIC_OR_SEPARATE`. The opt-in allows but does not prove an
    ///      async fill occurred; atomically settled slots have no reclaimable residual and
    ///      revert in mode storage. Reclaimed dstCST always goes to the originating cPT holder
    ///      rolloverContract recorded in `originData`; callers cannot choose the recipient. Exact mode
    ///      stores one residual slot and ignores `subFiller`. Partial mode identifies the slot
    ///      by `(orderId, defaultedFiller, subFiller)`.
    /// @custom:invariant INV-DEFAULTER-RECOUP — unpaid dstCST residual remains reclaimable to the
    ///                   originating cPT holder rolloverContract.
    /// @custom:invariant INV-PARTIAL-SUBFILLER-KEYING — partial-mode reclaim identifies slots by
    ///                   `(orderDigest, filler, subFiller)`.
    /// @custom:invariant N-INV-LIFECYCLE-ORIGINDATA-DIGEST-BINDING — `originData` must
    ///                   re-derive to the supplied order id before mutation.
    /// @param orderId Canonical order identifier.
    /// @param defaultedFiller Filler address whose unpaid rollover residual is reclaimed.
    /// @param subFiller Partial-mode sub-filler identity; ignored by exact mode.
    /// @param originData ABI-encoded order envelope.
    function reclaim(
        bytes32 orderId,
        address defaultedFiller,
        bytes32 subFiller,
        bytes calldata originData
    ) external;

    /// @notice Permissionlessly mark an opened or closing order as expired after its fill deadline.
    /// @dev Status-only lifecycle transition. Does not transfer tokens, clear residuals, or
    ///      mutate dstCST liability; unpaid destination-CST residual recovery is handled by
    ///      `reclaim`.
    /// @custom:invariant BS-ST-20 — expiry follows the canonical order-status state machine.
    /// @custom:invariant INV-FSM-TERMINAL-WRITE-COMPLETE — expiry writes a terminal status and
    ///                   emits the matching lifecycle event.
    /// @custom:invariant N-INV-LIFECYCLE-ORIGINDATA-DIGEST-BINDING — `originData` must
    ///                   re-derive to the supplied order id before mutation.
    /// @param orderId Canonical order identifier.
    /// @param originData ABI-encoded order envelope.
    function markExpired(bytes32 orderId, bytes calldata originData) external;

    /// @notice Cancel an order with the cPT holder's EIP-712 cancel signature.
    /// @dev Callable by anyone. Reverts if the order is already terminal or closing.
    ///      Exact-mode orders cancel only before any fill production; partial-mode orders enter
    ///      `Closing` when live dstCST escrow remains, otherwise they become `Cancelled`.
    /// @custom:invariant BS-ST-20 — cancel follows the canonical order-status state machine.
    /// @custom:invariant INV-FSM-TERMINAL-WRITE-COMPLETE — cancel writes `Cancelled` or
    ///                   `Closing` and emits the matching lifecycle event.
    /// @custom:invariant N-INV-LIFECYCLE-ORIGINDATA-DIGEST-BINDING — `originData` must
    ///                   re-derive to the supplied order id before mutation.
    /// @param orderId Canonical order identifier.
    /// @param originData ABI-encoded `GaslessCrossChainOrder` envelope.
    /// @param cptHolderSig cPT-holder EIP-712 signature over `CancelOrder(orderId, orderSalt)`.
    function cancel(bytes32 orderId, bytes calldata originData, bytes calldata cptHolderSig)
        external;

    /// @notice Return the current lifecycle status for an order.
    /// @custom:invariant INV-FSM-TERMINAL-WRITE-COMPLETE — indexers observe canonical terminal
    ///                   lifecycle status through this view.
    /// @param orderDigest Canonical order digest, used as the ERC-7683 order id.
    /// @return status Current order lifecycle status.
    function orderStatus(bytes32 orderDigest)
        external
        view
        returns (RolloverTypes.OrderStatus status);
}
