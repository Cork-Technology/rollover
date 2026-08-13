// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { PremiumMonotonicHandler } from "../handlers/PremiumMonotonicHandler.sol";
import { ICorkRolloverContract } from "src/interfaces/rollover/ICorkRolloverContract.sol";

/// @notice INV-PREMIUM-FIRED-MONOTONIC — continue-on-revert invariant suite: rolloverContract-side
///         `premiumFiredFor` is set-only (never cleared once true). Under atomic-fill the
///         Settler-side `premiumFired` latch commits in the same frame.
/// @dev continue-on-revert mode (companion at test/invariant/failOnRevert/PremiumMonotonic.t.sol).
/// @custom:invariant INV-PREMIUM-FIRED-MONOTONIC
contract PremiumMonotonicContinueOnRevertTest is BaseTest {
    /// @notice Pm handler.
    PremiumMonotonicHandler internal pmHandler;

    /// @inheritdoc BaseTest
    function setUp() public override {
        super.setUp();
        pmHandler = new PremiumMonotonicHandler(ICorkRolloverContract(rolloverContract));
        targetContract(address(pmHandler));
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = pmHandler.observe.selector;
        selectors[1] = pmHandler.registerPair.selector;
        selectors[2] = pmHandler.warpForward.selector;
        targetSelector(FuzzSelector({ addr: address(pmHandler), selectors: selectors }));
    }

    /// @notice invariant: premium fired is set only.
    function invariant_premiumFiredIsSetOnly() public view {
        uint256 n = pmHandler.observedCount();
        for (uint256 i = 0; i < n; ++i) {
            (bytes32 digest, address f) = pmHandler.observedPairs(i);
            if (pmHandler.firedSnapshot(digest, f)) {
                assertTrue(
                    ICorkRolloverContract(rolloverContract)
                        .premiumFiredFor(digest, f, bytes32(uint256(uint160(f)))),
                    "INV-PREMIUM-FIRED-MONOTONIC: bit regressed (loose)"
                );
            }
        }
    }
}
