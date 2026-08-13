// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { FillScaffold } from "../../base/FillScaffold.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";
import { SettlerTypes } from "src/types/SettlerTypes.sol";

/// @notice PartialFillerRolloverFieldsTest — pins PartialFillerRolloverFields behaviour for the Cork Rollover suite.
contract PartialFillerRolloverFieldsTest is FillScaffold {
    /// @notice Pins behaviour: partial Record Writes Src And Dst Separately.
    function test_partialRecordWritesSrcAndDstSeparately() public {
        // Under INV-DST-CST-MINT-RATIO-BOUNDED the deposit-leg caps `sharesOut` at the
        // canonical Phoenix `previewDeposit` quote, so the `setPartialDeposit` knob can
        // only simulate under-mint (numerator ≤ denominator). The fixture intentionally
        // picks distinct `srcProvided > dstProduced` to keep the two record fields
        // observably different — the test's only purpose is to verify the
        // FillerRolloverAccounting storage slots are written separately.
        uint256 srcProvided = 1_000e18;
        uint256 dstProduced = 700e18;

        phoenixPool.setPartialDeposit(dstCst.poolId(), dstProduced, srcProvided);

        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData = _usePartialSettler(orderData);
        orderData.orderSize = 5_000e18;
        RolloverTypes.RolloverIntent memory intent =
            _buildIntent(bytes32(0), srcProvided, dstProduced);
        orderData.rolloverIntentHash = _zeroDigestHash(intent);
        bytes32 orderDigest = _openOrder(orderData);
        intent.orderDigest = orderDigest;
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);

        _approveFiller(srcProvided, 0);
        _doRolloverAs(orderDigest, orderData, intent, srcProvided, filler);

        SettlerTypes.FillerRolloverAccounting memory rec =
        partialSettler.fillerSlotAccountingOf(
            orderDigest, filler, bytes32(uint256(uint160(filler)))
        )
        .rollover;
        assertEq(rec.srcCstProvided, srcProvided, "srcCstProvided must equal actual srcCST paid");
        assertEq(rec.dstCstProduced, dstProduced, "dstCstProduced must equal minted dstCST");
        assertTrue(rec.srcCstProvided != rec.dstCstProduced, "fields must be distinct");
    }
}
