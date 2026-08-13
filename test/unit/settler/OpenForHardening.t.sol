// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";

import { BaseSettler } from "src/BaseSettler.sol";
import { ExactSettler as Settler } from "src/ExactSettler.sol";
import {
    Settler__FillDeadlineExceedsPoolExpiry,
    Settler__OrderInTerminalState,
    Settler__OrderSaltMismatch,
    Settler__OriginChainIdMismatch,
    Settler__OriginSettlerMismatch,
    Settler__RolloverContractNotDeployed,
    Settler__RolloverParamsDstCstMismatch,
    Settler__RolloverParamsSrcCstMismatch,
    Settler__SelfExclusiveFiller,
    Settler__SettlerMismatch,
    Settler__UserMismatch,
    Settler__WrongDestinationChain,
    Settler__ZeroDstCstToken,
    Settler__ZeroOrderSize,
    Settler__ZeroRolloverIntentHash,
    Settler__ZeroSrcCstToken
} from "src/errors/SettlerErrors.sol";
import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice OpenForHardeningTest — pins OpenForHardening behaviour for the Cork Rollover suite.
contract OpenForHardeningTest is BaseTest {
    function _buildAndSign(RolloverTypes.OrderData memory orderData)
        internal
        view
        returns (ERC7683Types.GaslessCrossChainOrder memory g, bytes memory sig)
    {
        g = _gasless(orderData);
        sig = _signOrder(cptHolderPk, orderData);
    }

    function _emptyBytes() internal pure returns (bytes memory) {
        bytes memory empty;
        return empty;
    }

    function _orderForModeWithSalt(SettlerMode mode, uint64 salt)
        internal
        view
        returns (RolloverTypes.OrderData memory orderData)
    {
        orderData = _orderForMode(mode);
        orderData.orderSalt = salt;
    }

    /// @notice Shared `_validateOrderCommon` admission matrix across exact and partial settlers.
    function test_openFor_sharedValidationMatrix_exactAndPartial() public {
        _assertSharedValidationMatrix(SettlerMode.Exact, 1000);
        _assertSharedValidationMatrix(SettlerMode.Partial, 2000);
    }

    function _assertSharedValidationMatrix(SettlerMode mode, uint64 saltBase) internal {
        _assertEnvelopeOriginSettlerMismatch(mode, saltBase + 1);
        _assertEnvelopeUserMismatch(mode, saltBase + 2);
        _assertEnvelopeNonceMismatch(mode, saltBase + 3);
        _assertEnvelopeOriginChainMismatch(mode, saltBase + 4);
        _assertPayloadSettlerMismatch(mode, saltBase + 5);
        _assertSelfExclusiveFiller(mode, saltBase + 6);
        _assertZeroOrderSizeRevert(mode, saltBase + 7);
        _assertZeroSrcCstRevert(mode, saltBase + 8);
        _assertZeroDstCstRevert(mode, saltBase + 9);
        _assertZeroRolloverIntentHashRevert(mode, saltBase + 10);
        _assertSrcPoolExpiryRevert(mode, saltBase + 11);
        _assertDstPoolExpiryRevert(mode, saltBase + 12);
        _assertPoolExpiryRevertArgs(mode, saltBase + 13);
        _assertRolloverContractBindingRevert(mode, saltBase + 14);
        _assertRolloverParamsSrcCstMismatch(mode, saltBase + 15);
        _assertRolloverParamsDstCstMismatch(mode, saltBase + 16);
        _assertRolloverParamsMismatchPrecedesPoolExpiry(mode, saltBase + 17);
        _assertWrongDestinationChain(mode, saltBase + 18);
        _assertValidOrderAcceptance(mode, saltBase + 19);
        _assertOpenIdempotency(mode, saltBase + 20);
        _assertTerminalReopenRevert(mode, saltBase + 21);
        _assertOpenSelfSubmitted(mode, saltBase + 22);
        _assertResolve(mode, saltBase + 23);
    }

    function _assertEnvelopeOriginSettlerMismatch(SettlerMode mode, uint64 salt) internal {
        RolloverTypes.OrderData memory orderData = _orderForModeWithSalt(mode, salt);
        (ERC7683Types.GaslessCrossChainOrder memory g, bytes memory sig) = _buildAndSign(orderData);
        g.originSettler = address(0xBEEF);

        vm.expectRevert(Settler__OriginSettlerMismatch.selector);
        _settlerForMode(mode).openFor(g, sig, _emptyBytes());
    }

    function _assertEnvelopeUserMismatch(SettlerMode mode, uint64 salt) internal {
        RolloverTypes.OrderData memory orderData = _orderForModeWithSalt(mode, salt);
        (ERC7683Types.GaslessCrossChainOrder memory g, bytes memory sig) = _buildAndSign(orderData);
        g.user = address(0xBEEF);

        vm.expectRevert(Settler__UserMismatch.selector);
        _settlerForMode(mode).openFor(g, sig, _emptyBytes());
    }

    function _assertEnvelopeNonceMismatch(SettlerMode mode, uint64 salt) internal {
        RolloverTypes.OrderData memory orderData = _orderForModeWithSalt(mode, salt);
        (ERC7683Types.GaslessCrossChainOrder memory g, bytes memory sig) = _buildAndSign(orderData);
        g.nonce = orderData.orderSalt + 1;

        vm.expectRevert(Settler__OrderSaltMismatch.selector);
        _settlerForMode(mode).openFor(g, sig, _emptyBytes());
    }

    function _assertEnvelopeOriginChainMismatch(SettlerMode mode, uint64 salt) internal {
        RolloverTypes.OrderData memory orderData = _orderForModeWithSalt(mode, salt);
        (ERC7683Types.GaslessCrossChainOrder memory g, bytes memory sig) = _buildAndSign(orderData);
        g.originChainId = orderData.originChainId + 1;

        vm.expectRevert(Settler__OriginChainIdMismatch.selector);
        _settlerForMode(mode).openFor(g, sig, _emptyBytes());
    }

    function _assertPayloadSettlerMismatch(SettlerMode mode, uint64 salt) internal {
        RolloverTypes.OrderData memory orderData = _orderForModeWithSalt(mode, salt);
        orderData.settler = address(0xABCD);
        (ERC7683Types.GaslessCrossChainOrder memory g, bytes memory sig) = _buildAndSign(orderData);

        vm.expectRevert(Settler__SettlerMismatch.selector);
        _settlerForMode(mode).openFor(g, sig, _emptyBytes());
    }

    function _assertSelfExclusiveFiller(SettlerMode mode, uint64 salt) internal {
        RolloverTypes.OrderData memory orderData = _orderForModeWithSalt(mode, salt);
        orderData.exclusiveFiller = _settlerAddressForMode(mode);
        (ERC7683Types.GaslessCrossChainOrder memory g, bytes memory sig) = _buildAndSign(orderData);

        vm.expectRevert(Settler__SelfExclusiveFiller.selector);
        _settlerForMode(mode).openFor(g, sig, _emptyBytes());
    }

    function _assertZeroOrderSizeRevert(SettlerMode mode, uint64 salt) internal {
        RolloverTypes.OrderData memory orderData = _orderForModeWithSalt(mode, salt);
        orderData.orderSize = 0;
        (ERC7683Types.GaslessCrossChainOrder memory g, bytes memory sig) = _buildAndSign(orderData);

        vm.expectRevert(Settler__ZeroOrderSize.selector);
        _settlerForMode(mode).openFor(g, sig, _emptyBytes());
    }

    function _assertZeroSrcCstRevert(SettlerMode mode, uint64 salt) internal {
        RolloverTypes.OrderData memory orderData = _orderForModeWithSalt(mode, salt);
        orderData.srcCstToken = address(0);
        orderData.rolloverParams.srcCstToken = address(0);
        (ERC7683Types.GaslessCrossChainOrder memory g, bytes memory sig) = _buildAndSign(orderData);

        vm.expectRevert(Settler__ZeroSrcCstToken.selector);
        _settlerForMode(mode).openFor(g, sig, _emptyBytes());
    }

    function _assertZeroDstCstRevert(SettlerMode mode, uint64 salt) internal {
        RolloverTypes.OrderData memory orderData = _orderForModeWithSalt(mode, salt);
        orderData.dstCstToken = address(0);
        orderData.rolloverParams.dstCstToken = address(0);
        (ERC7683Types.GaslessCrossChainOrder memory g, bytes memory sig) = _buildAndSign(orderData);

        vm.expectRevert(Settler__ZeroDstCstToken.selector);
        _settlerForMode(mode).openFor(g, sig, _emptyBytes());
    }

    function _assertZeroRolloverIntentHashRevert(SettlerMode mode, uint64 salt) internal {
        RolloverTypes.OrderData memory orderData = _orderForModeWithSalt(mode, salt);
        orderData.rolloverIntentHash = bytes32(0);
        (ERC7683Types.GaslessCrossChainOrder memory g, bytes memory sig) = _buildAndSign(orderData);

        vm.expectRevert(Settler__ZeroRolloverIntentHash.selector);
        _settlerForMode(mode).openFor(g, sig, _emptyBytes());
    }

    function _assertSrcPoolExpiryRevert(SettlerMode mode, uint64 salt) internal {
        RolloverTypes.OrderData memory orderData = _orderForModeWithSalt(mode, salt);
        srcCst.setExpiry(uint256(orderData.fillDeadline));
        (ERC7683Types.GaslessCrossChainOrder memory g, bytes memory sig) = _buildAndSign(orderData);

        vm.expectRevert();
        _settlerForMode(mode).openFor(g, sig, _emptyBytes());
        srcCst.setExpiry(type(uint256).max);
    }

    function _assertDstPoolExpiryRevert(SettlerMode mode, uint64 salt) internal {
        RolloverTypes.OrderData memory orderData = _orderForModeWithSalt(mode, salt);
        dstCst.setExpiry(uint256(orderData.fillDeadline) - 1);
        (ERC7683Types.GaslessCrossChainOrder memory g, bytes memory sig) = _buildAndSign(orderData);

        vm.expectRevert();
        _settlerForMode(mode).openFor(g, sig, _emptyBytes());
        dstCst.setExpiry(type(uint256).max);
    }

    function _assertPoolExpiryRevertArgs(SettlerMode mode, uint64 salt) internal {
        RolloverTypes.OrderData memory orderData = _orderForModeWithSalt(mode, salt);
        uint256 srcExpiry = uint256(orderData.fillDeadline) + 100;
        uint256 dstExpiry = uint256(orderData.fillDeadline);
        srcCst.setExpiry(srcExpiry);
        dstCst.setExpiry(dstExpiry);
        (ERC7683Types.GaslessCrossChainOrder memory g, bytes memory sig) = _buildAndSign(orderData);

        vm.expectRevert(
            abi.encodeWithSelector(
                Settler__FillDeadlineExceedsPoolExpiry.selector,
                orderData.fillDeadline,
                srcExpiry,
                dstExpiry
            )
        );
        _settlerForMode(mode).openFor(g, sig, _emptyBytes());
        srcCst.setExpiry(type(uint256).max);
        dstCst.setExpiry(type(uint256).max);
    }

    function _assertRolloverContractBindingRevert(SettlerMode mode, uint64 salt) internal {
        RolloverTypes.OrderData memory orderData = _orderForModeWithSalt(mode, salt);
        orderData.rolloverContract = address(0xDEAD);
        (ERC7683Types.GaslessCrossChainOrder memory g, bytes memory sig) = _buildAndSign(orderData);

        vm.expectRevert(
            abi.encodeWithSelector(Settler__RolloverContractNotDeployed.selector, orderData.user)
        );
        _settlerForMode(mode).openFor(g, sig, _emptyBytes());
    }

    function _assertRolloverParamsSrcCstMismatch(SettlerMode mode, uint64 salt) internal {
        RolloverTypes.OrderData memory orderData = _orderForModeWithSalt(mode, salt);
        orderData.rolloverParams.srcCstToken = address(0xCAFE);
        (ERC7683Types.GaslessCrossChainOrder memory g, bytes memory sig) = _buildAndSign(orderData);

        vm.expectRevert(Settler__RolloverParamsSrcCstMismatch.selector);
        _settlerForMode(mode).openFor(g, sig, _emptyBytes());
    }

    function _assertRolloverParamsDstCstMismatch(SettlerMode mode, uint64 salt) internal {
        RolloverTypes.OrderData memory orderData = _orderForModeWithSalt(mode, salt);
        orderData.rolloverParams.dstCstToken = address(0xCAFE);
        (ERC7683Types.GaslessCrossChainOrder memory g, bytes memory sig) = _buildAndSign(orderData);

        vm.expectRevert(Settler__RolloverParamsDstCstMismatch.selector);
        _settlerForMode(mode).openFor(g, sig, _emptyBytes());
    }

    function _assertRolloverParamsMismatchPrecedesPoolExpiry(SettlerMode mode, uint64 salt)
        internal
    {
        RolloverTypes.OrderData memory srcMismatch = _orderForModeWithSalt(mode, salt);
        srcMismatch.rolloverParams.srcCstToken = address(0xCAFE);
        srcCst.setExpiry(uint256(srcMismatch.fillDeadline));
        (ERC7683Types.GaslessCrossChainOrder memory gSrc, bytes memory sigSrc) =
            _buildAndSign(srcMismatch);

        vm.expectRevert(Settler__RolloverParamsSrcCstMismatch.selector);
        _settlerForMode(mode).openFor(gSrc, sigSrc, _emptyBytes());
        srcCst.setExpiry(type(uint256).max);

        RolloverTypes.OrderData memory dstMismatch = _orderForModeWithSalt(mode, salt + 1);
        dstMismatch.rolloverParams.dstCstToken = address(0xCAFE);
        dstCst.setExpiry(uint256(dstMismatch.fillDeadline));
        (ERC7683Types.GaslessCrossChainOrder memory gDst, bytes memory sigDst) =
            _buildAndSign(dstMismatch);

        vm.expectRevert(Settler__RolloverParamsDstCstMismatch.selector);
        _settlerForMode(mode).openFor(gDst, sigDst, _emptyBytes());
        dstCst.setExpiry(type(uint256).max);
    }

    function _assertWrongDestinationChain(SettlerMode mode, uint64 salt) internal {
        RolloverTypes.OrderData memory orderData = _orderForModeWithSalt(mode, salt);
        orderData.destinationChainId = uint64(block.chainid) + 1;
        (ERC7683Types.GaslessCrossChainOrder memory g, bytes memory sig) = _buildAndSign(orderData);

        vm.expectRevert(Settler__WrongDestinationChain.selector);
        _settlerForMode(mode).openFor(g, sig, _emptyBytes());
    }

    function _assertValidOrderAcceptance(SettlerMode mode, uint64 salt) internal {
        RolloverTypes.OrderData memory orderData = _orderForModeWithSalt(mode, salt);
        (ERC7683Types.GaslessCrossChainOrder memory g, bytes memory sig) = _buildAndSign(orderData);

        _settlerForMode(mode).openFor(g, sig, _emptyBytes());
        bytes32 digest = _orderDigest(orderData);
        assertEq(
            uint8(_settlerForMode(mode).orderStatus(digest)),
            uint8(RolloverTypes.OrderStatus.Opened)
        );
    }

    function _assertOpenIdempotency(SettlerMode mode, uint64 salt) internal {
        RolloverTypes.OrderData memory orderData = _orderForModeWithSalt(mode, salt);
        (ERC7683Types.GaslessCrossChainOrder memory g, bytes memory sig) = _buildAndSign(orderData);

        _settlerForMode(mode).openFor(g, sig, _emptyBytes());
        _settlerForMode(mode).openFor(g, sig, _emptyBytes());

        assertEq(
            uint8(_settlerForMode(mode).orderStatus(_orderDigest(orderData))),
            uint8(RolloverTypes.OrderStatus.Opened)
        );
    }

    function _assertTerminalReopenRevert(SettlerMode mode, uint64 salt) internal {
        RolloverTypes.OrderData memory orderData = _orderForModeWithSalt(mode, salt);
        (ERC7683Types.GaslessCrossChainOrder memory g, bytes memory sig) = _buildAndSign(orderData);

        _settlerForMode(mode).openFor(g, sig, _emptyBytes());
        bytes32 digest = _orderDigest(orderData);
        bytes memory cancelSig =
            _signCancelFor(orderData.settler, cptHolderPk, digest, orderData.orderSalt);
        _settlerForMode(mode).cancel(digest, _originData(orderData), cancelSig);

        vm.expectRevert(Settler__OrderInTerminalState.selector);
        _settlerForMode(mode).openFor(g, sig, _emptyBytes());
    }

    function _assertOpenSelfSubmitted(SettlerMode mode, uint64 salt) internal {
        RolloverTypes.OrderData memory orderData = _orderForModeWithSalt(mode, salt);
        (ERC7683Types.GaslessCrossChainOrder memory g, bytes memory sig) = _buildAndSign(orderData);

        vm.prank(cptHolder);
        _settlerForMode(mode).openFor(g, sig, "");

        assertEq(
            uint8(_settlerForMode(mode).orderStatus(_orderDigest(orderData))),
            uint8(RolloverTypes.OrderStatus.Opened)
        );
    }

    function _assertResolve(SettlerMode mode, uint64 salt) internal view {
        RolloverTypes.OrderData memory orderData = _orderForModeWithSalt(mode, salt);
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);

        ERC7683Types.ResolvedCrossChainOrder memory resolved =
            _settlerForMode(mode).resolveFor(g, "");
        assertEq(resolved.user, orderData.user);
        assertEq(resolved.originChainId, orderData.originChainId);
        assertEq(resolved.openDeadline, uint32(orderData.openDeadline));
        assertEq(resolved.fillDeadline, uint32(orderData.fillDeadline));
    }

    /// @notice Pins behaviour: open For reverts On Envelope Origin Settler Mismatch.
    function test_openFor_revertsOnEnvelopeOriginSettlerMismatch() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        (ERC7683Types.GaslessCrossChainOrder memory g, bytes memory sig) = _buildAndSign(orderData);
        g.originSettler = address(0xBEEF);

        vm.expectRevert(Settler__OriginSettlerMismatch.selector);
        settler.openFor(g, sig, _emptyBytes());
    }

    /// @notice Pins behaviour: open For reverts On Envelope User Mismatch.
    function test_openFor_revertsOnEnvelopeUserMismatch() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        (ERC7683Types.GaslessCrossChainOrder memory g, bytes memory sig) = _buildAndSign(orderData);
        g.user = address(0xBEEF);

        vm.expectRevert(Settler__UserMismatch.selector);
        settler.openFor(g, sig, _emptyBytes());
    }

    /// @notice Pins behaviour: open For reverts On Envelope Nonce Mismatch.
    function test_openFor_revertsOnEnvelopeNonceMismatch() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        (ERC7683Types.GaslessCrossChainOrder memory g, bytes memory sig) = _buildAndSign(orderData);
        g.nonce = orderData.orderSalt + 1;

        vm.expectRevert(Settler__OrderSaltMismatch.selector);
        settler.openFor(g, sig, _emptyBytes());
    }

    /// @notice Pins behaviour: open For reverts On Envelope Origin Chain Id Mismatch.
    function test_openFor_revertsOnEnvelopeOriginChainIdMismatch() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        (ERC7683Types.GaslessCrossChainOrder memory g, bytes memory sig) = _buildAndSign(orderData);
        g.originChainId = orderData.originChainId + 1;

        vm.expectRevert(Settler__OriginChainIdMismatch.selector);
        settler.openFor(g, sig, _emptyBytes());
    }

    /// @notice Pins behaviour: open For reverts On Payload Settler Mismatch.
    function test_openFor_revertsOnPayloadSettlerMismatch() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.settler = address(0xABCD);

        (ERC7683Types.GaslessCrossChainOrder memory g, bytes memory sig) = _buildAndSign(orderData);

        vm.expectRevert(Settler__SettlerMismatch.selector);
        settler.openFor(g, sig, _emptyBytes());
    }

    /// @notice Pins behaviour: open For reverts On Self Exclusive Filler.
    function test_openFor_revertsOnSelfExclusiveFiller() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.exclusiveFiller = address(settler);
        (ERC7683Types.GaslessCrossChainOrder memory g, bytes memory sig) = _buildAndSign(orderData);

        vm.expectRevert(Settler__SelfExclusiveFiller.selector);
        settler.openFor(g, sig, _emptyBytes());
    }

    /// @notice Pins behaviour: open For reverts On Zero Order Size.
    function test_openFor_revertsOnZeroOrderSize() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = 0;
        (ERC7683Types.GaslessCrossChainOrder memory g, bytes memory sig) = _buildAndSign(orderData);

        vm.expectRevert(Settler__ZeroOrderSize.selector);
        settler.openFor(g, sig, _emptyBytes());
    }

    /// @notice Pins behaviour: open For reverts On Zero Src Cst Token.
    function test_openFor_revertsOnZeroSrcCstToken() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.srcCstToken = address(0);
        orderData.rolloverParams.srcCstToken = address(0);
        (ERC7683Types.GaslessCrossChainOrder memory g, bytes memory sig) = _buildAndSign(orderData);

        vm.expectRevert(Settler__ZeroSrcCstToken.selector);
        settler.openFor(g, sig, _emptyBytes());
    }

    /// @notice Pins behaviour: open For reverts On Zero Dst Cst Token.
    function test_openFor_revertsOnZeroDstCstToken() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.dstCstToken = address(0);
        orderData.rolloverParams.dstCstToken = address(0);
        (ERC7683Types.GaslessCrossChainOrder memory g, bytes memory sig) = _buildAndSign(orderData);

        vm.expectRevert(Settler__ZeroDstCstToken.selector);
        settler.openFor(g, sig, _emptyBytes());
    }

    /// @notice Pins behaviour: open For reverts On Zero RolloverContract Intent Hash.
    function test_openFor_revertsOnZeroRolloverIntentHash() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.rolloverIntentHash = bytes32(0);
        (ERC7683Types.GaslessCrossChainOrder memory g, bytes memory sig) = _buildAndSign(orderData);

        vm.expectRevert(Settler__ZeroRolloverIntentHash.selector);
        settler.openFor(g, sig, _emptyBytes());
    }

    /// @notice Pins behaviour: open For reverts On Fill Deadline At Src Pool Expiry.
    function test_openFor_revertsOnFillDeadlineAtSrcPoolExpiry() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();

        srcCst.setExpiry(uint256(orderData.fillDeadline));
        (ERC7683Types.GaslessCrossChainOrder memory g, bytes memory sig) = _buildAndSign(orderData);

        vm.expectRevert();
        settler.openFor(g, sig, _emptyBytes());
    }

    /// @notice Pins behaviour: open For reverts On Fill Deadline After Dst Pool Expiry.
    function test_openFor_revertsOnFillDeadlineAfterDstPoolExpiry() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        dstCst.setExpiry(uint256(orderData.fillDeadline) - 1);
        (ERC7683Types.GaslessCrossChainOrder memory g, bytes memory sig) = _buildAndSign(orderData);

        vm.expectRevert();
        settler.openFor(g, sig, _emptyBytes());
    }

    /// @notice Pins behaviour: open For accepts Order With Fill Deadline Before Both Pool Expiries.
    function test_openFor_acceptsOrderWithFillDeadlineBeforeBothPoolExpiries() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        srcCst.setExpiry(uint256(orderData.fillDeadline) + 1);
        dstCst.setExpiry(uint256(orderData.fillDeadline) + 1);
        (ERC7683Types.GaslessCrossChainOrder memory g, bytes memory sig) = _buildAndSign(orderData);

        settler.openFor(g, sig, _emptyBytes());
        bytes32 digest = _orderDigest(orderData);
        assertEq(uint8(settler.orderStatus(digest)), uint8(RolloverTypes.OrderStatus.Opened));
    }

    /// @notice Pins behaviour: open For reverts With Correct Error Args.
    function test_openFor_revertsWithCorrectErrorArgs() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        uint256 srcExpiry = uint256(orderData.fillDeadline) + 100;
        uint256 dstExpiry = uint256(orderData.fillDeadline);
        srcCst.setExpiry(srcExpiry);
        dstCst.setExpiry(dstExpiry);
        (ERC7683Types.GaslessCrossChainOrder memory g, bytes memory sig) = _buildAndSign(orderData);

        vm.expectRevert(
            abi.encodeWithSelector(
                Settler__FillDeadlineExceedsPoolExpiry.selector,
                orderData.fillDeadline,
                srcExpiry,
                dstExpiry
            )
        );
        settler.openFor(g, sig, _emptyBytes());
    }

    /// @notice Pins behaviour: open For reverts On Unattested RolloverContract.
    function test_openFor_revertsOnUnattestedRolloverContract() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.rolloverContract = address(0xDEAD);
        (ERC7683Types.GaslessCrossChainOrder memory g, bytes memory sig) = _buildAndSign(orderData);

        vm.expectRevert(
            abi.encodeWithSelector(Settler__RolloverContractNotDeployed.selector, orderData.user)
        );
        settler.openFor(g, sig, _emptyBytes());
    }

    /// @notice Pins behaviour: open For reverts On Zero RolloverContract.
    function test_openFor_revertsOnZeroRolloverContract() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.rolloverContract = address(0);
        (ERC7683Types.GaslessCrossChainOrder memory g, bytes memory sig) = _buildAndSign(orderData);

        vm.expectRevert(
            abi.encodeWithSelector(Settler__RolloverContractNotDeployed.selector, orderData.user)
        );
        settler.openFor(g, sig, _emptyBytes());
    }

    /// @notice Pins behaviour: open For reverts On Rollover Params Src Cst Mismatch.
    function test_openFor_revertsOnRolloverParamsSrcCstMismatch() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.rolloverParams.srcCstToken = address(0xCAFE);
        (ERC7683Types.GaslessCrossChainOrder memory g, bytes memory sig) = _buildAndSign(orderData);

        vm.expectRevert(Settler__RolloverParamsSrcCstMismatch.selector);
        settler.openFor(g, sig, _emptyBytes());
    }

    /// @notice Pins behaviour: open For reverts On Rollover Params Dst Cst Mismatch.
    function test_openFor_revertsOnRolloverParamsDstCstMismatch() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.rolloverParams.dstCstToken = address(0xCAFE);
        (ERC7683Types.GaslessCrossChainOrder memory g, bytes memory sig) = _buildAndSign(orderData);

        vm.expectRevert(Settler__RolloverParamsDstCstMismatch.selector);
        settler.openFor(g, sig, _emptyBytes());
    }

    /// @notice Pins behaviour: open For reverts On Wrong Destination Chain.
    function test_openFor_revertsOnWrongDestinationChain() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.destinationChainId = uint64(block.chainid) + 1;
        (ERC7683Types.GaslessCrossChainOrder memory g, bytes memory sig) = _buildAndSign(orderData);

        vm.expectRevert(Settler__WrongDestinationChain.selector);
        settler.openFor(g, sig, _emptyBytes());
    }

    /// @notice Pins behaviour: open For accepts Valid Order unchanged.
    function test_openFor_acceptsValidOrder_unchanged() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        (ERC7683Types.GaslessCrossChainOrder memory g, bytes memory sig) = _buildAndSign(orderData);

        settler.openFor(g, sig, _emptyBytes());
        bytes32 digest = _orderDigest(orderData);
        assertEq(uint8(settler.orderStatus(digest)), uint8(RolloverTypes.OrderStatus.Opened));
    }

    /// @notice Pins behaviour: open For idempotency unchanged.
    function test_openFor_idempotency_unchanged() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        (ERC7683Types.GaslessCrossChainOrder memory g, bytes memory sig) = _buildAndSign(orderData);

        settler.openFor(g, sig, _emptyBytes());

        settler.openFor(g, sig, _emptyBytes());
        bytes32 digest = _orderDigest(orderData);
        assertEq(uint8(settler.orderStatus(digest)), uint8(RolloverTypes.OrderStatus.Opened));
    }

    /// @notice Pins behaviour: open For terminal Status still Reverts.
    function test_openFor_terminalStatus_stillReverts() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        (ERC7683Types.GaslessCrossChainOrder memory g, bytes memory sig) = _buildAndSign(orderData);

        settler.openFor(g, sig, _emptyBytes());

        bytes32 digest = _orderDigest(orderData);
        bytes memory cancelSig =
            _signCancelFor(orderData.settler, cptHolderPk, digest, orderData.orderSalt);
        bytes memory originData = _originData(orderData);
        settler.cancel(digest, originData, cancelSig);
        assertEq(uint8(settler.orderStatus(digest)), uint8(RolloverTypes.OrderStatus.Cancelled));

        vm.expectRevert(Settler__OrderInTerminalState.selector);
        settler.openFor(g, sig, _emptyBytes());
    }

    /// @notice Pins behaviour: open accepts Order With Self Submitted Sig.
    function test_open_acceptsOrderWithSelfSubmittedSig() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        (ERC7683Types.GaslessCrossChainOrder memory g, bytes memory sig) = _buildAndSign(orderData);

        vm.prank(cptHolder);
        settler.openFor(g, sig, "");
        bytes32 digest = _orderDigest(orderData);
        assertEq(uint8(settler.orderStatus(digest)), uint8(RolloverTypes.OrderStatus.Opened));
    }

    /// @notice Pins behaviour: resolve outputs Built From Order Data or Envelope Matching.
    function test_resolve_outputsBuiltFromOrderData_orEnvelopeMatching() public view {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);

        ERC7683Types.ResolvedCrossChainOrder memory resolved = settler.resolveFor(g, "");
        assertEq(resolved.user, orderData.user);
        assertEq(resolved.originChainId, orderData.originChainId);
        assertEq(resolved.openDeadline, uint32(orderData.openDeadline));
        assertEq(resolved.fillDeadline, uint32(orderData.fillDeadline));
    }
}
