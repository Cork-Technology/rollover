// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { FillScaffold } from "../../base/FillScaffold.sol";
import { MockERC20 } from "../../mocks/MockERC20.sol";
import { StdStorage, stdStorage } from "forge-std/StdStorage.sol";
import {
    LibPhoenixShareQuantum__FillAmountNotQuantumAligned,
    LibPhoenixShareQuantum__OrderSizeNotQuantumAligned,
    LibPhoenixShareQuantum__ResidualNotQuantumAligned,
    LibPhoenixShareQuantum__UnsupportedCollateralDecimals
} from "src/errors/LibPhoenixShareQuantumErrors.sol";
import { IPoolManager, MarketId } from "src/interfaces/external/phoenix/IPoolManager.sol";
import { LibPhoenixShareQuantum } from "src/libraries/LibPhoenixShareQuantum.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice External wrapper for testing internal Phoenix share-quantum helper reverts.
contract PhoenixShareQuantumHarness {
    /// @notice Exposes the internal Phoenix source-share quantum helper for test assertions.
    /// @param poolManager Phoenix pool manager.
    /// @param srcPoolId Source Phoenix market id.
    /// @return quantum Minimum source-share quantum for the source market.
    function srcShareQuantum(IPoolManager poolManager, bytes32 srcPoolId)
        external
        view
        returns (uint256 quantum)
    {
        return LibPhoenixShareQuantum.srcShareQuantum(poolManager, srcPoolId);
    }
}

