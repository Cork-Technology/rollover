// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { FillScaffold } from "../../base/FillScaffold.sol";
import { CorkRolloverContract } from "src/CorkRolloverContract.sol";
import { ExactSettler as Settler } from "src/ExactSettler.sol";
import {
    CorkRolloverContract__OrderDataDigestMismatch,
    CorkRolloverContract__RolloverIntentHashCtxMismatch
} from "src/errors/CorkRolloverContractErrors.sol";
import {
    ICorkRolloverContractFactory
} from "src/interfaces/rollover/ICorkRolloverContractFactory.sol";
import { IRolloverHookDispatcher } from "src/interfaces/rollover/IRolloverHookDispatcher.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice RolloverIntent must stay bound to its originating orderDigest across re-dispatch attempts.
contract RolloverIntentBindingTest is FillScaffold {
    /// @notice Fill.
    uint256 internal constant FILL = 1_000e18;

    /// @notice Dst.
    uint256 internal constant DST = 1_000e18;

    /// @notice Premium.
    uint256 internal constant PREMIUM = 10e18;

    /// @notice Attacker.
    address internal attacker;

    /// @notice Order data.
    RolloverTypes.OrderData internal orderData;

    /// @notice Benign hash.
    bytes32 internal benignHash;

    /// @notice Order digest.
    bytes32 internal orderDigest;

    /// @inheritdoc BaseTest
    function setUp() public override {
        super.setUp();

        attacker = address(
            new Settler(
                address(factory),
                address(this),
                address(this),
                address(this),
                address(this),
                address(this)
            )
        );

        orderData = _baseOrder();
        orderData.allowPartialFills = false;
        orderData.orderSize = FILL;

        RolloverTypes.RolloverIntent memory benignIntent = _buildIntent(bytes32(0), FILL, DST);
        benignHash = _zeroDigestHash(benignIntent);
        orderData.rolloverIntentHash = benignHash;

        orderDigest = _openOrder(orderData);
        benignIntent.orderDigest = orderDigest;
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);

        _approveFiller(FILL, PREMIUM);
        _doRolloverAs(orderDigest, orderData, benignIntent, FILL, filler);
    }

    /// @notice alias intent rejected after first fill remains bound to the original order digest.
    function test_aliasIntentRejectedAfterFirstFillByOrderDigestBinding() public {
        RolloverTypes.RolloverIntent memory aliasIntent =
            _emptyIntent(rolloverContract, orderDigest);
        bytes32 aliasHash = _zeroDigestHash(aliasIntent);
        assertTrue(aliasHash != benignHash, "alias must hash differently");

        RolloverTypes.FillContext memory fillContext = _fillContext({
            filler_: attacker,
            fillAmount: 1,
            rolloverIntentHash: aliasHash,
            fillDeadline: orderData.fillDeadline,
            allowPartialFills: false,
            orderSize: FILL,
            originSettler: attacker,
            premiumToken_: address(premiumToken),
            premium: 0
        });

        bytes memory junkSig = new bytes(65);
        for (uint256 i = 0; i < 65; ++i) {
            junkSig[i] = bytes1(uint8(0xAA));
        }

        factory.approveSettler(attacker);

        // The attacker is a separate Settler instance with a distinct EIP-712 domain
        // separator (different `verifyingContract` address). When the rolloverContract re-derives
        // the order digest against the attacker's domain it diverges from `orderDigest`
        // (which was opened under the legitimate settler), so the fillContext ↔ OrderData
        // binding fires `CorkRolloverContract__OrderDataDigestMismatch`.
        vm.prank(attacker);
        vm.expectPartialRevert(CorkRolloverContract__OrderDataDigestMismatch.selector);
        IRolloverHookDispatcher(address(factory))
            .executeIntentHooks(
                rolloverContract,
                orderDigest,
                RolloverTypes.HookPhase.ROLLOVER,
                aliasIntent,
                junkSig,
                fillContext,
                orderData
            );
    }

    /// @notice Alias intent (under the same legitimate Settler) is rejected by the
    ///         fillContext ↔ OrderData `RolloverIntentHashCtxMismatch` guard once the alias hash
    ///         diverges from `orderData.rolloverIntentHash`.
    function test_aliasIntentRejectedByBindingUnderLegitimateSettler() public {
        RolloverTypes.RolloverIntent memory aliasIntent =
            _emptyIntent(rolloverContract, orderDigest);
        bytes32 aliasHash = _zeroDigestHash(aliasIntent);
        assertTrue(aliasHash != benignHash, "alias must hash differently");

        RolloverTypes.FillContext memory fillContext = _fillContext({
            filler_: filler,
            fillAmount: 1,
            rolloverIntentHash: aliasHash,
            fillDeadline: orderData.fillDeadline,
            allowPartialFills: orderData.allowPartialFills,
            orderSize: orderData.orderSize,
            originSettler: address(settler),
            premiumToken_: address(premiumToken),
            premium: 0
        });

        bytes memory junkSig = new bytes(65);
        for (uint256 i = 0; i < 65; ++i) {
            junkSig[i] = bytes1(uint8(0xAA));
        }

        vm.prank(address(settler));
        vm.expectRevert(CorkRolloverContract__RolloverIntentHashCtxMismatch.selector);
        IRolloverHookDispatcher(address(factory))
            .executeIntentHooks(
                rolloverContract,
                orderDigest,
                RolloverTypes.HookPhase.ROLLOVER,
                aliasIntent,
                junkSig,
                fillContext,
                orderData
            );
    }
}
