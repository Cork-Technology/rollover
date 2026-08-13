// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { Typehashes } from "src/libraries/Typehashes.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @title LibSettlerHashing
/// @notice EIP-712 hashing helpers for `OrderData`, `RolloverParams`, and `CancelOrder`. Each
///         hash function has matching `calldata` and `memory` variants; both produce identical
///         digests for identical inputs.
library LibSettlerHashing {
    /// @notice EIP-712 struct hash for a calldata `RolloverParams`.
    /// @param p RolloverParams struct.
    /// @return structHash EIP-712 struct hash.
    function hashRolloverParams(RolloverTypes.RolloverParams calldata p)
        internal
        pure
        returns (bytes32 structHash)
    {
        return keccak256(
            abi.encode(
                Typehashes.ROLLOVER_PARAMS_TYPEHASH,
                p.srcCstToken,
                p.dstCstToken,
                p.minCaReceived,
                p.minSharesOut,
                p.srcPoolId,
                p.dstPoolId,
                p.settler,
                p.jitMarketHash
            )
        );
    }

    /// @notice EIP-712 struct hash for a calldata `OrderData` (nests `RolloverParams`).
    /// @param orderData OrderData struct.
    /// @return structHash EIP-712 struct hash.
    function hashOrderData(RolloverTypes.OrderData calldata orderData)
        internal
        pure
        returns (bytes32 structHash)
    {
        bytes memory prefix = abi.encode(
            Typehashes.ORDER_DATA_TYPEHASH,
            orderData.user,
            orderData.settler,
            orderData.fillerHint,
            orderData.exclusiveFiller,
            orderData.srcCstToken,
            orderData.dstCstToken,
            orderData.premiumToken,
            orderData.rolloverContract,
            orderData.originChainId,
            orderData.destinationChainId
        );
        bytes memory suffix = abi.encode(
            orderData.openDeadline,
            orderData.fillDeadline,
            orderData.orderSalt,
            orderData.orderSize,
            orderData.minPremiumPerShare,
            orderData.allowPartialFills,
            orderData.allowUnderfill,
            orderData.premiumPaymentMode,
            orderData.rolloverIntentHash,
            hashRolloverParams(orderData.rolloverParams)
        );
        return keccak256(bytes.concat(prefix, suffix));
    }

    /// @notice EIP-712 typed-data digest (`0x1901‖domainSeparator‖structHash`) for calldata input.
    /// @param orderData OrderData struct.
    /// @param domainSeparator Settler EIP-712 domain separator.
    /// @return digest EIP-712 typed-data digest.
    function computeOrderDigest(RolloverTypes.OrderData calldata orderData, bytes32 domainSeparator)
        internal
        pure
        returns (bytes32 digest)
    {
        return keccak256(abi.encodePacked(hex"1901", domainSeparator, hashOrderData(orderData)));
    }

    /// @notice Canonical order identifier (alias of `computeOrderDigest`; the two are equal by
    ///         construction in the Cork Settler).
    /// @param orderData OrderData struct.
    /// @param domainSeparator Settler EIP-712 domain separator.
    /// @return orderId Canonical order identifier.
    function computeOrderId(RolloverTypes.OrderData calldata orderData, bytes32 domainSeparator)
        internal
        pure
        returns (bytes32 orderId)
    {
        return computeOrderDigest(orderData, domainSeparator);
    }

    /// @notice EIP-712 struct hash for a memory `RolloverParams`.
    /// @param p RolloverParams struct.
    /// @return structHash EIP-712 struct hash.
    function hashRolloverParamsMemory(RolloverTypes.RolloverParams memory p)
        internal
        pure
        returns (bytes32 structHash)
    {
        return keccak256(
            abi.encode(
                Typehashes.ROLLOVER_PARAMS_TYPEHASH,
                p.srcCstToken,
                p.dstCstToken,
                p.minCaReceived,
                p.minSharesOut,
                p.srcPoolId,
                p.dstPoolId,
                p.settler,
                p.jitMarketHash
            )
        );
    }

    /// @notice EIP-712 struct hash for a memory `OrderData`.
    /// @param orderData OrderData struct.
    /// @return structHash EIP-712 struct hash.
    function hashOrderDataMemory(RolloverTypes.OrderData memory orderData)
        internal
        pure
        returns (bytes32 structHash)
    {
        bytes memory prefix = abi.encode(
            Typehashes.ORDER_DATA_TYPEHASH,
            orderData.user,
            orderData.settler,
            orderData.fillerHint,
            orderData.exclusiveFiller,
            orderData.srcCstToken,
            orderData.dstCstToken,
            orderData.premiumToken,
            orderData.rolloverContract,
            orderData.originChainId,
            orderData.destinationChainId
        );
        bytes memory suffix = abi.encode(
            orderData.openDeadline,
            orderData.fillDeadline,
            orderData.orderSalt,
            orderData.orderSize,
            orderData.minPremiumPerShare,
            orderData.allowPartialFills,
            orderData.allowUnderfill,
            orderData.premiumPaymentMode,
            orderData.rolloverIntentHash,
            hashRolloverParamsMemory(orderData.rolloverParams)
        );
        return keccak256(bytes.concat(prefix, suffix));
    }

    /// @notice EIP-712 typed-data digest for a memory `OrderData`.
    /// @param orderData OrderData struct.
    /// @param domainSeparator Settler EIP-712 domain separator.
    /// @return digest EIP-712 typed-data digest.
    function computeOrderDigestMemory(
        RolloverTypes.OrderData memory orderData,
        bytes32 domainSeparator
    ) internal pure returns (bytes32 digest) {
        return keccak256(
            abi.encodePacked(hex"1901", domainSeparator, hashOrderDataMemory(orderData))
        );
    }

    /// @notice EIP-712 struct hash for the cPT-holder-cancel payload `CancelOrder(orderId, orderSalt)`.
    /// @param orderId Canonical order identifier.
    /// @param orderSalt cPT holder-supplied order salt (binds the cancel to the specific order).
    /// @return structHash EIP-712 struct hash.
    function hashCancelOrder(bytes32 orderId, uint64 orderSalt)
        internal
        pure
        returns (bytes32 structHash)
    {
        return keccak256(abi.encode(Typehashes.CANCEL_ORDER_TYPEHASH, orderId, orderSalt));
    }
}
