// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { MockEVC } from "../../mocks/MockEVC.sol";
import { ISignatureTransfer } from "permit2/interfaces/ISignatureTransfer.sol";
import { EvcRolloverAdapter, IEVC } from "src/EvcRolloverAdapter.sol";
import {
    EvcRolloverAdapter__ZeroPermit2,
    EvcRolloverAdapter__ZeroSettler
} from "src/errors/EvcRolloverAdapterErrors.sol";
import { ISettler } from "src/interfaces/settlers/ISettler.sol";

/// @notice EvcRolloverAdapterCtorUnitTest — covers the ctor branch left unexercised by
///         the existing suite (EVC-1 from
///         audits/forge-coverage-extend/phase-b2-test-proposals.md).
contract EvcRolloverAdapterCtorUnitTest is BaseTest {
    /// @notice EVC-1 (L168): ctor reverts when `partialSettler_` is the zero address with
    ///         non-zero `evc_`, `controller_`, and `exactSettler_`. Exercises the FOURTH
    ///         zero-check (L168), distinct from the L165/L166/L167 zero-checks for
    ///         `evc_`/`controller_`/`exactSettler_`.
    function testRevert_constructor_zeroPartialSettler() public {
        MockEVC evcMock = new MockEVC();
        ISettler exactSettler_ = ISettler(address(settler));

        vm.expectRevert(EvcRolloverAdapter__ZeroSettler.selector);
        new EvcRolloverAdapter(
            IEVC(address(evcMock)),
            address(0xC011704),
            exactSettler_,
            ISettler(address(0)),
            ISignatureTransfer(address(permit2))
        );
    }

    /// @notice Constructor rejects a zero Permit2 instance after EVC/controller/settlers are valid.
    function testRevert_constructor_zeroPermit2() public {
        MockEVC evcMock = new MockEVC();

        vm.expectRevert(EvcRolloverAdapter__ZeroPermit2.selector);
        new EvcRolloverAdapter(
            IEVC(address(evcMock)),
            address(0xC011704),
            ISettler(address(settler)),
            ISettler(address(partialSettler)),
            ISignatureTransfer(address(0))
        );
    }
}
