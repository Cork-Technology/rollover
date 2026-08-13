// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { FillScaffold } from "../../base/FillScaffold.sol";
import { UnderfillingRolloverModule } from "../../mocks/modules/UnderfillingRolloverModule.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { BaseFiller } from "src/BaseFiller.sol";
import { CorkRolloverContract } from "src/CorkRolloverContract.sol";
import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import { IRolloverContractLens } from "src/interfaces/rollover/IRolloverContractLens.sol";
import { ISettler } from "src/interfaces/settlers/ISettler.sol";
import { Typehashes } from "src/libraries/Typehashes.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice filler-supplied minDstPerSrc floor blocks hostile cPT holder with zero minSharesOut.
contract FillerMintFloorTest is FillScaffold {
    /// @notice Underfill module.
    UnderfillingRolloverModule internal underfillModule;

    /// @notice Filler2.
    address internal filler2 = address(0xF2);

    /// @notice Eoa pk.
    uint256 internal eoaPk;

    /// @notice Eoa.
    address internal eoa;

    /// @notice Order_size.
    uint256 internal constant ORDER_SIZE = 1_000e18;

    /// @notice Wad.
    uint256 internal constant WAD = 1e18;

    /// @inheritdoc BaseTest
    function setUp() public override {
        super.setUp();
        underfillModule = new UnderfillingRolloverModule();
        erc7484.setAttestedType(address(underfillModule), Typehashes.MODULE_TYPE_PRE_ROLLOVER_HOOK);
        srcCst.mint(filler2, 1_000_000e18);
        dstCst.mint(filler2, 1_000_000e18);
        premiumToken.mint(filler2, 1_000_000e18);
        vm.label(filler2, "filler2");
        vm.label(address(underfillModule), "underfillModule");

        vm.startPrank(filler);
        srcCst.approve(address(settler), type(uint256).max);
        srcCst.approve(address(partialSettler), type(uint256).max);
        premiumToken.approve(address(settler), type(uint256).max);
        premiumToken.approve(address(partialSettler), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(filler2);
        srcCst.approve(address(settler), type(uint256).max);
        srcCst.approve(address(partialSettler), type(uint256).max);
        premiumToken.approve(address(settler), type(uint256).max);
        premiumToken.approve(address(partialSettler), type(uint256).max);
        vm.stopPrank();

        (eoa, eoaPk) = makeAddrAndKey("fillerMintFloorEoa");
        srcCst.mint(eoa, 1_000_000e18);
        premiumToken.mint(eoa, 1_000_000e18);
        vm.startPrank(eoa);
        srcCst.approve(address(baseFiller), type(uint256).max);
        premiumToken.approve(address(baseFiller), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice _rollover filler data7 — under atomic-fill (INV-ATOMIC-FILL-CANONICAL)
    ///         this helper's `fill()` call carries an ATOMIC_TAG envelope. Wraps the
    ///         minDstPerSrc-carrying rollover leg + self-keyed no-op premium leg.
    function _rolloverFillerData7(
        uint256 fillAmount,
        RolloverTypes.RolloverIntent memory intent,
        bytes memory cptHolderSig,
        uint256 minDstPerSrc,
        address fillerAddr
    ) internal pure returns (bytes memory) {
        bytes memory rolloverLeg = abi.encode(
            uint8(RolloverTypes.HookPhase.ROLLOVER),
            fillAmount,
            uint256(0),
            fillerAddr,
            address(0),
            intent,
            minDstPerSrc,
            "",
            bytes32(0),
            ""
        );
        // Unbounded cap so tests that exercise large-operand math don't trip the
        // envelope-level `Settler__PremiumExceedsCap` guard; cap semantics are
        // covered by dedicated cap tests.
        return abi.encode(uint8(255), rolloverLeg, type(uint256).max, cptHolderSig);
    }

    /// @notice _order with.
    function _orderWith(bool allowPartialFills, bool allowUnderfill, uint256 orderSize)
        internal
        view
        returns (RolloverTypes.OrderData memory orderData)
    {
        orderData = _baseOrder();
        if (allowPartialFills) {
            orderData = _usePartialSettler(orderData);
        } else {
            orderData.allowPartialFills = false;
        }
        orderData.allowUnderfill = allowUnderfill;
        orderData.orderSize = orderSize;
    }

    /// @notice _intent for.
    function _intentFor(bytes32 orderDigest, uint256, uint256 dstMint)
        internal
        view
        returns (RolloverTypes.RolloverIntent memory)
    {
        RolloverTypes.Call[] memory preHooks = new RolloverTypes.Call[](1);
        preHooks[0] = _hook(
            address(sourceSrcCptModule),
            abi.encodeWithSignature("execute(address,uint256)", address(srcCpt), dstMint)
        );
        RolloverTypes.Call[] memory postHooks = new RolloverTypes.Call[](1);
        postHooks[0] = _hook(
            address(consumeDstCptModule),
            abi.encodeWithSignature("execute(address)", address(dstCpt))
        );
        return _intentWithHooks(
            rolloverContract, orderDigest, preHooks, new RolloverTypes.Call[](0), postHooks
        );
    }

    /// @notice _open with hash.
    function _openWithHash(
        RolloverTypes.OrderData memory orderData,
        uint256 srcRefund,
        uint256 dstMint
    )
        internal
        returns (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        )
    {
        bytes32 dummyDigest = bytes32(0);
        RolloverTypes.RolloverIntent memory probe = _intentFor(dummyDigest, srcRefund, dstMint);
        orderData.rolloverIntentHash = _zeroDigestHash(probe);
        orderDigest = _openOrder(orderData);
        intent = _intentFor(orderDigest, srcRefund, dstMint);
        cptHolderSig = _signOrder(cptHolderPk, orderData);
    }

    /// @notice _fill.
    function _fill(
        bytes32 orderDigest,
        RolloverTypes.OrderData memory orderData,
        RolloverTypes.RolloverIntent memory intent,
        bytes memory cptHolderSig,
        uint256 fillAmount,
        uint256 minDstPerSrc,
        address fillerAddr
    ) internal {
        bytes memory originData = _originData(orderData);
        bytes memory fillerData =
            _rolloverFillerData7(fillAmount, intent, cptHolderSig, minDstPerSrc, fillerAddr);
        vm.prank(fillerAddr);
        if (orderData.allowPartialFills) {
            partialSettler.fill(orderDigest, originData, fillerData);
        } else {
            settler.fill(orderDigest, originData, fillerData);
        }
    }

    /// @notice happy path above floor fill succeeds.
    function test_happyPath_aboveFloor_fillSucceeds() public {
        RolloverTypes.OrderData memory orderData = _orderWith(false, false, ORDER_SIZE);
        uint256 srcRefund = 0;
        uint256 dstMint = ORDER_SIZE;
        uint256 minDstPerSrc = WAD;

        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _openWithHash(orderData, srcRefund, dstMint);

        // INV-ATOMIC-FILL-CANONICAL: dstCST forwarded to filler in same frame.
        uint256 fillerDstBefore = dstCst.balanceOf(filler);
        _fill(orderDigest, orderData, intent, cptHolderSig, ORDER_SIZE, minDstPerSrc, filler);

        assertEq(
            dstCst.balanceOf(filler) - fillerDstBefore,
            dstMint,
            "dstDelta == dstMint (forwarded to filler)"
        );
        assertEq(
            IRolloverContractLens(address(factory))
            .orderState(rolloverContract, orderDigest)
            .rolled,
            ORDER_SIZE,
            "actualRolled == orderSize"
        );
    }

    /// @notice reverts when floor breach hostile cptHolder reverts insufficient mint rate.
    function testRevert_floorBreach_hostileCptHolder_revertsInsufficientMintRate() public {
        phoenixPool.setPartialDeposit(dstCst.poolId(), 1, ORDER_SIZE);
        RolloverTypes.OrderData memory orderData = _orderWith(false, false, ORDER_SIZE);
        uint256 minDstPerSrc = WAD;

        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _openWithHash(orderData, 0, ORDER_SIZE);

        uint256 required = (ORDER_SIZE * minDstPerSrc) / WAD;
        vm.expectRevert(
            abi.encodeWithSignature("Settler__InsufficientMintRate(uint256,uint256)", required, 1)
        );
        _fill(orderDigest, orderData, intent, cptHolderSig, ORDER_SIZE, minDstPerSrc, filler);
    }

    /// @notice floor breach baseline without floor silently passes.
    function test_floorBreach_baselineWithoutFloor_silentlyPasses() public {
        phoenixPool.setPartialDeposit(dstCst.poolId(), 1, ORDER_SIZE);
        RolloverTypes.OrderData memory orderData = _orderWith(false, false, ORDER_SIZE);

        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _openWithHash(orderData, 0, ORDER_SIZE);

        uint256 fillerSrcBefore = srcCst.balanceOf(filler);
        _fill(orderDigest, orderData, intent, cptHolderSig, ORDER_SIZE, 0, filler);

        assertEq(fillerSrcBefore - srcCst.balanceOf(filler), ORDER_SIZE, "baseline: filler drained");
        assertEq(
            IRolloverContractLens(address(factory))
            .orderState(rolloverContract, orderDigest)
            .rolled,
            ORDER_SIZE,
            "baseline: rolled == fill"
        );
    }

    /// @notice floor opt out zero rate any mint passes.
    function test_floorOptOut_zeroRate_anyMintPasses() public {
        phoenixPool.setPartialDeposit(dstCst.poolId(), 1, ORDER_SIZE);
        RolloverTypes.OrderData memory orderData = _orderWith(false, false, ORDER_SIZE);

        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _openWithHash(orderData, 0, ORDER_SIZE);

        _fill(orderDigest, orderData, intent, cptHolderSig, ORDER_SIZE, 0, filler);

        assertEq(
            IRolloverContractLens(address(factory))
            .orderState(rolloverContract, orderDigest)
            .rolled,
            ORDER_SIZE,
            "opt-out: rolled == fill"
        );
    }

    /// @notice allow underfill floor computed on actual rolled.
    function test_allowUnderfill_floorComputedOnActualRolled() public {
        RolloverTypes.OrderData memory orderData = _orderWith(false, true, ORDER_SIZE);
        uint256 srcRefund = 250e18;
        uint256 actualRolled = ORDER_SIZE - srcRefund;
        uint256 dstMint = actualRolled;
        uint256 minDstPerSrc = WAD;

        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _openWithHash(orderData, srcRefund, dstMint);

        _fill(orderDigest, orderData, intent, cptHolderSig, ORDER_SIZE, minDstPerSrc, filler);

        assertEq(
            IRolloverContractLens(address(factory))
            .orderState(rolloverContract, orderDigest)
            .rolled,
            actualRolled,
            "rolled == actualRolled"
        );
    }

    /// @notice reverts when allow underfill floor on actual rolled breach reverts.
    function testRevert_allowUnderfill_floorOnActualRolled_breachReverts() public {
        uint256 actualRolled = 750e18;
        phoenixPool.setPartialDeposit(dstCst.poolId(), actualRolled - 1, actualRolled);
        RolloverTypes.OrderData memory orderData = _orderWith(false, true, ORDER_SIZE);
        uint256 minDstPerSrc = WAD;

        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _openWithHash(orderData, 0, actualRolled);

        uint256 required = (actualRolled * minDstPerSrc) / WAD;
        vm.expectRevert(
            abi.encodeWithSignature(
                "Settler__InsufficientMintRate(uint256,uint256)", required, actualRolled - 1
            )
        );
        _fill(orderDigest, orderData, intent, cptHolderSig, ORDER_SIZE, minDstPerSrc, filler);
    }

    /// @notice full underfill floor trivially passes.
    function test_fullUnderfill_floorTriviallyPasses() public {
        RolloverTypes.OrderData memory orderData = _orderWith(false, true, ORDER_SIZE);
        uint256 minDstPerSrc = WAD;

        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _openWithHash(orderData, 0, 1);

        uint256 fillerSrcBefore = srcCst.balanceOf(filler);
        _fill(orderDigest, orderData, intent, cptHolderSig, ORDER_SIZE, minDstPerSrc, filler);

        assertEq(
            IRolloverContractLens(address(factory))
            .orderState(rolloverContract, orderDigest)
            .rolled,
            1,
            "actualRolled == 1"
        );
        assertEq(srcCst.balanceOf(filler), fillerSrcBefore - 1, "near-full refund");
    }

    // NOTE: `test_overflowGuard_mulDivHandlesLargeOperands` was removed under
    // INV-DST-CST-MINT-RATIO-BOUNDED. The previous scaffolding forced a 2^72×
    // over-mint via `setPartialDeposit(dstCst.poolId(), 1 << 72, 1)` to exercise
    // the wide-arithmetic path of the M-08 / INV-DSTCST-FLOOR `mulDiv` check.
    // The new deposit-leg cap (`CorkRolloverContract._depositLeg` quotes the canonical
    // mint via `IPoolManager.previewDeposit` and reverts on over-mint) makes
    // that scaffolding unreachable: the gate fires before the floor check is
    // ever evaluated against the wide operands. The underlying mulDiv-overflow
    // defence remains real and is exercised by the surrounding INV-DSTCST-FLOOR
    // tests at realistic operand widths; only its trigger surface has narrowed.

    /// @notice Premium refunded.
    /// @param amount amount.
    /// @param filler filler.
    /// @param orderDigest orderDigest.
    /// @param premiumToken premium token.
    event PremiumRefunded(
        bytes32 indexed orderDigest,
        address indexed filler,
        address indexed premiumToken,
        uint256 amount
    );

    /// @notice base filler premium leg still emits refund with floor.
    function test_baseFiller_atomicPremiumStillEmitsRefund_withFloor() public {
        uint256 fill = 1_000e18;
        uint256 dst = 1_000e18;
        uint256 mpps = 1e16;
        uint256 required = 10e18;
        uint256 cap = required * 2;

        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.minPremiumPerShare = mpps;
        orderData.allowPartialFills = false;
        orderData.orderSize = fill;
        orderData.orderSalt = 100;
        RolloverTypes.RolloverIntent memory intent = _buildIntent(bytes32(0), fill, dst);
        orderData.rolloverIntentHash = _zeroDigestHash(intent);
        bytes32 orderDigest = _orderDigest(orderData);
        intent.orderDigest = orderDigest;

        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory userSig = _signOrder(cptHolderPk, orderData);

        vm.expectEmit(true, true, true, true, address(baseFiller));
        emit PremiumRefunded(orderDigest, eoa, address(premiumToken), cap - required);

        vm.prank(eoa);
        baseFiller.execute(
            BaseFiller.FillerJob({
                settler: ISettler(address(settler)),
                order: g,
                userSig: userSig,
                srcCst: IERC20(address(srcCst)),
                premiumToken: IERC20(address(premiumToken)),
                fillerSrcCst: fill,
                intent: intent,
                premiumCap: cap,
                minDstPerSrc: WAD,
                fillerAuthSig: ""
            })
        );
    }

    /// @notice partial mode per fill floor enforced independently.
    function test_partialMode_perFillFloor_enforcedIndependently() public {
        RolloverTypes.OrderData memory orderData = _orderWith(true, false, ORDER_SIZE);
        uint256 chunk = ORDER_SIZE / 2;

        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _openWithHash(orderData, 0, chunk);

        _fill(orderDigest, orderData, intent, cptHolderSig, chunk, WAD, filler);
        assertEq(
            IRolloverContractLens(address(factory))
            .orderState(rolloverContract, orderDigest)
            .rolled,
            chunk,
            "fill #1 landed"
        );

        _fill(orderDigest, orderData, intent, cptHolderSig, chunk, WAD, filler2);

        assertEq(
            IRolloverContractLens(address(factory))
            .orderState(rolloverContract, orderDigest)
            .rolled,
            2 * chunk,
            "fill #2 lands independently while order stays Opened until aggregate completes"
        );
        assertEq(
            uint8(partialSettler.orderStatus(orderDigest)), uint8(RolloverTypes.OrderStatus.Settled)
        );
    }
}
