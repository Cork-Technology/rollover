// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { BaseSettler } from "src/BaseSettler.sol";
import { ExactSettler } from "src/ExactSettler.sol";
import { Settler__FillDeadlineMismatch } from "src/errors/SettlerErrors.sol";
import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice BaseFiller and Settler must derive byte-identical orderDigest values for the same order.
contract BaseFillerSettlerDigestParityTest is BaseTest {
    /// @notice base filler order id matches settler eip712 digest.
    function test_baseFillerOrderIdMatchesSettlerEip712Digest() public view {
        _assertBaseFillerOrderIdMatchesSettlerEip712Digest(SettlerMode.Exact);
        _assertBaseFillerOrderIdMatchesSettlerEip712Digest(SettlerMode.Partial);
    }

    function _assertBaseFillerOrderIdMatchesSettlerEip712Digest(SettlerMode mode) internal view {
        RolloverTypes.OrderData memory orderData = _orderForMode(mode);
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);

        bytes32 settlerDigest = _orderDigest(orderData);

        bytes32 resolvedOrderId = _settlerForMode(mode).resolveFor(g, "").orderId;
        assertEq(
            resolvedOrderId, settlerDigest, "F-I fix: resolveFor(order).orderId == EIP-712 digest"
        );

        bytes32 legacyOrderId = keccak256(abi.encode(g.user, g.nonce, g.orderData));
        assertNotEq(legacyOrderId, settlerDigest, "F-I regression: legacy formula diverges");
    }

    /// @notice tampered fill deadline reverts with dedicated error.
    function test_tamperedFillDeadlineRevertsWithDedicatedError() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.user = cptHolder;

        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);

        orderData.fillDeadline = uint64(uint32(g.fillDeadline) + 1);

        bytes memory tamperedOrderData = abi.encode(orderData);
        ERC7683Types.GaslessCrossChainOrder memory tampered = g;
        tampered.orderData = tamperedOrderData;

        bytes memory userSig = _signOrder(cptHolderPk, orderData);

        vm.expectRevert(Settler__FillDeadlineMismatch.selector);
        settler.openFor(tampered, userSig, "");
    }
}
