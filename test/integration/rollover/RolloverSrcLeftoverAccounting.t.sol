// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { FillScaffold } from "../../base/FillScaffold.sol";
import { MockERC20 } from "../../mocks/MockERC20.sol";
import { SrcCstDonateModule } from "../../mocks/modules/SrcCstDonateModule.sol";
import { CorkRolloverContract } from "src/CorkRolloverContract.sol";
import { ExactSettler as Settler } from "src/ExactSettler.sol";
import { Settler__SrcLeftoverExceedsFillAmount } from "src/errors/SettlerErrors.sol";
import { ICorkRolloverContract } from "src/interfaces/rollover/ICorkRolloverContract.sol";
import { IRolloverContractLens } from "src/interfaces/rollover/IRolloverContractLens.sol";
import { LibFillerPayload } from "src/libraries/LibFillerPayload.sol";
import { Typehashes } from "src/libraries/Typehashes.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice rollover srcCST leftover reconciles against the residual and per-filler payout legs.
contract SrcLeftoverFactoryMock {
    /// @notice Dst produced.
    /// @return dstProduced Stored dst produced value.
    uint256 public dstProduced;
    /// @notice Src leftover.
    /// @return srcLeftover Stored src leftover value.

    uint256 public srcLeftover;
    /// @notice Dst token.
    /// @return dstToken Stored dst token value.

    address public dstToken;

    /// @notice Configure.
    /// @param dstToken_ dst token contract.
    /// @param dstProduced_ Reported dstCST produced by the rolloverContract hook.
    /// @param srcLeftover_ srcCST left over after the rolloverContract hook (refundable to filler).

    // forge-lint: disable-next-line(missing-zero-check)
    function configure(address dstToken_, uint256 dstProduced_, uint256 srcLeftover_) external {
        dstToken = dstToken_;
        dstProduced = dstProduced_;
        srcLeftover = srcLeftover_;
    }
    /// @notice Execute intent hooks.
    /// @param rolloverContract_ Ignored rolloverContract address.
    /// @param orderDigest_ Ignored order digest.
    /// @param phase_ Ignored hook phase.
    /// @param intent_ Ignored rollover intent.
    /// @param signature_ Ignored cPT-holder signature bytes.
    /// @param ctx_ Ignored fill context.
    /// @param orderData_ Ignored order data.
    /// @return dstProducedOut Returned dstCST produced amount.
    /// @return srcLeftoverOut Returned srcCST leftover amount.

    function executeIntentHooks(
        address rolloverContract_,
        bytes32 orderDigest_,
        RolloverTypes.HookPhase phase_,
        RolloverTypes.RolloverIntent calldata intent_,
        bytes calldata signature_,
        RolloverTypes.FillContext calldata ctx_,
        RolloverTypes.OrderData calldata orderData_
    ) external returns (uint256 dstProducedOut, uint256 srcLeftoverOut) {
        rolloverContract_;
        orderDigest_;
        phase_;
        intent_;
        signature_;
        ctx_;
        orderData_;
        MockERC20(dstToken).mint(msg.sender, dstProduced);
        return (dstProduced, srcLeftover);
    }
    /// @notice Returns whether deployed rolloverContract.
    /// @param rolloverContract_ Ignored rolloverContract address.
    /// @return Return value.

    function isDeployedRolloverContract(address rolloverContract_) external pure returns (bool) {
        rolloverContract_;
        return true;
    }
}

