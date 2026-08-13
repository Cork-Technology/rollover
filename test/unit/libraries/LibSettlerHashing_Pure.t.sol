// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";
import { LibSettlerHashing } from "src/libraries/LibSettlerHashing.sol";
import { Typehashes } from "src/libraries/Typehashes.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice LibSettlerHashingPureTest — pins LibSettlerHashing_Pure behaviour for the Cork Rollover suite.
contract LibSettlerHashingPureTest is Test {
    /// @notice Ext hash rollover params.
    /// @param p Generic input.
    /// @return Return value.
    function extHashRolloverParams(RolloverTypes.RolloverParams calldata p)
        external
        pure
        returns (bytes32)
    {
        return LibSettlerHashing.hashRolloverParams(p);
    }
    /// @notice Ext hash order data.
    /// @param orderData Decoded order envelope.
    /// @return Return value.

    function extHashOrderData(RolloverTypes.OrderData calldata orderData)
        external
        pure
        returns (bytes32)
    {
        return LibSettlerHashing.hashOrderData(orderData);
    }
    /// @notice Ext compute order digest.
    /// @param orderData Decoded order envelope.
    /// @param domainSeparator EIP-712 domain separator.
    /// @return Return value.

    function extComputeOrderDigest(
        RolloverTypes.OrderData calldata orderData,
        bytes32 domainSeparator
    ) external pure returns (bytes32) {
        return LibSettlerHashing.computeOrderDigest(orderData, domainSeparator);
    }
    /// @notice Ext compute order id.
    /// @param orderData Decoded order envelope.
    /// @param domainSeparator EIP-712 domain separator.
    /// @return Return value.

    function extComputeOrderId(RolloverTypes.OrderData calldata orderData, bytes32 domainSeparator)
        external
        pure
        returns (bytes32)
    {
        return LibSettlerHashing.computeOrderId(orderData, domainSeparator);
    }

    function _baseParams() internal pure returns (RolloverTypes.RolloverParams memory) {
        return RolloverTypes.RolloverParams({
            srcCstToken: address(0x1111),
            dstCstToken: address(0x2222),
            minCaReceived: 500e18,
            minSharesOut: 100e18,
            srcPoolId: bytes32(uint256(0xAA01)),
            dstPoolId: bytes32(uint256(0xAA02)),
            settler: address(0x3333),
            jitMarketHash: bytes32(uint256(0xAA03))
        });
    }

    function _baseOrder() internal pure returns (RolloverTypes.OrderData memory) {
        return RolloverTypes.OrderData({
            user: address(0xA1),
            settler: address(0xB1),
            fillerHint: address(0xC1),
            exclusiveFiller: address(0),
            srcCstToken: address(0x1111),
            dstCstToken: address(0x2222),
            premiumToken: address(0x3333),
            rolloverContract: address(0x4444),
            originChainId: uint64(1),
            destinationChainId: uint64(1),
            openDeadline: uint64(1_000_000),
            fillDeadline: uint64(2_000_000),
            orderSalt: uint64(42),
            orderSize: 1_000e18,
            minPremiumPerShare: 1e16,
            allowPartialFills: false,
            allowUnderfill: false,
            premiumPaymentMode: RolloverTypes.PREMIUM_PAYMENT_MODE_ATOMIC_ONLY,
            rolloverIntentHash: bytes32(uint256(0xDEAD)),
            rolloverParams: _baseParams()
        });
    }
    /// @notice Test domain.

    bytes32 internal constant TEST_DOMAIN = keccak256("TestDomain");

    /// @notice Pins behaviour: hash Rollover Params Deterministic.
    function test_HashRolloverParams_Deterministic() public view {
        RolloverTypes.RolloverParams memory p = _baseParams();
        bytes32 a = this.extHashRolloverParams(p);
        bytes32 b = this.extHashRolloverParams(p);
        assertEq(a, b);
    }

    /// @notice Pins behaviour: hash Rollover Params Binds Src Cst Token.
    function test_HashRolloverParams_BindsSrcCstToken() public view {
        RolloverTypes.RolloverParams memory p = _baseParams();
        bytes32 a = this.extHashRolloverParams(p);
        p.srcCstToken = address(0xFFFF);
        bytes32 b = this.extHashRolloverParams(p);
        assertTrue(a != b, "srcCstToken must be load-bearing");
    }

    /// @notice Pins behaviour: hash Rollover Params Binds Src Pool Id.
    function test_HashRolloverParams_BindsSrcPoolId() public view {
        RolloverTypes.RolloverParams memory p = _baseParams();
        bytes32 a = this.extHashRolloverParams(p);
        p.srcPoolId = bytes32(uint256(0xBB01));
        bytes32 b = this.extHashRolloverParams(p);
        assertTrue(a != b, "srcPoolId must be load-bearing");
    }

    /// @notice Pins behaviour: hash Rollover Params Binds Dst Pool Id.
    function test_HashRolloverParams_BindsDstPoolId() public view {
        RolloverTypes.RolloverParams memory p = _baseParams();
        bytes32 a = this.extHashRolloverParams(p);
        p.dstPoolId = bytes32(uint256(0xBB02));
        bytes32 b = this.extHashRolloverParams(p);
        assertTrue(a != b, "dstPoolId must be load-bearing");
    }

    /// @notice Pins behaviour: hash Rollover Params Binds Settler.
    function test_HashRolloverParams_BindsSettler() public view {
        RolloverTypes.RolloverParams memory p = _baseParams();
        bytes32 a = this.extHashRolloverParams(p);
        p.settler = address(0x4444);
        bytes32 b = this.extHashRolloverParams(p);
        assertTrue(a != b, "settler must be load-bearing");
    }

    /// @notice Pins behaviour: hash Rollover Params Binds JIT Market Hash.
    function test_HashRolloverParams_BindsJitMarketHash() public view {
        RolloverTypes.RolloverParams memory p = _baseParams();
        bytes32 a = this.extHashRolloverParams(p);
        p.jitMarketHash = bytes32(uint256(0xBB03));
        bytes32 b = this.extHashRolloverParams(p);
        assertTrue(a != b, "jitMarketHash must be load-bearing");
    }

    /// @notice Pins behaviour: hash Rollover Params Matches Manual Keccak.
    function test_HashRolloverParams_MatchesManualKeccak() public view {
        RolloverTypes.RolloverParams memory p = RolloverTypes.RolloverParams({
            srcCstToken: address(0x1111),
            dstCstToken: address(0x2222),
            minCaReceived: 0,
            minSharesOut: 0,
            srcPoolId: bytes32(0),
            dstPoolId: bytes32(0),
            settler: address(0),
            jitMarketHash: bytes32(0)
        });
        bytes32 expected = keccak256(
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
        assertEq(this.extHashRolloverParams(p), expected);
    }

    /// @notice Pins behaviour: hash Order Data Deterministic.
    function test_HashOrderData_Deterministic() public view {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        bytes32 a = this.extHashOrderData(orderData);
        bytes32 b = this.extHashOrderData(orderData);
        assertEq(a, b);
    }

    /// @notice Pins behaviour: hash Order Data Binds User.
    function test_HashOrderData_BindsUser() public view {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        bytes32 a = this.extHashOrderData(orderData);
        orderData.user = address(0xFFFF);
        bytes32 b = this.extHashOrderData(orderData);
        assertTrue(a != b, "user must be load-bearing");
    }

    /// @notice Pins behaviour: hash Order Data Binds Order Salt.
    function test_HashOrderData_BindsOrderSalt() public view {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        bytes32 a = this.extHashOrderData(orderData);
        orderData.orderSalt = orderData.orderSalt + 1;
        bytes32 b = this.extHashOrderData(orderData);
        assertTrue(a != b, "orderSalt must be load-bearing");
    }

    /// @notice Pins behaviour: hash Order Data Binds Rollover Params.
    function test_HashOrderData_BindsRolloverParams() public view {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        bytes32 a = this.extHashOrderData(orderData);
        orderData.rolloverParams.minSharesOut = orderData.rolloverParams.minSharesOut + 1;
        bytes32 b = this.extHashOrderData(orderData);
        assertTrue(a != b, "rolloverParams must be load-bearing in parent hash");
    }

    /// @notice Pins behaviour: hash Order Data Binds RolloverContract Intent Hash.
    function test_HashOrderData_BindsRolloverIntentHash() public view {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        bytes32 a = this.extHashOrderData(orderData);
        orderData.rolloverIntentHash = bytes32(uint256(0xBEEF));
        bytes32 b = this.extHashOrderData(orderData);
        assertTrue(a != b, "rolloverIntentHash must be load-bearing");
    }

    /// @notice Pins behaviour: compute Order Digest Deterministic.
    function test_ComputeOrderDigest_Deterministic() public view {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        bytes32 a = this.extComputeOrderDigest(orderData, TEST_DOMAIN);
        bytes32 b = this.extComputeOrderDigest(orderData, TEST_DOMAIN);
        assertEq(a, b);
    }

    /// @notice Pins behaviour: compute Order Digest Matches Eip712 Prefix.
    function test_ComputeOrderDigest_MatchesEip712Prefix() public view {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        bytes32 structHash = this.extHashOrderData(orderData);
        bytes32 expected = keccak256(abi.encodePacked(hex"1901", TEST_DOMAIN, structHash));
        assertEq(this.extComputeOrderDigest(orderData, TEST_DOMAIN), expected);
    }

    /// @notice Pins behaviour: compute Order Digest Binds Domain Separator.
    function test_ComputeOrderDigest_BindsDomainSeparator() public view {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        bytes32 domainA = keccak256("DomainA");
        bytes32 domainB = keccak256("DomainB");
        bytes32 a = this.extComputeOrderDigest(orderData, domainA);
        bytes32 b = this.extComputeOrderDigest(orderData, domainB);
        assertTrue(a != b, "domain separator must be load-bearing");
    }

    /// @notice Pins behaviour: compute Order Digest Binds Order Data.
    function test_ComputeOrderDigest_BindsOrderData() public view {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        bytes32 a = this.extComputeOrderDigest(orderData, TEST_DOMAIN);
        orderData.orderSalt = orderData.orderSalt + 1;
        bytes32 b = this.extComputeOrderDigest(orderData, TEST_DOMAIN);
        assertTrue(a != b, "order data must be load-bearing in digest");
    }

    /// @notice Pins behaviour: compute Order Digest Not Zero.
    function test_ComputeOrderDigest_NotZero() public view {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        bytes32 digest = this.extComputeOrderDigest(orderData, TEST_DOMAIN);
        assertTrue(digest != bytes32(0), "digest must not be zero");
    }

    /// @notice Pins behaviour: compute Order Id Deterministic.
    function test_ComputeOrderId_Deterministic() public view {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        bytes32 a = this.extComputeOrderId(orderData, TEST_DOMAIN);
        bytes32 b = this.extComputeOrderId(orderData, TEST_DOMAIN);
        assertEq(a, b);
    }

    /// @notice Pins behaviour: compute Order Id Equals Compute Order Digest.
    function test_ComputeOrderId_EqualsComputeOrderDigest() public view {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        bytes32 digest = this.extComputeOrderDigest(orderData, TEST_DOMAIN);
        bytes32 orderId = this.extComputeOrderId(orderData, TEST_DOMAIN);
        assertEq(orderId, digest, "orderId and orderDigest must be equal");
    }

    /// @notice Pins behaviour: compute Order Id Binds Domain Separator.
    function test_ComputeOrderId_BindsDomainSeparator() public view {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        bytes32 domainA = keccak256("DomainA");
        bytes32 domainB = keccak256("DomainB");
        bytes32 a = this.extComputeOrderId(orderData, domainA);
        bytes32 b = this.extComputeOrderId(orderData, domainB);
        assertTrue(a != b, "domain separator must be load-bearing in orderId");
    }

    /// @notice Pins behaviour: compute Order Id Binds Order Data.
    function test_ComputeOrderId_BindsOrderData() public view {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        bytes32 a = this.extComputeOrderId(orderData, TEST_DOMAIN);
        orderData.orderSize = orderData.orderSize + 1;
        bytes32 b = this.extComputeOrderId(orderData, TEST_DOMAIN);
        assertTrue(a != b, "order data must be load-bearing in orderId");
    }

    /// @notice Pins behaviour: compute Order Id Not Zero.
    function test_ComputeOrderId_NotZero() public view {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        bytes32 orderId = this.extComputeOrderId(orderData, TEST_DOMAIN);
        assertTrue(orderId != bytes32(0), "orderId must not be zero");
    }

    /// @notice Pins behaviour: hash Cancel Order Binds Nonce.
    function test_HashCancelOrder_BindsNonce() public pure {
        bytes32 orderId = bytes32(uint256(0xDEAD));
        bytes32 a = LibSettlerHashing.hashCancelOrder(orderId, 1);
        bytes32 b = LibSettlerHashing.hashCancelOrder(orderId, 2);
        assertTrue(a != b, "nonce must be load-bearing in cancel hash");
    }

    /// @notice Pins behaviour: hash Cancel Order Matches Manual Keccak.
    function test_HashCancelOrder_MatchesManualKeccak() public pure {
        bytes32 orderId = bytes32(uint256(0xCAFE));
        uint64 nonce = 99;
        bytes32 expected = keccak256(abi.encode(Typehashes.CANCEL_ORDER_TYPEHASH, orderId, nonce));
        assertEq(LibSettlerHashing.hashCancelOrder(orderId, nonce), expected);
    }
}
