// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../base/BaseTest.sol";
import { FactoryDefaultsRotationHandler } from "./handlers/FactoryDefaultsRotationHandler.sol";

/// @notice Shared setup for factory-wide defaults management invariant suites.
abstract contract FactoryDefaultsRotationInvariantBase is BaseTest {
    /// @notice Active handler.
    FactoryDefaultsRotationHandler internal defaultsHandler;

    /// @notice Sets up the active factory-defaults management handler and targets its actions.
    function _setUpFactoryDefaultsRotationInvariant() internal {
        defaultsHandler =
            new FactoryDefaultsRotationHandler(factory, address(this), rolloverContract);
        targetContract(address(defaultsHandler));
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = defaultsHandler.setValidDefaults.selector;
        selectors[1] = defaultsHandler.deployFreshRolloverContract.selector;
        targetSelector(FuzzSelector({ addr: address(defaultsHandler), selectors: selectors }));
    }
}
