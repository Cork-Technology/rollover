// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { FactoryQueueChecksOwnerHandler } from "../handlers/FactoryQueueChecksOwnerHandler.sol";

/// @notice INV-FACTORY-QUEUE-CHECKS-OWNER — continue-on-revert invariant suite:
///         only factory-cPT holders can queue or cancel trust-config operations.
/// @dev Companion at test/invariant/failOnRevert/FactoryQueueChecksOwner.t.sol.
/// @custom:invariant INV-FACTORY-QUEUE-CHECKS-OWNER
contract FactoryQueueChecksOwnerContinueOnRevertTest is BaseTest {
    /// @notice Handler under test.
    FactoryQueueChecksOwnerHandler internal handler;

    /// @inheritdoc BaseTest
    function setUp() public override {
        super.setUp();
        handler = new FactoryQueueChecksOwnerHandler(factory, rolloverContract, cptHolder);
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.deployFactoryRolloverContract.selector;
        selectors[1] = handler.queueAsOwner.selector;
        selectors[2] = handler.queueAsNonOwner.selector;
        selectors[3] = handler.queueNonFactory.selector;
        selectors[4] = handler.cancelAsOwner.selector;
        selectors[5] = handler.cancelAsNonOwner.selector;
        selectors[6] = handler.cancelNonFactory.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    /// @notice Every successful queue/cancel observed by the handler was owner-authorized.
    /// @custom:invariant INV-FACTORY-QUEUE-CHECKS-OWNER
    function invariant_factoryQueueChecksOwner() public view {
        assertTrue(
            handler.allSuccessfulTrustConfigOpsAuthorized(),
            "INV-FACTORY-QUEUE-CHECKS-OWNER: unauthorized trust-config op succeeded"
        );
    }
}
