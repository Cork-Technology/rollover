// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";
import { ModuleType } from "src/interfaces/external/erc7484/IERC7484.sol";
import { Typehashes } from "src/libraries/Typehashes.sol";
import { MockERC7484 } from "test/mocks/MockERC7484.sol";

/// @notice Regression coverage for Cork's deployed-registry-compatible module-type allocation.
contract ModuleTypeCompatibilityTest is Test {
    /// @notice Registry mock under test.
    MockERC7484 internal registry;

    /// @notice Deploys a fresh registry mock.
    function setUp() public {
        registry = new MockERC7484();
    }

    /// @notice Production buckets are nonzero, unique, and fit the deployed registry bitmap.
    function test_productionModuleTypesAreNonzeroDistinctBitmapIndices() public pure {
        uint256[4] memory moduleTypes = [
            ModuleType.unwrap(Typehashes.MODULE_TYPE_PRE_ROLLOVER_HOOK),
            ModuleType.unwrap(Typehashes.MODULE_TYPE_MID_ROLLOVER_HOOK),
            ModuleType.unwrap(Typehashes.MODULE_TYPE_POST_ROLLOVER_HOOK),
            ModuleType.unwrap(Typehashes.MODULE_TYPE_EXECUTOR)
        ];

        for (uint256 i = 0; i < moduleTypes.length; ++i) {
            assertGt(moduleTypes[i], 0, "production module type must be nonzero");
            assertLe(moduleTypes[i], 31, "production module type must fit registry bitmap");
            for (uint256 j = i + 1; j < moduleTypes.length; ++j) {
                assertNotEq(
                    moduleTypes[i], moduleTypes[j], "production module types must be distinct"
                );
            }
        }
    }

    /// @notice The mock rejects the legacy high discriminator without making type 1 usable.
    function test_highModuleTypeIsRejectedWithoutTruncation() public {
        address module = makeAddr("module");
        ModuleType legacyType = ModuleType.wrap(0xc0c0_0001);

        vm.expectRevert(
            abi.encodeWithSelector(
                MockERC7484.MockERC7484__InvalidModuleType.selector, ModuleType.unwrap(legacyType)
            )
        );
        registry.setAttestedType(module, legacyType);

        vm.expectRevert(
            abi.encodeWithSelector(MockERC7484.MockERC7484__NotAttested.selector, module)
        );
        registry.check(module, ModuleType.wrap(1));
    }

    /// @notice Explicit-attester configuration rejects the legacy high discriminator.
    function test_highExplicitAttesterModuleTypeIsRejected() public {
        address attester = makeAddr("attester");
        address module = makeAddr("module");
        ModuleType legacyType = ModuleType.wrap(0xc0c0_0001);

        vm.expectRevert(
            abi.encodeWithSelector(
                MockERC7484.MockERC7484__InvalidModuleType.selector, ModuleType.unwrap(legacyType)
            )
        );
        registry.setAttestedTypeFor(attester, module, legacyType);

        address[] memory attesters = new address[](1);
        attesters[0] = attester;
        vm.expectRevert(
            abi.encodeWithSelector(MockERC7484.MockERC7484__NotAttested.selector, module)
        );
        registry.check(module, ModuleType.wrap(1), attesters, 1);
    }

    /// @notice Bitmap validation preserves strict attester ordering, thresholds, and revocation.
    function test_explicitAttesterThresholdOrderingAndRevocationRemainStrict() public {
        address module = makeAddr("module");
        address attesterA = address(0x1000);
        address attesterB = address(0x2000);
        ModuleType moduleType = Typehashes.MODULE_TYPE_PRE_ROLLOVER_HOOK;
        registry.setAttestedTypeFor(attesterA, module, moduleType);
        registry.setAttestedTypeFor(attesterB, module, moduleType);

        address[] memory attesters = new address[](2);
        attesters[0] = attesterA;
        attesters[1] = attesterB;
        registry.check(module, moduleType, attesters, 2);

        address[] memory unsorted = new address[](2);
        unsorted[0] = attesterB;
        unsorted[1] = attesterA;
        vm.expectRevert(
            abi.encodeWithSelector(
                MockERC7484.MockERC7484__UnsortedAttesters.selector, attesterB, attesterA
            )
        );
        registry.check(module, moduleType, unsorted, 2);

        registry.clearAttestedTypeFor(attesterB, module);
        vm.expectRevert(
            abi.encodeWithSelector(
                MockERC7484.MockERC7484__ThresholdNotMet.selector, module, uint256(2), uint256(1)
            )
        );
        registry.check(module, moduleType, attesters, 2);
    }

    /// @notice Bitmap validation preserves global rejection and caller-scoped rejection.
    function test_rejectionRemainsGlobalAndCallerScoped() public {
        address module = makeAddr("module");
        address smartAccount = makeAddr("smartAccount");
        ModuleType moduleType = Typehashes.MODULE_TYPE_EXECUTOR;
        registry.setAttestedType(module, moduleType);

        registry.setRejectedFor(smartAccount, module, true);
        vm.prank(smartAccount);
        vm.expectRevert(abi.encodeWithSelector(MockERC7484.MockERC7484__Rejected.selector, module));
        registry.check(module, moduleType);
        registry.check(module, moduleType);

        registry.setRejected(module, true);
        vm.expectRevert(abi.encodeWithSelector(MockERC7484.MockERC7484__Rejected.selector, module));
        registry.check(module, moduleType);
    }
}
