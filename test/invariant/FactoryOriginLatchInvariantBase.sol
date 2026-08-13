// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { FillScaffold } from "../base/FillScaffold.sol";
import { MarketId } from "src/interfaces/external/phoenix/IPoolManager.sol";
import { IRolloverHookDispatcher } from "src/interfaces/rollover/IRolloverHookDispatcher.sol";
import { Typehashes } from "src/libraries/Typehashes.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice Hook target that asserts the factory origin-settler latch during dispatch.
contract FactoryOriginLatchProbe {
    /// @notice Revert unless the factory latch equals `expected`.
    /// @param factoryAddr Cork factory address.
    /// @param expected Expected active origin settler.
    function assertOrigin(address factoryAddr, address expected) external view {
        if (IRolloverHookDispatcher(factoryAddr).originatingSettler() != expected) {
            revert("FactoryOriginLatchProbe: origin mismatch");
        }
    }
}

/// @notice N-INV-FACTORY-ORIGIN-LATCH-SCOPED — the factory's transient origin-settler latch
///         is visible only during an active Settler -> Factory -> RolloverContract dispatch frame and is
///         zero between dispatches, including after reverts.
abstract contract FactoryOriginLatchInvariantBase is FillScaffold {
    /// @notice Source amount used by bounded valid dispatches.
    uint256 internal constant LATCH_FILL = 1_000e18;

    /// @notice Hook probe attested under PRE_ROLLOVER.
    FactoryOriginLatchProbe internal originLatchProbe;

    /// @notice Monotonic salt for valid orders created by handler actions.
    uint64 internal nextLatchSalt = 10_000;

    /// @notice Limit successful fills so the invariant campaign stays cheap and deterministic.
    uint8 internal validDispatches;

    /// @notice Install the origin-latch probe and target this contract's handler actions.
    function setUp() public virtual override {
        super.setUp();
        originLatchProbe = new FactoryOriginLatchProbe();
        erc7484.setAttestedType(address(originLatchProbe), Typehashes.MODULE_TYPE_PRE_ROLLOVER_HOOK);

        targetContract(address(this));
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = this.driveExactDispatch.selector;
        selectors[1] = this.drivePartialDispatch.selector;
        selectors[2] = this.driveUnknownRolloverContractRevert.selector;
        selectors[3] = this.driveOriginMismatchRevert.selector;
        targetSelector(FuzzSelector({ addr: address(this), selectors: selectors }));
    }

    /// @notice Handler action: drive one valid exact-mode dispatch with an in-frame latch probe.
    function driveExactDispatch() external {
        if (validDispatches >= 4) {
            return;
        }
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSalt = ++nextLatchSalt;
        orderData.allowPartialFills = false;
        orderData.orderSize = LATCH_FILL;

        RolloverTypes.RolloverIntent memory intent = _intentWithOriginProbe(address(settler));
        orderData.rolloverIntentHash = _zeroDigestHash(intent);
        bytes32 orderDigest = _openOrder(orderData);
        intent.orderDigest = orderDigest;
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);

        _approveFiller(LATCH_FILL, 0);
        _doRolloverAs(orderDigest, orderData, intent, LATCH_FILL, filler);
        validDispatches++;
    }

    /// @notice Handler action: drive one valid partial-mode dispatch with an in-frame latch probe.
    function drivePartialDispatch() external {
        if (validDispatches >= 4) {
            return;
        }
        RolloverTypes.OrderData memory orderData = _usePartialSettler(_baseOrder());
        orderData.orderSalt = ++nextLatchSalt;
        orderData.orderSize = LATCH_FILL;

        RolloverTypes.RolloverIntent memory intent = _intentWithOriginProbe(address(partialSettler));
        orderData.rolloverIntentHash = _zeroDigestHash(intent);
        bytes32 orderDigest = _openOrder(orderData);
        intent.orderDigest = orderDigest;
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);

        _approveFiller(LATCH_FILL, 0);
        _doRolloverAs(orderDigest, orderData, intent, LATCH_FILL, filler);
        validDispatches++;
    }

    /// @notice Handler action: exercise unknown-rolloverContract dispatch, which must leave the latch zero.
    /// @param seed Fuzz seed for the fake rolloverContract and digest.
    function driveUnknownRolloverContractRevert(uint256 seed) external {
        address fakeRolloverContract =
            address(uint160(uint256(keccak256(abi.encode("fake-rolloverContract", seed)))));
        bytes32 digest = bytes32(seed | 1);
        RolloverTypes.RolloverIntent memory intent = _emptyIntent(fakeRolloverContract, digest);
        RolloverTypes.FillContext memory fillContext = _fillContext(
            filler,
            LATCH_FILL,
            bytes32(0),
            uint64(block.timestamp + 1 days),
            false,
            LATCH_FILL,
            address(settler),
            address(premiumToken),
            0
        );

        vm.prank(address(settler));
        try factory.executeIntentHooks(
            fakeRolloverContract,
            digest,
            RolloverTypes.HookPhase.ROLLOVER,
            intent,
            bytes(""),
            fillContext,
            _emptyOrderData()
        ) returns (
            uint256, uint256
        ) { }
            catch { }
    }

    /// @notice Handler action: exercise origin-settler mismatch, which must leave the latch zero.
    /// @param seed Fuzz seed for the digest.
    function driveOriginMismatchRevert(uint256 seed) external {
        bytes32 digest = bytes32(seed | 1);
        RolloverTypes.RolloverIntent memory intent = _emptyIntent(rolloverContract, digest);
        RolloverTypes.FillContext memory fillContext = _fillContext(
            filler,
            LATCH_FILL,
            bytes32(0),
            uint64(block.timestamp + 1 days),
            false,
            LATCH_FILL,
            address(partialSettler),
            address(premiumToken),
            0
        );

        vm.prank(address(settler));
        try factory.executeIntentHooks(
            rolloverContract,
            digest,
            RolloverTypes.HookPhase.ROLLOVER,
            intent,
            bytes(""),
            fillContext,
            _emptyOrderData()
        ) returns (
            uint256, uint256
        ) { }
            catch { }
    }

    /// @notice Invariant: the origin-settler latch is not visible outside dispatch frames.
    function invariant_originLatchClearedBetweenDispatches() public view {
        assertEq(
            factory.originatingSettler(),
            address(0),
            "N-INV-FACTORY-ORIGIN-LATCH-SCOPED: latch leaked outside dispatch"
        );
    }

    function _intentWithOriginProbe(address expectedOrigin)
        internal
        view
        returns (RolloverTypes.RolloverIntent memory intent)
    {
        RolloverTypes.Call[] memory preHooks = new RolloverTypes.Call[](2);
        preHooks[0] = _hook(
            address(sourceSrcCptModule),
            abi.encodeWithSignature("execute(address,uint256)", address(srcCpt), LATCH_FILL)
        );
        preHooks[1] = _hook(
            address(originLatchProbe),
            abi.encodeWithSignature(
                "assertOrigin(address,address)", address(factory), expectedOrigin
            )
        );
        RolloverTypes.Call[] memory postHooks = new RolloverTypes.Call[](1);
        postHooks[0] = _hook(
            address(consumeDstCptModule),
            abi.encodeWithSignature("execute(address)", address(dstCpt))
        );
        return _intentWithHooks(
            rolloverContract, bytes32(0), preHooks, new RolloverTypes.Call[](0), postHooks
        );
    }

    function _rolloverParamsFor(address originSettler)
        internal
        view
        returns (RolloverTypes.RolloverParams memory params)
    {
        params = RolloverTypes.RolloverParams({
            srcCstToken: address(srcCst),
            dstCstToken: address(dstCst),
            minCaReceived: 0,
            minSharesOut: 0,
            srcPoolId: MarketId.unwrap(srcCst.poolId()),
            dstPoolId: MarketId.unwrap(dstCst.poolId()),
            settler: originSettler,
            jitMarketHash: bytes32(0)
        });
    }
}
