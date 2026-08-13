// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { FillScaffold } from "../../base/FillScaffold.sol";
import { MockERC1271 } from "../../mocks/MockERC1271.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { CorkRolloverContract } from "src/CorkRolloverContract.sol";
import { ExactSettler } from "src/ExactSettler.sol";
import { PartialSettler } from "src/PartialSettler.sol";
import {
    CorkRolloverContract__IntentDeadlineBeforeFillDeadline,
    CorkRolloverContract__IntentHashMismatch
} from "src/errors/CorkRolloverContractErrors.sol";
import { LibRolloverOrder__BadOrderType } from "src/errors/LibRolloverOrderErrors.sol";
import {
    Settler__AlreadyFilled,
    Settler__AsyncPremiumOptInRequired,
    Settler__AtomicFillRequired,
    Settler__BadUserSignature,
    Settler__ExactSubFillerMismatch,
    Settler__FillAfterDeadline,
    Settler__FillerAlreadySettled,
    Settler__InsufficientRecoverableBalance,
    Settler__NoResidualToReclaim,
    Settler__NoRolloverLegForFiller,
    Settler__OrderIdMismatch,
    Settler__OrderNotExpirable,
    Settler__PremiumAlreadyFired,
    Settler__PremiumBeforeRollover,
    Settler__PremiumDestinationMismatch,
    Settler__PremiumExceedsCap,
    Settler__PremiumForOnlyPremiumPhase,
    Settler__PremiumForRequired,
    Settler__UnderfundedDstCstLiability
} from "src/errors/SettlerErrors.sol";
import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import { IExactSettler } from "src/interfaces/settlers/IExactSettler.sol";
import { IPartialSettler } from "src/interfaces/settlers/IPartialSettler.sol";
import { ISettler } from "src/interfaces/settlers/ISettler.sol";
import { LibAtomicFill } from "src/libraries/LibAtomicFill.sol";
import { LibFillerPayload } from "src/libraries/LibFillerPayload.sol";
import { Typehashes } from "src/libraries/Typehashes.sol";
import { ScopedTransferModule } from "src/modules/ScopedTransferModule.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice Test hook that always reverts during premium hook execution.
contract RevertingPremiumHook {
    /// @notice Raised by the reverting premium hook.
    error PremiumHookReverted();

    /// @notice Reverts to exercise strict premium hook failure handling.
    function boom() external pure {
        revert PremiumHookReverted();
    }
}

