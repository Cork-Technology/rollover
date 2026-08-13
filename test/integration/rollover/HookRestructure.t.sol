// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { FillScaffold } from "../../base/FillScaffold.sol";
import { MockERC20 } from "../../mocks/MockERC20.sol";
import { MockPhoenixPoolManagerNoCptGetter } from "../../mocks/MockPhoenix.sol";
import {
    ConsumeDstCptModule,
    DepositDstCptModule,
    DonateCaModule,
    DrainCaModule,
    MockYieldVault,
    NoopPreModule,
    OverSourceSrcCptModule,
    PremiumDepositIntoVaultModule,
    PremiumRouteModule,
    SourceSrcCptModule
} from "../../mocks/modules/HookModules.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { BaseSettler } from "src/BaseSettler.sol";
import { CorkRolloverContract } from "src/CorkRolloverContract.sol";
import { ExactSettler as Settler } from "src/ExactSettler.sol";
import {
    CorkRolloverContract__MidPhaseDstCstDrain,
    CorkRolloverContract__ModuleTypeMismatch,
    CorkRolloverContract__PoolManagerCallFailed
} from "src/errors/CorkRolloverContractErrors.sol";
import {
    Settler__AtomicFillRequired,
    Settler__DstCstNotCanonical,
    Settler__SrcCstNotCanonical
} from "src/errors/SettlerErrors.sol";
import { IERC7484 } from "src/interfaces/external/erc7484/IERC7484.sol";
import { IPoolManager, MarketId } from "src/interfaces/external/phoenix/IPoolManager.sol";
import { ICorkRolloverContract } from "src/interfaces/rollover/ICorkRolloverContract.sol";
import { IRolloverContractLens } from "src/interfaces/rollover/IRolloverContractLens.sol";
import { LibHookPhase } from "src/libraries/LibHookPhase.sol";
import { Typehashes } from "src/libraries/Typehashes.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice 4-hook RolloverIntent (pre/mid/post rollover + premium) dispatch ordering and INV-CPT-CONTAINED.
/// @custom:invariant INV-CPT-CONTAINED
contract HookRestructureTest is FillScaffold {
    /// @notice Order_size.
    uint256 internal constant ORDER_SIZE = 1_000e18;

    /// @notice Fill.
    uint256 internal constant FILL = 1_000e18;

    /// @notice Premium.
    uint256 internal constant PREMIUM = 10e18;

    /// @notice Intent phase fired.
    /// @param orderDigest orderDigest.
    /// @param phase phase.
    /// @param filler filler.
    /// @param requestedFillAmount requestedFillAmount.
    /// @param actualRolled actualRolled.
    /// @param cumulativeRolled cumulativeRolled.
    /// @param rolloverTerminal rolloverTerminal.
    /// @param dstProduced dstProduced.
    /// @param premium premium.
    event IntentPhaseFired(
        bytes32 indexed orderDigest,
        uint8 indexed phase,
        address indexed filler,
        uint256 requestedFillAmount,
        uint256 actualRolled,
        uint256 cumulativeRolled,
        bool rolloverTerminal,
        uint256 dstProduced,
        uint256 premium
    );

    /// @notice Ca dst.
    MockERC20 internal caDst;

    /// @notice Src pool id.
    MarketId internal srcPoolId;

    /// @notice Dst pool id.
    MarketId internal dstPoolId;

    /// @notice Source src.
    SourceSrcCptModule internal sourceSrc;

    /// @notice Consume dst.
    ConsumeDstCptModule internal consumeDst;

    /// @notice Deposit dst.
    DepositDstCptModule internal depositDst;

    /// @notice Drain ca.
    DrainCaModule internal drainCa;

    /// @notice Donate ca.
    DonateCaModule internal donateCa;

    /// @notice Over source src.
    OverSourceSrcCptModule internal overSourceSrc;

    /// @notice Noop pre.
    NoopPreModule internal noopPre;

    /// @notice Premium route.
    PremiumRouteModule internal premiumRoute;

    /// @notice Premium sink.
    address internal premiumSink = address(0xBEEF);

    /// @notice Dst cpt vault.
    address internal dstCptVault = address(0xFEED);

    /// @notice Test fixture setup.
    function setUp() public override {
        super.setUp();

        caDst = new MockERC20("CA-dst", "CAD", 18);
        srcPoolId = srcCst.poolId();
        dstPoolId = dstCst.poolId();

        sourceSrc = new SourceSrcCptModule();
        consumeDst = new ConsumeDstCptModule();
        depositDst = new DepositDstCptModule();
        drainCa = new DrainCaModule();
        donateCa = new DonateCaModule();
        overSourceSrc = new OverSourceSrcCptModule();
        noopPre = new NoopPreModule();
        premiumRoute = new PremiumRouteModule();

        erc7484.setAttestedType(address(sourceSrc), Typehashes.MODULE_TYPE_PRE_ROLLOVER_HOOK);
        erc7484.setAttestedType(address(overSourceSrc), Typehashes.MODULE_TYPE_PRE_ROLLOVER_HOOK);
        erc7484.setAttestedType(address(noopPre), Typehashes.MODULE_TYPE_PRE_ROLLOVER_HOOK);
        erc7484.setAttestedType(address(drainCa), Typehashes.MODULE_TYPE_MID_ROLLOVER_HOOK);
        erc7484.setAttestedType(address(donateCa), Typehashes.MODULE_TYPE_MID_ROLLOVER_HOOK);
        erc7484.setAttestedType(address(consumeDst), Typehashes.MODULE_TYPE_POST_ROLLOVER_HOOK);
        erc7484.setAttestedType(address(depositDst), Typehashes.MODULE_TYPE_POST_ROLLOVER_HOOK);
        erc7484.setAttestedType(address(premiumRoute), Typehashes.MODULE_TYPE_EXECUTOR);

        vm.label(address(caDst), "caDst");
        vm.label(address(sourceSrc), "sourceSrc");
        vm.label(address(consumeDst), "consumeDst");
        vm.label(address(depositDst), "depositDst");
        vm.label(address(drainCa), "drainCa");
        vm.label(address(overSourceSrc), "overSourceSrc");
        vm.label(address(noopPre), "noopPre");
        vm.label(address(premiumRoute), "premiumRoute");

        vm.startPrank(filler);
        srcCst.approve(address(settler), type(uint256).max);
        srcCst.approve(address(partialSettler), type(uint256).max);
        premiumToken.approve(address(settler), type(uint256).max);
        premiumToken.approve(address(partialSettler), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice _restructure order.
    function _restructureOrder(uint64 nonce)
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
            srcPoolId: MarketId.unwrap(srcPoolId),
            dstPoolId: MarketId.unwrap(dstPoolId),
            settler: address(settler),
            jitMarketHash: bytes32(0)
        });
    }

    /// @notice _pre source.
    function _preSource(uint256 amount) internal view returns (RolloverTypes.Call[] memory hooks) {
        hooks = new RolloverTypes.Call[](1);
        hooks[0] = _hook(
            address(sourceSrc),
            abi.encodeWithSignature("execute(address,uint256)", address(srcCpt), amount)
        );
    }

    /// @notice _post consume.
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

    /// @notice _empty.
    function _empty() internal pure returns (RolloverTypes.Call[] memory hooks) {
        hooks = new RolloverTypes.Call[](0);
    }

    /// @notice _setup rollover intent.
    function _setupRolloverIntent(
        RolloverTypes.OrderData memory orderData,
        RolloverTypes.Call[] memory pre,
        RolloverTypes.Call[] memory mid,
        RolloverTypes.Call[] memory post,
        RolloverTypes.Call[] memory prem
    )
        internal
        returns (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        )
    {
        intent = _intentWithFourHooks(rolloverContract, bytes32(0), pre, mid, post, prem);
        orderData.rolloverIntentHash = _zeroDigestHash(intent);
        orderDigest = _openOrder(orderData);
        intent.orderDigest = orderDigest;
        cptHolderSig = _signOrder(cptHolderPk, orderData);
    }

    /// @notice _fill rollover — under atomic-fill (INV-ATOMIC-FILL-CANONICAL) this
    ///         performs the full admit → rollover → premium → settle in one frame.
    ///         For exact-mode tests the order ends Settled; for partial-mode tests the
    ///         caller's slot is fully settled while the order remains Opened.
    function _fillRollover(
        bytes32 orderDigest,
        RolloverTypes.OrderData memory orderData,
        RolloverTypes.RolloverIntent memory intent,
        bytes memory cptHolderSig,
        uint256 fillAmount
    ) internal {
        _doRolloverAs(orderDigest, orderData, intent, fillAmount, filler);
    }

    /// @notice _fill premium — see _fillRollover; the atomic dispatcher glues both legs.
    function _fillPremium(
        bytes32 orderDigest,
        RolloverTypes.OrderData memory orderData,
        RolloverTypes.RolloverIntent memory intent,
        bytes memory cptHolderSig,
        uint256 premium
    ) internal { }

    /// @notice rollover full mode pushes src cst and sources src cpt burns both equally mints dst cst and dst cpt.
    function test_rollover_fullMode_pushesSrcCstAndSourcesSrcCpt_burnsBothEqually_mintsDstCstAndDstCpt()
        public
    {
        RolloverTypes.OrderData memory orderData = _restructureOrder(1);
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupRolloverIntent(
            orderData, _preSource(FILL), _empty(), _postConsume(FILL), _empty()
        );

        uint256 fillerDstBefore = dstCst.balanceOf(filler);
        _fillRollover(orderDigest, orderData, intent, cptHolderSig, FILL);

        assertEq(srcCpt.balanceOf(rolloverContract), 0, "srcCPT fully burned");
        assertEq(dstCpt.balanceOf(rolloverContract), 0, "dstCPT fully consumed");
        assertEq(srcCst.balanceOf(rolloverContract), 0, "srcCST fully unwound");
        // INV-ATOMIC-FILL-CANONICAL: dstCST forwarded to filler in same frame.
        assertEq(
            dstCst.balanceOf(filler) - fillerDstBefore,
            FILL,
            "dstCST forwarded to filler (atomic-fill)"
        );
    }

    /// @notice event intent phase fired expanded exact rollover fields.
    function test_event_intentPhaseFired_expandedExactRolloverFields() public {
        RolloverTypes.OrderData memory orderData = _restructureOrder(101);
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupRolloverIntent(
            orderData, _preSource(FILL), _empty(), _postConsume(FILL), _empty()
        );

        vm.expectEmit(true, true, true, true, rolloverContract);
        emit IntentPhaseFired(
            orderDigest,
            uint8(RolloverTypes.HookPhase.ROLLOVER),
            filler,
            FILL,
            FILL,
            FILL,
            true,
            FILL,
            0
        );
        _fillRollover(orderDigest, orderData, intent, cptHolderSig, FILL);
    }

    /// @notice event intent phase fired expanded partial rollover fields.
    function test_event_intentPhaseFired_expandedPartialRolloverFields() public {
        RolloverTypes.OrderData memory orderData = _restructureOrder(102);
        orderData = _usePartialSettler(orderData);
        uint256 half = FILL / 2;
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupRolloverIntent(
            orderData, _preSource(half), _empty(), _postConsume(half), _empty()
        );

        vm.expectEmit(true, true, true, true, rolloverContract);
        emit IntentPhaseFired(
            orderDigest,
            uint8(RolloverTypes.HookPhase.ROLLOVER),
            filler,
            half,
            half,
            half,
            false,
            half,
            0
        );
        _fillRollover(orderDigest, orderData, intent, cptHolderSig, half);
    }

    /// @notice event intent phase fired expanded premium fields. Under atomic-fill the
    ///         PREMIUM phase event is emitted within the same Settler frame as ROLLOVER;
    ///         the assertion is placed before the atomic call to consume the PREMIUM emit.
    function test_event_intentPhaseFired_expandedPremiumFields() public {
        RolloverTypes.OrderData memory orderData = _restructureOrder(103);
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupRolloverIntent(
            orderData, _preSource(FILL), _empty(), _postConsume(FILL), _empty()
        );

        vm.expectEmit(true, true, true, true, rolloverContract);
        emit IntentPhaseFired(
            orderDigest,
            uint8(RolloverTypes.HookPhase.PREMIUM),
            filler,
            0,
            0,
            FILL,
            true,
            0,
            PREMIUM
        );
        _fillRollover(orderDigest, orderData, intent, cptHolderSig, FILL);
    }

    /// @notice rollover underfill mode sources less src cpt burns min of both refunds leftover src cst.
    function test_rollover_underfillMode_sourcesLessSrcCpt_burnsMinOfBoth_refundsLeftoverSrcCst()
        public
    {
        RolloverTypes.OrderData memory orderData = _restructureOrder(2);
        orderData = _usePartialSettler(orderData);
        orderData.allowUnderfill = true;
        uint256 sourced = 700e18;
        uint256 fillerBefore = srcCst.balanceOf(filler);

        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupRolloverIntent(
            orderData, _preSource(sourced), _empty(), _postConsume(sourced), _empty()
        );

        uint256 fillerDstBefore = dstCst.balanceOf(filler);
        _fillRollover(orderDigest, orderData, intent, cptHolderSig, FILL);

        assertEq(
            dstCst.balanceOf(filler) - fillerDstBefore,
            sourced,
            "dstCST minted to filler == sourced amount (atomic-fill)"
        );
        assertEq(
            fillerBefore - srcCst.balanceOf(filler),
            sourced,
            "filler net srcCST cost == actually rolled (leftover refunded)"
        );
    }

    /// @notice rollover same ca token between pools mid hook empty succeeds.
    function test_rollover_sameCaTokenBetweenPools_midHookEmpty_succeeds() public {
        phoenixPool.bind(srcPoolId, srcCst, srcCpt, caSrc);
        phoenixPool.bind(dstPoolId, dstCst, dstCpt, caSrc);

        RolloverTypes.OrderData memory orderData = _restructureOrder(3);
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupRolloverIntent(
            orderData, _preSource(FILL), _empty(), _postConsume(FILL), _empty()
        );

        uint256 fillerDstBefore = dstCst.balanceOf(filler);
        _fillRollover(orderDigest, orderData, intent, cptHolderSig, FILL);

        assertEq(dstCst.balanceOf(filler) - fillerDstBefore, FILL);
    }

    /// @notice rollover different ca tokens between pools mid hook swaps succeeds.
    function test_rollover_differentCaTokensBetweenPools_midHookSwaps_succeeds() public {
        phoenixPool.bind(dstPoolId, dstCst, dstCpt, caDst);
        RolloverTypes.OrderData memory orderData = _restructureOrder(4);

        RolloverTypes.Call[] memory midHooks = new RolloverTypes.Call[](1);
        midHooks[0] = _hook(
            address(donateCa),
            abi.encodeWithSignature("execute(address,uint256)", address(caDst), FILL)
        );

        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupRolloverIntent(
            orderData, _preSource(FILL), midHooks, _postConsume(FILL), _empty()
        );

        uint256 fillerDstBefore = dstCst.balanceOf(filler);
        _fillRollover(orderDigest, orderData, intent, cptHolderSig, FILL);

        assertEq(dstCst.balanceOf(filler) - fillerDstBefore, FILL);
    }

    /// @notice rollover post hook consumes all dst cpt succeeds.
    function test_rollover_postHookConsumesAllDstCpt_succeeds() public {
        RolloverTypes.OrderData memory orderData = _restructureOrder(5);
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupRolloverIntent(
            orderData, _preSource(FILL), _empty(), _postConsume(FILL), _empty()
        );

        _fillRollover(orderDigest, orderData, intent, cptHolderSig, FILL);

        assertEq(
            dstCpt.balanceOf(rolloverContract),
            0,
            "rolloverContract holds zero dstCPT post-rollover"
        );
    }

    /// @notice rollover post hook deposits dst cpt into vault succeeds.
    function test_rollover_postHookDepositsDstCptIntoVault_succeeds() public {
        RolloverTypes.OrderData memory orderData = _restructureOrder(6);

        RolloverTypes.Call[] memory postHooks = new RolloverTypes.Call[](1);
        postHooks[0] = _hook(
            address(depositDst),
            abi.encodeWithSignature(
                "execute(address,address,uint256)", address(dstCpt), dstCptVault, FILL
            )
        );

        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupRolloverIntent(orderData, _preSource(FILL), _empty(), postHooks, _empty());

        _fillRollover(orderDigest, orderData, intent, cptHolderSig, FILL);

        assertEq(dstCpt.balanceOf(rolloverContract), 0, "rolloverContract exits with zero dstCPT");
        assertEq(dstCpt.balanceOf(dstCptVault), FILL, "vault received dstCPT");
    }

    /// @notice reverts when rollover pre hook fails to deliver src cpt reverts src cpt shortfall.
    function testRevert_rollover_preHookFailsToDeliverSrcCpt_revertsSrcCptShortfall() public {
        RolloverTypes.OrderData memory orderData = _restructureOrder(7);

        RolloverTypes.Call[] memory preHooks = new RolloverTypes.Call[](1);
        preHooks[0] = _hook(address(noopPre), abi.encodeWithSignature("execute()"));

        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupRolloverIntent(orderData, preHooks, _empty(), _empty(), _empty());

        bytes memory originData = _originData(orderData);
        bytes memory fillerData = _rolloverFillerData(FILL, intent, cptHolderSig);

        vm.expectRevert(
            abi.encodeWithSignature(
                "CorkRolloverContract__SrcCptShortfall(uint256,uint256)", FILL, 0
            )
        );
        vm.prank(filler);
        settler.fill(orderDigest, originData, fillerData);
    }

    /// @notice rollover pre hook over delivers src cpt refunds leftover to cptHolder does not revert.
    function test_rollover_preHookOverDeliversSrcCpt_refundsLeftoverToCptHolder_doesNotRevert()
        public
    {
        RolloverTypes.OrderData memory orderData = _restructureOrder(8);
        uint256 over = 50e18;

        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupRolloverIntent(
            orderData, _preSource(FILL + over), _empty(), _postConsume(FILL), _empty()
        );

        uint256 cptHolderBefore = srcCpt.balanceOf(cptHolder);
        uint256 fillerDstBefore = dstCst.balanceOf(filler);
        _fillRollover(orderDigest, orderData, intent, cptHolderSig, FILL);

        assertEq(
            srcCpt.balanceOf(cptHolder) - cptHolderBefore,
            over,
            "excess srcCPT refunded to cPT holder"
        );
        assertEq(
            dstCst.balanceOf(filler) - fillerDstBefore,
            FILL,
            "dstCST minted to filler == fillAmount"
        );
    }

    /// @notice reverts when rollover unwind mint below min ca received reverts insufficient collateral.
    function testRevert_rollover_unwindMintBelowMinCaReceived_revertsInsufficientCollateral()
        public
    {
        RolloverTypes.OrderData memory orderData = _restructureOrder(9);
        orderData.rolloverParams.minCaReceived = FILL + 1;

        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupRolloverIntent(
            orderData, _preSource(FILL), _empty(), _postConsume(FILL), _empty()
        );

        bytes memory originData = _originData(orderData);
        bytes memory fillerData = _rolloverFillerData(FILL, intent, cptHolderSig);

        vm.expectRevert(
            abi.encodeWithSignature(
                "CorkRolloverContract__UnwindMintShortfall(uint256,uint256)", FILL, FILL + 1
            )
        );
        vm.prank(filler);
        settler.fill(orderDigest, originData, fillerData);
    }

    /// @notice reverts when rollover unwind deposit below min shares out reverts insufficient shares out.
    function testRevert_rollover_unwindDepositBelowMinSharesOut_revertsInsufficientSharesOut()
        public
    {
        RolloverTypes.OrderData memory orderData = _restructureOrder(11);
        orderData.rolloverParams.minSharesOut = FILL + 1;

        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupRolloverIntent(
            orderData, _preSource(FILL), _empty(), _postConsume(FILL), _empty()
        );

        bytes memory originData = _originData(orderData);
        bytes memory fillerData = _rolloverFillerData(FILL, intent, cptHolderSig);

        vm.expectRevert(
            abi.encodeWithSignature(
                "CorkRolloverContract__UnwindDepositShortfall(uint256,uint256)", FILL, FILL + 1
            )
        );
        vm.prank(filler);
        settler.fill(orderDigest, originData, fillerData);
    }

    /// @notice reverts when rollover post hook leaves dst cpt in rolloverContract — INV-CPT-CONTAINED
    ///         bidirectional guard rejects via `CorkRolloverContract__DstCptNotRestored(expected, actual)`.
    function testRevert_rollover_postHookLeavesDstCptInRolloverContract_revertsDstCptNotRestored()
        public
    {
        RolloverTypes.OrderData memory orderData = _restructureOrder(12);

        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupRolloverIntent(orderData, _preSource(FILL), _empty(), _empty(), _empty());

        bytes memory originData = _originData(orderData);
        bytes memory fillerData = _rolloverFillerData(FILL, intent, cptHolderSig);

        vm.expectRevert(
            abi.encodeWithSignature(
                "CorkRolloverContract__DstCptNotRestored(uint256,uint256)", 0, FILL
            )
        );
        vm.prank(filler);
        settler.fill(orderDigest, originData, fillerData);
    }

    /// @notice reverts when rollover src cst no drain guard still holds.
    function testRevert_rollover_srcCstNoDrainGuardStillHolds() public {
        erc7484.setAttestedType(address(drainCa), Typehashes.MODULE_TYPE_PRE_ROLLOVER_HOOK);
        RolloverTypes.OrderData memory orderData = _restructureOrder(13);

        RolloverTypes.Call[] memory preHooks = new RolloverTypes.Call[](2);
        preHooks[0] = _hook(
            address(sourceSrc),
            abi.encodeWithSignature("execute(address,uint256)", address(srcCpt), FILL)
        );
        preHooks[1] = _hook(
            address(drainCa),
            abi.encodeWithSignature(
                "execute(address,address,uint256)", address(srcCst), address(0xDEAD), FILL
            )
        );

        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupRolloverIntent(orderData, preHooks, _empty(), _empty(), _empty());

        bytes memory originData = _originData(orderData);
        bytes memory fillerData = _rolloverFillerData(FILL, intent, cptHolderSig);

        vm.expectRevert();
        vm.prank(filler);
        settler.fill(orderDigest, originData, fillerData);
    }

    /// @notice reverts when rollover dst cst no drain guard still holds.
    function testRevert_rollover_dstCstNoDrainGuardStillHolds() public {
        dstCst.mint(rolloverContract, 100e18);

        erc7484.setAttestedType(address(drainCa), Typehashes.MODULE_TYPE_POST_ROLLOVER_HOOK);

        RolloverTypes.OrderData memory orderData = _restructureOrder(14);

        RolloverTypes.Call[] memory postHooks = new RolloverTypes.Call[](2);
        postHooks[0] = _hook(
            address(consumeDst),
            abi.encodeWithSignature("execute(address,uint256)", address(dstCpt), FILL)
        );
        postHooks[1] = _hook(
            address(drainCa),
            abi.encodeWithSignature(
                "execute(address,address,uint256)", address(dstCst), address(0xDEAD), 50e18
            )
        );

        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupRolloverIntent(orderData, _preSource(FILL), _empty(), postHooks, _empty());

        bytes memory originData = _originData(orderData);
        bytes memory fillerData = _rolloverFillerData(FILL, intent, cptHolderSig);

        vm.expectPartialRevert(CorkRolloverContract__MidPhaseDstCstDrain.selector);
        vm.prank(filler);
        settler.fill(orderDigest, originData, fillerData);
    }

    /// @notice srcPoolId mismatch is rejected at the Settler-level canonical-cST gate
    ///         (INV-CST-CANONICAL). The revert now fires inside `openFor` because the gate
    ///         runs at admission, before any rolloverContract dispatch.
    function testRevert_rollover_srcPoolIdMismatch_reverts() public {
        RolloverTypes.OrderData memory orderData = _restructureOrder(15);
        orderData.rolloverParams.srcPoolId = keccak256("wrong-pool");

        // shares(wrong-pool).swapToken == address(0) != orderData.srcCstToken
        vm.expectPartialRevert(Settler__SrcCstNotCanonical.selector);
        _setupRolloverIntent(orderData, _preSource(FILL), _empty(), _postConsume(FILL), _empty());
    }

    /// @notice dstPoolId mismatch is rejected at the Settler-level canonical-cST gate
    ///         (INV-CST-CANONICAL). The revert now fires inside `openFor` because the gate
    ///         runs at admission, before any rolloverContract dispatch.
    function testRevert_rollover_dstPoolIdMismatch_reverts() public {
        RolloverTypes.OrderData memory orderData = _restructureOrder(16);
        orderData.rolloverParams.dstPoolId = keccak256("wrong-pool");

        vm.expectPartialRevert(Settler__DstCstNotCanonical.selector);
        _setupRolloverIntent(orderData, _preSource(FILL), _empty(), _postConsume(FILL), _empty());
    }

    /// @notice premium cptHolder transfers premium anywhere succeeds no drain guard removed.
    function test_premium_cptHolderTransfersPremiumAnywhere_succeeds_noDrainGuardRemoved() public {
        RolloverTypes.OrderData memory orderData = _restructureOrder(17);

        RolloverTypes.Call[] memory premHooks = new RolloverTypes.Call[](1);
        premHooks[0] = _hook(
            address(premiumRoute),
            abi.encodeWithSignature(
                "execute(address,address,uint256)", address(premiumToken), premiumSink, PREMIUM
            )
        );

        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupRolloverIntent(
            orderData, _preSource(FILL), _empty(), _postConsume(FILL), premHooks
        );

        _fillRollover(orderDigest, orderData, intent, cptHolderSig, FILL);

        _fillPremium(orderDigest, orderData, intent, cptHolderSig, PREMIUM);

        assertEq(premiumToken.balanceOf(premiumSink), PREMIUM, "premium routed to sink");
        assertEq(
            premiumToken.balanceOf(rolloverContract),
            0,
            "rolloverContract holds zero premium post-fire"
        );
    }

    /// @notice premium partial fill race filler a fires before filler b rolls succeeds.
    ///         Under atomic-fill the premium fires in-frame with the rollover; the
    ///         per-slice premium = sliceA * minPremiumPerShare / 1e18 = 500e18 * 1e16 / 1e18 = 5e18.
    function test_premium_partialFillRace_fillerA_firesBeforeFillerB_rolls_succeeds() public {
        RolloverTypes.OrderData memory orderData = _restructureOrder(18);
        orderData = _usePartialSettler(orderData);
        uint256 sliceA = 500e18;
        uint256 sliceAPremium = sliceA * orderData.minPremiumPerShare / 1e18;

        RolloverTypes.Call[] memory premHooks = new RolloverTypes.Call[](1);
        premHooks[0] = _hook(
            address(premiumRoute),
            abi.encodeWithSignature(
                "execute(address,address,uint256)",
                address(premiumToken),
                premiumSink,
                sliceAPremium
            )
        );

        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupRolloverIntent(
            orderData, _preSource(sliceA), _empty(), _postConsume(sliceA), premHooks
        );

        _fillRollover(orderDigest, orderData, intent, cptHolderSig, sliceA);

        assertEq(premiumToken.balanceOf(premiumSink), sliceAPremium);
    }

    /// @notice premium per filler latch independent of other fillers.
    function test_premium_perFillerLatch_independentOfOtherFillers() public {
        address fillerB = address(0xF2);
        srcCst.mint(fillerB, 1_000_000e18);
        premiumToken.mint(fillerB, 1_000_000e18);
        vm.startPrank(fillerB);
        srcCst.approve(address(settler), type(uint256).max);
        srcCst.approve(address(partialSettler), type(uint256).max);
        premiumToken.approve(address(settler), type(uint256).max);
        premiumToken.approve(address(partialSettler), type(uint256).max);
        vm.stopPrank();

        RolloverTypes.OrderData memory orderData = _restructureOrder(19);
        orderData = _usePartialSettler(orderData);
        uint256 sliceA = 500e18;
        uint256 sliceB = 500e18;
        uint256 slicePremium = sliceA * orderData.minPremiumPerShare / 1e18;

        RolloverTypes.Call[] memory premHooks = new RolloverTypes.Call[](1);
        premHooks[0] = _hook(
            address(premiumRoute),
            abi.encodeWithSignature(
                "execute(address,address,uint256)", address(premiumToken), premiumSink, slicePremium
            )
        );

        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupRolloverIntent(
            orderData, _preSource(sliceA), _empty(), _postConsume(sliceA), premHooks
        );

        _fillRollover(orderDigest, orderData, intent, cptHolderSig, sliceA);

        // Per-filler premium-fired bit independence: under atomic-fill, fillerA's atomic
        // fill flips ONLY fillerA's bit; fillerB's bit stays clear. We record this
        // immediately after fillerA's fill (and before fillerB's would-be fill).
        assertTrue(
            IRolloverContractLens(address(factory))
                .premiumFiredFor(
                    rolloverContract, orderDigest, filler, bytes32(uint256(uint160(filler)))
                ),
            "fillerA premium-fired bit set"
        );
        assertFalse(
            IRolloverContractLens(address(factory))
                .premiumFiredFor(
                    rolloverContract, orderDigest, fillerB, bytes32(uint256(uint160(fillerB)))
                ),
            "fillerB's bit untouched by A's premium fire"
        );

        _doRolloverAs(orderDigest, orderData, intent, sliceB, fillerB);

        assertTrue(
            IRolloverContractLens(address(factory))
                .premiumFiredFor(
                    rolloverContract, orderDigest, fillerB, bytes32(uint256(uint160(fillerB)))
                ),
            "fillerB premium-fired after second fill"
        );
    }

    /// @notice premium cptHolder deposits premium into yield vault succeeds demonstrates answer r.
    function test_premium_cptHolderDepositsPremiumIntoYieldVault_succeeds_demonstratesAnswerR()
        public
    {
        MockYieldVault vault = new MockYieldVault();
        PremiumDepositIntoVaultModule depositPremium = new PremiumDepositIntoVaultModule();
        erc7484.setAttestedType(address(depositPremium), Typehashes.MODULE_TYPE_EXECUTOR);

        RolloverTypes.OrderData memory orderData = _restructureOrder(95);
        RolloverTypes.Call[] memory premHooks = new RolloverTypes.Call[](1);
        premHooks[0] = _hook(
            address(depositPremium),
            abi.encodeWithSignature(
                "execute(address,address,uint256)", address(premiumToken), address(vault), PREMIUM
            )
        );

        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupRolloverIntent(
            orderData, _preSource(FILL), _empty(), _postConsume(FILL), premHooks
        );

        _fillRollover(orderDigest, orderData, intent, cptHolderSig, FILL);
        _fillPremium(orderDigest, orderData, intent, cptHolderSig, PREMIUM);

        assertEq(
            vault.depositOf(rolloverContract),
            PREMIUM,
            "vault holds the premium for the rolloverContract"
        );
        assertEq(
            premiumToken.balanceOf(rolloverContract), 0, "rolloverContract exits with zero premium"
        );
    }

    /// @notice cpt rolloverContract holds zero allowance on src cpt post rollover.
    function test_cpt_rolloverContractHoldsZeroAllowanceOnSrcCpt_postRollover() public {
        RolloverTypes.OrderData memory orderData = _restructureOrder(20);
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupRolloverIntent(
            orderData, _preSource(FILL), _empty(), _postConsume(FILL), _empty()
        );

        _fillRollover(orderDigest, orderData, intent, cptHolderSig, FILL);

        assertEq(srcCpt.allowance(rolloverContract, address(phoenixPool)), 0);
        assertEq(srcCpt.allowance(rolloverContract, address(this)), 0);
        assertEq(srcCpt.allowance(rolloverContract, address(settler)), 0);
    }

    /// @notice cpt rolloverContract holds zero allowance on dst cpt post rollover.
    function test_cpt_rolloverContractHoldsZeroAllowanceOnDstCpt_postRollover() public {
        RolloverTypes.OrderData memory orderData = _restructureOrder(21);
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupRolloverIntent(
            orderData, _preSource(FILL), _empty(), _postConsume(FILL), _empty()
        );

        _fillRollover(orderDigest, orderData, intent, cptHolderSig, FILL);

        assertEq(dstCpt.allowance(rolloverContract, address(phoenixPool)), 0);
        assertEq(dstCpt.allowance(rolloverContract, address(this)), 0);
        assertEq(dstCpt.allowance(rolloverContract, address(settler)), 0);
    }

    /// @notice reverts when cpt external cannot pull dst cpt after real rollover.
    function testRevert_cpt_externalCannotPullDstCptAfterRealRollover() public {
        RolloverTypes.OrderData memory orderData = _restructureOrder(96);
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupRolloverIntent(
            orderData, _preSource(FILL), _empty(), _postConsume(FILL), _empty()
        );
        _fillRollover(orderDigest, orderData, intent, cptHolderSig, FILL);

        assertEq(dstCpt.balanceOf(rolloverContract), 0, "dstCPT contained post-leg");
        assertEq(dstCpt.allowance(rolloverContract, address(0xDADA)), 0, "no standing allowance");
        vm.expectPartialRevert(IERC20Errors.ERC20InsufficientAllowance.selector);
        vm.prank(address(0xDADA));
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        dstCpt.transferFrom(rolloverContract, address(0xDADA), 1);
    }

    /// @notice Under tag-routed fill (INV-FILL-TAG-DISPATCH), unsupported legacy
    ///         phase classes PRE/MID/POST (tags = 2/3/4) revert with
    ///         `Settler__AtomicFillRequired` at admission, BEFORE the phase
    ///         discriminant ever reaches `LibHookPhase.from`.
    function test_fill_phaseValuePreMidPost_revertsAtomicFillRequired() public {
        RolloverTypes.OrderData memory orderData = _restructureOrder(97);
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupRolloverIntent(
            orderData, _preSource(FILL), _empty(), _postConsume(FILL), _empty()
        );

        bytes memory originData = _originData(orderData);
        uint8[4] memory deadPhases = [uint8(2), uint8(3), uint8(4), type(uint8).max - 1];
        for (uint256 i = 0; i < deadPhases.length; ++i) {
            bytes memory empty;
            bytes memory fillerData = abi.encode(
                deadPhases[i],
                FILL,
                uint256(0),
                filler,
                address(0),
                intent,
                cptHolderSig,
                uint256(0),
                empty,
                bytes32(0),
                cptHolderSig
            );

            vm.expectRevert(Settler__AtomicFillRequired.selector);
            vm.prank(filler);
            settler.fill(orderDigest, originData, fillerData);
        }
    }

    /// @notice A module attested only for PREMIUM cannot execute in the PRE bucket.
    function test_executeIntentCalls_premiumAttestedModule_usedInPreSlot_revertsModuleTypeMismatch()
        public
    {
        erc7484.setAttestedType(address(sourceSrc), Typehashes.MODULE_TYPE_EXECUTOR);
        RolloverTypes.OrderData memory orderData = _restructureOrder(91);
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupRolloverIntent(
            orderData, _preSource(FILL), _empty(), _postConsume(FILL), _empty()
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContract__ModuleTypeMismatch.selector,
                address(sourceSrc),
                Typehashes.MODULE_TYPE_PRE_ROLLOVER_HOOK
            )
        );
        _fillRollover(orderDigest, orderData, intent, cptHolderSig, FILL);
    }

    /// @notice A module attested only for PRE cannot execute in the MID bucket.
    function test_executeIntentCalls_preAttestedModule_usedInMidSlot_revertsModuleTypeMismatch()
        public
    {
        erc7484.setAttestedType(address(donateCa), Typehashes.MODULE_TYPE_PRE_ROLLOVER_HOOK);
        RolloverTypes.Call[] memory mid = new RolloverTypes.Call[](1);
        mid[0] = _hook(
            address(donateCa),
            abi.encodeWithSignature("execute(address,uint256)", address(caSrc), uint256(0))
        );
        RolloverTypes.OrderData memory orderData = _restructureOrder(92);
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupRolloverIntent(orderData, _preSource(FILL), mid, _postConsume(FILL), _empty());

        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContract__ModuleTypeMismatch.selector,
                address(donateCa),
                Typehashes.MODULE_TYPE_MID_ROLLOVER_HOOK
            )
        );
        _fillRollover(orderDigest, orderData, intent, cptHolderSig, FILL);
    }

    /// @notice execute intent calls pre attested module used in post slot reverts module type mismatch.
    function test_executeIntentCalls_preAttestedModule_usedInPostSlot_revertsModuleTypeMismatch()
        public
    {
        RolloverTypes.Call[] memory post = new RolloverTypes.Call[](1);
        post[0] = _hook(
            address(sourceSrc),
            abi.encodeWithSignature("execute(address,uint256)", address(srcCpt), uint256(0))
        );

        RolloverTypes.OrderData memory orderData = _restructureOrder(93);
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupRolloverIntent(orderData, _preSource(FILL), _empty(), post, _empty());

        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContract__ModuleTypeMismatch.selector,
                address(sourceSrc),
                Typehashes.MODULE_TYPE_POST_ROLLOVER_HOOK
            )
        );
        _fillRollover(orderDigest, orderData, intent, cptHolderSig, FILL);
    }

    /// @notice A module attested only for POST cannot execute in the PREMIUM bucket.
    function test_executeIntentCalls_postAttestedModule_usedInPremiumSlot_revertsModuleTypeMismatch()
        public
    {
        erc7484.setAttestedType(address(premiumRoute), Typehashes.MODULE_TYPE_POST_ROLLOVER_HOOK);
        RolloverTypes.Call[] memory premium = new RolloverTypes.Call[](1);
        premium[0] = _hook(
            address(premiumRoute),
            abi.encodeWithSignature(
                "execute(address,address,uint256)", address(premiumToken), premiumSink, PREMIUM
            )
        );
        RolloverTypes.OrderData memory orderData = _restructureOrder(94);
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupRolloverIntent(orderData, _preSource(FILL), _empty(), _postConsume(FILL), premium);

        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContract__ModuleTypeMismatch.selector,
                address(premiumRoute),
                Typehashes.MODULE_TYPE_EXECUTOR
            )
        );
        _fillRollover(orderDigest, orderData, intent, cptHolderSig, FILL);
    }

    /// @notice execute intent calls check selector matches standard erc7484.
    function test_executeIntentCalls_checkSelector_matchesAllRolloverBuckets() public {
        RolloverTypes.Call[] memory mid = new RolloverTypes.Call[](1);
        mid[0] = _hook(
            address(donateCa),
            abi.encodeWithSignature("execute(address,uint256)", address(caSrc), uint256(0))
        );
        RolloverTypes.Call[] memory premium = new RolloverTypes.Call[](1);
        premium[0] = _hook(
            address(premiumRoute),
            abi.encodeWithSignature(
                "execute(address,address,uint256)", address(premiumToken), premiumSink, PREMIUM
            )
        );
        RolloverTypes.OrderData memory orderData = _restructureOrder(98);
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupRolloverIntent(orderData, _preSource(FILL), mid, _postConsume(FILL), premium);

        ICorkRolloverContract.RolloverContractTrustSnapshot memory snap =
            ICorkRolloverContract(rolloverContract).rolloverContractSnapshot();
        bytes4 explicitCheckSel = bytes4(keccak256("check(address,uint256,address[],uint256)"));

        vm.expectCall(
            address(erc7484),
            abi.encodeWithSelector(
                explicitCheckSel,
                address(sourceSrc),
                Typehashes.MODULE_TYPE_PRE_ROLLOVER_HOOK,
                snap.liveTrustAttesters,
                snap.liveTrustThreshold
            )
        );
        vm.expectCall(
            address(erc7484),
            abi.encodeWithSelector(
                explicitCheckSel,
                address(donateCa),
                Typehashes.MODULE_TYPE_MID_ROLLOVER_HOOK,
                snap.liveTrustAttesters,
                snap.liveTrustThreshold
            )
        );
        vm.expectCall(
            address(erc7484),
            abi.encodeWithSelector(
                explicitCheckSel,
                address(consumeDst),
                Typehashes.MODULE_TYPE_POST_ROLLOVER_HOOK,
                snap.liveTrustAttesters,
                snap.liveTrustThreshold
            )
        );
        vm.expectCall(
            address(erc7484),
            abi.encodeWithSelector(
                explicitCheckSel,
                address(premiumRoute),
                Typehashes.MODULE_TYPE_EXECUTOR,
                snap.liveTrustAttesters,
                snap.liveTrustThreshold
            )
        );
        _fillRollover(orderDigest, orderData, intent, cptHolderSig, FILL);
    }

    /// @notice deposit leg same ca token both pools mid hook donation does not inflate shares out.
    function test_depositLeg_sameCaTokenBothPools_midHookDonationDoesNotInflateSharesOut() public {
        uint256 donation = 250e18;
        caSrc.mint(rolloverContract, donation);

        RolloverTypes.OrderData memory orderData = _restructureOrder(92);
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupRolloverIntent(
            orderData, _preSource(FILL), _empty(), _postConsume(FILL), _empty()
        );

        uint256 fillerDstBefore = dstCst.balanceOf(filler);
        _fillRollover(orderDigest, orderData, intent, cptHolderSig, FILL);

        assertEq(
            dstCst.balanceOf(filler) - fillerDstBefore,
            FILL,
            "dstCST forwarded == bracket-derived caForDeposit (donation excluded; atomic-fill)"
        );

        assertEq(caSrc.balanceOf(rolloverContract), donation, "donation untouched");
    }

    /// @notice unwind leg phoenix without shares getter reverts hard.
    function test_unwindLeg_phoenixWithoutSharesGetter_revertsHard() public {
        MockPhoenixPoolManagerNoCptGetter brokenPool = new MockPhoenixPoolManagerNoCptGetter();
        brokenPool.bind(srcPoolId, srcCst, srcCpt, caSrc);
        brokenPool.bind(dstPoolId, dstCst, dstCpt, caSrc);
        srcCst.setPoolManager(IPoolManager(address(brokenPool)));
        dstCst.setPoolManager(IPoolManager(address(brokenPool)));

        RolloverTypes.OrderData memory orderData = _restructureOrder(91);
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupRolloverIntent(
            orderData, _preSource(FILL), _empty(), _postConsume(FILL), _empty()
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContract__PoolManagerCallFailed.selector,
                IPoolManager.shares.selector,
                bytes("")
            )
        );
        _fillRollover(orderDigest, orderData, intent, cptHolderSig, FILL);
    }
}