/// @notice F-01 — Phoenix source-share quantum must be enforced at admission/fill.
contract AtomicFillPhoenixQuantizationTest is FillScaffold {
    using stdStorage for StdStorage;

    /// @notice Six-decimal source collateral used to force a non-trivial Phoenix share quantum.
    MockERC20 internal caSrc6;

    /// @notice Phoenix minimumShares for 6-decimal CA: 10 ** 12.
    uint256 internal constant QUANTUM = 1e12;

    /// @notice Aligned base fill (multiple of QUANTUM).
    uint256 internal constant ALIGNED_FILL = 1_000e18;

    /// @notice Configure source and destination pools with six-decimal collateral.
    function setUp() public override {
        super.setUp();
        caSrc6 = new MockERC20("CA6", "CA6", 6);
        phoenixPool.bind(srcCst.poolId(), srcCst, srcCpt, caSrc6);
        phoenixPool.bind(dstCst.poolId(), dstCst, dstCpt, caSrc6);
        vm.prank(filler);
        srcCst.approve(address(settler), type(uint256).max);
        premiumToken.approve(address(settler), type(uint256).max);
        premiumToken.mint(filler, 1e36);
    }

    function _premiumCapForFill(uint256 fillAmount) internal view returns (uint256) {
        uint256 produced = fillAmount * 1e12;
        return (produced * _baseOrder().minPremiumPerShare + 1e18 - 1) / 1e18 + 1;
    }

    function _order6Dec(uint64 salt)
        internal
        view
        returns (RolloverTypes.OrderData memory orderData)
    {
        orderData = _baseOrder();
        orderData.orderSalt = salt;
        orderData.orderSize = ALIGNED_FILL;
    }

    function _intentAligned(bytes32 orderDigest)
        internal
        view
        returns (RolloverTypes.RolloverIntent memory)
    {
        return _buildIntent(orderDigest, ALIGNED_FILL, ALIGNED_FILL);
    }

    function _fillAsFiller(
        bytes32 orderDigest,
        RolloverTypes.OrderData memory orderData,
        RolloverTypes.RolloverIntent memory intent,
        bytes memory cptHolderSig,
        uint256 fillAmount,
        uint256 cap
    ) internal {
        _doAtomicFillAs(
            orderDigest, orderData, intent, fillAmount, filler, filler, _subFillerKey(filler), cap
        );
    }

    function _expectAggregateOverfill(
        bytes32 orderDigest,
        RolloverTypes.OrderData memory orderData,
        RolloverTypes.RolloverIntent memory intent,
        bytes memory cptHolderSig,
        uint256 consumedBefore,
        uint256 overfillAmount
    ) internal {
        bytes memory fillerData = _atomicFillerData(
            overfillAmount,
            _premiumCapForFill(overfillAmount),
            intent,
            filler,
            _subFillerKey(filler),
            _signOrder(cptHolderPk, orderData)
        );
        bytes memory originData = _originData(orderData);
        vm.expectRevert(
            abi.encodeWithSignature(
                "Settler__RolloverAmountOutOfBounds(uint256,uint256)",
                orderData.orderSize,
                consumedBefore + overfillAmount
            )
        );
        vm.prank(filler);
        partialSettler.fill(orderDigest, originData, fillerData);
    }

    /// @notice Non-quantized fill amount reverts at settler preflight before token movement.
    function testRevert_fill_nonQuantizedAmount() public {
        uint256 misaligned = ALIGNED_FILL + 1;
        RolloverTypes.OrderData memory orderData = _usePartialSettler(_order6Dec(801));
        orderData.orderSize = ALIGNED_FILL * 2;
        RolloverTypes.RolloverIntent memory probe = _buildIntent(bytes32(0), misaligned, 0);
        orderData.rolloverIntentHash = _zeroDigestHash(probe);
        bytes32 orderDigest = _openOrder(orderData);

        RolloverTypes.RolloverIntent memory intent = _buildIntent(orderDigest, misaligned, 0);
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);
        uint256 cap = _premiumCapForFill(misaligned);

        _approveFiller(misaligned, cap);
        vm.expectRevert(
            abi.encodeWithSelector(
                LibPhoenixShareQuantum__FillAmountNotQuantumAligned.selector, misaligned, QUANTUM
            )
        );
        _doAtomicFillAs(
            orderDigest, orderData, intent, misaligned, filler, filler, _subFillerKey(filler), cap
        );
    }

    /// @notice Partial fill reverts before token movement when prior fills make it overfill.
    function testRevert_partialFill_aggregateOverfillBeforeTransfer() public {
        uint256 firstFill = ALIGNED_FILL;
        uint256 overfillAmount = ALIGNED_FILL + QUANTUM;
        RolloverTypes.OrderData memory orderData = _usePartialSettler(_order6Dec(802));
        orderData.orderSize = 2 * ALIGNED_FILL;
        RolloverTypes.RolloverIntent memory probe = _buildIntent(bytes32(0), firstFill, firstFill);
        orderData.rolloverIntentHash = _zeroDigestHash(probe);
        bytes32 orderDigest = _openOrder(orderData);

        RolloverTypes.RolloverIntent memory intent = _buildIntent(orderDigest, firstFill, firstFill);
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);
        uint256 cap = _premiumCapForFill(firstFill);

        _approveFiller(firstFill, cap);
        _fillAsFiller(orderDigest, orderData, intent, cptHolderSig, firstFill, cap);

        _approveFiller(overfillAmount, _premiumCapForFill(overfillAmount));
        _expectAggregateOverfill(
            orderDigest, orderData, intent, cptHolderSig, firstFill, overfillAmount
        );
    }

    /// @notice Partial fill reverts before token movement when residual would be non-quantized.
    function testRevert_partialFill_nonQuantizedResidual() public {
        uint256 orderSize = 3 * ALIGNED_FILL;
        uint256 misalignedConsumed = ALIGNED_FILL + QUANTUM / 2;
        uint256 expectedResidual = orderSize - misalignedConsumed - ALIGNED_FILL;

        RolloverTypes.OrderData memory orderData = _usePartialSettler(_order6Dec(805));
        orderData.orderSize = orderSize;
        RolloverTypes.RolloverIntent memory probe =
            _buildIntent(bytes32(0), ALIGNED_FILL, ALIGNED_FILL);
        orderData.rolloverIntentHash = _zeroDigestHash(probe);
        bytes32 orderDigest = _openOrder(orderData);

        RolloverTypes.RolloverIntent memory intent =
            _buildIntent(orderDigest, ALIGNED_FILL, ALIGNED_FILL);
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);
        uint256 cap = _premiumCapForFill(ALIGNED_FILL);

        _approveFiller(ALIGNED_FILL, cap);
        _fillAsFiller(orderDigest, orderData, intent, cptHolderSig, ALIGNED_FILL, cap);

        stdstore.target(address(partialSettler)).sig("rolloverAccountingOf(bytes32)")
            .with_key(orderDigest).depth(2).checked_write(misalignedConsumed);

        _approveFiller(ALIGNED_FILL, cap);
        vm.expectRevert(
            abi.encodeWithSelector(
                LibPhoenixShareQuantum__ResidualNotQuantumAligned.selector,
                expectedResidual,
                QUANTUM
            )
        );
        _doAtomicFillAs(
            orderDigest, orderData, intent, ALIGNED_FILL, filler, filler, _subFillerKey(filler), cap
        );
    }

    /// @notice Quantum-aligned order and fill still succeed.
    function test_alignedExactFill_succeeds() public {
        RolloverTypes.OrderData memory orderData = _order6Dec(803);
        RolloverTypes.RolloverIntent memory probe = _intentAligned(bytes32(0));
        orderData.rolloverIntentHash = _zeroDigestHash(probe);
        bytes32 orderDigest = _openOrder(orderData);

        RolloverTypes.RolloverIntent memory intent = _intentAligned(orderDigest);
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);
        uint256 cap = _premiumCapForFill(ALIGNED_FILL);

        _approveFiller(ALIGNED_FILL, cap);
        _doAtomicFillAs(
            orderDigest, orderData, intent, ALIGNED_FILL, filler, filler, _subFillerKey(filler), cap
        );
    }

    /// @notice Admission rejects non-quantized order size.
    function testRevert_admission_nonQuantizedOrderSize() public {
        RolloverTypes.OrderData memory orderData = _order6Dec(804);
        orderData.orderSize = ALIGNED_FILL + 1;
        RolloverTypes.RolloverIntent memory probe = _intentAligned(bytes32(0));
        orderData.rolloverIntentHash = _zeroDigestHash(probe);
        bytes32 orderDigest = _orderDigest(orderData);
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);
        bytes memory atomicData = _atomicFillerData(
            ALIGNED_FILL,
            _premiumCapForFill(ALIGNED_FILL),
            _intentAligned(orderDigest),
            filler,
            _subFillerKey(filler),
            cptHolderSig
        );
        _approveFiller(ALIGNED_FILL, type(uint256).max);
        vm.prank(filler);
        vm.expectRevert(
            abi.encodeWithSelector(
                LibPhoenixShareQuantum__OrderSizeNotQuantumAligned.selector,
                orderData.orderSize,
                QUANTUM
            )
        );
        settler.fill(orderDigest, _originData(orderData), atomicData);
    }

    /// @notice Quantum helper supports the Phoenix-supported collateral decimals boundary.
    function test_srcShareQuantum_supportedDecimals() public {
        MockERC20 ca0 = new MockERC20("CA0", "CA0", 0);
        phoenixPool.bind(srcCst.poolId(), srcCst, srcCpt, ca0);
        assertEq(
            LibPhoenixShareQuantum.srcShareQuantum(phoenixPool, MarketId.unwrap(srcCst.poolId())),
            1e18,
            "dec 0"
        );

        MockERC20 ca8 = new MockERC20("CA8", "CA8", 8);
        phoenixPool.bind(srcCst.poolId(), srcCst, srcCpt, ca8);
        assertEq(
            LibPhoenixShareQuantum.srcShareQuantum(phoenixPool, MarketId.unwrap(srcCst.poolId())),
            1e10,
            "dec 8"
        );

        MockERC20 ca18 = new MockERC20("CA18", "CA18", 18);
        phoenixPool.bind(srcCst.poolId(), srcCst, srcCpt, ca18);
        assertEq(
            LibPhoenixShareQuantum.srcShareQuantum(phoenixPool, MarketId.unwrap(srcCst.poolId())),
            1,
            "dec 18"
        );
    }

    /// @notice Collateral decimals above 18 revert with an explicit admission error, not a panic.
    function testRevert_srcShareQuantum_unsupportedDecimals() public {
        MockERC20 ca19 = new MockERC20("CA19", "CA19", 19);
        phoenixPool.bind(srcCst.poolId(), srcCst, srcCpt, ca19);
        bytes32 srcPoolId = MarketId.unwrap(srcCst.poolId());
        PhoenixShareQuantumHarness harness = new PhoenixShareQuantumHarness();

        vm.expectRevert(
            abi.encodeWithSelector(
                LibPhoenixShareQuantum__UnsupportedCollateralDecimals.selector, uint8(19)
            )
        );
        harness.srcShareQuantum(phoenixPool, srcPoolId);
    }
}
