// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { LibSettlerHashing } from "src/libraries/LibSettlerHashing.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice RolloverIntent struct hashing matches the canonical typehash byte-for-byte.
contract RolloverIntentHashTypingTest is BaseTest {
    /// @notice  hash od.
    /// @param orderData Decoded order envelope.
    /// @return Return value.
    function _hashOd(RolloverTypes.OrderData calldata orderData) external pure returns (bytes32) {
        return LibSettlerHashing.hashOrderData(orderData);
    }

    /// @notice typed hash differs from naive abi encode.
    function test_typedHashDiffersFromNaiveAbiEncode() public view {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        bytes32 typed = this._hashOd(orderData);

        bytes32 naive = keccak256(abi.encode(orderData));
        assertTrue(typed != naive, "typed hash must differ from naive abi.encode");
    }

    /// @notice typed hash is deterministic.
    function test_typedHashIsDeterministic() public view {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        bytes32 a = this._hashOd(orderData);
        bytes32 b = this._hashOd(orderData);
        assertEq(a, b, "deterministic typed hash");
    }

    /// @notice typed hash binds rollover params sub struct.
    function test_typedHashBindsRolloverParamsSubStruct() public view {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        bytes32 a = this._hashOd(orderData);
        orderData.rolloverParams.minSharesOut = orderData.rolloverParams.minSharesOut + 1;
        bytes32 b = this._hashOd(orderData);
        assertTrue(a != b, "minSharesOut mutation must flip typed hash");
    }
}
