// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { FillScaffold } from "../../base/FillScaffold.sol";
import {
    ConsumeDstCptModule,
    DrainCaModule,
    SourceSrcCptModule
} from "../../mocks/modules/HookModules.sol";
import { CorkRolloverContract } from "src/CorkRolloverContract.sol";
import {
    CorkRolloverContract__MidPhaseDstCstDrain
} from "src/errors/CorkRolloverContractErrors.sol";
import { MarketId } from "src/interfaces/external/phoenix/IPoolManager.sol";
import { Typehashes } from "src/libraries/Typehashes.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice Regression coverage for PRE/MID-hook dstCST drain attempts through under-credited
///         `sharesOut`.
///
///         Previous mechanism: `_populateScratch` sealed `s.dstCstBefore`
///         BEFORE pre/mid hooks run. `_depositLeg` then computes
///         `sharesOut = balanceOf - s.dstCstBefore` against that same entry snapshot, so a
///         hook drain of `X` dstCST in PRE or MID is absorbed into `sharesOut = D - X`. The
///         rolloverContract transfers only `D - X` to the settler, leaving the rolloverContract balance back at
///         the entry snapshot, and the INV-5 floor check (`dstCstAfter >= dstCstBefore`)
///         passes silently — `X` dstCST sits with a hook-chosen recipient that paid no
///         premium.
///
///         Current mechanism: `_depositLeg` samples a local `dstCstAtDeposit`
///         snapshot after pre/mid hooks have already run. The deposit math now
///         reports `sharesOut = D` truthfully; the tail `safeTransfer(settler, D)` leaves
///         the rolloverContract at `entry - X`, and the INV-5 floor check fires with
///         `CorkRolloverContract__MidPhaseDstCstDrain(entry, entry - X)`.
///
///         Both tests below pin that post-fix behaviour: a hook drain of dstCST in PRE or
///         MID MUST revert with the INV-5 floor selector. Symmetric to the existing POST
///         bucket regression test `testRevert_rollover_dstCstNoDrainGuardStillHolds` at
///         `test/integration/rollover/HookRestructure.t.sol:529` (which already covered the
///         post-deposit drain path that the deposit-as-refill mechanism could not reach).
contract F01_DstCstDrainBracketTest is FillScaffold {
    /// @notice Canonical order size used by the regression scenarios.
    uint256 internal constant ORDER_SIZE = 1_000e18;

    /// @notice Full fill amount used to exercise one complete rollover leg.
    uint256 internal constant FILL = 1_000e18;

    /// @notice Existing dstCST inventory seeded on the rolloverContract before the hook drain.
    uint256 internal constant PRE_EXISTING_DST_CST = 250e18;

    /// @notice Amount a hostile hook attempts to drain before the deposit snapshot.
    uint256 internal constant DRAIN_AMOUNT = 200e18;

    /// @notice Recipient controlled by the simulated hostile hook.
    address internal hookAttacker = address(0xDEAD);

    /// @notice PRE hook module that sources the required srcCPT.
    SourceSrcCptModule internal sourceSrc;

    /// @notice POST hook module that consumes dstCPT after deposit.
    ConsumeDstCptModule internal consumeDst;

    /// @notice Malicious hook module used to drain token balances.
    DrainCaModule internal drain;

    /// @notice Test fixture setup.
    function setUp() public override {
        super.setUp();

        sourceSrc = new SourceSrcCptModule();
        consumeDst = new ConsumeDstCptModule();
        drain = new DrainCaModule();

        erc7484.setAttestedType(address(sourceSrc), Typehashes.MODULE_TYPE_PRE_ROLLOVER_HOOK);
        erc7484.setAttestedType(address(consumeDst), Typehashes.MODULE_TYPE_POST_ROLLOVER_HOOK);

        vm.label(address(sourceSrc), "sourceSrc");
        vm.label(address(consumeDst), "consumeDst");
        vm.label(address(drain), "drain");

        vm.startPrank(filler);
        srcCst.approve(address(settler), type(uint256).max);
        srcCst.approve(address(partialSettler), type(uint256).max);
        premiumToken.approve(address(settler), type(uint256).max);
        premiumToken.approve(address(partialSettler), type(uint256).max);
        vm.stopPrank();

        // Seed pre-existing dstCST inventory on the rolloverContract — the drain mechanism's source.
        dstCst.mint(rolloverContract, PRE_EXISTING_DST_CST);
    }

    /// @notice F-01 regression — MID bucket. A MID-hook that drains `X` dstCST out of the
    ///         rolloverContract between `_unwindLeg` and `_depositLeg` MUST revert with
    ///         `CorkRolloverContract__MidPhaseDstCstDrain` once DSR-2b's local snapshot prevents the
    ///         deposit math from absorbing the drain into `sharesOut = D - X`.
    function testRevert_F01_midHookDrainsRolloverContractDstCst_invokesInv5Floor() public {
        erc7484.setAttestedType(address(drain), Typehashes.MODULE_TYPE_MID_ROLLOVER_HOOK);

        RolloverTypes.OrderData memory orderData = _f01Order(1);
        RolloverTypes.Call[] memory midHooks = _drainHook(address(dstCst), DRAIN_AMOUNT);

        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupRollover(orderData, _preSourceSrc(FILL), midHooks, _postConsumeDst(FILL));

        vm.expectPartialRevert(CorkRolloverContract__MidPhaseDstCstDrain.selector);
        _doRolloverAs(orderDigest, orderData, intent, FILL, filler);
    }

    /// @notice F-01 regression — PRE bucket. Identical structure with the drain hook
    ///         attested and invoked in `preRolloverHooks` instead of `midRolloverHooks`.
    function testRevert_F01_preHookDrainsRolloverContractDstCst_invokesInv5Floor() public {
        erc7484.setAttestedType(address(drain), Typehashes.MODULE_TYPE_PRE_ROLLOVER_HOOK);

        RolloverTypes.OrderData memory orderData = _f01Order(2);

        // PRE bucket must still source srcCpt (the rollover precondition) AND run the
        // drain. Both hooks attested under PRE: sourceSrc by default in setUp, drain
        // attested per-test above.
        RolloverTypes.Call[] memory preHooks = new RolloverTypes.Call[](2);
        preHooks[0] = _hook(
            address(sourceSrc),
            abi.encodeWithSignature("execute(address,uint256)", address(srcCpt), FILL)
        );
        preHooks[1] = _hook(
            address(drain),
            abi.encodeWithSignature(
                "execute(address,address,uint256)", address(dstCst), hookAttacker, DRAIN_AMOUNT
            )
        );

        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupRollover(orderData, preHooks, _empty(), _postConsumeDst(FILL));

        vm.expectPartialRevert(CorkRolloverContract__MidPhaseDstCstDrain.selector);
        _doRolloverAs(orderDigest, orderData, intent, FILL, filler);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _f01Order(uint64 nonce)
        internal
        view
        returns (RolloverTypes.OrderData memory orderData)
    {
        orderData = _baseOrder();
        orderData.allowPartialFills = false;
        orderData.orderSize = ORDER_SIZE;
        orderData.orderSalt = nonce;
        orderData.rolloverParams = RolloverTypes.RolloverParams({
            srcCstToken: address(srcCst),
            dstCstToken: address(dstCst),
            minCaReceived: 0,
            minSharesOut: 0,
            srcPoolId: MarketId.unwrap(srcCst.poolId()),
            dstPoolId: MarketId.unwrap(dstCst.poolId()),
            settler: address(settler),
            jitMarketHash: bytes32(0)
        });
    }

    function _preSourceSrc(uint256 amount)
        internal
        view
        returns (RolloverTypes.Call[] memory hooks)
    {
        hooks = new RolloverTypes.Call[](1);
        hooks[0] = _hook(
            address(sourceSrc),
            abi.encodeWithSignature("execute(address,uint256)", address(srcCpt), amount)
        );
    }

    function _postConsumeDst(uint256 amount)
        internal
        view
        returns (RolloverTypes.Call[] memory hooks)
    {
        hooks = new RolloverTypes.Call[](1);
        hooks[0] = _hook(
            address(consumeDst),
            abi.encodeWithSignature("execute(address,uint256)", address(dstCpt), amount)
        );
    }

    function _drainHook(address token, uint256 amount)
        internal
        view
        returns (RolloverTypes.Call[] memory hooks)
    {
        hooks = new RolloverTypes.Call[](1);
        hooks[0] = _hook(
            address(drain),
            abi.encodeWithSignature("execute(address,address,uint256)", token, hookAttacker, amount)
        );
    }

    function _empty() internal pure returns (RolloverTypes.Call[] memory hooks) {
        hooks = new RolloverTypes.Call[](0);
    }

    function _setupRollover(
        RolloverTypes.OrderData memory orderData,
        RolloverTypes.Call[] memory pre,
        RolloverTypes.Call[] memory mid,
        RolloverTypes.Call[] memory post
    )
        internal
        returns (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        )
    {
        intent = _intentWithFourHooks(rolloverContract, bytes32(0), pre, mid, post, _empty());
        orderData.rolloverIntentHash = _zeroDigestHash(intent);
        orderDigest = _openOrder(orderData);
        intent.orderDigest = orderDigest;
        cptHolderSig = _signOrder(cptHolderPk, orderData);
    }
}
