// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { FactoryRolloverContractOfHandler } from "../handlers/FactoryRolloverContractOfHandler.sol";

/// @notice N-INV-ROLLOVER-CONTRACT-OF-IMMUTABLE-AFTER-SET — fail-on-revert invariant
///         suite: `CorkRolloverContractFactory.rolloverContractOf[user]` is set exactly once by
///         `deployRolloverContract`, never re-written, never cleared, and the
///         corollary `isDeployedRolloverContract[rolloverContract]` mirror stays true once
///         flipped.
/// @dev Companion at test/invariant/continueOnRevert/FactoryRolloverContractOf.t.sol.
/// @custom:invariant N-INV-ROLLOVER-CONTRACT-OF-IMMUTABLE-AFTER-SET
contract FactoryRolloverContractOfFailOnRevertTest is BaseTest {
    /// @notice Factory rolloverContractOf handler under test.
    FactoryRolloverContractOfHandler internal rolloverContractOfHandler;

    /// @inheritdoc BaseTest
    function setUp() public override {
        super.setUp();
        rolloverContractOfHandler = new FactoryRolloverContractOfHandler(factory);
        targetContract(address(rolloverContractOfHandler));
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = rolloverContractOfHandler.deployRolloverContractForNewActor.selector;
        selectors[1] = rolloverContractOfHandler.deployRolloverContractForBoundActor.selector;
        selectors[2] = rolloverContractOfHandler.observeActor.selector;
        selectors[3] = rolloverContractOfHandler.warpForward.selector;
        targetSelector(
            FuzzSelector({ addr: address(rolloverContractOfHandler), selectors: selectors })
        );
    }

    /// @notice invariant: once set, `rolloverContractOf[user]` never rotates or clears,
    ///         and the `isDeployedRolloverContract` mirror stays true.
    function invariant_rolloverContractOf_setOnceImmutable() public view {
        assertFalse(
            rolloverContractOfHandler.violated(),
            "N-INV-ROLLOVER-CONTRACT-OF-IMMUTABLE-AFTER-SET: rolloverContractOf was rewritten, cleared, or its isDeployedRolloverContract mirror dropped after first non-zero observation"
        );
    }
}
