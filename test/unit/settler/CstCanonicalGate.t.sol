// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { MockERC20 } from "../../mocks/MockERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { BaseSettler } from "src/BaseSettler.sol";
import { ExactSettler as Settler } from "src/ExactSettler.sol";
import {
    Settler__DstCstNotCanonical,
    Settler__SrcCstNotCanonical,
    Settler__ZeroAddress
} from "src/errors/SettlerErrors.sol";
import { IPoolManager, MarketId } from "src/interfaces/external/phoenix/IPoolManager.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @title CstCanonicalGateTest
/// @notice Pins `INV-CST-CANONICAL` — Settler MUST resolve every admitted
///         `srcCstToken` / `dstCstToken` against the trusted Phoenix `PoolManager`
///         singleton, not the caller-supplied token's own `poolManager()` view.
///         Prevents non-canonical cST admission through spoofed token metadata.
contract CstCanonicalGateTest is BaseTest {
    /// @notice Hostile cST that lies about its `poolManager()` and `expiry()` views.
    ///         An attacker uses this to forge a token that LOOKS canonical (`poolManager()`
    ///         returns the real `CORK_POOL_MANAGER` address) but is in fact attacker-owned
    ///         bytecode. The canonical-cST gate ignores `poolManager()` entirely — it asks
    ///         the trusted PM "what is the cST for the user-signed pool id?" and compares.
    function _deploySpoofedCst(address lyingPoolManager, bytes32 lyingPoolId)
        internal
        returns (SpoofedCst)
    {
        return new SpoofedCst(lyingPoolManager, lyingPoolId);
    }

    /// @notice Happy path: an order whose src and dst cST tokens are the canonical
    ///         Phoenix-bound tokens admits cleanly.
    function test_happyPath_canonicalCstsAdmit() public view {
        _assertCanonicalCstsAdmit(SettlerMode.Exact);
        _assertCanonicalCstsAdmit(SettlerMode.Partial);
    }

    /// @notice Public immutable getters expose the constructor-wired non-rotatable anchors.
    function test_publicAnchorGettersExposeConstructorWiring() public view {
        assertEq(
            settler.ROLLOVER_CONTRACT_FACTORY(), address(factory), "exact rolloverContract factory"
        );
        assertEq(settler.CORK_POOL_MANAGER(), address(phoenixPool), "exact pool manager");
        assertEq(
            partialSettler.ROLLOVER_CONTRACT_FACTORY(),
            address(factory),
            "partial rolloverContract factory"
        );
        assertEq(partialSettler.CORK_POOL_MANAGER(), address(phoenixPool), "partial pool manager");
    }

    function _assertCanonicalCstsAdmit(SettlerMode mode) internal view {
        RolloverTypes.OrderData memory orderData = _orderForMode(mode);
        // Sanity: BaseTest already wires srcCst/dstCst as canonical for srcPoolId/dstPoolId.
        (, address canonicalSrc) = IPoolManager(address(phoenixPool))
            .shares(MarketId.wrap(orderData.rolloverParams.srcPoolId));
        (, address canonicalDst) = IPoolManager(address(phoenixPool))
            .shares(MarketId.wrap(orderData.rolloverParams.dstPoolId));
        assertEq(canonicalSrc, orderData.srcCstToken, "src canonical mismatch");
        assertEq(canonicalDst, orderData.dstCstToken, "dst canonical mismatch");
    }

    /// @notice Hostile cPT holder substitutes a spoofed `srcCstToken` whose
    ///         `poolManager()` view returns the canonical PM address (i.e. the attacker
    ///         hardcodes the well-known singleton in their fake token's bytecode). The
    ///         legacy "ask the token who its PM is" defence would let this through. The
    ///         canonical gate rejects it because `PM.shares(signedSrcPoolId).swapToken`
    ///         resolves to the real srcCst, not the attacker's spoof.
    function testRevert_spoofedSrcCst_lyingPoolManager_rejected() public {
        _assertSpoofedSrcCstRejected(SettlerMode.Exact);
        _assertSpoofedSrcCstRejected(SettlerMode.Partial);
    }

    function _assertSpoofedSrcCstRejected(SettlerMode mode) internal {
        SpoofedCst hostileSrc = _deploySpoofedCst(
            address(phoenixPool), // lies: claims the canonical PM as its parent
            MarketId.unwrap(srcCst.poolId()) // lies: claims the real src pool id
        );

        RolloverTypes.OrderData memory orderData = _orderForMode(mode);
        // Substitute the attacker-controlled token at the order level. The signed pool id
        // still points to the real srcCst, so the gate sees mismatch.
        orderData.srcCstToken = address(hostileSrc);
        orderData.rolloverParams.srcCstToken = address(hostileSrc);

        bytes memory originData = abi.encode(_gasless(orderData));
        bytes memory fillerData = _emptyFillerData(orderData);

        vm.expectPartialRevert(Settler__SrcCstNotCanonical.selector);
        vm.prank(filler);
        _settlerForMode(mode).fill(_orderDigest(orderData), originData, fillerData);
    }

    /// @notice Spoofed dstCST case: same shape as the src case but applied to dstCST.
    function testRevert_spoofedDstCst_lyingPoolManager_rejected() public {
        _assertSpoofedDstCstRejected(SettlerMode.Exact);
        _assertSpoofedDstCstRejected(SettlerMode.Partial);
    }

    function _assertSpoofedDstCstRejected(SettlerMode mode) internal {
        SpoofedCst hostileDst =
            _deploySpoofedCst(address(phoenixPool), MarketId.unwrap(dstCst.poolId()));

        RolloverTypes.OrderData memory orderData = _orderForMode(mode);
        orderData.dstCstToken = address(hostileDst);
        orderData.rolloverParams.dstCstToken = address(hostileDst);

        bytes memory originData = abi.encode(_gasless(orderData));
        bytes memory fillerData = _emptyFillerData(orderData);

        vm.expectPartialRevert(Settler__DstCstNotCanonical.selector);
        vm.prank(filler);
        _settlerForMode(mode).fill(_orderDigest(orderData), originData, fillerData);
    }

    /// @notice Unbound poolId: an order whose signed `srcPoolId` does not exist in the
    ///         canonical PM resolves to `address(0)`, which never matches the supplied
    ///         token. Reverts at the canonical gate.
    function testRevert_unboundSrcPoolId_rejected() public {
        _assertUnboundSrcPoolIdRejected(SettlerMode.Exact);
        _assertUnboundSrcPoolIdRejected(SettlerMode.Partial);
    }

    function _assertUnboundSrcPoolIdRejected(SettlerMode mode) internal {
        RolloverTypes.OrderData memory orderData = _orderForMode(mode);
        orderData.rolloverParams.srcPoolId = keccak256("not-in-phoenix");

        bytes memory originData = abi.encode(_gasless(orderData));
        bytes memory fillerData = _emptyFillerData(orderData);

        vm.expectPartialRevert(Settler__SrcCstNotCanonical.selector);
        vm.prank(filler);
        _settlerForMode(mode).fill(_orderDigest(orderData), originData, fillerData);
    }

    /// @notice The Settler constructor rejects a zero `phoenixPoolManager_` argument.
    function testRevert_constructor_zeroCorkPoolManager() public {
        vm.expectRevert(Settler__ZeroAddress.selector);
        new Settler(
            address(factory), address(0), address(this), address(this), address(this), address(this)
        );
    }

    /// @notice The Settler constructor rejects a zero `rolloverContractFactory_` argument.
    function testRevert_constructor_zeroFactory() public {
        vm.expectRevert(Settler__ZeroAddress.selector);
        new Settler(
            address(0),
            address(phoenixPool),
            address(this),
            address(this),
            address(this),
            address(this)
        );
    }

    /// @notice The Settler constructor rejects a zero `ensOwner_` argument.
    function testRevert_constructor_zeroEnsOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new Settler(
            address(factory),
            address(phoenixPool),
            address(0),
            address(this),
            address(this),
            address(this)
        );
    }

    /// @notice The Settler constructor rejects a zero `admin_` argument.
    function testRevert_constructor_zeroAdmin() public {
        vm.expectRevert(Settler__ZeroAddress.selector);
        new Settler(
            address(factory),
            address(phoenixPool),
            address(this),
            address(0),
            address(this),
            address(this)
        );
    }

    /// @notice The Settler constructor rejects a zero `pauser_` argument.
    function testRevert_constructor_zeroPauser() public {
        vm.expectRevert(Settler__ZeroAddress.selector);
        new Settler(
            address(factory),
            address(phoenixPool),
            address(this),
            address(this),
            address(0),
            address(this)
        );
    }

    /// @notice The Settler constructor rejects a zero `unpauser_` argument.
    function testRevert_constructor_zeroUnpauser() public {
        vm.expectRevert(Settler__ZeroAddress.selector);
        new Settler(
            address(factory),
            address(phoenixPool),
            address(this),
            address(this),
            address(this),
            address(0)
        );
    }

    // ── helpers ───────────────────────────────────────────────────────────

    /// @dev Minimal atomic-fill envelope for ROLLOVER+PREMIUM — the canonical gate runs
    ///      BEFORE signature verification but AFTER the atomic-tag dispatch gate, so the
    ///      `fillerData` must carry a valid `ATOMIC_TAG = 255` envelope to reach the
    ///      canonical gate at all.
    function _emptyFillerData(RolloverTypes.OrderData memory orderData)
        internal
        view
        returns (bytes memory)
    {
        RolloverTypes.RolloverIntent memory intent =
            _emptyIntent(orderData.rolloverContract, _orderDigest(orderData));
        return _rolloverFillerData(orderData.orderSize, intent, orderData);
    }
}

