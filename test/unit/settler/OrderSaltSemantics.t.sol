// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { FillScaffold } from "../../base/FillScaffold.sol";
import { BaseSettler } from "src/BaseSettler.sol";
import { ExactSettler as Settler } from "src/ExactSettler.sol";
import { Settler__OrderSaltMismatch } from "src/errors/SettlerErrors.sol";
import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice Pins the orderSalt semantics family — salt enters the EIP-712 OrderData digest so sibling orders sharing the same salt but differing in any other field still produce distinct digests; salt is per-(user, settler, rolloverContract, chain) and cannot collide across rolloverContracts or users.
contract OrderSaltSemanticsTest is FillScaffold {
    /// @notice Keeper.
    address internal keeper = address(0xCAFE);
    /// @notice CptHolder2.

    address internal cptHolder2;
    /// @notice CptHolder2 pk.

    uint256 internal cptHolder2Pk;
    /// @notice Test fixture setup.

    function setUp() public override {
        super.setUp();
        (cptHolder2, cptHolder2Pk) = makeAddrAndKey("cptHolder2");
        vm.label(keeper, "keeper");
        vm.label(cptHolder2, "cptHolder2");
    }

    function _orderWithSalt(uint64 orderSalt)
        internal
        view
        returns (RolloverTypes.OrderData memory orderData)
    {
        orderData = _baseOrder();
        orderData.orderSalt = orderSalt;
    }

    /// @notice Pins behaviour: b1 sibling Salts Produce Distinct Digests And Open Independently.
    function test_B1_siblingSaltsProduceDistinctDigestsAndOpenIndependently() public {
        RolloverTypes.OrderData memory a = _orderWithSalt(42);
        a.orderSize = 1_000e18;

        RolloverTypes.OrderData memory b = _orderWithSalt(42);
        b.orderSize = 2_000e18;

        bytes32 digestA = _orderDigest(a);
        bytes32 digestB = _orderDigest(b);
        assertTrue(digestA != digestB, "sibling salts must yield distinct digests");

        bytes32 openedA = _openOrder(a);
        bytes32 openedB = _openOrder(b);
        assertEq(openedA, digestA);
        assertEq(openedB, digestB);

        assertEq(
            uint8(settler.orderStatus(digestA)),
            uint8(RolloverTypes.OrderStatus.Opened),
            "sibling A opened"
        );
        assertEq(
            uint8(settler.orderStatus(digestB)),
            uint8(RolloverTypes.OrderStatus.Opened),
            "sibling B opened"
        );
    }

    /// @notice Pins behaviour: b2 idempotent Reopen status Unchanged.
    function test_B2_idempotentReopen_statusUnchanged() public {
        RolloverTypes.OrderData memory orderData = _orderWithSalt(43);
        bytes32 digest = _openOrder(orderData);
        assertEq(uint8(settler.orderStatus(digest)), uint8(RolloverTypes.OrderStatus.Opened));

        bytes32 digest2 = _openOrder(orderData);
        assertEq(digest, digest2);
        assertEq(
            uint8(settler.orderStatus(digest)),
            uint8(RolloverTypes.OrderStatus.Opened),
            "second openFor is idempotent"
        );
    }

    /// @notice Pins behaviour: b3 cross User Salt Collision both Open Independently.
    /// @dev Under INV-USER-IS-ROLLOVER_CONTRACT-OWNER each user must have its own rolloverContract; cptHolder2 deploys
    ///      a sibling rolloverContract via the same factory so the salt-collision property can still
    ///      be exercised across users.
    function test_B3_crossUserSaltCollision_bothOpenIndependently() public {
        RolloverTypes.OrderData memory a = _orderWithSalt(77);

        vm.prank(cptHolder2);
        address rolloverContract2 = factory.deployRolloverContract();

        RolloverTypes.OrderData memory b = _orderWithSalt(77);
        b.user = cptHolder2;
        b.rolloverContract = rolloverContract2;

        bytes32 digestA = _orderDigest(a);
        bytes32 digestB = _orderDigest(b);
        assertTrue(digestA != digestB, "different users yield different digests");

        bytes32 openedA = _openOrder(a);
        assertEq(openedA, digestA);

        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(b);
        bytes memory sig = _signOrder(cptHolder2Pk, b);
        settler.openFor(g, sig, "");

        assertEq(uint8(settler.orderStatus(digestA)), uint8(RolloverTypes.OrderStatus.Opened));
        assertEq(uint8(settler.orderStatus(digestB)), uint8(RolloverTypes.OrderStatus.Opened));
    }

    /// @notice Pins behaviour: b4 direct Unopened Fill From None Still Works.
    function test_B4_directUnopenedFillFromNoneStillWorks() public {
        RolloverTypes.OrderData memory orderData = _orderWithSalt(81);
        orderData.allowPartialFills = false;
        orderData.orderSize = 1_000e18;

        RolloverTypes.RolloverIntent memory probe = _buildIntent(bytes32(0), 1_000e18, 1_000e18);
        orderData.rolloverIntentHash = _zeroDigestHash(probe);

        bytes32 orderDigest = _orderDigest(orderData);

        assertEq(
            uint8(settler.orderStatus(orderDigest)),
            uint8(RolloverTypes.OrderStatus.None),
            "pre-fill status is None"
        );

        RolloverTypes.RolloverIntent memory intent = _buildIntent(orderDigest, 1_000e18, 1_000e18);
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);
        _approveFiller(1_000e18, 0);

        uint256 rolloverContractSrcCstBefore = srcCst.balanceOf(rolloverContract);
        _doRolloverAs(orderDigest, orderData, intent, 1_000e18, filler);

        assertEq(
            srcCst.balanceOf(rolloverContract) - rolloverContractSrcCstBefore,
            0,
            "post-rollover rolloverContract srcCst delta matches expected (consumed by unwind)"
        );

        // Under atomic-fill the direct (None → Settled) path completes in one frame.
        assertEq(
            uint8(settler.orderStatus(orderDigest)),
            uint8(RolloverTypes.OrderStatus.Settled),
            "atomic-fill: direct unopened fill settles in-frame"
        );
    }

    /// @notice Pins behaviour: b5 cancel Is Order Scoped Not Salt Scoped.
    function test_B5_cancelIsOrderScopedNotSaltScoped() public {
        RolloverTypes.OrderData memory a = _orderWithSalt(91);
        a.orderSize = 500e18;
        RolloverTypes.OrderData memory b = _orderWithSalt(91);
        b.orderSize = 750e18;

        bytes32 digestA = _openOrder(a);
        bytes32 digestB = _openOrder(b);
        assertTrue(digestA != digestB);

        bytes memory sigA = _signCancelFor(a.settler, cptHolderPk, digestA, a.orderSalt);
        settler.cancel(digestA, _originData(a), sigA);
        assertEq(uint8(settler.orderStatus(digestA)), uint8(RolloverTypes.OrderStatus.Cancelled));

        assertEq(
            uint8(settler.orderStatus(digestB)),
            uint8(RolloverTypes.OrderStatus.Opened),
            "sibling B unaffected by cancel of A"
        );

        bytes memory sigB = _signCancelFor(b.settler, cptHolderPk, digestB, b.orderSalt);
        settler.cancel(digestB, _originData(b), sigB);
        assertEq(uint8(settler.orderStatus(digestB)), uint8(RolloverTypes.OrderStatus.Cancelled));
    }

    /// @notice Pins behaviour: b6 envelope Payload Mismatch Reverts.
    function test_B6_envelopePayloadMismatchReverts() public {
        RolloverTypes.OrderData memory orderData = _orderWithSalt(5);
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);

        g.nonce = 6;
        bytes memory sig = _signOrder(cptHolderPk, orderData);

        vm.expectRevert(Settler__OrderSaltMismatch.selector);
        settler.openFor(g, sig, "");
    }
}