/// @notice MinimalRolloverContractStub — minimal rolloverContract mock that satisfies the Settler's
///         `INV-USER-IS-ROLLOVER_CONTRACT-OWNER` admission check by exposing a settable `owner()`.
///         Intentionally has no hook execution surface; used by tests that exercise
///         post-admission paths against a synthetic factory.
contract MinimalRolloverContractStub {
    /// @notice CWIA-owner mock. Settable by tests to satisfy the Settler's
    ///         `INV-USER-IS-ROLLOVER_CONTRACT-OWNER` admission check.
    address public owner;

    /// @notice Set the cPT holder returned by the `owner()` view.
    /// @param o Address to mirror as the CWIA-baked owner.
    // Minimal mock mirrors arbitrary owner values supplied by tests.
    // forge-lint: disable-next-line(missing-zero-check)
    function setOwner(address o) external {
        owner = o;
    }
    /// @notice Originating settler.
    /// @return Return value.

    function originatingSettler() external pure returns (address) {
        return address(0);
    }
    /// @notice RolloverContract of.
    /// @param user_ Ignored owner address.
    /// @return Return value.

    function rolloverContractOf(address user_) external pure returns (address) {
        user_;
        return address(0);
    }
    /// @notice Deploy rolloverContract.
    /// @return Return value.

    function deployRolloverContract() external pure returns (address) {
        revert("unused");
    }
    /// @notice Approve settler.
    /// @param settler_ Ignored settler address.

    function approveSettler(address settler_) external pure {
        settler_;
    }
    /// @notice Revoke settler.
    /// @param settler_ Ignored settler address.

    function revokeSettler(address settler_) external pure {
        settler_;
    }
    /// @notice Approved settlers.
    /// @param settler_ Ignored settler address.
    /// @return Return value.

    function approvedSettlers(address settler_) external pure returns (bool) {
        settler_;
        return true;
    }
    /// @notice Order state.
    /// @param rolloverContract_ Ignored rolloverContract address.
    /// @param orderDigest_ Ignored order digest.
    /// @return Return value.

    function orderState(address rolloverContract_, bytes32 orderDigest_)
        external
        pure
        returns (ICorkRolloverContract.RolloverContractOrderState memory)
    {
        rolloverContract_;
        orderDigest_;
        return
            ICorkRolloverContract.RolloverContractOrderState({ rolled: 0, rolloverTerminal: false });
    }
    /// @notice RolloverContract config.
    /// @param rolloverContract_ Ignored rolloverContract address.
    /// @return Return value.

    function rolloverContractConfig(address rolloverContract_)
        external
        pure
        returns (IRolloverContractLens.RolloverContractConfig memory)
    {
        rolloverContract_;
        address[] memory empty;
        return IRolloverContractLens.RolloverContractConfig({
            owner: address(0),
            factory: address(0),
            erc7484Registry: address(0),
            liveTrustThreshold: 0,
            liveTrustAttesters: empty
        });
    }
    /// @notice Premium fired for.
    /// @param rolloverContract_ Ignored rolloverContract address.
    /// @param orderDigest_ Ignored order digest.
    /// @param filler_ Ignored filler address.
    /// @param subFiller_ Ignored sub-filler key.
    /// @return Return value.

    function premiumFiredFor(
        address rolloverContract_,
        bytes32 orderDigest_,
        address filler_,
        bytes32 subFiller_
    ) external pure returns (bool) {
        rolloverContract_;
        orderDigest_;
        filler_;
        subFiller_;
        return false;
    }
}

