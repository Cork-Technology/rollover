// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ExactSettler as Settler } from "src/ExactSettler.sol";
import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice SettlerPauseTest — pins SettlerPause behaviour for the Cork Rollover suite.
contract SettlerPauseTest is BaseTest {
    /// @notice AccessControl role allowed to pause the Settler.
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    /// @notice AccessControl role allowed to unpause the Settler.

    bytes32 internal constant UNPAUSER_ROLE = keccak256("UNPAUSER_ROLE");
    /// @notice Stranger.

    address internal stranger = address(0xDEAD);
    /// @notice Emitted on paused.
    /// @param account Account address.

    event Paused(address account);
    /// @notice Emitted on unpaused.
    /// @param account Account address.

    event Unpaused(address account);

    /// @notice Pins behaviour: pause Should Revert When Called By Non Pauser.
    function test_PauseShouldRevertWhenCalledByNonPauser() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, PAUSER_ROLE
            )
        );
        vm.prank(stranger);
        settler.pause();
    }

    /// @notice Pins behaviour: pause Should Revert When Already Paused.
    function test_PauseShouldRevertWhenAlreadyPaused() public {
        settler.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        settler.pause();
    }

    /// @notice Pins behaviour: pause Should Emit Paused Event.
    function test_PauseShouldEmitPausedEvent() public {
        vm.expectEmit(true, true, true, true, address(settler));
        emit Paused(address(this));
        settler.pause();
    }

    /// @notice Pins behaviour: unpause Should Revert When Called By Non Unpauser.
    function test_UnpauseShouldRevertWhenCalledByNonUnpauser() public {
        settler.pause();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, UNPAUSER_ROLE
            )
        );
        vm.prank(stranger);
        settler.unpause();
    }

    /// @notice Pins behaviour: unpause Should Revert When Not Paused.
    function test_UnpauseShouldRevertWhenNotPaused() public {
        vm.expectRevert(Pausable.ExpectedPause.selector);
        settler.unpause();
    }

    /// @notice Pins behaviour: unpause Should Emit Unpaused Event.
    function test_UnpauseShouldEmitUnpausedEvent() public {
        settler.pause();
        vm.expectEmit(true, true, true, true, address(settler));
        emit Unpaused(address(this));
        settler.unpause();
    }

    function _emptyGasless() internal pure returns (ERC7683Types.GaslessCrossChainOrder memory g) {
        g = ERC7683Types.GaslessCrossChainOrder({
            originSettler: address(0),
            user: address(0),
            nonce: 0,
            originChainId: 0,
            openDeadline: 0,
            fillDeadline: 0,
            orderDataType: bytes32(0),
            orderData: bytes("")
        });
    }

    function _emptyOnchain() internal pure returns (ERC7683Types.OnchainCrossChainOrder memory o) {
        o = ERC7683Types.OnchainCrossChainOrder({
            fillDeadline: 0, orderDataType: bytes32(0), orderData: bytes("")
        });
    }

    /// @notice Pins behaviour: open Reverts When Paused.
    function test_OpenRevertsWhenPaused() public {
        settler.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        settler.openFor(_emptyGasless(), bytes(""), "");
    }

    /// @notice Pins behaviour: on-chain open reverts when paused.
    function test_OnchainOpenRevertsWhenPaused() public {
        settler.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        settler.open(_emptyOnchain());
    }

    /// @notice Pins behaviour: open For Reverts When Paused.
    function test_OpenForRevertsWhenPaused() public {
        settler.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        settler.openFor(_emptyGasless(), bytes(""), bytes(""));
    }

    /// @notice Pins behaviour: fill Reverts When Paused.
    function test_FillRevertsWhenPaused() public {
        settler.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        settler.fill(bytes32(0), bytes(""), bytes(""));
    }

    /// @notice Pins behaviour: reclaim reverts when paused.
    function test_ReclaimRevertsWhenPaused() public {
        settler.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        settler.reclaim(bytes32(0), address(0), bytes32(0), bytes(""));
    }

    /// @notice Pins behaviour: markExpired reverts when paused.
    function test_MarkExpiredRevertsWhenPaused() public {
        settler.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        settler.markExpired(bytes32(0), bytes(""));
    }

    /// @notice Pins behaviour: cancel Reverts When Paused.
    function test_CancelRevertsWhenPaused() public {
        settler.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        settler.cancel(bytes32(0), bytes(""), bytes(""));
    }
}
