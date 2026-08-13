// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { SourceShapeAssertions } from "../../base/SourceShapeAssertions.sol";

/// @notice Regression pins for the repo-pinned ERC-7683 origin-settler method surface.
contract ERC7683OriginSurfaceShapeTest is SourceShapeAssertions {
    /// @notice Source path for the vendored ERC-7683 origin interface.
    string internal constant ORIGIN_INTERFACE =
        "src/interfaces/external/erc7683/IOriginSettler.sol";
    /// @notice Source path for the BaseSettler implementation.
    string internal constant BASE_SETTLER = "src/BaseSettler.sol";

    /// @notice Pins the pinned-draft ERC-7683 origin methods and event.
    function test_originInterface_matchesPinnedMethodSurface() public view {
        string memory src = vm.readFile(ORIGIN_INTERFACE);
        string memory compactSrc = _compactSource(src);

        _assertCompactSourceContains(
            compactSrc,
            "eventOpen(bytes32indexedorderId,ERC7683Types.ResolvedCrossChainOrderresolvedOrder);",
            "IOriginSettler Open event"
        );
        _assertCompactSourceContains(
            compactSrc,
            "functionopen(ERC7683Types.OnchainCrossChainOrdercalldataorder)external;",
            "IOriginSettler on-chain open"
        );
        _assertCompactSourceContains(
            compactSrc, "functionopenFor(", "IOriginSettler gasless openFor"
        );
        _assertCompactSourceContains(
            compactSrc,
            "functionresolve(ERC7683Types.OnchainCrossChainOrdercalldataorder)",
            "IOriginSettler on-chain resolve"
        );
        _assertCompactSourceContains(
            compactSrc, "functionresolveFor(", "IOriginSettler gasless resolveFor"
        );
    }

    /// @notice Rejects non-standard shortcut selectors in the vendored origin interface.
    function test_originInterface_rejectsNonStandardShortcutSelectors() public view {
        string memory src = vm.readFile(ORIGIN_INTERFACE);
        string memory compactSrc = _compactSource(src);

        _assertCompactSourceNotContains(
            compactSrc,
            "functionopen(ERC7683Types.GaslessCrossChainOrder",
            "IOriginSettler must not redeclare typed gasless open shortcut"
        );
        _assertCompactSourceNotContains(
            compactSrc,
            "functionopen(GaslessCrossChainOrder",
            "IOriginSettler must not redeclare imported gasless open shortcut"
        );
        _assertCompactSourceNotContains(
            compactSrc,
            "functionresolve(ERC7683Types.GaslessCrossChainOrder",
            "IOriginSettler must not redeclare typed gasless resolve shortcut"
        );
        _assertCompactSourceNotContains(
            compactSrc,
            "functionresolve(GaslessCrossChainOrder",
            "IOriginSettler must not redeclare imported gasless resolve shortcut"
        );
        _assertCompactSourceNotContains(
            compactSrc, "functionfill(", "IOriginSettler must not redeclare destination fill"
        );
    }

    /// @notice Rejects removed non-standard shortcut implementations in BaseSettler.
    function test_baseSettler_rejectsRemovedGaslessShortcutImplementations() public view {
        string memory src = vm.readFile(BASE_SETTLER);
        string memory compactSrc = _compactSource(src);

        _assertCompactSourceNotContains(
            compactSrc,
            "functionopen(ERC7683Types.GaslessCrossChainOrder",
            "BaseSettler must not expose typed gasless open shortcut"
        );
        _assertCompactSourceNotContains(
            compactSrc,
            "functionopen(GaslessCrossChainOrder",
            "BaseSettler must not expose imported gasless open shortcut"
        );
        _assertCompactSourceNotContains(
            compactSrc,
            "functionresolve(ERC7683Types.GaslessCrossChainOrder",
            "BaseSettler must not expose typed gasless resolve shortcut"
        );
        _assertCompactSourceNotContains(
            compactSrc,
            "functionresolve(GaslessCrossChainOrder",
            "BaseSettler must not expose imported gasless resolve shortcut"
        );
        assertSourceNotContains(src, "_openForCore", "BaseSettler must inline openFor core");
        assertSourceNotContains(
            src, "_verifyCptHolderSig", "BaseSettler must inline async premium signature check"
        );
    }

    /// @notice Asserts compacted source contains compacted needle.
    /// @param compactSrc Source with whitespace removed.
    /// @param compactNeedle Needle with whitespace removed.
    /// @param context Failure context.
    function _assertCompactSourceContains(
        string memory compactSrc,
        string memory compactNeedle,
        string memory context
    ) internal pure {
        require(
            sourceContains(compactSrc, compactNeedle),
            string.concat("missing: ", context, " - compact needle: ", compactNeedle)
        );
    }

    /// @notice Asserts compacted source does not contain compacted needle.
    /// @param compactSrc Source with whitespace removed.
    /// @param compactNeedle Needle with whitespace removed.
    /// @param context Failure context.
    function _assertCompactSourceNotContains(
        string memory compactSrc,
        string memory compactNeedle,
        string memory context
    ) internal pure {
        require(
            !sourceContains(compactSrc, compactNeedle),
            string.concat("forbidden present: ", context, " - compact needle: ", compactNeedle)
        );
    }

    /// @notice Removes ASCII whitespace from source text before shape assertions.
    /// @param src Source text.
    /// @return compact Source text with spaces, tabs, and line endings removed.
    function _compactSource(string memory src) internal pure returns (string memory compact) {
        bytes memory input = bytes(src);
        bytes memory buffer = new bytes(input.length);
        uint256 out;
        for (uint256 i = 0; i < input.length; ++i) {
            bytes1 c = input[i];
            if (c != 0x20 && c != 0x09 && c != 0x0a && c != 0x0d) {
                buffer[out++] = c;
            }
        }

        compact = new string(out);
        bytes memory compactBytes = bytes(compact);
        for (uint256 i = 0; i < out; ++i) {
            compactBytes[i] = buffer[i];
        }
    }
}
