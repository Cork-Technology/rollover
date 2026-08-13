// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { FillScaffold } from "../../base/FillScaffold.sol";
import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice each rolloverContract mirrors its own trust-config so IERC7484.check stays narrow.
contract PerRolloverContractTrustConfigTest is FillScaffold {
    /// @notice Fill.
    uint256 internal constant FILL = 1_000e18;

    /// @notice Dst.
    uint256 internal constant DST = 1_000e18;

    /// @notice CptHolder2.
    address internal cptHolder2;

    /// @notice CptHolder2 pk.
    uint256 internal cptHolder2Pk;

    /// @notice RolloverContract b.
    address internal rolloverContractB;

    /// @inheritdoc BaseTest
    function setUp() public override {
        super.setUp();
        (cptHolder2, cptHolder2Pk) = makeAddrAndKey("cptHolder2");
        vm.prank(cptHolder2);
        rolloverContractB = factory.deployRolloverContract();
    }

    /// @notice _open on rolloverContract b.
    function _openOnRolloverContractB()
        internal
        returns (
            bytes32 orderDigest,
            RolloverTypes.OrderData memory orderData,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        )
    {
        orderData = _baseOrder();
        orderData.user = cptHolder2;
        orderData.rolloverContract = rolloverContractB;
        orderData.orderSalt = 2;
        orderData.allowPartialFills = false;
        orderData.orderSize = FILL;
        intent = _buildIntent(bytes32(0), FILL, DST);
        intent.rolloverContract = rolloverContractB;
        orderData.rolloverIntentHash = _zeroDigestHash(intent);

        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory userSig = _signOrder(cptHolder2Pk, orderData);
        bytes memory empty;
        settler.openFor(g, userSig, empty);

        orderDigest = _orderDigest(orderData);
        intent.orderDigest = orderDigest;
        cptHolderSig = _signOrder(cptHolder2Pk, orderData);
    }

    /// @notice per rolloverContract isolation.
    function test_perRolloverContractIsolation() public {
        erc7484.setRejectedFor(rolloverContractB, address(sourceSrcCptModule), true);

        RolloverTypes.OrderData memory orderA = _baseOrder();
        orderA.allowPartialFills = false;
        orderA.orderSize = FILL;
        RolloverTypes.RolloverIntent memory intentA = _buildIntent(bytes32(0), FILL, DST);
        orderA.rolloverIntentHash = _zeroDigestHash(intentA);
        bytes32 orderDigestA = _openOrder(orderA);
        intentA.orderDigest = orderDigestA;
        bytes memory sigA = _signOrder(cptHolderPk, orderA);

        _approveFiller(FILL * 2, 0);
        _doRolloverAs(orderDigestA, orderA, intentA, FILL, filler);

        (
            bytes32 orderDigestB,
            RolloverTypes.OrderData memory orderB,
            RolloverTypes.RolloverIntent memory intentB,
            bytes memory sigB
        ) = _openOnRolloverContractB();
        vm.expectRevert();
        _doRolloverAs(orderDigestB, orderB, intentB, FILL, filler);
    }
}
