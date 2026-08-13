// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { DefaultAttestersSeedHandler } from "../handlers/DefaultAttestersSeedHandler.sol";

/// @notice INV-DEFAULT-ATTESTERS-FACTORY-SEEDED — fail-on-revert invariant suite: factory-seeded default attesters remain authoritative for new rolloverContracts.
/// @dev fail-on-revert mode (companion at test/invariant/continueOnRevert/DefaultAttestersSeed.t.sol).
/// @custom:invariant INV-DEFAULT-ATTESTERS-FACTORY-SEEDED
contract DefaultAttestersSeedFailOnRevertTest is BaseTest {
    /// @notice Seed handler.
    DefaultAttestersSeedHandler internal seedHandler;

    /// @inheritdoc BaseTest
    function setUp() public override {
        super.setUp();
        seedHandler = new DefaultAttestersSeedHandler(factory, erc7484);

        seedHandler.registerRolloverContract(rolloverContract, cptHolder);
        targetContract(address(seedHandler));
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = seedHandler.deployRolloverContract.selector;
        selectors[1] = seedHandler.observeSeedConsistency.selector;
        selectors[2] = seedHandler.queueTrust.selector;
        selectors[3] = seedHandler.applyTrust.selector;
        selectors[4] = seedHandler.warpForward.selector;
        targetSelector(FuzzSelector({ addr: address(seedHandler), selectors: selectors }));
    }

    /// @notice invariant: pre override rolloverContract mirrors factory seed.
    function invariant_preOverrideRolloverContractMirrorsFactorySeed() public view {
        assertFalse(
            seedHandler.preOverrideSeedDriftDetected(),
            "INV-DEFAULT-ATTESTERS-FACTORY-SEEDED: pre-override rolloverContract disagrees with factory seed"
        );
    }
}
