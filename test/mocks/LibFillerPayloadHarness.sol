// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { LibFillerPayload } from "src/libraries/LibFillerPayload.sol";
import { FillerPayload } from "src/types/FillerTypes.sol";

/// @notice Test harness exposing `LibFillerPayload` decode entrypoints.
contract LibFillerPayloadHarness {
    /// @notice Decode and validate a ROLLOVER inner leg via `LibFillerPayload`.
    /// @param fillerData ABI-encoded filler payload bytes.
    /// @return payload Decoded and shape-validated payload.
    function decodeRolloverPayload(bytes memory fillerData)
        external
        view
        returns (FillerPayload memory payload)
    {
        return LibFillerPayload.decodeRolloverPayload(fillerData);
    }

    /// @notice Decode an atomic envelope and require `ATOMIC_TAG`.
    /// @param fillerData ABI-encoded atomic envelope calldata.
    /// @return rolloverData Inner rollover leg bytes.
    /// @return premiumCap Premium cap from the envelope.
    /// @return cptHolderSig cPT-holder signature from the envelope.
    function decodeAtomicEnvelopeValidated(bytes calldata fillerData)
        external
        pure
        returns (bytes memory rolloverData, uint256 premiumCap, bytes memory cptHolderSig)
    {
        return LibFillerPayload.decodeAtomicEnvelopeValidated(fillerData);
    }
}
