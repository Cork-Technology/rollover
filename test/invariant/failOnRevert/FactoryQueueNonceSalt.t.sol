// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { FactoryQueueNonceSaltHandler } from "../handlers/FactoryQueueNonceSaltHandler.sol";

/// @notice N-INV-FACTORY-QUEUE-NONCE-SALT-UNIQUE — fail-on-revert suite:
///         successful trust-config queues use strictly increasing per-rolloverContract salts.
/// @dev Companion at test/invariant/continueOnRevert/FactoryQueueNonceSalt.t.sol.
/// @custom:invariant N-INV-FACTORY-QUEUE-NONCE-SALT-UNIQUE
contract FactoryQueueNonceSaltFailOnRevertTest is BaseTest {
    /// @notice Handler under test.
    FactoryQueueNonceSaltHandler internal handler;

    /// @inheritdoc BaseTest
    function setUp() public override {
        super.setUp();
        handler = new FactoryQueueNonceSaltHandler(factory, rolloverContract, cptHolder);
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = handler.deployFactoryRolloverContract.selector;
        selectors[1] = handler.queueAsOwner.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    /// @notice Every queued op id matches the expected per-rolloverContract nonce salt.
    function invariant_factoryQueueNonceSaltMatchesExpected() public view {
        assertTrue(
            handler.allQueuedOpIdsMatchedExpectedNonce(),
            "N-INV-FACTORY-QUEUE-NONCE-SALT-UNIQUE: queued op id did not match nonce-derived salt"
        );
    }

    /// @notice Every successful queue produced a fresh operation id.
    function invariant_factoryQueueSaltNeverReused() public view {
        assertTrue(
            handler.allQueuedOpIdsUnique(),
            "N-INV-FACTORY-QUEUE-NONCE-SALT-UNIQUE: queued op id was reused"
        );
    }
}
