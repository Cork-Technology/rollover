// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {
    ExactResidualReconciliationInvariantBase
} from "../ExactResidualReconciliationInvariantBase.sol";

/// @notice N-INV-EXACT-RESIDUAL-RECONCILES-TO-FILL-RECORD — continue-on-revert suite:
///         exact residuals reconcile to rollover accountings and drain on settlement/reclaim.
/// @dev Companion at test/invariant/failOnRevert/ExactResidualReconciliation.t.sol.
/// @custom:invariant N-INV-EXACT-RESIDUAL-RECONCILES-TO-FILL-RECORD
contract ExactResidualReconciliationContinueOnRevertTest is
    ExactResidualReconciliationInvariantBase
{
    /// @notice Sets up the exact residual reconciliation invariant handler.
    function setUp() public override {
        super.setUp();
        _setUpExactResidualInvariant();
    }

    /// @notice Live dstCST held by ExactSettler equals the ghost sum of unpaid exact residuals.
    function invariant_exactResidualSumMatchesSettlerBalance() public view {
        assertFalse(
            exactResidualHandler.residualMismatch(),
            "N-INV-EXACT-RESIDUAL-RECONCILES-TO-FILL-RECORD: exact residual sum diverged (loose)"
        );
    }

    /// @notice Exact residual never exceeds its produced rollover accounting.
    function invariant_exactResidualBoundedByProduced() public view {
        assertFalse(
            exactResidualHandler.residualExceededProduced(),
            "N-INV-EXACT-RESIDUAL-RECONCILES-TO-FILL-RECORD: residual exceeded produced (loose)"
        );
    }

    /// @notice `dstCstProduced` is set once for each exact rollover accounting.
    function invariant_exactProducedSetOnce() public view {
        assertFalse(
            exactResidualHandler.producedSetOnceViolated(),
            "N-INV-EXACT-RESIDUAL-RECONCILES-TO-FILL-RECORD: dstCstProduced changed (loose)"
        );
    }

    /// @notice Handler-authored valid operations should not unexpectedly revert.
    function invariant_exactResidualOpsDoNotRevert() public view {
        assertFalse(
            exactResidualHandler.unexpectedRevert(),
            "N-INV-EXACT-RESIDUAL-RECONCILES-TO-FILL-RECORD: valid exact residual op reverted (loose)"
        );
    }
}
