// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { FactorySoleTrustWriterHandler } from "../handlers/FactorySoleTrustWriterHandler.sol";
import { ICorkRolloverContract } from "src/interfaces/rollover/ICorkRolloverContract.sol";

/// @notice INV-ROLLOVER_CONTRACT-TRUST-ONLY-VIA-FACTORY — continue-on-revert invariant suite:
///         direct rolloverContract.setTrustConfig calls from any address other than the factory MUST
///         revert; live trust state MUST be unchanged.
/// @dev Companion at test/invariant/failOnRevert/FactoryIsSoleRolloverContractTrustWriter.t.sol.
/// @custom:invariant INV-ROLLOVER_CONTRACT-TRUST-ONLY-VIA-FACTORY
contract FactoryIsSoleRolloverContractTrustWriterContinueOnRevertTest is BaseTest {
    /// @notice Handler that probes the trust-write surface.
    FactorySoleTrustWriterHandler internal handler;

    /// @inheritdoc BaseTest
    function setUp() public override {
        super.setUp();
        ICorkRolloverContract.RolloverContractTrustSnapshot memory snap =
            ICorkRolloverContract(rolloverContract).rolloverContractSnapshot();
        handler = new FactorySoleTrustWriterHandler(
            rolloverContract, snap.liveTrustThreshold, snap.liveTrustAttesters
        );
        targetContract(address(handler));
    }

    /// @notice Live trust state stays frozen across the handler campaign.
    function invariant_liveTrustStateUnchanged() public view {
        ICorkRolloverContract.RolloverContractTrustSnapshot memory snap =
            ICorkRolloverContract(rolloverContract).rolloverContractSnapshot();
        assertEq(
            snap.liveTrustThreshold,
            handler.expectedThreshold(),
            "INV-ROLLOVER_CONTRACT-TRUST-ONLY-VIA-FACTORY: threshold drifted (loose)"
        );
        address[] memory expected = handler.expectedAttestersList();
        assertEq(snap.liveTrustAttesters.length, expected.length, "attester count drift (loose)");
        for (uint256 i = 0; i < expected.length; ++i) {
            assertEq(snap.liveTrustAttesters[i], expected[i], "attester drift (loose)");
        }
    }
}
