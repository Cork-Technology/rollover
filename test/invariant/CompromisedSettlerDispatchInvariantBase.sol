// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { FillScaffold } from "../base/FillScaffold.sol";
import {
    CompromisedSettlerDispatchHandler,
    ICompromisedSettlerDispatchDriver
} from "./handlers/CompromisedSettlerDispatchHandler.sol";
import { BaseSettler } from "src/BaseSettler.sol";
import { CorkRolloverContract } from "src/CorkRolloverContract.sol";
import {
    CorkRolloverContract__AllowPartialFillsMismatch,
    CorkRolloverContract__AllowUnderfillMismatch,
    CorkRolloverContract__FillDeadlineMismatch,
    CorkRolloverContract__OrderDataDigestMismatch,
    CorkRolloverContract__OrderSizeMismatch,
    CorkRolloverContract__PremiumTokenMismatch,
    CorkRolloverContract__RolloverIntentHashCtxMismatch
} from "src/errors/CorkRolloverContractErrors.sol";
import {
    Settler__ExactFillRequiresFullOrderSize,
    Settler__RolloverAmountOutOfBounds
} from "src/errors/SettlerErrors.sol";
import {
    ICorkRolloverContractFactory
} from "src/interfaces/rollover/ICorkRolloverContractFactory.sol";
import { IRolloverHookDispatcher } from "src/interfaces/rollover/IRolloverHookDispatcher.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice Shared active driver for compromised-settler dispatch invariant suites.
abstract contract CompromisedSettlerDispatchInvariantBase is
    FillScaffold,
    ICompromisedSettlerDispatchDriver
{
    /// @notice Fill amount used by handler-authored orders.
    uint256 internal constant COMPROMISED_FILL = 700e18;
    /// @notice Premium amount used by premium-phase dispatch probes.
    uint256 internal constant COMPROMISED_PREMIUM = 10e18;
    /// @notice Salt base reserved for handler-authored orders.
    uint64 internal constant COMPROMISED_SALT_BASE = 70_000;

    /// @notice Active handler.
    CompromisedSettlerDispatchHandler internal compromisedHandler;
    /// @notice Monotonic salt offset for handler-authored orders.
    uint64 internal nextCompromisedSalt;

    /// @notice Opened order bundle used by compromised-dispatch probes.
    struct CompromisedRecord {
        bytes32 orderDigest;
        RolloverTypes.OrderData orderData;
        RolloverTypes.RolloverIntent intent;
        bytes cptHolderSig;
    }

    /// @notice Fill-size scenarios sampled by exact/partial settler binding probes.
    enum FillSizeScenario {
        ExactStrictFullValid,
        ExactStrictUnderfillInvalid,
        ExactStrictOverfillInvalid,
        ExactAllowUnderfillValid,
        ExactAllowUnderfillOverfillInvalid,
        PartialUnderfillValid,
        PartialOverfillInvalid
    }

    /// @notice Sets up the active compromised-settler handler and targets its fillContext actions.
    function _setUpCompromisedSettlerDispatchInvariant() internal {
        nextCompromisedSalt = COMPROMISED_SALT_BASE;
        _approveFiller(type(uint256).max, type(uint256).max);

        compromisedHandler =
            new CompromisedSettlerDispatchHandler(ICompromisedSettlerDispatchDriver(address(this)));
        targetContract(address(compromisedHandler));
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = compromisedHandler.probeExactFillContextTamper.selector;
        selectors[1] = compromisedHandler.probePartialFillContextTamper.selector;
        targetSelector(FuzzSelector({ addr: address(compromisedHandler), selectors: selectors }));
    }

    /// @notice Sets up the active compromised-settler handler and targets digest actions.
    function _setUpCompromisedSettlerDigestInvariant() internal {
        nextCompromisedSalt = COMPROMISED_SALT_BASE + 10_000;
        _approveFiller(type(uint256).max, type(uint256).max);

        compromisedHandler =
            new CompromisedSettlerDispatchHandler(ICompromisedSettlerDispatchDriver(address(this)));
        targetContract(address(compromisedHandler));
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = compromisedHandler.probeExactDigestTamper.selector;
        selectors[1] = compromisedHandler.probePartialDigestTamper.selector;
        targetSelector(FuzzSelector({ addr: address(compromisedHandler), selectors: selectors }));
    }

    /// @notice Sets up the active compromised-settler handler and targets params actions.
    function _setUpCompromisedSettlerParamsInvariant() internal {
        nextCompromisedSalt = COMPROMISED_SALT_BASE + 20_000;
        _approveFiller(type(uint256).max, type(uint256).max);

        compromisedHandler =
            new CompromisedSettlerDispatchHandler(ICompromisedSettlerDispatchDriver(address(this)));
        targetContract(address(compromisedHandler));
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = compromisedHandler.probeExactParamsTamper.selector;
        selectors[1] = compromisedHandler.probePartialParamsTamper.selector;
        targetSelector(FuzzSelector({ addr: address(compromisedHandler), selectors: selectors }));
    }

    /// @notice Sets up the active compromised-settler handler and targets real fill-size actions.
    function _setUpExactFillSizeBindingInvariant() internal {
        nextCompromisedSalt = COMPROMISED_SALT_BASE + 30_000;
        _approveFiller(type(uint256).max, type(uint256).max);

        compromisedHandler =
            new CompromisedSettlerDispatchHandler(ICompromisedSettlerDispatchDriver(address(this)));
        targetContract(address(compromisedHandler));
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = compromisedHandler.probeExactFillSizeBinding.selector;
        targetSelector(FuzzSelector({ addr: address(compromisedHandler), selectors: selectors }));
    }

    /// @inheritdoc ICompromisedSettlerDispatchDriver
    function driveFillContextMatchesOrderTamper(uint8 fieldSeed, bool isPartial)
        external
        returns (bool accepted, bool wrongSelector, uint8 field)
    {
        require(msg.sender == address(compromisedHandler), "CompromisedDispatch: only handler");
        SettlerMode mode = isPartial ? SettlerMode.Partial : SettlerMode.Exact;
        field = fieldSeed % 6;
        CompromisedRecord memory rec = _compromisedRecord(mode);

        RolloverTypes.FillContext memory fillContext = _fillContextMatching(rec.orderData);
        bytes4 expectedSelector;
        RolloverTypes.HookPhase phase = RolloverTypes.HookPhase.ROLLOVER;

        if (field == 0) {
            fillContext.orderSize = rec.orderData.orderSize + 1;
            expectedSelector = CorkRolloverContract__OrderSizeMismatch.selector;
            _predepositRolloverAssets();
        } else if (field == 1) {
            fillContext.fillDeadline = rec.orderData.fillDeadline + 1;
            expectedSelector = CorkRolloverContract__FillDeadlineMismatch.selector;
            _predepositRolloverAssets();
        } else if (field == 2) {
            fillContext.allowPartialFills = !rec.orderData.allowPartialFills;
            expectedSelector = CorkRolloverContract__AllowPartialFillsMismatch.selector;
            _predepositRolloverAssets();
        } else if (field == 3) {
            fillContext.allowUnderfill = !rec.orderData.allowUnderfill;
            expectedSelector = CorkRolloverContract__AllowUnderfillMismatch.selector;
            _predepositRolloverAssets();
        } else if (field == 4) {
            fillContext.rolloverIntentHash =
                bytes32(uint256(rec.orderData.rolloverIntentHash) ^ uint256(1));
            expectedSelector = CorkRolloverContract__RolloverIntentHashCtxMismatch.selector;
            _predepositRolloverAssets();
        } else {
            _doRolloverAs(rec.orderDigest, rec.orderData, rec.intent, COMPROMISED_FILL, filler);
            fillContext.fillAmount = 0;
            fillContext.premiumToken = address(srcCst);
            fillContext.premium = COMPROMISED_PREMIUM;
            srcCst.mint(rolloverContract, COMPROMISED_PREMIUM);
            phase = RolloverTypes.HookPhase.PREMIUM;
            expectedSelector = CorkRolloverContract__PremiumTokenMismatch.selector;
        }

        (accepted, wrongSelector) =
            _tryCompromisedDispatch(mode, rec, fillContext, phase, expectedSelector);
    }

    /// @inheritdoc ICompromisedSettlerDispatchDriver
    function driveOrderDigestTamper(uint8 fieldSeed, bool isPartial)
        external
        returns (bool accepted, bool wrongSelector, uint8 field)
    {
        require(msg.sender == address(compromisedHandler), "CompromisedDispatch: only handler");
        SettlerMode mode = isPartial ? SettlerMode.Partial : SettlerMode.Exact;
        field = fieldSeed % 6;
        CompromisedRecord memory rec = _compromisedRecord(mode);
        bytes32 suppliedDigest = rec.orderDigest;

        if (field == 0) {
            rec.orderData.originChainId = uint64(block.chainid + 1);
        } else if (field == 1) {
            rec.orderData.destinationChainId = uint64(block.chainid + 2);
        } else if (field == 2) {
            rec.orderData.orderSalt = rec.orderData.orderSalt + 1;
        } else if (field == 3) {
            rec.orderData.minPremiumPerShare = rec.orderData.minPremiumPerShare + 1;
        } else if (field == 4) {
            rec.orderData.fillerHint = address(0xF00D);
        } else {
            suppliedDigest = bytes32(uint256(rec.orderDigest) ^ uint256(0xD16E57));
        }

        RolloverTypes.FillContext memory fillContext = _fillContextMatching(rec.orderData);
        _predepositRolloverAssets();
        (accepted, wrongSelector) = _tryCompromisedDigestDispatch(
            mode,
            rec,
            fillContext,
            RolloverTypes.HookPhase.ROLLOVER,
            suppliedDigest,
            CorkRolloverContract__OrderDataDigestMismatch.selector
        );
    }

    /// @inheritdoc ICompromisedSettlerDispatchDriver
    function driveRolloverParamsTamper(uint8 fieldSeed, bool isPartial)
        external
        returns (bool accepted, bool wrongSelector, uint8 field)
    {
        require(msg.sender == address(compromisedHandler), "CompromisedDispatch: only handler");
        SettlerMode mode = isPartial ? SettlerMode.Partial : SettlerMode.Exact;
        field = fieldSeed % 7;
        CompromisedRecord memory rec = _compromisedRecord(mode);

        if (field == 0) {
            rec.orderData.rolloverParams.srcCstToken =
                address(uint160(rec.orderData.rolloverParams.srcCstToken) ^ uint160(1));
        } else if (field == 1) {
            rec.orderData.rolloverParams.dstCstToken =
                address(uint160(rec.orderData.rolloverParams.dstCstToken) ^ uint160(1));
        } else if (field == 2) {
            rec.orderData.rolloverParams.minCaReceived =
                rec.orderData.rolloverParams.minCaReceived ^ uint256(1);
        } else if (field == 3) {
            rec.orderData.rolloverParams.minSharesOut =
                rec.orderData.rolloverParams.minSharesOut ^ uint256(1);
        } else if (field == 4) {
            rec.orderData.rolloverParams.srcPoolId =
                bytes32(uint256(rec.orderData.rolloverParams.srcPoolId) ^ uint256(1));
        } else if (field == 5) {
            rec.orderData.rolloverParams.dstPoolId =
                bytes32(uint256(rec.orderData.rolloverParams.dstPoolId) ^ uint256(1));
        } else {
            rec.orderData.rolloverParams.settler =
                address(uint160(rec.orderData.rolloverParams.settler) ^ uint160(1));
        }

        RolloverTypes.FillContext memory fillContext = _fillContextMatching(rec.orderData);
        _predepositRolloverAssets();
        (accepted, wrongSelector) = _tryCompromisedDispatch(
            mode,
            rec,
            fillContext,
            RolloverTypes.HookPhase.ROLLOVER,
            CorkRolloverContract__OrderDataDigestMismatch.selector
        );
    }

    /// @inheritdoc ICompromisedSettlerDispatchDriver
    function driveExactFillSizeBindingProbe(uint8 scenarioSeed, uint256 amountSeed)
        external
        returns (
            bool invalidAccepted,
            bool invalidWrongSelector,
            bool validUnexpectedRevert,
            uint8 scenario
        )
    {
        require(msg.sender == address(compromisedHandler), "CompromisedDispatch: only handler");
        scenario = scenarioSeed % 7;
        FillSizeScenario selected = FillSizeScenario(scenario);
        uint256 orderSize = _fillSizeOrderSize(amountSeed);
        uint256 underfillAmount = orderSize - 1e18;
        uint256 overfillAmount = orderSize + 1;
        SettlerMode mode = SettlerMode.Exact;
        bool allowUnderfill;
        uint256 fillAmount;
        bytes4 expectedSelector;
        bool shouldAccept;

        if (selected == FillSizeScenario.ExactStrictFullValid) {
            fillAmount = orderSize;
            shouldAccept = true;
        } else if (selected == FillSizeScenario.ExactStrictUnderfillInvalid) {
            fillAmount = underfillAmount;
            expectedSelector = Settler__ExactFillRequiresFullOrderSize.selector;
        } else if (selected == FillSizeScenario.ExactStrictOverfillInvalid) {
            fillAmount = overfillAmount;
            expectedSelector = Settler__RolloverAmountOutOfBounds.selector;
        } else if (selected == FillSizeScenario.ExactAllowUnderfillValid) {
            allowUnderfill = true;
            fillAmount = underfillAmount;
            shouldAccept = true;
        } else if (selected == FillSizeScenario.ExactAllowUnderfillOverfillInvalid) {
            allowUnderfill = true;
            fillAmount = overfillAmount;
            expectedSelector = Settler__RolloverAmountOutOfBounds.selector;
        } else if (selected == FillSizeScenario.PartialUnderfillValid) {
            mode = SettlerMode.Partial;
            fillAmount = underfillAmount;
            shouldAccept = true;
        } else {
            mode = SettlerMode.Partial;
            fillAmount = overfillAmount;
            expectedSelector = Settler__RolloverAmountOutOfBounds.selector;
        }

        CompromisedRecord memory rec = _fillSizeRecord(mode, orderSize, fillAmount, allowUnderfill);
        (bool accepted, bool wrongSelector) =
            _trySettlerFillSizeProbe(rec, fillAmount, expectedSelector);
        if (shouldAccept) {
            validUnexpectedRevert = !accepted;
        } else {
            invalidAccepted = accepted;
            invalidWrongSelector = !accepted && wrongSelector;
        }
    }

    function _compromisedRecord(SettlerMode mode) internal returns (CompromisedRecord memory rec) {
        rec.orderData = _orderForMode(mode);
        rec.orderData.orderSize = COMPROMISED_FILL;
        rec.orderData.orderSalt = nextCompromisedSalt++;

        RolloverTypes.RolloverIntent memory draft =
            _buildIntent(bytes32(0), COMPROMISED_FILL, COMPROMISED_FILL);
        draft.nonce = rec.orderData.orderSalt;
        draft.deadline = rec.orderData.fillDeadline;
        rec.orderData.rolloverIntentHash = _zeroDigestHash(draft);

        rec.orderDigest = _openOrder(rec.orderData);
        rec.intent = _buildIntent(rec.orderDigest, COMPROMISED_FILL, COMPROMISED_FILL);
        rec.intent.nonce = rec.orderData.orderSalt;
        rec.intent.deadline = rec.orderData.fillDeadline;
        rec.cptHolderSig = _signOrder(cptHolderPk, rec.orderData);
    }

    function _fillSizeRecord(
        SettlerMode mode,
        uint256 orderSize,
        uint256 intentSrcAmount,
        bool allowUnderfill
    ) internal returns (CompromisedRecord memory rec) {
        rec.orderData = _orderForMode(mode);
        rec.orderData.orderSize = orderSize;
        rec.orderData.allowUnderfill = allowUnderfill;
        rec.orderData.orderSalt = nextCompromisedSalt++;

        RolloverTypes.RolloverIntent memory draft =
            _buildIntent(bytes32(0), intentSrcAmount, intentSrcAmount);
        draft.nonce = rec.orderData.orderSalt;
        draft.deadline = rec.orderData.fillDeadline;
        rec.orderData.rolloverIntentHash = _zeroDigestHash(draft);

        rec.orderDigest = _orderDigest(rec.orderData);
        rec.intent = _buildIntent(rec.orderDigest, intentSrcAmount, intentSrcAmount);
        rec.intent.nonce = rec.orderData.orderSalt;
        rec.intent.deadline = rec.orderData.fillDeadline;
        rec.cptHolderSig = _signOrder(cptHolderPk, rec.orderData);
    }

    function _fillSizeOrderSize(uint256 amountSeed) internal pure returns (uint256) {
        return ((amountSeed % 999) + 2) * 1e18;
    }

    function _fillContextMatching(RolloverTypes.OrderData memory orderData)
        internal
        view
        returns (RolloverTypes.FillContext memory fillContext)
    {
        fillContext = RolloverTypes.FillContext({
            filler: filler,
            fillAmount: COMPROMISED_FILL,
            rolloverIntentHash: orderData.rolloverIntentHash,
            fillDeadline: orderData.fillDeadline,
            allowPartialFills: orderData.allowPartialFills,
            allowUnderfill: orderData.allowUnderfill,
            orderSize: orderData.orderSize,
            originSettler: orderData.settler,
            premiumToken: address(0),
            premium: 0,
            subFiller: _subFillerKey(filler)
        });
    }

    function _predepositRolloverAssets() internal {
        srcCst.mint(rolloverContract, COMPROMISED_FILL);
    }

    function _tryCompromisedDispatch(
        SettlerMode mode,
        CompromisedRecord memory rec,
        RolloverTypes.FillContext memory fillContext,
        RolloverTypes.HookPhase phase,
        bytes4 expectedSelector
    ) internal returns (bool accepted, bool wrongSelector) {
        try this.compromisedDispatchProbe(mode, rec, fillContext, phase) {
            accepted = true;
        } catch (bytes memory err) {
            bytes4 actual = _revertSelector(err);
            wrongSelector = actual != expectedSelector;
        }
    }

    function _tryCompromisedDigestDispatch(
        SettlerMode mode,
        CompromisedRecord memory rec,
        RolloverTypes.FillContext memory fillContext,
        RolloverTypes.HookPhase phase,
        bytes32 suppliedDigest,
        bytes4 expectedSelector
    ) internal returns (bool accepted, bool wrongSelector) {
        try this.compromisedDigestDispatchProbe(mode, rec, fillContext, phase, suppliedDigest) {
            accepted = true;
        } catch (bytes memory err) {
            bytes4 actual = _revertSelector(err);
            wrongSelector = actual != expectedSelector;
        }
    }

    function _trySettlerFillSizeProbe(
        CompromisedRecord memory rec,
        uint256 fillAmount,
        bytes4 expectedSelector
    ) internal returns (bool accepted, bool wrongSelector) {
        try this.settlerFillSizeProbe(rec, fillAmount) {
            accepted = true;
        } catch (bytes memory err) {
            bytes4 actual = _revertSelector(err);
            wrongSelector = actual != expectedSelector;
        }
    }

    /// @notice External probe wrapper so the driver can catch rolloverContract-dispatch reverts.
    /// @param mode Settler mode used to choose exact or partial dispatch authority.
    /// @param rec Opened order bundle under test.
    /// @param fillContext Fill context supplied to the rolloverContract boundary.
    /// @param phase Hook phase supplied to the rolloverContract boundary.
    function compromisedDispatchProbe(
        SettlerMode mode,
        CompromisedRecord calldata rec,
        RolloverTypes.FillContext calldata fillContext,
        RolloverTypes.HookPhase phase
    ) external {
        require(msg.sender == address(this), "CompromisedDispatch: only self");
        vm.prank(_settlerAddressForMode(mode));
        IRolloverHookDispatcher(factory)
            .executeIntentHooks(
                rolloverContract,
                rec.orderDigest,
                phase,
                rec.intent,
                rec.cptHolderSig,
                fillContext,
                rec.orderData
            );
    }

    /// @notice External probe wrapper that allows the supplied digest to diverge from rec.
    /// @param mode Settler mode used to choose exact or partial dispatch authority.
    /// @param rec Opened order bundle under test.
    /// @param fillContext Fill context supplied to the rolloverContract boundary.
    /// @param phase Hook phase supplied to the rolloverContract boundary.
    /// @param suppliedDigest Order digest supplied to the rolloverContract boundary.
    function compromisedDigestDispatchProbe(
        SettlerMode mode,
        CompromisedRecord calldata rec,
        RolloverTypes.FillContext calldata fillContext,
        RolloverTypes.HookPhase phase,
        bytes32 suppliedDigest
    ) external {
        require(msg.sender == address(this), "CompromisedDispatch: only self");
        vm.prank(_settlerAddressForMode(mode));
        IRolloverHookDispatcher(factory)
            .executeIntentHooks(
                rolloverContract,
                suppliedDigest,
                phase,
                rec.intent,
                rec.cptHolderSig,
                fillContext,
                rec.orderData
            );
    }

    /// @notice External probe wrapper so the driver can catch Settler.fill reverts.
    /// @param rec Opened order bundle under test.
    /// @param fillAmount Rollover fill amount submitted to Settler.fill.
    function settlerFillSizeProbe(CompromisedRecord calldata rec, uint256 fillAmount) external {
        require(msg.sender == address(this), "CompromisedDispatch: only self");
        _doRolloverAs(rec.orderDigest, rec.orderData, rec.intent, fillAmount, filler);
    }

    function _revertSelector(bytes memory err) internal pure returns (bytes4 selector) {
        if (err.length < 4) {
            return bytes4(0);
        }
        assembly {
            selector := mload(add(err, 0x20))
        }
    }
}
