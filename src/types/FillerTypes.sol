// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice Decoded filler-data payload supplied with every `Settler.fill` call.
/// @param phaseU8 Hook phase discriminator (0 = ROLLOVER, 1 = PREMIUM).
/// @param fillAmount srcCST amount the filler is providing (ROLLOVER only; 0 in PREMIUM).
/// @param premium Premium amount the filler is paying (PREMIUM only; 0 in ROLLOVER).
/// @param destination Filler-chosen settle/refund recipient (bound by the FillerAuth sig).
/// @param premiumFor ROLLOVER filler whose record is being paid in PREMIUM. Must be zero in
///        ROLLOVER payloads and nonzero in PREMIUM payloads.
/// @param intent `RolloverIntent` payload whose zero-digest hash is committed by `OrderData`.
/// @param minDstPerSrc Filler-supplied dstCST-per-srcCST floor (1e18-scaled; 0 = opt out;
///        see INV-DSTCST-FLOOR).
/// @param fillerAuthSig Optional EIP-712 / ERC-1271 signature by `exclusiveFiller`.
/// @param subFiller Partial-mode sub-filler identity discriminator. Shared filler contracts
///        derive this from caller identity (BaseFiller: `bytes32(msg.sender)`;
///        EvcRolloverAdapter: `bytes32(job.subaccount)`). Direct-EOA fillers send
///        `bytes32(0)`; `decodePayload` substitutes `bytes32(uint256(uint160(msg.sender)))`
///        so direct-EOA self-keys to its own address. Exact-mode settler storage ignores
///        this field; `FillContext`, rolloverContract `premiumFiredFor`, and `PremiumFired` use the
///        resolved value from the atomic frame.
/// @param cptHolderSig cPT-holder EIP-712 signature over `orderDigest`. Required on direct-fill
///        admission (status `None` -> non-`None`) per INV-DIRECT-FILL-CPT-HOLDER-SIG; ignored
///        on PREMIUM payloads and on already-`Opened` orders (openFor already attested).
/// @dev Field groups (calldata ABI wire order; NOT EIP-712-hashed - reorder is "only" an
///      encoder ABI break across `BaseFiller` / `EvcRolloverAdapter` and does NOT invalidate
///      cPT-holder-signed intents):
///      (1) Phase         - `phaseU8`
///      (2) Amounts       - `fillAmount`, `premium`
///      (3) Routing       - `destination`, `premiumFor`
///      (4) Intent        - `intent`
///      (5) Filler floor  - `minDstPerSrc`
///      (6) Filler auth   - `fillerAuthSig`
///      (7) Sub-filler    - `subFiller`
///      (8) cPT-holder auth    - `cptHolderSig`
/// @custom:invariant INV-WIRE-ORDER-STABILITY - FillerPayload encoder ABI is frozen across
///                   `BaseFiller` / `EvcRolloverAdapter` and their off-chain callers.
/// @custom:invariant INV-SUBFILLER-PROVENANCE - shared filler contracts derive `subFiller`
///                   from caller identity and never accept caller-supplied input;
///                   direct-EOA paths accept `subFiller == bytes32(0)` which defaults to
///                   `bytes32(msg.sender)` in `decodePayload`.
struct FillerPayload {
    // --- Phase ---
    uint8 phaseU8;
    // --- Amounts ---
    uint256 fillAmount;
    uint256 premium;
    // --- Routing ---
    address destination;
    address premiumFor;
    // --- Intent ---
    RolloverTypes.RolloverIntent intent;
    // --- Filler floor ---
    uint256 minDstPerSrc;
    // --- Filler auth ---
    bytes fillerAuthSig;
    // --- Sub-filler ---
    bytes32 subFiller;
    // --- cPT-holder auth ---
    bytes cptHolderSig;
}
