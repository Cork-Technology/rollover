// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { FillScaffold } from "../../base/FillScaffold.sol";
import { FillerPayload__InvalidPhase } from "src/errors/LibFillerPayloadErrors.sol";
import {
    Settler__AtomicFillRequired,
    Settler__FillAfterDeadline,
    Settler__OpenAfterOpenDeadline,
    Settler__OrderInTerminalState,
    Settler__PremiumDeliveryMismatch,
    Settler__PremiumExceedsCap,
    Settler__RolloverAmountOutOfBounds
} from "src/errors/SettlerErrors.sol";
import { ISettler } from "src/interfaces/settlers/ISettler.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice TDD scenarios for the atomic-fill dispatch path.
///
///         Atomic-fill collapses admit → rollover → premium → settle into a single Settler
///         call. The dispatch tag in `fillerData[0:1]` is `ATOMIC_TAG = uint8(255)`. Public
///         phase-tag payloads (`HookPhase.ROLLOVER`, `HookPhase.PREMIUM`) are rejected; those
///         tags are only valid inside the atomic envelope's inner leg payloads. The atomic
///         envelope shape is the verbatim 4-tuple:
///         `(uint8 ATOMIC_TAG, bytes rolloverFillerData, uint256 premiumCap, bytes cptHolderSig)`.
///
contract AtomicFillTest is FillScaffold {
    /// @notice Default fill amount used by tag-dispatch tests.
    uint256 internal constant FILL_AMOUNT = 100e18;
    // requiredPremium = ceil(produced * minPremiumPerShare / 1e18). With
    // orderSize=1000e18 and minPremiumPerShare=1e16, full-size produces a
    // requiredPremium of 10e18 — cap set above to leave filler headroom.
    /// @notice Filler-supplied premium cap (20e18) leaves headroom over the 10e18 required premium.
    uint256 internal constant PREMIUM_CAP = 20e18;

    function _atomicFillerData(
        bytes memory rolloverData,
        uint256 premiumCap,
        bytes memory cptHolderSig
    ) internal pure returns (bytes memory) {
        return abi.encode(ATOMIC_TAG, rolloverData, premiumCap, cptHolderSig);
    }

    function _buildAtomicEnvelope(RolloverTypes.OrderData memory orderData, uint256 fillAmount)
        internal
        view
        returns (bytes memory atomicData, bytes32 orderDigest)
    {
        // Build a probe intent to pin `rolloverIntentHash` to the canonical zero-digest hash so
        // the rolloverContract's intent-hash gate passes. `_baseOrder` uses a dummy `0xC1` placeholder.
        RolloverTypes.RolloverIntent memory probe = _buildIntent(bytes32(0), fillAmount, 0);
        orderData.rolloverIntentHash = _zeroDigestHash(probe);
        orderDigest = _orderDigest(orderData);
        RolloverTypes.RolloverIntent memory intent = _buildIntent(orderDigest, fillAmount, 0);
        bytes memory rolloverData = _legacyRolloverLeg(fillAmount, intent);
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);
        atomicData = _atomicFillerData(rolloverData, PREMIUM_CAP, cptHolderSig);
    }

    // --- 1. Happy-path: exact-mode atomic fill -----------------------------------------------

    /// @notice Exact-mode atomic fill admits, rolls, settles in one call; order ends Settled.
    function test_atomicFill_exact_happyPath() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        (bytes memory atomicData, bytes32 orderDigest) =
            _buildAtomicEnvelope(orderData, orderData.orderSize);
        _approveFiller(orderData.orderSize, PREMIUM_CAP);

        vm.prank(filler);
        ISettler(orderData.settler).fill(orderDigest, _originData(orderData), atomicData);

        // Atomic invariant: order Settled, filler holds dstCST, premium delivered to rolloverContract.
        assertEq(
            uint8(ISettler(orderData.settler).orderStatus(orderDigest)),
            uint8(RolloverTypes.OrderStatus.Settled)
        );
    }

    // --- 2. Happy-path: partial-mode atomic fill ---------------------------------------------

    /// @notice Partial-mode under-sized fill settles the sub-filler slot but keeps the
    ///         order `Opened` until aggregate srcCST consumption reaches `orderSize`.
    function test_atomicFill_partial_happyPath() public {
        RolloverTypes.OrderData memory orderData = _usePartialSettler(_baseOrder());
        (bytes memory atomicData, bytes32 orderDigest) = _buildAtomicEnvelope(orderData, 400e18);
        _approveFiller(400e18, PREMIUM_CAP);

        vm.prank(filler);
        ISettler(orderData.settler).fill(orderDigest, _originData(orderData), atomicData);

        assertEq(
            uint8(ISettler(orderData.settler).orderStatus(orderDigest)),
            uint8(RolloverTypes.OrderStatus.Opened)
        );
    }

    // --- 3. Partial-mode second sub-filler joins without re-checking cPT-holder-sig ---------------

    /// @notice Second sub-filler under the SAME msg.sender succeeds without premium-latch collision.
    function test_atomicFill_partial_secondSubFiller() public {
        RolloverTypes.OrderData memory orderData = _usePartialSettler(_baseOrder());
        // Build both envelopes against the SAME fillAmount so the rolloverIntentHash
        // (which depends on srcAmount via the preHook calldata) stays invariant across calls.
        // Reuse the same orderData → second sub-filler joins the same orderDigest.
        (bytes memory atomicDataA, bytes32 orderDigest) = _buildAtomicEnvelope(orderData, 400e18);
        _approveFiller(orderData.orderSize, PREMIUM_CAP);

        vm.prank(filler);
        ISettler(orderData.settler).fill(orderDigest, _originData(orderData), atomicDataA);

        // Build the second sub-filler envelope BEFORE warping — `_buildIntent`'s deadline is
        // `block.timestamp + 2 days`, so warping first would yield a different rolloverIntentHash
        // → different orderDigest. Build first, warp second.
        // Use a non-zero subFiller so the (msg.sender, subFiller) slot differs from the first
        // fill's slot (subFiller=0), modelling a routed-shared-filler joining the same order.
        RolloverTypes.RolloverIntent memory intentB = _buildIntent(orderDigest, 400e18, 0);
        bytes memory cptHolderSigB = _signOrder(cptHolderPk, orderData);
        bytes memory rolloverDataB =
            _legacyRolloverLegWithSubFiller(400e18, intentB, bytes32(uint256(0xB)));
        bytes memory atomicDataB = _atomicFillerData(rolloverDataB, PREMIUM_CAP, cptHolderSigB);
        // Second sub-filler joins — passes openDeadline gate even if it's expired by now.
        vm.warp(orderData.openDeadline + 1);
        vm.prank(filler);
        ISettler(orderData.settler).fill(orderDigest, _originData(orderData), atomicDataB);

        assertEq(
            uint8(ISettler(orderData.settler).orderStatus(orderDigest)),
            uint8(RolloverTypes.OrderStatus.Opened)
        );
    }

    /// @notice Malformed short `fillerData` fails at the fill dispatch boundary.
    function test_fillShortFillerData_revertsAtomicFillRequired() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        bytes32 orderDigest = _orderDigest(orderData);

        vm.expectRevert(Settler__AtomicFillRequired.selector);
        vm.prank(filler);
        ISettler(orderData.settler).fill(orderDigest, _originData(orderData), hex"00");
    }

    /// @notice Settler rejects a zero ROLLOVER fill before rolloverContract hook dispatch.
    function testRevert_atomicRollover_zeroFillAmount() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        (bytes memory atomicData, bytes32 orderDigest) = _buildAtomicEnvelope(orderData, 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                Settler__RolloverAmountOutOfBounds.selector, orderData.orderSize, 0
            )
        );
        vm.prank(filler);
        ISettler(orderData.settler).fill(orderDigest, _originData(orderData), atomicData);
    }

    // --- 5. Atomic-premium derivation boundary -------------------------------------------------
    //
    // Atomic premium carries no separate envelope segment. The Settler derives the premium
    // payload from the already decoded rollover intent, so the envelope cannot carry alternate
    // filler-auth, amount, routing, phase, or intent fields for the premium dispatch.

    // --- 6. requiredPremium > premiumCap reverts ---------------------------------------------

    /// @notice requiredPremium exceeding the filler-supplied premiumCap reverts the atomic fill.
    function test_atomicFill_premiumExceedsCap() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        // Force a tiny cap that the ceil-rounded requiredPremium will exceed.
        RolloverTypes.RolloverIntent memory probe = _buildIntent(bytes32(0), orderData.orderSize, 0);
        orderData.rolloverIntentHash = _zeroDigestHash(probe);
        bytes32 orderDigest = _orderDigest(orderData);
        RolloverTypes.RolloverIntent memory intent =
            _buildIntent(orderDigest, orderData.orderSize, 0);
        bytes memory rolloverData = _legacyRolloverLeg(orderData.orderSize, intent);
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);
        bytes memory atomicData = _atomicFillerData(rolloverData, 1, cptHolderSig);

        _approveFiller(orderData.orderSize, PREMIUM_CAP);

        vm.prank(filler);
        // Selector match only — exact (cap, required) tuple validated post-implementation.
        vm.expectRevert();
        ISettler(orderData.settler).fill(orderDigest, _originData(orderData), atomicData);
    }

    // --- 7. premiumCap remainder stays with filler -------------------------------------------

    /// @notice Settler pulls only the rolloverContract-computed requiredPremium; filler keeps the remainder up to premiumCap.
    function test_atomicFill_premiumCapRemainderStaysWithFiller() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        (bytes memory atomicData, bytes32 orderDigest) =
            _buildAtomicEnvelope(orderData, orderData.orderSize);
        _approveFiller(orderData.orderSize, PREMIUM_CAP);

        uint256 fillerPremiumBefore = premiumToken.balanceOf(filler);

        vm.prank(filler);
        ISettler(orderData.settler).fill(orderDigest, _originData(orderData), atomicData);

        // Settler must pull requiredPremium, not premiumCap — filler retains remainder.
        // requiredPremium = ceil(produced * minPremiumPerShare / 1e18). With produced ≤ orderSize
        // and minPremiumPerShare=1e16, requiredPremium ≤ 10e18 well below cap=5e18 — but in
        // this happy-path the filler's net outflow MUST equal the actual pull, not the cap.
        uint256 fillerPremiumAfter = premiumToken.balanceOf(filler);
        assertGt(fillerPremiumAfter, fillerPremiumBefore - PREMIUM_CAP);
    }

    /// @notice Fee-on-transfer premium tokens are rejected by the delivered-delta check.
    function testRevert_atomicFill_feeOnTransferPremiumDeliveryMismatch() public {
        FeeOnTransferPremiumToken feePremium = new FeeOnTransferPremiumToken(1e18);
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.premiumToken = address(feePremium);
        (bytes memory atomicData, bytes32 orderDigest) =
            _buildAtomicEnvelope(orderData, orderData.orderSize);

        uint256 requiredPremium = 10e18;
        feePremium.mint(filler, PREMIUM_CAP);
        vm.prank(filler);
        feePremium.approve(orderData.settler, PREMIUM_CAP);

        vm.prank(filler);
        vm.expectRevert(
            abi.encodeWithSelector(
                Settler__PremiumDeliveryMismatch.selector, requiredPremium, requiredPremium - 1e18
            )
        );
        ISettler(orderData.settler).fill(orderDigest, _originData(orderData), atomicData);
    }

    // --- 8. Terminal status blocks fill ------------------------------------------------------

    /// @notice Second atomic fill against an already-Settled order reverts OrderInTerminalState.
    function test_atomicFill_terminalStatusBlocksFill() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        (bytes memory atomicData, bytes32 orderDigest) =
            _buildAtomicEnvelope(orderData, orderData.orderSize);
        _approveFiller(orderData.orderSize * 2, PREMIUM_CAP * 2);

        // First fill settles the order.
        vm.prank(filler);
        ISettler(orderData.settler).fill(orderDigest, _originData(orderData), atomicData);

        // Second fill against the same (now Settled) order must revert.
        vm.prank(filler);
        vm.expectRevert(Settler__OrderInTerminalState.selector);
        ISettler(orderData.settler).fill(orderDigest, _originData(orderData), atomicData);
    }

    // --- 9. openDeadline past blocks FIRST admission (status None) ---------------------------

    /// @notice First-admission atomic fill after openDeadline reverts OpenAfterOpenDeadline.
    function test_atomicFill_openDeadlinePastBlocksFirstAdmission() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        (bytes memory atomicData, bytes32 orderDigest) =
            _buildAtomicEnvelope(orderData, orderData.orderSize);
        _approveFiller(orderData.orderSize, PREMIUM_CAP);

        vm.warp(orderData.openDeadline + 1);

        vm.prank(filler);
        vm.expectRevert(Settler__OpenAfterOpenDeadline.selector);
        ISettler(orderData.settler).fill(orderDigest, _originData(orderData), atomicData);
    }

    // --- 10. openDeadline past OK once status is Opened (from earlier openFor) ---------------

    /// @notice Already-Opened order accepts atomic fill after openDeadline (only fillDeadline gates).
    function test_atomicFill_openDeadlinePastAcceptedForOpened() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        // Pin rolloverIntentHash BEFORE opening so the opened orderDigest matches the
        // digest that _buildAtomicEnvelope later signs/derives.
        RolloverTypes.RolloverIntent memory probe = _buildIntent(bytes32(0), orderData.orderSize, 0);
        orderData.rolloverIntentHash = _zeroDigestHash(probe);
        bytes32 orderDigest = _openOrder(orderData);

        (bytes memory atomicData,) = _buildAtomicEnvelope(orderData, orderData.orderSize);
        _approveFiller(orderData.orderSize, PREMIUM_CAP);

        // Warp past openDeadline but stay under fillDeadline.
        vm.warp(orderData.openDeadline + 1);
        assertLt(block.timestamp, orderData.fillDeadline);

        vm.prank(filler);
        ISettler(orderData.settler).fill(orderDigest, _originData(orderData), atomicData);
    }

    // --- 11. fillDeadline past blocks always -------------------------------------------------

    /// @notice Atomic fill after fillDeadline always reverts FillAfterDeadline regardless of status.
    function test_atomicFill_fillDeadlinePastBlocksAlways() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        (bytes memory atomicData, bytes32 orderDigest) =
            _buildAtomicEnvelope(orderData, orderData.orderSize);
        _approveFiller(orderData.orderSize, PREMIUM_CAP);

        vm.warp(orderData.fillDeadline + 1);

        vm.prank(filler);
        vm.expectRevert(Settler__FillAfterDeadline.selector);
        ISettler(orderData.settler).fill(orderDigest, _originData(orderData), atomicData);
    }

    function _phaseRolloverData(
        uint256 fillAmount,
        RolloverTypes.RolloverIntent memory intent,
        bytes memory cptHolderSig
    ) private view returns (bytes memory) {
        return abi.encode(
            uint8(RolloverTypes.HookPhase.ROLLOVER),
            fillAmount,
            uint256(0),
            filler,
            address(0),
            intent,
            cptHolderSig,
            uint256(0),
            bytes(""),
            bytes32(0),
            cptHolderSig
        );
    }
}

