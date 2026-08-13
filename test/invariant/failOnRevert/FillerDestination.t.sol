// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { FillScaffold } from "../../base/FillScaffold.sol";
import { FillerDestinationHandler } from "../handlers/FillerDestinationHandler.sol";

/// @notice N-INV-FILLER-DESTINATION-NONZERO — fail-on-revert invariant suite:
///         `fillerDestination[orderDigest][filler](,subFiller)` is set exactly
///         once on rollover record write, never re-written, and never
///         `address(0)` after the write completes.
/// @dev Companion at test/invariant/continueOnRevert/FillerDestination.t.sol.
/// @custom:invariant N-INV-FILLER-DESTINATION-NONZERO
contract FillerDestinationFailOnRevertTest is FillScaffold {
    /// @notice Filler-destination handler under test.
    FillerDestinationHandler internal destHandler;

    /// @notice Sets up the active filler-destination invariant handler.
    function setUp() public override {
        super.setUp();
        _approveFiller(type(uint256).max, type(uint256).max);
        destHandler = new FillerDestinationHandler(
            FillerDestinationHandler.Wiring({
                exactSettler: settler,
                partialSettler: partialSettler,
                rolloverContract: rolloverContract,
                srcCst: srcCst,
                dstCst: dstCst,
                premiumToken: premiumToken,
                srcCpt: srcCpt,
                dstCpt: dstCpt,
                sourceSrcCpt: sourceSrcCptModule,
                consumeDstCpt: consumeDstCptModule,
                cptHolder: cptHolder,
                cptHolderPk: cptHolderPk
            })
        );
        destHandler.fillExact();
        destHandler.fillPartial();
        targetContract(address(destHandler));
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = destHandler.fillExact.selector;
        selectors[1] = destHandler.attemptExactSecondFill.selector;
        selectors[2] = destHandler.fillPartial.selector;
        selectors[3] = destHandler.attemptPartialSecondFillSameDestination.selector;
        selectors[4] = destHandler.attemptPartialDestinationOverwrite.selector;
        selectors[5] = destHandler.observeTuple.selector;
        targetSelector(FuzzSelector({ addr: address(destHandler), selectors: selectors }));
    }

    /// @notice invariant: once non-zero, destination is set-once and never
    ///         drops back to zero.
    function invariant_fillerDestination_setOnceNeverZero() public view {
        assertFalse(
            destHandler.setOnceViolated(),
            "N-INV-FILLER-DESTINATION-NONZERO: fillerDestination was rewritten or zeroed after first non-zero observation"
        );
    }

    /// @notice invariant: valid handler-authored fills should not unexpectedly revert.
    function invariant_fillerDestination_validFillsDoNotRevert() public view {
        assertFalse(
            destHandler.unexpectedRevert(),
            "N-INV-FILLER-DESTINATION-NONZERO: valid exact/partial fill unexpectedly reverted"
        );
    }

    /// @notice invariant: the handler must exercise at least one successful
    ///         public rollover, otherwise the set-once check is vacuous.
    function invariant_fillerDestination_handlerNonVacuous() public view {
        assertGt(
            destHandler.ghostSuccessfulFills(),
            0,
            "N-INV-FILLER-DESTINATION-NONZERO: no successful destination-writing fill observed"
        );
    }
}
