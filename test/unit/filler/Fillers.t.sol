// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { MockEVC } from "../../mocks/MockEVC.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { BaseFiller } from "src/BaseFiller.sol";
import { EvcRolloverAdapter, IEVC } from "src/EvcRolloverAdapter.sol";
import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import { IMarketRegistry } from "src/interfaces/external/market-registry/IMarketRegistry.sol";
import { IDefaultCorkController } from "src/interfaces/external/phoenix/IDefaultCorkController.sol";
import { IPoolManager } from "src/interfaces/external/phoenix/IPoolManager.sol";
import { ISettler } from "src/interfaces/settlers/ISettler.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

import { ISignatureTransfer } from "permit2/interfaces/ISignatureTransfer.sol";
import { BaseFiller__ZeroSettler } from "src/errors/BaseFillerErrors.sol";
import {
    EvcRolloverAdapter__ControllerNotEnabled,
    EvcRolloverAdapter__OnBehalfMismatch,
    EvcRolloverAdapter__ZeroController,
    EvcRolloverAdapter__ZeroEvc,
    EvcRolloverAdapter__ZeroSettler
} from "src/errors/EvcRolloverAdapterErrors.sol";
import { LibRolloverOrder__BadOrderType } from "src/errors/LibRolloverOrderErrors.sol";

