// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { FillScaffold } from "../../base/FillScaffold.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice setTrustConfig changes apply going forward — in-flight orders observe the pre-change config.
contract SetTrustConfigRetroactivityTest is FillScaffold {
    /// @notice Fill.
    uint256 internal constant FILL = 1_000e18;

    /// @notice Dst.
    uint256 internal constant DST = 1_000e18;

    /// @notice trust config change reverts outstanding intent.
    function test_trustConfigChangeRevertsOutstandingIntent() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.allowPartialFills = false;
        orderData.orderSize = FILL;
        RolloverTypes.RolloverIntent memory intent = _buildIntent(bytes32(0), FILL, DST);
        orderData.rolloverIntentHash = _zeroDigestHash(intent);
        bytes32 orderDigest = _openOrder(orderData);
        intent.orderDigest = orderDigest;
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);

        erc7484.setRejectedFor(rolloverContract, address(sourceSrcCptModule), true);

        _approveFiller(FILL, 0);
        vm.expectRevert();
        _doRolloverAs(orderDigest, orderData, intent, FILL, filler);
    }
}
