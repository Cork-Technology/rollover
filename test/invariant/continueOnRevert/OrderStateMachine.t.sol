// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { OrderStateMachineHandler } from "../handlers/OrderStateMachineHandler.sol";
import { ISettler } from "src/interfaces/settlers/ISettler.sol";

/// @notice BS-ST-20 — continue-on-revert invariant suite: OrderStatus transitions respect the documented terminal/non-terminal partition.
/// @dev continue-on-revert mode (companion at test/invariant/failOnRevert/OrderStateMachine.t.sol).
/// @custom:invariant BS-ST-20
contract OrderStateMachineContinueOnRevertTest is BaseTest {
    /// @notice Exact-mode state-machine handler.
    OrderStateMachineHandler internal exactHandler;

    /// @notice Partial-mode state-machine handler.
    OrderStateMachineHandler internal partialHandler;

    /// @inheritdoc BaseTest
    function setUp() public override {
        super.setUp();
        exactHandler = new OrderStateMachineHandler(ISettler(address(settler)));
        partialHandler = new OrderStateMachineHandler(ISettler(address(partialSettler)));
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = exactHandler.observe.selector;
        selectors[1] = exactHandler.registerOrderId.selector;
        selectors[2] = exactHandler.warpForward.selector;
        targetSelector(FuzzSelector({ addr: address(exactHandler), selectors: selectors }));
        targetSelector(FuzzSelector({ addr: address(partialHandler), selectors: selectors }));
    }

    /// @notice invariant: terminal status is sticky.
    function invariant_terminalStatusIsSticky() public view {
        _assertTerminalStatusIsSticky(exactHandler, ISettler(address(settler)));
        _assertTerminalStatusIsSticky(partialHandler, ISettler(address(partialSettler)));
    }

    function _assertTerminalStatusIsSticky(OrderStateMachineHandler handler, ISettler target)
        internal
        view
    {
        uint256 n = handler.observedCount();
        for (uint256 i = 0; i < n; ++i) {
            bytes32 id = handler.observedOrders(i);
            uint8 snap = handler.firstNonNoneStatus(id);
            if (snap == 2 || snap == 3 || snap == 4) {
                uint8 live = uint8(target.orderStatus(id));
                assertTrue(
                    live == 2 || live == 3 || live == 4, "BS-ST-20: terminal regressed (loose mode)"
                );
            }
        }
    }
}
