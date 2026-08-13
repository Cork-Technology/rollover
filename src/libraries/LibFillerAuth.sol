// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { SignatureChecker } from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import { Typehashes } from "src/libraries/Typehashes.sol";
import { FillerPayload } from "src/types/FillerTypes.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @title LibFillerAuth
/// @notice Filler-data marshalling and exclusive-filler authorisation helpers.
/// @custom:invariant INV-FILLER-AUTH — every successful `Settler.fill` is either unrestricted,
///                   called directly by the `exclusiveFiller`, or carries a valid EIP-712 /
///                   ERC-1271 signature by `exclusiveFiller` over `FillerAuth(orderDigest,
///                   destination, subFiller)`. Destination + subFiller binding makes any
///                   griefing replay across executors or sub-filler slots strictly net-negative
///                   for the attacker.
library LibFillerAuth {
    /// @notice Decode the 10-tuple filler-data blob produced by `BaseFiller` /
    ///         `EvcRolloverAdapter` (or directly by EOA fillers).
    /// @dev Direct-EOA fillers may send `subFiller == bytes32(0)`; the decoder substitutes
    ///      `bytes32(uint256(uint160(msg.sender)))` so direct-EOA partial-mode self-keys to its
    ///      own address. The function is `view` (no longer `pure`) because of the
    ///      `msg.sender` substitution.
    /// @param fillerData Calldata blob produced via `abi.encode(...)`.
    /// @return payload Decoded `FillerPayload` with `subFiller` resolved to a non-zero value.
    function decodePayload(bytes calldata fillerData)
        internal
        view
        returns (FillerPayload memory payload)
    {
        payload = decodePayloadRaw(fillerData);
        if (payload.subFiller == bytes32(0)) {
            payload.subFiller = bytes32(uint256(uint160(msg.sender)));
        }
    }

    /// @notice Decode the 10-tuple filler-data blob without applying direct-EOA sub-filler defaulting.
    /// @dev Preserves the wire value. The ERC-7683 `fill` path uses canonical atomic
    ///      decoders in `LibFillerPayload`; this raw helper is retained for tests and low-level
    ///      payload inspection.
    /// @param fillerData Calldata blob produced via `abi.encode(...)`.
    /// @return payload Decoded `FillerPayload` with the wire `subFiller` preserved.
    function decodePayloadRaw(bytes calldata fillerData)
        internal
        pure
        returns (FillerPayload memory payload)
    {
        (
            payload.phaseU8,
            payload.fillAmount,
            payload.premium,
            payload.destination,
            payload.premiumFor
        ) = abi.decode(fillerData, (uint8, uint256, uint256, address, address));
        _decodePayloadTail(fillerData, payload);
    }

    /// @notice Compute the EIP-712 digest for a
    ///         `FillerAuth(orderDigest, destination, subFiller)` struct.
    /// @param domainSeparator Settler EIP-712 domain separator.
    /// @param orderDigest Canonical order digest the auth is binding to.
    /// @param destination Filler-chosen destination address.
    /// @param subFiller Partial-mode sub-filler identity (or `bytes32(0)` for direct exact-mode
    ///        / partial-mode self-keyed direct-EOA fills — pass the resolved value).
    /// @return digest EIP-712 typed-data digest.
    function hashFillerAuth(
        bytes32 domainSeparator,
        bytes32 orderDigest,
        address destination,
        bytes32 subFiller
    ) internal pure returns (bytes32 digest) {
        bytes32 structHash = keccak256(
            abi.encode(Typehashes.FILLER_AUTH_TYPEHASH, orderDigest, destination, subFiller)
        );
        digest = MessageHashUtils.toTypedDataHash(domainSeparator, structHash);
    }

    /// @notice Authorisation decision for `Settler.fill`.
    /// @dev Upholds INV-FILLER-AUTH: returns true iff (a) no exclusivity gate, (b) direct call by
    ///      `exclusiveFiller`, or (c) a valid EIP-712 / ERC-1271 signature by `exclusiveFiller`
    ///      over `FillerAuth(orderDigest, destination, subFiller)`.
    /// @param exclusiveFiller Optional gate address (zero = no gate).
    /// @param caller `msg.sender` at the `fill` callsite.
    /// @param domainSeparator Settler EIP-712 domain separator.
    /// @param orderDigest Canonical order digest.
    /// @param destination Filler-chosen destination address.
    /// @param subFiller Resolved sub-filler identity (post-`decodePayload` substitution).
    /// @param fillerAuthSig Delegated-executor signature blob.
    /// @return ok True if the call is authorised.
    function isAuthorised(
        address exclusiveFiller,
        address caller,
        bytes32 domainSeparator,
        bytes32 orderDigest,
        address destination,
        bytes32 subFiller,
        bytes memory fillerAuthSig
    ) internal view returns (bool ok) {
        if (exclusiveFiller == address(0)) {
            return true;
        }
        if (caller == exclusiveFiller) {
            return true;
        }
        bytes32 authDigest = hashFillerAuth(domainSeparator, orderDigest, destination, subFiller);
        return SignatureChecker.isValidSignatureNow(exclusiveFiller, authDigest, fillerAuthSig);
    }

    /// @notice Memory-input variant of `decodePayload`. Used by the atomic-fill dispatcher
    ///         to decode the inner `rolloverFillerData` / `premiumFillerData` blobs peeled
    ///         out of the atomic envelope (which arrive as `bytes memory`).
    /// @dev Mirrors `decodePayload` exactly, including the `subFiller == bytes32(0)` →
    ///      `bytes32(uint256(uint160(msg.sender)))` substitution.
    /// @param fillerData ABI-encoded 10-tuple payload as `bytes memory`.
    /// @return payload Decoded `FillerPayload`.
    function decodePayloadMemory(bytes memory fillerData)
        internal
        view
        returns (FillerPayload memory payload)
    {
        (
            payload.phaseU8,
            payload.fillAmount,
            payload.premium,
            payload.destination,
            payload.premiumFor
        ) = abi.decode(fillerData, (uint8, uint256, uint256, address, address));
        _decodePayloadTailMemory(fillerData, payload);
        if (payload.subFiller == bytes32(0)) {
            payload.subFiller = bytes32(uint256(uint160(msg.sender)));
        }
    }

    /// @notice Decode the 10-tuple memory blob without applying direct-EOA sub-filler defaulting.
    /// @dev Retained for tests and low-level payload inspection that need the wire sub-filler
    ///      exactly as encoded.
    /// @param fillerData ABI-encoded 10-tuple payload as `bytes memory`.
    /// @return payload Decoded `FillerPayload` with the wire `subFiller` preserved.
    function decodePayloadRawMemory(bytes memory fillerData)
        internal
        pure
        returns (FillerPayload memory payload)
    {
        (
            payload.phaseU8,
            payload.fillAmount,
            payload.premium,
            payload.destination,
            payload.premiumFor
        ) = abi.decode(fillerData, (uint8, uint256, uint256, address, address));
        _decodePayloadTailMemory(fillerData, payload);
    }

    /// @dev Memory-input variant of `_decodePayloadTail`.
    function _decodePayloadTailMemory(bytes memory fillerData, FillerPayload memory payload)
        private
        pure
    {
        (
            ,,,,,
            payload.intent,
            payload.minDstPerSrc,
            payload.fillerAuthSig,
            payload.subFiller,
            payload.cptHolderSig
        ) =
            abi.decode(
                fillerData,
                (
                    uint256,
                    uint256,
                    uint256,
                    uint256,
                    uint256,
                    RolloverTypes.RolloverIntent,
                    uint256,
                    bytes,
                    bytes32,
                    bytes
                )
            );
    }

    /// @dev Decodes the tail of the 10-tuple filler-data blob. Split from `decodePayload` to
    ///      keep that function's stack usage within compiler limits.
    function _decodePayloadTail(bytes calldata fillerData, FillerPayload memory payload)
        private
        pure
    {
        (
            ,,,,,
            payload.intent,
            payload.minDstPerSrc,
            payload.fillerAuthSig,
            payload.subFiller,
            payload.cptHolderSig
        ) =
            abi.decode(
                fillerData,
                (
                    uint256,
                    uint256,
                    uint256,
                    uint256,
                    uint256,
                    RolloverTypes.RolloverIntent,
                    uint256,
                    bytes,
                    bytes32,
                    bytes
                )
            );
    }
}
