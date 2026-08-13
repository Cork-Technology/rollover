// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {
    CorkRolloverContractFactory__SettlerNotApproved
} from "src/errors/CorkRolloverContractFactoryErrors.sol";

import { BaseTest } from "../../base/BaseTest.sol";
import { ICorkRolloverContract } from "src/interfaces/rollover/ICorkRolloverContract.sol";
import {
    ICorkRolloverContractFactory
} from "src/interfaces/rollover/ICorkRolloverContractFactory.sol";
import { IRolloverHookDispatcher } from "src/interfaces/rollover/IRolloverHookDispatcher.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice Regression: under atomic-fill, factory `executeIntentHooks` policy-gate reverts
///         (e.g. `revokeSettler` / `INV-SETTLER-APPROVED`) propagate through `Settler.fill`
///         and roll back the entire transaction — no partial latch commit.
contract PremiumFactoryRevocationPropagatesTest is BaseTest {
    /// @notice ROLLOVER fill size in srcCST units used by the regression scenario.
    uint256 internal constant FILL_AMOUNT = 1_000e18;
    /// @notice PREMIUM amount in premium-token units paid on the second leg.
    uint256 internal constant PREMIUM = 10e18;

    /// @notice Fixture: max-approve Settler for srcCst + premiumToken from the filler.
    function setUp() public override {
        super.setUp();

        vm.prank(filler);
        srcCst.approve(address(settler), type(uint256).max);
        srcCst.approve(address(partialSettler), type(uint256).max);
        vm.prank(filler);
        premiumToken.approve(address(settler), type(uint256).max);
        premiumToken.approve(address(partialSettler), type(uint256).max);
        // `BaseTest.setUp` already runs `factory.approveSettler(address(settler))` from the
        // test contract (which is the factory admin), so no extra approval needed here.
    }

    /// @notice `revokeSettler` rejects the atomic fill at the factory allowlist gate inside
    ///         `executeIntentHooks` with `CorkRolloverContractFactory__SettlerNotApproved`. The whole tx
    ///         rolls back — balances and both premium latches untouched. Re-approval permits retry.
    function test_revokeSettler_revertsAtomicFillBeforePremiumDispatch() public {
        (
            bytes32 orderDigest,
            RolloverTypes.OrderData memory orderData,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupExactOrderWithEmptyPremium(uint64(1));

        // Factory admin revokes the Settler BEFORE any fill (instant kill-switch).
        factory.revokeSettler(address(settler));

        uint256 fillerPremiumBefore = premiumToken.balanceOf(filler);
        uint256 rolloverContractPremiumBefore = premiumToken.balanceOf(rolloverContract);
        uint256 settlerPremiumBefore = premiumToken.balanceOf(address(settler));

        // Atomic fill must propagate the factory's allowlist revert verbatim.
        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContractFactory__SettlerNotApproved.selector, address(settler)
            )
        );
        _fillRollover(orderDigest, orderData, intent, cptHolderSig, FILL_AMOUNT, filler);

        // Balances: nothing moved. Whole atomic frame rolled back.
        assertEq(premiumToken.balanceOf(filler), fillerPremiumBefore);
        assertEq(premiumToken.balanceOf(rolloverContract), rolloverContractPremiumBefore);
        assertEq(premiumToken.balanceOf(address(settler)), settlerPremiumBefore);
        assertFalse(
            ICorkRolloverContract(rolloverContract)
                .premiumFiredFor(orderDigest, filler, bytes32(uint256(uint160(filler))))
        );

        // Re-approve and retry — atomic fill succeeds (kill-switch is reversible).
        factory.approveSettler(address(settler));
        _fillRollover(orderDigest, orderData, intent, cptHolderSig, FILL_AMOUNT, filler);

        assertTrue(
            settler.rolloverAccountingOf(orderDigest).premiumFired,
            "Settler premiumFired latched on retry after re-approval"
        );
    }

    // --- minimal scaffolding copy-paste-free helpers --------------------------

    function _setupExactOrderWithEmptyPremium(uint64 salt)
        internal
        returns (
            bytes32 orderDigest,
            RolloverTypes.OrderData memory orderData,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        )
    {
        orderData = _baseExactOrder(salt);
        // Empty premiumHooks is sufficient: this test exercises the factory gate, not the
        // rolloverContract-side hook chain. cPT holder signs the intent with a zero-hook PREMIUM bucket.
        RolloverTypes.Call[] memory emptyHooks = new RolloverTypes.Call[](0);
        intent = _buildIntentWithSrcPostHooks(bytes32(0), FILL_AMOUNT, emptyHooks);
        orderData.rolloverIntentHash = _zeroDigestHash(intent);
        orderDigest = _openOrder(orderData);
        intent.orderDigest = orderDigest;
        cptHolderSig = _signOrder(cptHolderPk, orderData);
    }

    function _baseExactOrder(uint64 salt)
        internal
        view
        returns (RolloverTypes.OrderData memory od)
    {
        od = _baseOrder();
        od.orderSalt = salt;
        od.allowPartialFills = false;
    }

    function _buildIntentWithSrcPostHooks(
        bytes32 orderDigest,
        uint256 srcAmount,
        RolloverTypes.Call[] memory premiumHooks
    ) internal view returns (RolloverTypes.RolloverIntent memory) {
        RolloverTypes.Call[] memory pre = new RolloverTypes.Call[](1);
        pre[0] = _hook(
            address(sourceSrcCptModule),
            abi.encodeWithSignature("execute(address,uint256)", address(srcCpt), srcAmount)
        );
        RolloverTypes.Call[] memory post = new RolloverTypes.Call[](1);
        post[0] = _hook(
            address(consumeDstCptModule),
            abi.encodeWithSignature("execute(address)", address(dstCpt))
        );
        return _intentWithFourHooks(
            rolloverContract, orderDigest, pre, new RolloverTypes.Call[](0), post, premiumHooks
        );
    }

    function _fillRollover(
        bytes32 orderDigest,
        RolloverTypes.OrderData memory orderData,
        RolloverTypes.RolloverIntent memory intent,
        bytes memory cptHolderSig,
        uint256 fillAmount,
        address fillerAddr
    ) internal {
        bytes memory originData = _originData(orderData);
        bytes memory cptHolderOrderSig = _signOrder(cptHolderPk, orderData);
        bytes memory rolloverLeg = _pfrpRolloverLeg(fillAmount, fillerAddr, intent, cptHolderSig);
        bytes memory fillerData =
            abi.encode(uint8(255), rolloverLeg, uint256(1_000_000e18), cptHolderOrderSig);
        vm.prank(fillerAddr);
        settler.fill(orderDigest, originData, fillerData);
    }

    function _pfrpRolloverLeg(
        uint256 fillAmount,
        address fillerAddr,
        RolloverTypes.RolloverIntent memory intent,
        bytes memory cptHolderSig
    ) private pure returns (bytes memory) {
        return abi.encode(
            uint8(RolloverTypes.HookPhase.ROLLOVER),
            fillAmount,
            uint256(0),
            fillerAddr,
            address(0),
            intent,
            cptHolderSig,
            uint256(0),
            bytes(""),
            bytes32(0),
            bytes("")
        );
    }

    /// @dev Legacy `_fillPremium` — under atomic-fill the premium leg is glued to rollover.
    ///      Standalone PREMIUM dispatch is no longer supported. Preserved as no-op so the
    ///      callsites compile; the rollover call already paid premium.
    function _fillPremium(
        bytes32, /* orderDigest */
        RolloverTypes.OrderData memory, /* orderData */
        RolloverTypes.RolloverIntent memory, /* intent */
        bytes memory, /* cptHolderSig */
        uint256, /* premium */
        address /* fillerAddr */
    ) internal pure { /* atomic-fill already paid premium */ }
}
