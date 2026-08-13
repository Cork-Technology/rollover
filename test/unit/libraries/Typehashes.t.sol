// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";
import { Typehashes } from "src/libraries/Typehashes.sol";

/// @notice TypehashesUnitTest — pins Typehashes behaviour for the Cork Rollover suite.
contract TypehashesUnitTest is Test {
    /// @notice Pins behaviour: order Data Typehash Matches Pinned Literal.
    function test_orderDataTypehashMatchesPinnedLiteral() public pure {
        bytes32 expected = keccak256(
            "OrderData(address user,address settler,address fillerHint,address exclusiveFiller,address srcCstToken,address dstCstToken,address premiumToken,address rolloverContract,uint64 originChainId,uint64 destinationChainId,uint64 openDeadline,uint64 fillDeadline,uint64 orderSalt,uint256 orderSize,uint256 minPremiumPerShare,bool allowPartialFills,bool allowUnderfill,uint8 premiumPaymentMode,bytes32 rolloverIntentHash,RolloverParams rolloverParams)RolloverParams(address srcCstToken,address dstCstToken,uint256 minCaReceived,uint256 minSharesOut,bytes32 srcPoolId,bytes32 dstPoolId,address settler,bytes32 jitMarketHash)"
        );
        assertEq(Typehashes.ORDER_DATA_TYPEHASH, expected);
    }

    /// @notice Pins behaviour: rollover Params Typehash Matches Pinned Literal.
    function test_rolloverParamsTypehashMatchesPinnedLiteral() public pure {
        bytes32 expected = keccak256(
            "RolloverParams(address srcCstToken,address dstCstToken,uint256 minCaReceived,uint256 minSharesOut,bytes32 srcPoolId,bytes32 dstPoolId,address settler,bytes32 jitMarketHash)"
        );
        assertEq(Typehashes.ROLLOVER_PARAMS_TYPEHASH, expected);
    }

    /// @notice Pins the complete JIT market commitment preimage.
    function test_jitMarketParamsTypehashMatchesPinnedLiteral() public pure {
        bytes32 expected = keccak256(
            "JITMarketParams(address collateralAsset,address referenceAsset,uint256 expiryTimestamp,address recipe,uint256 rateOverride,uint256 rateMin,uint256 rateMax,uint256 rateChangePerDayMax,uint256 rateChangeCapacityMax,bytes additionalData,uint256 swapFeePercentage,uint256 unwindSwapFeePercentage)"
        );
        assertEq(Typehashes.JIT_MARKET_PARAMS_TYPEHASH, expected);
    }

    /// @notice Pins behaviour: cell Intent Typehash Matches Pinned Literal.
    function test_cellIntentTypehashMatchesPinnedLiteral() public pure {
        bytes32 expected = keccak256(
            "RolloverIntent(address rolloverContract,bytes32 orderDigest,uint64 deadline,uint64 nonce,Call[] preRolloverHooks,Call[] midRolloverHooks,Call[] postRolloverHooks,Call[] premiumHooks)Call(address target,uint256 value,bytes callData,bool allowFailure,bool isDelegateCall)"
        );
        assertEq(Typehashes.ROLLOVER_INTENT_TYPEHASH, expected);
    }

    /// @notice Pins behaviour: output Typehash Matches ERC7683 Canonical Form.
    function test_outputTypehashMatchesERC7683CanonicalForm() public pure {
        bytes32 expected =
            keccak256("Output(bytes32 token,uint256 amount,bytes32 recipient,uint256 chainId)");
        assertEq(Typehashes.OUTPUT_TYPEHASH, expected);
    }

    /// @notice Pins behaviour: cancel Order Typehash Matches Pinned Literal.
    function test_cancelOrderTypehashMatchesPinnedLiteral() public pure {
        bytes32 expected = keccak256("CancelOrder(bytes32 orderId,uint64 orderSalt)");
        assertEq(Typehashes.CANCEL_ORDER_TYPEHASH, expected);
    }

    /// @notice Pins behaviour: eip712 Domain Typehash Matches Pinned Literal.
    function test_eip712DomainTypehashMatchesPinnedLiteral() public pure {
        bytes32 expected = keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );
        assertEq(Typehashes.EIP712_DOMAIN_TYPEHASH, expected);
    }

    /// @notice Pins behaviour: all Typehashes Are Pairwise Distinct.
    function test_allTypehashesArePairwiseDistinct() public pure {
        bytes32[7] memory all = [
            Typehashes.ORDER_DATA_TYPEHASH,
            Typehashes.ROLLOVER_PARAMS_TYPEHASH,
            Typehashes.JIT_MARKET_PARAMS_TYPEHASH,
            Typehashes.ROLLOVER_INTENT_TYPEHASH,
            Typehashes.OUTPUT_TYPEHASH,
            Typehashes.CANCEL_ORDER_TYPEHASH,
            Typehashes.EIP712_DOMAIN_TYPEHASH
        ];
        for (uint256 i = 0; i < all.length; ++i) {
            for (uint256 j = i + 1; j < all.length; ++j) {
                assertTrue(all[i] != all[j], "typehashes must be pairwise distinct");
            }
        }
    }

    /// @notice Pins behaviour: no Typehash Is Zero Hash.
    function test_noTypehashIsZeroHash() public pure {
        assertTrue(Typehashes.ORDER_DATA_TYPEHASH != bytes32(0));
        assertTrue(Typehashes.ROLLOVER_PARAMS_TYPEHASH != bytes32(0));
        assertTrue(Typehashes.JIT_MARKET_PARAMS_TYPEHASH != bytes32(0));
        assertTrue(Typehashes.ROLLOVER_INTENT_TYPEHASH != bytes32(0));
        assertTrue(Typehashes.OUTPUT_TYPEHASH != bytes32(0));
        assertTrue(Typehashes.CANCEL_ORDER_TYPEHASH != bytes32(0));
        assertTrue(Typehashes.EIP712_DOMAIN_TYPEHASH != bytes32(0));
    }

    /// @notice Pins behaviour: order Data Typehash Differs From Rollover Params Typehash.
    function test_orderDataTypehashDiffersFromRolloverParamsTypehash() public pure {
        assertTrue(
            Typehashes.ORDER_DATA_TYPEHASH != Typehashes.ROLLOVER_PARAMS_TYPEHASH,
            "embedded sub-struct typehash must differ from parent"
        );
    }

    /// @notice Pins behaviour: cancel Order Typehash Binds Order Salt.
    function test_cancelOrderTypehashBindsOrderSalt() public pure {
        bytes32 noSalt = keccak256("CancelOrder(bytes32 orderId)");
        assertTrue(noSalt != Typehashes.CANCEL_ORDER_TYPEHASH, "orderSalt must be load-bearing");
    }

    /// @notice Pins behaviour: output Typehash Binds Chain Id.
    function test_outputTypehashBindsChainId() public pure {
        bytes32 noChain = keccak256("Output(bytes32 token,uint256 amount,bytes32 recipient)");
        assertTrue(noChain != Typehashes.OUTPUT_TYPEHASH, "chainId must be load-bearing");
    }

    /// @notice Pins behaviour: rollover Params Typehash Rejects Legacy Hooks Data Preimage.
    function test_rolloverParamsTypehashRejectsLegacyHooksDataPreimage() public pure {
        bytes32 legacy = keccak256(
            "RolloverParams(address srcCstToken,address dstCstToken,uint256 minCaReceived,uint256 minSharesOut,bytes preRolloverHooksData,bytes postRolloverHooksData)"
        );
        assertTrue(
            legacy != Typehashes.ROLLOVER_PARAMS_TYPEHASH,
            "legacy hooks-data preimage must not match the rolloverContract-opinionated typehash"
        );
    }

    /// @notice Pins behaviour: domain Typehash Binds Name And Version.
    function test_domainTypehashBindsNameAndVersion() public pure {
        bytes32 noVersion =
            keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");
        assertTrue(noVersion != Typehashes.EIP712_DOMAIN_TYPEHASH, "version must be load-bearing");
        bytes32 noName =
            keccak256("EIP712Domain(string version,uint256 chainId,address verifyingContract)");
        assertTrue(noName != Typehashes.EIP712_DOMAIN_TYPEHASH, "name must be load-bearing");
    }
}
