// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { ParticipantCountHandler } from "../handlers/ParticipantCountHandler.sol";
import { IPartialSettler } from "src/interfaces/settlers/IPartialSettler.sol";

/// @notice INV-PARTICIPANT-COUNT-MONOTONIC — continue-on-revert invariant suite: Settler participantCount per order is monotone non-decreasing.
/// @dev continue-on-revert mode (companion at test/invariant/failOnRevert/ParticipantCount.t.sol).
/// @custom:invariant INV-PARTICIPANT-COUNT-MONOTONIC
contract ParticipantCountContinueOnRevertTest is BaseTest {
    /// @notice Pc handler.
    ParticipantCountHandler internal pcHandler;

    /// @inheritdoc BaseTest
    function setUp() public override {
        super.setUp();
        pcHandler = new ParticipantCountHandler(IPartialSettler(address(partialSettler)));
        targetContract(address(pcHandler));
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = pcHandler.observe.selector;
        selectors[1] = pcHandler.registerOrderId.selector;
        selectors[2] = pcHandler.observeOrderCount.selector;
        selectors[3] = pcHandler.warpForward.selector;
        targetSelector(FuzzSelector({ addr: address(pcHandler), selectors: selectors }));
    }

    /// @notice invariant: participant count non decreasing.
    function invariant_participantCountNonDecreasing() public view {
        uint256 n = pcHandler.observedCount();
        for (uint256 i = 0; i < n; ++i) {
            bytes32 id = pcHandler.observedOrders(i);
            uint32 live =
                IPartialSettler(address(partialSettler))
            .rolloverAccountingOf(id)
            .participantSlotCount;
            uint32 snap = pcHandler.lastCount(id);
            assertGe(
                uint256(live), uint256(snap), "INV-PARTICIPANT-COUNT-MONOTONIC: regressed (loose)"
            );
        }
    }
}
