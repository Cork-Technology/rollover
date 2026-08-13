// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { FillScaffold } from "../../base/FillScaffold.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice partial-mode metadata stays consistent when filled before openFor is called.
contract DirectPreOpenPartialMetadataTest is FillScaffold {
    /// @notice Direct filler.
    address internal directFiller = address(0xE1);

    /// @notice Fill.
    uint256 internal constant FILL = 500e18;

    /// @inheritdoc BaseTest
    function setUp() public override {
        super.setUp();
        srcCst.mint(directFiller, 1_000_000e18);
        premiumToken.mint(directFiller, 1_000_000e18);
        vm.startPrank(directFiller);
        srcCst.approve(address(settler), type(uint256).max);
        srcCst.approve(address(partialSettler), type(uint256).max);
        premiumToken.approve(address(settler), type(uint256).max);
        premiumToken.approve(address(partialSettler), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice direct pre open partial filler dst produced uses partial record.
    function test_directPreOpenPartialFillerDstProducedUsesPartialRecord() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData = _usePartialSettler(orderData);
        orderData.orderSize = 1_000e18;
        orderData.orderSalt = 501;
        RolloverTypes.RolloverIntent memory probe = _buildIntent(bytes32(0), FILL, FILL);
        orderData.rolloverIntentHash = _zeroDigestHash(probe);
        bytes32 orderDigest = _orderDigest(orderData);
        RolloverTypes.RolloverIntent memory intent = _buildIntent(orderDigest, FILL, FILL);
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);

        _doRolloverAs(orderDigest, orderData, intent, FILL, directFiller);

        assertEq(
            partialSettler.fillerSlotAccountingOf(
                    orderDigest, directFiller, bytes32(uint256(uint160(directFiller)))
                ).rollover.dstCstProduced,
            FILL
        );
    }
}
