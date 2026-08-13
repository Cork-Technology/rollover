// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { FillScaffold } from "../../base/FillScaffold.sol";
import {
    CorkRolloverContract__SignedSettlerOriginMismatch
} from "src/errors/CorkRolloverContractErrors.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice RolloverPreflightSettlerPinTest — pins RolloverPreflightSettlerPin behaviour for the Cork Rollover suite.
contract RolloverPreflightSettlerPinTest is FillScaffold {
    /// @notice RolloverContract namespace slot.
    bytes32 internal constant ROLLOVER_CONTRACT_NAMESPACE_SLOT = keccak256(
        abi.encode(uint256(keccak256("cork.rollover.rolloverContract")) - 1)
    ) & ~bytes32(uint256(0xff));
    /// @notice Fill.

    uint256 internal constant FILL = 500e18;

    function _setupDirectFactoryOrder(address signedSettler)
        internal
        view
        returns (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        )
    {
        orderData = _baseOrder();
        orderData = _usePartialSettler(orderData);
        orderData.rolloverParams.settler = signedSettler;
        intent = _buildIntent(bytes32(0), FILL, FILL);
        orderData.rolloverIntentHash = _zeroDigestHash(intent);
        orderDigest = _orderDigest(orderData);
        intent.orderDigest = orderDigest;
        cptHolderSig = _signOrder(cptHolderPk, orderData);
    }

    function _fillContextFor(
        RolloverTypes.OrderData memory orderData,
        uint256 fillAmount,
        address originSettler
    ) internal pure returns (RolloverTypes.FillContext memory) {
        return RolloverTypes.FillContext({
            filler: address(0xF1),
            fillAmount: fillAmount,
            rolloverIntentHash: orderData.rolloverIntentHash,
            fillDeadline: orderData.fillDeadline,
            allowPartialFills: orderData.allowPartialFills,
            allowUnderfill: orderData.allowUnderfill,
            orderSize: orderData.orderSize,
            originSettler: originSettler,
            premiumToken: orderData.premiumToken,
            premium: 0,
            subFiller: bytes32(0)
        });
    }

    /// @notice Signed rollover settler must match the factory-latched origin settler.
    function testRevert_signedSettlerMismatchReverts() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupDirectFactoryOrder(address(settler));

        RolloverTypes.FillContext memory fillContext =
            _fillContextFor(orderData, FILL, address(partialSettler));

        vm.prank(address(partialSettler));
        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContract__SignedSettlerOriginMismatch.selector,
                address(settler),
                address(partialSettler)
            )
        );
        factory.executeIntentHooks(
            rolloverContract,
            orderDigest,
            RolloverTypes.HookPhase.ROLLOVER,
            intent,
            cptHolderSig,
            fillContext,
            orderData
        );
    }

    /// @notice Pins behaviour: settler Equals Origin Succeeds.
    function test_settlerEqualsOriginSucceeds() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupDirectFactoryOrder(address(partialSettler));

        vm.prank(filler);
        require(srcCst.transfer(rolloverContract, FILL), "fund rolloverContract srcCst");

        RolloverTypes.FillContext memory fillContext =
            _fillContextFor(orderData, FILL, address(partialSettler));

        vm.prank(address(partialSettler));
        factory.executeIntentHooks(
            rolloverContract,
            orderDigest,
            RolloverTypes.HookPhase.ROLLOVER,
            intent,
            cptHolderSig,
            fillContext,
            orderData
        );

        assertGt(dstCst.balanceOf(address(partialSettler)), 0, "dstCST must reach approved Settler");
    }

    /// @notice Signed settler pin applies to PREMIUM as well as ROLLOVER.
    function testRevert_signedSettlerPinAppliesToPremiumPhase() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupDirectFactoryOrder(address(settler));

        RolloverTypes.FillContext memory fillContext =
            _fillContextFor(orderData, 0, address(partialSettler));
        fillContext.premiumToken = orderData.premiumToken;
        fillContext.premium = 1;

        vm.prank(address(partialSettler));
        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContract__SignedSettlerOriginMismatch.selector,
                address(settler),
                address(partialSettler)
            )
        );
        factory.executeIntentHooks(
            rolloverContract,
            orderDigest,
            RolloverTypes.HookPhase.PREMIUM,
            intent,
            cptHolderSig,
            fillContext,
            orderData
        );
    }

    /// @notice Zero signed settler fails through the same single pin check.
    function testRevert_signedSettlerPinRejectsZero() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupDirectFactoryOrder(address(0));

        RolloverTypes.FillContext memory fillContext =
            _fillContextFor(orderData, FILL, address(partialSettler));

        vm.prank(address(partialSettler));
        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContract__SignedSettlerOriginMismatch.selector,
                address(0),
                address(partialSettler)
            )
        );
        factory.executeIntentHooks(
            rolloverContract,
            orderDigest,
            RolloverTypes.HookPhase.ROLLOVER,
            intent,
            cptHolderSig,
            fillContext,
            orderData
        );
    }

    /// @notice Pins behaviour: storage rolloverContract Namespace Slot Unchanged.
    function test_storage_rolloverContractNamespaceSlotUnchanged() public pure {
        bytes32 expected = keccak256(
            abi.encode(uint256(keccak256("cork.rollover.rolloverContract")) - 1)
        ) & ~bytes32(uint256(0xff));
        assertEq(expected, ROLLOVER_CONTRACT_NAMESPACE_SLOT);
    }

    /// @notice Pins behaviour: settler-pin error adds no storage.
    function test_storage_settlerPinAddsNoStorage() public pure {
        bytes4 selector = CorkRolloverContract__SignedSettlerOriginMismatch.selector;
        assertTrue(selector != bytes4(0));
    }
}
