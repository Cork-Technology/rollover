// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../base/BaseTest.sol";
import { MockEVC } from "../mocks/MockEVC.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { EvcRolloverAdapter, IEVC } from "src/EvcRolloverAdapter.sol";
import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import { ISettler } from "src/interfaces/settlers/ISettler.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

import { ISignatureTransfer } from "permit2/interfaces/ISignatureTransfer.sol";
import { EvcRolloverAdapter__ZeroController } from "src/errors/EvcRolloverAdapterErrors.sol";

/// @notice EvcRolloverAdapter invariants — ZeroEvc constructor guard and dispatch hygiene.
contract EvcAdapterInvariantsTest is BaseTest {
    /// @notice Evc mock.
    MockEVC internal evcMock;

    /// @notice Evc adapter.
    EvcRolloverAdapter internal evcAdapter;

    /// @inheritdoc BaseTest
    function setUp() public override {
        super.setUp();
        evcMock = new MockEVC();
        evcAdapter = new EvcRolloverAdapter(
            IEVC(address(evcMock)),
            address(0xCAFEEFEE),
            ISettler(address(settler)),
            ISettler(address(partialSettler)),
            ISignatureTransfer(address(permit2))
        );
    }

    /// @notice reverts when evc adapter without evc context reverts.
    function testRevert_evcAdapterWithoutEvcContextReverts() public {
        evcMock.setFrame(address(0), false, address(0xCAFEEFEE));
        ERC7683Types.GaslessCrossChainOrder memory g;
        bytes memory empty;
        RolloverTypes.RolloverIntent memory intent;
        vm.expectRevert();
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

    /// @notice adapter balance unchanged after revert.
    function test_adapterBalanceUnchangedAfterRevert() public {
        evcMock.setFrame(address(0), false, address(0xCAFEEFEE));
        ERC7683Types.GaslessCrossChainOrder memory g;
        bytes memory empty;
        RolloverTypes.RolloverIntent memory intent;
        uint256 preBal = srcCst.balanceOf(address(evcAdapter));
        vm.expectRevert();
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
                fillerSrcCst: 10e18,
                minDstPerSrc: 0,
                intent: intent,
                premium: 0,
                fillerAuthSig: "",
                nonce: 0,
                deadline: 0,
                fundingSig: ""
            })
        );
        assertEq(
            srcCst.balanceOf(address(evcAdapter)), preBal, "F6: revert leaves balance unchanged"
        );
    }

    /// @notice revert path leaves no stuck allowance.
    function test_revertPathLeavesNoStuckAllowance() public {
        evcMock.setFrame(address(0xDEAD), true, address(0xCAFEEFEE));
        ERC7683Types.GaslessCrossChainOrder memory g;
        bytes memory empty;
        RolloverTypes.RolloverIntent memory intent;

        uint256 preAllowance = srcCst.allowance(address(evcAdapter), address(settler));
        vm.expectRevert();
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

        assertEq(
            srcCst.allowance(address(evcAdapter), address(settler)),
            preAllowance,
            "F7b: revert leaves no leftover allowance"
        );
    }

    /// @notice reverts when on behalf mismatch prevents execution.
    function testRevert_onBehalfMismatchPreventsExecution() public {
        evcMock.setFrame(address(0xCAFE), true, address(0xCAFEEFEE));
        ERC7683Types.GaslessCrossChainOrder memory g;
        bytes memory empty;
        RolloverTypes.RolloverIntent memory intent;

        vm.expectRevert();
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

    /// @notice controller set at deployment and immutable.
    function test_controllerSetAtDeploymentAndImmutable() public view {
        assertEq(evcAdapter.CONTROLLER(), address(0xCAFEEFEE));
    }

    /// @notice reverts when zero controller construction reverts.
    function testRevert_zeroControllerConstructionReverts() public {
        vm.expectRevert(EvcRolloverAdapter__ZeroController.selector);
        new EvcRolloverAdapter(
            IEVC(address(evcMock)),
            address(0),
            ISettler(address(settler)),
            ISettler(address(partialSettler)),
            ISignatureTransfer(address(permit2))
        );
    }

    /// @notice evc adapter execute happy path consumes allowances.
    function test_evcAdapterExecuteHappyPathConsumesAllowances() public {
        (address subaccount, uint256 subPk) = _makeEvcAccount("evcSubaccount", address(evcMock));
        uint256 fillerSrc = 1_000e18;
        uint256 premiumAmount = 10e18;
        uint256 dstMinted = 900e18;

        _redeployAdapterControllerSelf(subaccount);
        phoenixPool.setPartialDeposit(dstCst.poolId(), dstMinted, fillerSrc);

        EvcRolloverAdapter.EvcRolloverJob memory job =
            _buildHappyPathJob(subaccount, fillerSrc, premiumAmount);
        job.fundingSig = _signFundingSig(job, subPk, SettlerMode.Exact);

        evcMock.setFrame(subaccount, true, evcAdapter.CONTROLLER());

        bytes32 orderId = settler.resolveFor(job.order, "").orderId;

        evcMock.proxy(
            subaccount,
            evcAdapter.CONTROLLER(),
            address(evcAdapter),
            abi.encodeCall(EvcRolloverAdapter.execute, (job))
        );

        assertEq(
            dstCst.balanceOf(subaccount),
            dstMinted,
            "exact EVC execute settles dstCST to the subaccount"
        );
        assertEq(
            uint8(settler.orderStatus(orderId)),
            uint8(RolloverTypes.OrderStatus.Settled),
            "exact EVC execute terminally settles the order"
        );

        assertEq(
            premiumToken.allowance(subaccount, address(evcAdapter)),
            0,
            "F2 EVC: subaccount -> EvcRolloverAdapter premium allowance must be consumed"
        );

        assertEq(
            premiumToken.allowance(address(evcAdapter), address(settler)),
            0,
            "F2 EVC: EvcRolloverAdapter -> Settler premium allowance must be zeroed"
        );
        assertEq(
            premiumToken.allowance(address(evcAdapter), address(partialSettler)),
            0,
            "F2 EVC: EvcRolloverAdapter -> PartialSettler premium allowance must stay zero"
        );
    }

    /// @notice evc adapter atomic fill accepts delegated exclusive-filler auth.
    function test_evcAdapterExecuteWithDelegatedExclusiveFillerAuthSucceeds() public {
        (address subaccount, uint256 subPk) =
            _makeEvcAccount("evcDelegatedSubaccount", address(evcMock));
        (address exclusiveFiller, uint256 exclusivePk) = makeAddrAndKey("evcExclusiveFiller");
        uint256 fillerSrc = 1_000e18;
        uint256 premiumAmount = 10e18;
        uint256 dstMinted = 900e18;

        _redeployAdapterControllerSelf(subaccount);
        phoenixPool.setPartialDeposit(dstCst.poolId(), dstMinted, fillerSrc);

        (EvcRolloverAdapter.EvcRolloverJob memory job, bytes32 orderId) = _buildDelegatedExclusiveJob(
            subaccount, subPk, exclusiveFiller, exclusivePk, fillerSrc, premiumAmount
        );

        evcMock.setFrame(subaccount, true, evcAdapter.CONTROLLER());
        evcMock.proxy(
            subaccount,
            evcAdapter.CONTROLLER(),
            address(evcAdapter),
            abi.encodeCall(EvcRolloverAdapter.execute, (job))
        );

        assertEq(dstCst.balanceOf(subaccount), dstMinted);
        assertEq(uint8(settler.orderStatus(orderId)), uint8(RolloverTypes.OrderStatus.Settled));
    }

    /// @notice evc adapter partial execution consumes allowances and clears both settler approvals.
    function test_evcAdapterPartialExecuteHappyPathConsumesAllowances() public {
        (address subaccount, uint256 subPk) =
            _makeEvcAccount("evcSubaccountPartial", address(evcMock));
        uint256 fillerSrc = 1_000e18;
        uint256 premiumAmount = 10e18;
        uint256 dstMinted = 900e18;

        _redeployAdapterControllerSelf(subaccount);
        phoenixPool.setPartialDeposit(dstCst.poolId(), dstMinted, fillerSrc);

        EvcRolloverAdapter.EvcRolloverJob memory job =
            _buildHappyPathJobForMode(SettlerMode.Partial, subaccount, fillerSrc, premiumAmount);
        job.fundingSig = _signFundingSig(job, subPk, SettlerMode.Partial);

        evcMock.setFrame(subaccount, true, evcAdapter.CONTROLLER());

        bytes32 orderId = partialSettler.resolveFor(job.order, "").orderId;

        evcMock.proxy(
            subaccount,
            evcAdapter.CONTROLLER(),
            address(evcAdapter),
            abi.encodeCall(EvcRolloverAdapter.executePartial, (job))
        );

        assertEq(
            dstCst.balanceOf(subaccount),
            dstMinted,
            "partial EVC execute settles dstCST to the subaccount"
        );
        // INV-FSM-TERMINAL-WRITE-COMPLETE — EVC adapter consumes the full partial order
        // and drains the only filler residual in the same tx, so the order settles.
        assertEq(
            uint8(partialSettler.orderStatus(orderId)),
            uint8(RolloverTypes.OrderStatus.Settled),
            "partial EVC per-filler settle promotes after full aggregate consumption"
        );
        // EvcAdapter routed `subaccount`; subFiller=bytes32(subaccount).
        assertTrue(
            partialSettler.fillerSlotAccountingOf(
                orderId, address(evcAdapter), bytes32(uint256(uint160(subaccount)))
            )
            .settled
        );
        assertEq(partialSettler.rolloverAccountingOf(orderId).dstCstEscrowed, 0);

        assertEq(
            premiumToken.allowance(subaccount, address(evcAdapter)),
            0,
            "F2 EVC partial: subaccount premium allowance must be consumed"
        );
        assertEq(srcCst.allowance(address(evcAdapter), address(partialSettler)), 0);
        assertEq(premiumToken.allowance(address(evcAdapter), address(partialSettler)), 0);
        assertEq(srcCst.allowance(address(evcAdapter), address(settler)), 0);
        assertEq(premiumToken.allowance(address(evcAdapter), address(settler)), 0);
    }

    /// @notice _redeploy adapter controller self.
    function _redeployAdapterControllerSelf(address subaccount) private {
        evcMock.setFrame(subaccount, true, address(0xCAFEEFEE));
        evcAdapter = new EvcRolloverAdapter(
            IEVC(address(evcMock)),
            address(evcAdapter),
            ISettler(address(settler)),
            ISettler(address(partialSettler)),
            ISignatureTransfer(address(permit2))
        );
        evcAdapter = new EvcRolloverAdapter(
            IEVC(address(evcMock)),
            address(evcAdapter),
            ISettler(address(settler)),
            ISettler(address(partialSettler)),
            ISignatureTransfer(address(permit2))
        );
        evcMock.setFrame(subaccount, true, evcAdapter.CONTROLLER());
    }

    /// @notice _build happy path job.
    function _buildHappyPathJob(address subaccount, uint256 fillerSrc, uint256 premiumAmount)
        private
        view
        returns (EvcRolloverAdapter.EvcRolloverJob memory job)
    {
        return _buildHappyPathJobForMode(SettlerMode.Exact, subaccount, fillerSrc, premiumAmount);
    }

    function _buildDelegatedExclusiveJob(
        address subaccount,
        uint256 subPk,
        address exclusiveFiller,
        uint256 exclusivePk,
        uint256 fillerSrc,
        uint256 premiumAmount
    ) private view returns (EvcRolloverAdapter.EvcRolloverJob memory job, bytes32 orderId) {
        RolloverTypes.OrderData memory orderData =
            _happyPathOrderData(SettlerMode.Exact, fillerSrc, premiumAmount);
        orderData.exclusiveFiller = exclusiveFiller;
        RolloverTypes.RolloverIntent memory intent = _happyPathIntent(orderData, fillerSrc);

        job = _buildHappyPathJob(subaccount, fillerSrc, premiumAmount);
        job.order = _gasless(orderData);
        job.userSig = _signOrder(cptHolderPk, orderData);
        job.intent = intent;
        job.nonce = uint256(keccak256(abi.encode("evcDelegatedExclusive", subaccount)));

        orderId = _orderDigest(orderData);
        bytes32 subFiller = bytes32(uint256(uint160(subaccount)));
        job.fillerAuthSig =
            _signFillerAuthFor(address(settler), exclusivePk, orderId, subaccount, subFiller);
        job.fundingSig =
            _signPermit2WitnessForJob(job, subPk, address(evcAdapter), address(settler), orderData);
    }

    /// @notice _build happy path job for mode.
    function _buildHappyPathJobForMode(
        SettlerMode mode,
        address subaccount,
        uint256 fillerSrc,
        uint256 premiumAmount
    ) private view returns (EvcRolloverAdapter.EvcRolloverJob memory job) {
        RolloverTypes.OrderData memory orderData =
            _happyPathOrderData(mode, fillerSrc, premiumAmount);
        RolloverTypes.RolloverIntent memory intent = _happyPathIntent(orderData, fillerSrc);

        job.settler = _settlerForMode(mode);
        job.order = _gasless(orderData);
        job.userSig = _signOrder(cptHolderPk, orderData);
        job.subaccount = subaccount;
        job.fundingAccount = subaccount;
        job.recipient = subaccount;
        job.srcCst = IERC20(address(srcCst));
        job.premiumToken = IERC20(address(premiumToken));
        job.fillerSrcCst = fillerSrc;
        job.minDstPerSrc = 0;
        job.intent = intent;
        job.premium = premiumAmount;
        job.nonce = uint256(keccak256(abi.encode(subaccount, fillerSrc, mode)));
        job.deadline = block.timestamp + 1 hours;
    }

    function _happyPathOrderData(
        SettlerMode mode,
        uint256 fillerSrc,
        uint256 /*premiumAmount*/
    )
        private
        view
        returns (RolloverTypes.OrderData memory orderData)
    {
        orderData = _orderForMode(mode);
        orderData.orderSize = fillerSrc;
        orderData.rolloverParams.minCaReceived = 0;
        orderData.rolloverParams.minSharesOut = 0;
        orderData.minPremiumPerShare = 1;
        // Compute intent hash for binding the orderData ↔ intent loop.
        RolloverTypes.RolloverIntent memory intent = _happyPathIntentNoDigest(fillerSrc);
        orderData.rolloverIntentHash = _zeroDigestHash(intent);
    }

    function _happyPathIntent(RolloverTypes.OrderData memory orderData, uint256 fillerSrc)
        private
        view
        returns (RolloverTypes.RolloverIntent memory intent)
    {
        intent = _happyPathIntentNoDigest(fillerSrc);
        intent.orderDigest = _orderDigest(orderData);
    }

    function _happyPathIntentNoDigest(uint256 fillerSrc)
        private
        view
        returns (RolloverTypes.RolloverIntent memory intent)
    {
        RolloverTypes.Call[] memory rolloverHooks = new RolloverTypes.Call[](1);
        rolloverHooks[0] = _hook(
            address(sourceSrcCptModule),
            abi.encodeWithSignature("execute(address,uint256)", address(srcCpt), fillerSrc)
        );
        RolloverTypes.Call[] memory empty = new RolloverTypes.Call[](0);
        RolloverTypes.Call[] memory postHooks = new RolloverTypes.Call[](1);
        postHooks[0] = _hook(
            address(consumeDstCptModule),
            abi.encodeWithSignature("execute(address)", address(dstCpt))
        );
        intent = _intentWithHooks(rolloverContract, bytes32(0), rolloverHooks, empty, postHooks);
    }

    function _signFundingSig(
        EvcRolloverAdapter.EvcRolloverJob memory job,
        uint256 ownerPk,
        SettlerMode mode
    ) private view returns (bytes memory) {
        RolloverTypes.OrderData memory orderData =
            _happyPathOrderData(mode, job.fillerSrcCst, job.premium);
        return _signPermit2WitnessForJob(
            job, ownerPk, address(evcAdapter), _settlerAddressForMode(mode), orderData
        );
    }
}
