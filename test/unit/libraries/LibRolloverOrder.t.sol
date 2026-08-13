// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";
import {
    LibRolloverOrder__BadOrderType,
    LibRolloverOrder__NonCanonicalOrderData
} from "src/errors/LibRolloverOrderErrors.sol";
import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import { LibRolloverOrder } from "src/libraries/LibRolloverOrder.sol";
import { Typehashes } from "src/libraries/Typehashes.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice LibRolloverOrderUnitTest — pins LibRolloverOrder behaviour for the Cork Rollover suite.
contract LibRolloverOrderUnitTest is Test {
    /// @notice  decode.
    /// @param g Generic input.
    /// @return Return value.
    function _decode(ERC7683Types.GaslessCrossChainOrder calldata g)
        external
        pure
        returns (RolloverTypes.OrderData memory)
    {
        return LibRolloverOrder.decodeOrderData(g);
    }

    /// @notice decode memory wrapper.
    /// @param g Generic input.
    /// @return Return value.
    function _decodeMemory(ERC7683Types.GaslessCrossChainOrder memory g)
        external
        pure
        returns (RolloverTypes.OrderData memory)
    {
        return LibRolloverOrder.decodeOrderDataMemory(g);
    }

    /// @notice External wrapper for testing the calldata-based resolved-order helper.
    /// @param orderData Decoded Cork order data.
    /// @param g ERC-7683 gasless order envelope.
    /// @param orderDigest Canonical settler order digest.
    /// @return Resolved ERC-7683 order.
    function _buildResolved(
        RolloverTypes.OrderData memory orderData,
        ERC7683Types.GaslessCrossChainOrder calldata g,
        bytes32 orderDigest
    ) external pure returns (ERC7683Types.ResolvedCrossChainOrder memory) {
        return LibRolloverOrder.buildResolvedOrder(orderData, g, orderDigest);
    }

    function _baseOd() internal pure returns (RolloverTypes.OrderData memory orderData) {
        orderData.user = address(0xA1);
        orderData.settler = address(0xCAFE0001);
        orderData.fillerHint = address(0xF1);
        orderData.exclusiveFiller = address(0);
        orderData.srcCstToken = address(0xCAFE0051);
        orderData.dstCstToken = address(0xD1);
        orderData.premiumToken = address(0xCAFE0091);
        orderData.rolloverContract = address(0xC1);
        orderData.originChainId = 1;
        orderData.destinationChainId = 1;
        orderData.openDeadline = 1000;
        orderData.fillDeadline = 2000;
        orderData.orderSalt = 1;
        orderData.orderSize = 1_000e18;
        orderData.minPremiumPerShare = 1e16;
        orderData.allowPartialFills = false;
        orderData.allowUnderfill = false;
        orderData.premiumPaymentMode = RolloverTypes.PREMIUM_PAYMENT_MODE_ATOMIC_ONLY;
        orderData.rolloverIntentHash = bytes32(uint256(0xCA));
        orderData.rolloverParams.srcCstToken = address(0xCAFE0051);
        orderData.rolloverParams.dstCstToken = address(0xD1);
        orderData.rolloverParams.minCaReceived = 0;
        orderData.rolloverParams.minSharesOut = 0;
    }

    function _gFor(RolloverTypes.OrderData memory orderData)
        internal
        pure
        returns (ERC7683Types.GaslessCrossChainOrder memory g)
    {
        g.originSettler = orderData.settler;
        g.user = orderData.user;
        g.nonce = orderData.orderSalt;
        g.originChainId = orderData.originChainId;
        g.openDeadline = uint32(orderData.openDeadline);
        g.fillDeadline = uint32(orderData.fillDeadline);
        g.orderDataType = Typehashes.ORDER_DATA_TYPEHASH;
        g.orderData = abi.encode(orderData);
    }

    /// @notice Pins behaviour: decode Order Data With Bad Type Reverts.
    function testRevert_decodeOrderDataWithBadTypeReverts() public {
        RolloverTypes.OrderData memory orderData = _baseOd();
        ERC7683Types.GaslessCrossChainOrder memory g = _gFor(orderData);
        g.orderDataType = keccak256("BadType");
        vm.expectRevert(LibRolloverOrder__BadOrderType.selector);
        this._decode(g);
    }

    /// @notice Old soft-version discriminators are rejected after the EIP-712 typehash cutover.
    function testRevert_decodeOrderDataWithV3TypeReverts() public {
        RolloverTypes.OrderData memory orderData = _baseOd();
        ERC7683Types.GaslessCrossChainOrder memory g = _gFor(orderData);
        g.orderDataType = keccak256("CorkRolloverOrderDataV3");
        vm.expectRevert(LibRolloverOrder__BadOrderType.selector);
        this._decode(g);
    }

    /// @notice The accepted order-data type matches the EIP-712 OrderData typehash.
    function test_corkOrderDataTypeMatchesOrderDataTypehash() public pure {
        assertEq(LibRolloverOrder.CORK_ORDER_DATA_TYPE, Typehashes.ORDER_DATA_TYPEHASH);
    }

    /// @notice Trailing bytes are rejected at the calldata decode boundary.
    function testRevert_decodeOrderDataRejectsTrailingBytes() public {
        RolloverTypes.OrderData memory orderData = _baseOd();
        ERC7683Types.GaslessCrossChainOrder memory g = _gFor(orderData);
        g.orderData = bytes.concat(g.orderData, hex"01");

        vm.expectRevert(LibRolloverOrder__NonCanonicalOrderData.selector);
        this._decode(g);
    }

    /// @notice Trailing bytes are rejected at the memory decode boundary.
    function testRevert_decodeOrderDataMemoryRejectsTrailingBytes() public {
        RolloverTypes.OrderData memory orderData = _baseOd();
        ERC7683Types.GaslessCrossChainOrder memory g = _gFor(orderData);
        g.orderData = bytes.concat(g.orderData, hex"01");

        vm.expectRevert(LibRolloverOrder__NonCanonicalOrderData.selector);
        this._decodeMemory(g);
    }

    /// @notice Pins behaviour: project Outputs Returns Single Max Spent And Min Received Rows.
    function test_projectOutputsReturnsSingleMaxSpentAndMinReceivedRows() public pure {
        RolloverTypes.OrderData memory orderData = _baseOd();
        orderData.rolloverParams.minSharesOut = 950e18;
        (ERC7683Types.Output[] memory ms, ERC7683Types.Output[] memory mr) =
            LibRolloverOrder.projectOutputs(orderData);
        assertEq(ms.length, 1, "single maxSpent row");
        assertEq(mr.length, 1, "single minReceived row");
        assertEq(ms[0].amount, orderData.orderSize);
        assertEq(mr[0].amount, orderData.rolloverParams.minSharesOut);
        assertEq(ms[0].recipient, bytes32(uint256(uint160(orderData.rolloverContract))));
        assertEq(mr[0].recipient, bytes32(0));
    }

    /// @notice A-1: `minReceived[0].amount` sourced from `rolloverParams.minSharesOut`, not `orderSize`.
    function test_projectOutputsMinReceivedAmountIsMinSharesOut() public pure {
        RolloverTypes.OrderData memory orderData = _baseOd();
        orderData.orderSize = 1_000e18;
        orderData.rolloverParams.minSharesOut = 950e18;
        (, ERC7683Types.Output[] memory mr) = LibRolloverOrder.projectOutputs(orderData);
        assertEq(mr[0].amount, 950e18, "minReceived amount = minSharesOut");
        assertTrue(mr[0].amount != orderData.orderSize, "amount diverged from orderSize");
    }

    /// @notice A-2: `minReceived[0].token` regression — dstCstToken unchanged.
    function test_projectOutputsMinReceivedTokenIsDstCstToken() public pure {
        RolloverTypes.OrderData memory orderData = _baseOd();
        orderData.rolloverParams.minSharesOut = 1;
        (, ERC7683Types.Output[] memory mr) = LibRolloverOrder.projectOutputs(orderData);
        assertEq(mr[0].token, bytes32(uint256(uint160(orderData.dstCstToken))), "dstCstToken pin");
    }

    /// @notice A-3: `maxSpent[0].amount` regression — srcCST side still tracks `orderSize`.
    function test_projectOutputsMaxSpentAmountIsOrderSize() public pure {
        RolloverTypes.OrderData memory orderData = _baseOd();
        orderData.orderSize = 1_234e18;
        orderData.rolloverParams.minSharesOut = 999e18;
        (ERC7683Types.Output[] memory ms,) = LibRolloverOrder.projectOutputs(orderData);
        assertEq(ms[0].amount, 1_234e18, "maxSpent amount = orderSize");
        assertEq(ms[0].token, bytes32(uint256(uint160(orderData.srcCstToken))), "srcCstToken pin");
    }

    /// @notice A-4: cross-decimal scenario — orderSize and minSharesOut diverge by exchange-rate factor.
    function test_projectOutputsCrossDecimalScenarioUsesMinSharesOut() public pure {
        RolloverTypes.OrderData memory orderData = _baseOd();
        orderData.orderSize = 1_000e18;
        orderData.rolloverParams.minSharesOut = 950e18;
        (ERC7683Types.Output[] memory ms, ERC7683Types.Output[] memory mr) =
            LibRolloverOrder.projectOutputs(orderData);
        assertEq(ms[0].amount, 1_000e18, "srcCST side = orderSize");
        assertEq(mr[0].amount, 950e18, "dstCST side = minSharesOut");
    }

    /// @notice A-1 corollary: `minSharesOut == 0` projects as 0 (cPT-holder-authorized unbounded slippage).
    function test_projectOutputsMinSharesOutZeroProjectsZero() public pure {
        RolloverTypes.OrderData memory orderData = _baseOd();
        orderData.orderSize = 1_000e18;
        orderData.rolloverParams.minSharesOut = 0;
        (, ERC7683Types.Output[] memory mr) = LibRolloverOrder.projectOutputs(orderData);
        assertEq(mr[0].amount, 0, "unbounded slippage projects 0");
    }

    /// @notice Pins resolved-order projection fields and encoded fill instruction payload.
    function test_buildResolvedOrderProjectsEnvelopeAndInstructions() public view {
        RolloverTypes.OrderData memory orderData = _baseOd();
        orderData.rolloverParams.minSharesOut = 950e18;
        ERC7683Types.GaslessCrossChainOrder memory g = _gFor(orderData);
        bytes32 orderDigest = bytes32(uint256(0xD16E57));

        ERC7683Types.ResolvedCrossChainOrder memory resolved =
            this._buildResolved(orderData, g, orderDigest);

        assertEq(resolved.user, g.user);
        assertEq(resolved.originChainId, g.originChainId);
        assertEq(resolved.openDeadline, g.openDeadline);
        assertEq(resolved.fillDeadline, g.fillDeadline);
        assertEq(resolved.orderId, orderDigest);
        assertEq(resolved.maxSpent.length, 1);
        assertEq(resolved.minReceived.length, 1);
        assertEq(resolved.fillInstructions.length, 1);
        assertEq(resolved.maxSpent[0].amount, orderData.orderSize);
        assertEq(resolved.minReceived[0].amount, orderData.rolloverParams.minSharesOut);
        assertEq(
            resolved.maxSpent[0].recipient, bytes32(uint256(uint160(orderData.rolloverContract)))
        );
        assertEq(resolved.minReceived[0].recipient, bytes32(0));
        assertEq(resolved.fillInstructions[0].destinationChainId, orderData.destinationChainId);
        assertEq(
            resolved.fillInstructions[0].destinationSettler,
            bytes32(uint256(uint160(orderData.settler)))
        );
        ERC7683Types.GaslessCrossChainOrder memory encodedOrder = abi.decode(
            resolved.fillInstructions[0].originData, (ERC7683Types.GaslessCrossChainOrder)
        );
        RolloverTypes.OrderData memory encodedData =
            abi.decode(encodedOrder.orderData, (RolloverTypes.OrderData));
        assertEq(encodedOrder.user, g.user);
        assertEq(encodedData.orderSalt, orderData.orderSalt);
    }

    /// @notice Pins behaviour: fuzzes order Data Decode Round Trip Preserves All Fields.
    /// @param nonce Nonce.
    /// @param openDl Open deadline (Unix timestamp).
    /// @param size Fill size (raw units).
    function testFuzz_orderDataDecodeRoundTripPreservesAllFields(
        uint64 nonce,
        uint64 openDl,
        uint256 size
    ) public view {
        if (openDl < 100) {
            openDl = 100;
        }
        if (openDl > 1e9) {
            openDl = uint64(openDl % 1e9) + 100;
        }
        if (size == 0) {
            size = 1;
        }
        RolloverTypes.OrderData memory orderData = _baseOd();
        orderData.orderSalt = nonce;
        orderData.openDeadline = openDl;
        orderData.fillDeadline = openDl + 100;
        orderData.orderSize = size;
        ERC7683Types.GaslessCrossChainOrder memory g = _gFor(orderData);
        RolloverTypes.OrderData memory decoded = this._decode(g);
        assertEq(decoded.orderSalt, nonce);
        assertEq(decoded.openDeadline, openDl);
        assertEq(decoded.orderSize, size);
        assertEq(decoded.user, orderData.user);
    }

    /// @notice Pins behaviour: fuzzes project Outputs Amount Scales Linearly With Order Size and minSharesOut.
    /// @param size Fill size (raw units, srcCST-denominated).
    /// @param minOut Minimum-out (raw units, dstCST-denominated).
    function testFuzz_projectOutputsAmountScalesLinearlyWithOrderSize(uint128 size, uint128 minOut)
        public
        pure
    {
        if (size == 0) {
            size = 1;
        }
        RolloverTypes.OrderData memory orderData = _baseOd();
        orderData.orderSize = uint256(size);
        orderData.rolloverParams.minSharesOut = uint256(minOut);
        (ERC7683Types.Output[] memory ms, ERC7683Types.Output[] memory mr) =
            LibRolloverOrder.projectOutputs(orderData);
        assertEq(ms[0].amount, uint256(size));
        assertEq(mr[0].amount, uint256(minOut));
    }
}
