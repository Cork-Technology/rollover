// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {
    OpenedOrdersFillableUntilFillDeadlineInvariantBase
} from "../handlers/OpenedOrdersFillableUntilFillDeadlineHandler.sol";

/// @notice INV-OPENED-ORDERS-FILLABLE-UNTIL-FILLDEADLINE — fail-on-revert
///         invariant suite: opened orders remain fillable until fillDeadline
///         through direct and helper-style paths, then reject after fillDeadline.
/// @dev fail-on-revert mode (companion at test/invariant/continueOnRevert/OpenedOrdersFillableUntilFillDeadline.t.sol).
/// @custom:invariant INV-OPENED-ORDERS-FILLABLE-UNTIL-FILLDEADLINE
contract OpenedOrdersFillableUntilFillDeadlineFailOnRevertTest is
    OpenedOrdersFillableUntilFillDeadlineInvariantBase
{
    /// @notice Sets up the active opened-order fillability invariant handler.
    function setUp() public override {
        super.setUp();
        _setUpOpenedOrdersFillableUntilFillDeadlineInvariant();
    }

    /// @notice invariant: opened orders do not reject direct/helper fills before fillDeadline.
    function invariant_openedOrdersRemainFillableUntilFillDeadline_strict() public view {
        assertFalse(
            openedOrdersFillableHandler.fillableOpenedOrderRejected(),
            "INV-OPENED-ORDERS-FILLABLE-UNTIL-FILLDEADLINE: fillable opened order rejected"
        );
        assertEq(
            openedOrdersFillableHandler.ghostUnexpectedFillableRejects(),
            0,
            "INV-OPENED-ORDERS-FILLABLE-UNTIL-FILLDEADLINE: unexpected fillable reject"
        );
    }

    /// @notice invariant: opened orders do not accept direct/helper fills after fillDeadline.
    function invariant_openedOrdersRejectAfterFillDeadline_strict() public view {
        assertFalse(
            openedOrdersFillableHandler.expiredOpenedOrderAccepted(),
            "INV-OPENED-ORDERS-FILLABLE-UNTIL-FILLDEADLINE: expired opened order accepted"
        );
        assertEq(
            openedOrdersFillableHandler.ghostUnexpectedExpiredAccepts(),
            0,
            "INV-OPENED-ORDERS-FILLABLE-UNTIL-FILLDEADLINE: unexpected expired accept"
        );
    }

    /// @notice invariant: handler-authored valid opens and driver calls do not fail.
    function invariant_openedOrdersDriverHealthy_strict() public view {
        assertFalse(
            openedOrdersFillableHandler.validOpenRejected(),
            "INV-OPENED-ORDERS-FILLABLE-UNTIL-FILLDEADLINE: valid open rejected"
        );
        assertFalse(
            openedOrdersFillableHandler.driverReverted(),
            "INV-OPENED-ORDERS-FILLABLE-UNTIL-FILLDEADLINE: driver reverted"
        );
    }
}
