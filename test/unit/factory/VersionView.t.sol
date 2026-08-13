// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import {
    ICorkRolloverContractFactory
} from "src/interfaces/rollover/ICorkRolloverContractFactory.sol";

/// @notice VersionViewTest (factory) — pins identity-view behaviour for `CorkRolloverContractFactory`.
/// @dev Snapshot pin: any drift in `version()` semantics must trip this test.
contract FactoryVersionViewTest is BaseTest {
    /// @notice Pins behaviour: factory `version()` returns the exact semver literal "1.0.0".
    function test_version_returnsExpectedSemver() public view {
        string memory v = ICorkRolloverContractFactory(address(factory)).version();
        assertEq(v, "1.0.0", "factory version literal");
    }

    /// @notice Pins behaviour: factory `version()` is `pure` — invokable via staticcall.
    function test_version_isPure() public view {
        (bool ok, bytes memory ret) =
            address(factory).staticcall(abi.encodeWithSignature("version()"));
        assertTrue(ok, "factory version staticcall");
        string memory decoded = abi.decode(ret, (string));
        assertEq(decoded, "1.0.0", "factory version via staticcall");
    }
}
