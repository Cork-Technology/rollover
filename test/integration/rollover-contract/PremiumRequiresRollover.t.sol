// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { FillScaffold } from "../../base/FillScaffold.sol";
import { CorkRolloverContract } from "src/CorkRolloverContract.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice PremiumRequiresRolloverTest — pins the rolloverContract-side `$.rolled[orderDigest] == 0`
///         guard at the head of `_handlePhasePremium` (INV-PREMIUM-REQUIRES-ROLLOVER).
///         Defense-in-depth against a compromised approved Settler bypassing its own
///         per-filler `rec.dstCstProduced != 0` ordering enforcement.
/// @custom:invariant INV-PREMIUM-REQUIRES-ROLLOVER
contract PremiumRequiresRolloverTest is FillScaffold {
    /// @notice Default fill amount (src side) used by helper scenarios.
    uint256 internal constant FILL = 1_000e18;
    /// @notice Default dst amount produced for fill scenarios.
    uint256 internal constant DST = 1_000e18;
    /// @notice Default premium amount used by fill scenarios.
    uint256 internal constant PREMIUM = 10e18;

    /// @notice Selector expected when PREMIUM is dispatched before ROLLOVER.
    /// @dev Literal selector for `CorkRolloverContract__PremiumBeforeRollover()`.
    bytes4 internal constant PREMIUM_BEFORE_ROLLOVER_SELECTOR =
        bytes4(keccak256("CorkRolloverContract__PremiumBeforeRollover()"));

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
            originSettler: address(settler),
            premiumToken: orderData.premiumToken,
            premium: premium,
            subFiller: bytes32(uint256(uint160(filler)))
        });
    }

    /// @notice Compromised approved Settler dispatches PREMIUM before any ROLLOVER has
    ///         fired: the rolloverContract reverts `CorkRolloverContract__PremiumBeforeRollover`.
    function testRevert_premium_beforeRollover_reverts() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _opened();
        RolloverTypes.FillContext memory fillContext = _fillContextPremium(orderData, PREMIUM);

        vm.expectRevert(PREMIUM_BEFORE_ROLLOVER_SELECTOR);
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

    /// @notice Regression: normal ROLLOVER → PREMIUM flow via `settler.fill` succeeds.
    function test_premium_afterRollover_succeeds() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _opened();
        _doRolloverAs(orderDigest, orderData, intent, FILL, filler);
        assertTrue(
            settler.rolloverAccountingOf(orderDigest).premiumFired,
            "premium must fire on happy path"
        );
    }

    /// @notice The reverting PREMIUM-before-ROLLOVER call must not mutate the rolloverContract's
    ///         per-filler latch — legitimate PREMIUM after the legitimate ROLLOVER must
    ///         remain reachable.
    function test_premium_orderingError_doesNotMutateLatch() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _opened();
        RolloverTypes.FillContext memory fillContext = _fillContextPremium(orderData, PREMIUM);

        vm.expectRevert(PREMIUM_BEFORE_ROLLOVER_SELECTOR);
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

        assertFalse(
            CorkRolloverContract(rolloverContract)
                .premiumFiredFor(orderDigest, filler, bytes32(uint256(uint160(filler)))),
            "rolloverContract premium latch must be untouched on revert"
        );

        // Legitimate ROLLOVER → PREMIUM must still succeed.
        _doRolloverAs(orderDigest, orderData, intent, FILL, filler);
        assertTrue(
            settler.rolloverAccountingOf(orderDigest).premiumFired,
            "legitimate premium must fire post-rollover"
        );
    }
}
