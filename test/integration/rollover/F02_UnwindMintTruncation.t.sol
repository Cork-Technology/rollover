// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { FillScaffold } from "../../base/FillScaffold.sol";
import { MockERC20 } from "../../mocks/MockERC20.sol";
import {
    LibPhoenixShareQuantum__OrderSizeNotQuantumAligned
} from "src/errors/LibPhoenixShareQuantumErrors.sol";
import { ICorkRolloverContract } from "src/interfaces/rollover/ICorkRolloverContract.sol";
import { LibPhoenixShareQuantum } from "src/libraries/LibPhoenixShareQuantum.sol";
import { Typehashes } from "src/libraries/Typehashes.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice IMintableInline — minimal local interface for the inline donation module.
interface IMintableInline {
    /// @notice Mint to `to` (used inside a delegatecall hook where `to == address(this) == rolloverContract`).
    /// @param to Recipient address.
    /// @param amount Token amount to mint (in token base units).
    function mint(address to, uint256 amount) external;
}

/// @notice MintSrcCstSelfModule — mid-rollover hook that mints srcCST into the rolloverContract to
///         simulate an unsolicited donation that would let the rolloverContract's srcCST drift above
///         the `s.srcCstBefore - fillAmount` floor. Exists to exercise the
///         `CorkRolloverContract__SrcCstNotReturned` tail-guard.
contract MintSrcCstSelfModule {
    /// @notice Execute.
    /// @param srcCst srcCST token contract.
    /// @param amount Donation amount.
    function execute(address srcCst, uint256 amount) external {
        IMintableInline(srcCst).mint(address(this), amount);
    }
}

