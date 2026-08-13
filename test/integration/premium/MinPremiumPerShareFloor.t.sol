// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { FillScaffold } from "../../base/FillScaffold.sol";
import { BaseSettler } from "src/BaseSettler.sol";
import { ExactSettler as Settler } from "src/ExactSettler.sol";
import { Settler__PremiumExceedsCap } from "src/errors/SettlerErrors.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice min-premium-per-share floor is enforced at fill time.
contract MinPremiumPerShareFloorTest is FillScaffold {
    /// @notice Fill.
    uint256 internal constant FILL = 1_000e18;

    /// @notice Dst.
    uint256 internal constant DST = 1_000e18;

    /// @notice _bracket open.
    function _bracketOpen(uint256 minPremiumPerShare)
        internal
        returns (
            bytes32 orderDigest,
            RolloverTypes.OrderData memory orderData,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        )
    {
        orderData = _baseOrder();
        orderData.minPremiumPerShare = minPremiumPerShare;
        orderData.allowPartialFills = false;
        orderData.orderSize = FILL;

        orderDigest = _openOrder(orderData);
        intent = _signedIntent(orderDigest, FILL, DST);
        orderData.rolloverIntentHash = _zeroDigestHash(intent);
    }

    /// @notice _bracket open signed.
    function _bracketOpenSigned(uint256 minPremiumPerShare)
        internal
        returns (
            bytes32 orderDigest,
            RolloverTypes.OrderData memory orderData,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        )
    {
        orderData = _baseOrder();
        orderData.minPremiumPerShare = minPremiumPerShare;
        orderData.allowPartialFills = false;
        orderData.orderSize = FILL;

        intent = _buildIntent(bytes32(0), FILL, DST);
        orderData.rolloverIntentHash = _zeroDigestHash(intent);
        orderDigest = _openOrder(orderData);
        intent.orderDigest = orderDigest;
        cptHolderSig = _signOrder(cptHolderPk, orderData);
    }

    /// @notice _run rollover.
    function _runRollover(uint256 minPremiumPerShare)
        internal
        returns (
            bytes32 orderDigest,
            RolloverTypes.OrderData memory orderData,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        )
    {
        (orderDigest, orderData, intent, cptHolderSig) = _bracketOpenSigned(minPremiumPerShare);
        _approveFiller(FILL, 1_000_000e18);
        _doRolloverAs(orderDigest, orderData, intent, FILL, filler);
    }

    /// @notice Under atomic-fill the premium-floor enforcement uses the
    ///         envelope-level `premiumCap`. A cap below `requiredPremium` reverts
    ///         with `Settler__PremiumExceedsCap(cap, required)` before the order
    ///         can settle.
    function testRevert_belowFloor() public {
        uint256 mpps = 1e16;
        (
            bytes32 orderDigest,
            RolloverTypes.OrderData memory orderData,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _bracketOpenSigned(mpps);
        _approveFiller(FILL, 1_000_000e18);
        uint256 required = (DST * mpps) / 1e18;
        vm.expectRevert(
            abi.encodeWithSelector(Settler__PremiumExceedsCap.selector, required - 1, required)
        );
        _doRolloverAsWithCap(orderDigest, orderData, intent, FILL, filler, required - 1);
    }

    /// @notice at floor — premium fires in-frame under atomic-fill.
    function test_atFloor() public {
        uint256 mpps = 1e16;
        (
            bytes32 orderDigest,
            RolloverTypes.OrderData memory orderData,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _runRollover(mpps);
        uint256 required = (DST * mpps) / 1e18;
        assertEq(premiumToken.balanceOf(rolloverContract), required);
        // discard unused vars
        orderDigest;
        orderData;
        intent;
        cptHolderSig;
    }

    /// @notice Ceil-rounding regression: even a sub-1-token leg pulls ≥1 wei premium.
    function testRevert_ceilDivRoundsUp() public {
        uint256 mpps = 1e17;
        uint256 smallFill = 7;
        uint256 smallDst = 7;
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.minPremiumPerShare = mpps;
        orderData.allowPartialFills = false;
        orderData.orderSize = smallFill;
        RolloverTypes.RolloverIntent memory intent = _buildIntent(bytes32(0), smallFill, smallDst);
        orderData.rolloverIntentHash = _zeroDigestHash(intent);
        bytes32 orderDigest = _openOrder(orderData);
        intent.orderDigest = orderDigest;
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);

        _approveFiller(smallFill, 1_000_000e18);
        // Cap = 0 would fail the ceil; cap = 1 passes — verifies that ceilDiv rounds up.
        vm.expectRevert(abi.encodeWithSelector(Settler__PremiumExceedsCap.selector, 0, 1));
        _doRolloverAsWithCap(orderDigest, orderData, intent, smallFill, filler, 0);

        _doRolloverAsWithCap(orderDigest, orderData, intent, smallFill, filler, 1);
    }

    /// @notice premium scales with dst cst produced not source consumed.
    function test_premiumScalesWithDstCstProducedNotSourceConsumed() public {
        uint256 mpps = 1e16;
        uint256 sourceConsumed = FILL;
        uint256 produced = FILL / 2;
        phoenixPool.setPartialDeposit(dstCst.poolId(), 1, 2);

        (
            bytes32 orderDigest,
            RolloverTypes.OrderData memory orderData,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _bracketOpenSigned(mpps);
        _approveFiller(sourceConsumed, 1_000_000e18);
        _doRolloverAs(orderDigest, orderData, intent, sourceConsumed, filler);

        uint256 requiredFromProduced = (produced * mpps + 1e18 - 1) / 1e18;
        uint256 requiredFromSource = (sourceConsumed * mpps + 1e18 - 1) / 1e18;
        assertEq(settler.rolloverAccountingOf(orderDigest).dstCstProduced, produced);
        assertLt(requiredFromProduced, requiredFromSource);

        assertEq(premiumToken.balanceOf(rolloverContract), requiredFromProduced);
    }
}
