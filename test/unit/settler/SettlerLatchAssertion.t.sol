// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {
    CorkRolloverContractFactory__SettlerNotApproved
} from "src/errors/CorkRolloverContractFactoryErrors.sol";

import { FillScaffold } from "../../base/FillScaffold.sol";
import { CorkRolloverContract } from "src/CorkRolloverContract.sol";
import { CorkRolloverContractFactory } from "src/CorkRolloverContractFactory.sol";
import { ExactSettler as Settler } from "src/ExactSettler.sol";
import { CorkRolloverContract__NotFactory } from "src/errors/CorkRolloverContractErrors.sol";
import { ICorkRolloverContract } from "src/interfaces/rollover/ICorkRolloverContract.sol";
import {
    ICorkRolloverContractFactory
} from "src/interfaces/rollover/ICorkRolloverContractFactory.sol";
import {
    ICorkRolloverContractFactoryAdmin
} from "src/interfaces/rollover/ICorkRolloverContractFactoryAdmin.sol";
import { IRolloverHookDispatcher } from "src/interfaces/rollover/IRolloverHookDispatcher.sol";
import { Typehashes } from "src/libraries/Typehashes.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice View hook that asserts `factory.originatingSettler()` during a dispatch frame.
contract OriginLatchProbe {
    /// @notice Require the factory origin latch to equal `expected`.
    /// @param factoryAddr Cork factory address.
    /// @param expected Expected latched origin settler.
    function assertOrigin(address factoryAddr, address expected) external view {
        if (IRolloverHookDispatcher(factoryAddr).originatingSettler() != expected) {
            revert("OriginLatchProbe: origin latch mismatch");
        }
    }
}

