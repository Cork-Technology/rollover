// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {
    CorkRolloverContractFactory__SettlerNotOriginSettler,
    CorkRolloverContractFactory__UnknownRolloverContract
} from "src/errors/CorkRolloverContractFactoryErrors.sol";

import { FillScaffold } from "../../base/FillScaffold.sol";
import { CorkRolloverContractFactory } from "src/CorkRolloverContractFactory.sol";
import {
    ICorkRolloverContractFactory
} from "src/interfaces/rollover/ICorkRolloverContractFactory.sol";
import { IRolloverContractLens } from "src/interfaces/rollover/IRolloverContractLens.sol";
import { IRolloverHookDispatcher } from "src/interfaces/rollover/IRolloverHookDispatcher.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice Standalone coverage for CorkRolloverContractFactory branches not hit by shared suites.
contract CorkRolloverContractFactoryStandaloneCoverageTest is FillScaffold {
    function _singleton(address a) internal pure returns (address[] memory out) {
        out = new address[](1);
        out[0] = a;
    }

    function _pair(address a, address b) internal pure returns (address[] memory out) {
        out = new address[](2);
        out[0] = a;
        out[1] = b;
    }

    /// @notice CF-2: apply uses the queued mirror and clears it after timelock execution.
    function test_CF2_applyTrustConfig_usesQueuedMirrorAndClearsPending() public {
        address[] memory queued = _pair(address(0xA1), address(0xA2));
        vm.prank(cptHolder);
        factory.queueTrustConfig(2, queued);

        vm.warp(block.timestamp + 1 hours);
        factory.applyTrustConfig(rolloverContract);

        (uint8 threshold, address[] memory pendingAttesters,) =
            factory.pendingTrustConfig(rolloverContract);
        assertEq(threshold, 0, "apply clears queued threshold");
        assertEq(pendingAttesters.length, 0, "apply clears queued list");
    }

    /// @notice CF-3: dispatch rejects a fill context origin settler that differs from msg.sender.
    function test_CF3_executeIntentHooks_fillContextOriginSettlerMismatch_reverts() public {
        RolloverTypes.FillContext memory fillContext;
        fillContext.originSettler = address(partialSettler);

        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContractFactory__SettlerNotOriginSettler.selector,
                address(partialSettler),
                address(settler)
            )
        );
        vm.prank(address(settler));
        factory.executeIntentHooks(
            address(0xCAFE),
            bytes32(uint256(1)),
            RolloverTypes.HookPhase.ROLLOVER,
            _emptyIntent(address(0xCAFE), bytes32(uint256(1))),
            "",
            fillContext,
            _emptyOrderData()
        );
    }

    /// @notice CF-3: transient originating-settler latch clears between dispatch frames.
    function test_CF3_executeIntentHooks_originLatchClearsBetweenSettlerFrames() public {
        uint256 fillAmount = 100e18;
        RolloverTypes.OrderData memory first = _baseOrder();
        first.orderSize = fillAmount;
        first.orderSalt = 701;
        RolloverTypes.RolloverIntent memory firstIntent =
            _buildIntent(bytes32(0), fillAmount, fillAmount);
        first.rolloverIntentHash = _zeroDigestHash(firstIntent);
        bytes32 firstDigest = _openOrder(first);
        firstIntent.orderDigest = firstDigest;

        vm.prank(filler);
        srcCst.approve(address(settler), fillAmount);
        _doRolloverAs(firstDigest, first, firstIntent, fillAmount, filler);
        assertEq(factory.originatingSettler(), address(0), "exact frame clears origin latch");

        RolloverTypes.OrderData memory second = _usePartialSettler(_baseOrder());
        second.orderSize = fillAmount;
        second.orderSalt = 702;
        second.allowUnderfill = true;
        RolloverTypes.RolloverIntent memory secondIntent =
            _buildIntent(bytes32(0), fillAmount, fillAmount);
        second.rolloverIntentHash = _zeroDigestHash(secondIntent);
        bytes32 secondDigest = _openOrder(second);
        secondIntent.orderDigest = secondDigest;

        vm.prank(filler);
        srcCst.approve(address(partialSettler), fillAmount);

        _doRolloverAs(secondDigest, second, secondIntent, fillAmount, filler);
        assertEq(factory.originatingSettler(), address(0), "partial frame clears origin latch");
    }

    /// @notice Lens read-through views reject addresses outside this factory's rolloverContract lineage.
    function test_lensViews_unknownRolloverContract_revertUnknownRolloverContract() public {
        address unknownRolloverContract = makeAddr("unknown-rolloverContract-lens");
        IRolloverContractLens lens = IRolloverContractLens(address(factory));

        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContractFactory__UnknownRolloverContract.selector,
                unknownRolloverContract
            )
        );
        lens.orderState(unknownRolloverContract, bytes32(uint256(1)));

        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContractFactory__UnknownRolloverContract.selector,
                unknownRolloverContract
            )
        );
        lens.premiumFiredFor(
            unknownRolloverContract, bytes32(uint256(1)), filler, bytes32(uint256(2))
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContractFactory__UnknownRolloverContract.selector,
                unknownRolloverContract
            )
        );
        lens.rolloverContractConfig(unknownRolloverContract);
    }
}
