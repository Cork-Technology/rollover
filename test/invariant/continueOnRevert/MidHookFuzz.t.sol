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

/// @notice INV-DST-FLOOR — continue-on-revert invariant suite: end-to-end value is bounded by `params.minSharesOut`; the deleted `MidPhaseCollateralDrain` selector is never emitted.
/// @dev continue-on-revert mode (companion at test/invariant/failOnRevert/MidHookFuzz.t.sol).
/// @custom:invariant INV-DST-FLOOR
contract MidHookFuzzContinueOnRevertTest is BaseTest {
    /// @notice Fuzz handler instance.
    MidHookFuzzHandler internal midHandler;

    /// @notice Destination collateral asset (distinct token from caSrc).
    MockERC20 internal caDst;

    /// @notice Mid-rollover hook modules used by the handler.
    SwapCaModule internal swapMod;

    /// @notice Post-hook dstCPT consumer used by the handler.
    ConsumeDstCptModule internal consumeMod;

    /// @notice Sink address used by the swap mock to absorb caSrc.
    address internal swapSink = address(0xCA51);

    /// @inheritdoc BaseTest
    function setUp() public override {
        super.setUp();

        // Cross-CA pool binding for the destination market.
        caDst = new MockERC20("CA-dst", "CAD", 18);
        phoenixPool.bind(dstCst.poolId(), dstCst, dstCpt, caDst);

        swapMod = new SwapCaModule();
        consumeMod = new ConsumeDstCptModule();

        erc7484.setAttestedType(address(swapMod), Typehashes.MODULE_TYPE_MID_ROLLOVER_HOOK);
        erc7484.setAttestedType(address(consumeMod), Typehashes.MODULE_TYPE_POST_ROLLOVER_HOOK);

        // Filler allowance for repeated fills.
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

    /// @notice invariant: legs producing at least `minSharesOut` never revert (loose).
    function invariant_legAtOrAboveFloorNeverReverts() public view {
        assertFalse(
            midHandler.ghostFloorClearedButReverted(),
            "INV-DST-FLOOR: leg produced >= minSharesOut yet reverted"
        );
    }

    /// @notice invariant: legs producing below `minSharesOut` never succeed (loose).
    function invariant_legBelowFloorAlwaysReverts() public view {
        assertFalse(
            midHandler.ghostBelowFloorButSucceeded(),
            "INV-DST-FLOOR: leg produced < minSharesOut yet succeeded"
        );
    }

    /// @notice invariant: the deleted `MidPhaseCollateralDrain` selector is never returned by a reverted leg.
    function invariant_midPhaseCollateralDrainSelectorNeverEmitted() public view {
        assertFalse(
            midHandler.ghostMidDrainEmitted(),
            "INV-DST-FLOOR: deleted MidPhaseCollateralDrain selector was emitted"
        );
    }
}
