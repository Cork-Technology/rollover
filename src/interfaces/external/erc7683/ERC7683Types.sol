// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

/// @title ERC7683Types
/// @notice Structs from Cork's implemented ERC-7683 cross-chain order interface surface.
/// @dev ABI matches the ERC-7683 text pinned at
///      https://github.com/ethereum/ERCs/blob/dfc90d9274c17977b8bad021ae1207f71c339266/ERCS/erc-7683.md.
library ERC7683Types {
    /// @notice ERC-7683 `Output` shape.
    /// @param token Token identifier, encoded as bytes32 for cross-chain address support.
    /// @param amount Token amount.
    /// @param recipient Output recipient, encoded as bytes32 for cross-chain address support.
    /// @param chainId Chain where the output token transfer or receipt is expected.
    struct Output {
        bytes32 token;
        uint256 amount;
        bytes32 recipient;
        uint256 chainId;
    }

    /// @notice ERC-7683 on-chain cross-chain order envelope.
    /// @param fillDeadline Last timestamp at which the order can be filled.
    /// @param orderDataType Type discriminator for the opaque `orderData` payload.
    /// @param orderData Opaque order payload interpreted by the settler.
    struct OnchainCrossChainOrder {
        uint32 fillDeadline;
        bytes32 orderDataType;
        bytes orderData;
    }

    /// @notice ERC-7683 gasless cross-chain order envelope.
    /// @param originSettler Origin-chain settler that owns order admission.
    /// @param user cPT holder that signed the order.
    /// @param nonce cPT holder-supplied replay-protection nonce.
    /// @param originChainId Chain where the order originates.
    /// @param openDeadline Last timestamp at which the order can be opened.
    /// @param fillDeadline Last timestamp at which the order can be filled.
    /// @param orderDataType Type discriminator for the opaque `orderData` payload.
    /// @param orderData Opaque order payload interpreted by the settler.
    struct GaslessCrossChainOrder {
        address originSettler;
        address user;
        uint256 nonce;
        uint256 originChainId;
        uint32 openDeadline;
        uint32 fillDeadline;
        bytes32 orderDataType;
        bytes orderData;
    }

    /// @notice ERC-7683 resolved cross-chain order (output of `resolve` / `resolveFor`).
    /// @param user cPT holder that signed the order.
    /// @param originChainId Chain where the order originates.
    /// @param openDeadline Last timestamp at which the order can be opened.
    /// @param fillDeadline Last timestamp at which the order can be filled.
    /// @param orderId Canonical identifier for the resolved order.
    /// @param maxSpent Maximum outputs the filler will send.
    /// @param minReceived Minimum outputs that must be given to the filler.
    /// @param fillInstructions Instructions fillers use to execute destination settlement.
    struct ResolvedCrossChainOrder {
        address user;
        uint256 originChainId;
        uint32 openDeadline;
        uint32 fillDeadline;
        bytes32 orderId;
        Output[] maxSpent;
        Output[] minReceived;
        FillInstruction[] fillInstructions;
    }

    /// @notice ERC-7683 fill instruction returned by `resolve`.
    /// @dev `destinationChainId` is `uint256` to match Cork's pinned ERC-7683 ABI at
    ///      https://github.com/ethereum/ERCs/blob/dfc90d9274c17977b8bad021ae1207f71c339266/ERCS/erc-7683.md;
    ///      narrowing it would change the `Open` event's nested resolved-order ABI.
    /// @param destinationChainId Chain where the fill instruction should be executed.
    /// @param destinationSettler Destination settler address, encoded as bytes32.
    /// @param originData Opaque origin-chain data forwarded to the destination settler.
    struct FillInstruction {
        uint256 destinationChainId;
        bytes32 destinationSettler;
        bytes originData;
    }
}
