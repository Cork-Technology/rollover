// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { FillScaffold } from "../../base/FillScaffold.sol";
import { DepositDstCptModule } from "../../mocks/modules/HookModules.sol";
import { Typehashes } from "src/libraries/Typehashes.sol";
import { PostRolloverDstCptTransferModule } from "src/modules/PostRolloverDstCptTransferModule.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice Regression coverage for the production post-rollover dstCPT hook. The hook routes
///         only the post-deposit minted dstCPT amount and leaves standing dstCPT in the
///         rolloverContract for the final bidirectional guard to preserve.
contract PostRolloverDstCptTransferModuleTest is FillScaffold {
    /// @notice Full-fill amount used by happy-path and revert tests.
    uint256 internal constant FILL = 1_000e18;
    /// @notice Partial-fill amount below `FILL`.
    uint256 internal constant PARTIAL_FILL = 400e18;
    /// @notice Source cPT made available for underfill tests.
    uint256 internal constant UNDERFILLED_SRC_CPT = 600e18;
    /// @notice Standing dstCPT balance used to prove the module does not sweep inventory.
    uint256 internal constant PRE_EXISTING_CPT = 500e18;
    /// @notice Premium approved for the shared fill scaffold.
    uint256 internal constant PREMIUM = 10e18;

    /// @notice Selector for the final dstCPT restoration guard.
    bytes4 internal constant DST_CPT_NOT_RESTORED_SELECTOR =
        bytes4(keccak256("CorkRolloverContract__DstCptNotRestored(uint256,uint256)"));

    /// @notice cPT roller recipient used by the standard post-rollover hook.
    address internal cptRoller = address(0xC9A7);
    /// @notice Production minted-amount dstCPT post-hook under test.
    PostRolloverDstCptTransferModule internal dstCptTransferModule;
    /// @notice Test hook that intentionally routes less than the minted dstCPT amount.
    DepositDstCptModule internal underRouteModule;
    /// @notice Test hook attested as mid-rollover to prove pre-deposit dstCPT drains are caught.
    DepositDstCptModule internal midDrainModule;

    /// @notice Deploys and attests the production module and adversarial test hooks.
    function setUp() public override {
        super.setUp();
        dstCptTransferModule = new PostRolloverDstCptTransferModule();
        underRouteModule = new DepositDstCptModule();
        midDrainModule = new DepositDstCptModule();
        erc7484.setAttestedType(
            address(dstCptTransferModule), Typehashes.MODULE_TYPE_POST_ROLLOVER_HOOK
        );
        erc7484.setAttestedType(
            address(underRouteModule), Typehashes.MODULE_TYPE_POST_ROLLOVER_HOOK
        );
        erc7484.setAttestedType(address(midDrainModule), Typehashes.MODULE_TYPE_MID_ROLLOVER_HOOK);
    }

    /// @notice Full exact fill routes the whole newly minted dstCPT amount to the roller.
    function test_fullFill_routesNewlyMintedDstCpt() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent
        ) = _openExactOrder(FILL, FILL, false);

        uint256 rollerBefore = dstCpt.balanceOf(cptRoller);
        _doRolloverAs(orderDigest, orderData, intent, FILL, filler);

        assertEq(dstCpt.balanceOf(rolloverContract), 0, "rolloverContract dstCPT restored");
        assertEq(dstCpt.balanceOf(cptRoller) - rollerBefore, FILL, "roller receives full mint");
    }

    /// @notice Partial fill routes only the partial newly minted dstCPT amount.
    function test_partialFill_routesOnlyPartialDstCptMinted() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent
        ) = _openPartialOrder(FILL, PARTIAL_FILL);

        uint256 rollerBefore = dstCpt.balanceOf(cptRoller);
        _doRolloverAs(orderDigest, orderData, intent, PARTIAL_FILL, filler);

        assertEq(dstCpt.balanceOf(rolloverContract), 0, "rolloverContract dstCPT restored");
        assertEq(
            dstCpt.balanceOf(cptRoller) - rollerBefore, PARTIAL_FILL, "roller receives partial mint"
        );
    }

    /// @notice Exact underfill routes only the actually minted dstCPT amount.
    function test_underfill_routesOnlyActuallyMintedDstCpt() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent
        ) = _openExactOrder(FILL, UNDERFILLED_SRC_CPT, true);

        uint256 rollerBefore = dstCpt.balanceOf(cptRoller);
        _doRolloverAs(orderDigest, orderData, intent, FILL, filler);

        assertEq(dstCpt.balanceOf(rolloverContract), 0, "rolloverContract dstCPT restored");
        assertEq(
            dstCpt.balanceOf(cptRoller) - rollerBefore,
            UNDERFILLED_SRC_CPT,
            "roller receives underfilled mint"
        );
    }

    /// @notice Missing post hook leaves minted dstCPT in the rolloverContract and reverts.
    function testRevert_missingPostHookLeavesDstCptAndRevertsFinalGuard() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent
        ) = _openOrderWithPostHooks(FILL, FILL, false, false, new RolloverTypes.Call[](0));

        vm.expectPartialRevert(DST_CPT_NOT_RESTORED_SELECTOR);
        _doRolloverAs(orderDigest, orderData, intent, FILL, filler);
    }

    /// @notice Under-routing the post hook leaves residual dstCPT and reverts.
    function testRevert_underRoutingPostHookLeavesDstCptAndRevertsFinalGuard() public {
        RolloverTypes.Call[] memory postHooks = new RolloverTypes.Call[](1);
        postHooks[0] = _hook(
            address(underRouteModule),
            abi.encodeWithSignature(
                "execute(address,address,uint256)", address(dstCpt), cptRoller, FILL - 1
            )
        );
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent
        ) = _openOrderWithPostHooks(FILL, FILL, false, false, postHooks);

        vm.expectPartialRevert(DST_CPT_NOT_RESTORED_SELECTOR);
        _doRolloverAs(orderDigest, orderData, intent, FILL, filler);
    }

    /// @notice Minted-amount hook leaves pre-existing dstCPT at the entry snapshot.
    function test_preExistingDstCptIsNotSweptByMintedHook() public {
        dstCpt.mint(rolloverContract, PRE_EXISTING_CPT);
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent
        ) = _openExactOrder(FILL, FILL, false);

        uint256 rollerBefore = dstCpt.balanceOf(cptRoller);
        _doRolloverAs(orderDigest, orderData, intent, FILL, filler);

        assertEq(
            dstCpt.balanceOf(rolloverContract),
            PRE_EXISTING_CPT,
            "standing dstCPT remains at entry snapshot"
        );
        assertEq(dstCpt.balanceOf(cptRoller) - rollerBefore, FILL, "only minted amount routed");
    }

    /// @notice A pre-deposit standing dstCPT drain cannot mask a matching deposit mint.
    function testRevert_preDepositDrainCannotMaskMatchingDstCptMint() public {
        dstCpt.mint(rolloverContract, FILL);

        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = FILL;
        RolloverTypes.Call[] memory preHooks = new RolloverTypes.Call[](1);
        preHooks[0] = _hook(
            address(sourceSrcCptModule),
            abi.encodeWithSignature("execute(address,uint256)", address(srcCpt), FILL)
        );
        RolloverTypes.Call[] memory midHooks = new RolloverTypes.Call[](1);
        midHooks[0] = _hook(
            address(midDrainModule),
            abi.encodeWithSignature(
                "execute(address,address,uint256)", address(dstCpt), address(0xD4A11), FILL
            )
        );
        RolloverTypes.RolloverIntent memory intent = _intentWithHooks(
            rolloverContract, bytes32(0), preHooks, midHooks, _standardPostHooks()
        );
        orderData.rolloverIntentHash = _zeroDigestHash(intent);
        bytes32 orderDigest = _openOrder(orderData);
        intent.orderDigest = orderDigest;
        _approveFiller(FILL, PREMIUM);

        vm.expectPartialRevert(DST_CPT_NOT_RESTORED_SELECTOR);
        _doRolloverAs(orderDigest, orderData, intent, FILL, filler);
    }

    /// @notice Opens an exact-mode order with the standard dstCPT post hook.
    function _openExactOrder(uint256 orderSize, uint256 sourcedSrcCpt, bool allowUnderfill)
        internal
        returns (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent
        )
    {
        RolloverTypes.Call[] memory postHooks = _standardPostHooks();
        return _openOrderWithPostHooks(orderSize, sourcedSrcCpt, false, allowUnderfill, postHooks);
    }

    /// @notice Opens a partial-mode order with the standard dstCPT post hook.
    function _openPartialOrder(uint256 orderSize, uint256 sourcedSrcCpt)
        internal
        returns (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent
        )
    {
        RolloverTypes.Call[] memory postHooks = _standardPostHooks();
        return _openOrderWithPostHooks(orderSize, sourcedSrcCpt, true, false, postHooks);
    }

    /// @notice Opens an order with caller-provided post hooks.
    function _openOrderWithPostHooks(
        uint256 orderSize,
        uint256 sourcedSrcCpt,
        bool usePartialSettler,
        bool allowUnderfill,
        RolloverTypes.Call[] memory postHooks
    )
        internal
        returns (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent
        )
    {
        orderData = usePartialSettler ? _usePartialSettler(_baseOrder()) : _baseOrder();
        orderData.orderSize = orderSize;
        orderData.allowUnderfill = allowUnderfill;
        RolloverTypes.Call[] memory preHooks = new RolloverTypes.Call[](1);
        preHooks[0] = _hook(
            address(sourceSrcCptModule),
            abi.encodeWithSignature("execute(address,uint256)", address(srcCpt), sourcedSrcCpt)
        );
        intent = _intentWithHooks(
            rolloverContract, bytes32(0), preHooks, new RolloverTypes.Call[](0), postHooks
        );
        orderData.rolloverIntentHash = _zeroDigestHash(intent);
        orderDigest = _openOrder(orderData);
        intent.orderDigest = orderDigest;
        _approveFiller(orderSize, PREMIUM);
    }

    /// @notice Builds the standard post hook that routes dynamic minted dstCPT to `cptRoller`.
    function _standardPostHooks() internal view returns (RolloverTypes.Call[] memory postHooks) {
        postHooks = new RolloverTypes.Call[](1);
        postHooks[0] = _hook(
            address(dstCptTransferModule),
            abi.encodeWithSignature("execute(address,address)", address(dstCpt), cptRoller)
        );
    }
}
