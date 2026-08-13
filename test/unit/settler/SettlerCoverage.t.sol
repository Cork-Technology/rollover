// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { BaseSettler } from "src/BaseSettler.sol";
import { ExactSettler as Settler } from "src/ExactSettler.sol";
import { LibRolloverOrder__BadOrderType } from "src/errors/LibRolloverOrderErrors.sol";
import {
    Settler__FillDeadlineMismatch,
    Settler__InvalidPremiumPaymentMode,
    Settler__OpenAfterOpenDeadline,
    Settler__OpenDeadlineMismatch,
    Settler__OrderIdMismatch,
    Settler__ReclaimBeforeFillDeadline,
    Settler__UserMismatch,
    Settler__ZeroAddress,
    Settler__ZeroMint
} from "src/errors/SettlerErrors.sol";
import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice Minimal owner surface used by the zero-mint factory fixture.
contract ZeroMintOwnerRolloverContract {
    /// @notice cPT holder returned for admission checks.
    address public immutable owner;

    /// @param owner_ Owner address reported to the Settler.
    constructor(address owner_) {
        owner = owner_;
    }
}

/// @notice Factory fixture that admits one rolloverContract and returns a zero rollover mint.
contract ZeroMintFactory {
    /// @notice RolloverContract address considered factory-deployed.
    address public deployedRolloverContract;

    /// @notice Sets the fixture rolloverContract admitted by `isDeployedRolloverContract`.
    /// @param rolloverContract RolloverContract address to mark as deployed.
    function setDeployedRolloverContract(address rolloverContract) external {
        deployedRolloverContract = rolloverContract;
    }

    /// @notice Reports whether the supplied rolloverContract is admitted by this fixture.
    /// @param rolloverContract RolloverContract address queried by the Settler.
    /// @return deployed True when `rolloverContract` is the fixture rolloverContract.
    function isDeployedRolloverContract(address rolloverContract)
        external
        view
        returns (bool deployed)
    {
        deployed = rolloverContract == deployedRolloverContract;
    }

    /// @notice Fixture hook dispatch: returns no destination CST to hit `Settler__ZeroMint`.
    /// @param _rolloverContract Ignored rolloverContract argument.
    /// @param _orderDigest Ignored order digest argument.
    /// @param _phase Ignored hook phase argument.
    /// @param _intent Ignored rollover intent argument.
    /// @param _signature Ignored cPT-holder signature argument.
    /// @param _ctx Ignored fill context argument.
    /// @param _orderData Ignored order data argument.
    /// @return dstProduced Always zero.
    /// @return srcLeftover Always zero.
    function executeIntentHooks(
        address _rolloverContract,
        bytes32 _orderDigest,
        RolloverTypes.HookPhase _phase,
        RolloverTypes.RolloverIntent calldata _intent,
        bytes calldata _signature,
        RolloverTypes.FillContext calldata _ctx,
        RolloverTypes.OrderData calldata _orderData
    ) external pure returns (uint256 dstProduced, uint256 srcLeftover) {
        (_rolloverContract, _orderDigest, _phase, _intent, _signature, _ctx, _orderData);
        return (dstProduced, srcLeftover);
    }
}

