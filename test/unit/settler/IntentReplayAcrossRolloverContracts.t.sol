// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { FillScaffold } from "../../base/FillScaffold.sol";
import { CorkRolloverContract } from "src/CorkRolloverContract.sol";
import {
    CorkRolloverContract__RolloverContractMismatch
} from "src/errors/CorkRolloverContractErrors.sol";
import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice IntentReplayAcrossRolloverContractsTest — pins IntentReplayAcrossRolloverContracts behaviour for the Cork Rollover suite.
contract IntentReplayAcrossRolloverContractsTest is FillScaffold {
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
    /// @notice Test fixture setup.

    function setUp() public override {
        super.setUp();
        (cptHolder2, cptHolder2Pk) = makeAddrAndKey("cptHolder2");
        vm.prank(cptHolder2);
        rolloverContractB = factory.deployRolloverContract();
        assertTrue(rolloverContractB != rolloverContract, "rolloverContracts must be distinct");
    }

    /// @notice Pins behaviour: intent Replay Across RolloverContracts Reverts.
    function testRevert_intentReplayAcrossRolloverContractsReverts() public {
        RolloverTypes.OrderData memory orderA = _baseOrder();
        orderA.allowPartialFills = false;
        orderA.orderSize = FILL;
        RolloverTypes.RolloverIntent memory intentA = _buildIntent(bytes32(0), FILL, DST);
        orderA.rolloverIntentHash = _zeroDigestHash(intentA);
        bytes32 orderDigestA = _openOrder(orderA);
        intentA.orderDigest = orderDigestA;

        RolloverTypes.OrderData memory orderB = _baseOrder();
        orderB.user = cptHolder2;
        orderB.rolloverContract = rolloverContractB;
        orderB.orderSalt = 7;
        orderB.allowPartialFills = false;
        orderB.orderSize = FILL;
        orderB.rolloverIntentHash = orderA.rolloverIntentHash;
        ERC7683Types.GaslessCrossChainOrder memory gB = _gasless(orderB);
        bytes memory userSigB = _signOrder(cptHolder2Pk, orderB);
        bytes memory empty;
        settler.openFor(gB, userSigB, empty);
        bytes32 orderDigestB = _orderDigest(orderB);

        intentA.orderDigest = orderDigestB;

        _approveFiller(FILL, 0);
        vm.expectRevert(CorkRolloverContract__RolloverContractMismatch.selector);
        _doRolloverAs(orderDigestB, orderB, intentA, FILL, filler);
    }
}
