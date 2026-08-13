// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { IRolloverHookDispatcher } from "src/interfaces/rollover/IRolloverHookDispatcher.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice FactoryPhaseAllowlistTest — pins FactoryPhaseAllowlist behaviour for the Cork Rollover suite.
contract FactoryPhaseAllowlistTest is BaseTest {
    function _emptyFillContext() internal view returns (RolloverTypes.FillContext memory) {
        return _fillContext({
            filler_: address(this),
            fillAmount: 0,
            rolloverIntentHash: bytes32(uint256(1)),
            fillDeadline: uint64(block.timestamp + 1 days),
            allowPartialFills: false,
            orderSize: 1,
            originSettler: address(this),
            premiumToken_: address(premiumToken),
            premium: 0
        });
    }

    function _assertInvalidRawPhaseRejected(uint8 phase) internal {
        RolloverTypes.RolloverIntent memory intent =
            _emptyIntent(rolloverContract, bytes32(uint256(0xD16E57)));
        bytes memory sig = new bytes(65);

        RolloverTypes.FillContext memory fillContext = _emptyFillContext();
        vm.prank(address(settler));
        (bool ok,) = address(factory)
            .call(
                abi.encodeWithSelector(
                    IRolloverHookDispatcher.executeIntentHooks.selector,
                    rolloverContract,
                    bytes32(uint256(0xD16E57)),
                    phase,
                    intent,
                    sig,
                    fillContext,
                    _emptyOrderData()
                )
            );
        assertFalse(ok, "invalid raw phase accepted");
    }

    /// @notice Raw ABI phase values above the enum range are rejected before dispatch.
    function test_phaseOneAboveMaxReverts() public {
        _assertInvalidRawPhaseRejected(uint8(RolloverTypes.HookPhase.PREMIUM) + 1);
    }

    /// @notice Raw ABI phase values above the enum range are rejected before dispatch.
    function test_phaseMidRangeReverts() public {
        _assertInvalidRawPhaseRejected(uint8(64));
    }

    /// @notice Raw ABI phase values above the enum range are rejected before dispatch.
    function test_phaseMaxReverts() public {
        _assertInvalidRawPhaseRejected(type(uint8).max);
    }
}
