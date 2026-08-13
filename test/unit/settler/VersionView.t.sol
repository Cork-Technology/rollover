// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { ISettler } from "src/interfaces/settlers/ISettler.sol";

/// @notice VersionViewTest (settler) — pins identity-view behaviour for `Settler`.
/// @dev Snapshot pin: any drift in `version()` semantics must trip this test.
contract SettlerVersionViewTest is BaseTest {
    /// @notice Pins behaviour: settler `version()` returns the exact semver literal "1.0.0".
    function test_version_returnsExpectedSemver() public view {
        string memory v = ISettler(address(settler)).version();
        assertEq(v, "1.0.0", "settler version literal");
    }

    /// @notice Pins behaviour: settler `version()` is `pure` — invokable via staticcall.
    function test_version_isPure() public view {
        (bool ok, bytes memory ret) =
            address(settler).staticcall(abi.encodeWithSignature("version()"));
        assertTrue(ok, "settler version staticcall");
        string memory decoded = abi.decode(ret, (string));
        assertEq(decoded, "1.0.0", "settler version via staticcall");
    }
}
