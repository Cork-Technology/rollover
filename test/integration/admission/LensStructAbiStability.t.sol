// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { SourceShapeAssertions } from "../../base/SourceShapeAssertions.sol";
import { ICorkRolloverContract } from "src/interfaces/rollover/ICorkRolloverContract.sol";
import { IRolloverContractLens } from "src/interfaces/rollover/IRolloverContractLens.sol";

/// @notice LensStructAbiStabilityTest - pins the ABI component order (field order, names, and
///         types) of the lens output structs that form the SDK / indexer decoding contract:
///         `IRolloverContractLens.RolloverContractConfig`,
///         `ICorkRolloverContract.RolloverContractTrustSnapshot`, and
///         `ICorkRolloverContract.RolloverContractOrderState`.
///
/// @dev    Mirrors `test/integration/admission/OrderDataWireStability.t.sol`: structural reads via
///         `vm.readFile` + shared source-shape assertions. Behaviour tests in
///         `test/unit/rollover-contract/RolloverContractLens.t.sol` access every struct field by
///         name, which is order-independent: swapping two same-typed fields (e.g. `owner` <-> `factory`,
///         both `address`) or appending a field recompiles cleanly and leaves those assertions green
///         while the emitted ABI `components` array silently changes, breaking off-chain positional
///         decoders. This file is the CI gate that fails on any such reorder / rename / retype /
///         extension. The constant references below also force a compile-time dependency on the
///         current struct shapes.
contract LensStructAbiStabilityTest is SourceShapeAssertions {
    // ─────────────────────────────────────────────────────────────────────────
    // Compile-time anchors - reference each struct so this file fails to compile
    // if a struct is renamed or removed outright.
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Compile-time pin of `RolloverContractConfig` field count (5).
    function _refConfig()
        internal
        pure
        returns (IRolloverContractLens.RolloverContractConfig memory)
    {
        address[] memory attesters = new address[](0);
        return IRolloverContractLens.RolloverContractConfig({
            owner: address(0),
            factory: address(0),
            erc7484Registry: address(0),
            liveTrustThreshold: 0,
            liveTrustAttesters: attesters
        });
    }

    /// @notice Compile-time pin of `RolloverContractTrustSnapshot` field count (3).
    function _refSnapshot()
        internal
        pure
        returns (ICorkRolloverContract.RolloverContractTrustSnapshot memory)
    {
        address[] memory attesters = new address[](0);
        return ICorkRolloverContract.RolloverContractTrustSnapshot({
            erc7484Registry: address(0), liveTrustThreshold: 0, liveTrustAttesters: attesters
        });
    }

    /// @notice Compile-time pin of `RolloverContractOrderState` field count (2).
    function _refOrderState()
        internal
        pure
        returns (ICorkRolloverContract.RolloverContractOrderState memory)
    {
        return ICorkRolloverContract.RolloverContractOrderState({
            rolled: 0, rolloverTerminal: false
        });
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Source-shape pins - verbatim contiguous struct bodies
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice `RolloverContractConfig` component order MUST stay
    ///         (owner, factory, erc7484Registry, liveTrustThreshold, liveTrustAttesters).
    function test_lens_rolloverContractConfig_field_order_pinned() public view {
        string memory src = vm.readFile("src/interfaces/rollover/IRolloverContractLens.sol");
        assertSourceContains(
            src,
            "struct RolloverContractConfig {\n        address owner;\n        address factory;\n        address erc7484Registry;\n        uint8 liveTrustThreshold;\n        address[] liveTrustAttesters;\n    }",
            "RolloverContractConfig ABI component order frozen - reorder/extension breaks SDK decoders"
        );
    }

    /// @notice `RolloverContractTrustSnapshot` component order MUST stay
    ///         (erc7484Registry, liveTrustThreshold, liveTrustAttesters).
    function test_lens_rolloverContractTrustSnapshot_field_order_pinned() public view {
        string memory src = vm.readFile("src/interfaces/rollover/ICorkRolloverContract.sol");
        assertSourceContains(
            src,
            "struct RolloverContractTrustSnapshot {\n        address erc7484Registry;\n        uint8 liveTrustThreshold;\n        address[] liveTrustAttesters;\n    }",
            "RolloverContractTrustSnapshot ABI component order frozen - reorder/extension breaks SDK decoders"
        );
    }

    /// @notice `RolloverContractOrderState` component order MUST stay (rolled, rolloverTerminal).
    function test_lens_rolloverContractOrderState_field_order_pinned() public view {
        string memory src = vm.readFile("src/interfaces/rollover/ICorkRolloverContract.sol");
        assertSourceContains(
            src,
            "struct RolloverContractOrderState {\n        uint256 rolled;\n        bool rolloverTerminal;\n    }",
            "RolloverContractOrderState ABI component order frozen - reorder/extension breaks SDK decoders"
        );
    }

    /// @notice Refute known same-typed reorder variants that would silently recompile but flip the
    ///         emitted ABI `components` array.
    function test_lens_structs_reject_known_reorder_variants() public view {
        string memory lens = vm.readFile("src/interfaces/rollover/IRolloverContractLens.sol");
        string memory rc = vm.readFile("src/interfaces/rollover/ICorkRolloverContract.sol");
        // owner <-> factory swap (both address) inside RolloverContractConfig.
        assertSourceNotContains(
            lens,
            "struct RolloverContractConfig {\n        address factory;\n        address owner;",
            "RolloverContractConfig MUST NOT swap owner/factory"
        );
        // rolled <-> rolloverTerminal would change types, but pin the inverse order textually too.
        assertSourceNotContains(
            rc,
            "struct RolloverContractOrderState {\n        bool rolloverTerminal;\n        uint256 rolled;",
            "RolloverContractOrderState MUST NOT reorder rolled/rolloverTerminal"
        );
        // erc7484Registry MUST remain the first TrustSnapshot field (anchors the CWIA-baked registry).
        assertSourceNotContains(
            rc,
            "struct RolloverContractTrustSnapshot {\n        uint8 liveTrustThreshold;",
            "RolloverContractTrustSnapshot MUST keep erc7484Registry first"
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Docs discipline - the ABI pin must be recorded, not left as "reader-discipline-only"
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice The three docs surfaces point at this CI pin rather than the old "not CI-pinned" wording.
    function test_docs_record_lens_abi_pin() public view {
        string memory interfaces = vm.readFile("docs/spec/md/units/interfaces.md");
        assertSourceContains(
            interfaces,
            "LensStructAbiStability.t.sol",
            "interfaces.md must point at the lens ABI pin"
        );
        // The lens ABI must no longer be framed as reader-discipline-only. The bare phrase still
        // legitimately applies to the unrelated `IPoolShare.expiry()` item, so refute the lens
        // grouping header specifically rather than the standalone phrase.
        assertSourceNotContains(
            interfaces,
            "Two interface-stability invariants are reader-discipline-only",
            "interfaces.md must drop the reader-discipline-only framing for the lens ABI"
        );

        string memory threatModel = vm.readFile("docs/agent-context/spec/threat-model.md");
        assertSourceContains(
            threatModel,
            "LensStructAbiStability.t.sol",
            "threat-model.md must point at the lens ABI pin"
        );
        assertSourceNotContains(
            threatModel,
            "Lens ABI not CI-pinned",
            "threat-model.md must drop the not-CI-pinned residual wording"
        );

        string memory designNotes = vm.readFile("docs/agent-context/spec/design-notes.md");
        assertSourceContains(
            designNotes,
            "LensStructAbiStability.t.sol",
            "design-notes.md section 10 must point at the lens ABI pin"
        );
        assertSourceNotContains(
            designNotes,
            "Lens ABI not CI-pinned",
            "design-notes.md section 10 must drop the not-CI-pinned heading wording"
        );
    }
}
