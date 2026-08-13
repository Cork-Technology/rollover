// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Vm } from "forge-std/Vm.sol";
import { BaseFiller } from "src/BaseFiller.sol";
import { BaseSettler } from "src/BaseSettler.sol";
import { ExactSettler as Settler } from "src/ExactSettler.sol";
import { Settler__PremiumExceedsCap } from "src/errors/SettlerErrors.sol";
import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import { IMarketRegistry } from "src/interfaces/external/market-registry/IMarketRegistry.sol";
import { IDefaultCorkController } from "src/interfaces/external/phoenix/IDefaultCorkController.sol";
import { IPoolManager } from "src/interfaces/external/phoenix/IPoolManager.sol";
import { ISettler } from "src/interfaces/settlers/ISettler.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";
import { SettlerTypes } from "src/types/SettlerTypes.sol";
import { FillScaffold } from "test/base/FillScaffold.sol";

/// @notice BaseFillerExactPremiumTest — pins BaseFillerExactPremium behaviour for the Cork Rollover suite.
contract BaseFillerExactPremiumTest is FillScaffold {
    /// @notice Setup struct.
    struct Setup {
        RolloverTypes.OrderData orderData;
        ERC7683Types.GaslessCrossChainOrder g;
        bytes userSig;
        RolloverTypes.RolloverIntent intent;
        bytes cptHolderSig;
        bytes32 orderDigest;
    }

    /// @notice Emitted on premium refunded.
    /// @param orderDigest EIP-712 order digest.
    /// @param filler Filler address.
    /// @param premiumToken Premium token address.
    /// @param amount Token amount (raw units).
    event PremiumRefunded(
        bytes32 indexed orderDigest,
        address indexed filler,
        address indexed premiumToken,
        uint256 amount
    );
    /// @notice Eoa.

    address internal eoa;
    /// @notice Eoa pk.

    uint256 internal eoaPk;
    /// @notice Eoa2.

    address internal eoa2;
    /// @notice Eoa2 pk.

    uint256 internal eoa2Pk;
    /// @notice Test fixture setup.

    function setUp() public override {
        super.setUp();
        (eoa, eoaPk) = makeAddrAndKey("baseFillerEoa");
        (eoa2, eoa2Pk) = makeAddrAndKey("baseFillerEoa2");

        srcCst.mint(eoa, 1_000_000e18);
        premiumToken.mint(eoa, 1_000_000e18);
        srcCst.mint(eoa2, 1_000_000e18);
        premiumToken.mint(eoa2, 1_000_000e18);

        vm.startPrank(eoa);
        srcCst.approve(address(baseFiller), type(uint256).max);
        premiumToken.approve(address(baseFiller), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(eoa2);
        srcCst.approve(address(baseFiller), type(uint256).max);
        premiumToken.approve(address(baseFiller), type(uint256).max);
        vm.stopPrank();
    }

    function _prepare(
        uint256 mpps,
        bool allowPartialFills,
        uint256 fillAmount,
        uint256 dstAmount,
        uint64 nonce
    ) internal view returns (Setup memory s) {
        s.orderData = _baseOrder();
        s.orderData.minPremiumPerShare = mpps;
        s.orderData.allowPartialFills = allowPartialFills;
        if (allowPartialFills) {
            s.orderData = _usePartialSettler(s.orderData);
        }
        s.orderData.orderSize = fillAmount;
        s.orderData.orderSalt = nonce;

        s.intent = _buildIntent(bytes32(0), fillAmount, dstAmount);
        s.orderData.rolloverIntentHash = _zeroDigestHash(s.intent);

        s.orderDigest = _orderDigest(s.orderData);
        s.intent.orderDigest = s.orderDigest;
        s.cptHolderSig = _signOrder(cptHolderPk, s.orderData);

        s.g = _gasless(s.orderData);
        s.userSig = _signOrder(cptHolderPk, s.orderData);
    }

    function _runExecute(
        Setup memory s,
        uint256 fillerSrcCst,
        uint256 premiumCap,
        address fillerEoa
    ) internal {
        vm.prank(fillerEoa);
        baseFiller.execute(
            BaseFiller.FillerJob({
                settler: ISettler(s.orderData.settler),
                order: s.g,
                userSig: s.userSig,
                srcCst: IERC20(address(srcCst)),
                premiumToken: IERC20(address(premiumToken)),
                fillerSrcCst: fillerSrcCst,
                intent: s.intent,
                premiumCap: premiumCap,
                minDstPerSrc: uint256(0),
                fillerAuthSig: ""
            })
        );
    }

    /// @notice Pins behaviour: exact Mode happy Path exact Divisible no Refund.
    function test_exactMode_happyPath_exactDivisible_noRefund() public {
        uint256 fill = 1_000e18;
        uint256 dst = 1_000e18;
        uint256 mpps = 1e16;
        uint256 required = 10e18;
        Setup memory s = _prepare(mpps, false, fill, dst, 1);

        uint256 rolloverContractPremiumPre = premiumToken.balanceOf(rolloverContract);
        uint256 eoaPremiumPre = premiumToken.balanceOf(eoa);

        _runExecute(s, fill, required, eoa);

        assertEq(eoaPremiumPre - premiumToken.balanceOf(eoa), required, "eoa paid exactly required");
        assertEq(
            premiumToken.balanceOf(rolloverContract) - rolloverContractPremiumPre,
            required,
            "rolloverContract received required"
        );
        assertEq(
            premiumToken.balanceOf(address(baseFiller)), 0, "BaseFiller premium frame restored"
        );
    }

    /// @notice Pins behaviour: exact Mode ceil Rounding Edge matches Settler Floor.
    function test_exactMode_ceilRoundingEdge_matchesSettlerFloor() public {
        uint256 fill = 7;
        uint256 dst = 7;
        uint256 mpps = 1e17;
        uint256 required = 1;
        Setup memory s = _prepare(mpps, false, fill, dst, 2);

        uint256 eoaPremiumPre = premiumToken.balanceOf(eoa);

        _runExecute(s, fill, required, eoa);

        assertEq(
            eoaPremiumPre - premiumToken.balanceOf(eoa),
            required,
            "eoa paid exactly the ceil-rounded floor"
        );
    }

    /// @notice Pins behaviour: partial Mode per Filler Ceil Rounded.
    function test_partialMode_perFillerCeilRounded() public {
        uint256 fill = 1_000e18;
        uint256 dst = 1_000e18;
        uint256 mpps = 1e16;
        uint256 required = 10e18;
        Setup memory s = _prepare(mpps, true, fill, dst, 3);

        uint256 eoaPremiumPre = premiumToken.balanceOf(eoa);
        _runExecute(s, fill, required, eoa);

        // Lens views key by `(orderDigest, filler, subFiller)` post-Cand-9. The BaseFiller
        // routed `eoa`'s subaccount, so the rollover record's subFiller is bytes32(eoa).
        assertEq(
            partialSettler.fillerSlotAccountingOf(
                    s.orderDigest, address(baseFiller), bytes32(uint256(uint160(eoa)))
                ).rollover.dstCstProduced,
            dst,
            "partial rollover accounting returns produced for BaseFiller"
        );
        assertEq(dstCst.balanceOf(eoa), dst, "partial BaseFiller execute settles same tx");
        assertTrue(
            partialSettler.fillerSlotAccountingOf(
                s.orderDigest, address(baseFiller), bytes32(uint256(uint160(eoa)))
            )
            .settled
        );
        // INV-FSM-TERMINAL-WRITE-COMPLETE — BaseFiller.execute consumes the full partial
        // order and drains the only filler residual in the same tx, so the order settles.
        assertEq(
            uint8(partialSettler.orderStatus(s.orderDigest)),
            uint8(RolloverTypes.OrderStatus.Settled),
            "partial per-filler settle promotes to Settled after full aggregate consumption"
        );

        assertEq(eoaPremiumPre - premiumToken.balanceOf(eoa), required, "eoa paid required");
    }

    /// @notice Pins behaviour: premium Cap Below Required reverts With Exact Args.
    function testRevert_premiumCapBelowRequired_revertsWithExactArgs() public {
        uint256 fill = 1_000e18;
        uint256 dst = 1_000e18;
        uint256 mpps = 1e16;
        uint256 required = 10e18;
        uint256 cap = 5e18;
        Setup memory s = _prepare(mpps, false, fill, dst, 4);

        // Under atomic-fill the premium-cap check moved from the filler to the Settler:
        // the envelope-level `premiumCap` field is enforced inside `_atomicPremiumAndSettle`.
        vm.expectRevert(abi.encodeWithSelector(Settler__PremiumExceedsCap.selector, cap, required));
        _runExecute(s, fill, cap, eoa);
    }

    /// @notice Pins behaviour: premium Leftover refund emits Premium Refunded.
    function test_premiumLeftover_refund_emitsPremiumRefunded() public {
        uint256 fill = 1_000e18;
        uint256 dst = 1_000e18;
        uint256 mpps = 1e16;
        uint256 required = 10e18;
        uint256 cap = required * 2;
        Setup memory s = _prepare(mpps, false, fill, dst, 5);

        uint256 eoaPremiumPre = premiumToken.balanceOf(eoa);

        vm.expectEmit(true, true, true, true, address(baseFiller));
        emit PremiumRefunded(s.orderDigest, eoa, address(premiumToken), cap - required);
        _runExecute(s, fill, cap, eoa);

        assertEq(eoaPremiumPre - premiumToken.balanceOf(eoa), required, "net debit == required");

        assertEq(premiumToken.balanceOf(address(baseFiller)), 0, "BaseFiller frame restored");
    }

    /// @notice Fuzzes premium debit/refund invariants over bounded exact fills.
    /// @param fill_ Fuzz seed for the exact fill amount.
    /// @param mpps_ Fuzz seed for the signed minimum premium-per-share.
    /// @param slack_ Fuzz seed for premium cap slack above the required premium.
    function testFuzz_exactModePremiumDebitRefundInvariants(
        uint96 fill_,
        uint96 mpps_,
        uint96 slack_
    ) public {
        uint256 fill = bound(uint256(fill_), 1, 100_000e18);
        uint256 mpps = bound(uint256(mpps_), 1, 1e18);
        uint256 required = (fill * mpps + 1e18 - 1) / 1e18;
        uint256 slack = bound(uint256(slack_), 0, 1_000e18);
        uint256 cap = required + slack;
        Setup memory s = _prepare(mpps, false, fill, fill, 7);

        uint256 rolloverContractPremiumPre = premiumToken.balanceOf(rolloverContract);
        uint256 eoaPremiumPre = premiumToken.balanceOf(eoa);

        _runExecute(s, fill, cap, eoa);

        assertEq(eoaPremiumPre - premiumToken.balanceOf(eoa), required, "net debit == required");
        assertEq(
            premiumToken.balanceOf(rolloverContract) - rolloverContractPremiumPre,
            required,
            "rolloverContract received required"
        );
        assertEq(premiumToken.balanceOf(address(baseFiller)), 0, "BaseFiller frame restored");
    }

    /// @notice Pins behaviour: mpps Zero required Zero no Refund Event.
    function test_mppsZero_requiredZero_noRefundEvent() public {
        MockMpps0Settler stub = new MockMpps0Settler();
        stub.setProduced(123);
        BaseFiller stubPinnedFiller = new BaseFiller(
            ISettler(address(stub)),
            ISettler(address(stub)),
            IPoolManager(address(0)),
            IDefaultCorkController(address(0)),
            IMarketRegistry(address(0))
        );

        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.minPremiumPerShare = 0;
        orderData.allowPartialFills = false;
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory userSig;
        RolloverTypes.RolloverIntent memory intent;

        uint256 eoaPremiumPre = premiumToken.balanceOf(eoa);
        uint256 fillerPremiumPre = premiumToken.balanceOf(address(baseFiller));

        vm.recordLogs();
        vm.prank(eoa);
        stubPinnedFiller.execute(
            BaseFiller.FillerJob({
                settler: ISettler(address(stub)),
                order: g,
                userSig: userSig,
                srcCst: IERC20(address(srcCst)),
                premiumToken: IERC20(address(premiumToken)),
                fillerSrcCst: 0,
                intent: intent,
                premiumCap: 0,
                minDstPerSrc: uint256(0),
                fillerAuthSig: ""
            })
        );

        assertEq(premiumToken.balanceOf(eoa), eoaPremiumPre, "eoa premium untouched");
        assertEq(
            premiumToken.balanceOf(address(baseFiller)),
            fillerPremiumPre,
            "BaseFiller frame untouched"
        );

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 sig = keccak256("PremiumRefunded(bytes32,address,address,uint256)");
        for (uint256 i = 0; i < entries.length; ++i) {
            assertTrue(
                entries[i].topics.length == 0 || entries[i].topics[0] != sig,
                "no PremiumRefunded for zero delta"
            );
        }
    }

    /// @notice Pins behaviour: partial rollover accounting is keyed by filler slot.
    function test_fillerSlotAccountingOf_returnsFillerSlotAccounting() public {
        uint256 fill = 500e18;
        uint256 dst = 500e18;
        uint256 mpps = 1e16;
        Setup memory s = _prepare(mpps, true, fill, dst, 6);

        vm.prank(filler);
        srcCst.approve(address(partialSettler), type(uint256).max);
        _openOrder(s.orderData);
        _doRolloverAs(s.orderDigest, s.orderData, s.intent, fill, filler);

        SettlerTypes.FillerRolloverAccounting memory accounting =
        partialSettler.fillerSlotAccountingOf(
            s.orderDigest, filler, bytes32(uint256(uint160(filler)))
        )
        .rollover;
        assertEq(accounting.dstCstProduced, dst, "partial branch reads slot dstCstProduced");

        assertEq(
            partialSettler.fillerSlotAccountingOf(
                    s.orderDigest, address(0xDEAD), bytes32(uint256(uint160(address(0xDEAD))))
                ).rollover.dstCstProduced,
            0,
            "unrelated filler returns zero in partial mode"
        );
    }
}

/// @notice MockMpps0Settler — pins BaseFillerExactPremium behaviour for the Cork Rollover suite.
contract MockMpps0Settler is ISettler {
    /// @notice  produced.
    uint256 internal _produced;
    /// @notice Sets produced.
    /// @param p Generic input.

    function setProduced(uint256 p) external {
        _produced = p;
    }

    /// @inheritdoc ISettler
    // forge-lint: disable-next-line(mixed-case-function)
    function DOMAIN_SEPARATOR() external pure override returns (bytes32) {
        return bytes32(uint256(0xD0));
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
        pure
        override
        returns (ERC7683Types.ResolvedCrossChainOrder memory r)
    {
        order_;
        r.orderId = bytes32(0);
    }

    /// @notice Resolve for.
    /// @param order_ Ignored order envelope.
    /// @param originData_ Ignored origin data.
    /// @return r Computed result.
    function resolveFor(
        ERC7683Types.GaslessCrossChainOrder calldata order_,
        bytes calldata originData_
    ) external pure override returns (ERC7683Types.ResolvedCrossChainOrder memory r) {
        order_;
        originData_;
        r.orderId = bytes32(0);
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

    /// @notice Refund.
    /// @param orderDigest_ Ignored order digest.
    /// @param originData_ Ignored origin data.

    function markExpired(bytes32 orderDigest_, bytes calldata originData_) external pure override {
        orderDigest_;
        originData_;
    }
    /// @notice Cancel.
    /// @param orderDigest_ Ignored order digest.
    /// @param originData_ Ignored origin data.
    /// @param reason_ Ignored cancel reason.

    function cancel(bytes32 orderDigest_, bytes calldata originData_, bytes calldata reason_)
        external
        pure
        override
    {
        orderDigest_;
        originData_;
        reason_;
    }
    /// @notice Order status.
    /// @param orderDigest_ Ignored order digest.
    /// @return Return value.

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
