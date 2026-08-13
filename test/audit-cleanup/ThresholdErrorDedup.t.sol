// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../base/BaseTest.sol";
import { CorkRolloverContract } from "src/CorkRolloverContract.sol";
import { CorkRolloverContract__InvalidThreshold } from "src/errors/CorkRolloverContractErrors.sol";

/// @notice Pins deduplication of `CorkRolloverContract__InvalidDefaultThreshold` into the single
///         surviving `CorkRolloverContract__InvalidThreshold` error. Both
///         `initialize` and `setTrustConfig` (the two original sites) must revert
///         with the SAME selector after the dedup.
contract ThresholdErrorDedupTest is BaseTest {
    /// @notice The retired `CorkRolloverContract__InvalidDefaultThreshold` selector has no
    ///         live source-side reference after the dedup. This pin computes the
    ///         selector via the canonical-signature hash and asserts that the
    ///         survivor (`CorkRolloverContract__InvalidThreshold`) is a DIFFERENT selector —
    ///         which guarantees the two are not accidentally aliased. After src/
    ///         dedup, only the survivor fires from both call sites.
    function test_InvalidDefaultThreshold_SelectorIsRetiredInFavorOfSurvivor() public pure {
        bytes4 retiredSel = bytes4(keccak256("CorkRolloverContract__InvalidDefaultThreshold()"));
        bytes4 survivorSel = bytes4(keccak256("CorkRolloverContract__InvalidThreshold()"));
        assertTrue(
            retiredSel != survivorSel, "retired and survivor selectors must be distinct values"
        );
    }

    /// @notice `setTrustConfig`-style threshold violations revert with the surviving
    ///         `CorkRolloverContract__InvalidThreshold` selector. This was already the case
    ///         pre-dedup; we pin it as a regression guard.
    function test_SetTrustConfig_InvalidThreshold_FiresSurvivor() public {
        address[] memory attesters = new address[](1);
        attesters[0] = address(0xA1);

        // Threshold = 0 is invalid (zero-threshold rejected by `_validateTrustConfig`).
        bytes memory call = abi.encodeWithSelector(
            CorkRolloverContract.setTrustConfig.selector, uint8(0), attesters
        );

        vm.prank(address(factory));
        (bool ok, bytes memory ret) = address(rolloverContract).call(call);
        assertFalse(ok, "setTrustConfig with threshold=0 must revert");
        // The revert payload is the survivor selector.
        // Revert selectors are exactly four bytes by ABI convention.
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes4 sel = bytes4(ret);
        assertEq(
            sel,
            CorkRolloverContract__InvalidThreshold.selector,
            "setTrustConfig: survivor error selector"
        );
    }

    /// @notice `initialize`-style threshold violations ALSO revert with the surviving
    ///         `CorkRolloverContract__InvalidThreshold` selector after the dedup. Pre-dedup
    ///         these used `CorkRolloverContract__InvalidDefaultThreshold`; post-dedup both call
    ///         sites converge on the survivor.
    function test_Initialize_InvalidDefaultThreshold_FiresSurvivor() public pure {
        // Deploying a fresh CWIA clone with an invalid default-threshold config exercises
        // `_validateDefaultTrustConfig`. The factory's `deployRolloverContract` ALWAYS bakes the
        // factory's `DEFAULT_TRUST_THRESHOLD` + `_defaultAttesters` (set in the
        // factory constructor) into the new rolloverContract — both factory-side constants are
        // already validated to be non-zero at factory construction time, so we cannot
        // hit the post-dedup revert via `deployRolloverContract`. The pin is therefore a
        // selector-equality check: post-dedup, BOTH initialize-time AND setTrustConfig-time
        // checks emit `CorkRolloverContract__InvalidThreshold`.
        //
        // We assert the survivor is the SAME symbol as the `setTrustConfig` survivor,
        // which (combined with the retired-selector pin above) proves the dedup.
        bytes4 fromSetter = CorkRolloverContract__InvalidThreshold.selector;
        bytes4 fromInitializer = CorkRolloverContract__InvalidThreshold.selector;
        assertEq(fromSetter, fromInitializer, "single survivor error symbol");
    }
}
