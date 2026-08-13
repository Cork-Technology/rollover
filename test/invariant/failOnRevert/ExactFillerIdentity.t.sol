// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { FillScaffold } from "../../base/FillScaffold.sol";
import { ExactFillerIdentityHandler } from "../handlers/ExactFillerIdentityHandler.sol";

/// @notice INV-EXACT-FILLER-IDENTITY — fail-on-revert invariant suite:
///         exact settle requires the supplied filler argument to equal the
///         recorded rollover filler, while settlement routes to the recorded
///         destination keyed by that filler.
/// @dev Companion at test/invariant/continueOnRevert/ExactFillerIdentity.t.sol.
/// @custom:invariant INV-EXACT-FILLER-IDENTITY
contract ExactFillerIdentityFailOnRevertTest is FillScaffold {
    /// @notice Active exact filler identity handler.
    ExactFillerIdentityHandler internal identityHandler;

    /// @notice Sets up the active exact filler identity handler.
    function setUp() public override {
        super.setUp();
        identityHandler = new ExactFillerIdentityHandler(
            ExactFillerIdentityHandler.Wiring({
                exactSettler: settler,
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
        targetContract(address(identityHandler));
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = identityHandler.settleRecordedFillerDestination.selector;
        selectors[1] = identityHandler.settleHelperDestination.selector;
        selectors[2] = identityHandler.settleAlternateDestination.selector;
        selectors[3] = identityHandler.rejectFrontRunFillerArgument.selector;
        selectors[4] = identityHandler.rejectZeroFillerArgument.selector;
        targetSelector(FuzzSelector({ addr: address(identityHandler), selectors: selectors }));
    }

    /// @notice invariant: exact rollover records bind the actual filler and destination.
    function invariant_exactFillerIdentity_recordBindingStable() public view {
        assertFalse(
            identityHandler.recordBindingViolated(),
            "INV-EXACT-FILLER-IDENTITY: exact rollover accounting or destination binding drifted"
        );
    }

    /// @notice invariant: mismatched settle filler arguments never accept.
    function invariant_exactFillerIdentity_mismatchedFillerRejected() public view {
        assertFalse(
            identityHandler.mismatchedFillerAccepted(),
            "INV-EXACT-FILLER-IDENTITY: mismatched settle filler argument accepted"
        );
    }

    /// @notice invariant: mismatched settle filler arguments use the target guard.
    function invariant_exactFillerIdentity_mismatchedFillerUsesTargetGuard() public view {
        assertFalse(
            identityHandler.mismatchedFillerWrongSelector(),
            "INV-EXACT-FILLER-IDENTITY: mismatched settle filler wrong selector"
        );
    }

    /// @notice invariant: rejected front-run attempts do not mutate route or balances.
    function invariant_exactFillerIdentity_frontRunAttemptNoStateMutation() public view {
        assertFalse(
            identityHandler.frontRunMutatedState(),
            "INV-EXACT-FILLER-IDENTITY: rejected front-run settle mutated state"
        );
    }

    /// @notice invariant: successful exact settle pays the recorded destination.
    function invariant_exactFillerIdentity_successRoutesToRecordedDestination() public view {
        assertFalse(
            identityHandler.destinationRoutingViolated(),
            "INV-EXACT-FILLER-IDENTITY: successful settle missed recorded destination"
        );
    }
}
