// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { MockERC7484 } from "../../mocks/MockERC7484.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { CorkRolloverContract } from "src/CorkRolloverContract.sol";
import { CorkRolloverContractFactory } from "src/CorkRolloverContractFactory.sol";
import { ICorkRolloverContract } from "src/interfaces/rollover/ICorkRolloverContract.sol";

/// @notice VersionViewsTest (rolloverContract) — pins identity-view behaviour for `CorkRolloverContract`.
/// @dev Snapshot pins: any drift in `version()` or `factory()` semantics must trip these tests.
contract RolloverContractVersionViewsTest is BaseTest {
    /// @notice Pins behaviour: rolloverContract `version()` returns the exact semver literal "1.0.0".
    function test_version_returnsExpectedSemver() public view {
        string memory v = ICorkRolloverContract(rolloverContract).version();
        assertEq(v, "1.0.0", "rolloverContract version literal");
    }

    /// @notice Pins behaviour: rolloverContract `version()` is `pure` — invokable via staticcall from a
    ///         non-payable context without state access (sanity guard against accidental `view`).
    function test_version_isPure() public view {
        (bool ok, bytes memory ret) =
            address(rolloverContract).staticcall(abi.encodeWithSignature("version()"));
        assertTrue(ok, "rolloverContract version staticcall");
        string memory decoded = abi.decode(ret, (string));
        assertEq(decoded, "1.0.0", "rolloverContract version via staticcall");
    }

    /// @notice Pins behaviour: rolloverContract `factory()` returns the deployer factory address.
    function test_rolloverContract_factory_returnsDeployerAddress() public view {
        address f = ICorkRolloverContract(rolloverContract).factory();
        assertEq(f, address(factory), "factory() == deployer factory");
    }

    /// @notice Pins behaviour: rolloverContract `factory()` matches the CWIA trailer factory bytes
    ///         (defence-in-depth — confirms the view reads the trailer, not a storage slot).
    function test_rolloverContract_factory_matchesCwiaTrailer() public view {
        bytes memory args = Clones.fetchCloneArgs(rolloverContract);
        // Trailer layout: 0..20 owner | 20..40 factory | 40..60 registry.
        require(args.length == 60, "unexpected CWIA arg length");
        address trailerFactory;
        assembly {
            trailerFactory := shr(0x60, mload(add(args, 0x34)))
        }
        assertEq(trailerFactory, address(factory), "trailer factory matches");
        assertEq(
            ICorkRolloverContract(rolloverContract).factory(),
            trailerFactory,
            "factory() view matches trailer"
        );
    }

    /// @notice Pins behaviour: every clone produced by the same factory reports the same
    ///         factory address (no per-clone storage divergence).
    function test_rolloverContract_factory_pureAcrossClones() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        vm.prank(alice);
        address rolloverContractA = factory.deployRolloverContract();
        vm.prank(bob);
        address rolloverContractB = factory.deployRolloverContract();
        assertEq(
            ICorkRolloverContract(rolloverContractA).factory(), address(factory), "clone A factory"
        );
        assertEq(
            ICorkRolloverContract(rolloverContractB).factory(), address(factory), "clone B factory"
        );
        assertEq(
            ICorkRolloverContract(rolloverContractA).factory(),
            ICorkRolloverContract(rolloverContractB).factory(),
            "clones agree on factory"
        );
    }

    /// @notice Pins behaviour: a fresh factory instance produces clones whose `factory()`
    ///         points at the new factory, not the BaseTest factory.
    function test_rolloverContract_factory_distinctAcrossFactories() public {
        CorkRolloverContract impl = new CorkRolloverContract();
        MockERC7484 registry = new MockERC7484();
        address[] memory defaults = new address[](1);
        defaults[0] = address(0xBEEF);
        TimelockController tl = _deployTrustConfigTimelockForNextFactory();
        CorkRolloverContractFactory other = new CorkRolloverContractFactory(
            address(impl),
            address(registry),
            1,
            defaults,
            address(tl),
            address(this),
            address(this),
            address(this),
            address(this),
            address(this)
        );
        vm.prank(makeAddr("solo"));
        address soloRolloverContract = other.deployRolloverContract();
        assertEq(
            ICorkRolloverContract(soloRolloverContract).factory(),
            address(other),
            "alternate factory recorded"
        );
        assertTrue(
            ICorkRolloverContract(soloRolloverContract).factory() != address(factory),
            "not the BaseTest factory"
        );
    }
}
