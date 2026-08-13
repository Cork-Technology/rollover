// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { FillScaffold } from "../../base/FillScaffold.sol";
import { BaseSettler } from "src/BaseSettler.sol";
import {
    Settler__OriginSettlerMismatch,
    Settler__RolloverParamsDstCstMismatch,
    Settler__RolloverParamsSettlerMismatch,
    Settler__RolloverParamsSrcCstMismatch
} from "src/errors/SettlerErrors.sol";
import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice Pins the Settler-half of INV-PARAMS-SETTLER-PIN-MIRROR. `_validateOrderCommon`
///         cross-checks `orderData.rolloverParams.settler == orderData.settler` at admission,
///         pattern-consistent with the existing `srcCstToken` and `dstCstToken` mirror
///         checks. Closes the cPT holder self-grief class where a cPT holder signing a non-zero but
///         bogus inner `rolloverParams.settler` admits at openFor and reverts every fill
///         downstream at the rolloverContract's `_validateRolloverPreflight`.
contract RolloverParamsSettlerMirrorTest is FillScaffold {
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

    /// @notice happy path: canonical `rolloverParams.settler == orderData.settler` admits.
    function test_open_with_canonical_inner_settler_succeeds() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory sig = _signOrder(cptHolderPk, orderData);

        settler.openFor(g, sig, "");
        bytes32 orderDigest = _orderDigest(orderData);
        assertEq(uint8(settler.orderStatus(orderDigest)), uint8(RolloverTypes.OrderStatus.Opened));
    }

    /// @notice openFor rejects when `rolloverParams.settler` is a non-canonical non-zero address.
    function testRevert_open_with_bogus_inner_settler() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        orderData.rolloverParams.settler = address(0xBEEF);
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory sig = _signOrder(cptHolderPk, orderData);

        vm.expectRevert(bytes4(keccak256("Settler__RolloverParamsSettlerMismatch()")));
        settler.openFor(g, sig, "");
    }

    /// @notice openFor rejects when `rolloverParams.settler == address(0)`.
    function testRevert_open_with_inner_settler_zero() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        orderData.rolloverParams.settler = address(0);
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory sig = _signOrder(cptHolderPk, orderData);

        vm.expectRevert(bytes4(keccak256("Settler__RolloverParamsSettlerMismatch()")));
        settler.openFor(g, sig, "");
    }

    /// @notice when outer `orderData.settler != address(this)`, the outer check fires first
    ///         (Settler__SettlerMismatch), before the new mirror check.
    function testRevert_outer_settler_wrong_fires_earlier() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        orderData.settler = address(0xCAFE);
        orderData.rolloverParams.settler = address(0xCAFE);
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        g.originSettler = address(settler);
        bytes memory sig = _signOrder(cptHolderPk, orderData);

        vm.expectRevert(Settler__OriginSettlerMismatch.selector);
        settler.openFor(g, sig, "");
    }

    /// @notice existing src-CST mirror check still fires (regression).
    function testRevert_existing_srcCst_mirror_check_still_fires() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        orderData.rolloverParams.srcCstToken = address(0xDEAD);
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory sig = _signOrder(cptHolderPk, orderData);

        vm.expectRevert(Settler__RolloverParamsSrcCstMismatch.selector);
        settler.openFor(g, sig, "");
    }

    /// @notice existing dst-CST mirror check still fires (regression).
    function testRevert_existing_dstCst_mirror_check_still_fires() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        orderData.rolloverParams.dstCstToken = address(0xDEAD);
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory sig = _signOrder(cptHolderPk, orderData);

        vm.expectRevert(Settler__RolloverParamsDstCstMismatch.selector);
        settler.openFor(g, sig, "");
    }

    /// @notice `Settler__RolloverParamsSettlerMismatch` selector resolves via observed revert.
    function test_error_selector_added() public {
        bytes4 expected = bytes4(keccak256("Settler__RolloverParamsSettlerMismatch()"));
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        orderData.rolloverParams.settler = address(0xBEEF);
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory sig = _signOrder(cptHolderPk, orderData);
        try settler.openFor(g, sig, "") {
            revert("admission must reject mismatched rolloverParams.settler");
        } catch (bytes memory reason) {
            bytes4 actual;
            assembly {
                actual := mload(add(reason, 0x20))
            }
            assertEq(actual, expected);
        }
    }
}
