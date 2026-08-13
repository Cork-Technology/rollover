// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { FillScaffold } from "../../base/FillScaffold.sol";
import { CorkRolloverContract } from "src/CorkRolloverContract.sol";
import {
    CorkRolloverContract__SignedSettlerOriginMismatch
} from "src/errors/CorkRolloverContractErrors.sol";
import { LibAtomicFill } from "src/libraries/LibAtomicFill.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice Regression pins for Plamen M-01: PREMIUM must prove cPT-holder-signed
///         `orderData.rolloverParams.settler` matches `fillContext.originSettler` before
///         `premiumFiredFor` is set.
contract PremiumSignedSettlerBindingTest is FillScaffold {
    /// @notice ERC-7201 namespace slot for `CorkRolloverContract` storage (must match `CorkRolloverContract.sol`).
    bytes32 internal constant ROLLOVER_CONTRACT_STORAGE_SLOT =
        0xb4cefcf1cd721ac7aa7779687f98e0bf77365d8cc544d423bc3152971ed5cc00;

    /// @notice Default fill amount (src side).
    uint256 internal constant FILL = 1_000e18;
    /// @notice Default dst amount produced for fill scenarios.
    uint256 internal constant DST = 1_000e18;
    /// @notice Default premium amount used by fill scenarios.
    uint256 internal constant PREMIUM = 10e18;

    function _setRolled(bytes32 orderDigest, uint256 rolled) internal {
        bytes32 slot =
            keccak256(abi.encode(orderDigest, uint256(ROLLOVER_CONTRACT_STORAGE_SLOT) + 1));
        vm.store(rolloverContract, slot, bytes32(rolled));
    }

    /// @dev Self-consistent EIP-712 order where `orderData.settler` is the partial Settler
    ///      (domain separator) but cPT-holder-signed `rolloverParams.settler` names the exact Settler.
    ///      Cannot be admitted via `openFor` (INV-PARAMS-SETTLER-PIN-MIRROR) but is digest-valid
    ///      for direct factory hooks.
    function _spoofOrderWithInnerSettlerDrift()
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
        orderData.rolloverParams.settler = address(settler);
        orderData.allowPartialFills = false;
        orderData.orderSize = FILL;
        intent = _buildIntent(bytes32(0), FILL, DST);
        orderData.rolloverIntentHash = _zeroDigestHash(intent);
        orderDigest = _orderDigest(orderData);
        intent.orderDigest = orderDigest;
        cptHolderSig = _signOrder(cptHolderPk, orderData);
    }

    function _fillContextPremium(RolloverTypes.OrderData memory orderData, uint256 premium)
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
            originSettler: address(partialSettler),
            premiumToken: orderData.premiumToken,
            premium: premium,
            subFiller: bytes32(uint256(uint160(filler)))
        });
    }

    function _fundRolloverContractForRollover(uint256 srcAmount) internal {
        vm.prank(filler);
        require(srcCst.transfer(rolloverContract, srcAmount), "fund rolloverContract srcCst");
    }

    function _factoryRollover(
        RolloverTypes.OrderData memory orderData,
        bytes32 orderDigest,
        RolloverTypes.RolloverIntent memory intent,
        bytes memory cptHolderSig
    ) internal {
        RolloverTypes.FillContext memory fillContext = _fillContext(
            filler,
            FILL,
            orderData.rolloverIntentHash,
            orderData.fillDeadline,
            orderData.allowPartialFills,
            orderData.orderSize,
            orderData.settler,
            address(0),
            0
        );
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

    function _fundRolloverContractPremium(uint256 premium) internal {
        vm.prank(filler);
        require(premiumToken.transfer(rolloverContract, premium), "fund rolloverContract premium");
    }

    function _factoryPremium(
        RolloverTypes.OrderData memory orderData,
        bytes32 orderDigest,
        RolloverTypes.RolloverIntent memory intent,
        bytes memory cptHolderSig,
        uint256 premium
    ) internal {
        _fundRolloverContractPremium(premium);
        RolloverTypes.FillContext memory fillContext = _fillContextPremium(orderData, premium);
        vm.prank(address(partialSettler));
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

    /// @notice PREMIUM with signed inner settler != `fillContext.originSettler` reverts before latch.
    function testRevert_premium_signedSettlerDrift_reverts() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _spoofOrderWithInnerSettlerDrift();

        _setRolled(orderDigest, FILL);
        _fundRolloverContractPremium(PREMIUM);

        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContract__SignedSettlerOriginMismatch.selector,
                address(settler),
                address(partialSettler)
            )
        );
        vm.prank(address(partialSettler));
        factory.executeIntentHooks(
            rolloverContract,
            orderDigest,
            RolloverTypes.HookPhase.PREMIUM,
            intent,
            cptHolderSig,
            _fillContextPremium(orderData, PREMIUM),
            orderData
        );
    }

    /// @notice Same signed-settler drift is rejected on ROLLOVER and PREMIUM.
    function testRevert_rollover_signedSettlerDrift_reverts() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _spoofOrderWithInnerSettlerDrift();

        _fundRolloverContractForRollover(FILL);

        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContract__SignedSettlerOriginMismatch.selector,
                address(settler),
                address(partialSettler)
            )
        );
        vm.prank(address(partialSettler));
        factory.executeIntentHooks(
            rolloverContract,
            orderDigest,
            RolloverTypes.HookPhase.ROLLOVER,
            intent,
            cptHolderSig,
            _fillContextPremium(orderData, 0),
            orderData
        );
    }

    /// @notice Failed PREMIUM spoof must not set `premiumFiredFor`.
    function test_premium_spoofDoesNotMutateLatch() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _spoofOrderWithInnerSettlerDrift();

        _setRolled(orderDigest, FILL);
        _fundRolloverContractPremium(PREMIUM);

        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContract__SignedSettlerOriginMismatch.selector,
                address(settler),
                address(partialSettler)
            )
        );
        vm.prank(address(partialSettler));
        factory.executeIntentHooks(
            rolloverContract,
            orderDigest,
            RolloverTypes.HookPhase.PREMIUM,
            intent,
            cptHolderSig,
            _fillContextPremium(orderData, PREMIUM),
            orderData
        );

        assertFalse(
            CorkRolloverContract(rolloverContract)
                .premiumFiredFor(orderDigest, filler, bytes32(uint256(uint160(filler)))),
            "rolloverContract premium latch must be untouched on spoof revert"
        );
    }

    /// @notice After a failed spoof, legitimate PREMIUM on a canonical partial order still succeeds.
    function test_premium_afterFailedSpoof_legitimatePremiumSucceeds() public {
        (
            RolloverTypes.OrderData memory spoofOrder,
            bytes32 spoofDigest,
            RolloverTypes.RolloverIntent memory spoofIntent,
            bytes memory spoofCptHolderSig
        ) = _spoofOrderWithInnerSettlerDrift();

        _setRolled(spoofDigest, FILL);
        _fundRolloverContractPremium(PREMIUM);
        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContract__SignedSettlerOriginMismatch.selector,
                address(settler),
                address(partialSettler)
            )
        );
        vm.prank(address(partialSettler));
        factory.executeIntentHooks(
            rolloverContract,
            spoofDigest,
            RolloverTypes.HookPhase.PREMIUM,
            spoofIntent,
            spoofCptHolderSig,
            _fillContextPremium(spoofOrder, PREMIUM),
            spoofOrder
        );

        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData = _usePartialSettler(orderData);
        orderData.orderSize = FILL;
        orderData.orderSalt = 9_001;
        RolloverTypes.RolloverIntent memory intent = _buildIntent(bytes32(0), FILL, DST);
        orderData.rolloverIntentHash = _zeroDigestHash(intent);
        bytes32 orderDigest = _openOrder(orderData);
        intent.orderDigest = orderDigest;
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);

        _fundRolloverContractForRollover(FILL);
        _factoryRollover(orderData, orderDigest, intent, cptHolderSig);

        uint256 premium = LibAtomicFill.computeRequiredPremium(FILL, orderData.minPremiumPerShare);
        _factoryPremium(orderData, orderDigest, intent, cptHolderSig, premium);

        assertTrue(
            CorkRolloverContract(rolloverContract)
                .premiumFiredFor(orderDigest, filler, bytes32(uint256(uint160(filler)))),
            "legitimate premium must latch after failed spoof"
        );
    }

    /// @notice Atomic exact-fill premium flow still passes (regression).
    function test_exactAtomicPremium_happyPath() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.allowPartialFills = false;
        orderData.orderSize = FILL;
        RolloverTypes.RolloverIntent memory intent = _buildIntent(bytes32(0), FILL, DST);
        orderData.rolloverIntentHash = _zeroDigestHash(intent);
        bytes32 orderDigest = _openOrder(orderData);
        intent.orderDigest = orderDigest;
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);
        uint256 premium = LibAtomicFill.computeRequiredPremium(FILL, orderData.minPremiumPerShare);
        _approveFiller(FILL, premium);
        _doRolloverAs(orderDigest, orderData, intent, FILL, filler);
        assertTrue(
            settler.rolloverAccountingOf(orderDigest).premiumFired, "exact atomic premium must fire"
        );
    }

    /// @notice Atomic partial-fill premium flow still passes (regression).
    function test_partialAtomicPremium_happyPath() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData = _usePartialSettler(orderData);
        orderData.orderSize = FILL;
        RolloverTypes.RolloverIntent memory intent = _buildIntent(bytes32(0), FILL, DST);
        orderData.rolloverIntentHash = _zeroDigestHash(intent);
        bytes32 orderDigest = _openOrder(orderData);
        intent.orderDigest = orderDigest;
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);
        uint256 premium = LibAtomicFill.computeRequiredPremium(FILL, orderData.minPremiumPerShare);
        _approveFiller(FILL, premium);
        _doRolloverAs(orderDigest, orderData, intent, FILL, filler);
        assertTrue(
            partialSettler.fillerSlotAccountingOf(
                orderDigest, filler, bytes32(uint256(uint160(filler)))
            )
            .settled,
            "partial atomic premium must settle filler"
        );
    }
}
