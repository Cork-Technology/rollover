// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { MockEVC } from "../../mocks/MockEVC.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Vm } from "forge-std/Vm.sol";
import { EvcRolloverAdapter, IEVC } from "src/EvcRolloverAdapter.sol";
import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import { ISettler } from "src/interfaces/settlers/ISettler.sol";
import { LibSettlerHashing } from "src/libraries/LibSettlerHashing.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

import { ISignatureTransfer } from "permit2/interfaces/ISignatureTransfer.sol";
import {
    EvcRolloverAdapter__UnknownSettler,
    EvcRolloverAdapter__ZeroFundingAccount,
    EvcRolloverAdapter__ZeroRecipient
} from "src/errors/EvcRolloverAdapterErrors.sol";

/// @notice MockPartialPullSettler — pins EvcRolloverAdapterCoverage behaviour for the Cork Rollover suite.
contract MockPartialPullSettler {
    /// @notice Premium token.
    /// @return premiumToken Stored premium token value.
    address public premiumToken;
    /// @notice Partial premium.
    /// @return partialPremium Stored partial premium value.

    uint256 public partialPremium;
    /// @notice Sink.
    /// @return sink Stored sink value.

    address public sink;
    /// @notice Rollover min dst per src.
    /// @return rolloverMinDstPerSrc Stored rollover min dst per src value.

    uint256 public rolloverMinDstPerSrc;
    /// @notice Premium min dst per src.
    /// @return premiumMinDstPerSrc Stored premium min dst per src value.

    uint256 public premiumMinDstPerSrc;
    /// @notice Produced.
    /// @return produced Stored produced value.

    uint256 public produced;
    /// @notice Premium forwarded.
    /// @return premiumForwarded Stored premium forwarded value.

    uint256 public premiumForwarded;

    /// @notice Configure partial pull.
    /// @param token_ Token contract.
    /// @param partial_ Whether the order uses partial-fill mode.
    /// @param sink_ Sink address.

    // forge-lint: disable-next-line(missing-zero-check)
    function configurePartialPull(address token_, uint256 partial_, address sink_) external {
        premiumToken = token_;
        partialPremium = partial_;
        sink = sink_;
    }
    /// @notice Sets produced.
    /// @param produced_ Produced amount.

    function setProduced(uint256 produced_) external {
        produced = produced_;
    }

    /// @notice Domain separator.
    /// @return Return value.

    // forge-lint: disable-next-line(mixed-case-function)
    function DOMAIN_SEPARATOR() external pure returns (bytes32) {
        return bytes32(0);
    }

    /// @notice Stub orderStatus consumed by the adapter's conditional-openFor guard.
    ///         Returns `0` (None) so the adapter always calls `openFor` (existing
    ///         coverage matches the unconditional-openFor expectation).
    /// @param orderDigest_ Ignored order digest.
    /// @return Returns the `None` status.
    function orderStatus(bytes32 orderDigest_) external pure returns (uint8) {
        orderDigest_;
        return 0;
    }

    /// @notice Filler dst produced of.
    /// @param orderDigest_ Ignored order digest.
    /// @param filler_ Ignored filler address.
    /// @return Return value.

    function fillerDstProducedOf(bytes32 orderDigest_, address filler_)
        external
        view
        returns (uint256)
    {
        orderDigest_;
        filler_;
        return produced;
    }

    /// @notice 3-arg overload — subFiller dimension (ignored).
    /// @param orderDigest_ Ignored order digest.
    /// @param filler_ Ignored filler address.
    /// @param subFiller_ Ignored sub-filler id.
    /// @return Configured dstProduced value.
    function fillerDstProducedOf(bytes32 orderDigest_, address filler_, bytes32 subFiller_)
        external
        view
        returns (uint256)
    {
        orderDigest_;
        filler_;
        subFiller_;
        return produced;
    }
    /// @notice Open for.
    /// @param order_ Ignored order envelope.
    /// @param signature_ Ignored signature bytes.
    /// @param originData_ Ignored origin data.

    function openFor(
        ERC7683Types.GaslessCrossChainOrder calldata order_,
        bytes calldata signature_,
        bytes calldata originData_
    ) external pure {
        order_;
        signature_;
        originData_;
    }

    /// @notice Resolve for.
    /// @param order Order envelope.
    /// @param originData_ Ignored origin data.
    /// @return r Computed result.
    function resolveFor(
        ERC7683Types.GaslessCrossChainOrder calldata order,
        bytes calldata originData_
    ) external pure returns (ERC7683Types.ResolvedCrossChainOrder memory r) {
        order;
        originData_;
        r.orderId = bytes32(uint256(0xCAFEC0DE));
    }

    /// @notice Fill.
    /// @param orderId Canonical order id (recomputed from the order envelope).
    /// @param originData ERC-7683 origin-side data (encoded order envelope).
    /// @param fillerData ERC-7683 filler-side data (encoded fill payload).

    /// @notice Under atomic-fill the adapter sends an ATOMIC_TAG=255 envelope:
    ///         `(uint8 tag, bytes rolloverLeg, uint256 premiumCap, bytes cptHolderSig)`.
    ///         The mock decodes the rollover leg and records its minDstPerSrc,
    ///         then pulls the configured `requiredPremium` from `msg.sender` (the adapter,
    ///         which has already pulled `premium` from the user and approved `premium` to
    ///         this mock — see `configurePartialPull`).
    function fill(bytes32 orderId, bytes calldata originData, bytes calldata fillerData) external {
        orderId;
        originData;
        (, bytes memory rolloverLeg,,) = abi.decode(fillerData, (uint8, bytes, uint256, bytes));
        (,,,,,, uint256 rolloverMin,,,) = abi.decode(
            rolloverLeg,
            (
                uint8,
                uint256,
                uint256,
                address,
                address,
                RolloverTypes.RolloverIntent,
                uint256,
                bytes,
                bytes32,
                bytes
            )
        );
        // Atomic premium has no separate envelope segment.
        rolloverMinDstPerSrc = rolloverMin;
        premiumMinDstPerSrc = 0;
        premiumForwarded = partialPremium;
        if (partialPremium > 0) {
            require(
                IERC20(premiumToken).transferFrom(msg.sender, sink, partialPremium),
                "MockPartialPullSettler: transferFrom failed"
            );
        }
    }
}

