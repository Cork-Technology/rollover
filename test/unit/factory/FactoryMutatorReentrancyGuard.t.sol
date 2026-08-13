// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { SourceShapeAssertions } from "../../base/SourceShapeAssertions.sol";

/// @notice FactoryMutatorReentrancyGuardTest - regression pin for issue #141. Asserts that the
///         three previously-unguarded state-mutating factory entrypoints (`setDefaults`,
///         `queueTrustConfig`, `queueFactoryDefaultTrustConfig`) carry the `nonReentrant`
///         modifier, restoring parity with every sibling factory mutator. Defense-in-depth /
///         modifier-consistency only; not a live exploit. Source-shape assertions via
///         `vm.readFile` and `SourceShapeAssertions` so the pin survives
///         unrelated body edits.
contract FactoryMutatorReentrancyGuardTest is SourceShapeAssertions {
    /// @notice Factory source path read via `vm.readFile` to assert the guarded signatures.
    string internal constant FACTORY_SRC = "src/CorkRolloverContractFactory.sol";
    /// @notice Factory unit doc path read via `vm.readFile` to assert the entrypoint table.
    string internal constant FACTORY_DOC = "docs/spec/md/units/factory.md";

    /// @notice `setDefaults` carries `nonReentrant`.
    function test_setDefaults_is_nonReentrant() public view {
        string memory src = vm.readFile(FACTORY_SRC);
        _assertFunctionDeclarationHasModifier(src, "setDefaults", "nonReentrant");
    }

    /// @notice `queueTrustConfig` carries `nonReentrant`.
    function test_queueTrustConfig_is_nonReentrant() public view {
        string memory src = vm.readFile(FACTORY_SRC);
        _assertFunctionDeclarationHasModifier(src, "queueTrustConfig", "nonReentrant");
    }

    /// @notice `queueFactoryDefaultTrustConfig` carries `nonReentrant`.
    function test_queueFactoryDefaultTrustConfig_is_nonReentrant() public view {
        string memory src = vm.readFile(FACTORY_SRC);
        _assertFunctionDeclarationHasModifier(src, "queueFactoryDefaultTrustConfig", "nonReentrant");
    }

    /// @notice Entrypoint-table doc rows reflect the restored `nonReentrant` guard.
    function test_all_factory_mutators_guarded_doc_table() public view {
        string memory doc = vm.readFile(FACTORY_DOC);
        assertSourceContains(
            doc,
            "`setDefaults(uint8 threshold, address[] attesters, address registry)` | `nonReentrant onlyRole(DEFAULTS_MANAGER_ROLE)`",
            "factory doc table: setDefaults row MUST show nonReentrant onlyRole"
        );
        assertSourceContains(
            doc,
            "`queueFactoryDefaultTrustConfig()` | `nonReentrant`",
            "factory doc table: queueFactoryDefaultTrustConfig row MUST show nonReentrant"
        );
        assertSourceContains(
            doc,
            "`queueTrustConfig(uint8 threshold, address[] attesters)` | `nonReentrant`",
            "factory doc table: queueTrustConfig row MUST show nonReentrant"
        );
    }

    /// @notice Assert that a function declaration contains the expected modifier before the body.
    function _assertFunctionDeclarationHasModifier(
        string memory src,
        string memory functionName,
        string memory modifierName
    ) internal pure {
        assertSourceContainsBetween(
            src,
            string.concat("function ", functionName),
            "{",
            modifierName,
            string.concat(functionName, " declaration MUST contain ", modifierName)
        );
    }
}