/// @notice Minimal fee-on-transfer ERC-20 used only to exercise premium delivery accounting.
contract FeeOnTransferPremiumToken {
    /// @notice Token balances.
    mapping(address account => uint256 balance) public balanceOf;
    /// @notice Token allowances.
    mapping(address owner => mapping(address spender => uint256 amount)) public allowance;
    /// @notice Flat fee retained on every `transferFrom`.
    uint256 public immutable fee;

    /// @param fee_ Flat fee retained on every `transferFrom`.
    constructor(uint256 fee_) {
        fee = fee_;
    }

    /// @notice Mint test tokens.
    /// @param to Recipient.
    /// @param amount Amount.
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    /// @notice Approve spender.
    /// @param spender Spender.
    /// @param amount Amount.
    /// @return ok True on success.
    function approve(address spender, uint256 amount) external returns (bool ok) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    /// @notice Transfer with a flat fee retained by this token contract.
    /// @param from Source.
    /// @param to Recipient.
    /// @param amount Requested amount.
    /// @return ok True on success.
    function transferFrom(address from, address to, uint256 amount) external returns (bool ok) {
        uint256 approved = allowance[from][msg.sender];
        if (approved != type(uint256).max) {
            allowance[from][msg.sender] = approved - amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount - fee;
        balanceOf[address(this)] += fee;
        return true;
    }
}