/// @notice Minimal spoof: lies about its `poolManager()` and `poolId()` views.
///         Mimics what a hostile cPT holder would deploy to bypass naive "ask the
///         token who its PM is" defences.
contract SpoofedCst {
    /// @notice Address this contract claims as its parent PoolManager (a lie).
    address public immutable POOL_MANAGER_LIE;
    /// @notice Pool id this contract claims to belong to (a lie).
    bytes32 public immutable POOL_ID_LIE;

    /// @param lyingPoolManager Address this token will claim as its parent PM.
    /// @param lyingPoolId Pool id this token will claim as its own.
    // Hostile mock intentionally accepts a spoofed nonzero or zero pool manager.
    // forge-lint: disable-next-line(missing-zero-check)
    constructor(address lyingPoolManager, bytes32 lyingPoolId) {
        POOL_MANAGER_LIE = lyingPoolManager;
        POOL_ID_LIE = lyingPoolId;
    }

    /// @notice Lying `IPoolShare.poolManager()` view.
    /// @return Configured lie value.
    function poolManager() external view returns (address) {
        return POOL_MANAGER_LIE;
    }

    /// @notice Lying `IPoolShare.poolId()` view.
    /// @return Configured lie value.
    function poolId() external view returns (bytes32) {
        return POOL_ID_LIE;
    }

    /// @notice Lying `IPoolShare.expiry()` view that always claims an infinite expiry.
    /// @return `type(uint256).max`.
    function expiry() external pure returns (uint256) {
        return type(uint256).max;
    }
}
