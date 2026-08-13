// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { BaseFiller } from "src/BaseFiller.sol";
import {
    BaseFiller__UnknownSettler,
    BaseFiller__ZeroSettler
} from "src/errors/BaseFillerErrors.sol";
import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import { IMarketRegistry } from "src/interfaces/external/market-registry/IMarketRegistry.sol";
import { IDefaultCorkController } from "src/interfaces/external/phoenix/IDefaultCorkController.sol";
import { IPoolManager } from "src/interfaces/external/phoenix/IPoolManager.sol";
import { ISettler } from "src/interfaces/settlers/ISettler.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice BaseFillerCtorAndAssertUnitTest — covers the two BaseFiller branches the
///         existing suite leaves unexercised (BF-1, BF-2 from
///         audits/forge-coverage-extend/phase-b2-test-proposals.md).
contract BaseFillerCtorAndAssertUnitTest is BaseTest {
    /// @notice BF-1 (L94): ctor reverts when `partialSettler_` is the zero address with a
    ///         non-zero `exactSettler_`. Exercises the SECOND zero-check (L94), distinct
    ///         from the existing `(0,0)` test which short-circuits on L93.
    function testRevert_constructor_zeroPartialSettler() public {
        vm.expectRevert(BaseFiller__ZeroSettler.selector);
        new BaseFiller(
            ISettler(address(settler)),
            ISettler(address(0)),
            IPoolManager(address(0)),
            IDefaultCorkController(address(0)),
            IMarketRegistry(address(0))
        );
    }

    /// @notice BF-2 (L371): `_assertExpectedSettler` reverts with `BaseFiller__UnknownSettler`
    ///         when the caller-supplied `job.settler` is the zero address. Reached via
    ///         `execute(...)` with a valid decodeable order and `settler = address(0)`.
    function testRevert_assertExpectedSettler_zeroActual() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        RolloverTypes.RolloverIntent memory intent;
        bytes memory empty;

        vm.expectRevert(BaseFiller__UnknownSettler.selector);
        baseFiller.execute(
            BaseFiller.FillerJob({
                settler: ISettler(address(0)),
                order: g,
                userSig: empty,
                srcCst: IERC20(address(srcCst)),
                premiumToken: IERC20(address(premiumToken)),
                fillerSrcCst: 0,
                intent: intent,
                premiumCap: 0,
                minDstPerSrc: 0,
                fillerAuthSig: ""
            })
        );
    }
}
