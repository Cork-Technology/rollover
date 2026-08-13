// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {
    CorkRolloverContractFactory__AddressHasNoCode,
    CorkRolloverContractFactory__ZeroAddress
} from "src/errors/CorkRolloverContractFactoryErrors.sol";

import { MockERC7484 } from "../../mocks/MockERC7484.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { Test } from "forge-std/Test.sol";
import { CorkRolloverContract } from "src/CorkRolloverContract.sol";
import { CorkRolloverContractFactory } from "src/CorkRolloverContractFactory.sol";

/// @notice FactoryRegistryAddrZeroCheckTest — pins FactoryRegistryAddrZeroCheck behaviour for the Cork Rollover suite.
contract FactoryRegistryAddrZeroCheckTest is Test {
    /// @notice Impl.
    CorkRolloverContract impl;
    /// @notice Erc7484.

    MockERC7484 erc7484;
    /// @notice Test fixture setup.

    function setUp() public {
        impl = new CorkRolloverContract();
        erc7484 = new MockERC7484();
    }

    function _singletonDefaults() internal pure returns (address[] memory d) {
        d = new address[](1);
        d[0] = address(0xDEFA);
    }

    function _deployTrustConfigTimelockForNextFactory()
        internal
        returns (TimelockController controller)
    {
        uint64 nonce = vm.getNonce(address(this));
        address predictedFactory = vm.computeCreateAddress(address(this), nonce + 1);
        address[] memory proposers = new address[](1);
        proposers[0] = predictedFactory;
        address[] memory executors = new address[](1);
        executors[0] = predictedFactory;
        controller = new TimelockController(1 hours, proposers, executors, address(this));
    }

    /// @notice Pins behaviour: zero Erc7484 Reverts.
    function test_zeroErc7484Reverts() public {
        TimelockController tl = _deployTrustConfigTimelockForNextFactory();
        vm.expectRevert(CorkRolloverContractFactory__ZeroAddress.selector);
        new CorkRolloverContractFactory(
            address(impl),
            address(0),
            1,
            _singletonDefaults(),
            address(tl),
            address(this),
            address(this),
            address(this),
            address(this),
            address(this)
        );
    }

    /// @notice Pins behaviour: eoa Erc7484 Reverts.
    function test_eoaErc7484Reverts() public {
        address eoa = makeAddr("eoa");
        TimelockController tl = _deployTrustConfigTimelockForNextFactory();
        vm.expectRevert(
            abi.encodeWithSelector(CorkRolloverContractFactory__AddressHasNoCode.selector, eoa)
        );
        new CorkRolloverContractFactory(
            address(impl),
            eoa,
            1,
            _singletonDefaults(),
            address(tl),
            address(this),
            address(this),
            address(this),
            address(this),
            address(this)
        );
    }

    /// @notice Pins behaviour: valid Registries Succeed.
    function test_validRegistriesSucceed() public {
        TimelockController tl = _deployTrustConfigTimelockForNextFactory();
        CorkRolloverContractFactory f = new CorkRolloverContractFactory(
            address(impl),
            address(erc7484),
            1,
            _singletonDefaults(),
            address(tl),
            address(this),
            address(this),
            address(this),
            address(this),
            address(this)
        );
        assertEq(f.ERC7484_REGISTRY(), address(erc7484));
        assertEq(f.DEFAULT_TRUST_THRESHOLD(), 1);
    }
}
