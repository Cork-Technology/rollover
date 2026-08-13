// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { FillScaffold } from "../../base/FillScaffold.sol";
import { BaseSettler } from "src/BaseSettler.sol";
import {
    Settler__DstCstEqualsPremiumToken,
    Settler__SrcCstEqualsPremiumToken,
    Settler__ZeroPremiumToken
} from "src/errors/SettlerErrors.sol";
import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice Pins INV-PREMIUM-TOKEN-NONZERO. `_validateOrderCommon` rejects any order
///         where `orderData.premiumToken == address(0)` at both admission paths
///         (openFor and direct-fill). Closes the filler-strand-until-fillDeadline grief
///         class where a cPT holder signing `premiumToken = address(0)` would admit at
///         `_validateOrderCommon` (vacuous src/dst-vs-premium mismatch checks) and
///         later strand dstCST in `_executePremiumLeg` at `IERC20(address(0)).balanceOf`.
contract PremiumTokenZeroAdmissionTest is FillScaffold {
    /// @notice Order size used across admission tests.
    uint256 internal constant ORDER = 1_000e18;

    /// @inheritdoc BaseTest
    function setUp() public override {
        super.setUp();
        vm.startPrank(filler);
        srcCst.approve(address(settler), type(uint256).max);
        srcCst.approve(address(partialSettler), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice _prepare builds intent + signature for a happy direct-fill flow.
    /// @param orderData OrderData under test.
    /// @return orderDigest EIP-712 order digest.
    /// @return intent RolloverIntent bound to `orderDigest`.
    /// @return cptHolderSig cPT holder signature over `OrderData`.
    function _prepare(RolloverTypes.OrderData memory orderData)
        internal
        view
        returns (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        )
    {
        RolloverTypes.RolloverIntent memory probe = _buildIntent(bytes32(0), ORDER, ORDER);
        orderData.rolloverIntentHash = _zeroDigestHash(probe);
        orderDigest = _orderDigest(orderData);
        intent = _buildIntent(orderDigest, ORDER, ORDER);
        cptHolderSig = _signOrder(cptHolderPk, orderData);
    }

    /// @notice openFor rejects an order signed with `premiumToken == address(0)`.
    function testRevert_openFor_zeroPremiumToken() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        orderData.premiumToken = address(0);

        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory sig = _signOrder(cptHolderPk, orderData);

        vm.expectRevert(bytes4(keccak256("Settler__ZeroPremiumToken()")));
        settler.openFor(g, sig, "");
    }

    /// @notice direct-fill rejects an order signed with `premiumToken == address(0)`.
    function testRevert_directFill_zeroPremiumToken() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        orderData.premiumToken = address(0);
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(orderData);

        vm.expectRevert(bytes4(keccak256("Settler__ZeroPremiumToken()")));
        _doRolloverAs(orderDigest, orderData, intent, ORDER, filler);
    }

    /// @notice nonzero `premiumToken` happy path still admits (regression).
    function test_nonzeroPremiumToken_happyPath() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(orderData);

        _doRolloverAs(orderDigest, orderData, intent, ORDER, filler);
        assertEq(settler.rolloverAccountingOf(orderDigest).dstCstProduced, ORDER);
    }

    /// @notice srcCst == premiumToken admission check still fires (regression).
    function testRevert_existing_srcCstEqualsPremium_check_still_fires() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        orderData.premiumToken = address(srcCst);

        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory sig = _signOrder(cptHolderPk, orderData);

        vm.expectRevert(Settler__SrcCstEqualsPremiumToken.selector);
        settler.openFor(g, sig, "");
    }

    /// @notice dstCst == premiumToken admission check still fires (regression).
    function testRevert_existing_dstCstEqualsPremium_check_still_fires() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        orderData.premiumToken = address(dstCst);

        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory sig = _signOrder(cptHolderPk, orderData);

        vm.expectRevert(Settler__DstCstEqualsPremiumToken.selector);
        settler.openFor(g, sig, "");
    }

    /// @notice `Settler__ZeroPremiumToken` selector resolves and matches the deployed
    ///         BaseSettler bytecode. After src/ adds the error, this matches `BaseSettler`.
    function test_error_selector_added() public {
        bytes4 expected = bytes4(keccak256("Settler__ZeroPremiumToken()"));
        // Construct a malformed order and observe the revert selector matches.
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        orderData.premiumToken = address(0);
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory sig = _signOrder(cptHolderPk, orderData);
        try settler.openFor(g, sig, "") {
            revert("admission must reject zero premiumToken");
        } catch (bytes memory reason) {
            bytes4 actual;
            assembly {
                actual := mload(add(reason, 0x20))
            }
            assertEq(actual, expected);
        }
    }
}
