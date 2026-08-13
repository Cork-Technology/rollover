// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { FillScaffold } from "../../base/FillScaffold.sol";
import { CorkRolloverContract } from "src/CorkRolloverContract.sol";
import {
    CorkRolloverContract__AllowPartialFillsMismatch,
    CorkRolloverContract__AllowUnderfillMismatch,
    CorkRolloverContract__FillDeadlineMismatch,
    CorkRolloverContract__OrderDataDigestMismatch,
    CorkRolloverContract__OrderSizeMismatch,
    CorkRolloverContract__PremiumTokenMismatch,
    CorkRolloverContract__RolloverIntentHashCtxMismatch
} from "src/errors/CorkRolloverContractErrors.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice FillContextOrderDataBindingTest — pins the rolloverContract-side re-derivation of `orderDigest`
///         from `orderData` (INV-ORDER-DIGEST-RE-DERIVED-ROLLOVER_CONTRACT-SIDE) and the field-by-field
///         cross-check between Settler-supplied `fillContext.*` and cPT-holder-signed `orderData.*`
///         (INV-FILL-CONTEXT-MATCHES-ORDER). A compromised approved Settler can no longer fabricate
///         `fillContext.{orderSize, fillDeadline, premiumToken, allowPartialFills, allowUnderfill,
///         rolloverIntentHash}` without the rolloverContract catching the divergence at admission.
/// @custom:invariant INV-FILL-CONTEXT-MATCHES-ORDER
/// @custom:invariant INV-ORDER-DIGEST-RE-DERIVED-ROLLOVER_CONTRACT-SIDE
contract FillContextOrderDataBindingTest is FillScaffold {
    /// @notice Default fill amount (src side) used by helper scenarios.
    uint256 internal constant FILL = 1_000e18;
    /// @notice Default dst amount produced for fill scenarios.
    uint256 internal constant DST = 1_000e18;
    /// @notice Default premium amount used by fill scenarios.
    uint256 internal constant PREMIUM = 10e18;

    function _opened()
        internal
        returns (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        )
    {
        orderData = _baseOrder();
        orderData.allowPartialFills = false;
        orderData.orderSize = FILL;
        intent = _buildIntent(bytes32(0), FILL, DST);
        orderData.rolloverIntentHash = _zeroDigestHash(intent);
        orderDigest = _openOrder(orderData);
        intent.orderDigest = orderDigest;
        cptHolderSig = _signOrder(cptHolderPk, orderData);
        _approveFiller(FILL, PREMIUM);
    }

    function _openedForMode(SettlerMode mode, uint64 saltOffset)
        internal
        returns (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        )
    {
        orderData = _orderForMode(mode);
        orderData.orderSalt += saltOffset;
        orderData.orderSize = FILL;
        intent = _buildIntent(bytes32(0), FILL, DST);
        orderData.rolloverIntentHash = _zeroDigestHash(intent);
        orderDigest = _openOrder(orderData);
        intent.orderDigest = orderDigest;
        cptHolderSig = _signOrder(cptHolderPk, orderData);
        _approveFiller(FILL, PREMIUM);
    }

    function _fillContextMatching(RolloverTypes.OrderData memory orderData)
        internal
        view
        returns (RolloverTypes.FillContext memory)
    {
        return RolloverTypes.FillContext({
            filler: filler,
            fillAmount: FILL,
            rolloverIntentHash: orderData.rolloverIntentHash,
            fillDeadline: orderData.fillDeadline,
            allowPartialFills: orderData.allowPartialFills,
            allowUnderfill: orderData.allowUnderfill,
            orderSize: orderData.orderSize,
            originSettler: orderData.settler,
            premiumToken: address(0),
            premium: 0,
            subFiller: bytes32(0)
        });
    }

    /// @notice Shared rolloverContract fillContext/orderData/digest/params binding matrix against exact settler.
    function test_sharedFillContextOrderDataBindingMatrix_exact() public {
        _assertSharedFillContextOrderDataBindingMatrix(SettlerMode.Exact, 1000);
    }

    /// @notice Shared rolloverContract fillContext/orderData/digest/params binding matrix against partial settler.
    function test_sharedFillContextOrderDataBindingMatrix_partial() public {
        _assertSharedFillContextOrderDataBindingMatrix(SettlerMode.Partial, 2000);
    }

    function _assertSharedFillContextOrderDataBindingMatrix(SettlerMode mode, uint64 saltBase)
        internal
    {
        _assertFillContextHappyPath(mode, saltBase + 1);
        _assertFillContextOrderSizeMismatch(mode, saltBase + 2);
        _assertFillContextFillDeadlineMismatch(mode, saltBase + 3);
        _assertFillContextAllowPartialFillsMismatch(mode, saltBase + 4);
        _assertFillContextAllowUnderfillMismatch(mode, saltBase + 5);
        _assertFillContextRolloverIntentHashMismatch(mode, saltBase + 6);
        _assertFillContextPremiumTokenMismatch(mode, saltBase + 7);
        _assertFillContextDigestMismatch(mode, saltBase + 8);
        _assertFillContextRolloverParamsDigestMismatch(mode, saltBase + 9);
        _assertFillContextForeignDomainDigestMismatch(mode, saltBase + 10);
    }

    function _assertFillContextHappyPath(SettlerMode mode, uint64 salt) internal {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _openedForMode(mode, salt);
        _doRolloverAs(orderDigest, orderData, intent, FILL, filler);
        if (mode == SettlerMode.Partial) {
            assertTrue(
                partialSettler.fillerSlotAccountingOf(
                        orderDigest, filler, bytes32(uint256(uint160(filler)))
                    ).rollover.premiumFired,
                "partial premium must fire on happy path"
            );
        } else {
            assertTrue(
                settler.rolloverAccountingOf(orderDigest).premiumFired,
                "exact premium must fire on happy path"
            );
        }
    }

    function _assertFillContextOrderSizeMismatch(SettlerMode mode, uint64 salt) internal {
        (
            RolloverTypes.OrderData memory fillContextOrderData,
            bytes32 fillContextOrderDigest,
            RolloverTypes.RolloverIntent memory fillContextIntent,
            bytes memory fillContextCptHolderSig
        ) = _openedForMode(mode, salt);
        RolloverTypes.FillContext memory fillContext = _fillContextMatching(fillContextOrderData);
        fillContext.orderSize = fillContextOrderData.orderSize + 1;
        _expectFillContextMismatch(
            fillContextOrderData,
            fillContextOrderDigest,
            fillContextIntent,
            fillContextCptHolderSig,
            fillContext,
            CorkRolloverContract__OrderSizeMismatch.selector
        );
    }

    function _assertFillContextFillDeadlineMismatch(SettlerMode mode, uint64 salt) internal {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _openedForMode(mode, salt);
        RolloverTypes.FillContext memory fillContext = _fillContextMatching(orderData);
        fillContext.fillDeadline = orderData.fillDeadline + 1;
        _expectFillContextMismatch(
            orderData,
            orderDigest,
            intent,
            cptHolderSig,
            fillContext,
            CorkRolloverContract__FillDeadlineMismatch.selector
        );
    }

    function _assertFillContextAllowPartialFillsMismatch(SettlerMode mode, uint64 salt) internal {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _openedForMode(mode, salt);
        RolloverTypes.FillContext memory fillContext = _fillContextMatching(orderData);
        fillContext.allowPartialFills = !orderData.allowPartialFills;
        _expectFillContextMismatch(
            orderData,
            orderDigest,
            intent,
            cptHolderSig,
            fillContext,
            CorkRolloverContract__AllowPartialFillsMismatch.selector
        );
    }

    function _assertFillContextAllowUnderfillMismatch(SettlerMode mode, uint64 salt) internal {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _openedForMode(mode, salt);
        RolloverTypes.FillContext memory fillContext = _fillContextMatching(orderData);
        fillContext.allowUnderfill = !orderData.allowUnderfill;
        _expectFillContextMismatch(
            orderData,
            orderDigest,
            intent,
            cptHolderSig,
            fillContext,
            CorkRolloverContract__AllowUnderfillMismatch.selector
        );
    }

    function _assertFillContextRolloverIntentHashMismatch(SettlerMode mode, uint64 salt) internal {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _openedForMode(mode, salt);
        RolloverTypes.FillContext memory fillContext = _fillContextMatching(orderData);
        fillContext.rolloverIntentHash = bytes32(uint256(orderData.rolloverIntentHash) ^ uint256(1));
        _expectFillContextMismatch(
            orderData,
            orderDigest,
            intent,
            cptHolderSig,
            fillContext,
            CorkRolloverContract__RolloverIntentHashCtxMismatch.selector
        );
    }

    function _assertFillContextPremiumTokenMismatch(SettlerMode mode, uint64 salt) internal {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _openedForMode(mode, salt);
        _doRolloverAs(orderDigest, orderData, intent, FILL, filler);

        RolloverTypes.FillContext memory fillContext = _fillContextMatching(orderData);
        fillContext.premiumToken = address(0xDEAD);
        fillContext.premium = PREMIUM;

        vm.expectPartialRevert(CorkRolloverContract__PremiumTokenMismatch.selector);
        vm.prank(orderData.settler);
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

    function _assertFillContextDigestMismatch(SettlerMode mode, uint64 salt) internal {
        (
            RolloverTypes.OrderData memory digestOrderData,
            bytes32 digestOrderDigest,
            RolloverTypes.RolloverIntent memory digestIntent,
            bytes memory digestCptHolderSig
        ) = _openedForMode(mode, salt);
        RolloverTypes.FillContext memory digestFillContext = _fillContextMatching(digestOrderData);
        digestOrderData.orderSize = digestOrderData.orderSize + 1;
        digestFillContext.orderSize = digestOrderData.orderSize;
        vm.expectPartialRevert(CorkRolloverContract__OrderDataDigestMismatch.selector);
        vm.prank(digestOrderData.settler);
        factory.executeIntentHooks(
            rolloverContract,
            digestOrderDigest,
            RolloverTypes.HookPhase.ROLLOVER,
            digestIntent,
            digestCptHolderSig,
            digestFillContext,
            digestOrderData
        );
    }

    function _assertFillContextRolloverParamsDigestMismatch(SettlerMode mode, uint64 salt)
        internal
    {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _openedForMode(mode, salt);
        RolloverTypes.FillContext memory fillContext = _fillContextMatching(orderData);
        orderData.rolloverParams.settler = address(0xCAFE);
        _expectOrderDataDigestMismatch(orderData, orderDigest, intent, cptHolderSig, fillContext);
    }

    function _assertFillContextForeignDomainDigestMismatch(SettlerMode mode, uint64 salt) internal {
        (
            RolloverTypes.OrderData memory orderData,,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _openedForMode(mode, salt);
        orderData.originChainId = uint64(block.chainid + 1);
        RolloverTypes.FillContext memory fillContext = _fillContextMatching(orderData);
        _expectOrderDataDigestMismatch(
            orderData, bytes32(uint256(0xC11D)), intent, cptHolderSig, fillContext
        );
    }

    /// @notice Happy path: matching `fillContext` and `orderData` pass the binding check.
    function test_happyPath_matchingFillContextAndOrderData() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _opened();
        _doRolloverAs(orderDigest, orderData, intent, FILL, filler);
        // Premium leg also passes through the binding (PREMIUM-phase premiumToken check).
        assertTrue(
            settler.rolloverAccountingOf(orderDigest).premiumFired,
            "premium must fire on happy path"
        );
    }

    /// @notice Tampered `fillContext.orderSize` is caught by INV-FILL-CONTEXT-MATCHES-ORDER.
    function testRevert_orderSizeTampered() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _opened();
        RolloverTypes.FillContext memory fillContext = _fillContextMatching(orderData);
        fillContext.orderSize = orderData.orderSize + 1;

        vm.expectPartialRevert(CorkRolloverContract__OrderSizeMismatch.selector);
        vm.prank(orderData.settler);
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

    /// @notice Tampered `fillContext.fillDeadline` is caught by INV-FILL-CONTEXT-MATCHES-ORDER.
    function testRevert_fillDeadlineTampered() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _opened();
        RolloverTypes.FillContext memory fillContext = _fillContextMatching(orderData);
        fillContext.fillDeadline = orderData.fillDeadline + 1;

        vm.expectPartialRevert(CorkRolloverContract__FillDeadlineMismatch.selector);
        vm.prank(orderData.settler);
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

    /// @notice Tampered `fillContext.allowPartialFills` is caught by INV-FILL-CONTEXT-MATCHES-ORDER.
    function testRevert_allowPartialFillsTampered() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _opened();
        RolloverTypes.FillContext memory fillContext = _fillContextMatching(orderData);
        fillContext.allowPartialFills = !orderData.allowPartialFills;

        vm.expectPartialRevert(CorkRolloverContract__AllowPartialFillsMismatch.selector);
        vm.prank(orderData.settler);
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

    /// @notice Tampered `fillContext.allowUnderfill` is caught by INV-FILL-CONTEXT-MATCHES-ORDER.
    function testRevert_allowUnderfillTampered() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _opened();
        RolloverTypes.FillContext memory fillContext = _fillContextMatching(orderData);
        fillContext.allowUnderfill = !orderData.allowUnderfill;

        vm.expectPartialRevert(CorkRolloverContract__AllowUnderfillMismatch.selector);
        vm.prank(orderData.settler);
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

    /// @notice Tampered `fillContext.rolloverIntentHash` is caught by INV-FILL-CONTEXT-MATCHES-ORDER.
    function testRevert_rolloverIntentHashTampered() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _opened();
        RolloverTypes.FillContext memory fillContext = _fillContextMatching(orderData);
        fillContext.rolloverIntentHash = bytes32(uint256(orderData.rolloverIntentHash) ^ uint256(1));

        vm.expectRevert(CorkRolloverContract__RolloverIntentHashCtxMismatch.selector);
        vm.prank(address(settler));
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

    /// @notice Tampered `fillContext.premiumToken` during PREMIUM phase is caught by
    ///         INV-FILL-CONTEXT-MATCHES-ORDER. (ROLLOVER phase tolerates zero `premiumToken`.)
    function testRevert_premiumTokenTamperedPremiumPhase() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _opened();
        _doRolloverAs(orderDigest, orderData, intent, FILL, filler);

        RolloverTypes.FillContext memory fillContext = _fillContextMatching(orderData);
        fillContext.premiumToken = address(0xDEAD);
        fillContext.premium = PREMIUM;

        vm.expectPartialRevert(CorkRolloverContract__PremiumTokenMismatch.selector);
        vm.prank(address(settler));
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

    /// @notice Tampering any `orderData.*` field that contributes to the EIP-712 digest
    ///         is caught by INV-ORDER-DIGEST-RE-DERIVED-ROLLOVER_CONTRACT-SIDE.
    function testRevert_orderDataOrderSizeTampered_digestMismatch() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _opened();
        RolloverTypes.FillContext memory fillContext = _fillContextMatching(orderData);
        // Mutate orderData.orderSize AND fillContext.orderSize to bypass INV-FILL-CONTEXT-MATCHES-ORDER;
        // the EIP-712 digest re-derivation still fails because the digest was signed
        // over the original `orderData.orderSize`.
        orderData.orderSize = orderData.orderSize + 1;
        fillContext.orderSize = orderData.orderSize;

        vm.expectPartialRevert(CorkRolloverContract__OrderDataDigestMismatch.selector);
        vm.prank(address(settler));
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

    /// @notice Tampering `orderData.rolloverParams.settler` (nested in the EIP-712 struct)
    ///         is caught by INV-ORDER-DIGEST-RE-DERIVED-ROLLOVER_CONTRACT-SIDE.
    function testRevert_orderDataRolloverParamsTampered_digestMismatch() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _opened();
        RolloverTypes.FillContext memory fillContext = _fillContextMatching(orderData);
        orderData.rolloverParams.settler = address(0xCAFE);

        vm.expectPartialRevert(CorkRolloverContract__OrderDataDigestMismatch.selector);
        vm.prank(address(settler));
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

    /// @notice Domain-separator binding: an orderDigest computed under a foreign chain id
    ///         (or foreign verifyingContract) is rejected because the rolloverContract reads
    ///         `ISettler(fillContext.originSettler).DOMAIN_SEPARATOR()` for re-derivation.
    function testRevert_foreignChainIdDigest_rejected() public {
        (
            RolloverTypes.OrderData memory orderData,,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _opened();
        // Forge a digest by setting `orderData.originChainId` to something other than
        // `block.chainid`. The cPT-holder-signed envelope opened under chain id `block.chainid`;
        // the rolloverContract will re-derive a digest under the actual Settler's domain and reject
        // it because the local mutation diverges from the opened digest.
        orderData.originChainId = uint64(block.chainid + 1);
        RolloverTypes.FillContext memory fillContext = _fillContextMatching(orderData);

        // Use a synthetic digest that cannot have been opened — this proves the rolloverContract
        // does not trust the dispatched `orderDigest` at face value.
        bytes32 syntheticDigest = bytes32(uint256(0xC11D));

        vm.expectPartialRevert(CorkRolloverContract__OrderDataDigestMismatch.selector);
        vm.prank(address(settler));
        factory.executeIntentHooks(
            rolloverContract,
            syntheticDigest,
            RolloverTypes.HookPhase.ROLLOVER,
            intent,
            cptHolderSig,
            fillContext,
            orderData
        );
    }

    function _expectFillContextMismatch(
        RolloverTypes.OrderData memory orderData,
        bytes32 orderDigest,
        RolloverTypes.RolloverIntent memory intent,
        bytes memory cptHolderSig,
        RolloverTypes.FillContext memory fillContext,
        bytes4 selector
    ) internal {
        vm.expectPartialRevert(selector);
        vm.prank(orderData.settler);
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

    function _expectOrderDataDigestMismatch(
        RolloverTypes.OrderData memory orderData,
        bytes32 orderDigest,
        RolloverTypes.RolloverIntent memory intent,
        bytes memory cptHolderSig,
        RolloverTypes.FillContext memory fillContext
    ) internal {
        vm.expectPartialRevert(CorkRolloverContract__OrderDataDigestMismatch.selector);
        vm.prank(orderData.settler);
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
}
