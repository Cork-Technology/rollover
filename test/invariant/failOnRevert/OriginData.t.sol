// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { OriginDataInvariantBase } from "../OriginDataInvariantBase.sol";

/// @notice N-INV-LIFECYCLE-ORIGINDATA-DIGEST-BINDING — fail-on-revert suite:
///         canonical originData is immutable and re-hashes to its order digest.
/// @dev Companion at test/invariant/continueOnRevert/OriginData.t.sol.
/// @custom:invariant N-INV-LIFECYCLE-ORIGINDATA-DIGEST-BINDING
contract OriginDataFailOnRevertTest is OriginDataInvariantBase {
    /// @notice Sets up the originData invariant handler.
    function setUp() public override {
        super.setUp();
        _setUpOriginDataInvariant();
    }

    /// @notice Canonical originData is never cleared or rewritten after first observation.
    function invariant_originDataSetOnce() public view {
        assertFalse(
            originDataHandler.setOnceViolated(),
            "N-INV-LIFECYCLE-ORIGINDATA-DIGEST-BINDING: originData changed or cleared"
        );
    }

    /// @notice Canonical originData re-hashes to the order digest key.
    function invariant_originDataRehashesToDigest() public view {
        assertFalse(
            originDataHandler.digestMismatch(),
            "N-INV-LIFECYCLE-ORIGINDATA-DIGEST-BINDING: originData does not rehash to order digest"
        );
    }

    /// @notice Handler-authored valid admissions should not unexpectedly revert.
    function invariant_originDataAdmissionsDoNotRevert() public view {
        assertFalse(
            originDataHandler.unexpectedRevert(),
            "N-INV-LIFECYCLE-ORIGINDATA-DIGEST-BINDING: valid originData admission reverted"
        );
    }
}
