// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { MockERC20 } from "../../mocks/MockERC20.sol";
import {
    ConsumeDstCptModule,
    SourceSrcCptModule,
    SwapCaModule
} from "../../mocks/modules/HookModules.sol";
import { MidHookFuzzHandler } from "../handlers/MidHookFuzzHandler.sol";
import { Typehashes } from "src/libraries/Typehashes.sol";

/// @notice INV-DST-FLOOR — fail-on-revert invariant suite: end-to-end value is bounded by `params.minSharesOut`; the deleted `MidPhaseCollateralDrain` selector is never emitted.
/// @dev fail-on-revert mode (companion at test/invariant/continueOnRevert/MidHookFuzz.t.sol).
/// @custom:invariant INV-DST-FLOOR
contract MidHookFuzzFailOnRevertTest is BaseTest {
    /// @notice Fuzz handler instance.
    MidHookFuzzHandler internal midHandler;

    /// @notice Destination collateral asset.
    MockERC20 internal caDst;

    /// @notice Mid-rollover swap module.
    SwapCaModule internal swapMod;

    /// @notice Post-hook dstCPT consumer.
    ConsumeDstCptModule internal consumeMod;

    /// @notice Sink address for caSrc consumed by the swap mock.
    address internal swapSink = address(0xCA51);

    /// @inheritdoc BaseTest
    function setUp() public override {
        super.setUp();

        caDst = new MockERC20("CA-dst", "CAD", 18);
        phoenixPool.bind(dstCst.poolId(), dstCst, dstCpt, caDst);

        swapMod = new SwapCaModule();
        consumeMod = new ConsumeDstCptModule();

        erc7484.setAttestedType(address(swapMod), Typehashes.MODULE_TYPE_MID_ROLLOVER_HOOK);
        erc7484.setAttestedType(address(consumeMod), Typehashes.MODULE_TYPE_POST_ROLLOVER_HOOK);

        vm.startPrank(filler);
        srcCst.approve(address(settler), type(uint256).max);
        srcCst.approve(address(partialSettler), type(uint256).max);
        vm.stopPrank();

        midHandler = new MidHookFuzzHandler(
            settler,
            rolloverContract,
            srcCst,
            dstCst,
            premiumToken,
            caSrc,
            caDst,
            srcCpt,
            dstCpt,
            MidHookFuzzHandler.Wiring({
                sourceSrc: sourceSrcCptModule,
                swap: swapMod,
                consume: consumeMod,
                cptHolder: cptHolder,
                cptHolderPk: cptHolderPk,
                filler: filler,
                sink: swapSink
            })
        );

        targetContract(address(midHandler));
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = midHandler.attemptRollover.selector;
        targetSelector(FuzzSelector({ addr: address(midHandler), selectors: selectors }));
    }

    /// @notice invariant: legs producing at least `minSharesOut` never revert (strict).
    function invariant_legAtOrAboveFloorNeverReverts_strict() public view {
        assertFalse(
            midHandler.ghostFloorClearedButReverted(),
            "INV-DST-FLOOR: leg produced >= minSharesOut yet reverted"
        );
    }

    /// @notice invariant: legs producing below `minSharesOut` never succeed (strict).
    function invariant_legBelowFloorAlwaysReverts_strict() public view {
        assertFalse(
            midHandler.ghostBelowFloorButSucceeded(),
            "INV-DST-FLOOR: leg produced < minSharesOut yet succeeded (strict)"
        );
    }

    /// @notice invariant: the deleted `MidPhaseCollateralDrain` selector is never returned by a reverted leg (strict).
    function invariant_midPhaseCollateralDrainSelectorNeverEmitted_strict() public view {
        assertFalse(
            midHandler.ghostMidDrainEmitted(),
            "INV-DST-FLOOR: deleted MidPhaseCollateralDrain selector was emitted (strict)"
        );
    }
}