/// @notice SettlerLatchAssertionTest — pins SettlerLatchAssertion behaviour for the Cork Rollover suite.
contract SettlerLatchAssertionTest is FillScaffold {
    /// @notice Origin latch probe deployed for in-frame assertions.
    OriginLatchProbe internal originProbe;

    /// @notice Deploy and attest the origin-latch probe used by mixed-settler tests.
    function setUp() public override {
        super.setUp();
        originProbe = new OriginLatchProbe();
        erc7484.setAttestedType(address(originProbe), Typehashes.MODULE_TYPE_PRE_ROLLOVER_HOOK);
    }
    /// @notice Fill.
    uint256 internal constant FILL = 1_000e18;
    /// @notice Dst.

    uint256 internal constant DST = 1_000e18;

    /// @notice Pins behaviour: direct RolloverContract Call Reverts Not Factory.
    function testRevert_directRolloverContractCallRevertsNotFactory() public {
        RolloverTypes.RolloverIntent memory intent = _emptyIntent(rolloverContract, bytes32(0));
        RolloverTypes.FillContext memory fillContext = _fillContext(
            filler,
            FILL,
            bytes32(0),
            uint64(block.timestamp + 1 days),
            false,
            FILL,
            address(settler),
            address(premiumToken),
            0
        );
        vm.expectRevert(CorkRolloverContract__NotFactory.selector);
        vm.prank(anyone);
        ICorkRolloverContract(rolloverContract)
            .executeIntentHooks(
                bytes32(uint256(0xC0FE)),
                RolloverTypes.HookPhase.ROLLOVER,
                intent,
                bytes(""),
                fillContext,
                _emptyOrderData()
            );
    }

    /// @notice Pins behaviour: reverts when settler Mismatch On Factory Call.
    function testRevert_settlerMismatchOnFactoryCall() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.allowPartialFills = false;
        orderData.orderSize = FILL;
        RolloverTypes.RolloverIntent memory intent = _buildIntent(bytes32(0), FILL, DST);
        orderData.rolloverIntentHash = _zeroDigestHash(intent);
        bytes32 orderDigest = _openOrder(orderData);
        intent.orderDigest = orderDigest;
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);

        RolloverTypes.FillContext memory fillContext = _fillContext(
            filler,
            FILL,
            orderData.rolloverIntentHash,
            orderData.fillDeadline,
            false,
            FILL,
            address(0xDEAD),
            address(premiumToken),
            0
        );

        vm.prank(anyone);
        vm.expectRevert();
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

    function _buildExecuteCallFor(address originSettler)
        internal
        returns (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig,
            RolloverTypes.FillContext memory fillContext
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
        fillContext = _fillContext(
            filler,
            FILL,
            orderData.rolloverIntentHash,
            orderData.fillDeadline,
            false,
            FILL,
            originSettler,
            address(premiumToken),
            0
        );
    }

    /// @notice Pins behaviour: unapproved Settler Reverts At Factory Gate.
    function testRevert_unapprovedSettlerRevertsAtFactoryGate() public {
        factory.revokeSettler(address(settler));

        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig,
            RolloverTypes.FillContext memory fillContext
        ) = _buildExecuteCallFor(address(settler));

        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContractFactory__SettlerNotApproved.selector, address(settler)
            )
        );
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

    /// @notice Mixed-settler dispatches in one tx succeed once the origin latch clears between calls.
    function test_mixedSettlerSameTx_succeedsAfterOriginLatchClears() public {
        // --- ExactSettler order (salt 1) ---
        RolloverTypes.OrderData memory exactOrder = _baseOrder();
        exactOrder.orderSalt = 1;
        exactOrder.allowPartialFills = false;
        exactOrder.orderSize = FILL;
        RolloverTypes.RolloverIntent memory exactIntent = _intentWithOriginProbe(address(settler));
        exactOrder.rolloverIntentHash = _zeroDigestHash(exactIntent);
        bytes32 exactDigest = _openOrder(exactOrder);
        exactIntent.orderDigest = exactDigest;
        _approveFiller(FILL, 0);
        _doRolloverAs(exactDigest, exactOrder, exactIntent, FILL, filler);
        assertEq(factory.originatingSettler(), address(0), "origin latch cleared after exact fill");

        // --- PartialSettler order (salt 2) ---
        RolloverTypes.OrderData memory partialOrder = _usePartialSettler(_baseOrder());
        partialOrder.orderSalt = 2;
        partialOrder.orderSize = FILL;
        RolloverTypes.RolloverIntent memory partialIntent =
            _intentWithOriginProbe(address(partialSettler));
        partialOrder.rolloverIntentHash = _zeroDigestHash(partialIntent);
        bytes32 partialDigest = _openOrder(partialOrder);
        partialIntent.orderDigest = partialDigest;
        _doRolloverAs(partialDigest, partialOrder, partialIntent, FILL, filler);
        assertEq(
            factory.originatingSettler(), address(0), "origin latch cleared after partial fill"
        );
    }

    function _intentWithOriginProbe(address expectedOrigin)
        internal
        view
        returns (RolloverTypes.RolloverIntent memory intent)
    {
        RolloverTypes.Call[] memory preHooks = new RolloverTypes.Call[](2);
        preHooks[0] = _hook(
            address(sourceSrcCptModule),
            abi.encodeWithSignature("execute(address,uint256)", address(srcCpt), FILL)
        );
        preHooks[1] = _hook(
            address(originProbe),
            abi.encodeWithSignature(
                "assertOrigin(address,address)", address(factory), expectedOrigin
            )
        );
        RolloverTypes.Call[] memory postHooks = new RolloverTypes.Call[](1);
        postHooks[0] = _hook(
            address(consumeDstCptModule),
            abi.encodeWithSignature("execute(address)", address(dstCpt))
        );
        return _intentWithHooks(
            rolloverContract, bytes32(0), preHooks, new RolloverTypes.Call[](0), postHooks
        );
    }

    /// @notice Pins behaviour: approve Revoke Events Emitted.
    function test_approveRevokeEventsEmitted() public {
        Settler tgt = new Settler(
            address(factory),
            address(this),
            address(this),
            address(this),
            address(this),
            address(this)
        );

        vm.expectEmit(true, false, false, true, address(factory));
        emit ICorkRolloverContractFactoryAdmin.SettlerApproved(address(tgt));
        factory.approveSettler(address(tgt));
        assertTrue(factory.approvedSettlers(address(tgt)), "approveSettler must set the flag");

        vm.expectEmit(true, false, false, true, address(factory));
        emit ICorkRolloverContractFactoryAdmin.SettlerRevoked(address(tgt));
        factory.revokeSettler(address(tgt));
        assertFalse(factory.approvedSettlers(address(tgt)), "revokeSettler must clear the flag");
    }
}
