// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {
    CorkRolloverContractFactory__InvalidOrderBinding,
    CorkRolloverContractFactory__UnknownRolloverContract
} from "src/errors/CorkRolloverContractFactoryErrors.sol";

import { FillScaffold } from "../../base/FillScaffold.sol";
import {
    CorkRolloverContract__RolloverContractMismatch
} from "src/errors/CorkRolloverContractErrors.sol";
import { MarketId } from "src/interfaces/external/phoenix/IPoolManager.sol";
import {
    ICorkRolloverContractFactory
} from "src/interfaces/rollover/ICorkRolloverContractFactory.sol";
import { IRolloverHookDispatcher } from "src/interfaces/rollover/IRolloverHookDispatcher.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice CorkRolloverContractFactoryInFlightTest — pins factory dispatch policy branches.
contract CorkRolloverContractFactoryInFlightTest is FillScaffold {
    /// @notice Pins behaviour: reverts when unknown RolloverContract.
    function testRevert_unknownRolloverContract() public {
        address fakeRolloverContract = makeAddr("notARolloverContract");
        RolloverTypes.RolloverIntent memory intent =
            _emptyIntent(fakeRolloverContract, bytes32(uint256(1)));
        RolloverTypes.FillContext memory fillContext = _fillContext(
            filler,
            0,
            bytes32(0),
            uint64(block.timestamp + 1 days),
            false,
            0,
            address(settler),
            address(0),
            0
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContractFactory__UnknownRolloverContract.selector, fakeRolloverContract
            )
        );
        vm.prank(address(settler));
        factory.executeIntentHooks(
            fakeRolloverContract,
            bytes32(uint256(1)),
            RolloverTypes.HookPhase.ROLLOVER,
            intent,
            bytes(""),
            fillContext,
            _emptyOrderData()
        );
    }

    /// @notice Pins behaviour: reverts when invalid Order Binding Zero Digest.
    function testRevert_invalidOrderBindingZeroDigest() public {
        RolloverTypes.RolloverIntent memory intent = _emptyIntent(rolloverContract, bytes32(0));
        RolloverTypes.FillContext memory fillContext = _fillContext(
            filler,
            0,
            bytes32(0),
            uint64(block.timestamp + 1 days),
            false,
            0,
            address(settler),
            address(0),
            0
        );
        vm.expectRevert(CorkRolloverContractFactory__InvalidOrderBinding.selector);
        vm.prank(address(settler));
        factory.executeIntentHooks(
            rolloverContract,
            bytes32(0),
            RolloverTypes.HookPhase.ROLLOVER,
            intent,
            bytes(""),
            fillContext,
            _emptyOrderData()
        );
    }

    /// @notice RolloverContract-side reverts after the factory latch write roll the transient latch back.
    function testRevert_rolloverContractRevertAfterLatchWrite_clearsOriginLatch() public {
        bytes32 digest = bytes32(uint256(1));
        address wrongRolloverContract = makeAddr("wrong-rolloverContract-in-intent");
        RolloverTypes.RolloverIntent memory intent = _emptyIntent(wrongRolloverContract, digest);
        RolloverTypes.FillContext memory fillContext = _fillContext(
            filler,
            0,
            bytes32(0),
            uint64(block.timestamp + 1 days),
            false,
            0,
            address(settler),
            address(0),
            0
        );

        vm.expectRevert(CorkRolloverContract__RolloverContractMismatch.selector);
        vm.prank(address(settler));
        factory.executeIntentHooks(
            rolloverContract,
            digest,
            RolloverTypes.HookPhase.ROLLOVER,
            intent,
            bytes(""),
            fillContext,
            _emptyOrderData()
        );

        assertEq(factory.originatingSettler(), address(0), "origin latch must roll back on revert");
    }
}
