// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { CorkRolloverContract } from "src/CorkRolloverContract.sol";
import { IPoolManager, MarketId } from "src/interfaces/external/phoenix/IPoolManager.sol";

import { CorkRolloverContractHarness } from "../../harnesses/CorkRolloverContractHarness.sol";
import {
    CorkRolloverContract__PoolManagerCallFailed
} from "src/errors/CorkRolloverContractErrors.sol";

/// @notice PhoenixCstIdentityTest — pins PhoenixCstIdentity behaviour for the Cork Rollover suite.
contract PhoenixCstIdentityTest is Test {
    /// @notice Harness.
    CorkRolloverContractHarness internal harness;
    /// @notice Pool id.

    bytes32 internal constant POOL_ID = bytes32(uint256(0xC571));
    /// @notice Cpt.

    address internal constant CPT = address(0xC971);
    /// @notice Cst.

    address internal constant CST = 0xC571000000000000000000000000000000000000;
    /// @notice Shares selector.

    bytes4 internal constant SHARES_SELECTOR = IPoolManager.shares.selector;
    /// @notice Test fixture setup.

    function setUp() public {
        harness = new CorkRolloverContractHarness();
    }

    function _installPm(bytes memory returndata) internal returns (address pm) {
        pm = makeAddr("phoenix.pm");
        bytes memory call = abi.encodeWithSelector(SHARES_SELECTOR, POOL_ID);
        vm.mockCall(pm, call, returndata);
    }

    function _installPmRevert() internal returns (address pm) {
        pm = makeAddr("phoenix.pm.revert");
        bytes memory call = abi.encodeWithSelector(SHARES_SELECTOR, POOL_ID);
        vm.mockCallRevert(pm, call, bytes(""));
    }

    function _abiPair(address a, address b) internal pure returns (bytes memory) {
        return abi.encode(a, b);
    }

    /// @notice Pins behaviour: canonical Success returns Principal Token.
    function test_canonicalSuccess_returnsPrincipalToken() public {
        address pm = _installPm(_abiPair(CPT, CST));
        address resolved = harness.exposed_siblingCptToken(IPoolManager(pm), POOL_ID, CST);
        assertEq(resolved, CPT, "principal token must round-trip");
    }

    /// @notice Pins behaviour: short Returndata reverts.
    function test_shortReturndata_reverts() public {
        bytes memory short = abi.encodePacked(uint256(uint160(CPT)));
        assertEq(short.length, 32, "fixture: short returndata is 32 bytes");
        address pm = _installPm(short);

        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContract__PoolManagerCallFailed.selector, SHARES_SELECTOR, short
            )
        );
        harness.exposed_siblingCptToken(IPoolManager(pm), POOL_ID, CST);
    }

    /// @notice Pins behaviour: long Returndata reverts.
    function test_longReturndata_reverts() public {
        bytes memory long = abi.encode(CPT, CST, uint256(0xdeadbeef));
        assertEq(long.length, 96, "fixture: long returndata is 96 bytes");
        address pm = _installPm(long);

        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContract__PoolManagerCallFailed.selector, SHARES_SELECTOR, long
            )
        );
        harness.exposed_siblingCptToken(IPoolManager(pm), POOL_ID, CST);
    }

    /// @notice Pins behaviour: zero Principal reverts.
    function test_zeroPrincipal_reverts() public {
        bytes memory data = _abiPair(address(0), CST);
        address pm = _installPm(data);

        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContract__PoolManagerCallFailed.selector, SHARES_SELECTOR, data
            )
        );
        harness.exposed_siblingCptToken(IPoolManager(pm), POOL_ID, CST);
    }

    /// @notice Pins behaviour: zero Swap Token reverts.
    function test_zeroSwapToken_reverts() public {
        bytes memory data = _abiPair(CPT, address(0));
        address pm = _installPm(data);

        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContract__PoolManagerCallFailed.selector, SHARES_SELECTOR, data
            )
        );
        harness.exposed_siblingCptToken(IPoolManager(pm), POOL_ID, CST);
    }

    /// @notice Pins behaviour: swap Token Mismatch reverts.
    function test_swapTokenMismatch_reverts() public {
        address foreignCst = makeAddr("foreign.cst");
        bytes memory data = _abiPair(CPT, foreignCst);
        address pm = _installPm(data);

        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContract__PoolManagerCallFailed.selector, SHARES_SELECTOR, data
            )
        );
        harness.exposed_siblingCptToken(IPoolManager(pm), POOL_ID, CST);
    }

    /// @notice Pins behaviour: pm Reverts surfaces Named Error.
    function test_pmReverts_surfacesNamedError() public {
        address pm = _installPmRevert();

        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContract__PoolManagerCallFailed.selector, SHARES_SELECTOR, bytes("")
            )
        );
        harness.exposed_siblingCptToken(IPoolManager(pm), POOL_ID, CST);
    }
}
