// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { FillScaffold } from "../../base/FillScaffold.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { CorkRolloverContract } from "src/CorkRolloverContract.sol";
import { CorkRolloverContractFactory } from "src/CorkRolloverContractFactory.sol";
import {
    CorkRolloverContract__BadIntentSignature,
    CorkRolloverContract__DeadlineExpired,
    CorkRolloverContract__IntentDeadlineExpired,
    CorkRolloverContract__InvalidThreshold,
    CorkRolloverContract__PremiumAlreadyFiredForFiller,
    CorkRolloverContract__RegistryZero,
    CorkRolloverContract__ZeroFiller
} from "src/errors/CorkRolloverContractErrors.sol";
import { Settler__ZeroPremiumToken } from "src/errors/SettlerErrors.sol";
import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import { ICorkRolloverContract } from "src/interfaces/rollover/ICorkRolloverContract.sol";
import {
    ICorkRolloverContractFactory
} from "src/interfaces/rollover/ICorkRolloverContractFactory.sol";
import { IRolloverHookDispatcher } from "src/interfaces/rollover/IRolloverHookDispatcher.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice CorkRolloverContractEnvelopeNegativesTest — pins CorkRolloverContractEnvelopeNegatives behaviour for the Cork Rollover suite.
contract CorkRolloverContractEnvelopeNegativesTest is FillScaffold {
    /// @notice Fill.
    uint256 internal constant FILL = 1_000e18;
    /// @notice Dst.

    uint256 internal constant DST = 1_000e18;
    /// @notice Premium.

    uint256 internal constant PREMIUM = 10e18;

    function _stdParams() internal view returns (RolloverTypes.RolloverParams memory) {
        return RolloverTypes.RolloverParams({
            srcCstToken: address(srcCst),
            dstCstToken: address(dstCst),
            minCaReceived: 0,
            minSharesOut: 0,
            srcPoolId: bytes32(0),
            dstPoolId: bytes32(0),
            settler: address(0),
            jitMarketHash: bytes32(0)
        });
    }

    function _setupOrderAndIntent()
        internal
        returns (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        )
    {
        orderData = _baseOrder();
        orderData.allowPartialFills = false;
        orderData.orderSize = FILL;
        intent = _buildIntent(bytes32(0), FILL, DST);
        orderData.rolloverIntentHash = _zeroDigestHash(intent);
        orderDigest = _openOrder(orderData);
        intent.orderDigest = orderDigest;
        cptHolderSig = _signOrder(cptHolderPk, orderData);
    }

    function _fillContextFor(RolloverTypes.OrderData memory orderData)
        internal
        view
        returns (RolloverTypes.FillContext memory)
    {
        return _fillContext(
            filler,
            FILL,
            orderData.rolloverIntentHash,
            orderData.fillDeadline,
            false,
            FILL,
            address(settler),
            address(premiumToken),
            0
        );
    }

    /// @notice Pins behaviour: reverts when deadline Expired.
    function testRevert_deadlineExpired() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupOrderAndIntent();
        RolloverTypes.FillContext memory fillContext = _fillContextFor(orderData);
        fillContext.fillDeadline = uint64(block.timestamp - 1);

        vm.expectRevert(CorkRolloverContract__DeadlineExpired.selector);
        vm.prank(address(settler));
        factory.executeIntentHooks(
            rolloverContract,
            orderDigest,
            RolloverTypes.HookPhase.ROLLOVER,
            intent,
            cptHolderSig,
            fillContext,
            orderData
        );
    }

    /// @notice Pins behaviour: reverts when intent Deadline Expired.
    function testRevert_intentDeadlineExpired() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupOrderAndIntent();

        vm.warp(uint256(intent.deadline) + 1);

        RolloverTypes.FillContext memory fillContext = _fillContextFor(orderData);
        fillContext.fillDeadline = uint64(block.timestamp + 1 days);

        vm.expectRevert(CorkRolloverContract__IntentDeadlineExpired.selector);
        vm.prank(address(settler));
        factory.executeIntentHooks(
            rolloverContract,
            orderDigest,
            RolloverTypes.HookPhase.ROLLOVER,
            intent,
            cptHolderSig,
            fillContext,
            orderData
        );
    }

    /// @notice Pins behaviour: reverts when phase Out Of Range.
    function testRevert_phaseOutOfRange() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupOrderAndIntent();
        RolloverTypes.FillContext memory fillContext = _fillContextFor(orderData);

        vm.prank(address(settler));
        (bool ok,) = address(factory)
            .call(
                abi.encodeWithSelector(
                    IRolloverHookDispatcher.executeIntentHooks.selector,
                    rolloverContract,
                    orderDigest,
                    uint8(99),
                    intent,
                    cptHolderSig,
                    fillContext,
                    orderData
                )
            );
        assertFalse(ok, "invalid raw phase accepted");
    }

    /// @notice Pins behaviour: reverts when zero Filler.
    function testRevert_zeroFiller() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupOrderAndIntent();
        RolloverTypes.FillContext memory fillContext = _fillContextFor(orderData);
        fillContext.filler = address(0);

        vm.expectRevert(CorkRolloverContract__ZeroFiller.selector);
        vm.prank(address(settler));
        factory.executeIntentHooks(
            rolloverContract,
            orderDigest,
            RolloverTypes.HookPhase.ROLLOVER,
            intent,
            cptHolderSig,
            fillContext,
            orderData
        );
    }

    /// @notice Pins behaviour: reverts when bad Intent Signature.
    function testRevert_badIntentSignature() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
        ) = _setupOrderAndIntent();

        (, uint256 strangerPk) = makeAddrAndKey("stranger");
        bytes memory badSig = _signOrder(strangerPk, orderData);
        RolloverTypes.FillContext memory fillContext = _fillContextFor(orderData);

        vm.expectRevert(CorkRolloverContract__BadIntentSignature.selector);
        vm.prank(address(settler));
        factory.executeIntentHooks(
            rolloverContract,
            orderDigest,
            RolloverTypes.HookPhase.ROLLOVER,
            intent,
            badSig,
            fillContext,
            orderData
        );
    }

    /// @notice Pins behaviour: a cPT-holder-signed order with `premiumToken == address(0)` is
    ///         rejected at Settler admission via INV-PREMIUM-TOKEN-NONZERO. The legacy
    ///         rolloverContract-side defence (`CorkRolloverContract__PremiumDrainTokenZero`) has been removed
    ///         as dead code now that the Settler admission gate blocks the order before
    ///         any rolloverContract dispatch.
    function testRevert_premiumDrainTokenZero_now_rejected_at_admission() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.allowPartialFills = false;
        orderData.orderSize = FILL;
        orderData.premiumToken = address(0);
        RolloverTypes.RolloverIntent memory intent = _buildIntent(bytes32(0), FILL, DST);
        orderData.rolloverIntentHash = _zeroDigestHash(intent);

        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory sig = _signOrder(cptHolderPk, orderData);

        vm.expectRevert(bytes4(keccak256("Settler__ZeroPremiumToken()")));
        settler.openFor(g, sig, "");
    }

    /// @notice Pins behaviour: reverts when premium Already Fired For Filler.
    function testRevert_premiumAlreadyFiredForFiller() public {
        (
            bytes32 orderDigest,
            RolloverTypes.OrderData memory orderData,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _runHappyPathThroughSettler();

        RolloverTypes.FillContext memory fillContext = _fillContext(
            filler,
            0,
            orderData.rolloverIntentHash,
            orderData.fillDeadline,
            false,
            FILL,
            address(settler),
            address(premiumToken),
            PREMIUM
        );

        vm.expectRevert(CorkRolloverContract__PremiumAlreadyFiredForFiller.selector);
        vm.prank(address(settler));
        factory.executeIntentHooks(
            rolloverContract,
            orderDigest,
            RolloverTypes.HookPhase.PREMIUM,
            intent,
            cptHolderSig,
            fillContext,
            orderData
        );
    }

    /// @notice Pins behaviour: rolloverContract setTrustConfig rejects threshold > attester length.
    function testRevert_setTrustConfig_thresholdAboveLength() public {
        address[] memory attesters = new address[](1);
        attesters[0] = address(0xAAA);
        vm.expectRevert(CorkRolloverContract__InvalidThreshold.selector);
        vm.prank(address(factory));
        ICorkRolloverContract(rolloverContract).setTrustConfig(2, attesters);
    }

    /// @notice Pins behaviour: rolloverContract setTrustConfig rejects zero threshold with attesters.
    function testRevert_setTrustConfig_zeroThresholdNonEmpty() public {
        address[] memory attesters = new address[](1);
        attesters[0] = address(0xAAA);
        vm.expectRevert(CorkRolloverContract__InvalidThreshold.selector);
        vm.prank(address(factory));
        ICorkRolloverContract(rolloverContract).setTrustConfig(0, attesters);
    }

    /// @notice Pins behaviour: rolloverContract setTrustConfig rejects zero threshold + empty list.
    function testRevert_setTrustConfig_zeroThresholdEmpty() public {
        address[] memory empty = new address[](0);
        vm.expectRevert(CorkRolloverContract__InvalidThreshold.selector);
        vm.prank(address(factory));
        ICorkRolloverContract(rolloverContract).setTrustConfig(0, empty);
    }

    /// @notice Pins behaviour: initialize Reverts On Zero Registry.
    function testRevert_initializeRevertsOnZeroRegistry() public {
        CorkRolloverContract freshImpl = new CorkRolloverContract();
        // CWIA trailer with address(0) baked as registry — initialize reads it via _registry().
        bytes memory args = abi.encodePacked(cptHolder, address(this), address(0));
        address freshRolloverContract = Clones.cloneWithImmutableArgs(address(freshImpl), args);

        address[] memory defaults = new address[](1);
        defaults[0] = defaultAttester;
        vm.prank(address(this));
        vm.expectRevert(CorkRolloverContract__RegistryZero.selector);
        ICorkRolloverContract(freshRolloverContract).initialize(1, defaults);
    }

    function _runHappyPathThroughSettler()
        internal
        returns (
            bytes32 orderDigest,
            RolloverTypes.OrderData memory orderData,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        )
    {
        orderData = _baseOrder();
        orderData.allowPartialFills = false;
        orderData.orderSize = FILL;
        intent = _buildIntent(bytes32(0), FILL, DST);
        orderData.rolloverIntentHash = _zeroDigestHash(intent);
        orderDigest = _openOrder(orderData);
        intent.orderDigest = orderDigest;
        cptHolderSig = _signOrder(cptHolderPk, orderData);
        _approveFiller(FILL, PREMIUM);
        _doRolloverAs(orderDigest, orderData, intent, FILL, filler);
    }
}