/// @notice FillersUnitTest — pins Fillers behaviour for the Cork Rollover suite.
contract FillersUnitTest is BaseTest {
    /// @notice Evc mock.
    MockEVC internal evcMock;
    /// @notice Evc adapter.

    EvcRolloverAdapter internal evcAdapter;
    /// @notice Test fixture setup.

    function setUp() public override {
        super.setUp();
        evcMock = new MockEVC();
        evcAdapter = new EvcRolloverAdapter(
            IEVC(address(evcMock)),
            address(0xCAFEF),
            ISettler(address(settler)),
            ISettler(address(partialSettler)),
            ISignatureTransfer(address(permit2))
        );
    }

    /// @notice Pins behaviour: reverts when base Filler Constructor Zero Settler.
    function testRevert_baseFillerConstructorZeroSettler() public {
        vm.expectRevert(BaseFiller__ZeroSettler.selector);
        new BaseFiller(
            ISettler(address(0)),
            ISettler(address(0)),
            IPoolManager(address(0)),
            IDefaultCorkController(address(0)),
            IMarketRegistry(address(0))
        );
    }

    /// @notice Pins behaviour: evc Adapter With Zero Controller Reverts.
    function testRevert_evcAdapterWithZeroControllerReverts() public {
        vm.expectRevert(EvcRolloverAdapter__ZeroController.selector);
        new EvcRolloverAdapter(
            IEVC(address(evcMock)),
            address(0),
            ISettler(address(settler)),
            ISettler(address(partialSettler)),
            ISignatureTransfer(address(permit2))
        );
    }

    /// @notice Pins behaviour: evc Adapter With Zero Evc Reverts.
    function testRevert_evcAdapterWithZeroEvcReverts() public {
        vm.expectRevert(EvcRolloverAdapter__ZeroEvc.selector);
        new EvcRolloverAdapter(
            IEVC(address(0)),
            address(0xCAFEF),
            ISettler(address(settler)),
            ISettler(address(partialSettler)),
            ISignatureTransfer(address(permit2))
        );
    }

    /// @notice Pins behaviour: reverts when evc Adapter Constructor Zero Settler.
    function testRevert_evcAdapterConstructorZeroSettler() public {
        vm.expectRevert(EvcRolloverAdapter__ZeroSettler.selector);
        new EvcRolloverAdapter(
            IEVC(address(evcMock)),
            address(0xCAFEF),
            ISettler(address(0)),
            ISettler(address(partialSettler)),
            ISignatureTransfer(address(permit2))
        );
    }

    /// @notice Pins behaviour: evc Adapter Execute Not Evc Context Reverts.
    function testRevert_evcAdapterExecuteNotEvcContextReverts() public {
        evcMock.setFrame(address(0), false, address(0xCAFEF));
        ERC7683Types.GaslessCrossChainOrder memory g;
        bytes memory empty;
        RolloverTypes.RolloverIntent memory intent;
        vm.expectRevert(MockEVC.EVC_OnBehalfOfAccountNotAuthenticated.selector);
        evcAdapter.execute(
            EvcRolloverAdapter.EvcRolloverJob({
                settler: ISettler(address(settler)),
                order: g,
                userSig: empty,
                subaccount: anyone,
                fundingAccount: anyone,
                recipient: anyone,
                srcCst: IERC20(address(srcCst)),
                premiumToken: IERC20(address(premiumToken)),
                fillerSrcCst: 0,
                minDstPerSrc: 0,
                intent: intent,
                premium: 0,
                fillerAuthSig: "",
                nonce: 0,
                deadline: 0,
                fundingSig: ""
            })
        );
    }

    /// @notice Pins behaviour: evc Adapter Execute On Behalf Mismatch Reverts.
    function testRevert_evcAdapterExecuteOnBehalfMismatchReverts() public {
        evcMock.setFrame(address(0xDEAD), true, address(0xCAFEF));
        ERC7683Types.GaslessCrossChainOrder memory g;
        bytes memory empty;
        RolloverTypes.RolloverIntent memory intent;
        vm.expectRevert(
            abi.encodeWithSelector(
                EvcRolloverAdapter__OnBehalfMismatch.selector, address(0xDEAD), anyone
            )
        );
        evcAdapter.execute(
            EvcRolloverAdapter.EvcRolloverJob({
                settler: ISettler(address(settler)),
                order: g,
                userSig: empty,
                subaccount: anyone,
                fundingAccount: anyone,
                recipient: anyone,
                srcCst: IERC20(address(srcCst)),
                premiumToken: IERC20(address(premiumToken)),
                fillerSrcCst: 0,
                minDstPerSrc: 0,
                intent: intent,
                premium: 0,
                fillerAuthSig: "",
                nonce: 0,
                deadline: 0,
                fundingSig: ""
            })
        );
    }

    /// @notice Pins behaviour: evc Adapter Execute Controller Not Enabled Reverts.
    function testRevert_evcAdapterExecuteControllerNotEnabledReverts() public {
        evcMock.setFrame(anyone, false, address(0xCAFEF));
        ERC7683Types.GaslessCrossChainOrder memory g;
        bytes memory empty;
        RolloverTypes.RolloverIntent memory intent;
        vm.expectRevert(EvcRolloverAdapter__ControllerNotEnabled.selector);
        evcAdapter.execute(
            EvcRolloverAdapter.EvcRolloverJob({
                settler: ISettler(address(settler)),
                order: g,
                userSig: empty,
                subaccount: anyone,
                fundingAccount: anyone,
                recipient: anyone,
                srcCst: IERC20(address(srcCst)),
                premiumToken: IERC20(address(premiumToken)),
                fillerSrcCst: 0,
                minDstPerSrc: 0,
                intent: intent,
                premium: 0,
                fillerAuthSig: "",
                nonce: 0,
                deadline: 0,
                fundingSig: ""
            })
        );
    }

    /// @notice Pins behaviour: evc Adapter Execute Partial Not Evc Context Reverts.
    function testRevert_evcAdapterExecutePartialNotEvcContextReverts() public {
        evcMock.setFrame(address(0), false, address(0xCAFEF));
        ERC7683Types.GaslessCrossChainOrder memory g;
        bytes memory empty;
        RolloverTypes.RolloverIntent memory intent;
        vm.expectRevert(MockEVC.EVC_OnBehalfOfAccountNotAuthenticated.selector);
        evcAdapter.executePartial(
            EvcRolloverAdapter.EvcRolloverJob({
                settler: ISettler(address(settler)),
                order: g,
                userSig: empty,
                subaccount: anyone,
                fundingAccount: anyone,
                recipient: anyone,
                srcCst: IERC20(address(srcCst)),
                premiumToken: IERC20(address(premiumToken)),
                fillerSrcCst: 0,
                minDstPerSrc: 0,
                intent: intent,
                premium: 0,
                fillerAuthSig: "",
                nonce: 0,
                deadline: 0,
                fundingSig: ""
            })
        );
    }

    /// @notice Pins behaviour: base Filler Execute With Zero Settler Reverts.
    function testRevert_baseFillerExecuteWithZeroSettlerReverts() public {
        ERC7683Types.GaslessCrossChainOrder memory g;
        bytes memory empty;
        RolloverTypes.RolloverIntent memory intent;
        vm.expectRevert(LibRolloverOrder__BadOrderType.selector);
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
