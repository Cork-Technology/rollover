// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {
    FillerPayload__AtomicTagRequired,
    FillerPayload__InvalidPhase,
    FillerPayload__InvalidRolloverShape
} from "src/errors/LibFillerPayloadErrors.sol";
import { LibAtomicFill } from "src/libraries/LibAtomicFill.sol";
import { LibFillerAuth } from "src/libraries/LibFillerAuth.sol";
import { FillerPayload } from "src/types/FillerTypes.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @title LibFillerPayload
/// @notice Canonical encode/decode helpers for atomic-fill inner legs and envelopes.
/// @custom:invariant INV-WIRE-ORDER-STABILITY — encoder ABI matches `FillerPayload`.
library LibFillerPayload {
    /// @notice Expected phase byte for a ROLLOVER inner leg.
    uint8 internal constant ROLLOVER_PHASE = uint8(RolloverTypes.HookPhase.ROLLOVER);

    /// @notice ABI-encode a 10-tuple `FillerPayload` blob.
    function encodeFillerPayload(FillerPayload memory payload)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(
            payload.phaseU8,
            payload.fillAmount,
            payload.premium,
            payload.destination,
            payload.premiumFor,
            payload.intent,
            payload.minDstPerSrc,
            payload.fillerAuthSig,
            payload.subFiller,
            payload.cptHolderSig
        );
    }

    /// @notice Encode a ROLLOVER inner leg for an atomic-fill envelope.
    function encodeRolloverLeg(
        uint256 fillAmount,
        address destination,
        RolloverTypes.RolloverIntent memory intent,
        uint256 minDstPerSrc,
        bytes memory fillerAuthSig,
        bytes32 subFiller,
        bytes memory cptHolderSig
    ) internal pure returns (bytes memory) {
        return encodeFillerPayload(
            FillerPayload({
                phaseU8: ROLLOVER_PHASE,
                fillAmount: fillAmount,
                premium: 0,
                destination: destination,
                premiumFor: address(0),
                intent: intent,
                minDstPerSrc: minDstPerSrc,
                fillerAuthSig: fillerAuthSig,
                subFiller: subFiller,
                cptHolderSig: cptHolderSig
            })
        );
    }

    /// @notice Encode the atomic-fill outer envelope.
    function encodeAtomicEnvelope(
        bytes memory rolloverData,
        uint256 premiumCap,
        bytes memory cptHolderSig
    ) internal pure returns (bytes memory) {
        return abi.encode(LibAtomicFill.ATOMIC_TAG, rolloverData, premiumCap, cptHolderSig);
    }

    /// @notice Decode and validate a ROLLOVER inner leg.
    function decodeRolloverPayload(bytes memory fillerData)
        internal
        view
        returns (FillerPayload memory payload)
    {
        payload = LibFillerAuth.decodePayloadMemory(fillerData);
        if (payload.phaseU8 != ROLLOVER_PHASE) {
            revert FillerPayload__InvalidPhase(ROLLOVER_PHASE, payload.phaseU8);
        }
        if (payload.premium != 0 || payload.premiumFor != address(0)) {
            revert FillerPayload__InvalidRolloverShape();
        }
    }

    /// @notice Decode an atomic envelope and reject non-`ATOMIC_TAG` discriminators.
    function decodeAtomicEnvelopeValidated(bytes calldata fillerData)
        internal
        pure
        returns (bytes memory rolloverData, uint256 premiumCap, bytes memory cptHolderSig)
    {
        uint8 tag;
        (tag, rolloverData, premiumCap, cptHolderSig) =
            LibAtomicFill.decodeAtomicEnvelope(fillerData);
        if (tag != LibAtomicFill.ATOMIC_TAG) {
            revert FillerPayload__AtomicTagRequired();
        }
    }
}
