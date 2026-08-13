// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { DstCstReconcileHandler } from "../handlers/DstCstReconcileHandler.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IPartialSettler } from "src/interfaces/settlers/IPartialSettler.sol";

/// @notice INV-DST-CST-RECONCILES — continue-on-revert invariant suite: per-order dstCST inflow reconciles against per-filler payouts.
/// @dev continue-on-revert mode (companion at test/invariant/failOnRevert/DstCstReconcile.t.sol).
/// @custom:invariant INV-DST-CST-RECONCILES
contract DstCstReconcileContinueOnRevertTest is BaseTest {
    /// @notice Reconcile handler.
    DstCstReconcileHandler internal reconcileHandler;

    /// @inheritdoc BaseTest
    function setUp() public override {
        super.setUp();
        reconcileHandler = new DstCstReconcileHandler(
            IPartialSettler(address(partialSettler)), IERC20(address(dstCst))
        );
        targetContract(address(reconcileHandler));
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = reconcileHandler.observe.selector;
        selectors[1] = reconcileHandler.registerOrderId.selector;
        selectors[2] = reconcileHandler.warpForward.selector;
        targetSelector(FuzzSelector({ addr: address(reconcileHandler), selectors: selectors }));
    }

    /// @notice invariant: settler covers partial escrow.
    function invariant_settlerCoversPartialEscrow() public view {
        uint256 live = IERC20(address(dstCst)).balanceOf(address(partialSettler));
        uint256 sum = reconcileHandler.sumPartialEscrow();
        assertGe(live, sum, "INV-DST-CST-RECONCILES: settler dstCST short (loose)");
    }
}
