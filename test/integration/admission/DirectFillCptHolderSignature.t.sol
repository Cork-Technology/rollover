// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { FillScaffold } from "../../base/FillScaffold.sol";
import { BaseSettler } from "src/BaseSettler.sol";
import { Settler__BadUserSignature } from "src/errors/SettlerErrors.sol";
import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import { ISettler } from "src/interfaces/settlers/ISettler.sol";
import { LibFillerAuth } from "src/libraries/LibFillerAuth.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice Pins INV-DIRECT-FILL-CPT-HOLDER-SIG. Direct-fill admission (status==`None` branch) at
///         `BaseSettler.fill` MUST verify a valid EIP-712 cPT-holder signature on `orderDigest`
///         sourced from `FillerPayload.cptHolderSig`. Mirrors the `openFor` admission contract so
///         every `None` → non-`None` transition is cPT holder-attested. Once the order is `Opened`
///         (post-`openFor`), the check is skipped — cPT holder has already attested via `openFor`.
contract DirectFillCptHolderSignatureTest is FillScaffold {
    /// @notice Order size shared across admission scenarios.
    uint256 internal constant ORDER = 1_000e18;

    /// @notice Approves filler allowances before each test.
    function setUp() public override {
        super.setUp();
        vm.startPrank(filler);
        srcCst.approve(address(settler), type(uint256).max);
        srcCst.approve(address(partialSettler), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Build a canonical order + intent harness for a direct-fill test.
    function _prepare(RolloverTypes.OrderData memory orderData)
        internal
        view
        returns (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        )
    {
        RolloverTypes.RolloverIntent memory probe = _buildIntent(bytes32(0), ORDER, ORDER);
        orderData.rolloverIntentHash = _zeroDigestHash(probe);
        orderDigest = _orderDigest(orderData);
        intent = _buildIntent(orderDigest, ORDER, ORDER);
        cptHolderSig = _signOrder(cptHolderPk, orderData);
    }

    /// @notice Direct-fill at `None` status WITH a valid cPT-holder sig succeeds (positive path).
    function test_DirectFill_WithValidCptHolderSig_Succeeds() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(orderData);

        _doRolloverWithCptHolderSig(orderDigest, orderData, intent, ORDER, filler, cptHolderSig);
        assertEq(settler.rolloverAccountingOf(orderDigest).dstCstProduced, ORDER);
    }

    /// @notice Direct-fill at `None` with EMPTY cPT-holder sig reverts `Settler__BadUserSignature`.
    function testRevert_DirectFill_WithEmptyCptHolderSig_RevertsCptHolderSigInvalid() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        (bytes32 orderDigest, RolloverTypes.RolloverIntent memory intent,) = _prepare(orderData);

        bytes memory empty;
        vm.expectRevert(Settler__BadUserSignature.selector);
        _doRolloverWithCptHolderSig(orderDigest, orderData, intent, ORDER, filler, empty);
    }

    /// @notice cPT holder sig from a DIFFERENT signer (not `orderData.user`) reverts.
    function testRevert_DirectFill_WithCptHolderSigFromDifferentSigner_RevertsCptHolderSigInvalid()
        public
    {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        (bytes32 orderDigest, RolloverTypes.RolloverIntent memory intent,) = _prepare(orderData);

        (, uint256 attackerPk) = makeAddrAndKey("attacker-not-cptHolder");
        bytes memory wrongSig = _signOrder(attackerPk, orderData);

        vm.expectRevert(Settler__BadUserSignature.selector);
        _doRolloverWithCptHolderSig(orderDigest, orderData, intent, ORDER, filler, wrongSig);
    }

    /// @notice cPT holder sig over a DIFFERENT orderDigest reverts. Replays a sig from one
    ///         order onto another order (same cPT holder, different salt → different digest).
    function testRevert_DirectFill_WithCptHolderSigForDifferentOrderDigest_RevertsCptHolderSigInvalid()
        public
    {
        // Order A — the order being filled.
        RolloverTypes.OrderData memory orderA = _baseOrder();
        orderA.orderSize = ORDER;
        (bytes32 digestA, RolloverTypes.RolloverIntent memory intentA,) = _prepare(orderA);

        // Order B — different salt, different digest, same cPT holder.
        RolloverTypes.OrderData memory orderB = _baseOrder();
        orderB.orderSize = ORDER;
        orderB.orderSalt = 999;
        bytes memory replaySig = _signOrder(cptHolderPk, orderB);

        vm.expectRevert(Settler__BadUserSignature.selector);
        _doRolloverWithCptHolderSig(digestA, orderA, intentA, ORDER, filler, replaySig);
    }

    /// @notice After `openFor` has admitted the order, rolloverContract hook execution
    ///         still needs the cPT-holder sig for per-dispatch authorization.
    function test_OpenForThenFill_WithCptHolderSig_Succeeds() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(orderData);

        // openFor admits the order.
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory userSig = _signOrder(cptHolderPk, orderData);
        settler.openFor(g, userSig, "");
        assertEq(uint8(settler.orderStatus(orderDigest)), uint8(RolloverTypes.OrderStatus.Opened));

        _doRolloverWithCptHolderSig(orderDigest, orderData, intent, ORDER, filler, cptHolderSig);
        assertEq(settler.rolloverAccountingOf(orderDigest).dstCstProduced, ORDER);
    }

    /// @notice Partial-mode sub-filler keying composes with the cPT-holder-sig check.
    function test_PartialFill_SubFillerKeying_WithCptHolderSig() public {
        RolloverTypes.OrderData memory orderData = _usePartialSettler(_baseOrder());
        orderData.orderSize = ORDER;
        orderData.allowUnderfill = true;
        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _prepare(orderData);

        // First sub-filler: `filler` self-keys to bytes32(uint160(filler)).
        _doRolloverWithCptHolderSig(orderDigest, orderData, intent, ORDER / 2, filler, cptHolderSig);

        // First sub-filler record observable under its self-keyed slot.
        assertGt(
            partialSettler.fillerSlotAccountingOf(
                    orderDigest, filler, bytes32(uint256(uint160(filler)))
                ).rollover.srcCstProvided,
            0
        );

        // Second sub-filler: a different EOA — atomic-fill terminal-state gate fires.
        address subFiller2 = address(0xBEEF1234);
        srcCst.mint(subFiller2, ORDER);
        premiumToken.mint(subFiller2, 1_000_000e18);
        vm.startPrank(subFiller2);
        srcCst.approve(address(partialSettler), type(uint256).max);
        premiumToken.approve(address(partialSettler), type(uint256).max);
        vm.stopPrank();

        _doRolloverWithCptHolderSig(
            orderDigest, orderData, intent, ORDER / 2, subFiller2, cptHolderSig
        );

        assertGt(
            partialSettler.fillerSlotAccountingOf(
                    orderDigest, subFiller2, bytes32(uint256(uint160(subFiller2)))
                ).rollover.srcCstProvided,
            0
        );
        assertEq(
            uint8(partialSettler.orderStatus(orderDigest)), uint8(RolloverTypes.OrderStatus.Settled)
        );
    }

    /// @notice Regression pin: `fillerData` must decode as the canonical 10-tuple. A 9-tuple
    ///         (one slot short) reverts in `abi.decode`.
    function testRevert_FillerPayload_TupleShape_Pin_LegacyNineTuple() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        (bytes32 orderDigest, RolloverTypes.RolloverIntent memory intent,) = _prepare(orderData);

        bytes memory originData = _originData(orderData);
        bytes memory empty;
        // 9-tuple — missing cptHolderSig at slot 10. abi.decode against the 10-tuple
        // schema reverts on insufficient calldata.
        bytes memory legacyFillerData = abi.encode(
            uint8(RolloverTypes.HookPhase.ROLLOVER),
            ORDER,
            uint256(0),
            filler,
            address(0),
            intent,
            uint256(0),
            empty,
            bytes32(0)
        );

        vm.prank(filler);
        // Solidity's ABI decoder bounds failure for the short legacy tuple has no stable
        // custom-error selector.
        vm.expectRevert();
        ISettler(orderData.settler).fill(orderDigest, originData, legacyFillerData);
    }

    /// @notice Regression pin: FillerAuth typehash is exactly the expected literal.
    ///         Detects any silent rotation that would invalidate in-flight FillerAuth signatures.
    function test_FillerAuthTypehash_PinByteEqual() public pure {
        bytes32 expected =
            keccak256("FillerAuth(bytes32 orderDigest,address destination,bytes32 subFiller)");
        // FillerAuth carries auth-binding semantics for the exclusive-filler gate.
        // The cPT-holder signature is a separate
        // EIP-712 message (ORDER_DATA_TYPEHASH preimage) — adding cPT-holder-sig verification
        // does NOT rotate the FillerAuth typehash.
        assertEq(
            LibFillerAuth.hashFillerAuth(
                bytes32(uint256(0xD0AA)), bytes32(uint256(0xDE57)), address(0), bytes32(0)
            ),
            keccak256(
                abi.encodePacked(
                    hex"1901",
                    bytes32(uint256(0xD0AA)),
                    keccak256(
                        abi.encode(expected, bytes32(uint256(0xDE57)), address(0), bytes32(0))
                    )
                )
            ),
            "FillerAuth typehash drift"
        );
    }

    // -------------------------- 10-tuple builder for negatives --------------------------

    /// @dev Build and send a ROLLOVER fill with an explicit cPT-holder-sig blob. Mirrors
    ///      `_doRolloverAs` but takes `cptHolderSig` from the test rather than auto-signing.
    function _doRolloverWithCptHolderSig(
        bytes32 orderDigest,
        RolloverTypes.OrderData memory orderData,
        RolloverTypes.RolloverIntent memory intent,
        uint256 fillAmount,
        address fillerAddr,
        bytes memory cptHolderSig
    ) internal {
        bytes memory originData = _originData(orderData);
        bytes memory rolloverLeg = _dfmsRolloverLeg(fillAmount, fillerAddr, intent);
        bytes memory fillerData =
            abi.encode(uint8(255), rolloverLeg, uint256(1_000_000e18), cptHolderSig);
        vm.prank(fillerAddr);
        ISettler(orderData.settler).fill(orderDigest, originData, fillerData);
    }

    function _dfmsRolloverLeg(
        uint256 fillAmount,
        address fillerAddr,
        RolloverTypes.RolloverIntent memory intent
    ) private pure returns (bytes memory) {
        return abi.encode(
            uint8(RolloverTypes.HookPhase.ROLLOVER),
            fillAmount,
            uint256(0),
            fillerAddr,
            address(0),
            intent,
            uint256(0),
            bytes(""),
            bytes32(0),
            bytes("")
        );
    }
}
