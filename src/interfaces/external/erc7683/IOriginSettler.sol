// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";

/// @title IOriginSettler
/// @notice ERC-7683 origin-side settler entrypoints implemented by Cork Settlers.
/// @dev ABI matches the ERC-7683 text pinned at
///      https://github.com/ethereum/ERCs/blob/dfc90d9274c17977b8bad021ae1207f71c339266/ERCS/erc-7683.md.
interface IOriginSettler {
    /// @notice Emitted when an order is opened on the origin settler.
    /// @param orderId Canonical order identifier.
    /// @param resolvedOrder ERC-7683 resolved order projection.
    event Open(bytes32 indexed orderId, ERC7683Types.ResolvedCrossChainOrder resolvedOrder);

    /// @notice Register an on-chain cross-chain order submitted by the order user.
    /// @dev Standard ERC-7683 `open(OnchainCrossChainOrder)` selector. The caller must equal
    ///      the decoded Cork order user.
    /// @param order The on-chain cross-chain order envelope.
    function open(ERC7683Types.OnchainCrossChainOrder calldata order) external;

    /// @notice Register a user-signed gasless order through the ERC-7683 `openFor` path.
    /// @dev Callable by anyone. Cork intentionally ignores ERC-7683 `originFillerData`:
    ///      filler-specific authorization is checked at fill time through `fillerData` /
    ///      `FillerAuth`, not during order admission. Reopening an already-opened order is a
    ///      no-op only after the supplied envelope and signature still pass admission checks; no
    ///      second `Open` event is emitted. No tokens move during open.
    /// @param order The user-signed gasless cross-chain order envelope.
    /// @param signature Signature by the decoded order user over the canonical order digest.
    /// @param originFillerData ERC-7683 filler-defined data, intentionally ignored by Cork.
    function openFor(
        ERC7683Types.GaslessCrossChainOrder calldata order,
        bytes calldata signature,
        bytes calldata originFillerData
    ) external;

    /// @notice Project an on-chain order into its canonical resolved form.
    /// @dev Standard ERC-7683 `resolve(OnchainCrossChainOrder)` selector. Does not verify a
    ///      cPT-holder signature.
    /// @param order The on-chain cross-chain order envelope.
    /// @return resolved The resolved cross-chain order including orderId and fill instructions.
    function resolve(ERC7683Types.OnchainCrossChainOrder calldata order)
        external
        view
        returns (ERC7683Types.ResolvedCrossChainOrder memory resolved);

    /// @notice Project a gasless order into its resolved form through the ERC-7683 `resolveFor` path.
    /// @dev Cork intentionally ignores `originFillerData`; the resolved projection is determined
    ///      only by the signed order envelope. Reverts if the envelope fails signature-free
    ///      admission shape checks (envelope binding, order-shape, factory-attested
    ///      rolloverContract, user==rolloverContract owner, canonical-cST resolution,
    ///      share-quantum alignment, pool-expiry gate, and exact/partial mode). No cPT-holder
    ///      signature is checked on this view path.
    /// @param order The user-signed gasless cross-chain order envelope.
    /// @param originFillerData ERC-7683 filler-defined data, intentionally ignored by Cork.
    /// @return resolved The resolved cross-chain order including orderId and fill instructions.
    function resolveFor(
        ERC7683Types.GaslessCrossChainOrder calldata order,
        bytes calldata originFillerData
    ) external view returns (ERC7683Types.ResolvedCrossChainOrder memory resolved);
}
