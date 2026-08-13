// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { BaseSettler } from "src/BaseSettler.sol";
import {
    Settler__ExactFillsNotSupported,
    Settler__PartialFillsNotSupported,
    Settler__SettlerMismatch
} from "src/errors/SettlerErrors.sol";
import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";
import { SettlerTypes } from "src/types/SettlerTypes.sol";

/// @notice Split settler mode gates and address/domain binding checks.
contract SplitSettlerModeTest is BaseTest {
    /// @notice exact-mode settler rejects an order whose payload enables partial fills.
    function testRevert_exactSettlerRejectsPartialOrder() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.allowPartialFills = true;

        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory sig = _signOrder(cptHolderPk, orderData);

        vm.expectRevert(Settler__PartialFillsNotSupported.selector);
        settler.openFor(g, sig, "");
    }

    /// @notice partial-mode settler rejects an order whose payload disables partial fills.
    function testRevert_partialSettlerRejectsExactOrder() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.settler = address(partialSettler);
        orderData.rolloverParams.settler = address(partialSettler);

        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory sig = _signOrder(cptHolderPk, orderData);

        vm.expectRevert(Settler__ExactFillsNotSupported.selector);
        partialSettler.openFor(g, sig, "");
    }

    /// @notice partial-signed order cannot be replayed against the exact-mode settler.
    function testRevert_partialSignedOrderCannotOpenOnExactSettler() public {
        RolloverTypes.OrderData memory orderData = _usePartialSettler(_baseOrder());
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory sig = _signOrder(cptHolderPk, orderData);

        vm.expectRevert(Settler__SettlerMismatch.selector);
        settler.openFor(g, sig, "");
    }

    /// @notice exact-signed order cannot be replayed against the partial-mode settler.
    function testRevert_exactSignedOrderCannotOpenOnPartialSettler() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory sig = _signOrder(cptHolderPk, orderData);

        vm.expectRevert(Settler__SettlerMismatch.selector);
        partialSettler.openFor(g, sig, "");
    }

    /// @notice `fillerSlotAccountingOf` is partial-only and absent from the exact settler ABI.
    ///         The lens is keyed by `(orderDigest, filler, subFiller)`; this pin uses the
    ///         3-arg signature.
    function test_fillerSlotAccountingOf_partialOnly() public view {
        bytes memory callData = abi.encodeWithSignature(
            "fillerSlotAccountingOf(bytes32,address,bytes32)", bytes32(0), address(this), bytes32(0)
        );

        (bool exactOk,) = address(settler).staticcall(callData);
        (bool partialOk, bytes memory partialReturn) = address(partialSettler).staticcall(callData);

        assertFalse(exactOk, "exact must not expose fillerSlotAccountingOf");
        assertTrue(partialOk, "partial exposes fillerSlotAccountingOf");
        SettlerTypes.FillerSlotAccounting memory accounting =
            abi.decode(partialReturn, (SettlerTypes.FillerSlotAccounting));
        assertFalse(accounting.settled, "unset partial latch is false");
    }
}
