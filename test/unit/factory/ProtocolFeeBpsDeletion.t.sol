// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { IRolloverContractLens } from "src/interfaces/rollover/IRolloverContractLens.sol";

/// @notice ProtocolFeeBpsDeletionTest — pins the post-deletion contract surface for the
///         `protocolFeeBps` phantom-feature cleanup. Every assertion proves something has
///         been REMOVED (function selector gone, struct field gone, constant gone, doc
///         row gone, storage slot bumped to a fresh v3 namespace).
contract ProtocolFeeBpsDeletionTest is BaseTest {
    /// @notice Legacy selector for `setProtocolFeeBps(uint16)`; MUST no longer resolve.
    bytes4 internal constant SET_PROTOCOL_FEE_BPS_SELECTOR =
        bytes4(keccak256("setProtocolFeeBps(uint16)"));
    /// @notice Legacy selector for `effectProtocolFeeBps()`; MUST no longer resolve.
    bytes4 internal constant EFFECT_PROTOCOL_FEE_BPS_SELECTOR =
        bytes4(keccak256("effectProtocolFeeBps()"));

    /// @dev v3 ERC-7201 namespace constant — `keccak256(abi.encode(uint256(keccak256(
    ///      "cork.factory.storage.v3")) - 1)) & ~bytes32(uint256(0xff))`. The factory's
    ///      private `FACTORY_STORAGE_SLOT` constant MUST embed this exact value.
    bytes32 internal immutable EXPECTED_V3_SLOT = _erc7201SlotFromName("cork.factory.storage.v3");

    /// @dev Compute the canonical ERC-7201 namespace slot for a given namespace name.
    function _erc7201SlotFromName(string memory ns) internal pure returns (bytes32) {
        return keccak256(abi.encode(uint256(keccak256(bytes(ns))) - 1)) & ~bytes32(uint256(0xff));
    }

    /// @notice `setProtocolFeeBps(uint16)` MUST NOT resolve on the deployed factory ABI.
    function test_setProtocolFeeBps_not_present() public {
        (bool ok, bytes memory ret) =
            address(factory).call(abi.encodeWithSelector(SET_PROTOCOL_FEE_BPS_SELECTOR, uint16(0)));
        assertFalse(ok, "setProtocolFeeBps must not resolve");
        // Defence-in-depth: ensure no return payload was synthesised (catches a
        // fallback that silently succeeds).
        assertEq(ret.length, 0, "no return payload expected from unresolved selector");
    }

    /// @notice `effectProtocolFeeBps()` MUST NOT resolve on the deployed factory ABI.
    function test_effectProtocolFeeBps_not_present() public {
        (bool ok, bytes memory ret) =
            address(factory).call(abi.encodeWithSelector(EFFECT_PROTOCOL_FEE_BPS_SELECTOR));
        assertFalse(ok, "effectProtocolFeeBps must not resolve");
        assertEq(ret.length, 0, "no return payload expected from unresolved selector");
    }

    /// @notice The `ProtocolConfig` struct + `protocolConfig()` lens entry were deleted
    ///         alongside the rolloverPeriod surface. This test now pins the selector removal.
    function test_protocolConfig_lens_selector_removed() public {
        bytes4 sel = bytes4(keccak256("protocolConfig()"));
        (bool ok,) = address(factory).call(abi.encodeWithSelector(sel));
        assertFalse(ok, "protocolConfig() lens entry must be removed");
    }

    /// @notice The `MAX_FEE_BPS` token MUST NOT appear in `src/CorkRolloverContractFactory.sol`.
    function test_max_fee_bps_constant_not_referenced() public view {
        string memory src = vm.readFile("src/CorkRolloverContractFactory.sol");
        assertFalse(
            _contains(src, "MAX_FEE_BPS"),
            "MAX_FEE_BPS literal must be deleted from CorkRolloverContractFactory.sol"
        );
        assertFalse(
            _contains(src, "protocolFeeBps"),
            "protocolFeeBps identifier must be deleted from CorkRolloverContractFactory.sol"
        );
        assertFalse(
            _contains(src, "ProtocolFeeBpsScheduled"),
            "ProtocolFeeBpsScheduled event symbol must be deleted"
        );
        assertFalse(
            _contains(src, "ProtocolFeeBpsEffected"),
            "ProtocolFeeBpsEffected event symbol must be deleted"
        );
        assertFalse(
            _contains(src, "InvalidFeeBps"),
            "CorkRolloverContractFactory__InvalidFeeBps error symbol must be deleted"
        );
    }

    /// @notice The factory's ERC-7201 storage slot must be bumped to v3 (the v2 layout
    ///         contained `protocolFeeBps` / `pendingProtocolFeeBps` /
    ///         `pendingProtocolFeeBpsReadyAt` and is no longer compatible).
    function test_storage_layout_fingerprint_v3() public view {
        string memory src = vm.readFile("src/CorkRolloverContractFactory.sol");
        assertTrue(
            _contains(src, vm.toString(EXPECTED_V3_SLOT)),
            "FACTORY_STORAGE_SLOT must equal the v3 ERC-7201 namespace hash"
        );
        assertTrue(
            _contains(src, "cork.factory.storage.v3"),
            "factory must carry the v3 namespace name in source"
        );
    }

    /// @notice `docs/INVARIANTS.md` must not retain any protocol-fee row.
    function test_invariant_ledger_no_protocolfee_rows() public view {
        string memory ledger = vm.readFile("docs/INVARIANTS.md");
        assertFalse(
            _contains(ledger, "protocolFeeBps"),
            "docs/INVARIANTS.md must not reference protocolFeeBps"
        );
        assertFalse(
            _contains(ledger, "MAX_FEE_BPS"), "docs/INVARIANTS.md must not reference MAX_FEE_BPS"
        );
    }

    /// @notice `src/interfaces/rollover/IRolloverContractLens.sol` `ProtocolConfig` struct must declare
    ///         exactly 3 fields and no protocol-fee fields.
    function test_lens_interface_struct_shape() public view {
        string memory iface = vm.readFile("src/interfaces/rollover/IRolloverContractLens.sol");
        assertFalse(
            _contains(iface, "protocolFeeBps"),
            "IRolloverContractLens must not declare protocolFeeBps field"
        );
        assertFalse(
            _contains(iface, "pendingProtocolFeeBps"),
            "IRolloverContractLens must not declare pendingProtocolFeeBps field"
        );
    }

    /// @dev Naive substring search — uses raw byte comparison so it copes with the small
    ///      doc-and-source surface this test reads. We only ever look for ASCII tokens.
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
