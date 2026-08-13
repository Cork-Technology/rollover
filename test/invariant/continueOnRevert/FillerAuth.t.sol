// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { FillerAuthHandler } from "../handlers/FillerAuthHandler.sol";
import { BaseSettler } from "src/BaseSettler.sol";

/// @notice INV-FILLER-AUTH — continue-on-revert invariant suite: no fill executes without a matching FillerAuth(orderDigest, destination, subFiller) signature.
/// @dev continue-on-revert mode (companion at test/invariant/failOnRevert/FillerAuth.t.sol).
/// @custom:invariant INV-FILLER-AUTH
contract FillerAuthContinueOnRevertTest is BaseTest {
    /// @notice Filler_auth_typehash_expected.
    bytes32 internal constant FILLER_AUTH_TYPEHASH_EXPECTED =
        keccak256("FillerAuth(bytes32 orderDigest,address destination,bytes32 subFiller)");

    /// @notice Exact-domain handler.
    FillerAuthHandler internal exactHandler;

    /// @notice Partial-domain handler.
    FillerAuthHandler internal partialHandler;

    /// @inheritdoc BaseTest
    function setUp() public override {
        super.setUp();
        bytes32 live = BaseSettler(address(settler)).fillerAuthTypehash();
        require(live == FILLER_AUTH_TYPEHASH_EXPECTED, "FillerAuth typehash drift");
        bytes32 partialLive = BaseSettler(address(partialSettler)).fillerAuthTypehash();
        require(partialLive == FILLER_AUTH_TYPEHASH_EXPECTED, "Partial FillerAuth typehash drift");

        exactHandler = new FillerAuthHandler(address(settler));
        partialHandler = new FillerAuthHandler(address(partialSettler));
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = exactHandler.probeDirect.selector;
        selectors[1] = exactHandler.probeDelegated.selector;
        targetSelector(FuzzSelector({ addr: address(exactHandler), selectors: selectors }));
        targetSelector(FuzzSelector({ addr: address(partialHandler), selectors: selectors }));
    }

    /// @notice invariant: no bad sig ever accepted.
    function invariant_noBadSigEverAccepted() public view {
        assertEq(exactHandler.ghostBadSigAccepted(), 0, "INV-FILLER-AUTH: exact bad sig");
        assertEq(exactHandler.ghostBadDestAccepted(), 0, "INV-FILLER-AUTH: exact bad dest");
        assertEq(partialHandler.ghostBadSigAccepted(), 0, "INV-FILLER-AUTH: partial bad sig");
        assertEq(partialHandler.ghostBadDestAccepted(), 0, "INV-FILLER-AUTH: partial bad dest");
    }
}
