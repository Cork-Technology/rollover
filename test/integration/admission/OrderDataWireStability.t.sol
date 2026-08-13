// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { SourceShapeAssertions } from "../../base/SourceShapeAssertions.sol";
import { ISettler } from "src/interfaces/settlers/ISettler.sol";
import { Typehashes } from "src/libraries/Typehashes.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice OrderDataWireStabilityTest - pins the OrderData / RolloverParams / FillerPayload wire
///         order, typehash literals, NatSpec field-group discipline, and the F-06 view-param /
///         storage-mapping-key rename (`orderId` → `orderDigest`) on internal-lifecycle surfaces.
contract OrderDataWireStabilityTest is SourceShapeAssertions {
    // ─────────────────────────────────────────────────────────────────────────
    // Wire-order regression pin: typehash literals byte-identical
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Pins `ORDER_DATA_TYPEHASH` literal preimage byte-for-byte.
    function test_orderDataTypehash_literal_unchanged() public pure {
        bytes32 expected = keccak256(
            "OrderData(address user,address settler,address fillerHint,address exclusiveFiller,address srcCstToken,address dstCstToken,address premiumToken,address rolloverContract,uint64 originChainId,uint64 destinationChainId,uint64 openDeadline,uint64 fillDeadline,uint64 orderSalt,uint256 orderSize,uint256 minPremiumPerShare,bool allowPartialFills,bool allowUnderfill,uint8 premiumPaymentMode,bytes32 rolloverIntentHash,RolloverParams rolloverParams)RolloverParams(address srcCstToken,address dstCstToken,uint256 minCaReceived,uint256 minSharesOut,bytes32 srcPoolId,bytes32 dstPoolId,address settler,bytes32 jitMarketHash)"
        );
        assertEq(
            Typehashes.ORDER_DATA_TYPEHASH,
            expected,
            "OrderData typehash literal drift - wire order MUST be frozen post-launch"
        );
    }

    /// @notice Pins `ROLLOVER_PARAMS_TYPEHASH` literal preimage byte-for-byte.
    function test_rolloverParamsTypehash_literal_unchanged() public pure {
        bytes32 expected = keccak256(
            "RolloverParams(address srcCstToken,address dstCstToken,uint256 minCaReceived,uint256 minSharesOut,bytes32 srcPoolId,bytes32 dstPoolId,address settler,bytes32 jitMarketHash)"
        );
        assertEq(
            Typehashes.ROLLOVER_PARAMS_TYPEHASH,
            expected,
            "RolloverParams typehash literal drift - wire order MUST be frozen post-launch"
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Struct-vs-tuple decode regression per [[feedback-abi-decode-struct-vs-tuple]]
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Encodes a populated `OrderData` struct and re-decodes; field-by-field equality
    ///         catches accidental struct reorder masquerading as a NatSpec PR. (Encoded as the
    ///         struct because a flat 19-arg `abi.encode` exceeds Solidity's stack depth without
    ///         `--via-ir`; the canonical EIP-712 ABI for `OrderData` is the struct shape.)
    function test_orderData_decode_struct_matches_flat_tuple() public pure {
        RolloverTypes.RolloverParams memory rp = RolloverTypes.RolloverParams({
            srcCstToken: address(0xA1),
            dstCstToken: address(0xA2),
            minCaReceived: 11,
            minSharesOut: 22,
            srcPoolId: bytes32(uint256(0xB1)),
            dstPoolId: bytes32(uint256(0xB2)),
            settler: address(0xA3),
            jitMarketHash: bytes32(uint256(0xB3))
        });

        RolloverTypes.OrderData memory src = RolloverTypes.OrderData({
            user: address(0x01),
            settler: address(0x02),
            fillerHint: address(0x03),
            exclusiveFiller: address(0x04),
            srcCstToken: address(0x05),
            dstCstToken: address(0x06),
            premiumToken: address(0x07),
            rolloverContract: address(0x08),
            originChainId: uint64(1),
            destinationChainId: uint64(2),
            openDeadline: uint64(3),
            fillDeadline: uint64(4),
            orderSalt: uint64(5),
            orderSize: uint256(100),
            minPremiumPerShare: uint256(200),
            allowPartialFills: true,
            allowUnderfill: false,
            premiumPaymentMode: RolloverTypes.PREMIUM_PAYMENT_MODE_ATOMIC_ONLY,
            rolloverIntentHash: bytes32(uint256(0xCAFE)),
            rolloverParams: rp
        });

        bytes memory flat = abi.encode(src);
        RolloverTypes.OrderData memory decoded = abi.decode(flat, (RolloverTypes.OrderData));

        assertEq(decoded.user, address(0x01), "user");
        assertEq(decoded.settler, address(0x02), "settler");
        assertEq(decoded.fillerHint, address(0x03), "fillerHint");
        assertEq(decoded.exclusiveFiller, address(0x04), "exclusiveFiller");
        assertEq(decoded.srcCstToken, address(0x05), "srcCstToken");
        assertEq(decoded.dstCstToken, address(0x06), "dstCstToken");
        assertEq(decoded.premiumToken, address(0x07), "premiumToken");
        assertEq(decoded.rolloverContract, address(0x08), "rolloverContract");
        assertEq(decoded.originChainId, uint64(1), "originChainId");
        assertEq(decoded.destinationChainId, uint64(2), "destinationChainId");
        assertEq(decoded.openDeadline, uint64(3), "openDeadline");
        assertEq(decoded.fillDeadline, uint64(4), "fillDeadline");
        assertEq(decoded.orderSalt, uint64(5), "orderSalt");
        assertEq(decoded.orderSize, uint256(100), "orderSize");
        assertEq(decoded.minPremiumPerShare, uint256(200), "minPremiumPerShare");
        assertTrue(decoded.allowPartialFills, "allowPartialFills");
        assertFalse(decoded.allowUnderfill, "allowUnderfill");
        assertEq(
            decoded.premiumPaymentMode,
            RolloverTypes.PREMIUM_PAYMENT_MODE_ATOMIC_ONLY,
            "premiumPaymentMode"
        );
        assertEq(decoded.rolloverIntentHash, bytes32(uint256(0xCAFE)), "rolloverIntentHash");
        assertEq(decoded.rolloverParams.srcCstToken, address(0xA1), "rp.srcCstToken");
        assertEq(decoded.rolloverParams.settler, address(0xA3), "rp.settler");
        assertEq(decoded.rolloverParams.jitMarketHash, bytes32(uint256(0xB3)), "rp.jitMarketHash");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // NatSpec discipline - structural reads via vm.readFile
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice OrderData NatSpec docblock documents the 7 field groups + reorder-hostility warning.
    function test_natspec_orderdata_documents_field_groups() public view {
        string memory src = vm.readFile("src/types/RolloverTypes.sol");
        assertSourceContains(
            src, "DO NOT REORDER POST-LAUNCH", "RolloverTypes.sol OrderData reorder warning"
        );
        assertSourceContains(
            src, "rolloverIntentHash", "RolloverTypes.sol OrderData intent-hash continuity warning"
        );
        assertSourceContains(
            src, "Settler EIP-712 domain", "RolloverTypes.sol OrderData domain warning"
        );
        assertSourceContains(
            src,
            "PREMIUM_PAYMENT_MODE_ATOMIC_ONLY",
            "RolloverTypes.sol premiumPaymentMode constants"
        );
        // Seven group labels (Parties / Tokens / Routing / Deadlines / Economic / Flags / Intent)
        assertSourceContains(src, "Parties", "OrderData group label: Parties");
        assertSourceContains(src, "Tokens", "OrderData group label: Tokens");
        assertSourceContains(src, "Routing", "OrderData group label: Routing");
        assertSourceContains(src, "Deadlines", "OrderData group label: Deadlines");
        assertSourceContains(src, "Economic", "OrderData group label: Economic");
        assertSourceContains(src, "Flags", "OrderData group label: Flags");
        assertSourceContains(src, "Intent bind", "OrderData group label: Intent bind");
    }

    /// @notice FillerPayload NatSpec docblock documents the 8 field groups + ABI-only warning.
    function test_natspec_fillerpayload_documents_field_groups() public view {
        string memory src = vm.readFile("src/types/FillerTypes.sol");
        // ABI-break-only clarification (not EIP-712-hashed).
        assertSourceContains(src, "NOT EIP-712-hashed", "FillerPayload ABI-only clarification");
        // Eight group labels (Phase / Amounts / Routing / Intent / Filler floor / Filler auth /
        // Sub-filler / cPT-holder auth)
        assertSourceContains(src, "Phase", "FillerPayload group label: Phase");
        assertSourceContains(src, "Amounts", "FillerPayload group label: Amounts");
        assertSourceContains(src, "Routing", "FillerPayload group label: Routing");
        assertSourceContains(src, "Intent", "FillerPayload group label: Intent");
        assertSourceContains(src, "Filler floor", "FillerPayload group label: Filler floor");
        assertSourceContains(src, "Filler auth", "FillerPayload group label: Filler auth");
        assertSourceContains(src, "Sub-filler", "FillerPayload group label: Sub-filler");
        assertSourceContains(src, "cPT-holder auth", "FillerPayload group label: cPT-holder auth");
    }

    /// @notice Typehashes NatSpec documents the reorder-hostility paragraph for both typehashes.
    function test_natspec_typehashes_documents_reorder_hostility() public view {
        string memory src = vm.readFile("src/libraries/Typehashes.sol");
        assertSourceContains(src, "DO NOT REORDER POST-LAUNCH", "Typehashes reorder warning");
        assertSourceContains(
            src, "Settler EIP-712 domain/version", "Typehashes domain-version reference"
        );
        assertSourceContains(src, "INV-WIRE-ORDER-STABILITY", "Typehashes references invariant");
    }

    /// @notice Inline section headers present inside the struct bodies (sentinel for forge fmt).
    function test_inline_section_headers_present_in_structs() public view {
        string memory rolloverContractTypes = vm.readFile("src/types/RolloverTypes.sol");
        assertSourceContains(
            rolloverContractTypes, "// --- Parties ---", "OrderData inline header: Parties"
        );
        assertSourceContains(
            rolloverContractTypes, "// --- Tokens ---", "OrderData inline header: Tokens"
        );
        assertSourceContains(
            rolloverContractTypes, "// --- Routing ---", "OrderData inline header: Routing"
        );
        assertSourceContains(
            rolloverContractTypes, "// --- Deadlines", "OrderData inline header: Deadlines"
        );
        assertSourceContains(
            rolloverContractTypes, "// --- Economic", "OrderData inline header: Economic"
        );
        assertSourceContains(
            rolloverContractTypes, "// --- Flags ---", "OrderData inline header: Flags"
        );
        assertSourceContains(
            rolloverContractTypes, "// --- Intent binding ---", "OrderData inline header: Intent"
        );

        string memory fillerTypes = vm.readFile("src/types/FillerTypes.sol");
        assertSourceContains(fillerTypes, "// --- Phase ---", "FillerPayload inline header: Phase");
        assertSourceContains(
            fillerTypes, "// --- Amounts ---", "FillerPayload inline header: Amounts"
        );
        assertSourceContains(
            fillerTypes, "// --- Routing ---", "FillerPayload inline header: Routing"
        );
        assertSourceContains(
            fillerTypes, "// --- Intent ---", "FillerPayload inline header: Intent"
        );
        assertSourceContains(
            fillerTypes, "// --- Filler floor ---", "FillerPayload inline header: Floor"
        );
        assertSourceContains(
            fillerTypes, "// --- Filler auth ---", "FillerPayload inline header: Auth"
        );
        assertSourceContains(
            fillerTypes, "// --- Sub-filler ---", "FillerPayload inline header: Sub-filler"
        );
        assertSourceContains(
            fillerTypes,
            "// --- cPT-holder auth ---",
            "FillerPayload inline header: cPT-holder auth"
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // View-param naming discipline (F-06 Layer-2 fold)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice BaseSettler `orderStatus` external view renames its parameter to `orderDigest`.
    function test_view_orderStatus_parameter_renamed_to_orderDigest() public view {
        string memory src = vm.readFile("src/BaseSettler.sol");
        assertSourceContains(
            src,
            "function orderStatus(bytes32 orderDigest)",
            "orderStatus view parameter MUST be named orderDigest"
        );
        assertSourceNotContains(
            src,
            "function orderStatus(bytes32 orderId)",
            "orderStatus view parameter MUST NOT be named orderId"
        );
    }

    /// @notice PartialSettler slot-accounting view names its first parameter `orderDigest`.
    function test_view_fillerSlotAccountingOf_parameter_named_orderDigest() public view {
        string memory exactSrc = vm.readFile("src/ExactSettler.sol");
        string memory partialSrc = vm.readFile("src/PartialSettler.sol");
        assertSourceContains(
            partialSrc,
            "function fillerSlotAccountingOf(bytes32 orderDigest, address filler, bytes32 subFiller)",
            "partial fillerSlotAccountingOf view parameter MUST be named orderDigest"
        );
        assertSourceNotContains(
            exactSrc,
            "function fillerDstProducedOf(",
            "exact fillerDstProducedOf view MUST NOT exist"
        );
        assertSourceNotContains(
            partialSrc,
            "function fillerDstProducedOf(",
            "partial fillerDstProducedOf view MUST NOT exist"
        );
        assertSourceNotContains(
            exactSrc,
            "function settlementDestinationOf(",
            "exact settlementDestinationOf view MUST NOT exist"
        );
        assertSourceNotContains(
            partialSrc,
            "function fillerRolloverAccountingOf(",
            "partial fillerRolloverAccountingOf view MUST NOT exist"
        );
        assertSourceNotContains(
            partialSrc,
            "function fillerSlotSettledOf(",
            "partial fillerSlotSettledOf view MUST NOT exist"
        );
        assertSourceNotContains(
            partialSrc,
            "function settlementDestinationOf(bytes32 orderDigest, address filler, bytes32 subFiller)",
            "partial settlementDestinationOf view MUST NOT exist"
        );
        assertSourceNotContains(
            partialSrc,
            "function fillerSlotAccountingOf(bytes32 orderId,",
            "partial fillerSlotAccountingOf view parameter MUST NOT be named orderId"
        );
    }

    /// @notice BaseSettler no longer exposes the redundant orderData cache view.
    function test_view_orderDataOf_removed() public view {
        string memory src = vm.readFile("src/BaseSettler.sol");
        assertSourceNotContains(
            src,
            "function orderDataOf(",
            "orderDataOf view MUST stay removed; Open.originData is the canonical observable payload"
        );
    }

    /// @notice ExactSettler / PartialSettler `orderStatus` storage mapping renames its key.
    function test_storage_orderStatus_mapping_key_renamed() public view {
        string memory exactSrc = vm.readFile("src/ExactSettler.sol");
        string memory partialSrc = vm.readFile("src/PartialSettler.sol");
        assertSourceContains(
            exactSrc,
            "mapping(bytes32 orderDigest => RolloverTypes.OrderStatus status) orderStatus",
            "ExactSettler.orderStatus mapping key MUST be orderDigest"
        );
        assertSourceContains(
            partialSrc,
            "mapping(bytes32 orderDigest => RolloverTypes.OrderStatus status) orderStatus",
            "PartialSettler.orderStatus mapping key MUST be orderDigest"
        );
        assertSourceNotContains(
            exactSrc,
            "mapping(bytes32 orderId => RolloverTypes.OrderStatus status) orderStatus",
            "ExactSettler.orderStatus mapping key MUST NOT be orderId"
        );
        assertSourceNotContains(
            partialSrc,
            "mapping(bytes32 orderId => RolloverTypes.OrderStatus status) orderStatus",
            "PartialSettler.orderStatus mapping key MUST NOT be orderId"
        );
    }

    /// @notice ExactSettler / PartialSettler keep the former cache slot reserved for layout parity.
    function test_storage_orderById_mapping_key_reserved() public view {
        string memory exactSrc = vm.readFile("src/ExactSettler.sol");
        string memory partialSrc = vm.readFile("src/PartialSettler.sol");
        assertSourceContains(
            exactSrc,
            "mapping(bytes32 orderId => RolloverTypes.OrderData orderData) orderById",
            "ExactSettler.orderById slot MUST stay reserved"
        );
        assertSourceContains(
            partialSrc,
            "mapping(bytes32 orderId => RolloverTypes.OrderData orderData) orderById",
            "PartialSettler.orderById slot MUST stay reserved"
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ERC-7683 interface conformance
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice ERC-7683 splits origin admission/resolution from destination fills.
    function test_erc7683_origin_destination_interfaces_split_fill() public view {
        string memory origin = vm.readFile("src/interfaces/external/erc7683/IOriginSettler.sol");
        string memory destination =
            vm.readFile("src/interfaces/external/erc7683/IDestinationSettler.sol");
        string memory settler = vm.readFile("src/interfaces/settlers/ISettler.sol");

        assertSourceNotContains(
            origin,
            "function fill(bytes32 orderId, bytes calldata originData, bytes calldata fillerData)",
            "IOriginSettler MUST NOT expose destination fill"
        );
        assertSourceContains(
            origin,
            "event Open(bytes32 indexed orderId,",
            "IOriginSettler MUST expose the standard Open event ABI"
        );
        assertSourceContains(
            destination,
            "function fill(bytes32 orderId, bytes calldata originData, bytes calldata fillerData)",
            "IDestinationSettler MUST expose destination fill"
        );
        assertSourceContains(
            settler,
            "override(IDestinationSettler)",
            "ISettler fill MUST override only IDestinationSettler"
        );
        assertSourceNotContains(
            settler,
            "override(IOriginSettler, IDestinationSettler)",
            "ISettler fill MUST NOT override IOriginSettler"
        );
    }

    /// @notice Non-standard gasless open/resolve overloads stay removed.
    function test_erc7683_gasless_open_resolve_shims_removed() public view {
        string memory origin = vm.readFile("src/interfaces/external/erc7683/IOriginSettler.sol");
        string memory settler = vm.readFile("src/interfaces/settlers/ISettler.sol");
        string memory base = vm.readFile("src/BaseSettler.sol");

        _assertNoFunctionTakingGaslessOrder(
            origin, "open", "IOriginSettler MUST NOT expose non-standard gasless open shim"
        );
        _assertNoFunctionTakingGaslessOrder(
            origin, "resolve", "IOriginSettler MUST NOT expose non-standard gasless resolve shim"
        );
        _assertNoFunctionTakingGaslessOrder(
            settler, "open", "ISettler MUST NOT reintroduce non-standard gasless open shim"
        );
        _assertNoFunctionTakingGaslessOrder(
            settler, "resolve", "ISettler MUST NOT reintroduce non-standard gasless resolve shim"
        );
        _assertNoFunctionTakingGaslessOrder(
            base, "open", "BaseSettler MUST NOT implement non-standard gasless open shim"
        );
        _assertNoFunctionTakingGaslessOrder(
            base, "resolve", "BaseSettler MUST NOT implement non-standard gasless resolve shim"
        );
    }

    /// @notice Pinned ERC-7683 `FillInstruction.destinationChainId` is `uint256`.
    function test_erc7683_fill_instruction_destination_chain_id_is_uint256() public view {
        string memory typesSrc = vm.readFile("src/interfaces/external/erc7683/ERC7683Types.sol");

        assertSourceContains(
            typesSrc,
            "uint256 destinationChainId;",
            "FillInstruction.destinationChainId MUST be uint256"
        );
        assertSourceNotContains(
            typesSrc,
            "uint64 destinationChainId;",
            "FillInstruction.destinationChainId MUST NOT be uint64"
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ABI selector regression - parameter renames do NOT change selectors
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice External selectors are name+type-list only; parameter renames are invisible.
    function test_abi_selectors_unchanged_after_rename() public pure {
        bytes4 expectedOrderStatus = bytes4(keccak256("orderStatus(bytes32)"));

        assertEq(ISettler.orderStatus.selector, expectedOrderStatus, "orderStatus selector");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Invariant ledger discipline
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice INV-WIRE-ORDER-STABILITY is recorded in the invariant ledger with key fields.
    function test_invariants_ledger_documents_wire_order_stability() public view {
        string memory ledger = vm.readFile("docs/INVARIANTS.md");
        assertSourceContains(ledger, "### INV-WIRE-ORDER-STABILITY", "ledger heading");
        assertSourceContains(ledger, "rolloverIntentHash", "ledger references rolloverIntentHash");
        assertSourceContains(ledger, "Settler EIP-712 domain", "ledger references domain strategy");
        assertSourceContains(
            ledger, "FillerPayload", "ledger references FillerPayload encoder distinction"
        );
    }

    /// @notice Reject exact `function <name>(...GaslessCrossChainOrder...)` declarations,
    ///         regardless of forge formatting across multiple lines. `openFor` / `resolveFor`
    ///         are skipped because the byte after the exact name is not `(`.
    function _assertNoFunctionTakingGaslessOrder(
        string memory src,
        string memory name,
        string memory context
    ) private pure {
        bytes memory haystack = bytes(src);
        bytes memory needle = bytes.concat("function ", bytes(name));
        bytes memory gasless = bytes("ERC7683Types.GaslessCrossChainOrder");
        uint256 from;

        while (from < haystack.length) {
            uint256 functionStart = sourceIndexOf(haystack, needle, from);
            if (functionStart == type(uint256).max) {
                return;
            }
            uint256 afterName = functionStart + needle.length;
            if (afterName < haystack.length && haystack[afterName] == 0x28) {
                uint256 declarationEnd = sourceIndexOf(haystack, bytes("{"), afterName);
                uint256 semicolon = sourceIndexOf(haystack, bytes(";"), afterName);
                if (semicolon < declarationEnd) {
                    declarationEnd = semicolon;
                }
                if (declarationEnd == type(uint256).max) {
                    declarationEnd = haystack.length;
                }
                assertFalse(
                    sourceContainsBetween(haystack, gasless, afterName, declarationEnd), context
                );
            }
            from = afterName;
        }
    }
}
