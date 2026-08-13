// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { FillScaffold } from "../../base/FillScaffold.sol";
import { MockERC20 } from "../../mocks/MockERC20.sol";
import {
    ConsumeDstCptModule,
    DonateCaModule,
    DrainCaModule,
    SourceSrcCptModule,
    SwapCaModule
} from "../../mocks/modules/HookModules.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { CorkRolloverContract } from "src/CorkRolloverContract.sol";
import {
    CorkRolloverContract__CaInsufficientForDeposit,
    CorkRolloverContract__UnwindDepositShortfall
} from "src/errors/CorkRolloverContractErrors.sol";
import { MarketId } from "src/interfaces/external/phoenix/IPoolManager.sol";
import { Typehashes } from "src/libraries/Typehashes.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice INV-DST-FLOOR — `params.minSharesOut` is the load-bearing safety against mid-hook value-skim; the mid-hook MAY decrease caSrc (cross-CA rollover) and end-to-end value is guaranteed only by the deposit-side floor.
/// @custom:invariant INV-DST-FLOOR
contract MidHookDstFloorTest is FillScaffold {
    /// @notice Fill / unwind amount used by every scenario in this suite.
    uint256 internal constant FILL = 1_000e18;

    /// @notice Destination collateral asset (distinct from `caSrc`) used for cross-CA scenarios.
    MockERC20 internal caDst;

    /// @notice Source pool identifier (caSrc bound).
    MarketId internal srcPoolId;

    /// @notice Destination pool identifier (rebound per scenario to `caSrc` or `caDst`).
    MarketId internal dstPoolId;

    /// @notice Pre-rollover hook source for srcCPT.
    SourceSrcCptModule internal sourceSrc;

    /// @notice Post-rollover hook consumer for dstCPT.
    ConsumeDstCptModule internal consumeDst;

    /// @notice Mid-rollover hook that drains caSrc out of the rolloverContract.
    DrainCaModule internal drainCa;

    /// @notice Mid-rollover hook that donates caDst into the rolloverContract without consuming caSrc.
    DonateCaModule internal donateCa;

    /// @notice Mid-rollover hook that atomically swaps caSrc for caDst.
    SwapCaModule internal swapCa;

    /// @notice Sink address for caSrc drained by `SwapCaModule`.
    address internal swapSink = address(0xCA51);

    /// @notice Test fixture setup.
    function setUp() public override {
        super.setUp();

        caDst = new MockERC20("CA-dst", "CAD", 18);
        srcPoolId = srcCst.poolId();
        dstPoolId = dstCst.poolId();

        sourceSrc = new SourceSrcCptModule();
        consumeDst = new ConsumeDstCptModule();
        drainCa = new DrainCaModule();
        donateCa = new DonateCaModule();
        swapCa = new SwapCaModule();

        erc7484.setAttestedType(address(sourceSrc), Typehashes.MODULE_TYPE_PRE_ROLLOVER_HOOK);
        erc7484.setAttestedType(address(consumeDst), Typehashes.MODULE_TYPE_POST_ROLLOVER_HOOK);
        erc7484.setAttestedType(address(drainCa), Typehashes.MODULE_TYPE_MID_ROLLOVER_HOOK);
        erc7484.setAttestedType(address(donateCa), Typehashes.MODULE_TYPE_MID_ROLLOVER_HOOK);
        erc7484.setAttestedType(address(swapCa), Typehashes.MODULE_TYPE_MID_ROLLOVER_HOOK);

        vm.label(address(caDst), "caDst");
        vm.label(address(swapCa), "swapCa");
        vm.label(swapSink, "swapSink");

        vm.startPrank(filler);
        srcCst.approve(address(settler), type(uint256).max);
        srcCst.approve(address(partialSettler), type(uint256).max);
        vm.stopPrank();
    }

    // --- HELPERS ----------------------------------------------------------

    /// @dev Build an order template scoped to this scenario.
    function _order(uint64 nonce, uint256 minSharesOut)
        internal
        view
        returns (RolloverTypes.OrderData memory orderData)
    {
        orderData = _baseOrder();
        orderData.allowPartialFills = false;
        orderData.orderSize = FILL;
        orderData.orderSalt = nonce;
        orderData.rolloverParams = RolloverTypes.RolloverParams({
            srcCstToken: address(srcCst),
            dstCstToken: address(dstCst),
            minCaReceived: 0,
            minSharesOut: minSharesOut,
            srcPoolId: MarketId.unwrap(srcPoolId),
            dstPoolId: MarketId.unwrap(dstPoolId),
            settler: address(settler),
            jitMarketHash: bytes32(0)
        });
    }

    /// @dev Wrap a swap-style mid-hook in a one-element Call array.
    function _swapHook(uint256 amountIn, uint256 amountOut)
        internal
        view
        returns (RolloverTypes.Call[] memory hooks)
    {
        hooks = new RolloverTypes.Call[](1);
        hooks[0] = _hook(
            address(swapCa),
            abi.encodeWithSignature(
                "execute(address,address,uint256,address,uint256)",
                address(caSrc),
                swapSink,
                amountIn,
                address(caDst),
                amountOut
            )
        );
    }

    /// @dev Build the pre-hook that sources srcCPT for the leg.
    function _preSource(uint256 amount) internal view returns (RolloverTypes.Call[] memory hooks) {
        hooks = new RolloverTypes.Call[](1);
        hooks[0] = _hook(
            address(sourceSrc),
            abi.encodeWithSignature("execute(address,uint256)", address(srcCpt), amount)
        );
    }

    /// @dev Build the post-hook that consumes dstCPT at the end of the leg.
    function _postConsume(uint256 amount)
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

    /// @dev Build a zero-element hook array.
    function _none() internal pure returns (RolloverTypes.Call[] memory hooks) {
        hooks = new RolloverTypes.Call[](0);
    }

    /// @dev Sign the intent (with the zero-digest hash sealed into orderData) and open the order.
    function _prepIntent(
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
        intent = _intentWithFourHooks(rolloverContract, bytes32(0), pre, mid, post, _emptyHooks());
        orderData.rolloverIntentHash = _zeroDigestHash(intent);
        orderDigest = _openOrder(orderData);
        intent.orderDigest = orderDigest;
        cptHolderSig = _signOrder(cptHolderPk, orderData);
    }

    /// @dev Fire the atomic rollover+premium fill via Settler.fill (INV-ATOMIC-FILL-CANONICAL).
    function _fill(
        bytes32 orderDigest,
        RolloverTypes.OrderData memory orderData,
        RolloverTypes.RolloverIntent memory intent,
        bytes memory cptHolderSig
    ) internal {
        _doRolloverAs(orderDigest, orderData, intent, FILL, filler);
    }

    // --- SCENARIOS --------------------------------------------------------

    /// @notice Cross-CA happy path: swap consumes all caSrc, mints enough caDst to clear `minSharesOut`.
    function test_crossCa_midHookSwapsCaSrcToCaDst_succeeds() public {
        phoenixPool.bind(dstPoolId, dstCst, dstCpt, caDst);

        RolloverTypes.OrderData memory orderData = _order(1, FILL);
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepIntent(orderData, _preSource(FILL), _swapHook(FILL, FILL), _postConsume(FILL));

        uint256 fillerDstBefore = dstCst.balanceOf(filler);
        _fill(orderDigest, orderData, intent, cptHolderSig);

        assertEq(
            dstCst.balanceOf(filler) - fillerDstBefore,
            FILL,
            "dstCST forwarded to filler (atomic-fill)"
        );
        assertEq(caSrc.balanceOf(swapSink), FILL, "caSrc routed to swap sink");
        assertEq(caDst.balanceOf(rolloverContract), 0, "caDst fully deposited (no residual)");
    }

    /// @notice Cross-CA bad-rate swap: caDst produced is below `minSharesOut`; revert with `UnwindDepositShortfall`.
    function test_crossCa_midHookSwapsAtBadRate_revertsUnwindDepositShortfall() public {
        phoenixPool.bind(dstPoolId, dstCst, dstCpt, caDst);

        uint256 badRateOut = FILL / 20; // 5% of FILL
        RolloverTypes.OrderData memory orderData = _order(2, FILL);
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepIntent(
            orderData, _preSource(FILL), _swapHook(FILL, badRateOut), _postConsume(badRateOut)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContract__UnwindDepositShortfall.selector, badRateOut, FILL
            )
        );
        _fill(orderDigest, orderData, intent, cptHolderSig);
    }

    /// @notice Cross-CA pure drain: caSrc consumed, zero caDst produced; revert with `CaInsufficientForDeposit`.
    function test_crossCa_midHookConsumesAllCaSrcProducesZeroCaDst_revertsCaInsufficientForDeposit()
        public
    {
        phoenixPool.bind(dstPoolId, dstCst, dstCpt, caDst);

        RolloverTypes.OrderData memory orderData = _order(3, 0);
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepIntent(orderData, _preSource(FILL), _swapHook(FILL, 0), _postConsume(0));

        vm.expectRevert(CorkRolloverContract__CaInsufficientForDeposit.selector);
        _fill(orderDigest, orderData, intent, cptHolderSig);
    }

    /// @notice Cross-CA partial swap: 60% of caSrc consumed; residual stays in the rolloverContract.
    function test_crossCa_midHookConsumesPartialCaSrc_succeeds_residualStaysInRolloverContract()
        public
    {
        phoenixPool.bind(dstPoolId, dstCst, dstCpt, caDst);

        uint256 swapIn = (FILL * 60) / 100; // 600
        uint256 swapOut = (FILL * 80) / 100; // 800 (favourable rate covers the floor)
        uint256 floor = FILL / 4; // 250

        RolloverTypes.OrderData memory orderData = _order(4, floor);
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepIntent(
            orderData, _preSource(FILL), _swapHook(swapIn, swapOut), _postConsume(swapOut)
        );

        uint256 fillerDstBefore = dstCst.balanceOf(filler);
        _fill(orderDigest, orderData, intent, cptHolderSig);

        assertEq(dstCst.balanceOf(filler) - fillerDstBefore, swapOut, "dstCST forwarded == swapOut");
        assertEq(
            caSrc.balanceOf(rolloverContract),
            FILL - swapIn,
            "residual caSrc kept in rolloverContract"
        );
        assertEq(caSrc.balanceOf(swapSink), swapIn, "swap consumed caSrc routed to sink");
    }

    /// @notice Same-CA regression: empty mid-hooks, leg succeeds on default rebound (caSrc === caDst).
    function test_sameCa_midHookEmpty_stillSucceeds() public {
        // Default BaseTest binding already maps both pools to caSrc.
        RolloverTypes.OrderData memory orderData = _order(5, FILL);
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepIntent(orderData, _preSource(FILL), _none(), _postConsume(FILL));

        uint256 fillerDstBefore = dstCst.balanceOf(filler);
        _fill(orderDigest, orderData, intent, cptHolderSig);

        assertEq(dstCst.balanceOf(filler) - fillerDstBefore, FILL, "dstCST forwarded == FILL");
    }

    /// @notice Same-CA drain: malicious mid-hook drains all caSrc; `caForDeposit == 0` reverts `CaInsufficientForDeposit` (dst-side floor catches same-CA drain too, no special case needed).
    function test_sameCa_midHookDrainsCaSrc_revertsCaInsufficientForDeposit() public {
        // Default BaseTest binding maps both pools to caSrc, so caDst === caSrc.
        RolloverTypes.OrderData memory orderData = _order(6, 0);

        RolloverTypes.Call[] memory midHooks = new RolloverTypes.Call[](1);
        midHooks[0] = _hook(
            address(drainCa),
            abi.encodeWithSignature(
                "execute(address,address,uint256)", address(caSrc), swapSink, FILL
            )
        );

        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepIntent(orderData, _preSource(FILL), midHooks, _postConsume(0));

        vm.expectRevert(CorkRolloverContract__CaInsufficientForDeposit.selector);
        _fill(orderDigest, orderData, intent, cptHolderSig);
    }

    /// @notice Cross-CA boundary: swap calibrated to produce exactly `floor - 1` dstCST; reverts `UnwindDepositShortfall(floor - 1, floor)`.
    function test_crossCa_minSharesOutFloorIsLoadBearing_revertsExactlyBelowFloor() public {
        phoenixPool.bind(dstPoolId, dstCst, dstCpt, caDst);

        uint256 floor = FILL / 2; // 500
        uint256 swapOut = floor - 1; // 499
        RolloverTypes.OrderData memory orderData = _order(7, floor);
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepIntent(
            orderData, _preSource(FILL), _swapHook(FILL, swapOut), _postConsume(swapOut)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContract__UnwindDepositShortfall.selector, swapOut, floor
            )
        );
        _fill(orderDigest, orderData, intent, cptHolderSig);
    }
}
