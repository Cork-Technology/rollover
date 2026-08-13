// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Test } from "forge-std/Test.sol";
import { BaseFiller } from "src/BaseFiller.sol";
import { EvcRolloverAdapter, IEVC } from "src/EvcRolloverAdapter.sol";
import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import { IMarketRegistry } from "src/interfaces/external/market-registry/IMarketRegistry.sol";
import { IDefaultCorkController } from "src/interfaces/external/phoenix/IDefaultCorkController.sol";
import { IPoolManager } from "src/interfaces/external/phoenix/IPoolManager.sol";
import { ISettler } from "src/interfaces/settlers/ISettler.sol";
import { LibRolloverOrder } from "src/libraries/LibRolloverOrder.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { MockEVC } from "test/mocks/MockEVC.sol";

import { ISignatureTransfer } from "permit2/interfaces/ISignatureTransfer.sol";
import { BaseFiller__SettlerMismatch } from "src/errors/BaseFillerErrors.sol";
import {
    EvcRolloverAdapter__FundingSigInvalid,
    EvcRolloverAdapter__SettlerMismatch
} from "src/errors/EvcRolloverAdapterErrors.sol";

/// @notice per-filler refund path is safe against residual accounting regressions.
contract MockNoopSettler is ISettler {
    /// @notice _order id.
    bytes32 internal _orderId;
    /// @notice Sets order id.
    /// @param id Identifier.

    function setOrderId(bytes32 id) external {
        _orderId = id;
    }

    // forge-lint: disable-next-line(mixed-case-function)

    /// @inheritdoc ISettler
    function DOMAIN_SEPARATOR() external pure override returns (bytes32) {
        return bytes32(0);
    }

    /// @inheritdoc ISettler
    function version() external pure override returns (string memory) {
        return "mock";
    }

    /// @inheritdoc ISettler
    function fillerAuthTypehash() external pure override returns (bytes32) {
        return bytes32(0);
    }

    /// @notice On-chain open.
    /// @param order_ Ignored order envelope.
    function open(ERC7683Types.OnchainCrossChainOrder calldata order_) external pure override {
        order_;
    }

    /// @notice Open for.
    /// @param order_ Ignored order envelope.
    /// @param signature_ Ignored signature bytes.
    /// @param originData_ Ignored origin data.

    function openFor(
        ERC7683Types.GaslessCrossChainOrder calldata order_,
        bytes calldata signature_,
        bytes calldata originData_
    ) external pure override {
        order_;
        signature_;
        originData_;
    }

    /// @notice Resolve on-chain order.
    /// @param order_ Ignored order envelope.
    /// @return r Computed result.
    function resolve(ERC7683Types.OnchainCrossChainOrder calldata order_)
        external
        view
        override
        returns (ERC7683Types.ResolvedCrossChainOrder memory r)
    {
        order_;
        r.orderId = _orderId;
    }

    /// @notice Resolve for.
    /// @param order_ Ignored order envelope.
    /// @param originData_ Ignored origin data.
    /// @return r Computed result.
    function resolveFor(
        ERC7683Types.GaslessCrossChainOrder calldata order_,
        bytes calldata originData_
    ) external view override returns (ERC7683Types.ResolvedCrossChainOrder memory r) {
        order_;
        originData_;
        r.orderId = _orderId;
    }
    /// @notice Fill.
    /// @param orderId_ Ignored order id.
    /// @param originData_ Ignored origin data.
    /// @param fillerData_ Ignored filler data.

    function fill(bytes32 orderId_, bytes calldata originData_, bytes calldata fillerData_)
        external
        pure
        override
    {
        orderId_;
        originData_;
        fillerData_;
    }

    /// @inheritdoc ISettler
    function reclaim(
        bytes32 orderId_,
        address defaulterFiller_,
        bytes32 subFiller_,
        bytes calldata originData_
    ) external pure override {
        orderId_;
        defaulterFiller_;
        subFiller_;
        originData_;
    }

    /// @inheritdoc ISettler
    function markExpired(bytes32 orderDigest_, bytes calldata originData_) external pure override {
        orderDigest_;
        originData_;
    }

    /// @inheritdoc ISettler
    function cancel(bytes32 orderDigest_, bytes calldata originData_, bytes calldata reason_)
        external
        pure
        override
    {
        orderDigest_;
        originData_;
        reason_;
    }

    /// @inheritdoc ISettler
    function orderStatus(bytes32 orderDigest_)
        external
        pure
        override
        returns (RolloverTypes.OrderStatus)
    {
        orderDigest_;
        return RolloverTypes.OrderStatus.None;
    }
}

