// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice SettlerStrengthenedTest — pins SettlerStrengthened behaviour for the Cork Rollover suite.
contract SettlerStrengthenedTest is BaseTest {
    /// @notice Pins behaviour: cancel Bad Signature Reverts Before Fsm Gate.
    function testRevert_cancelBadSignatureRevertsBeforeFsmGate() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        bytes32 digest = _openOrder(orderData);

        bytes memory badSig = new bytes(65);

        badSig[64] = bytes1(uint8(27));
        badSig[31] = bytes1(uint8(1));
        badSig[63] = bytes1(uint8(1));
        vm.expectRevert();
        settler.cancel(digest, _originData(orderData), badSig);
    }
}
