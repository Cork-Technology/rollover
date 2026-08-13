// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { FillScaffold } from "../../base/FillScaffold.sol";
import { MockERC1271 } from "../../mocks/MockERC1271.sol";
import { BaseSettler } from "src/BaseSettler.sol";
import {
    Settler__SelfExclusiveFiller,
    Settler__UnauthorizedFiller
} from "src/errors/SettlerErrors.sol";
import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import { LibFillerPayload } from "src/libraries/LibFillerPayload.sol";
import { Typehashes } from "src/libraries/Typehashes.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice FillerAuthTest — pins FillerAuth behaviour for the Cork Rollover suite.
contract FillerAuthTest is FillScaffold {
    /// @notice Filler auth typehash expected.
    bytes32 internal constant FILLER_AUTH_TYPEHASH_EXPECTED =
        keccak256("FillerAuth(bytes32 orderDigest,address destination,bytes32 subFiller)");
    /// @notice Eoa filler.

    address internal eoaFiller;
    /// @notice Eoa filler pk.

    uint256 internal eoaFillerPk;
    /// @notice Executor.

    address internal executor;
    /// @notice Fill.

    uint256 internal constant FILL = 500e18;
    /// @notice Test fixture setup.

    function setUp() public override {
        super.setUp();
        (eoaFiller, eoaFillerPk) = makeAddrAndKey("exclusive-eoa");
        executor = makeAddr("delegated-executor");

        srcCst.mint(executor, 1_000_000e18);
        srcCst.mint(eoaFiller, 1_000_000e18);
        premiumToken.mint(executor, 1_000_000e18);
        premiumToken.mint(eoaFiller, 1_000_000e18);
        vm.startPrank(executor);
        srcCst.approve(address(settler), type(uint256).max);
        srcCst.approve(address(partialSettler), type(uint256).max);
        premiumToken.approve(address(settler), type(uint256).max);
        premiumToken.approve(address(partialSettler), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(eoaFiller);
        srcCst.approve(address(settler), type(uint256).max);
        srcCst.approve(address(partialSettler), type(uint256).max);
        premiumToken.approve(address(settler), type(uint256).max);
        premiumToken.approve(address(partialSettler), type(uint256).max);
        vm.stopPrank();

        bytes32 live = BaseSettler(address(settler)).fillerAuthTypehash();
        require(live == FILLER_AUTH_TYPEHASH_EXPECTED, "FillerAuth typehash drift");
        bytes32 partialLive = BaseSettler(address(partialSettler)).fillerAuthTypehash();
        require(partialLive == FILLER_AUTH_TYPEHASH_EXPECTED, "Partial FillerAuth typehash drift");
    }

    function _settlerDomainSeparator(address settler_) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                Typehashes.EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("CorkSettler")),
                keccak256(bytes("1.0.0")),
                block.chainid,
                settler_
            )
        );
    }

    /// @dev FillerAuth digest includes the sub-filler slot key.
    function _fillerAuthDigest(bytes32 orderDigest, address destination, bytes32 subFiller)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(FILLER_AUTH_TYPEHASH_EXPECTED, orderDigest, destination, subFiller)
        );
        return keccak256(
            abi.encodePacked(hex"1901", _settlerDomainSeparator(address(settler)), structHash)
        );
    }

    function _fillerAuthDigestFor(
        SettlerMode mode,
        bytes32 orderDigest,
        address destination,
        bytes32 subFiller
    ) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(FILLER_AUTH_TYPEHASH_EXPECTED, orderDigest, destination, subFiller)
        );
        return keccak256(
            abi.encodePacked(
                hex"1901", _settlerDomainSeparator(_settlerAddressForMode(mode)), structHash
            )
        );
    }

    function _signFillerAuth(
        uint256 pk,
        bytes32 orderDigest,
        address destination,
        bytes32 subFiller
    ) internal view returns (bytes memory) {
        bytes32 digest = _fillerAuthDigest(orderDigest, destination, subFiller);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signFillerAuthFor(
        SettlerMode mode,
        uint256 pk,
        bytes32 orderDigest,
        address destination,
        bytes32 subFiller
    ) internal view returns (bytes memory) {
        bytes32 digest = _fillerAuthDigestFor(mode, orderDigest, destination, subFiller);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _setupOrder(address exclusive)
        internal
        returns (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        )
    {
        orderData = _baseOrder();
        // INV-EXACT-FILL-SIZE-BINDING: scaffold drives partial-amount fills on an exact order;
        // allowUnderfill must be true to clear the strict-exact admission gate.
        orderData.allowUnderfill = true;
        orderData.exclusiveFiller = exclusive;
        intent = _buildIntent(bytes32(0), FILL, FILL);
        orderData.rolloverIntentHash = _zeroDigestHash(intent);

        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory userSig = _signOrder(cptHolderPk, orderData);
        bytes memory empty;
        settler.openFor(g, userSig, empty);
        orderDigest = _orderDigest(orderData);
        intent.orderDigest = orderDigest;
        cptHolderSig = _signOrder(cptHolderPk, orderData);
    }

    function _setupOrderForMode(SettlerMode mode, address exclusive, uint64 saltOffset)
        internal
        returns (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        )
    {
        orderData = _orderForMode(mode);
        orderData.orderSalt += saltOffset;
        // INV-EXACT-FILL-SIZE-BINDING: partial-amount FillerAuth probe; allowUnderfill must be
        // true for exact mode to clear the strict-exact admission gate.
        orderData.allowUnderfill = true;
        orderData.exclusiveFiller = exclusive;
        intent = _buildIntent(bytes32(0), FILL, FILL);
        orderData.rolloverIntentHash = _zeroDigestHash(intent);

        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory userSig = _signOrder(cptHolderPk, orderData);
        bytes memory empty;
        _settlerForMode(mode).openFor(g, userSig, empty);
        orderDigest = _orderDigest(orderData);
        intent.orderDigest = orderDigest;
        cptHolderSig = _signOrder(cptHolderPk, orderData);
    }

    /// @dev Build an atomic-fill envelope for the FillerAuth matrix tests. Under the
    ///      atomic-fill dispatch (INV-ATOMIC-FILL-CANONICAL) every `fill()` call must
    ///      carry an ATOMIC_TAG (255) envelope; this helper wraps the rollover-leg
    ///      auth payload + a self-keyed no-op premium leg into the canonical envelope.
    ///      The matrix is exercising rollover-side auth checks — premium=0 keeps the
    ///      ④ premium pull a no-op.
    function _rolloverFillerData(
        uint256 fillAmount,
        address destination,
        RolloverTypes.RolloverIntent memory intent,
        bytes memory fillerAuthSig,
        bytes memory cptHolderSig
    ) internal pure returns (bytes memory) {
        bytes memory rolloverLeg = _faRolloverLeg(fillAmount, destination, intent, fillerAuthSig);
        return abi.encode(uint8(255), rolloverLeg, DEFAULT_PREMIUM_CAP, cptHolderSig);
    }

    function _faRolloverLeg(
        uint256 fillAmount,
        address destination,
        RolloverTypes.RolloverIntent memory intent,
        bytes memory fillerAuthSig
    ) private pure returns (bytes memory) {
        return abi.encode(
            uint8(RolloverTypes.HookPhase.ROLLOVER),
            fillAmount,
            uint256(0),
            destination,
            address(0),
            intent,
            uint256(0),
            fillerAuthSig,
            bytes32(0),
            bytes("")
        );
    }

    /// @notice Shared FillerAuth matrix against the exact settler domain.
    function test_fill_sharedFillerAuthMatrix_exact() public {
        _assertSharedFillerAuthMatrix(SettlerMode.Exact);
    }

    /// @notice Shared FillerAuth matrix against the partial settler domain.
    function test_fill_sharedFillerAuthMatrix_partial() public {
        _assertSharedFillerAuthMatrix(SettlerMode.Partial);
    }

    function _assertSharedFillerAuthMatrix(SettlerMode mode) internal {
        _assertDirectFiller(mode, 10);
        _assertDelegatedAuth(mode, 20);
        _assertBadSigRejected(mode, 30);
        _assertWrongDestinationRejected(mode, 40);
        _assertNoExclusiveFiller(mode, 50);
        _assertFastPathNoneStatus(mode, 60);
    }

    function _assertDirectFiller(SettlerMode mode, uint64 saltOffset) internal {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupOrderForMode(mode, eoaFiller, saltOffset);
        bytes memory fillerData = _rolloverFillerData(
            FILL, eoaFiller, intent, new bytes(0), _signOrder(cptHolderPk, orderData)
        );
        vm.prank(eoaFiller);
        _settlerForMode(mode).fill(orderDigest, _originData(orderData), fillerData);
    }

    function _assertDelegatedAuth(SettlerMode mode, uint64 saltOffset) internal {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupOrderForMode(mode, eoaFiller, saltOffset);
        bytes memory authSig = _signFillerAuthFor(
            mode, eoaFillerPk, orderDigest, executor, bytes32(uint256(uint160(executor)))
        );
        bytes memory fillerData = _rolloverFillerData(
            FILL, executor, intent, authSig, _signOrder(cptHolderPk, orderData)
        );
        vm.prank(executor);
        _settlerForMode(mode).fill(orderDigest, _originData(orderData), fillerData);
    }

    function _assertBadSigRejected(SettlerMode mode, uint64 saltOffset) internal {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupOrderForMode(mode, eoaFiller, saltOffset);
        bytes memory authSig = _signFillerAuthFor(
            mode,
            eoaFillerPk,
            bytes32(uint256(0xDEAD)),
            executor,
            bytes32(uint256(uint160(executor)))
        );
        bytes memory fillerData = _rolloverFillerData(
            FILL, executor, intent, authSig, _signOrder(cptHolderPk, orderData)
        );
        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(Settler__UnauthorizedFiller.selector, eoaFiller, executor)
        );
        _settlerForMode(mode).fill(orderDigest, _originData(orderData), fillerData);
    }

    function _assertWrongDestinationRejected(SettlerMode mode, uint64 saltOffset) internal {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupOrderForMode(mode, eoaFiller, saltOffset);
        address d1 = makeAddr("matrix-d1");
        address d2 = makeAddr("matrix-d2");
        bytes memory authSig = _signFillerAuthFor(
            mode, eoaFillerPk, orderDigest, d1, bytes32(uint256(uint160(executor)))
        );
        bytes memory fillerData =
            _rolloverFillerData(FILL, d2, intent, authSig, _signOrder(cptHolderPk, orderData));
        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(Settler__UnauthorizedFiller.selector, eoaFiller, executor)
        );
        _settlerForMode(mode).fill(orderDigest, _originData(orderData), fillerData);
    }

    function _assertNoExclusiveFiller(SettlerMode mode, uint64 saltOffset) internal {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupOrderForMode(mode, address(0), saltOffset);
        bytes memory fillerData = _rolloverFillerData(
            FILL, executor, intent, new bytes(0), _signOrder(cptHolderPk, orderData)
        );
        vm.prank(executor);
        _settlerForMode(mode).fill(orderDigest, _originData(orderData), fillerData);
    }

    function _assertFastPathNoneStatus(SettlerMode mode, uint64 saltOffset) internal {
        RolloverTypes.OrderData memory orderData = _orderForMode(mode);
        orderData.orderSalt += saltOffset;
        // INV-EXACT-FILL-SIZE-BINDING: probe drives a partial-amount fill on an exact order.
        orderData.allowUnderfill = true;
        orderData.exclusiveFiller = eoaFiller;
        RolloverTypes.RolloverIntent memory intent = _buildIntent(bytes32(0), FILL, FILL);
        orderData.rolloverIntentHash = _zeroDigestHash(intent);
        bytes32 orderDigest = _orderDigest(orderData);
        intent.orderDigest = orderDigest;
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);

        bytes memory fillerData = _rolloverFillerData(
            FILL, eoaFiller, intent, new bytes(0), _signOrder(cptHolderPk, orderData)
        );
        vm.prank(eoaFiller);
        _settlerForMode(mode).fill(orderDigest, _originData(orderData), fillerData);
    }

    /// @notice Pins behaviour: fill direct eoa no sig.
    function test_fill_direct_eoa_no_sig() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupOrder(eoaFiller);

        bytes memory empty;
        bytes memory fillerData =
            _rolloverFillerData(FILL, eoaFiller, intent, empty, _signOrder(cptHolderPk, orderData));
        uint256 fillerBalBefore = dstCst.balanceOf(eoaFiller);
        vm.prank(eoaFiller);
        settler.fill(orderDigest, _originData(orderData), fillerData);
        // Under atomic-fill, settle transfers dstCST to the filler in-frame.
        assertGt(dstCst.balanceOf(eoaFiller) - fillerBalBefore, 0, "dstCST must reach filler");
    }

    /// @notice Pins behaviour: fill direct safe no sig.
    function test_fill_direct_safe_no_sig() public {
        MockERC1271 safe = new MockERC1271(true);
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupOrder(address(safe));

        srcCst.mint(address(safe), 1_000_000e18);
        premiumToken.mint(address(safe), 1_000_000e18);
        vm.startPrank(address(safe));
        srcCst.approve(address(settler), type(uint256).max);
        srcCst.approve(address(partialSettler), type(uint256).max);
        premiumToken.approve(address(settler), type(uint256).max);
        premiumToken.approve(address(partialSettler), type(uint256).max);
        vm.stopPrank();

        bytes memory empty;
        bytes memory fillerData = _rolloverFillerData(
            FILL, address(safe), intent, empty, _signOrder(cptHolderPk, orderData)
        );
        uint256 safeBalBefore = dstCst.balanceOf(address(safe));
        vm.prank(address(safe));
        settler.fill(orderDigest, _originData(orderData), fillerData);
        // Under atomic-fill, settle transfers dstCST to the filler in-frame.
        assertGt(
            dstCst.balanceOf(address(safe)) - safeBalBefore, 0, "dstCST must reach safe filler"
        );
    }

    /// @notice Pins behaviour: fill direct destination freely chosen.
    function test_fill_direct_destination_freely_chosen() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupOrder(eoaFiller);

        address chosenDest = makeAddr("chosen-dest");
        bytes memory empty;
        bytes memory fillerData = _rolloverFillerData(
            FILL, chosenDest, intent, empty, _signOrder(cptHolderPk, orderData)
        );
        vm.prank(eoaFiller);
        settler.fill(orderDigest, _originData(orderData), fillerData);
    }

    /// @notice Pins behaviour: fill delegated eoa sig happy.
    function test_fill_delegated_eoa_sig_happy() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupOrder(eoaFiller);

        bytes memory authSig = _signFillerAuth(
            eoaFillerPk, orderDigest, executor, bytes32(uint256(uint160(executor)))
        );
        bytes memory fillerData = _rolloverFillerData(
            FILL, executor, intent, authSig, _signOrder(cptHolderPk, orderData)
        );
        vm.prank(executor);
        settler.fill(orderDigest, _originData(orderData), fillerData);
    }

    /// @notice Pins behaviour: fill delegated safe sig happy.
    function test_fill_delegated_safe_sig_happy() public {
        MockERC1271 safe = new MockERC1271(true);
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupOrder(address(safe));

        bytes memory anyBytes = new bytes(1);
        bytes memory fillerData = _rolloverFillerData(
            FILL, executor, intent, anyBytes, _signOrder(cptHolderPk, orderData)
        );
        vm.prank(executor);
        settler.fill(orderDigest, _originData(orderData), fillerData);
    }

    /// @notice Atomic fill authenticates the rollover leg and reuses that slot for premium settle.
    function test_atomicFill_delegatedRolloverAuthOnly_succeeds() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupOrder(eoaFiller);

        bytes memory authSig = _signFillerAuth(
            eoaFillerPk, orderDigest, executor, bytes32(uint256(uint160(executor)))
        );
        bytes memory fillerData = _rolloverFillerData(
            FILL, executor, intent, authSig, _signOrder(cptHolderPk, orderData)
        );

        vm.prank(executor);
        settler.fill(orderDigest, _originData(orderData), fillerData);
    }

    /// @notice Pins behaviour: reverts when fill delegated bad sig.
    function testRevert_fill_delegated_bad_sig() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupOrder(eoaFiller);

        bytes memory authSig = _signFillerAuth(
            eoaFillerPk, bytes32(uint256(0xDEAD)), executor, bytes32(uint256(uint160(executor)))
        );
        bytes memory fillerData = _rolloverFillerData(
            FILL, executor, intent, authSig, _signOrder(cptHolderPk, orderData)
        );
        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(Settler__UnauthorizedFiller.selector, eoaFiller, executor)
        );
        settler.fill(orderDigest, _originData(orderData), fillerData);
    }

    /// @notice Pins behaviour: reverts when fill delegated wrong destination.
    function testRevert_fill_delegated_wrong_destination() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupOrder(eoaFiller);

        address d1 = makeAddr("d1");
        address d2 = makeAddr("d2");
        bytes memory authSig =
            _signFillerAuth(eoaFillerPk, orderDigest, d1, bytes32(uint256(uint160(executor))));
        bytes memory fillerData =
            _rolloverFillerData(FILL, d2, intent, authSig, _signOrder(cptHolderPk, orderData));
        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(Settler__UnauthorizedFiller.selector, eoaFiller, executor)
        );
        settler.fill(orderDigest, _originData(orderData), fillerData);
    }

    /// @notice Pins behaviour: fill delegated sig replay across executors.
    function test_fill_delegated_sig_replay_across_executors() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupOrder(eoaFiller);

        bytes memory authSig = _signFillerAuth(
            eoaFillerPk, orderDigest, executor, bytes32(uint256(uint160(executor)))
        );
        bytes memory fillerData = _rolloverFillerData(
            FILL, executor, intent, authSig, _signOrder(cptHolderPk, orderData)
        );

        vm.prank(executor);
        settler.fill(orderDigest, _originData(orderData), fillerData);

        address executor2 = makeAddr("executor2");
        bytes memory authSig2 = _signFillerAuth(
            eoaFillerPk, orderDigest, executor2, bytes32(uint256(uint160(executor2)))
        );
        bytes memory cptHolderSig2 = _signOrder(cptHolderPk, orderData);
        bytes memory fillerData2 =
            _rolloverFillerData(FILL, executor2, intent, authSig2, cptHolderSig2);
        vm.prank(executor2);
        vm.expectRevert();
        settler.fill(orderDigest, _originData(orderData), fillerData2);
    }

    /// @notice Pins behaviour: fill no exclusive filler any msgsender.
    function test_fill_no_exclusive_filler_any_msgsender() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupOrder(address(0));

        bytes memory empty;
        bytes memory fillerData =
            _rolloverFillerData(FILL, executor, intent, empty, _signOrder(cptHolderPk, orderData));
        vm.prank(executor);
        settler.fill(orderDigest, _originData(orderData), fillerData);
    }

    /// @notice Pins behaviour: open For ignores origin Filler Data.
    function test_openFor_ignores_originFillerData() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.exclusiveFiller = eoaFiller;
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory userSig = _signOrder(cptHolderPk, orderData);
        bytes memory garbage = abi.encodePacked(uint256(0xDEADBEEF));
        address anyone_ = makeAddr("openFor-anyone");
        vm.prank(anyone_);
        settler.openFor(g, userSig, garbage);
        bytes32 orderDigest = _orderDigest(orderData);
        assertEq(uint8(settler.orderStatus(orderDigest)), uint8(RolloverTypes.OrderStatus.Opened));
    }

    /// @notice Pins behaviour: open For no filler auth required.
    function test_openFor_no_filler_auth_required() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.exclusiveFiller = eoaFiller;
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory userSig = _signOrder(cptHolderPk, orderData);
        bytes memory empty;
        vm.prank(executor);
        settler.openFor(g, userSig, empty);
        bytes32 orderDigest = _orderDigest(orderData);
        assertEq(uint8(settler.orderStatus(orderDigest)), uint8(RolloverTypes.OrderStatus.Opened));
    }

    /// @notice Pins behaviour: fill fast path None status with filler auth.
    function test_fill_fast_path_None_status_with_filler_auth() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.allowPartialFills = false;
        // INV-EXACT-FILL-SIZE-BINDING: probe drives a partial-amount exact fill.
        orderData.allowUnderfill = true;
        orderData.exclusiveFiller = eoaFiller;
        RolloverTypes.RolloverIntent memory intent = _buildIntent(bytes32(0), FILL, FILL);
        orderData.rolloverIntentHash = _zeroDigestHash(intent);
        bytes32 orderDigest = _orderDigest(orderData);
        intent.orderDigest = orderDigest;
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);

        bytes memory empty;
        bytes memory fillerData =
            _rolloverFillerData(FILL, eoaFiller, intent, empty, _signOrder(cptHolderPk, orderData));
        vm.prank(eoaFiller);
        settler.fill(orderDigest, _originData(orderData), fillerData);
    }

    /// @notice Pins behaviour: reverts when open For self exclusive filler.
    function testRevert_openFor_self_exclusive_filler() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.exclusiveFiller = address(settler);
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory userSig = _signOrder(cptHolderPk, orderData);
        bytes memory empty;
        vm.expectRevert(Settler__SelfExclusiveFiller.selector);
        settler.openFor(g, userSig, empty);
    }
}