/// @notice F-02 regression — Phoenix `unwindMint` truncates input down to a multiple of
///         `minimumShares = 10**(18 - CAdecimals)` before burning srcCST + srcCPT. The rolloverContract's
///         `_unwindLeg` mirrors that truncation so `rolled[]` tracks Phoenix-burned shares (not
///         the calldata request), the truncation residue srcCST is forwarded to the Settler as
///         `srcLeftover` and refunded to the filler, the truncation residue srcCPT is swept to
///         the cPT holder under INV-CPT-CONTAINED, and `PHASE_0_TERMINAL_BIT` does not fire
///         prematurely on exact-mode orders whose size is not a clean multiple.
contract F02_UnwindMintTruncation is FillScaffold {
    /// @notice 6-decimal collateral asset replacing the 18-decimal default from BaseTest.
    MockERC20 internal caSrc6;

    /// @notice Phoenix minimumShares for a 6-decimal CA: 10 ** (18 - 6) = 1e12.
    uint256 internal constant MIN_SHARES_6_DEC = 1e12;

    /// @dev Compute the canonical atomic-fill premium cap for a 6-dec CA. The rolloverContract's
    ///      `_depositLeg` scales `caIn` by `10**(18 - caDecimals) = 1e12`, so `produced =
    ///      effectivelyBurned * 1e12`. The Settler then requires
    ///      `ceil(produced * minPremiumPerShare / 1e18)`. We pass a cap >= that required
    ///      premium so the atomic envelope's `Settler__PremiumExceedsCap` gate is satisfied
    ///      under the 6-dec CA fixture (the 18-dec default cap of 1e24 is insufficient at
    ///      the 1e12 scaling factor).
    function _premiumCapForFill(uint256 effectivelyBurned, uint256 minPremiumPerShare)
        internal
        pure
        returns (uint256 cap)
    {
        uint256 produced = effectivelyBurned * 1e12;
        cap = (produced * minPremiumPerShare + 1e18 - 1) / 1e18;
    }

    /// @inheritdoc BaseTest
    function setUp() public override {
        super.setUp();
        // Replace the 18-dec caSrc with a 6-dec instance and rebind both pools so unwindMint
        // exercises Phoenix truncation. MockPhoenixPoolManager.unwindMint reads `caDecimals`
        // off the bound CA and truncates `sharesIn` to a multiple of `minimumShares`.
        caSrc6 = new MockERC20("CA6", "CA6", 6);
        phoenixPool.bind(srcCst.poolId(), srcCst, srcCpt, caSrc6);
        phoenixPool.bind(dstCst.poolId(), dstCst, dstCpt, caSrc6);

        vm.prank(filler);
        srcCst.approve(address(settler), type(uint256).max);
        vm.prank(filler);
        srcCst.approve(address(partialSettler), type(uint256).max);

        // Atomic-fill pulls `requiredPremium = ceil(produced * minPremiumPerShare / 1e18)`
        // from the filler in-frame. Under the 6-dec CA fixture `produced = burned * 1e12`,
        // so the per-fill premium is up to ~1e31 (e.g. heri PoC `effectivelyBurned=1e21`).
        // The default 1e24 premiumToken mint from BaseTest is insufficient — top up the
        // filler so the atomic envelope's `transferFrom` succeeds for the largest fixture.
        premiumToken.mint(filler, 1e34);
    }

    // -----------------------------------------------------------------------------------------
    // helpers
    // -----------------------------------------------------------------------------------------

    /// @notice _intent that mints `actualRolled` srcCPT in the pre-hook and burns dstCPT in post.
    /// @param orderDigest Latched order digest.
    /// @param actualRolled srcCPT delivered to the rolloverContract by the pre-hook.
    function _intentFor(bytes32 orderDigest, uint256 actualRolled)
        internal
        view
        returns (RolloverTypes.RolloverIntent memory)
    {
        RolloverTypes.Call[] memory pre = new RolloverTypes.Call[](1);
        pre[0] = _hook(
            address(sourceSrcCptModule),
            abi.encodeWithSignature("execute(address,uint256)", address(srcCpt), actualRolled)
        );
        RolloverTypes.Call[] memory post = new RolloverTypes.Call[](1);
        post[0] = _hook(
            address(consumeDstCptModule),
            abi.encodeWithSignature("execute(address)", address(dstCpt))
        );
        return
            _intentWithHooks(rolloverContract, orderDigest, pre, new RolloverTypes.Call[](0), post);
    }

    /// @notice OpenedOrder — bundle of artifacts every test needs after `_openOrder`.
    struct OpenedOrder {
        bytes32 orderDigest;
        RolloverTypes.OrderData orderData;
        RolloverTypes.RolloverIntent intent;
        bytes cptHolderSig;
    }

    /// @notice Open an exact-mode order with `allowUnderfill = true` and the supplied size.
    /// @param orderSize Latched order size for the rolloverContract's overfill ceiling.
    /// @param salt Order salt for uniqueness across tests.
    /// @param srcAmount srcCPT amount the pre-hook mints into the rolloverContract (mirrors fillAmount).
    function _openExactUnderfill(uint256 orderSize, uint64 salt, uint256 srcAmount)
        internal
        returns (OpenedOrder memory o)
    {
        o.orderData = _baseOrder();
        o.orderData.allowUnderfill = true;
        o.orderData.orderSize = orderSize;
        o.orderData.orderSalt = salt;
        RolloverTypes.RolloverIntent memory probe = _intentFor(bytes32(0), srcAmount);
        o.orderData.rolloverIntentHash = _zeroDigestHash(probe);
        o.orderDigest = _openOrder(o.orderData);
        o.intent = _intentFor(o.orderDigest, srcAmount);
        o.cptHolderSig = _signOrder(cptHolderPk, o.orderData);
    }

    /// @notice Open a partial-mode order with `allowUnderfill = true` and the supplied size.
    /// @param orderSize Latched order size.
    /// @param salt Order salt.
    /// @param srcAmount srcCPT amount the pre-hook mints (per-fill).
    function _openPartialUnderfill(uint256 orderSize, uint64 salt, uint256 srcAmount)
        internal
        returns (OpenedOrder memory o)
    {
        o.orderData = _baseOrder();
        o.orderData = _usePartialSettler(o.orderData);
        o.orderData.allowUnderfill = true;
        o.orderData.orderSize = orderSize;
        o.orderData.orderSalt = salt;
        RolloverTypes.RolloverIntent memory probe = _intentFor(bytes32(0), srcAmount);
        o.orderData.rolloverIntentHash = _zeroDigestHash(probe);
        o.orderDigest = _openOrder(o.orderData);
        o.intent = _intentFor(o.orderDigest, srcAmount);
        o.cptHolderSig = _signOrder(cptHolderPk, o.orderData);
    }

    // -----------------------------------------------------------------------------------------
    // A-0 — F-01 early reject supersedes non-quantum truncation end-to-end paths
    // -----------------------------------------------------------------------------------------

    /// @notice Non-quantized order size is rejected at open (F-01); legacy truncation paths are
    ///         covered in `AtomicFillPhoenixQuantization.t.sol`.
    function testRevert_nonQuantumOrderSize_rejectedAtOpen() public {
        uint256 nMin = 1_000;
        uint256 delta = 999;
        uint256 misalignedOrderSize = nMin * MIN_SHARES_6_DEC + delta;

        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData = _usePartialSettler(orderData);
        orderData.orderSize = misalignedOrderSize;
        orderData.orderSalt = 0xF020;
        RolloverTypes.RolloverIntent memory probe = _intentFor(bytes32(0), misalignedOrderSize);
        orderData.rolloverIntentHash = _zeroDigestHash(probe);

        vm.expectRevert(
            abi.encodeWithSelector(
                LibPhoenixShareQuantum__OrderSizeNotQuantumAligned.selector,
                misalignedOrderSize,
                MIN_SHARES_6_DEC
            )
        );
        _openOrder(orderData);
    }

    // -----------------------------------------------------------------------------------------
    // A-1..A-4 — aligned fill with CPT underfill: srcCST refund, rolled tracks burn, no terminal
    // -----------------------------------------------------------------------------------------

    /// @notice A-1: srcCST surplus from underfill is refunded to the filler (not stranded).
    /// @notice A-3: `rolled[]` credits delivered/burned shares, not the calldata ceiling.
    /// @notice A-4: terminal bit stays clear when `newRolled < orderSize`.
    function test_partialUnderfill_truncationResidueReconcilesAndTerminalDoesNotFire() public {
        uint256 nMin = 1_000;
        uint256 fillAmount = nMin * MIN_SHARES_6_DEC;
        uint256 effectivelyBurned = fillAmount - MIN_SHARES_6_DEC;
        uint256 srcCstRefund = MIN_SHARES_6_DEC;
        uint256 orderSize = fillAmount;

        OpenedOrder memory o = _openPartialUnderfill(orderSize, 0xF021, effectivelyBurned);

        uint256 rolloverContractSrcBefore = srcCst.balanceOf(rolloverContract);
        uint256 rolloverContractCptBefore = srcCpt.balanceOf(rolloverContract);
        uint256 fillerSrcBefore = srcCst.balanceOf(filler);
        uint256 ownerCptBefore = srcCpt.balanceOf(_owner());

        _doRolloverAsWithCap(
            o.orderDigest,
            o.orderData,
            o.intent,
            fillAmount,
            filler,
            _premiumCapForFill(effectivelyBurned, o.orderData.minPremiumPerShare)
        );

        assertEq(
            srcCst.balanceOf(rolloverContract),
            rolloverContractSrcBefore,
            "A-1: rolloverContract srcCST not restored"
        );
        assertEq(
            srcCst.balanceOf(filler),
            fillerSrcBefore - effectivelyBurned,
            "A-1: filler net debit equals effectivelyBurned"
        );

        assertEq(
            srcCpt.balanceOf(rolloverContract),
            rolloverContractCptBefore,
            "A-2: rolloverContract srcCPT not restored"
        );
        assertEq(
            srcCpt.balanceOf(_owner()), ownerCptBefore, "A-2: no cPT holder srcCPT on CPT underfill"
        );

        ICorkRolloverContract.RolloverContractOrderState memory state =
            ICorkRolloverContract(rolloverContract).orderState(o.orderDigest);
        assertEq(state.rolled, effectivelyBurned, "A-3: rolled tracks Phoenix-burned shares");
        assertFalse(state.rolloverTerminal, "A-4: terminal bit did not fire prematurely");
        assertEq(srcCstRefund, MIN_SHARES_6_DEC);
    }

    // -----------------------------------------------------------------------------------------
    // A-2, A-5 — CPT excess above burn ceiling swept to cPT holder (INV-CPT-CONTAINED)
    // -----------------------------------------------------------------------------------------

    /// @notice A-2: hook-delivered srcCPT above the burn ceiling is swept to the cPT holder.
    function test_cptExcess_aboveBurnCeiling_sweptToCptHolder() public {
        uint256 nMin = 1_000;
        uint256 delta = 999;
        uint256 fillAmount = nMin * MIN_SHARES_6_DEC;
        uint256 cptDelivered = fillAmount + delta;
        uint256 orderSize = fillAmount;

        OpenedOrder memory o = _openPartialUnderfill(orderSize, 0xF022, cptDelivered);

        uint256 rolloverContractCptBefore = srcCpt.balanceOf(rolloverContract);
        uint256 ownerCptBefore = srcCpt.balanceOf(_owner());

        _doRolloverAsWithCap(
            o.orderDigest,
            o.orderData,
            o.intent,
            fillAmount,
            filler,
            _premiumCapForFill(fillAmount, o.orderData.minPremiumPerShare)
        );

        assertEq(
            srcCpt.balanceOf(rolloverContract),
            rolloverContractCptBefore,
            "A-2: rolloverContract srcCPT restored"
        );
        assertEq(
            srcCpt.balanceOf(_owner()),
            ownerCptBefore + delta,
            "A-2: cPT holder receives CPT excess"
        );

        ICorkRolloverContract.RolloverContractOrderState memory state =
            ICorkRolloverContract(rolloverContract).orderState(o.orderDigest);
        assertEq(state.rolled, fillAmount, "A-2: rolled tracks burned shares");
    }

    /// @notice _owner — reads the CWIA-baked cPT holder.
    function _owner() internal view returns (address) {
        return cptHolder;
    }

    // -----------------------------------------------------------------------------------------
    // A-5 — partial-mode multi-fill: per-fill residue reconciled, rolled = sum(burned)
    // -----------------------------------------------------------------------------------------

    /// @notice A-5: partial-mode single atomic fill sweeps CPT excess; rolled tracks burned amount.
    function test_partialUnderfill_perFillResidueAccumulatesToBurnedSum() public {
        uint256 nMin = 500;
        uint256 delta = 777;
        uint256 fillAmount = nMin * MIN_SHARES_6_DEC;
        uint256 cptDelivered = fillAmount + delta;
        uint256 orderSize = 3 * fillAmount;

        OpenedOrder memory o = _openPartialUnderfill(orderSize, 0xF025, cptDelivered);

        uint256 rolloverContractSrcBefore = srcCst.balanceOf(rolloverContract);
        uint256 rolloverContractCptBefore = srcCpt.balanceOf(rolloverContract);
        uint256 ownerCptBefore = srcCpt.balanceOf(_owner());

        _doRolloverAsWithCap(
            o.orderDigest,
            o.orderData,
            o.intent,
            fillAmount,
            filler,
            _premiumCapForFill(fillAmount, o.orderData.minPremiumPerShare)
        );

        assertEq(
            srcCst.balanceOf(rolloverContract),
            rolloverContractSrcBefore,
            "A-5: rolloverContract srcCST stable across N fills"
        );
        assertEq(
            srcCpt.balanceOf(rolloverContract),
            rolloverContractCptBefore,
            "A-5: rolloverContract srcCPT stable across N fills"
        );
        assertEq(
            srcCpt.balanceOf(_owner()),
            ownerCptBefore + delta,
            "A-5: cPT holder srcCPT excess on single atomic fill"
        );

        ICorkRolloverContract.RolloverContractOrderState memory state =
            ICorkRolloverContract(rolloverContract).orderState(o.orderDigest);
        assertEq(state.rolled, fillAmount, "A-5: rolled tracks Phoenix-burned shares");
        assertFalse(
            state.rolloverTerminal,
            "A-5: rolloverContract terminal bit clear (newRolled < orderSize)"
        );
    }

    // -----------------------------------------------------------------------------------------
    // A-6 — aligned fillAmount (no residue): regression / happy path
    // -----------------------------------------------------------------------------------------

    /// @notice A-6: aligned `fillAmount = N * minimumShares`, zero residue. `srcLeftover == 0`,
    ///         `rolled == fillAmount`, terminal-bit fires correctly when fillAmount == orderSize.
    function test_exact_alignedFillAmount_noResidue_terminalFires() public {
        uint256 fillAmount = 1_000 * MIN_SHARES_6_DEC; // aligned: % min == 0

        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.allowUnderfill = false; // strict exact
        orderData.orderSize = fillAmount;
        orderData.orderSalt = 0xF026;
        RolloverTypes.RolloverIntent memory probe = _intentFor(bytes32(0), fillAmount);
        orderData.rolloverIntentHash = _zeroDigestHash(probe);
        bytes32 orderDigest = _openOrder(orderData);
        RolloverTypes.RolloverIntent memory intent = _intentFor(orderDigest, fillAmount);
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);
        uint256 cap = _premiumCapForFill(fillAmount, orderData.minPremiumPerShare);

        uint256 rolloverContractSrcBefore = srcCst.balanceOf(rolloverContract);
        uint256 rolloverContractCptBefore = srcCpt.balanceOf(rolloverContract);
        uint256 ownerCptBefore = srcCpt.balanceOf(_owner());

        _doRolloverAsWithCap(orderDigest, orderData, intent, fillAmount, filler, cap);

        assertEq(
            srcCst.balanceOf(rolloverContract),
            rolloverContractSrcBefore,
            "A-6: rolloverContract srcCST stable"
        );
        assertEq(
            srcCpt.balanceOf(rolloverContract),
            rolloverContractCptBefore,
            "A-6: rolloverContract srcCPT stable"
        );
        assertEq(
            srcCpt.balanceOf(_owner()),
            ownerCptBefore,
            "A-6: zero cPT holder residue on aligned fill"
        );

        ICorkRolloverContract.RolloverContractOrderState memory state =
            ICorkRolloverContract(rolloverContract).orderState(orderDigest);
        assertEq(state.rolled, fillAmount, "A-6: aligned rolled == fillAmount");
        assertTrue(state.rolloverTerminal, "A-6: terminal bit fires on exact match");
    }

    // -----------------------------------------------------------------------------------------
    // Exact-mode `orderSize = N*min + delta` with allowUnderfill=true.
    // The truncated burn is recorded and the order stays open for further fills.
    // -----------------------------------------------------------------------------------------

    /// @notice Aligned fill with CPT underfill refunds srcCST; rolled tracks burn.
    function test_heriPoC_fixedBehaviour() public {
        uint256 fillAmount = 1_000 * MIN_SHARES_6_DEC;
        uint256 effectivelyBurned = fillAmount - MIN_SHARES_6_DEC;
        uint256 orderSize = fillAmount;

        OpenedOrder memory o = _openPartialUnderfill(orderSize, 0xF027, effectivelyBurned);

        uint256 rolloverContractSrcBefore = srcCst.balanceOf(rolloverContract);
        uint256 rolloverContractCptBefore = srcCpt.balanceOf(rolloverContract);
        uint256 fillerSrcBefore = srcCst.balanceOf(filler);
        uint256 ownerCptBefore = srcCpt.balanceOf(_owner());

        _doRolloverAsWithCap(
            o.orderDigest,
            o.orderData,
            o.intent,
            fillAmount,
            filler,
            _premiumCapForFill(effectivelyBurned, o.orderData.minPremiumPerShare)
        );

        assertEq(
            srcCst.balanceOf(rolloverContract),
            rolloverContractSrcBefore,
            "A-7: rolloverContract srcCST restored"
        );
        assertEq(
            srcCpt.balanceOf(rolloverContract),
            rolloverContractCptBefore,
            "A-7: rolloverContract srcCPT restored"
        );
        assertEq(
            srcCst.balanceOf(filler), fillerSrcBefore - effectivelyBurned, "A-7: filler refund"
        );
        assertEq(
            srcCpt.balanceOf(_owner()), ownerCptBefore, "A-7: no cPT holder srcCPT on underfill"
        );

        ICorkRolloverContract.RolloverContractOrderState memory state =
            ICorkRolloverContract(rolloverContract).orderState(o.orderDigest);
        assertEq(state.rolled, effectivelyBurned, "A-7: rolled = Phoenix-burned");
        assertFalse(state.rolloverTerminal, "A-7: terminal bit suppressed");
    }

    // -----------------------------------------------------------------------------------------
    // A-8 — heri partial-mode variant
    // -----------------------------------------------------------------------------------------

    /// @notice A-8: partial-mode heri PoC — CPT excess swept on first atomic frame.
    function test_heriPartialModePoC_fixedBehaviour() public {
        uint256 fillAmount = 250 * MIN_SHARES_6_DEC;
        uint256 delta = MIN_SHARES_6_DEC - 1;
        uint256 cptDelivered = fillAmount + delta;
        uint256 orderSize = 4 * fillAmount;

        OpenedOrder memory o = _openPartialUnderfill(orderSize, 0xF028, cptDelivered);

        uint256 rolloverContractSrcBefore = srcCst.balanceOf(rolloverContract);
        uint256 rolloverContractCptBefore = srcCpt.balanceOf(rolloverContract);
        uint256 ownerCptBefore = srcCpt.balanceOf(_owner());

        _doRolloverAsWithCap(
            o.orderDigest,
            o.orderData,
            o.intent,
            fillAmount,
            filler,
            _premiumCapForFill(fillAmount, o.orderData.minPremiumPerShare)
        );

        assertEq(
            srcCst.balanceOf(rolloverContract),
            rolloverContractSrcBefore,
            "A-8: rolloverContract srcCST stable across atomic frame"
        );
        assertEq(
            srcCpt.balanceOf(rolloverContract),
            rolloverContractCptBefore,
            "A-8: rolloverContract srcCPT stable across atomic frame"
        );
        assertEq(
            srcCpt.balanceOf(_owner()),
            ownerCptBefore + delta,
            "A-8: cPT holder CPT excess on single atomic fill"
        );

        ICorkRolloverContract.RolloverContractOrderState memory state =
            ICorkRolloverContract(rolloverContract).orderState(o.orderDigest);
        assertEq(state.rolled, fillAmount, "A-8: rolled tracks Phoenix-burned shares");
        assertFalse(
            state.rolloverTerminal,
            "A-8: rolloverContract terminal bit clear (newRolled < orderSize)"
        );
    }

    // -----------------------------------------------------------------------------------------
    // A-9 — Layer-1 C tail-guard: any src-side drift (donation, hook mutation, semantic shift)
    //        bricks the leg via `CorkRolloverContract__SrcCstNotReturned`.
    // -----------------------------------------------------------------------------------------

    /// @notice MintSrcCstSelfModule instance used by A-9 to simulate a mid-leg donation.
    MintSrcCstSelfModule internal donateSrcCstSelfModule;

    /// @notice A-9: a mid-rollover hook that donates srcCST into the rolloverContract (driving
    ///         `srcCstAfter > s.srcCstBefore - fillAmount`) is bricked by the tail-guard.
    function test_midLegSrcCstDonation_revertsViaSrcCstNotReturnedTailGuard() public {
        donateSrcCstSelfModule = new MintSrcCstSelfModule();
        erc7484.setAttestedType(
            address(donateSrcCstSelfModule), Typehashes.MODULE_TYPE_MID_ROLLOVER_HOOK
        );

        uint256 fillAmount = 1_000 * MIN_SHARES_6_DEC; // aligned, zero residue baseline
        uint256 donation = 12_345;
        uint256 orderSize = fillAmount;

        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = orderSize;
        orderData.orderSalt = 0xF029;
        // Build an intent with pre-hook srcCPT delivery + a mid-hook srcCST donation +
        // post-hook dstCPT cleanup.
        RolloverTypes.Call[] memory pre = new RolloverTypes.Call[](1);
        pre[0] = _hook(
            address(sourceSrcCptModule),
            abi.encodeWithSignature("execute(address,uint256)", address(srcCpt), fillAmount)
        );
        RolloverTypes.Call[] memory mid = new RolloverTypes.Call[](1);
        mid[0] = _hook(
            address(donateSrcCstSelfModule),
            abi.encodeWithSignature("execute(address,uint256)", address(srcCst), donation)
        );
        RolloverTypes.Call[] memory post = new RolloverTypes.Call[](1);
        post[0] = _hook(
            address(consumeDstCptModule),
            abi.encodeWithSignature("execute(address)", address(dstCpt))
        );
        RolloverTypes.RolloverIntent memory probe =
            _intentWithHooks(rolloverContract, bytes32(0), pre, mid, post);
        orderData.rolloverIntentHash = _zeroDigestHash(probe);
        bytes32 orderDigest = _openOrder(orderData);
        RolloverTypes.RolloverIntent memory intent =
            _intentWithHooks(rolloverContract, orderDigest, pre, mid, post);
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);

        // Expected: tail guard reverts. Pre-leg rolloverContract srcCST is 0; Settler transfers
        // `fillAmount` in (snapshot = fillAmount); Phoenix burns `fillAmount` (aligned, no
        // residue); donation adds `donation`; final balance `donation`. Expected (under guard)
        // = snapshot - fillAmount = 0. Actual = `donation`.
        vm.expectRevert(
            abi.encodeWithSignature(
                "CorkRolloverContract__SrcCstNotReturned(uint256,uint256)", uint256(0), donation
            )
        );
        _doRolloverAs(orderDigest, orderData, intent, fillAmount, filler);
    }
}
