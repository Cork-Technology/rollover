// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { FillScaffold } from "../../base/FillScaffold.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice InvCptContainedBidirectionalTest — pins the bidirectional `!=` end-of-leg guard
///         on srcCPT and dstCPT (INV-CPT-CONTAINED). Catches both post-hook residual ABOVE
///         entry snapshot AND silent sweep of pre-existing CPT BELOW entry snapshot.
/// @custom:invariant INV-CPT-CONTAINED
contract InvCptContainedBidirectionalTest is FillScaffold {
    /// @notice Default fill amount (src side) used by helper scenarios.
    uint256 internal constant FILL = 1_000e18;
    /// @notice Default dst amount produced for fill scenarios.
    uint256 internal constant DST = 1_000e18;
    /// @notice Default premium amount used by fill scenarios.
    uint256 internal constant PREMIUM = 10e18;
    /// @notice Amount of CPT pre-minted to the rolloverContract before the rollover, emulating
    ///         cPT holder pre-staging or a previous leg's residual CPT held by the rolloverContract.
    uint256 internal constant PRE_EXISTING_CPT = 500e18;

    /// @notice Selector for `CorkRolloverContract__DstCptNotRestored(uint256,uint256)` — bidirectional
    ///         INV-CPT-CONTAINED guard on the dst side.
    bytes4 internal constant DST_CPT_NOT_RESTORED_SELECTOR =
        bytes4(keccak256("CorkRolloverContract__DstCptNotRestored(uint256,uint256)"));
    /// @notice Selector for `CorkRolloverContract__SrcCptNotRestored(uint256,uint256)` — bidirectional
    ///         INV-CPT-CONTAINED guard on the src side.
    bytes4 internal constant SRC_CPT_NOT_RESTORED_SELECTOR =
        bytes4(keccak256("CorkRolloverContract__SrcCptNotRestored(uint256,uint256)"));
    /// @notice Selector for the legacy directional `CorkRolloverContract__DstCptNotConsumed(uint256)`
    ///         error — retained so structural assertions can prove the old selector is gone.
    bytes4 internal constant LEGACY_DST_CPT_NOT_CONSUMED_SELECTOR =
        bytes4(keccak256("CorkRolloverContract__DstCptNotConsumed(uint256)"));

    function _opened()
        internal
        returns (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        )
    {
        orderData = _baseOrder();
        orderData.allowPartialFills = false;
        orderData.orderSize = FILL;
        intent = _buildIntent(bytes32(0), FILL, DST);
        orderData.rolloverIntentHash = _zeroDigestHash(intent);
        orderDigest = _openOrder(orderData);
        intent.orderDigest = orderDigest;
        cptHolderSig = _signOrder(cptHolderPk, orderData);
        _approveFiller(FILL, PREMIUM);
    }

    /// @notice Baseline regression — empty pre-existing CPT, legacy full-balance burn test hook:
    ///         the leg succeeds with `srcCptAfter == srcCptBefore == 0` and
    ///         `dstCptAfter == dstCptBefore == 0` post-consume.
    function test_baseline_no_preexisting_cpt_rollover_succeeds() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _opened();
        _doRolloverAs(orderDigest, orderData, intent, FILL, filler);
        // dstCPT and srcCPT must both be zero at the rolloverContract after a clean leg.
        assertEq(srcCpt.balanceOf(rolloverContract), 0, "srcCPT must return to entry snapshot (0)");
        assertEq(dstCpt.balanceOf(rolloverContract), 0, "dstCPT must return to entry snapshot (0)");
    }

    /// @notice Pre-existing dstCPT in the rolloverContract is silently drained by a legacy
    ///         full-balance burn test hook (which sweeps `balanceOf(this)`). The
    ///         bidirectional INV-CPT-CONTAINED guard must catch the drain: the rolloverContract
    ///         reverts with `CorkRolloverContract__DstCptNotRestored(expected, actual)` because
    ///         `dstCptAfter != dstCptBefore` (post-leg below entry snapshot).
    function testRevert_preexisting_dstCpt_swept_via_post_hook_reverts() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _opened();

        // Pre-mint dstCPT directly to the rolloverContract — emulates cPT holder pre-staging or a previous
        // leg's residual. The `consumeDstCptModule` post-hook will sweep ALL dstCPT
        // including this pre-existing balance.
        dstCpt.mint(rolloverContract, PRE_EXISTING_CPT);
        assertEq(dstCpt.balanceOf(rolloverContract), PRE_EXISTING_CPT, "pre-mint setup");

        vm.expectPartialRevert(DST_CPT_NOT_RESTORED_SELECTOR);
        _doRolloverAs(orderDigest, orderData, intent, FILL, filler);
    }

    /// @notice The bidirectional guard also catches the OPPOSITE direction — residual
    ///         dstCPT left ABOVE entry snapshot. Drop the consumeDstCptModule post-hook
    ///         so freshly-minted dstCPT
    ///         is not swept; the leg must revert `__DstCptNotRestored` (formerly
    ///         `__DstCptNotConsumed`).
    function testRevert_postLeg_dstCpt_residual_above_snapshot_still_reverts() public {
        // Build an intent WITHOUT the consume-dstCPT post-hook; everything else identical.
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.allowPartialFills = false;
        orderData.orderSize = FILL;

        RolloverTypes.Call[] memory preHooks = new RolloverTypes.Call[](1);
        preHooks[0] = _hook(
            address(sourceSrcCptModule),
            abi.encodeWithSignature("execute(address,uint256)", address(srcCpt), FILL)
        );
        RolloverTypes.RolloverIntent memory intent = _intentWithHooks(
            rolloverContract,
            bytes32(0),
            preHooks,
            new RolloverTypes.Call[](0),
            new RolloverTypes.Call[](0)
        );
        orderData.rolloverIntentHash = _zeroDigestHash(intent);
        bytes32 orderDigest = _openOrder(orderData);
        intent.orderDigest = orderDigest;
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);
        _approveFiller(FILL, PREMIUM);

        vm.expectPartialRevert(DST_CPT_NOT_RESTORED_SELECTOR);
        _doRolloverAs(orderDigest, orderData, intent, FILL, filler);
    }

    /// @notice The top-of-file INV-CPT-CONTAINED NatSpec must spell out bidirectional +
    ///         both-token semantics.
    function test_natspec_inv_cpt_contained_bidirectional() public view {
        string memory src = vm.readFile("src/CorkRolloverContract.sol");
        assertTrue(_contains(src, "INV-CPT-CONTAINED"), "INV-CPT-CONTAINED tag must remain");
        assertTrue(
            _contains(src, "srcCptAfter"),
            "INV-CPT-CONTAINED NatSpec must reference srcCptAfter direction"
        );
        assertTrue(
            _contains(src, "dstCptAfter"),
            "INV-CPT-CONTAINED NatSpec must reference dstCptAfter direction"
        );
        assertTrue(
            _contains(src, "SrcCptNotRestored"),
            "INV-CPT-CONTAINED NatSpec must reference the new SrcCptNotRestored error"
        );
        assertTrue(
            _contains(src, "DstCptNotRestored"),
            "INV-CPT-CONTAINED NatSpec must reference the new DstCptNotRestored error"
        );
    }

    /// @notice `docs/INVARIANTS.md` INV-CPT-CONTAINED row must document the bidirectional
    ///         semantics and both new error names.
    function test_invariants_ledger_documents_bidirectional() public view {
        string memory ledger = vm.readFile("docs/INVARIANTS.md");
        assertTrue(
            _contains(ledger, "SrcCptNotRestored"), "ledger must reference SrcCptNotRestored"
        );
        assertTrue(
            _contains(ledger, "DstCptNotRestored"), "ledger must reference DstCptNotRestored"
        );
        assertTrue(
            _contains(ledger, "bidirectional") || _contains(ledger, "Bidirectional"),
            "ledger must spell out bidirectional semantics"
        );
    }

    /// @notice The legacy `CorkRolloverContract__DstCptNotConsumed(uint256)` error symbol must be
    ///         removed from `src/CorkRolloverContract.sol`.
    function test_error_signatures_renamed() public view {
        string memory src = vm.readFile("src/CorkRolloverContract.sol");
        assertFalse(
            _contains(src, "DstCptNotConsumed"),
            "legacy CorkRolloverContract__DstCptNotConsumed must be removed"
        );
        assertTrue(
            _contains(src, "DstCptNotRestored"),
            "renamed CorkRolloverContract__DstCptNotRestored must be present"
        );
        assertTrue(
            _contains(src, "SrcCptNotRestored"),
            "new CorkRolloverContract__SrcCptNotRestored must be present"
        );
    }

    /// @dev Naive substring search — used only against doc-and-source bytes.
    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0 || n.length > h.length) {
            return false;
        }
        for (uint256 i = 0; i <= h.length - n.length; ++i) {
            bool match_ = true;
            for (uint256 j = 0; j < n.length; ++j) {
                if (h[i + j] != n[j]) {
                    match_ = false;
                    break;
                }
            }
            if (match_) {
                return true;
            }
        }
        return false;
    }
}
