// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "./BaseTest.sol";
import { ISettler } from "src/interfaces/settlers/ISettler.sol";
import { LibFillerPayload } from "src/libraries/LibFillerPayload.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice Extends BaseTest with atomic-fill helpers for unit tests that drive
///         Settler.fill end-to-end. Under the atomic-fill dispatch (INV-ATOMIC-FILL-CANONICAL)
///         these helper-driven `fill()` calls carry an ATOMIC_TAG (255) envelope
///         wrapping rollover + premium + an explicit premiumCap + cPT-holder signature.
abstract contract FillScaffold is BaseTest {
    /// @notice Dispatch tag for atomic-fill `fillerData` envelopes (INV-ATOMIC-FILL-CANONICAL).
    uint8 internal constant ATOMIC_TAG = 255;

    /// @notice Default premium cap used by helpers — large enough that the
    ///         ceil-rounded `requiredPremium = ceil(produced * minPremiumPerShare / 1e18)`
    ///         comfortably fits under the cap for every test fixture in the suite.
    uint256 internal constant DEFAULT_PREMIUM_CAP = 1_000_000e18;

    function _buildIntent(bytes32 orderDigest, uint256 srcAmount, uint256)
        internal
        view
        returns (RolloverTypes.RolloverIntent memory)
    {
        RolloverTypes.Call[] memory preHooks = new RolloverTypes.Call[](1);
        preHooks[0] = _hook(
            address(sourceSrcCptModule),
            abi.encodeWithSignature("execute(address,uint256)", address(srcCpt), srcAmount)
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

    function _signedIntent(bytes32 orderDigest, uint256 srcAmount, uint256 dstAmount)
        internal
        view
        returns (RolloverTypes.RolloverIntent memory intent)
    {
        intent = _buildIntent(orderDigest, srcAmount, dstAmount);
    }

    /// @dev Under atomic-fill, EVERY fill pulls premium in-frame. Legacy callers passing
    ///      `premium=0` (carryover from when premium was a separate phase) would now revert
    ///      with `transferFrom` arithmetic underflow. We approve `max(premium, srcAmount)` on
    ///      the premium token so legacy zero-premium callsites continue to work, while tests
    ///      that want a tight premium cap can still set it via the atomic envelope.
    function _approveFiller(uint256 srcAmount, uint256 premium) internal {
        uint256 premiumApprove = premium == 0 ? srcAmount : premium;
        vm.startPrank(filler);
        srcCst.approve(address(settler), srcAmount);
        srcCst.approve(address(partialSettler), srcAmount);
        premiumToken.approve(address(settler), premiumApprove);
        premiumToken.approve(address(partialSettler), premiumApprove);
        vm.stopPrank();
    }

    function _atomicFillerData(
        uint256 fillAmount,
        uint256 premiumCap,
        RolloverTypes.RolloverIntent memory intent,
        address destination,
        bytes32 subFiller,
        bytes memory cptHolderSig
    ) internal pure returns (bytes memory) {
        bytes memory rolloverData = LibFillerPayload.encodeRolloverLeg(
            fillAmount, destination, intent, 0, bytes(""), subFiller, bytes("")
        );
        return LibFillerPayload.encodeAtomicEnvelope(rolloverData, premiumCap, cptHolderSig);
    }

    /// @dev Atomic-fill helper: filler == destination, self-keyed subFiller.
    function _doRolloverAs(
        bytes32 orderDigest,
        RolloverTypes.OrderData memory orderData,
        RolloverTypes.RolloverIntent memory intent,
        uint256 fillAmount,
        address fillerAddr
    ) internal {
        _doAtomicFillAs(
            orderDigest,
            orderData,
            intent,
            fillAmount,
            fillerAddr,
            fillerAddr,
            _subFillerKey(fillerAddr),
            DEFAULT_PREMIUM_CAP
        );
    }

    /// @dev Variant with an explicit `premiumCap`.
    function _doRolloverAsWithCap(
        bytes32 orderDigest,
        RolloverTypes.OrderData memory orderData,
        RolloverTypes.RolloverIntent memory intent,
        uint256 fillAmount,
        address fillerAddr,
        uint256 premiumCap
    ) internal {
        _doAtomicFillAs(
            orderDigest,
            orderData,
            intent,
            fillAmount,
            fillerAddr,
            fillerAddr,
            _subFillerKey(fillerAddr),
            premiumCap
        );
    }

    /// @dev Full atomic-fill driver. The helper signs `OrderData` internally and threads that
    ///      cPT-holder signature through the atomic envelope.
    function _doAtomicFillAs(
        bytes32 orderDigest,
        RolloverTypes.OrderData memory orderData,
        RolloverTypes.RolloverIntent memory intent,
        uint256 fillAmount,
        address fillerAddr,
        address destination,
        bytes32 subFiller,
        uint256 premiumCap
    ) internal {
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);
        bytes memory fillerData =
            _atomicFillerData(fillAmount, premiumCap, intent, destination, subFiller, cptHolderSig);
        vm.prank(fillerAddr);
        ISettler(orderData.settler).fill(orderDigest, _originData(orderData), fillerData);
    }
}
