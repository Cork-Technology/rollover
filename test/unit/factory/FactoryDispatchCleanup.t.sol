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

/// @notice FactoryDispatchCleanupTest — pins FactoryDispatchCleanup behaviour for the Cork Rollover suite.
contract FactoryDispatchCleanupTest is Test {
    /// @notice Impl.
    CorkRolloverContract internal impl;
    /// @notice Erc7484.

    MockERC7484 internal erc7484;
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

    /// @notice Pins behaviour: reverts when constructor zero Implementation.
    function testRevert_constructor_zeroImplementation() public {
        TimelockController tl = _deployTrustConfigTimelockForNextFactory();
        vm.expectRevert(CorkRolloverContractFactory__ZeroAddress.selector);
        new CorkRolloverContractFactory(
            address(0),
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
    }

    /// @notice Pins behaviour: reverts when constructor eoa Implementation.
    function testRevert_constructor_eoaImplementation() public {
        address eoa = makeAddr("eoa-impl");
        TimelockController tl = _deployTrustConfigTimelockForNextFactory();
        vm.expectRevert(
            abi.encodeWithSelector(CorkRolloverContractFactory__AddressHasNoCode.selector, eoa)
        );
        new CorkRolloverContractFactory(
            eoa,
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
    }
}
