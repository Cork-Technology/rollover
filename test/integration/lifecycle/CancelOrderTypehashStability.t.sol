// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice CancelOrder EIP-712 typehash stability — locks the canonical hashCancelOrder layout.
contract CancelOrderTypehashStabilityTest is BaseTest {
    /// @notice legacy cancel digest without nonce rejected.
    function test_legacyCancelDigestWithoutNonceRejected() public {
        _assertLegacyCancelDigestWithoutNonceRejected(SettlerMode.Exact);
        _assertLegacyCancelDigestWithoutNonceRejected(SettlerMode.Partial);
    }

    function _assertLegacyCancelDigestWithoutNonceRejected(SettlerMode mode) internal {
        RolloverTypes.OrderData memory orderData = _orderForMode(mode);
        bytes32 digest = _openOrder(orderData);

        bytes32 legacyTypehash = keccak256("CancelOrder(bytes32 orderId)");
        bytes32 inner = keccak256(abi.encode(legacyTypehash, digest));
        bytes32 legacyDigest =
            keccak256(abi.encodePacked(hex"1901", _domainSeparator(orderData.settler), inner));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(cptHolderPk, legacyDigest);
        bytes memory legacySig = abi.encodePacked(r, s, v);

        vm.expectRevert();
        _settlerForMode(mode).cancel(digest, _originData(orderData), legacySig);
    }

    /// @notice typed cancel digest with nonce accepted.
    function test_typedCancelDigestWithNonceAccepted() public {
        _assertTypedCancelDigestWithNonceAccepted(SettlerMode.Exact);
        _assertTypedCancelDigestWithNonceAccepted(SettlerMode.Partial);
    }

    function _assertTypedCancelDigestWithNonceAccepted(SettlerMode mode) internal {
        RolloverTypes.OrderData memory orderData = _orderForMode(mode);
        bytes32 digest = _openOrder(orderData);
        bytes memory typedSig =
            _signCancelFor(orderData.settler, cptHolderPk, digest, orderData.orderSalt);
        _settlerForMode(mode).cancel(digest, _originData(orderData), typedSig);
        assertEq(
            uint8(_settlerForMode(mode).orderStatus(digest)),
            uint8(RolloverTypes.OrderStatus.Cancelled)
        );
    }
}
