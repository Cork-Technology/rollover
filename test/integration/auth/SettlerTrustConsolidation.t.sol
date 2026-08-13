// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {
    CorkRolloverContractFactory__SettlerNotApproved
} from "src/errors/CorkRolloverContractFactoryErrors.sol";

import { BaseTest } from "../../base/BaseTest.sol";
import { FillScaffold } from "../../base/FillScaffold.sol";
import { BaseSettler } from "src/BaseSettler.sol";
import { CorkRolloverContract } from "src/CorkRolloverContract.sol";
import { CorkRolloverContractFactory } from "src/CorkRolloverContractFactory.sol";
import { Settler__RolloverParamsSettlerMismatch } from "src/errors/SettlerErrors.sol";
import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import {
    ICorkRolloverContractFactory
} from "src/interfaces/rollover/ICorkRolloverContractFactory.sol";
import { IRolloverHookDispatcher } from "src/interfaces/rollover/IRolloverHookDispatcher.sol";
import { Typehashes } from "src/libraries/Typehashes.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice Settler trust-config reads consolidate from a single authoritative source.
contract SettlerTrustConsolidationTest is FillScaffold {
    /// @notice Filler_auth_typehash_expected.
    bytes32 internal constant FILLER_AUTH_TYPEHASH_EXPECTED =
        keccak256("FillerAuth(bytes32 orderDigest,address destination,bytes32 subFiller)");

    /// @notice Eoa filler.
    address internal eoaFiller;

    /// @notice Eoa filler pk.
    uint256 internal eoaFillerPk;

    /// @notice Executor.
    address internal executor;

    /// @notice Fill.
    uint256 internal constant FILL = 500e18;

    /// @inheritdoc BaseTest
    function setUp() public override {
        super.setUp();
        (eoaFiller, eoaFillerPk) = makeAddrAndKey("xc-exclusive");
        executor = makeAddr("xc-executor");
        srcCst.mint(executor, 1_000_000e18);
        srcCst.mint(eoaFiller, 1_000_000e18);
        premiumToken.mint(executor, 1_000_000e18);
        premiumToken.mint(eoaFiller, 1_000_000e18);
        vm.startPrank(executor);
        srcCst.approve(address(settler), type(uint256).max);
        srcCst.approve(address(partialSettler), type(uint256).max);
        premiumToken.approve(address(settler), type(uint256).max);
        premiumToken.approve(address(partialSettler), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(eoaFiller);
        srcCst.approve(address(settler), type(uint256).max);
        srcCst.approve(address(partialSettler), type(uint256).max);
        premiumToken.approve(address(settler), type(uint256).max);
        premiumToken.approve(address(partialSettler), type(uint256).max);
        vm.stopPrank();

        bytes32 live = BaseSettler(address(settler)).fillerAuthTypehash();
        require(live == FILLER_AUTH_TYPEHASH_EXPECTED, "FillerAuth typehash drift");
    }

    /// @notice _settler for address.
    function _settlerForAddress(address s) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                Typehashes.EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("CorkSettler")),
                keccak256(bytes("1.0.0")),
                block.chainid,
                s
            )
        );
    }

    /// @notice Encodes a canonical ROLLOVER filler-data leg (one half of an atomic-fill envelope).
    function _rolloverFillerData(
        uint256 fillAmount,
        address destination,
        RolloverTypes.RolloverIntent memory intent,
        bytes memory cptHolderSig,
        bytes memory authSig
    ) internal pure returns (bytes memory) {
        return abi.encode(
            RolloverTypes.HookPhase.ROLLOVER,
            fillAmount,
            uint256(0),
            destination,
            address(0),
            intent,
            cptHolderSig,
            uint256(0),
            authSig,
            bytes32(0),
            ""
        );
    }

    /// @notice Wrap a rollover leg into the atomic-fill envelope (INV-ATOMIC-FILL-CANONICAL).
    ///         Pairs the leg with a self-keyed no-op premium leg (premium=0, cap=DEFAULT_PREMIUM_CAP)
    ///         so this auth-flow test exercises the rollover-side admission.
    function _atomicEnvelopeFor(
        bytes memory rolloverLeg,
        RolloverTypes.RolloverIntent memory intent,
        bytes memory,
        address destination,
        bytes memory cptHolderSig
    ) internal pure returns (bytes memory) {
        destination;
        intent;
        return abi.encode(uint8(255), rolloverLeg, DEFAULT_PREMIUM_CAP, cptHolderSig);
    }

    /// @notice _struct hash prefix.
    function _structHashPrefix(RolloverTypes.OrderData memory orderData)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(
            Typehashes.ORDER_DATA_TYPEHASH,
            orderData.user,
            orderData.settler,
            orderData.fillerHint,
            orderData.exclusiveFiller,
            orderData.srcCstToken,
            orderData.dstCstToken,
            orderData.premiumToken,
            orderData.rolloverContract,
            orderData.originChainId,
            orderData.destinationChainId
        );
    }

    /// @notice _struct hash suffix.
    function _structHashSuffix(RolloverTypes.OrderData memory orderData)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(
            orderData.openDeadline,
            orderData.fillDeadline,
            orderData.orderSalt,
            orderData.orderSize,
            orderData.minPremiumPerShare,
            orderData.allowPartialFills,
            orderData.allowUnderfill,
            orderData.premiumPaymentMode,
            orderData.rolloverIntentHash,
            _hashRolloverParamsMemory(orderData.rolloverParams)
        );
    }

    /// @notice _digest for settler.
    function _digestForSettler(RolloverTypes.OrderData memory orderData, address settlerAddr)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash =
            keccak256(bytes.concat(_structHashPrefix(orderData), _structHashSuffix(orderData)));
        return keccak256(abi.encodePacked(hex"1901", _settlerForAddress(settlerAddr), structHash));
    }

    /// @notice reverts when combined unapproved settler blocks valid filler auth sig.
    function testRevert_combined_unapprovedSettler_blocksValidFillerAuthSig() public {
        address rogueSettler = makeAddr("rogue-settler");
        RolloverTypes.OrderData memory orderData = _baseOrder();
        bytes32 orderDigest = _openOrder(orderData);
        RolloverTypes.RolloverIntent memory intent = _emptyIntent(rolloverContract, orderDigest);
        bytes memory sig = new bytes(65);
        RolloverTypes.FillContext memory fillContext = _fillContext({
            filler_: executor,
            fillAmount: 1,
            rolloverIntentHash: orderData.rolloverIntentHash,
            fillDeadline: orderData.fillDeadline,
            allowPartialFills: orderData.allowPartialFills,
            orderSize: orderData.orderSize,
            originSettler: rogueSettler,
            premiumToken_: address(premiumToken),
            premium: 0
        });
        vm.prank(rogueSettler);
        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContractFactory__SettlerNotApproved.selector, rogueSettler
            )
        );
        factory.executeIntentHooks(
            rolloverContract,
            orderDigest,
            RolloverTypes.HookPhase.ROLLOVER,
            intent,
            sig,
            fillContext,
            orderData
        );
    }

    /// @notice mismatched `rolloverParams.settler` is now rejected at Settler admission
    ///         (INV-PARAMS-SETTLER-PIN-MIRROR), so a filler with a valid authentication
    ///         signature still cannot transact against such an order; the order cannot
    ///         even reach the `Opened` state.
    function testRevert_combined_approvedSettler_paramsMismatch_blocksValidFillerAuthSig() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData = _usePartialSettler(orderData);
        orderData.exclusiveFiller = eoaFiller;

        orderData.rolloverParams.settler = address(0xCAFE);

        RolloverTypes.RolloverIntent memory intent = _buildIntent(bytes32(0), FILL, FILL);
        orderData.rolloverIntentHash = _zeroDigestHash(intent);

        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory userSig = _signOrder(cptHolderPk, orderData);
        bytes memory empty;
        vm.prank(executor);
        vm.expectRevert(Settler__RolloverParamsSettlerMismatch.selector);
        partialSettler.openFor(g, userSig, empty);
    }

    /// @notice combined direct fill through approved settler end to end.
    function test_combined_directFillThroughApprovedSettler_endToEnd() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData = _usePartialSettler(orderData);
        orderData.exclusiveFiller = eoaFiller;

        RolloverTypes.RolloverIntent memory intent = _buildIntent(bytes32(0), FILL, FILL);
        orderData.rolloverIntentHash = _zeroDigestHash(intent);
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory userSig = _signOrder(cptHolderPk, orderData);
        bytes memory empty;
        vm.prank(executor);
        partialSettler.openFor(g, userSig, empty);
        bytes32 orderDigest = _orderDigest(orderData);
        intent.orderDigest = orderDigest;
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);

        bytes memory rolloverLeg = _rolloverFillerData(FILL, eoaFiller, intent, cptHolderSig, empty);
        bytes memory fillerData = _atomicEnvelopeFor(
            rolloverLeg, intent, cptHolderSig, eoaFiller, _signOrder(cptHolderPk, orderData)
        );
        uint256 fillerDstBefore = dstCst.balanceOf(eoaFiller);
        vm.prank(eoaFiller);
        partialSettler.fill(orderDigest, _originData(orderData), fillerData);
        // INV-ATOMIC-FILL-CANONICAL: dstCST forwarded to filler in same frame.
        assertGt(dstCst.balanceOf(eoaFiller) - fillerDstBefore, 0);
    }
}
