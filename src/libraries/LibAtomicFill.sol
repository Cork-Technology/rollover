// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @title LibAtomicFill
/// @notice Helpers for the atomic-fill dispatch path.
///
///         The atomic-fill envelope encodes a single Settler call that drives
///         admit → rollover → premium → settle inside one frame. The first byte of
///         `fillerData` is the dispatch tag. `ATOMIC_TAG` is distinct from every
///         `HookPhase` enum value so the Settler can route atomic fills separately
///         from cPT-holder-opt-in async phase fills.
///
/// @custom:invariant INV-FILL-TAG-DISPATCH — `ATOMIC_TAG` is the atomic dispatch
///                   branch; `HookPhase` tags are async discriminators only for
///                   orders signed with separate premium opt-in.
library LibAtomicFill {
    /// @notice Settler fill branch selected from the leading filler-data dispatch tag.
    /// @dev `Invalid` is a parser result, not an executable branch. `Rollover` and
    ///      `Premium` reuse `RolloverTypes.HookPhase` tags for async fills, while
    ///      `Atomic` uses `ATOMIC_TAG` for one-frame rollover-plus-premium settlement.
    enum FillDispatch {
        Invalid,
        Rollover,
        Premium,
        Atomic
    }

    /// @notice Dispatch tag for atomic-fill `fillerData` envelopes.
    /// @dev Chosen as `uint8(255)` to maximise distance from existing `HookPhase`
    ///      values (`ROLLOVER = 0`, `PREMIUM = 1`).
    uint8 internal constant ATOMIC_TAG = 255;

    /// @notice Peek the leading dispatch tag of an ABI-encoded `fillerData` blob without
    ///         attempting to decode the rest of the envelope.
    /// @dev The first ABI-encoded field is a left-padded `uint8`. Returns `0` if the blob
    ///      is shorter than 32 bytes; callers that accept ROLLOVER tags must still decode
    ///      the full payload before any state transition.
    /// @param fillerData ABI-encoded blob.
    /// @return tag Leading `uint8` discriminator.
    function peekTag(bytes calldata fillerData) internal pure returns (uint8 tag) {
        if (fillerData.length < 32) {
            return 0;
        }
        // The first 32-byte word holds a left-padded uint8 — the low byte is at offset 31.
        tag = uint8(fillerData[31]);
    }

    /// @notice Classify the leading `Settler.fill` dispatch tag without decoding the payload.
    /// @param fillerData ABI-encoded filler data.
    /// @return dispatch Cork fill-dispatch branch.
    function peekDispatch(bytes calldata fillerData) internal pure returns (FillDispatch dispatch) {
        if (fillerData.length < 32) {
            return FillDispatch.Invalid;
        }

        uint8 tag = peekTag(fillerData);
        if (tag == ATOMIC_TAG) {
            return FillDispatch.Atomic;
        }
        if (tag == uint8(RolloverTypes.HookPhase.ROLLOVER)) {
            return FillDispatch.Rollover;
        }
        if (tag == uint8(RolloverTypes.HookPhase.PREMIUM)) {
            return FillDispatch.Premium;
        }

        return FillDispatch.Invalid;
    }

    /// @notice Decode an atomic-fill envelope.
    /// @dev The envelope is the verbatim 4-tuple
    ///      `(uint8 ATOMIC_TAG, bytes rolloverFillerData, uint256 premiumCap, bytes cptHolderSig)`.
    ///      The rollover `FillerPayload` is decoded by `LibFillerAuth.decodePayload`
    ///      downstream; the premium payload is synthesized from that validated rollover leg.
    /// @param fillerData ABI-encoded atomic envelope.
    /// @return tag Dispatch tag — caller must reject anything other than `ATOMIC_TAG`.
    /// @return rolloverData Inner rollover-leg `FillerPayload` bytes.
    /// @return premiumCap Upper bound on premium the filler authorises this fill to pull.
    /// @return cptHolderSig EIP-712 cPT-holder signature over `orderDigest` for first-admission auth.
    function decodeAtomicEnvelope(bytes calldata fillerData)
        internal
        pure
        returns (
            uint8 tag,
            bytes memory rolloverData,
            uint256 premiumCap,
            bytes memory cptHolderSig
        )
    {
        (tag, rolloverData, premiumCap, cptHolderSig) =
            abi.decode(fillerData, (uint8, bytes, uint256, bytes));
    }

    /// @notice Compute the required premium for a given produced dstCST amount.
    /// @dev Ceil-rounded — filler can never owe less than the cPT holder's
    ///      `minPremiumPerShare` rate; tie-breaks favour the cPT holder. `minPremiumPerShare`
    ///      is denominated in raw premium-token base units per `1e18` dstCST produced,
    ///      and the returned value is transferred directly as raw premium-token units.
    /// @param produced dstCST amount produced and credited to the filler.
    /// @param minPremiumPerShare cPT-holder-signed raw premium-token units per `1e18` dstCST produced.
    /// @return requiredPremium Ceil-rounded premium token amount owed by the filler.
    function computeRequiredPremium(uint256 produced, uint256 minPremiumPerShare)
        internal
        pure
        returns (uint256 requiredPremium)
    {
        requiredPremium = Math.mulDiv(produced, minPremiumPerShare, 1e18, Math.Rounding.Ceil);
    }
}
