// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { SettlerPinHandler } from "../handlers/SettlerPinHandler.sol";

/// @notice INV-PARAMS-SETTLER-PIN — fail-on-revert invariant suite: RolloverParams.settler must equal fillContext.originSettler at fill time.
/// @dev fail-on-revert mode (companion at test/invariant/continueOnRevert/ParamsSettlerPin.t.sol).
/// @custom:invariant INV-PARAMS-SETTLER-PIN
contract ParamsSettlerPinFailOnRevertTest is BaseTest {
    /// @notice Exact-mode handler.
    SettlerPinHandler internal exactHandler;

    /// @notice Partial-mode handler.
    SettlerPinHandler internal partialHandler;

    /// @inheritdoc BaseTest
    function setUp() public override {
        super.setUp();

        exactHandler = new SettlerPinHandler(factory, address(settler), rolloverContract);
        partialHandler = new SettlerPinHandler(factory, address(partialSettler), rolloverContract);
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = exactHandler.dispatchMatched.selector;
        selectors[1] = exactHandler.dispatchMismatched.selector;
        targetSelector(FuzzSelector({ addr: address(exactHandler), selectors: selectors }));
        targetSelector(FuzzSelector({ addr: address(partialHandler), selectors: selectors }));
    }

    /// @notice invariant: no mismatched dispatch accepted.
    function invariant_noMismatchedDispatchAccepted() public view {
        assertEq(
            exactHandler.ghostMismatchedAccepted(),
            0,
            "INV-PARAMS-SETTLER-PIN: exact mismatch slipped"
        );
        assertEq(
            partialHandler.ghostMismatchedAccepted(),
            0,
            "INV-PARAMS-SETTLER-PIN: partial mismatch slipped"
        );
    }
}