/// @notice per-filler refund path is safe against residual accounting regressions.
contract FillerRefundSafetyTest is Test {
    using SafeERC20 for IERC20;

    /// @notice Base filler.
    BaseFiller internal baseFiller;

    /// @notice Evc adapter.
    EvcRolloverAdapter internal evcAdapter;

    /// @notice Noop settler.
    MockNoopSettler internal noopSettler;

    /// @notice Evc mock.
    MockEVC internal evcMock;

    /// @notice Src cst.
    MockERC20 internal srcCst;

    /// @notice Alice.
    address internal alice = address(0xA11CE);

    /// @notice Bob.
    address internal bob = address(0xB0B);

    /// @notice Stranded.
    uint256 internal constant STRANDED = 100e18;

    /// @notice Alice_pull.
    uint256 internal constant ALICE_PULL = 50e18;
    /// @notice Test fixture setup.

    function setUp() public {
        noopSettler = new MockNoopSettler();
        baseFiller = new BaseFiller(
            ISettler(address(noopSettler)),
            ISettler(address(noopSettler)),
            IPoolManager(address(0)),
            IDefaultCorkController(address(0)),
            IMarketRegistry(address(0))
        );
        evcMock = new MockEVC();
        evcAdapter = new EvcRolloverAdapter(
            IEVC(address(evcMock)),
            address(0xCAFE),
            ISettler(address(noopSettler)),
            ISettler(address(noopSettler)),
            ISignatureTransfer(address(0x000000000022D473030F116dDEE9F6B43aC78BA3))
        );

        srcCst = new MockERC20("srcCST", "SRC", 18);
        IERC20 srcCstErc = IERC20(address(srcCst));

        srcCst.mint(bob, STRANDED * 3);
        vm.startPrank(bob);
        srcCstErc.safeTransfer(address(baseFiller), STRANDED);
        srcCstErc.safeTransfer(address(evcAdapter), STRANDED);
        srcCstErc.safeTransfer(address(evcAdapter), STRANDED);
        vm.stopPrank();

        srcCst.mint(alice, ALICE_PULL * 3);
        vm.startPrank(alice);
        srcCst.approve(address(baseFiller), type(uint256).max);
        srcCst.approve(address(evcAdapter), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice _empty order.
    function _emptyOrder() internal view returns (ERC7683Types.GaslessCrossChainOrder memory g) {
        return _emptyOrder(false);
    }

    /// @notice _empty partial order.
    function _emptyPartialOrder()
        internal
        view
        returns (ERC7683Types.GaslessCrossChainOrder memory g)
    {
        return _emptyOrder(true);
    }

    function _emptyOrder(bool allowPartialFills)
        internal
        view
        returns (ERC7683Types.GaslessCrossChainOrder memory g)
    {
        RolloverTypes.OrderData memory orderData;
        orderData.user = alice;
        orderData.allowPartialFills = allowPartialFills;
        g.user = alice;
        g.originSettler = address(noopSettler);
        g.orderDataType = LibRolloverOrder.CORK_ORDER_DATA_TYPE;
        g.orderData = abi.encode(orderData);
    }

    /// @notice base filler stranded tokens not swept into caller refund.
    function test_baseFillerStrandedTokensNotSweptIntoCallerRefund() public {
        assertEq(
            srcCst.balanceOf(address(baseFiller)),
            STRANDED,
            "precond: BaseFiller holds Bob's stranded tokens"
        );
        uint256 aliceBefore = srcCst.balanceOf(alice);

        bytes memory empty;
        RolloverTypes.RolloverIntent memory intent;
        vm.prank(alice);

        baseFiller.execute(
            BaseFiller.FillerJob({
                settler: ISettler(address(noopSettler)),
                order: _emptyOrder(),
                userSig: empty,
                srcCst: IERC20(address(srcCst)),
                premiumToken: IERC20(address(srcCst)),
                fillerSrcCst: ALICE_PULL,
                intent: intent,
                premiumCap: 0,
                minDstPerSrc: 0,
                fillerAuthSig: ""
            })
        );

        uint256 aliceAfter = srcCst.balanceOf(alice);
        assertEq(aliceAfter, aliceBefore, "Alice net delta zero - only her unused tail returned");

        assertEq(
            srcCst.balanceOf(address(baseFiller)),
            STRANDED,
            "BaseFiller retains Bob's stranded tokens"
        );
    }

    /// @notice reverts when base filler rejects mismatched settler before token pull.
    function testRevert_baseFillerRejectsMismatchedSettlerBeforeTokenPull() public {
        MockNoopSettler maliciousSettler = new MockNoopSettler();
        bytes memory empty;
        RolloverTypes.RolloverIntent memory intent;

        uint256 alicePre = srcCst.balanceOf(alice);
        uint256 fillerPre = srcCst.balanceOf(address(baseFiller));

        vm.startPrank(alice);
        srcCst.approve(address(baseFiller), 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                BaseFiller__SettlerMismatch.selector,
                address(noopSettler),
                address(maliciousSettler)
            )
        );
        baseFiller.execute(
            BaseFiller.FillerJob({
                settler: ISettler(address(maliciousSettler)),
                order: _emptyOrder(),
                userSig: empty,
                srcCst: IERC20(address(srcCst)),
                premiumToken: IERC20(address(srcCst)),
                fillerSrcCst: ALICE_PULL,
                intent: intent,
                premiumCap: 0,
                minDstPerSrc: 0,
                fillerAuthSig: ""
            })
        );
        vm.stopPrank();

        assertEq(srcCst.balanceOf(alice), alicePre, "caller balance unchanged");
        assertEq(srcCst.balanceOf(address(baseFiller)), fillerPre, "wrapper balance unchanged");
        assertEq(srcCst.allowance(address(baseFiller), address(maliciousSettler)), 0);
    }

    /// @notice reverts when evc adapter execute rejects mismatched settler before token pull.
    function testRevert_evcAdapterExecuteRejectsMismatchedSettlerBeforeTokenPull() public {
        evcMock.setFrame(alice, true, address(0xCAFE));
        MockNoopSettler maliciousSettler = new MockNoopSettler();
        bytes memory empty;
        RolloverTypes.RolloverIntent memory intent;

        uint256 alicePre = srcCst.balanceOf(alice);
        uint256 adapterPre = srcCst.balanceOf(address(evcAdapter));

        vm.prank(alice);
        srcCst.approve(address(evcAdapter), 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                EvcRolloverAdapter__SettlerMismatch.selector,
                address(noopSettler),
                address(maliciousSettler)
            )
        );
        evcMock.proxy(
            alice,
            address(0xCAFE),
            address(evcAdapter),
            abi.encodeCall(
                EvcRolloverAdapter.execute,
                (EvcRolloverAdapter.EvcRolloverJob({
                        settler: ISettler(address(maliciousSettler)),
                        order: _emptyPartialOrder(),
                        userSig: empty,
                        subaccount: alice,
                        fundingAccount: alice,
                        recipient: alice,
                        srcCst: IERC20(address(srcCst)),
                        premiumToken: IERC20(address(srcCst)),
                        fillerSrcCst: ALICE_PULL,
                        minDstPerSrc: 0,
                        intent: intent,
                        premium: 0,
                        fillerAuthSig: "",
                        nonce: 0,
                        deadline: 0,
                        fundingSig: ""
                    }))
            )
        );

        assertEq(srcCst.balanceOf(alice), alicePre, "subaccount balance unchanged");
        assertEq(srcCst.balanceOf(address(evcAdapter)), adapterPre, "wrapper balance unchanged");
        assertEq(srcCst.allowance(address(evcAdapter), address(maliciousSettler)), 0);
    }

    /// @notice reverts when evc adapter execute partial rejects mismatched settler before token pull.
    function testRevert_evcAdapterExecutePartialRejectsMismatchedSettlerBeforeTokenPull() public {
        evcMock.setFrame(alice, true, address(0xCAFE));
        MockNoopSettler maliciousSettler = new MockNoopSettler();
        bytes memory empty;
        RolloverTypes.RolloverIntent memory intent;

        uint256 alicePre = srcCst.balanceOf(alice);
        uint256 adapterPre = srcCst.balanceOf(address(evcAdapter));

        vm.prank(alice);
        srcCst.approve(address(evcAdapter), 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                EvcRolloverAdapter__SettlerMismatch.selector,
                address(noopSettler),
                address(maliciousSettler)
            )
        );
        evcMock.proxy(
            alice,
            address(0xCAFE),
            address(evcAdapter),
            abi.encodeCall(
                EvcRolloverAdapter.executePartial,
                (EvcRolloverAdapter.EvcRolloverJob({
                        settler: ISettler(address(maliciousSettler)),
                        order: _emptyPartialOrder(),
                        userSig: empty,
                        subaccount: alice,
                        fundingAccount: alice,
                        recipient: alice,
                        srcCst: IERC20(address(srcCst)),
                        premiumToken: IERC20(address(srcCst)),
                        fillerSrcCst: ALICE_PULL,
                        minDstPerSrc: 0,
                        intent: intent,
                        premium: 0,
                        fillerAuthSig: "",
                        nonce: 0,
                        deadline: 0,
                        fundingSig: ""
                    }))
            )
        );

        assertEq(srcCst.balanceOf(alice), alicePre, "subaccount balance unchanged");
        assertEq(srcCst.balanceOf(address(evcAdapter)), adapterPre, "wrapper balance unchanged");
        assertEq(srcCst.allowance(address(evcAdapter), address(maliciousSettler)), 0);
    }

    /// @notice evc adapter exact path stranded tokens not swept into caller refund.
    function test_evcAdapterExactPathStrandedTokensNotSweptIntoCallerRefund() public {
        evcMock.setFrame(alice, true, address(0xCAFE));

        assertEq(
            srcCst.balanceOf(address(evcAdapter)),
            STRANDED * 2,
            "precond: adapter holds two strands"
        );
        uint256 aliceBefore = srcCst.balanceOf(alice);

        bytes memory empty;
        RolloverTypes.RolloverIntent memory intent;

        // Post-Permit2 funding migration: an unsigned funding-sig path reverts
        // before token movement. Strand-preservation is still the property
        // under test — assertions below verify the strand survives the revert.
        vm.expectRevert(EvcRolloverAdapter__FundingSigInvalid.selector);
        evcMock.proxy(
            alice,
            address(0xCAFE),
            address(evcAdapter),
            abi.encodeCall(
                EvcRolloverAdapter.execute,
                (EvcRolloverAdapter.EvcRolloverJob({
                        settler: ISettler(address(noopSettler)),
                        order: _emptyPartialOrder(),
                        userSig: empty,
                        subaccount: alice,
                        fundingAccount: alice,
                        recipient: alice,
                        srcCst: IERC20(address(srcCst)),
                        premiumToken: IERC20(address(srcCst)),
                        fillerSrcCst: ALICE_PULL,
                        minDstPerSrc: 0,
                        intent: intent,
                        premium: 0,
                        fillerAuthSig: "",
                        nonce: 0,
                        deadline: 0,
                        fundingSig: ""
                    }))
            )
        );

        uint256 aliceAfter = srcCst.balanceOf(alice);
        assertEq(aliceAfter, aliceBefore, "Alice net delta zero - only her unused tail returned");
        assertEq(
            srcCst.balanceOf(address(evcAdapter)), STRANDED * 2, "adapter retains stranded tokens"
        );
    }

    /// @notice evc adapter partial path stranded tokens not swept into caller refund.
    function test_evcAdapterPartialPathStrandedTokensNotSweptIntoCallerRefund() public {
        evcMock.setFrame(alice, true, address(0xCAFE));

        uint256 strandBefore = srcCst.balanceOf(address(evcAdapter));
        uint256 aliceBefore = srcCst.balanceOf(alice);

        bytes memory empty;
        RolloverTypes.RolloverIntent memory intent;

        vm.expectRevert(EvcRolloverAdapter__FundingSigInvalid.selector);
        evcMock.proxy(
            alice,
            address(0xCAFE),
            address(evcAdapter),
            abi.encodeCall(
                EvcRolloverAdapter.executePartial,
                (EvcRolloverAdapter.EvcRolloverJob({
                        settler: ISettler(address(noopSettler)),
                        order: _emptyPartialOrder(),
                        userSig: empty,
                        subaccount: alice,
                        fundingAccount: alice,
                        recipient: alice,
                        srcCst: IERC20(address(srcCst)),
                        premiumToken: IERC20(address(srcCst)),
                        fillerSrcCst: ALICE_PULL,
                        minDstPerSrc: 0,
                        intent: intent,
                        premium: 0,
                        fillerAuthSig: "",
                        nonce: 0,
                        deadline: 0,
                        fundingSig: ""
                    }))
            )
        );

        uint256 aliceAfter = srcCst.balanceOf(alice);
        assertEq(aliceAfter, aliceBefore, "Alice net delta zero - only her unused tail returned");
        assertEq(
            srcCst.balanceOf(address(evcAdapter)),
            strandBefore,
            "adapter retains stranded tokens after partial path"
        );
    }
}