/// @notice EvcRolloverAdapterCoverageTest — pins EvcRolloverAdapterCoverage behaviour for the Cork Rollover suite.
contract EvcRolloverAdapterCoverageTest is BaseTest {
    /// @notice Event topic used to detect adapter funding pulls in logs.
    bytes32 private constant ADAPTER_FUNDING_PULLED_TOPIC = keccak256(
        "AdapterFundingPulled(bytes32,address,address,bytes32,address,uint256,address)"
    );
    /// @notice Event topic used to detect adapter tail refunds in logs.
    bytes32 private constant ADAPTER_TAIL_REFUNDED_TOPIC =
        keccak256("AdapterTailRefunded(bytes32,address,address,bytes32,address,uint256)");

    /// @notice Evc mock.
    MockEVC internal evcMock;
    /// @notice Evc adapter.

    EvcRolloverAdapter internal evcAdapter;
    /// @notice Mock settler.

    MockPartialPullSettler internal mockSettler;
    /// @notice Subaccount.

    address internal subaccount;
    /// @notice Subaccount private key used to sign Permit2 witness for funding.
    uint256 internal subaccountPk;
    /// @notice Adapter controller cached for proxy helpers (avoids staticcalls after expectRevert).
    address internal controller;
    /// @notice Emitted on transfer.
    /// @param from Source address.
    /// @param to Destination address.
    /// @param value Numeric value.

    event Transfer(address indexed from, address indexed to, uint256 value);
    /// @notice Test fixture setup.

    function setUp() public override {
        super.setUp();
        evcMock = new MockEVC();
        mockSettler = new MockPartialPullSettler();
        evcAdapter = new EvcRolloverAdapter(
            IEVC(address(evcMock)),
            address(0xC011704),
            ISettler(address(mockSettler)),
            ISettler(address(mockSettler)),
            ISignatureTransfer(address(permit2))
        );

        (subaccount, subaccountPk) = makeAddrAndKey("evcSubaccount");
        evcMock.setAccountOwner(subaccount, subaccount);
        vm.startPrank(subaccount);
        srcCst.approve(address(permit2), type(uint256).max);
        premiumToken.approve(address(permit2), type(uint256).max);
        vm.stopPrank();
        controller = evcAdapter.CONTROLLER();
        vm.label(address(evcMock), "mockEVC");
        vm.label(address(evcAdapter), "evcAdapter");
        vm.label(address(mockSettler), "mockPartialPullSettler");
        vm.label(subaccount, "subaccount");
    }

    /// @dev Drive `evcAdapter.execute(job)` through the EVC proxy with the subaccount
    ///      wired as the on-behalf-of frame.
    function _proxyExecute(EvcRolloverAdapter.EvcRolloverJob memory job, address onBehalf)
        internal
    {
        evcMock.proxy(
            onBehalf,
            controller,
            address(evcAdapter),
            abi.encodeCall(EvcRolloverAdapter.execute, (job))
        );
    }

    /// @dev Partial-mode variant of `_proxyExecute`.
    function _proxyExecutePartial(EvcRolloverAdapter.EvcRolloverJob memory job, address onBehalf)
        internal
    {
        evcMock.proxy(
            onBehalf,
            controller,
            address(evcAdapter),
            abi.encodeCall(EvcRolloverAdapter.executePartial, (job))
        );
    }

    function _adapterOrder(bool allowPartial)
        internal
        view
        returns (
            ERC7683Types.GaslessCrossChainOrder memory g,
            RolloverTypes.OrderData memory orderData
        )
    {
        orderData = _baseOrder();
        if (allowPartial) {
            orderData = _usePartialSettler(orderData);
        } else {
            orderData.allowPartialFills = false;
        }
        g = _gasless(orderData);
    }

    /// @dev Sign Permit2 witness against the MockPartialPullSettler's zero
    ///      domain separator. Caller seeds `job.nonce` + `job.deadline` first.
    function _signMockFunding(
        EvcRolloverAdapter.EvcRolloverJob memory job,
        RolloverTypes.OrderData memory orderData
    ) internal view returns (bytes memory) {
        return _signPermit2WitnessForJobWithSep(
            job, subaccountPk, address(evcAdapter), bytes32(0), orderData
        );
    }

    /// @notice Build a syntactically valid exact adapter job for funding precondition tests.
    /// @param g Gasless order envelope.
    /// @return job Adapter job with a nonempty placeholder funding signature.
    function _fundingPrecheckJob(ERC7683Types.GaslessCrossChainOrder memory g)
        internal
        view
        returns (EvcRolloverAdapter.EvcRolloverJob memory job)
    {
        RolloverTypes.RolloverIntent memory intent;
        job = EvcRolloverAdapter.EvcRolloverJob({
            settler: ISettler(address(mockSettler)),
            order: g,
            userSig: "",
            subaccount: subaccount,
            fundingAccount: subaccount,
            recipient: subaccount,
            srcCst: IERC20(address(srcCst)),
            premiumToken: IERC20(address(premiumToken)),
            fillerSrcCst: 0,
            minDstPerSrc: 0,
            intent: intent,
            premium: 0,
            fillerAuthSig: "",
            nonce: 0,
            deadline: block.timestamp + 1 hours,
            fundingSig: hex"01"
        });
    }

    function _topicOf(address value) private pure returns (bytes32) {
        return bytes32(uint256(uint160(value)));
    }

    function _hasAdapterFundingPulledLog(
        Vm.Log[] memory logs,
        bytes32 orderDigest,
        address subaccount_,
        address fundingAccount,
        bytes32 subFiller,
        address token,
        uint256 amount,
        address recipient
    ) private view returns (bool) {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter != address(evcAdapter) || logs[i].topics.length != 4
                    || logs[i].topics[0] != ADAPTER_FUNDING_PULLED_TOPIC
                    || logs[i].topics[1] != orderDigest
                    || logs[i].topics[2] != _topicOf(subaccount_)
                    || logs[i].topics[3] != _topicOf(fundingAccount)
            ) {
                continue;
            }

            (bytes32 loggedSubFiller, address loggedToken, uint256 loggedAmount, address loggedTo) =
                abi.decode(logs[i].data, (bytes32, address, uint256, address));
            if (
                loggedSubFiller == subFiller && loggedToken == token && loggedAmount == amount
                    && loggedTo == recipient
            ) {
                return true;
            }
        }
        return false;
    }

    function _hasAdapterTailRefundedLog(
        Vm.Log[] memory logs,
        bytes32 orderDigest,
        address subaccount_,
        address recipient,
        bytes32 subFiller,
        address token,
        uint256 amount
    ) private view returns (bool) {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter != address(evcAdapter) || logs[i].topics.length != 4
                    || logs[i].topics[0] != ADAPTER_TAIL_REFUNDED_TOPIC
                    || logs[i].topics[1] != orderDigest
                    || logs[i].topics[2] != _topicOf(subaccount_)
                    || logs[i].topics[3] != _topicOf(recipient)
            ) {
                continue;
            }

            (bytes32 loggedSubFiller, address loggedToken, uint256 loggedAmount) =
                abi.decode(logs[i].data, (bytes32, address, uint256));
            if (loggedSubFiller == subFiller && loggedToken == token && loggedAmount == amount) {
                return true;
            }
        }
        return false;
    }

    function _assertAdapterL05Provenance(
        Vm.Log[] memory logs,
        bytes32 orderDigest,
        uint256 fillerSrcCst,
        uint256 premium,
        uint256 expectedResidual
    ) private view {
        bytes32 subFiller = bytes32(uint256(uint160(subaccount)));
        assertTrue(
            _hasAdapterFundingPulledLog(
                logs,
                orderDigest,
                subaccount,
                subaccount,
                subFiller,
                address(srcCst),
                fillerSrcCst,
                subaccount
            ),
            "L-05: adapter srcCST funding pull provenance event missing"
        );
        assertTrue(
            _hasAdapterFundingPulledLog(
                logs,
                orderDigest,
                subaccount,
                subaccount,
                subFiller,
                address(premiumToken),
                premium,
                subaccount
            ),
            "L-05: adapter premium funding pull provenance event missing"
        );
        assertTrue(
            _hasAdapterTailRefundedLog(
                logs, orderDigest, subaccount, subaccount, subFiller, address(srcCst), fillerSrcCst
            ),
            "L-05: adapter srcCST tail refund provenance event missing"
        );
        assertTrue(
            _hasAdapterTailRefundedLog(
                logs,
                orderDigest,
                subaccount,
                subaccount,
                subFiller,
                address(premiumToken),
                expectedResidual
            ),
            "L-05: adapter premium tail refund provenance event missing"
        );
    }

    /// @notice Pins behaviour: execute Reverts On Zero Settler.
    function testRevert_executeRevertsOnZeroSettler() public {
        evcMock.setFrame(subaccount, true, controller);

        (ERC7683Types.GaslessCrossChainOrder memory g,) = _adapterOrder(false);
        bytes memory empty;
        RolloverTypes.RolloverIntent memory intent;

        vm.expectRevert(EvcRolloverAdapter__UnknownSettler.selector);
        _proxyExecute(
            EvcRolloverAdapter.EvcRolloverJob({
                settler: ISettler(address(0)),
                order: g,
                userSig: empty,
                subaccount: subaccount,
                fundingAccount: subaccount,
                recipient: subaccount,
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
            }),
            subaccount
        );
    }

    /// @notice Pins behaviour: funding authorization rejects a zero funding account.
    function testRevert_executeRejectsZeroFundingAccount() public {
        evcMock.setFrame(subaccount, true, controller);
        (ERC7683Types.GaslessCrossChainOrder memory g,) = _adapterOrder(false);
        EvcRolloverAdapter.EvcRolloverJob memory job = _fundingPrecheckJob(g);
        job.fundingAccount = address(0);

        vm.expectRevert(EvcRolloverAdapter__ZeroFundingAccount.selector);
        _proxyExecute(job, subaccount);
    }

    /// @notice Pins behaviour: funding authorization rejects a zero recipient.
    function testRevert_executeRejectsZeroRecipient() public {
        evcMock.setFrame(subaccount, true, controller);
        (ERC7683Types.GaslessCrossChainOrder memory g,) = _adapterOrder(false);
        EvcRolloverAdapter.EvcRolloverJob memory job = _fundingPrecheckJob(g);
        job.recipient = address(0);

        vm.expectRevert(EvcRolloverAdapter__ZeroRecipient.selector);
        _proxyExecute(job, subaccount);
    }

    /// @notice Pins behaviour: execute Partial Reverts On Zero Settler.
    function testRevert_executePartialRevertsOnZeroSettler() public {
        evcMock.setFrame(subaccount, true, controller);

        (ERC7683Types.GaslessCrossChainOrder memory g,) = _adapterOrder(true);
        bytes memory empty;
        RolloverTypes.RolloverIntent memory intent;

        vm.expectRevert(EvcRolloverAdapter__UnknownSettler.selector);
        _proxyExecutePartial(
            EvcRolloverAdapter.EvcRolloverJob({
                settler: ISettler(address(0)),
                order: g,
                userSig: empty,
                subaccount: subaccount,
                fundingAccount: subaccount,
                recipient: subaccount,
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
            }),
            subaccount
        );
    }

    /// @notice Pins behaviour: execute Treats Premium As Cap And Refunds Unused Tail.
    function test_executeTreatsPremiumAsCapAndRefundsUnusedTail() public {
        uint256 fillerSrcCst = 11e18;
        uint256 premium = 100e18;
        uint256 requiredPremium = 30e18;
        uint256 expectedResidual = premium - requiredPremium;

        evcMock.setFrame(subaccount, true, controller);
        mockSettler.configurePartialPull(address(premiumToken), requiredPremium, address(0xDEAD));
        mockSettler.setProduced(300e18);

        srcCst.mint(subaccount, fillerSrcCst);
        premiumToken.mint(subaccount, premium);

        (ERC7683Types.GaslessCrossChainOrder memory g, RolloverTypes.OrderData memory orderData) =
            _adapterOrder(false);
        orderData.minPremiumPerShare = 1e17;
        g = _gasless(orderData);
        RolloverTypes.RolloverIntent memory intent;

        uint256 subPre = premiumToken.balanceOf(subaccount);
        uint256 subSrcPre = srcCst.balanceOf(subaccount);
        uint256 adapterPre = premiumToken.balanceOf(address(evcAdapter));

        vm.expectEmit(true, true, false, true, address(premiumToken));
        emit Transfer(address(evcAdapter), subaccount, expectedResidual);

        EvcRolloverAdapter.EvcRolloverJob memory job = EvcRolloverAdapter.EvcRolloverJob({
            settler: ISettler(address(mockSettler)),
            order: g,
            userSig: "",
            subaccount: subaccount,
            fundingAccount: subaccount,
            recipient: subaccount,
            srcCst: IERC20(address(srcCst)),
            premiumToken: IERC20(address(premiumToken)),
            fillerSrcCst: fillerSrcCst,
            minDstPerSrc: 0,
            intent: intent,
            premium: premium,
            fillerAuthSig: "",
            nonce: uint256(keccak256("test_executeTreatsPremiumAsCapAndRefundsUnusedTail")),
            deadline: block.timestamp + 1 hours,
            fundingSig: ""
        });
        job.fundingSig = _signMockFunding(job, orderData);
        bytes32 orderDigest = LibSettlerHashing.computeOrderDigestMemory(orderData, bytes32(0));

        vm.recordLogs();
        _proxyExecute(job, subaccount);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            subPre - premiumToken.balanceOf(subaccount),
            requiredPremium,
            "subaccount premium delta must equal required"
        );
        assertEq(srcCst.balanceOf(subaccount), subSrcPre, "srcCST tail is refunded to subaccount");

        assertEq(
            premiumToken.balanceOf(address(evcAdapter)),
            adapterPre,
            "EvcRolloverAdapter premium balance must be restored to preBal"
        );

        assertEq(
            premiumToken.balanceOf(address(0xDEAD)),
            requiredPremium,
            "mock settler sink received exactly the required premium"
        );
        assertEq(mockSettler.premiumForwarded(), requiredPremium, "adapter forwarded required only");
        assertEq(premiumToken.allowance(address(evcAdapter), address(mockSettler)), 0);
        // Atomic-fill settlement is part of the Settler.fill() frame.
        _assertAdapterL05Provenance(logs, orderDigest, fillerSrcCst, premium, expectedResidual);
    }

    /// @notice Pins behaviour: execute Partial Treats Premium As Cap And Refunds Unused Tail.
    function test_executePartialTreatsPremiumAsCapAndRefundsUnusedTail() public {
        uint256 premium = 100e18;
        uint256 requiredPremium = 30e18;

        evcMock.setFrame(subaccount, true, controller);
        mockSettler.configurePartialPull(address(premiumToken), requiredPremium, address(0xDEAD));
        mockSettler.setProduced(300e18);

        premiumToken.mint(subaccount, premium);

        (ERC7683Types.GaslessCrossChainOrder memory g, RolloverTypes.OrderData memory orderData) =
            _adapterOrder(true);
        orderData.minPremiumPerShare = 1e17;
        g = _gasless(orderData);
        bytes memory userSig;
        RolloverTypes.RolloverIntent memory intent;

        uint256 subPre = premiumToken.balanceOf(subaccount);
        EvcRolloverAdapter.EvcRolloverJob memory job = EvcRolloverAdapter.EvcRolloverJob({
            settler: ISettler(address(mockSettler)),
            order: g,
            userSig: userSig,
            subaccount: subaccount,
            fundingAccount: subaccount,
            recipient: subaccount,
            srcCst: IERC20(address(srcCst)),
            premiumToken: IERC20(address(premiumToken)),
            fillerSrcCst: 0,
            minDstPerSrc: 0,
            intent: intent,
            premium: premium,
            fillerAuthSig: "",
            nonce: uint256(keccak256("test_executePartialTreatsPremiumAsCapAndRefundsUnusedTail")),
            deadline: block.timestamp + 1 hours,
            fundingSig: ""
        });
        job.fundingSig = _signMockFunding(job, orderData);
        _proxyExecutePartial(job, subaccount);

        assertEq(subPre - premiumToken.balanceOf(subaccount), requiredPremium);
        assertEq(premiumToken.balanceOf(address(evcAdapter)), 0);
        assertEq(premiumToken.allowance(address(evcAdapter), address(mockSettler)), 0);
        assertEq(mockSettler.premiumForwarded(), requiredPremium);
        // Atomic-fill settlement is part of the Settler.fill() frame.
    }

    // Deleted: `testRevert_executePremiumCapBelowRequired`.
    // Rationale: Under atomic-fill the adapter no longer checks the premium cap between
    // legs — the envelope-level `premiumCap` is enforced inside the Settler
    // (`Settler__PremiumExceedsCap` in `_atomicPremiumAndSettle`). This test pinned the
    // removed adapter-side check and relied on a `mockSettler` that does not model the
    // atomic dispatcher; the Settler-side equivalent is covered by atomic-fill suites.

    /// @notice Pins behaviour: execute Forwards Rollover Min Dst Per Src And Pads Premium.
    function test_executeForwardsRolloverMinDstPerSrcAndPadsPremium() public {
        uint256 floor = 2e18;
        evcMock.setFrame(subaccount, true, controller);
        mockSettler.configurePartialPull(address(premiumToken), 0, address(0xDEAD));

        (ERC7683Types.GaslessCrossChainOrder memory g, RolloverTypes.OrderData memory orderData) =
            _adapterOrder(false);
        bytes memory userSig;
        RolloverTypes.RolloverIntent memory intent;

        EvcRolloverAdapter.EvcRolloverJob memory job = EvcRolloverAdapter.EvcRolloverJob({
            settler: ISettler(address(mockSettler)),
            order: g,
            userSig: userSig,
            subaccount: subaccount,
            fundingAccount: subaccount,
            recipient: subaccount,
            srcCst: IERC20(address(srcCst)),
            premiumToken: IERC20(address(premiumToken)),
            fillerSrcCst: 0,
            minDstPerSrc: floor,
            intent: intent,
            premium: 0,
            fillerAuthSig: "",
            nonce: uint256(keccak256("test_executeForwardsRolloverMinDstPerSrcAndPadsPremium")),
            deadline: block.timestamp + 1 hours,
            fundingSig: ""
        });
        job.fundingSig = _signMockFunding(job, orderData);
        _proxyExecute(job, subaccount);

        assertEq(mockSettler.rolloverMinDstPerSrc(), floor);
        assertEq(mockSettler.premiumMinDstPerSrc(), 0);
    }
}
