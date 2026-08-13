// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { FillScaffold } from "../base/FillScaffold.sol";
import { BaseSettler } from "src/BaseSettler.sol";
import { Settler__ZeroAddress } from "src/errors/SettlerErrors.sol";
import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import { LibFillerPayload } from "src/libraries/LibFillerPayload.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice Pins the deletion of the `destination == address(0) → destination = filler`
///         fallbacks at
///         PartialSettler `_loadPremiumPaymentContext`, PartialSettler `_settlePaidRolloverRecord`, and
///         ExactSettler `_loadPremiumPaymentContext`. The admission gate at
///         `BaseSettler._validateRolloverBeforeExecution` reverts with `Settler__ZeroAddress`
///         on any zero-destination payload BEFORE state is written, so the
///         downstream fallbacks are unreachable.
contract DestinationZeroFallbackRemovedTest is FillScaffold {
    /// @notice Fill amount used by the scaffold.
    uint256 internal constant FILL = 500e18;

    /// @notice PartialSettler: a zero-destination ROLLOVER payload reverts at admission
    ///         with `Settler__ZeroAddress`. Proves `fillerDestination` is never
    ///         populated with zero for partial-mode rollovers — so the fallback in
    ///         `_loadPremiumPaymentContext` / `_settlePaidRolloverRecord` is dead code.
    function test_PartialSettler_DestinationZero_RevertsAtAdmission_NotFallback() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupZeroDestinationOrder(true);
        bytes memory fillerData = _zeroDestRolloverFillerData(orderData, intent, cptHolderSig);

        srcCst.mint(filler, FILL);
        vm.prank(filler);
        srcCst.approve(address(partialSettler), FILL);

        vm.prank(filler);
        vm.expectRevert(Settler__ZeroAddress.selector);
        partialSettler.fill(orderDigest, _originData(orderData), fillerData);
    }

    /// @notice ExactSettler: a zero-destination ROLLOVER payload reverts at admission
    ///         with `Settler__ZeroAddress`. Proves `fillerDestination` is never
    ///         populated with zero for exact-mode rollovers — so the fallback in
    ///         `_loadPremiumPaymentContext` is dead code.
    function test_ExactSettler_DestinationZero_RevertsAtAdmission_NotFallback() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupZeroDestinationOrder(false);
        bytes memory fillerData = _zeroDestRolloverFillerData(orderData, intent, cptHolderSig);

        srcCst.mint(filler, FILL);
        vm.prank(filler);
        srcCst.approve(address(settler), FILL);

        vm.prank(filler);
        vm.expectRevert(Settler__ZeroAddress.selector);
        settler.fill(orderDigest, _originData(orderData), fillerData);
    }

    function _setupZeroDestinationOrder(bool isPartial)
        internal
        returns (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        )
    {
        orderData = isPartial ? _orderForMode(SettlerMode.Partial) : _baseOrder();
        orderData.allowUnderfill = true;
        intent = _buildIntent(bytes32(0), FILL, FILL);
        orderData.rolloverIntentHash = _zeroDigestHash(intent);

        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory userSig = _signOrder(cptHolderPk, orderData);
        bytes memory empty;
        if (isPartial) {
            partialSettler.openFor(g, userSig, empty);
        } else {
            settler.openFor(g, userSig, empty);
        }
        orderDigest = _orderDigest(orderData);
        intent.orderDigest = orderDigest;
        cptHolderSig = _signOrder(cptHolderPk, orderData);
    }

    /// @dev Atomic-fill envelope wrapping a ROLLOVER leg with `destination = address(0)`.
    function _zeroDestRolloverFillerData(
        RolloverTypes.OrderData memory, /* orderData (signed earlier) */
        RolloverTypes.RolloverIntent memory intent,
        bytes memory cptHolderSig
    ) internal pure returns (bytes memory) {
        bytes memory empty;
        bytes memory rolloverLeg = abi.encode(
            uint8(RolloverTypes.HookPhase.ROLLOVER),
            FILL,
            uint256(0),
            address(0), // destination = 0 — the surface under test
            address(0),
            intent,
            cptHolderSig,
            uint256(0),
            empty,
            bytes32(0),
            empty
        );
        return abi.encode(uint8(255), rolloverLeg, uint256(1_000_000e18), empty);
    }
}