/// @notice SettlerCoverageTest — pins SettlerCoverage behaviour for the Cork Rollover suite.
contract SettlerCoverageTest is BaseTest {
    /// @notice Settler ns.
    bytes32 internal constant SETTLER_NS =
        0xb7e7c121e679474e290835181b8c64de1b75fda9ced266988999e301ae1dfb00;
    /// @notice Off order status.

    uint256 internal constant OFF_ORDER_STATUS = 0;

    function _slotOrderStatus(bytes32 orderId) internal pure returns (bytes32) {
        return keccak256(abi.encode(orderId, bytes32(uint256(SETTLER_NS) + OFF_ORDER_STATUS)));
    }

    /// @notice Pins behaviour: resolve For Reverts After Open Deadline.
    function testRevert_resolveForRevertsAfterOpenDeadline() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();

        orderData.openDeadline = uint64(block.timestamp + 1 hours);

        orderData.fillDeadline = orderData.openDeadline + 1 days;

        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);

        vm.warp(uint256(orderData.openDeadline) + 1);

        bytes memory empty;
        vm.expectRevert(Settler__OpenAfterOpenDeadline.selector);
        settler.resolveFor(g, empty);
    }

    /// @notice Pins `resolveFor` success output and covers the third-party opener path.
    function test_resolveForBuildsResolvedOrder() public view {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);

        ERC7683Types.ResolvedCrossChainOrder memory resolved =
            settler.resolveFor(g, bytes("ignored"));

        assertEq(resolved.user, orderData.user, "resolved user");
        assertEq(resolved.originChainId, orderData.originChainId, "origin chain");
        assertEq(resolved.openDeadline, uint32(orderData.openDeadline), "open deadline");
        assertEq(resolved.fillDeadline, uint32(orderData.fillDeadline), "fill deadline");
        assertEq(resolved.orderId, _orderDigest(orderData), "order digest");
        assertEq(resolved.maxSpent.length, 1, "max spent length");
        assertEq(resolved.minReceived.length, 1, "min received length");
        assertEq(resolved.fillInstructions.length, 1, "fill instruction length");
        assertEq(
            resolved.fillInstructions[0].destinationSettler,
            bytes32(uint256(uint160(orderData.settler))),
            "destination settler"
        );
        assertEq(resolved.fillInstructions[0].originData, _originData(orderData), "origin data");
    }

    /// @notice Pins behaviour: resolve reverts after open deadline.
    function testRevert_resolveRevertsAfterOpenDeadline() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.openDeadline = uint64(block.timestamp + 1 hours);
        orderData.fillDeadline = orderData.openDeadline + 1 days;
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);

        vm.warp(uint256(orderData.openDeadline) + 1);

        vm.expectRevert(Settler__OpenAfterOpenDeadline.selector);
        settler.resolveFor(g, "");
    }

    /// @notice Pins behaviour: resolve rejects envelopes whose user differs from order data.
    function testRevert_resolveRejectsUserMismatch() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        g.user = makeAddr("resolve-wrong-user");

        vm.expectRevert(Settler__UserMismatch.selector);
        settler.resolveFor(g, "");
    }

    /// @notice Pins behaviour: resolveFor rejects envelopes whose deadline differs from order data.
    function testRevert_resolveForRejectsOpenDeadlineMismatch() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        g.openDeadline = uint32(orderData.openDeadline + 1);

        vm.expectRevert(Settler__OpenDeadlineMismatch.selector);
        settler.resolveFor(g, bytes("ignored"));
    }

    /// @notice Standard on-chain ERC-7683 selector preimages are present.
    function test_onchainOrderSelectorPreimages() public pure {
        assertEq(
            bytes4(keccak256("open((uint32,bytes32,bytes))")),
            bytes4(0xe917a962),
            "open(OnchainCrossChainOrder)"
        );
        assertEq(
            bytes4(keccak256("resolve((uint32,bytes32,bytes))")),
            bytes4(0x41b477dd),
            "resolve(OnchainCrossChainOrder)"
        );
    }

    /// @notice The on-chain open path admits the order user directly without a signature.
    function test_onchainOpenUserOnlyOpensOrder() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        ERC7683Types.OnchainCrossChainOrder memory order = _onchain(orderData);

        vm.prank(cptHolder);
        settler.open(order);

        assertEq(
            uint8(settler.orderStatus(_orderDigest(orderData))),
            uint8(RolloverTypes.OrderStatus.Opened)
        );
    }

    /// @notice On-chain open requires the transaction sender to be the decoded order user.
    function testRevert_onchainOpenWrongCaller() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        ERC7683Types.OnchainCrossChainOrder memory order = _onchain(orderData);

        vm.prank(anyone);
        vm.expectRevert(Settler__UserMismatch.selector);
        settler.open(order);
    }

    /// @notice The abbreviated on-chain fillDeadline must bind to decoded order data.
    function testRevert_onchainOpenFillDeadlineMismatch() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        ERC7683Types.OnchainCrossChainOrder memory order = _onchain(orderData);
        order.fillDeadline = order.fillDeadline + 1;

        vm.prank(cptHolder);
        vm.expectRevert(Settler__FillDeadlineMismatch.selector);
        settler.open(order);
    }

    /// @notice On-chain open shares the gasless open-deadline admission ceiling.
    function testRevert_onchainOpenAfterOpenDeadline() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        ERC7683Types.OnchainCrossChainOrder memory order = _onchain(orderData);

        vm.warp(orderData.openDeadline + 1);
        vm.prank(cptHolder);
        vm.expectRevert(Settler__OpenAfterOpenDeadline.selector);
        settler.open(order);
    }

    /// @notice On-chain orders share the same Cork orderDataType gate as gasless orders.
    function testRevert_onchainResolveBadType() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        ERC7683Types.OnchainCrossChainOrder memory order = _onchain(orderData);
        order.orderDataType = keccak256("BadType");

        vm.expectRevert(LibRolloverOrder__BadOrderType.selector);
        settler.resolve(order);
    }

    /// @notice On-chain resolve projects byte-identically to the equivalent gasless envelope.
    function test_onchainResolveMatchesGaslessProjection() public view {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        ERC7683Types.OnchainCrossChainOrder memory onchainOrder = _onchain(orderData);
        ERC7683Types.GaslessCrossChainOrder memory gaslessOrder = _gasless(orderData);

        ERC7683Types.ResolvedCrossChainOrder memory onchainResolved = settler.resolve(onchainOrder);
        ERC7683Types.ResolvedCrossChainOrder memory gaslessResolved =
            settler.resolveFor(gaslessOrder, "");

        assertEq(keccak256(abi.encode(onchainResolved)), keccak256(abi.encode(gaslessResolved)));
    }

    /// @notice Pins behaviour: generic token rescue rejects a zero recipient address.
    function testRevert_recoverTokenZeroRecipient() public {
        vm.expectRevert(Settler__ZeroAddress.selector);
        settler.recoverToken(IERC20(address(srcCst)), address(0), 1);
    }

    /// @notice Pins behaviour: admission rejects unsupported premium payment modes.
    function testRevert_openForInvalidPremiumPaymentMode() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.premiumPaymentMode = 2;
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory sig = _signOrder(cptHolderPk, orderData);

        vm.expectRevert(Settler__InvalidPremiumPaymentMode.selector);
        settler.openFor(g, sig, bytes(""));
    }

    /// @notice Pins behaviour: admission rejects gasless envelopes whose openDeadline differs from signed order data.
    function testRevert_openForOpenDeadlineMismatch() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        g.openDeadline = uint32(orderData.openDeadline + 1);
        bytes memory sig = _signOrder(cptHolderPk, orderData);

        vm.expectRevert(Settler__OpenDeadlineMismatch.selector);
        settler.openFor(g, sig, bytes(""));
    }

    /// @notice Pins behaviour: reverts when markExpired order id mismatch.
    function testRevert_markExpiredOrderIdMismatch() public {
        RolloverTypes.OrderData memory orderA = _baseOrder();
        orderA.orderSalt = 7796;
        bytes32 digestA = _openOrder(orderA);

        RolloverTypes.OrderData memory orderB = _baseOrder();
        orderB.orderSalt = 7797;
        bytes memory originDataB = _originData(orderB);

        vm.warp(uint256(orderA.fillDeadline) + 1);

        vm.expectRevert(Settler__OrderIdMismatch.selector);
        settler.markExpired(digestA, originDataB);

        assertEq(
            uint8(settler.orderStatus(digestA)),
            uint8(RolloverTypes.OrderStatus.Opened),
            "order A must remain Opened after digest-mismatch revert"
        );
    }

    /// @notice Pins behaviour: reverts when cancel Never Opened Order.
    function testRevert_cancelNeverOpenedOrder() public {
        bytes32 fakeOrderId = bytes32(uint256(0xDEADBEEFC0DE));

        assertEq(
            uint8(settler.orderStatus(fakeOrderId)),
            uint8(RolloverTypes.OrderStatus.None),
            "precond: fakeOrderId has no FSM record"
        );

        RolloverTypes.OrderData memory orderData = _baseOrder();
        bytes memory originData = _originData(orderData);
        bytes memory anySig = hex"00";
        vm.expectRevert(Settler__OrderIdMismatch.selector);
        settler.cancel(fakeOrderId, originData, anySig);
    }

    /// @notice Pins behaviour: reclaim re-derives origin data and rejects mismatched order ids.
    function testRevert_reclaimOrderIdMismatch() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.premiumPaymentMode = RolloverTypes.PREMIUM_PAYMENT_MODE_ATOMIC_OR_SEPARATE;
        bytes32 wrongOrderId = bytes32(uint256(0xBADC0DE));

        vm.expectRevert(Settler__OrderIdMismatch.selector);
        settler.reclaim(wrongOrderId, filler, bytes32(0), _originData(orderData));
    }

    /// @notice Pins behaviour: reclaim cannot run until after the fill deadline.
    function testRevert_reclaimBeforeFillDeadline() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.premiumPaymentMode = RolloverTypes.PREMIUM_PAYMENT_MODE_ATOMIC_OR_SEPARATE;
        bytes32 orderDigest = _openOrder(orderData);

        vm.expectRevert(Settler__ReclaimBeforeFillDeadline.selector);
        settler.reclaim(orderDigest, filler, bytes32(0), _originData(orderData));
    }

    /// @notice Pins the Settler's rollover zero-mint guard after factory dispatch.
    function testRevert_fillZeroMintFromFactory() public {
        ZeroMintFactory zeroMintFactory = new ZeroMintFactory();
        ZeroMintOwnerRolloverContract zeroMintRolloverContract =
            new ZeroMintOwnerRolloverContract(cptHolder);
        zeroMintFactory.setDeployedRolloverContract(address(zeroMintRolloverContract));

        Settler zeroMintSettler = new Settler(
            address(zeroMintFactory),
            address(phoenixPool),
            address(this),
            address(this),
            address(this),
            address(this)
        );

        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.settler = address(zeroMintSettler);
        orderData.rolloverContract = address(zeroMintRolloverContract);
        orderData.orderSalt = 0xA11CE;
        orderData.orderSize = 100e18;
        orderData.rolloverParams.settler = address(zeroMintSettler);

        bytes32 orderDigest = _orderDigest(orderData);
        RolloverTypes.RolloverIntent memory intent =
            _emptyIntent(address(zeroMintRolloverContract), orderDigest);
        bytes memory fillerData = _rolloverFillerData(orderData.orderSize, intent, orderData);

        vm.startPrank(filler);
        srcCst.approve(address(zeroMintSettler), orderData.orderSize);
        vm.expectRevert(Settler__ZeroMint.selector);
        zeroMintSettler.fill(orderDigest, _originData(orderData), fillerData);
        vm.stopPrank();
    }
}
