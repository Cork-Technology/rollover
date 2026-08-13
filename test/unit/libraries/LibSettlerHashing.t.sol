// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { LibSettlerHashing } from "src/libraries/LibSettlerHashing.sol";
import { Typehashes } from "src/libraries/Typehashes.sol";

/// @notice LibSettlerHashingUnitTest — pins LibSettlerHashing behaviour for the Cork Rollover suite.
contract LibSettlerHashingUnitTest is BaseTest {
    /// @notice Pins behaviour: order Data Typehash Is Stable.
    function test_orderDataTypehashIsStable() public pure {
        bytes32 expected = keccak256(
            "OrderData(address user,address settler,address fillerHint,address exclusiveFiller,address srcCstToken,address dstCstToken,address premiumToken,address rolloverContract,uint64 originChainId,uint64 destinationChainId,uint64 openDeadline,uint64 fillDeadline,uint64 orderSalt,uint256 orderSize,uint256 minPremiumPerShare,bool allowPartialFills,bool allowUnderfill,uint8 premiumPaymentMode,bytes32 rolloverIntentHash,RolloverParams rolloverParams)RolloverParams(address srcCstToken,address dstCstToken,uint256 minCaReceived,uint256 minSharesOut,bytes32 srcPoolId,bytes32 dstPoolId,address settler,bytes32 jitMarketHash)"
        );
        assertEq(Typehashes.ORDER_DATA_TYPEHASH, expected);
    }

    /// @notice Pins behaviour: rollover Params Typehash Is Stable.
    function test_rolloverParamsTypehashIsStable() public pure {
        bytes32 expected = keccak256(
            "RolloverParams(address srcCstToken,address dstCstToken,uint256 minCaReceived,uint256 minSharesOut,bytes32 srcPoolId,bytes32 dstPoolId,address settler,bytes32 jitMarketHash)"
        );
        assertEq(Typehashes.ROLLOVER_PARAMS_TYPEHASH, expected);
    }

    /// @notice Pins behaviour: cancel Order Typehash Binds Order Id And Order Salt.
    function test_cancelOrderTypehashBindsOrderIdAndOrderSalt() public pure {
        bytes32 expected = keccak256("CancelOrder(bytes32 orderId,uint64 orderSalt)");
        assertEq(Typehashes.CANCEL_ORDER_TYPEHASH, expected);
    }

    /// @notice Pins behaviour: output Typehash Matches ERC7683 Canonical Form.
    function test_outputTypehashMatchesERC7683CanonicalForm() public pure {
        bytes32 expected =
            keccak256("Output(bytes32 token,uint256 amount,bytes32 recipient,uint256 chainId)");
        assertEq(Typehashes.OUTPUT_TYPEHASH, expected);
    }

    /// @notice Pins behaviour: hash Cancel Order Produces Deterministic Hash.
    function test_hashCancelOrderProducesDeterministicHash() public pure {
        bytes32 a = LibSettlerHashing.hashCancelOrder(bytes32(uint256(1)), 7);
        bytes32 b = LibSettlerHashing.hashCancelOrder(bytes32(uint256(1)), 7);
        assertEq(a, b);
        bytes32 c = LibSettlerHashing.hashCancelOrder(bytes32(uint256(2)), 7);
        assertTrue(a != c, "different orderId yields different hash");
    }
}