/// @notice Covers the signed opt-in async premium settlement path.
contract AsyncPremiumOptInTest is FillScaffold {
    /// @notice Exact-fill order size used by async premium tests.
    uint256 internal constant EXACT_SIZE = 100e18;
    /// @notice Partial-fill chunk size used by async premium tests.
    uint256 internal constant PARTIAL_CHUNK = 30e18;
    /// @notice Premium amount required by exact-fill async premium orders.
    uint256 internal constant EXACT_PREMIUM = 1e18;
    /// @notice Premium amount required by each partial-fill async premium chunk.
    uint256 internal constant PARTIAL_PREMIUM = 0.3e18;

    /// @notice First test filler/destination actor.
    address internal alice = address(0xA11CE);
    /// @notice Second test filler/destination actor.
    address internal bob = address(0xB0B);
    /// @notice Third test filler/destination actor.
    address internal cara = address(0xCAAA);
    /// @notice External actor that pays premiums for fillers.
    address internal sponsor = address(0x5A0);

    /// @notice Hook instance used to verify premium hook reverts remain strict.
    RevertingPremiumHook internal revertingPremiumHook;
    /// @notice Scoped transfer module used for delivered-premium sentinel regression coverage.
    ScopedTransferModule internal scopedTransferModule;

    /// @notice Deploys the reverting hook and funds the async premium test actors.
    function setUp() public override {
        super.setUp();
        revertingPremiumHook = new RevertingPremiumHook();
        scopedTransferModule = new ScopedTransferModule();
        erc7484.setAttestedType(address(revertingPremiumHook), Typehashes.MODULE_TYPE_EXECUTOR);
        erc7484.setAttestedType(address(scopedTransferModule), Typehashes.MODULE_TYPE_EXECUTOR);
        _fundAndApprove(alice);
        _fundAndApprove(bob);
        _fundAndApprove(cara);
        _fundAndApprove(sponsor);
    }

    function _fundAndApprove(address who) internal {
        srcCst.mint(who, 1_000_000e18);
        premiumToken.mint(who, 1_000_000e18);
        vm.startPrank(who);
        srcCst.approve(address(settler), type(uint256).max);
        srcCst.approve(address(partialSettler), type(uint256).max);
        premiumToken.approve(address(settler), type(uint256).max);
        premiumToken.approve(address(partialSettler), type(uint256).max);
        vm.stopPrank();
    }

    function _sf(address who) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(who)));
    }

    function _intent(bytes32 orderDigest, uint256 fillAmount)
        internal
        view
        returns (RolloverTypes.RolloverIntent memory)
    {
        return _intentWithPremiumHooks(orderDigest, fillAmount, new RolloverTypes.Call[](0));
    }

    function _intentWithPremiumHooks(
        bytes32 orderDigest,
        uint256 fillAmount,
        RolloverTypes.Call[] memory premiumHooks
    ) internal view returns (RolloverTypes.RolloverIntent memory) {
        RolloverTypes.Call[] memory preHooks = new RolloverTypes.Call[](1);
        preHooks[0] = _hook(
            address(sourceSrcCptModule),
            abi.encodeWithSignature("execute(address,uint256)", address(srcCpt), fillAmount)
        );
        RolloverTypes.Call[] memory postHooks = new RolloverTypes.Call[](1);
        postHooks[0] = _hook(
            address(consumeDstCptModule),
            abi.encodeWithSignature("execute(address)", address(dstCpt))
        );
        return _intentWithFourHooks(
            rolloverContract,
            orderDigest,
            preHooks,
            new RolloverTypes.Call[](0),
            postHooks,
            premiumHooks
        );
    }

    function _prepare(
        RolloverTypes.OrderData memory orderData,
        uint256 fillAmount,
        RolloverTypes.Call[] memory premiumHooks
    )
        internal
        view
        returns (
            RolloverTypes.OrderData memory prepared,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        )
    {
        prepared = orderData;
        prepared.premiumPaymentMode = 1;
        RolloverTypes.RolloverIntent memory probe =
            _intentWithPremiumHooks(bytes32(0), fillAmount, premiumHooks);
        prepared.rolloverIntentHash = _zeroDigestHash(probe);
        orderDigest = _orderDigest(prepared);
        intent = _intentWithPremiumHooks(orderDigest, fillAmount, premiumHooks);
        cptHolderSig = _signOrder(cptHolderPk, prepared);
    }

    function _rolloverData(
        uint256 fillAmount,
        address destination,
        bytes32 subFiller,
        RolloverTypes.RolloverIntent memory intent,
        bytes memory
    ) internal pure returns (bytes memory) {
        return _rolloverFillData(fillAmount, destination, subFiller, intent, bytes(""));
    }

    function _rolloverFillData(
        uint256 fillAmount,
        address destination,
        bytes32 subFiller,
        RolloverTypes.RolloverIntent memory intent,
        bytes memory cptHolderSig
    ) internal pure returns (bytes memory) {
        return abi.encode(
            uint8(RolloverTypes.HookPhase.ROLLOVER),
            fillAmount,
            uint256(0),
            destination,
            address(0),
            intent,
            uint256(0),
            bytes(""),
            subFiller,
            cptHolderSig
        );
    }

    function _premiumFillData(
        address destination,
        address premiumFor,
        bytes32 subFiller,
        RolloverTypes.RolloverIntent memory intent,
        uint256 premiumCap,
        bytes memory cptHolderSig
    ) internal pure returns (bytes memory) {
        return abi.encode(
            uint8(RolloverTypes.HookPhase.PREMIUM),
            uint256(0),
            premiumCap,
            destination,
            premiumFor,
            intent,
            uint256(0),
            bytes(""),
            subFiller,
            cptHolderSig
        );
    }

    function _malformedRolloverWithPremiumFields(
        uint256 fillAmount,
        address destination,
        address premiumFor,
        RolloverTypes.RolloverIntent memory intent,
        bytes memory cptHolderSig
    ) internal pure returns (bytes memory) {
        return abi.encode(
            uint8(RolloverTypes.HookPhase.ROLLOVER),
            fillAmount,
            uint256(1),
            destination,
            premiumFor,
            intent,
            uint256(0),
            bytes(""),
            bytes32(0),
            cptHolderSig
        );
    }

    function _malformedPremiumWithFillAmount(
        address destination,
        address premiumFor,
        RolloverTypes.RolloverIntent memory intent,
        uint256 premiumCap
    ) internal pure returns (bytes memory) {
        return abi.encode(
            uint8(RolloverTypes.HookPhase.PREMIUM),
            uint256(1),
            premiumCap,
            destination,
            premiumFor,
            intent,
            uint256(0),
            bytes(""),
            bytes32(0),
            bytes("")
        );
    }

    function _atomicData(
        uint256 fillAmount,
        address destination,
        RolloverTypes.RolloverIntent memory intent,
        bytes memory cptHolderSig
    ) internal pure returns (bytes memory) {
        bytes memory rolloverData = LibFillerPayload.encodeRolloverLeg(
            fillAmount, destination, intent, 0, bytes(""), bytes32(0), bytes("")
        );
        return
            LibFillerPayload.encodeAtomicEnvelope(rolloverData, DEFAULT_PREMIUM_CAP, cptHolderSig);
    }

    function _fillRollover(
        RolloverTypes.OrderData memory orderData,
        bytes32 orderDigest,
        uint256 fillAmount,
        address destination,
        bytes32 subFiller,
        RolloverTypes.RolloverIntent memory intent,
        bytes memory cptHolderSig
    ) internal {
        ISettler(orderData.settler)
            .fill(
                orderDigest,
                _originData(orderData),
                _rolloverFillData(fillAmount, destination, subFiller, intent, cptHolderSig)
            );
    }

    function _fillPremium(
        RolloverTypes.OrderData memory orderData,
        bytes32 orderDigest,
        address destination,
        address premiumFor,
        bytes32 subFiller,
        RolloverTypes.RolloverIntent memory intent,
        uint256 premiumCap
    ) internal {
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);
        bytes memory fillerData =
            _premiumFillData(destination, premiumFor, subFiller, intent, premiumCap, cptHolderSig);
        ISettler(orderData.settler).fill(orderDigest, _originData(orderData), fillerData);
    }

    function _fillPremiumWithCptHolderSig(
        RolloverTypes.OrderData memory orderData,
        bytes32 orderDigest,
        address destination,
        address premiumFor,
        bytes32 subFiller,
        RolloverTypes.RolloverIntent memory intent,
        uint256 premiumCap,
        bytes memory cptHolderSig
    ) internal {
        bytes memory fillerData = _premiumFillData(
            destination, premiumFor, subFiller, intent, premiumCap, cptHolderSig
        );
        ISettler(orderData.settler).fill(orderDigest, _originData(orderData), fillerData);
    }

    function _fillSelfKeyedPartialPremium(
        RolloverTypes.OrderData memory orderData,
        bytes32 orderDigest,
        address premiumFor,
        RolloverTypes.RolloverIntent memory intent,
        uint256 premiumCap
    ) internal {
        _fillPremium(
            orderData, orderDigest, address(0), premiumFor, _sf(premiumFor), intent, premiumCap
        );
    }

    /// @notice Verifies invalid async dispatch tags reject before payload decoding.
    function testRevert_asyncFill_invalidDispatchTag() public {
        (RolloverTypes.OrderData memory orderData, bytes32 orderDigest,,) =
            _prepare(_exactOrder(), EXACT_SIZE, new RolloverTypes.Call[](0));

        bytes memory invalidTaggedData = abi.encode(uint8(7), bytes32(uint256(0xBADC0DE)));

        vm.prank(filler);
        vm.expectRevert(Settler__AtomicFillRequired.selector);
        ISettler(orderData.settler).fill(orderDigest, _originData(orderData), invalidTaggedData);
    }

    /// @notice Verifies async rollover rejects premium-only fields before admission.
    function testRevert_asyncRollover_rejectsPremiumFields() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(_exactOrder(), EXACT_SIZE, new RolloverTypes.Call[](0));

        vm.prank(filler);
        vm.expectRevert(Settler__PremiumForOnlyPremiumPhase.selector);
        ISettler(orderData.settler)
            .fill(
                orderDigest,
                _originData(orderData),
                _malformedRolloverWithPremiumFields(EXACT_SIZE, alice, filler, intent, cptHolderSig)
            );
    }

    /// @notice L-02: direct first-fill rejects non-canonical originData that is not a
    ///         single ABI-encoded ERC-7683 order envelope for `orderDigest`.
    function testRevert_directFirstFill_rejectsNonCanonicalTupleOriginData() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(_exactOrder(), EXACT_SIZE, new RolloverTypes.Call[](0));

        RolloverTypes.OrderData memory appendedOrderData = orderData;
        appendedOrderData.minPremiumPerShare = orderData.minPremiumPerShare + 1;
        bytes memory mismatchedOriginData = abi.encode(_gasless(orderData), appendedOrderData);

        vm.prank(alice);
        vm.expectRevert(Settler__OrderIdMismatch.selector);
        ISettler(orderData.settler)
            .fill(
                orderDigest,
                mismatchedOriginData,
                _rolloverFillData(EXACT_SIZE, alice, bytes32(0), intent, cptHolderSig)
            );
    }

    /// @notice L-02: direct first-fill rejects malformed raw ERC-7683 orderDataType before
    ///         admitting the order.
    function testRevert_directFirstFill_rejectsBadRawOrderDataType() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(_exactOrder(), EXACT_SIZE, new RolloverTypes.Call[](0));

        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        g.orderDataType = bytes32(0);

        vm.prank(alice);
        vm.expectRevert(LibRolloverOrder__BadOrderType.selector);
        ISettler(orderData.settler)
            .fill(
                orderDigest,
                abi.encode(g),
                _rolloverFillData(EXACT_SIZE, alice, bytes32(0), intent, cptHolderSig)
            );
    }

    /// @notice L-02: non-fill lifecycle calls reject originData whose embedded orderData has another digest.
    function testRevert_cancel_rejectsOriginDataForDifferentOrderDigest() public {
        (RolloverTypes.OrderData memory orderData, bytes32 orderDigest,,) =
            _prepare(_exactOrder(), EXACT_SIZE, new RolloverTypes.Call[](0));
        ISettler(orderData.settler)
            .openFor(_gasless(orderData), _signOrder(cptHolderPk, orderData), "");

        RolloverTypes.OrderData memory otherOrderData = orderData;
        otherOrderData.minPremiumPerShare = orderData.minPremiumPerShare + 1;
        bytes memory mismatchedOriginData = abi.encode(_gasless(otherOrderData));
        bytes memory cancelSig =
            _signCancelFor(address(settler), cptHolderPk, orderDigest, orderData.orderSalt);

        vm.prank(orderData.user);
        vm.expectRevert(Settler__OrderIdMismatch.selector);
        ISettler(orderData.settler).cancel(orderDigest, mismatchedOriginData, cancelSig);
    }

    /// @notice Verifies async premium rejects rollover-only fill amount fields before subject lookup.
    function testRevert_asyncPremium_rejectsFillAmount() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(_exactOrder(), EXACT_SIZE, new RolloverTypes.Call[](0));

        vm.prank(sponsor);
        vm.expectRevert(Settler__PremiumForOnlyPremiumPhase.selector);
        ISettler(orderData.settler)
            .fill(
                orderDigest,
                _originData(orderData),
                _malformedPremiumWithFillAmount(address(0), filler, intent, EXACT_PREMIUM)
            );
    }

    /// @notice Verifies phase-tagged async fill rejects orders without opt-in.
    function test_nonOptInPhaseTaggedFillReverts() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = EXACT_SIZE;
        RolloverTypes.RolloverIntent memory probe = _intent(bytes32(0), EXACT_SIZE);
        orderData.rolloverIntentHash = _zeroDigestHash(probe);
        bytes32 orderDigest = _orderDigest(orderData);
        RolloverTypes.RolloverIntent memory intent = _intent(orderDigest, EXACT_SIZE);
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);

        vm.prank(filler);
        vm.expectRevert(Settler__AsyncPremiumOptInRequired.selector);
        _fillRollover(orderData, orderDigest, EXACT_SIZE, filler, bytes32(0), intent, cptHolderSig);

        vm.prank(sponsor);
        vm.expectRevert(Settler__AsyncPremiumOptInRequired.selector);
        _fillPremium(orderData, orderDigest, sponsor, filler, bytes32(0), intent, EXACT_PREMIUM);
    }

    /// @notice Verifies sponsored exact phase premium settlement releases dst to recorded destination.
    function test_exactPhaseRolloverThenSponsoredPremiumSettlesRecordedDestination() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(_exactOrder(), EXACT_SIZE, new RolloverTypes.Call[](0));

        vm.prank(filler);
        _fillRollover(orderData, orderDigest, EXACT_SIZE, alice, bytes32(0), intent, cptHolderSig);

        assertEq(
            ExactSettler(orderData.settler).rolloverAccountingOf(orderDigest).settlementDestination,
            alice,
            "exact filler destination recorded"
        );
        assertEq(dstCst.balanceOf(alice), 0, "rollover-only leaves dst escrowed");
        assertEq(
            IExactSettler(orderData.settler).rolloverAccountingOf(orderDigest).dstCstProduced,
            EXACT_SIZE,
            "exact record produced"
        );

        uint256 sponsorPremiumBefore = premiumToken.balanceOf(sponsor);
        vm.prank(sponsor);
        _fillPremium(orderData, orderDigest, address(0), filler, bytes32(0), intent, EXACT_PREMIUM);

        assertEq(dstCst.balanceOf(alice), EXACT_SIZE, "dst released to original destination");
        assertEq(dstCst.balanceOf(sponsor), 0, "premium payer cannot redirect dst");
        assertEq(sponsorPremiumBefore - premiumToken.balanceOf(sponsor), EXACT_PREMIUM);
        assertEq(
            uint8(ISettler(orderData.settler).orderStatus(orderDigest)),
            uint8(RolloverTypes.OrderStatus.Settled)
        );

        vm.warp(uint256(orderData.fillDeadline) + 1);
        vm.expectRevert(Settler__OrderNotExpirable.selector);
        ISettler(orderData.settler).markExpired(orderDigest, _originData(orderData));
    }

    /// @notice Async PREMIUM does not re-query live FillerAuth after the rollover slot is recorded.
    function test_asyncPremiumAfterErc1271ExclusiveFillerRevocationSettlesRecordedDestination()
        public
    {
        MockERC1271 exclusiveFiller = new MockERC1271(true);
        RolloverTypes.OrderData memory baseOrder = _exactOrder();
        baseOrder.exclusiveFiller = address(exclusiveFiller);
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(baseOrder, EXACT_SIZE, new RolloverTypes.Call[](0));

        vm.prank(filler);
        _fillRollover(orderData, orderDigest, EXACT_SIZE, alice, bytes32(0), intent, cptHolderSig);

        exclusiveFiller.setAccept(false);

        vm.prank(sponsor);
        _fillPremium(orderData, orderDigest, address(0), filler, bytes32(0), intent, EXACT_PREMIUM);

        assertEq(dstCst.balanceOf(alice), EXACT_SIZE, "dst released to recorded destination");
        assertEq(dstCst.balanceOf(sponsor), 0, "sponsor cannot redirect dst");
        assertEq(
            uint8(ISettler(orderData.settler).orderStatus(orderDigest)),
            uint8(RolloverTypes.OrderStatus.Settled)
        );
    }

    /// @notice Async PREMIUM must re-check the cPT-holder signature after a prior ROLLOVER.
    function testRevert_asyncPremium_emptyCptHolderSigRevertsAfterRollover() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(_exactOrder(), EXACT_SIZE, new RolloverTypes.Call[](0));

        vm.prank(filler);
        _fillRollover(orderData, orderDigest, EXACT_SIZE, alice, bytes32(0), intent, cptHolderSig);

        vm.prank(sponsor);
        vm.expectRevert(Settler__BadUserSignature.selector);
        _fillPremiumWithCptHolderSig(
            orderData, orderDigest, address(0), filler, bytes32(0), intent, EXACT_PREMIUM, bytes("")
        );
    }

    /// @notice Async PREMIUM rejects a cPT-holder signature from any key other than the cPT holder.
    function testRevert_asyncPremium_badCptHolderSigRevertsAfterRollover() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(_exactOrder(), EXACT_SIZE, new RolloverTypes.Call[](0));

        vm.prank(filler);
        _fillRollover(orderData, orderDigest, EXACT_SIZE, alice, bytes32(0), intent, cptHolderSig);

        (, uint256 strangerPk) = makeAddrAndKey("async-premium-stranger");
        bytes memory badCptHolderSig = _signOrder(strangerPk, orderData);

        vm.prank(sponsor);
        vm.expectRevert(Settler__BadUserSignature.selector);
        _fillPremiumWithCptHolderSig(
            orderData,
            orderDigest,
            address(0),
            filler,
            bytes32(0),
            intent,
            EXACT_PREMIUM,
            badCptHolderSig
        );
    }

    /// @notice Even with a valid cPT-holder signature, async PREMIUM rejects a tampered intent whose
    ///         zero-digest hash does not match the cPT-holder-signed `OrderData.rolloverIntentHash`.
    function testRevert_asyncPremium_validCptHolderSigStillRequiresIntentHashMatch() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(_exactOrder(), EXACT_SIZE, new RolloverTypes.Call[](0));

        vm.prank(filler);
        _fillRollover(orderData, orderDigest, EXACT_SIZE, alice, bytes32(0), intent, cptHolderSig);

        intent.nonce = intent.nonce + 1;

        vm.prank(sponsor);
        vm.expectRevert(CorkRolloverContract__IntentHashMismatch.selector);
        _fillPremiumWithCptHolderSig(
            orderData,
            orderDigest,
            address(0),
            filler,
            bytes32(0),
            intent,
            EXACT_PREMIUM,
            _signOrder(cptHolderPk, orderData)
        );
    }

    /// @notice M-02: async orders must not cache an intent that expires before fillDeadline.
    function testRevert_asyncRollover_rejectsIntentDeadlineBeforeFillDeadline() public {
        RolloverTypes.OrderData memory orderData = _exactOrder();
        orderData.premiumPaymentMode = RolloverTypes.PREMIUM_PAYMENT_MODE_ATOMIC_OR_SEPARATE;
        uint64 earlyIntentDeadline = uint64(block.timestamp + 1 days);
        assertLt(earlyIntentDeadline, orderData.fillDeadline, "regression setup");

        RolloverTypes.RolloverIntent memory probe =
            _intentWithPremiumHooks(bytes32(0), EXACT_SIZE, new RolloverTypes.Call[](0));
        probe.deadline = earlyIntentDeadline;
        orderData.rolloverIntentHash = _zeroDigestHash(probe);

        bytes32 orderDigest = _orderDigest(orderData);
        RolloverTypes.RolloverIntent memory intent =
            _intentWithPremiumHooks(orderDigest, EXACT_SIZE, new RolloverTypes.Call[](0));
        intent.deadline = earlyIntentDeadline;
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);

        vm.prank(filler);
        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContract__IntentDeadlineBeforeFillDeadline.selector,
                earlyIntentDeadline,
                orderData.fillDeadline
            )
        );
        _fillRollover(orderData, orderDigest, EXACT_SIZE, alice, bytes32(0), intent, cptHolderSig);
    }

    /// @notice Verifies duplicate exact rollover and insufficient premium cap revert.
    function test_exactDuplicateRolloverAndPremiumCapRevert() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(_exactOrder(), EXACT_SIZE, new RolloverTypes.Call[](0));

        vm.prank(filler);
        _fillRollover(orderData, orderDigest, EXACT_SIZE, alice, bytes32(0), intent, cptHolderSig);

        vm.prank(filler);
        vm.expectRevert(Settler__AlreadyFilled.selector);
        _fillRollover(orderData, orderDigest, EXACT_SIZE, alice, bytes32(0), intent, cptHolderSig);

        vm.prank(sponsor);
        vm.expectRevert(Settler__PremiumDestinationMismatch.selector);
        _fillPremium(orderData, orderDigest, sponsor, filler, bytes32(0), intent, EXACT_PREMIUM);

        vm.prank(sponsor);
        vm.expectRevert(
            abi.encodeWithSelector(
                Settler__PremiumExceedsCap.selector, EXACT_PREMIUM - 1, EXACT_PREMIUM
            )
        );
        _fillPremium(
            orderData, orderDigest, address(0), filler, bytes32(0), intent, EXACT_PREMIUM - 1
        );
    }

    /// @notice Verifies exact async premium rejects a sub-filler different from rollover.
    function testRevert_exactAsyncPremium_wrongSubFiller() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(_exactOrder(), EXACT_SIZE, new RolloverTypes.Call[](0));

        bytes32 recordedSubFiller = _sf(alice);
        bytes32 suppliedSubFiller = _sf(bob);
        vm.prank(filler);
        _fillRollover(
            orderData, orderDigest, EXACT_SIZE, alice, recordedSubFiller, intent, cptHolderSig
        );

        vm.prank(sponsor);
        vm.expectRevert(
            abi.encodeWithSelector(
                Settler__ExactSubFillerMismatch.selector, recordedSubFiller, suppliedSubFiller
            )
        );
        _fillPremium(
            orderData, orderDigest, address(0), filler, suppliedSubFiller, intent, EXACT_PREMIUM
        );
    }

    /// @notice Verifies exact async premium cannot run before the rollover leg.
    function testRevert_exactAsyncPremium_beforeRollover() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(_exactOrder(), EXACT_SIZE, new RolloverTypes.Call[](0));

        vm.prank(sponsor);
        vm.expectRevert(Settler__PremiumBeforeRollover.selector);
        _fillPremium(orderData, orderDigest, address(0), filler, bytes32(0), intent, EXACT_PREMIUM);
    }

    /// @notice Verifies exact async premium is single-use after settlement.
    function testRevert_exactAsyncPremium_secondPremiumAlreadyFired() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(_exactOrder(), EXACT_SIZE, new RolloverTypes.Call[](0));

        vm.prank(filler);
        _fillRollover(orderData, orderDigest, EXACT_SIZE, alice, bytes32(0), intent, cptHolderSig);

        vm.prank(sponsor);
        _fillPremium(orderData, orderDigest, address(0), filler, bytes32(0), intent, EXACT_PREMIUM);

        vm.prank(sponsor);
        vm.expectRevert(Settler__PremiumAlreadyFired.selector);
        _fillPremium(orderData, orderDigest, address(0), filler, bytes32(0), intent, EXACT_PREMIUM);
    }

    /// @notice Verifies exact reclaim has no effect when an opened order has no residual.
    function testRevert_exactReclaim_openedNoResidual() public {
        (RolloverTypes.OrderData memory orderData, bytes32 orderDigest,,) =
            _prepare(_exactOrder(), EXACT_SIZE, new RolloverTypes.Call[](0));

        _openOrder(orderData);
        vm.warp(orderData.fillDeadline + 1);
        vm.expectRevert(Settler__NoResidualToReclaim.selector);
        ISettler(orderData.settler).reclaim(orderDigest, filler, bytes32(0), _originData(orderData));
    }

    /// @notice Verifies the same unpaid exact residual cannot be reclaimed twice.
    function testRevert_exactReclaim_sameUnpaidResidualTwice() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(_exactOrder(), EXACT_SIZE, new RolloverTypes.Call[](0));

        vm.prank(filler);
        _fillRollover(orderData, orderDigest, EXACT_SIZE, alice, bytes32(0), intent, cptHolderSig);

        vm.warp(orderData.fillDeadline + 1);
        ISettler(orderData.settler).reclaim(orderDigest, filler, bytes32(0), _originData(orderData));

        vm.expectRevert(Settler__NoResidualToReclaim.selector);
        ISettler(orderData.settler).reclaim(orderDigest, filler, bytes32(0), _originData(orderData));
    }

    /// @notice Verifies reverting premium hooks leave premium unfired and funds unparked.
    function test_premiumHookRevertDoesNotParkPremiumOrFire() public {
        RolloverTypes.Call[] memory premiumHooks = new RolloverTypes.Call[](1);
        premiumHooks[0] =
            _hook(address(revertingPremiumHook), abi.encodeCall(RevertingPremiumHook.boom, ()));
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(_exactOrder(), EXACT_SIZE, premiumHooks);

        vm.prank(filler);
        _fillRollover(orderData, orderDigest, EXACT_SIZE, alice, bytes32(0), intent, cptHolderSig);

        uint256 sponsorPremiumBefore = premiumToken.balanceOf(sponsor);
        uint256 rolloverContractPremiumBefore = premiumToken.balanceOf(rolloverContract);
        vm.prank(sponsor);
        vm.expectRevert();
        _fillPremium(orderData, orderDigest, address(0), filler, bytes32(0), intent, EXACT_PREMIUM);

        assertEq(premiumToken.balanceOf(sponsor), sponsorPremiumBefore);
        assertEq(premiumToken.balanceOf(rolloverContract), rolloverContractPremiumBefore);
        assertFalse(IExactSettler(orderData.settler).rolloverAccountingOf(orderDigest).premiumFired);
        assertEq(dstCst.balanceOf(address(settler)), EXACT_SIZE, "unpaid residual remains");
    }

    /// @notice Verifies partial orders can mix atomic and async premium slots through reclaim.
    function test_partialMixedAtomicAndAsyncSlotsAndReclaim() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(_partialOrder(), PARTIAL_CHUNK, new RolloverTypes.Call[](0));

        vm.prank(alice);
        ISettler(orderData.settler)
            .fill(
                orderDigest,
                _originData(orderData),
                _atomicData(PARTIAL_CHUNK, alice, intent, cptHolderSig)
            );
        assertEq(
            uint8(ISettler(orderData.settler).orderStatus(orderDigest)),
            uint8(RolloverTypes.OrderStatus.Opened),
            "partial remains fillable after sub-order atomic settle"
        );

        vm.prank(bob);
        _fillRollover(orderData, orderDigest, PARTIAL_CHUNK, bob, _sf(bob), intent, cptHolderSig);
        assertEq(
            PartialSettler(orderData.settler)
            .fillerSlotAccountingOf(orderDigest, bob, _sf(bob))
            .settlementDestination,
            bob,
            "partial filler destination recorded"
        );
        assertEq(
            IPartialSettler(orderData.settler).rolloverAccountingOf(orderDigest).dstCstEscrowed,
            PARTIAL_CHUNK
        );

        vm.prank(sponsor);
        _fillPremium(orderData, orderDigest, bob, bob, _sf(bob), intent, PARTIAL_PREMIUM);
        assertEq(dstCst.balanceOf(bob), PARTIAL_CHUNK, "bob receives recorded destination");

        vm.prank(cara);
        _fillRollover(orderData, orderDigest, PARTIAL_CHUNK, cara, _sf(cara), intent, cptHolderSig);
        assertEq(
            IPartialSettler(orderData.settler).rolloverAccountingOf(orderDigest).srcCstConsumed,
            orderData.orderSize,
            "aggregate progress reaches order size"
        );
        assertEq(
            IPartialSettler(orderData.settler).rolloverAccountingOf(orderDigest).dstCstEscrowed,
            PARTIAL_CHUNK,
            "only cara remains escrowed"
        );

        vm.warp(orderData.fillDeadline + 1);
        ISettler(orderData.settler).reclaim(orderDigest, cara, _sf(cara), _originData(orderData));
        assertEq(
            IPartialSettler(orderData.settler).rolloverAccountingOf(orderDigest).dstCstEscrowed, 0
        );

        vm.prank(sponsor);
        vm.expectRevert(Settler__FillAfterDeadline.selector);
        _fillPremium(orderData, orderDigest, address(0), cara, _sf(cara), intent, PARTIAL_PREMIUM);
    }

    /// @notice L-01: a direct EOA that creates a partial async rollover with wire-zero
    ///         `subFiller` can premium the same self-keyed slot with wire-zero `subFiller`.
    function test_partialDirectEoaWireZeroPremiumSettlesSelfKeyedSlot() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(_partialOrder(), PARTIAL_CHUNK, new RolloverTypes.Call[](0));

        vm.prank(bob);
        _fillRollover(orderData, orderDigest, PARTIAL_CHUNK, bob, bytes32(0), intent, cptHolderSig);

        assertEq(
            PartialSettler(orderData.settler)
            .fillerSlotAccountingOf(orderDigest, bob, _sf(bob))
            .settlementDestination,
            bob,
            "rollover wire-zero canonicalizes to direct EOA self-key"
        );

        uint256 bobPremiumBefore = premiumToken.balanceOf(bob);
        vm.prank(bob);
        _fillPremium(orderData, orderDigest, address(0), bob, bytes32(0), intent, PARTIAL_PREMIUM);

        assertEq(dstCst.balanceOf(bob), PARTIAL_CHUNK, "premium releases self-keyed residual");
        assertEq(bobPremiumBefore - premiumToken.balanceOf(bob), PARTIAL_PREMIUM);
        assertEq(
            IPartialSettler(orderData.settler).rolloverAccountingOf(orderDigest).dstCstEscrowed, 0
        );
    }

    /// @notice A wire-zero partial async premium may still pin the recorded destination.
    function test_partialDirectEoaWireZeroPremiumAcceptsRecordedDestination() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(_partialOrder(), PARTIAL_CHUNK, new RolloverTypes.Call[](0));

        vm.prank(bob);
        _fillRollover(orderData, orderDigest, PARTIAL_CHUNK, bob, bytes32(0), intent, cptHolderSig);

        vm.prank(bob);
        _fillPremium(orderData, orderDigest, bob, bob, bytes32(0), intent, PARTIAL_PREMIUM);

        assertEq(dstCst.balanceOf(bob), PARTIAL_CHUNK, "premium releases self-keyed residual");
    }

    /// @notice L-02: fragmented partial premium must stay within the order-level ceiling.
    function test_partialFragmentedPremiumUsesOrderLevelCeiling() public {
        uint256 fragment = 1;
        RolloverTypes.OrderData memory fragmentedOrder = _usePartialSettler(_baseOrder());
        fragmentedOrder.orderSize = fragment * 2;
        uint256 orderLevelPremium = LibAtomicFill.computeRequiredPremium(
            fragmentedOrder.orderSize, fragmentedOrder.minPremiumPerShare
        );
        assertEq(orderLevelPremium, 1, "regression setup needs aggregate ceil below fragments");

        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(fragmentedOrder, fragment, new RolloverTypes.Call[](0));

        vm.prank(bob);
        _fillRollover(orderData, orderDigest, fragment, bob, _sf(bob), intent, cptHolderSig);

        vm.prank(cara);
        _fillRollover(orderData, orderDigest, fragment, cara, _sf(cara), intent, cptHolderSig);

        uint256 sponsorPremiumBefore = premiumToken.balanceOf(sponsor);
        vm.prank(sponsor);
        _fillSelfKeyedPartialPremium(orderData, orderDigest, bob, intent, 1);

        uint256 premiumPaid = sponsorPremiumBefore - premiumToken.balanceOf(sponsor);
        assertEq(
            premiumPaid, orderLevelPremium, "first rounded fragment consumes aggregate ceiling"
        );

        vm.prank(sponsor);
        _fillSelfKeyedPartialPremium(
            orderData, orderDigest, cara, intent, orderLevelPremium - premiumPaid
        );

        assertLe(
            sponsorPremiumBefore - premiumToken.balanceOf(sponsor),
            orderLevelPremium,
            "fragmentation must not exceed order-level premium ceiling"
        );
    }

    /// @notice R-01: a later rounded-to-zero partial premium must not be bricked by a
    ///         delivered-premium sentinel hook.
    function test_partialFragmentedZeroPremiumSentinelHookDoesNotBrickSettlement() public {
        uint256 fragment = 1;
        RolloverTypes.OrderData memory fragmentedOrder = _usePartialSettler(_baseOrder());
        fragmentedOrder.orderSize = fragment * 2;
        uint256 orderLevelPremium = LibAtomicFill.computeRequiredPremium(
            fragmentedOrder.orderSize, fragmentedOrder.minPremiumPerShare
        );
        assertEq(orderLevelPremium, 1, "regression setup needs aggregate ceil below fragments");

        RolloverTypes.Call[] memory premiumHooks = new RolloverTypes.Call[](1);
        premiumHooks[0] = _hook(
            address(scopedTransferModule),
            abi.encodeCall(
                ScopedTransferModule.execute,
                (IERC20(address(premiumToken)), type(uint256).max, address(0xA11CED))
            )
        );

        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(fragmentedOrder, fragment, premiumHooks);

        vm.prank(bob);
        _fillRollover(orderData, orderDigest, fragment, bob, _sf(bob), intent, cptHolderSig);

        vm.prank(cara);
        _fillRollover(orderData, orderDigest, fragment, cara, _sf(cara), intent, cptHolderSig);

        uint256 sponsorPremiumBefore = premiumToken.balanceOf(sponsor);
        vm.prank(sponsor);
        _fillSelfKeyedPartialPremium(orderData, orderDigest, bob, intent, 1);
        uint256 premiumPaid = sponsorPremiumBefore - premiumToken.balanceOf(sponsor);
        assertEq(premiumPaid, orderLevelPremium, "first slot consumes aggregate ceiling");

        uint256 caraDstBefore = dstCst.balanceOf(cara);
        vm.prank(sponsor);
        _fillSelfKeyedPartialPremium(orderData, orderDigest, cara, intent, 0);

        assertEq(dstCst.balanceOf(cara) - caraDstBefore, fragment, "zero-premium slot settles");
        assertEq(
            sponsorPremiumBefore - premiumToken.balanceOf(sponsor),
            orderLevelPremium,
            "second slot owes and moves zero premium"
        );
    }

    /// @notice Verifies partial async premium rejects wrong slots, duplicate rollover, and repeat premium.
    function test_partialWrongSlotAlreadyPaidAndDuplicateRolloverRevert() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(_partialOrder(), PARTIAL_CHUNK, new RolloverTypes.Call[](0));

        vm.prank(bob);
        _fillRollover(orderData, orderDigest, PARTIAL_CHUNK, bob, _sf(bob), intent, cptHolderSig);

        vm.prank(sponsor);
        vm.expectRevert(Settler__NoRolloverLegForFiller.selector);
        _fillPremium(orderData, orderDigest, sponsor, bob, _sf(alice), intent, PARTIAL_PREMIUM);

        vm.prank(sponsor);
        vm.expectRevert(Settler__NoRolloverLegForFiller.selector);
        _fillPremium(orderData, orderDigest, sponsor, alice, _sf(bob), intent, PARTIAL_PREMIUM);

        vm.prank(bob);
        vm.expectRevert(Settler__AlreadyFilled.selector);
        _fillRollover(orderData, orderDigest, PARTIAL_CHUNK, bob, _sf(bob), intent, cptHolderSig);

        vm.prank(sponsor);
        _fillPremium(orderData, orderDigest, address(0), bob, _sf(bob), intent, PARTIAL_PREMIUM);

        vm.prank(sponsor);
        vm.expectRevert(Settler__PremiumAlreadyFired.selector);
        _fillPremium(orderData, orderDigest, address(0), bob, _sf(bob), intent, PARTIAL_PREMIUM);
    }

    /// @notice Verifies partial async premium requires a nonzero `premiumFor`.
    function testRevert_partialAsyncPremium_zeroPremiumFor() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(_partialOrder(), PARTIAL_CHUNK, new RolloverTypes.Call[](0));

        vm.prank(bob);
        _fillRollover(orderData, orderDigest, PARTIAL_CHUNK, bob, _sf(bob), intent, cptHolderSig);

        vm.prank(sponsor);
        vm.expectRevert(Settler__PremiumForRequired.selector);
        _fillPremium(orderData, orderDigest, bob, address(0), _sf(bob), intent, PARTIAL_PREMIUM);
    }

    /// @notice Verifies reclaim rejects an already atomically settled partial slot.
    function testRevert_partialReclaim_atomicSettledSlotPremiumFired() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(_partialOrder(), PARTIAL_CHUNK, new RolloverTypes.Call[](0));

        _atomicPartial(orderDigest, orderData, intent, cptHolderSig, alice);

        vm.warp(orderData.fillDeadline + 1);
        vm.expectRevert(Settler__NoResidualToReclaim.selector);
        ISettler(orderData.settler).reclaim(orderDigest, alice, _sf(alice), _originData(orderData));
    }

    /// @notice Verifies the same unpaid partial slot cannot be reclaimed twice.
    function testRevert_partialReclaim_sameUnpaidSlotTwice() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(_partialOrder(), PARTIAL_CHUNK, new RolloverTypes.Call[](0));

        vm.prank(cara);
        _fillRollover(orderData, orderDigest, PARTIAL_CHUNK, cara, _sf(cara), intent, cptHolderSig);

        vm.warp(orderData.fillDeadline + 1);
        ISettler(orderData.settler).reclaim(orderDigest, cara, _sf(cara), _originData(orderData));

        vm.expectRevert(Settler__NoResidualToReclaim.selector);
        ISettler(orderData.settler).reclaim(orderDigest, cara, _sf(cara), _originData(orderData));
    }

    /// @notice Verifies partial reclaim rejects a missing slot with no residual.
    function testRevert_partialReclaim_missingSlotNoResidual() public {
        (RolloverTypes.OrderData memory orderData, bytes32 orderDigest,,) =
            _prepare(_partialOrder(), PARTIAL_CHUNK, new RolloverTypes.Call[](0));

        vm.warp(orderData.fillDeadline + 1);
        vm.expectRevert(Settler__NoResidualToReclaim.selector);
        ISettler(orderData.settler).reclaim(orderDigest, alice, _sf(alice), _originData(orderData));
    }

    /// @notice GH-100: exact live dstCST liability blocks rescue of owed residual but permits excess.
    function test_exactLiveDstCstLiabilityBlocksRescueButPermitsExcess() public {
        uint256 excess = 5e18;
        address recipient = makeAddr("exact-excess-recipient");
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(_exactOrder(), EXACT_SIZE, new RolloverTypes.Call[](0));

        vm.prank(filler);
        _fillRollover(orderData, orderDigest, EXACT_SIZE, alice, bytes32(0), intent, cptHolderSig);

        assertEq(settler.dstCstLiabilityOf(address(dstCst)), EXACT_SIZE, "live exact liability");
        assertEq(settler.recoverableTokenBalance(address(dstCst)), 0, "owed residual blocked");
        vm.expectRevert(Settler__InsufficientRecoverableBalance.selector);
        settler.recoverToken(IERC20(address(dstCst)), recipient, 1);

        dstCst.mint(address(settler), excess);
        assertEq(settler.recoverableTokenBalance(address(dstCst)), excess, "only excess");
        settler.recoverToken(IERC20(address(dstCst)), recipient, excess);

        assertEq(dstCst.balanceOf(recipient), excess);
        assertEq(settler.dstCstLiabilityOf(address(dstCst)), EXACT_SIZE, "rescue unchanged");
        assertEq(dstCst.balanceOf(address(settler)), EXACT_SIZE, "liability remains backed");
    }

    /// @notice GH-100: partial live dstCST liability blocks rescue of owed residual but permits excess.
    function test_partialLiveDstCstLiabilityBlocksRescueButPermitsExcess() public {
        uint256 excess = 3e18;
        address recipient = makeAddr("partial-excess-recipient");
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(_partialOrder(), PARTIAL_CHUNK, new RolloverTypes.Call[](0));

        vm.prank(bob);
        _fillRollover(orderData, orderDigest, PARTIAL_CHUNK, bob, _sf(bob), intent, cptHolderSig);

        assertEq(
            partialSettler.dstCstLiabilityOf(address(dstCst)),
            PARTIAL_CHUNK,
            "live partial liability"
        );
        assertEq(partialSettler.recoverableTokenBalance(address(dstCst)), 0);
        dstCst.mint(address(partialSettler), excess);
        partialSettler.recoverToken(IERC20(address(dstCst)), recipient, excess);

        assertEq(dstCst.balanceOf(recipient), excess);
        assertEq(partialSettler.dstCstLiabilityOf(address(dstCst)), PARTIAL_CHUNK);
        assertEq(dstCst.balanceOf(address(partialSettler)), PARTIAL_CHUNK);
    }

    /// @notice GH-100: exact premium settlement decrements liability when dstCST exits.
    function test_exactSettlementDecrementsDstCstLiability() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(_exactOrder(), EXACT_SIZE, new RolloverTypes.Call[](0));

        vm.prank(filler);
        _fillRollover(orderData, orderDigest, EXACT_SIZE, alice, bytes32(0), intent, cptHolderSig);
        assertEq(settler.dstCstLiabilityOf(address(dstCst)), EXACT_SIZE);

        vm.prank(sponsor);
        _fillPremium(orderData, orderDigest, address(0), filler, bytes32(0), intent, EXACT_PREMIUM);

        assertEq(settler.dstCstLiabilityOf(address(dstCst)), 0);
        assertEq(dstCst.balanceOf(alice), EXACT_SIZE);
    }

    /// @notice GH-100: partial premium settlement decrements liability when dstCST exits.
    function test_partialSettlementDecrementsDstCstLiability() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(_partialOrder(), PARTIAL_CHUNK, new RolloverTypes.Call[](0));

        vm.prank(bob);
        _fillRollover(orderData, orderDigest, PARTIAL_CHUNK, bob, _sf(bob), intent, cptHolderSig);
        assertEq(partialSettler.dstCstLiabilityOf(address(dstCst)), PARTIAL_CHUNK);

        vm.prank(sponsor);
        _fillPremium(orderData, orderDigest, bob, bob, _sf(bob), intent, PARTIAL_PREMIUM);

        assertEq(partialSettler.dstCstLiabilityOf(address(dstCst)), 0);
        assertEq(dstCst.balanceOf(bob), PARTIAL_CHUNK);
    }

    /// @notice GH-100: exact reclaim decrements liability when unpaid dstCST exits to the rolloverContract.
    function test_exactReclaimDecrementsDstCstLiability() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(_exactOrder(), EXACT_SIZE, new RolloverTypes.Call[](0));

        vm.prank(filler);
        _fillRollover(orderData, orderDigest, EXACT_SIZE, alice, bytes32(0), intent, cptHolderSig);
        vm.warp(orderData.fillDeadline + 1);
        ISettler(orderData.settler).reclaim(orderDigest, filler, bytes32(0), _originData(orderData));

        assertEq(settler.dstCstLiabilityOf(address(dstCst)), 0);
        assertEq(dstCst.balanceOf(orderData.rolloverContract), EXACT_SIZE);
    }

    /// @notice GH-100: partial reclaim decrements liability when unpaid dstCST exits to the rolloverContract.
    function test_partialReclaimDecrementsDstCstLiability() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(_partialOrder(), PARTIAL_CHUNK, new RolloverTypes.Call[](0));

        vm.prank(cara);
        _fillRollover(orderData, orderDigest, PARTIAL_CHUNK, cara, _sf(cara), intent, cptHolderSig);
        vm.warp(orderData.fillDeadline + 1);
        ISettler(orderData.settler).reclaim(orderDigest, cara, _sf(cara), _originData(orderData));

        assertEq(partialSettler.dstCstLiabilityOf(address(dstCst)), 0);
        assertEq(dstCst.balanceOf(orderData.rolloverContract), PARTIAL_CHUNK);
    }

    /// @notice GH-100: cancel is status-only and does not decrement live dstCST liability.
    function test_partialCancelDoesNotDecrementDstCstLiability() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(_partialOrder(), PARTIAL_CHUNK, new RolloverTypes.Call[](0));

        vm.prank(bob);
        _fillRollover(orderData, orderDigest, PARTIAL_CHUNK, bob, _sf(bob), intent, cptHolderSig);

        bytes memory cancelSig =
            _signCancelFor(address(partialSettler), cptHolderPk, orderDigest, orderData.orderSalt);
        vm.prank(orderData.user);
        ISettler(orderData.settler).cancel(orderDigest, _originData(orderData), cancelSig);

        assertEq(partialSettler.dstCstLiabilityOf(address(dstCst)), PARTIAL_CHUNK);
        assertEq(
            uint8(ISettler(orderData.settler).orderStatus(orderDigest)),
            uint8(RolloverTypes.OrderStatus.Closing)
        );
    }

    /// @notice GH-100: rescue and recoverable-balance views fail closed when liability is underfunded.
    function testRevert_underfundedDstCstLiabilityFailsClosed() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(_exactOrder(), EXACT_SIZE, new RolloverTypes.Call[](0));

        vm.prank(filler);
        _fillRollover(orderData, orderDigest, EXACT_SIZE, alice, bytes32(0), intent, cptHolderSig);
        dstCst.burn(address(settler), 1);

        vm.expectRevert(Settler__UnderfundedDstCstLiability.selector);
        settler.recoverableTokenBalance(address(dstCst));

        vm.expectRevert(Settler__UnderfundedDstCstLiability.selector);
        settler.recoverToken(IERC20(address(dstCst)), alice, 1);
    }

    /// @notice Verifies partial finality waits for aggregate order size and zero escrow.
    function test_partialFinalityRequiresAggregateOrderSizeAndNoEscrow() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(_partialOrder(), PARTIAL_CHUNK, new RolloverTypes.Call[](0));

        _atomicPartial(orderDigest, orderData, intent, cptHolderSig, alice);
        assertEq(
            uint8(ISettler(orderData.settler).orderStatus(orderDigest)),
            uint8(RolloverTypes.OrderStatus.Opened)
        );

        _atomicPartial(orderDigest, orderData, intent, cptHolderSig, bob);
        assertEq(
            uint8(ISettler(orderData.settler).orderStatus(orderDigest)),
            uint8(RolloverTypes.OrderStatus.Opened)
        );

        _atomicPartial(orderDigest, orderData, intent, cptHolderSig, cara);
        assertEq(
            uint8(ISettler(orderData.settler).orderStatus(orderDigest)),
            uint8(RolloverTypes.OrderStatus.Settled)
        );
    }

    function _atomicPartial(
        bytes32 orderDigest,
        RolloverTypes.OrderData memory orderData,
        RolloverTypes.RolloverIntent memory intent,
        bytes memory cptHolderSig,
        address who
    ) internal {
        vm.prank(who);
        ISettler(orderData.settler)
            .fill(
                orderDigest,
                _originData(orderData),
                _atomicData(PARTIAL_CHUNK, who, intent, cptHolderSig)
            );
    }

    function _exactOrder() internal view returns (RolloverTypes.OrderData memory orderData) {
        orderData = _baseOrder();
        orderData.orderSize = EXACT_SIZE;
    }

    function _partialOrder() internal view returns (RolloverTypes.OrderData memory orderData) {
        orderData = _usePartialSettler(_baseOrder());
        orderData.orderSize = PARTIAL_CHUNK * 3;
    }
}