/// @notice rollover srcCST leftover reconciles against the residual and per-filler payout legs.
contract RolloverSrcLeftoverAccountingTest is FillScaffold {
    /// @notice Src donate.
    SrcCstDonateModule internal srcDonate;

    /// @notice Order.
    uint256 internal constant ORDER = 1_000e18;

    /// @inheritdoc BaseTest
    function setUp() public override {
        super.setUp();
        srcDonate = new SrcCstDonateModule();
        erc7484.setAttestedType(address(srcDonate), Typehashes.MODULE_TYPE_POST_ROLLOVER_HOOK);
        vm.prank(filler);
        srcCst.approve(address(settler), type(uint256).max);
        srcCst.approve(address(partialSettler), type(uint256).max);
    }

    /// @notice _order underfill.
    function _orderUnderfill(uint64 nonce)
        internal
        view
        returns (RolloverTypes.OrderData memory orderData)
    {
        orderData = _baseOrder();
        orderData.allowUnderfill = true;
        orderData.orderSize = ORDER;
        orderData.orderSalt = nonce;
    }

    /// @notice _intent for.
    function _intentFor(bytes32 orderDigest, uint256 actualRolled, uint256 donation)
        internal
        view
        returns (RolloverTypes.RolloverIntent memory)
    {
        RolloverTypes.Call[] memory pre = new RolloverTypes.Call[](1);
        pre[0] = _hook(
            address(sourceSrcCptModule),
            abi.encodeWithSignature("execute(address,uint256)", address(srcCpt), actualRolled)
        );
        uint256 postLen = donation == 0 ? 1 : 2;
        RolloverTypes.Call[] memory post = new RolloverTypes.Call[](postLen);
        post[0] = _hook(
            address(consumeDstCptModule),
            abi.encodeWithSignature("execute(address)", address(dstCpt))
        );
        if (donation != 0) {
            post[1] = _hook(
                address(srcDonate),
                abi.encodeWithSignature(
                    "execute(address,address,uint256)", address(srcCst), address(settler), donation
                )
            );
        }
        return
            _intentWithHooks(rolloverContract, orderDigest, pre, new RolloverTypes.Call[](0), post);
    }

    /// @notice _open with intent.
    function _openWithIntent(
        RolloverTypes.OrderData memory orderData,
        uint256 actualRolled,
        uint256 donation
    )
        internal
        returns (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        )
    {
        RolloverTypes.RolloverIntent memory probe = _intentFor(bytes32(0), actualRolled, donation);
        orderData.rolloverIntentHash = _zeroDigestHash(probe);
        orderDigest = _openOrder(orderData);
        intent = _intentFor(orderDigest, actualRolled, donation);
        cptHolderSig = _signOrder(cptHolderPk, orderData);
    }

    /// @notice underfill refund uses returned src leftover.
    function test_underfillRefundUsesReturnedSrcLeftover() public {
        uint256 actualRolled = 750e18;
        uint256 srcLeftover = ORDER - actualRolled;
        RolloverTypes.OrderData memory orderData = _orderUnderfill(601);
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _openWithIntent(orderData, actualRolled, 0);

        uint256 fillerBefore = srcCst.balanceOf(filler);
        _doRolloverAs(orderDigest, orderData, intent, ORDER, filler);

        assertEq(srcCst.balanceOf(filler), fillerBefore - actualRolled);
        assertEq(settler.rolloverAccountingOf(orderDigest).dstCstProduced, actualRolled);
        assertEq(srcCst.balanceOf(address(settler)), 0, "leftover forwarded to filler");
        assertEq(srcLeftover, ORDER - actualRolled);
    }

    /// @notice extra src donation during hook (delta > leftover) succeeds post-Cand-19.
    ///         Surplus accumulates at the Settler with no protocol-recognized claim.
    function test_extraSrcDonationDuringHookSucceeds() public {
        uint256 actualRolled = 750e18;
        uint256 donation = 10e18;
        RolloverTypes.OrderData memory orderData = _orderUnderfill(602);
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _openWithIntent(orderData, actualRolled, donation);

        uint256 settlerSrcBefore = srcCst.balanceOf(address(settler));
        _doRolloverAs(orderDigest, orderData, intent, ORDER, filler);

        assertEq(
            srcCst.balanceOf(address(settler)),
            settlerSrcBefore + donation,
            "donation surplus parks at Settler"
        );
        assertEq(settler.rolloverAccountingOf(orderDigest).dstCstProduced, actualRolled);
    }

    /// @notice reverts with the renamed selector when rolloverContract refunds less than the reported leftover.
    function testRevert_missingSrcLeftoverDeliveryRevertsWithShortfallSelector() public {
        SrcLeftoverFactoryMock mockFactory = new SrcLeftoverFactoryMock();
        Settler altSettler = new Settler(
            address(mockFactory),
            address(phoenixPool),
            address(this),
            address(this),
            address(this),
            address(this)
        );
        mockFactory.configure(address(dstCst), ORDER, 100e18);

        MinimalRolloverContractStub rolloverContractStub = new MinimalRolloverContractStub();
        RolloverTypes.OrderData memory orderData = _baseOrder();
        rolloverContractStub.setOwner(orderData.user); // satisfy INV-USER-IS-ROLLOVER_CONTRACT-OWNER admission
        orderData.settler = address(altSettler);
        orderData.rolloverParams.settler = address(altSettler);
        orderData.rolloverContract = address(rolloverContractStub);
        orderData.orderSize = ORDER;
        orderData.orderSalt = 603;
        bytes32 orderDigest = _orderDigestFor(address(altSettler), orderData);

        vm.startPrank(filler);
        srcCst.approve(address(altSettler), type(uint256).max);
        vm.stopPrank();

        RolloverTypes.RolloverIntent memory intent = _emptyIntent(rolloverContract, orderDigest);
        bytes memory cptHolderOrderSig = _signOrder(cptHolderPk, orderData);
        bytes memory rolloverLeg = abi.encode(
            uint8(RolloverTypes.HookPhase.ROLLOVER),
            ORDER,
            uint256(0),
            filler,
            address(0),
            intent,
            new bytes(65),
            uint256(0),
            "",
            bytes32(0),
            ""
        );
        bytes memory fillerData =
            abi.encode(uint8(255), rolloverLeg, uint256(1_000_000e18), cptHolderOrderSig);

        vm.expectRevert(
            abi.encodeWithSignature(
                "Settler__SrcLeftoverDeliveryShortfall(uint256,uint256)", 100e18, 0
            )
        );
        vm.prank(filler);
        altSettler.fill(orderDigest, _originDataFor(orderData), fillerData);
    }

    /// @notice RolloverContract cannot report more srcCST leftover than the filler supplied.
    function testRevert_srcLeftoverAboveFillAmountRevertsBeforeRefund() public {
        SrcLeftoverFactoryMock mockFactory = new SrcLeftoverFactoryMock();
        Settler altSettler = new Settler(
            address(mockFactory),
            address(phoenixPool),
            address(this),
            address(this),
            address(this),
            address(this)
        );
        mockFactory.configure(address(dstCst), ORDER, ORDER + 1);

        MinimalRolloverContractStub rolloverContractStub = new MinimalRolloverContractStub();
        RolloverTypes.OrderData memory orderData = _baseOrder();
        rolloverContractStub.setOwner(orderData.user);
        orderData.settler = address(altSettler);
        orderData.rolloverParams.settler = address(altSettler);
        orderData.rolloverContract = address(rolloverContractStub);
        orderData.orderSize = ORDER;
        orderData.orderSalt = 604;
        bytes32 orderDigest = _orderDigestFor(address(altSettler), orderData);

        vm.startPrank(filler);
        srcCst.approve(address(altSettler), type(uint256).max);
        vm.stopPrank();

        RolloverTypes.RolloverIntent memory intent = _emptyIntent(rolloverContract, orderDigest);
        bytes memory cptHolderOrderSig = _signOrder(cptHolderPk, orderData);
        bytes memory rolloverLeg = abi.encode(
            uint8(RolloverTypes.HookPhase.ROLLOVER),
            ORDER,
            uint256(0),
            filler,
            address(0),
            intent,
            new bytes(65),
            uint256(0),
            "",
            bytes32(0),
            ""
        );
        bytes memory fillerData =
            abi.encode(uint8(255), rolloverLeg, uint256(1_000_000e18), cptHolderOrderSig);

        vm.expectRevert(
            abi.encodeWithSelector(Settler__SrcLeftoverExceedsFillAmount.selector, ORDER + 1, ORDER)
        );
        vm.prank(filler);
        altSettler.fill(orderDigest, _originDataFor(orderData), fillerData);
    }

    /// @notice _origin data for.
    function _originDataFor(RolloverTypes.OrderData memory orderData)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(_gasless(orderData));
    }

    /// @notice _order digest for.
    function _orderDigestFor(address settlerAddr, RolloverTypes.OrderData memory orderData)
        internal
        view
        returns (bytes32)
    {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                Typehashes.EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("CorkSettler")),
                keccak256(bytes("1.0.0")),
                block.chainid,
                settlerAddr
            )
        );
        bytes memory prefix = abi.encode(
            Typehashes.ORDER_DATA_TYPEHASH,
            orderData.user,
            orderData.settler,
            orderData.fillerHint,
            orderData.exclusiveFiller,
            orderData.srcCstToken,
            orderData.dstCstToken,
            orderData.premiumToken,
            orderData.rolloverContract,
            orderData.originChainId,
            orderData.destinationChainId
        );
        bytes memory suffix = abi.encode(
            orderData.openDeadline,
            orderData.fillDeadline,
            orderData.orderSalt,
            orderData.orderSize,
            orderData.minPremiumPerShare,
            orderData.allowPartialFills,
            orderData.allowUnderfill,
            orderData.premiumPaymentMode,
            orderData.rolloverIntentHash,
            _hashRolloverParamsMemory(orderData.rolloverParams)
        );
        bytes32 structHash = keccak256(bytes.concat(prefix, suffix));
        return keccak256(abi.encodePacked(hex"1901", domainSeparator, structHash));
    }
}
