// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {
    Settler__PremiumForOnlyPremiumPhase,
    Settler__UnknownPhase
} from "src/errors/SettlerErrors.sol";
import { LibFillerAuth } from "src/libraries/LibFillerAuth.sol";
import { LibFillerPayload } from "src/libraries/LibFillerPayload.sol";
import { FillerPayload } from "src/types/FillerTypes.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @title LibFillerPayloadExternal
/// @notice External-library wrappers for heavy filler-payload decoders.
library LibFillerPayloadExternal {
    /// @notice Decode a calldata filler payload without sub-filler defaulting.
    /// @param fillerData ABI-encoded `FillerPayload`.
    /// @return payload Decoded payload with the wire sub-filler value preserved.
    function decodePayloadRaw(bytes calldata fillerData)
        external
        pure
        returns (FillerPayload memory payload)
    {
        return LibFillerAuth.decodePayloadRaw(fillerData);
    }

    /// @notice Decode and validate an async ROLLOVER phase payload.
    /// @dev Applies direct-EOA sub-filler defaulting before returning the payload.
    /// @param fillerData ABI-encoded `FillerPayload`.
    /// @return payload Decoded ROLLOVER payload with sub-filler resolved.
    function decodeAsyncRolloverPayload(bytes calldata fillerData)
        external
        view
        returns (FillerPayload memory payload)
    {
        payload = LibFillerAuth.decodePayload(fillerData);
        if (payload.phaseU8 != uint8(RolloverTypes.HookPhase.ROLLOVER)) {
            revert Settler__UnknownPhase();
        }
        if (payload.premium != 0 || payload.premiumFor != address(0)) {
            revert Settler__PremiumForOnlyPremiumPhase();
        }
    }

    /// @notice Decode and validate an async PREMIUM phase payload.
    /// @dev Preserves the wire sub-filler value; mode-specific Settlers resolve it against the
    ///      recorded rollover slot.
    /// @param fillerData ABI-encoded `FillerPayload`.
    /// @return payload Decoded PREMIUM payload with the wire sub-filler preserved.
    function decodeAsyncPremiumPayload(bytes calldata fillerData)
        external
        pure
        returns (FillerPayload memory payload)
    {
        payload = LibFillerAuth.decodePayloadRaw(fillerData);
        if (payload.phaseU8 != uint8(RolloverTypes.HookPhase.PREMIUM)) {
            revert Settler__UnknownPhase();
        }
        if (payload.fillAmount != 0) {
            revert Settler__PremiumForOnlyPremiumPhase();
        }
    }

    /// @notice Decode an atomic-fill envelope and heavy rollover payload in one library call.
    /// @param fillerData ABI-encoded atomic-fill envelope.
    /// @return rolloverPayload Decoded and validated ROLLOVER inner-leg payload.
    /// @return premiumCap Filler-authorised premium cap from the atomic envelope.
    /// @return cptHolderSig cPT-holder signature from the atomic envelope.
    function decodeAtomicPayloads(bytes calldata fillerData)
        external
        view
        returns (
            FillerPayload memory rolloverPayload,
            uint256 premiumCap,
            bytes memory cptHolderSig
        )
    {
        bytes memory rolloverData;
        (rolloverData, premiumCap, cptHolderSig) =
            LibFillerPayload.decodeAtomicEnvelopeValidated(fillerData);
        rolloverPayload = LibFillerPayload.decodeRolloverPayload(rolloverData);
        rolloverPayload.cptHolderSig = cptHolderSig;
    }
}
