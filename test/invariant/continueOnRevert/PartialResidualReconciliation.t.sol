// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import {
    PartialResidualReconciliationHandler
} from "../handlers/PartialResidualReconciliationHandler.sol";

/// @notice N-INV-PARTIAL-RESIDUAL-RECONCILES-TO-TOTAL — continue-on-revert invariant suite: sum of partial fills and cPT-holder cancel equals the original orderSize.
/// @dev continue-on-revert mode (companion at test/invariant/failOnRevert/PartialResidualReconciliation.t.sol).
/// @custom:invariant N-INV-PARTIAL-RESIDUAL-RECONCILES-TO-TOTAL
contract PartialResidualReconciliationContinueOnRevertTest is BaseTest {
    /// @notice Reconciliation handler.
    PartialResidualReconciliationHandler internal reconciliationHandler;

    /// @inheritdoc BaseTest
    function setUp() public override {
        super.setUp();
        reconciliationHandler = new PartialResidualReconciliationHandler(partialSettler);
        targetContract(address(reconciliationHandler));
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = reconciliationHandler.registerDigestAndFiller.selector;
        selectors[1] = reconciliationHandler.observeReconciliation.selector;
        selectors[2] = reconciliationHandler.warpForward.selector;
        targetSelector(FuzzSelector({ addr: address(reconciliationHandler), selectors: selectors }));
    }

    /// @notice invariant: residual sum equals total.
    function invariant_residualSumEqualsTotal() public view {
        assertFalse(
            reconciliationHandler.reconciliationViolated(),
            "N-INV-PARTIAL-RESIDUAL-RECONCILES-TO-TOTAL: per-filler residual sum diverged from order escrow (loose)"
        );
    }
}
