// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { CountingSettler } from "../../mocks/CountingSettler.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { BaseFiller } from "src/BaseFiller.sol";
import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import { IMarketRegistry } from "src/interfaces/external/market-registry/IMarketRegistry.sol";
import { IDefaultCorkController } from "src/interfaces/external/phoenix/IDefaultCorkController.sol";
import { IPoolManager } from "src/interfaces/external/phoenix/IPoolManager.sol";
import { ISettler } from "src/interfaces/settlers/ISettler.sol";
import { LibSettlerHashing } from "src/libraries/LibSettlerHashing.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice Pins INV-OPENED-ORDERS-FILLABLE-UNTIL-FILLDEADLINE (BaseFiller helper half):
///         local digest computation and idempotent `openFor` skip on `Opened`.
contract BaseFillerOpenForIdempotentTest is BaseTest {
    /// @notice CountingSettler bound to the filler's exact-mode slot.
    CountingSettler internal exactCount;
    /// @notice CountingSettler bound to the filler's partial-mode slot.
    CountingSettler internal partialCount;
    /// @notice Filler under test.
    BaseFiller internal testFiller;

    /// @notice Caller driving `BaseFiller.execute`.
    address internal caller;

    /// @inheritdoc BaseTest
    function setUp() public override {
        super.setUp();
        bytes32 domainSep = settler.DOMAIN_SEPARATOR();
        exactCount = new CountingSettler(domainSep);
        partialCount = new CountingSettler(domainSep);
        testFiller = new BaseFiller(
            ISettler(address(exactCount)),
            ISettler(address(partialCount)),
            IPoolManager(address(0)),
            IDefaultCorkController(address(0)),
            IMarketRegistry(address(0))
        );
        caller = makeAddr("baseFillerCaller");
    }

    function _job() internal view returns (BaseFiller.FillerJob memory j) {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.settler = address(exactCount);
        orderData.rolloverParams.settler = address(exactCount);
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        RolloverTypes.RolloverIntent memory intent;
        bytes memory empty;
        j = BaseFiller.FillerJob({
            settler: ISettler(address(exactCount)),
            order: g,
            userSig: empty,
            srcCst: IERC20(address(srcCst)),
            premiumToken: IERC20(address(premiumToken)),
            fillerSrcCst: 0,
            intent: intent,
            premiumCap: 0,
            minDstPerSrc: 0,
            fillerAuthSig: ""
        });
    }

    function _orderDigestOf(BaseFiller.FillerJob memory j) internal view returns (bytes32) {
        RolloverTypes.OrderData memory od = abi.decode(j.order.orderData, (RolloverTypes.OrderData));
        return LibSettlerHashing.computeOrderDigestMemory(od, exactCount.DOMAIN_SEPARATOR());
    }

    function _callExecute(BaseFiller.FillerJob memory j) internal {
        vm.prank(caller);
        testFiller.execute(j);
    }

    /// @notice status `None` calls `openFor` exactly once.
    function test_runSettlement_callsOpenFor_when_status_is_None() public {
        _callExecute(_job());
        assertEq(exactCount.openForCalls(), 1, "openFor called once on None");
    }

    /// @notice status `Opened` skips `openFor`.
    function test_runSettlement_skipsOpenFor_when_status_is_Opened() public {
        BaseFiller.FillerJob memory j = _job();
        bytes32 orderId = _orderDigestOf(j);
        exactCount.setStatus(orderId, uint8(RolloverTypes.OrderStatus.Opened));
        _callExecute(j);
        assertEq(exactCount.openForCalls(), 0, "openFor must be skipped on Opened");
    }

    /// @notice Under atomic-fill settlement happens inside the atomic `fill()` frame.
    ///         The invariant is unchanged: the
    ///         BaseFiller must drive the Settler with the locally computed orderDigest,
    ///         not the `resolve()` sentinel.
    function test_runSettlement_uses_localDigest_not_resolveReturn() public {
        BaseFiller.FillerJob memory j = _job();
        bytes32 localDigest = _orderDigestOf(j);
        _callExecute(j);
        assertEq(exactCount.lastFillOrderId(), localDigest, "fill must use local digest");
        assertTrue(
            exactCount.lastFillOrderId() != bytes32(uint256(0xDEADBEEF)),
            "fill must not use resolve sentinel"
        );
    }
}
