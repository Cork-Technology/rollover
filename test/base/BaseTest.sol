// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { MockERC7484 } from "../mocks/MockERC7484.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { DeployPermit2 } from "permit2-test/utils/DeployPermit2.sol";
import { ISignatureTransfer } from "permit2/interfaces/ISignatureTransfer.sol";
import { BaseFiller } from "src/BaseFiller.sol";
import { CorkRolloverContract } from "src/CorkRolloverContract.sol";
import { CorkRolloverContractFactory } from "src/CorkRolloverContractFactory.sol";
import { EvcRolloverAdapter } from "src/EvcRolloverAdapter.sol";
import { ExactSettler } from "src/ExactSettler.sol";
import { PartialSettler } from "src/PartialSettler.sol";
import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import { IMarketRegistry } from "src/interfaces/external/market-registry/IMarketRegistry.sol";
import { IDefaultCorkController } from "src/interfaces/external/phoenix/IDefaultCorkController.sol";
import { ICorkRolloverContract } from "src/interfaces/rollover/ICorkRolloverContract.sol";
import { ISettler } from "src/interfaces/settlers/ISettler.sol";
import { LibAuthenticatedHooks } from "src/libraries/LibAuthenticatedHooks.sol";
import { LibFillerAuth } from "src/libraries/LibFillerAuth.sol";
import { LibFillerPayload } from "src/libraries/LibFillerPayload.sol";
import { LibSettlerHashing } from "src/libraries/LibSettlerHashing.sol";
import { Typehashes } from "src/libraries/Typehashes.sol";
import { ApproveModule } from "src/modules/ApproveModule.sol";
import { MidRolloverReferenceModule } from "src/modules/MidRolloverReferenceModule.sol";
import { PostRolloverReferenceModule } from "src/modules/PostRolloverReferenceModule.sol";
import { PreRolloverReferenceModule } from "src/modules/PreRolloverReferenceModule.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice Minimal helper interface for reading Permit2's EIP-712 domain
///         separator from the etched canonical instance in tests.
interface IPermit2DomainSeparator {
    /// @notice Read Permit2's cached EIP-712 domain separator.
    /// @return Domain separator computed during Permit2 construction.
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockCpt, MockPhoenixPoolManager } from "../mocks/MockPhoenix.sol";
import { ConsumeAllDstCptModule, SourceSrcCptModule } from "../mocks/modules/HookModules.sol";
import { PremiumPullModule } from "../mocks/modules/PremiumPullModule.sol";
import { RolloverDepositModule } from "../mocks/modules/RolloverDepositModule.sol";
import { IPoolManager, MarketId } from "src/interfaces/external/phoenix/IPoolManager.sol";

/// @notice Shared scaffold for Cork Rollover unit tests — deploys factory, settler, rolloverContract implementation, attester registry, mock Phoenix pool, mock tokens, reference and pull/deposit modules, and the BaseFiller; provides EIP-712 digest, order-construction, signing, and rollover-fillerData helpers.
abstract contract BaseTest is Test {
    /// @notice Fill-mode selector for tests that exercise shared settler behavior.
    enum SettlerMode {
        Exact,
        Partial
    }

    /// @notice Admin EOA used across the test harness.
    address internal admin = address(0xA0);
    /// @notice Manager EOA used across the test harness.

    address internal manager = address(0xB0);
    /// @notice Guardian EOA used across the test harness.

    address internal guardian = address(0xC0);
    /// @notice cPT holder EOA used across the test harness.

    address internal cptHolder;
    /// @notice Private key for the cPT holder test EOA.

    uint256 internal cptHolderPk;
    /// @notice Filler EOA used across the test harness.

    address internal filler = address(0xF1);
    /// @notice Anyone.

    address internal anyone = address(0x9999);
    /// @notice Default attester.

    address internal defaultAttester = address(0xDEFA);
    /// @notice Erc7484.

    MockERC7484 internal erc7484;
    /// @notice RolloverContract impl.

    CorkRolloverContract internal rolloverContractImpl;
    /// @notice Factory.

    CorkRolloverContractFactory internal factory;
    /// @notice External per-rolloverContract trust-config timelock used by the factory.

    TimelockController internal trustConfigTimelock;
    /// @notice Exact-mode Settler.

    ExactSettler internal settler;
    /// @notice Partial-mode Settler.

    PartialSettler internal partialSettler;
    /// @notice RolloverContract.

    address internal rolloverContract;
    /// @notice Approve module.

    ApproveModule internal approveModule;
    /// @notice Pre module.

    PreRolloverReferenceModule internal preModule;
    /// @notice Mid module.

    MidRolloverReferenceModule internal midModule;
    /// @notice Post module.

    PostRolloverReferenceModule internal postModule;
    /// @notice Premium pull.

    PremiumPullModule internal premiumPull;
    /// @notice Rollover deposit.

    RolloverDepositModule internal rolloverDeposit;
    /// @notice Base filler.

    BaseFiller internal baseFiller;
    /// @notice Src cst.

    MockERC20 internal srcCst;
    /// @notice Dst cst.

    MockERC20 internal dstCst;
    /// @notice Premium token.

    MockERC20 internal premiumToken;
    /// @notice Phoenix pool.

    MockPhoenixPoolManager internal phoenixPool;
    /// @notice Src cpt.

    MockCpt internal srcCpt;
    /// @notice Dst cpt.

    MockCpt internal dstCpt;
    /// @notice Ca src.

    MockERC20 internal caSrc;
    /// @notice Source src cpt module.

    SourceSrcCptModule internal sourceSrcCptModule;
    /// @notice Consume dst cpt module.

    ConsumeAllDstCptModule internal consumeDstCptModule;
    /// @notice Cork order data type.

    bytes32 internal constant CORK_ORDER_DATA_TYPE = Typehashes.ORDER_DATA_TYPEHASH;

    /// @notice Canonical Permit2 address. Real deployed bytecode is etched here by
    ///         `DeployPermit2.deployPermit2()` in setUp so test contracts can sign
    ///         + dispatch real Permit2 transfers without recompiling Permit2's
    ///         pinned `0.8.17` source.
    address internal constant PERMIT2_ADDR = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /// @notice Permit2 instance shared across the test harness. Etched in setUp at
    ///         `PERMIT2_ADDR` and used by the EVC adapter funding path.
    ISignatureTransfer internal permit2;

    /// @notice Test fixture setup.

    function setUp() public virtual {
        (cptHolder, cptHolderPk) = makeAddrAndKey("cptHolder");
        DeployPermit2 dp = new DeployPermit2();
        dp.deployPermit2();
        permit2 = ISignatureTransfer(PERMIT2_ADDR);

        erc7484 = new MockERC7484();

        rolloverContractImpl = new CorkRolloverContract();
        address[] memory defaults = new address[](1);
        defaults[0] = defaultAttester;
        trustConfigTimelock = _deployTrustConfigTimelockForNextFactory();
        factory = new CorkRolloverContractFactory(
            address(rolloverContractImpl),
            address(erc7484),
            1,
            defaults,
            address(trustConfigTimelock),
            manager,
            address(this),
            address(this),
            address(this),
            address(this)
        );

        // INV-CST-CANONICAL — the canonical Phoenix PoolManager is the trust root that
        // Settler.CORK_POOL_MANAGER points at. Deploy it before Settler so the immutable can
        // be wired correctly.
        phoenixPool = new MockPhoenixPoolManager();

        settler = new ExactSettler(
            address(factory),
            address(phoenixPool),
            address(this),
            address(this),
            address(this),
            address(this)
        );
        partialSettler = new PartialSettler(
            address(factory),
            address(phoenixPool),
            address(this),
            address(this),
            address(this),
            address(this)
        );

        factory.approveSettler(address(settler));
        factory.approveSettler(address(partialSettler));

        approveModule = new ApproveModule();
        preModule = new PreRolloverReferenceModule();
        midModule = new MidRolloverReferenceModule();
        postModule = new PostRolloverReferenceModule();
        premiumPull = new PremiumPullModule();
        rolloverDeposit = new RolloverDepositModule();

        baseFiller = new BaseFiller(
            ISettler(address(settler)),
            ISettler(address(partialSettler)),
            IPoolManager(address(0)),
            IDefaultCorkController(address(0)),
            IMarketRegistry(address(0))
        );

        _registerModule(address(approveModule));
        _registerModule(address(preModule));
        _registerModule(address(midModule));
        _registerModule(address(postModule));

        _registerModule(address(premiumPull));
        _registerModule(address(rolloverDeposit));

        vm.prank(cptHolder);
        rolloverContract = factory.deployRolloverContract();

        srcCst = new MockERC20("srcCST", "SRC", 18);
        dstCst = new MockERC20("dstCST", "DST", 18);
        premiumToken = new MockERC20("Premium", "PRM", 18);

        srcCst.mint(filler, 1_000_000e18);
        dstCst.mint(filler, 1_000_000e18);
        premiumToken.mint(filler, 1_000_000e18);

        // Atomic-fill: the Settler now pulls premium + srcCST in a single frame, so the
        // canonical `filler` actor needs both approvals on both mode Settlers ahead of
        // every direct `settler.fill(...)` call. Pre-existing subclasses set their own
        // overrides on top of these.
        vm.startPrank(filler);
        srcCst.approve(address(settler), type(uint256).max);
        srcCst.approve(address(partialSettler), type(uint256).max);
        premiumToken.approve(address(settler), type(uint256).max);
        premiumToken.approve(address(partialSettler), type(uint256).max);
        vm.stopPrank();

        srcCpt = new MockCpt("srcCPT", "SCPT");
        dstCpt = new MockCpt("dstCPT", "DCPT");
        caSrc = new MockERC20("CA", "CA", 18);
        phoenixPool.bind(srcCst.poolId(), srcCst, srcCpt, caSrc);
        phoenixPool.bind(dstCst.poolId(), dstCst, dstCpt, caSrc);
        srcCst.setPoolManager(phoenixPool);
        dstCst.setPoolManager(phoenixPool);
        sourceSrcCptModule = new SourceSrcCptModule();
        consumeDstCptModule = new ConsumeAllDstCptModule();

        erc7484.setAttestedType(
            address(sourceSrcCptModule), Typehashes.MODULE_TYPE_PRE_ROLLOVER_HOOK
        );
        erc7484.setAttestedType(
            address(consumeDstCptModule), Typehashes.MODULE_TYPE_POST_ROLLOVER_HOOK
        );
        erc7484.setAttestedType(address(approveModule), Typehashes.MODULE_TYPE_EXECUTOR);
        erc7484.setAttestedType(address(preModule), Typehashes.MODULE_TYPE_PRE_ROLLOVER_HOOK);
        erc7484.setAttestedType(address(midModule), Typehashes.MODULE_TYPE_MID_ROLLOVER_HOOK);
        erc7484.setAttestedType(address(postModule), Typehashes.MODULE_TYPE_POST_ROLLOVER_HOOK);
        erc7484.setAttestedType(address(premiumPull), Typehashes.MODULE_TYPE_EXECUTOR);
        erc7484.setAttestedType(address(rolloverDeposit), Typehashes.MODULE_TYPE_PRE_ROLLOVER_HOOK);

        vm.label(address(phoenixPool), "phoenixPool");
        vm.label(address(srcCpt), "srcCpt");
        vm.label(address(dstCpt), "dstCpt");
        vm.label(address(caSrc), "caSrc");

        vm.label(cptHolder, "cptHolder");
        vm.label(filler, "filler");
        vm.label(address(factory), "factory");
        vm.label(address(rolloverContract), "rolloverContract");
        vm.label(address(settler), "settler");
        vm.label(address(partialSettler), "partialSettler");
    }

    /// @dev Deploy a trust-config timelock pre-wired for the next contract created by this test.
    function _deployTrustConfigTimelockForNextFactory()
        internal
        returns (TimelockController controller)
    {
        uint64 nonce = vm.getNonce(address(this));
        address predictedFactory = vm.computeCreateAddress(address(this), nonce + 1);

        address[] memory proposers = new address[](1);
        proposers[0] = predictedFactory;
        address[] memory executors = new address[](1);
        executors[0] = predictedFactory;

        controller =
            new TimelockController(_trustConfigDelay(), proposers, executors, address(this));
    }

    function _trustConfigDelay() internal pure virtual returns (uint256) {
        return 1 hours;
    }

    function _registerModule(address) internal pure { }

    function _emptyHooks() internal pure returns (RolloverTypes.Call[] memory h) {
        h = new RolloverTypes.Call[](0);
    }

    function _baseOrder() internal view returns (RolloverTypes.OrderData memory orderData) {
        orderData.user = cptHolder;
        orderData.settler = address(settler);
        orderData.fillerHint = filler;
        orderData.exclusiveFiller = address(0);
        orderData.srcCstToken = address(srcCst);
        orderData.dstCstToken = address(dstCst);
        orderData.premiumToken = address(premiumToken);
        orderData.rolloverContract = rolloverContract;
        orderData.originChainId = uint64(block.chainid);
        orderData.destinationChainId = uint64(block.chainid);
        orderData.openDeadline = uint64(block.timestamp + 1 days);
        orderData.fillDeadline = uint64(block.timestamp + 2 days);
        orderData.orderSalt = 1;
        orderData.orderSize = 1_000e18;
        orderData.minPremiumPerShare = 1e16;
        orderData.premiumPaymentMode = RolloverTypes.PREMIUM_PAYMENT_MODE_ATOMIC_ONLY;
        orderData.rolloverIntentHash = bytes32(uint256(0xC1));
        orderData.rolloverParams.srcCstToken = address(srcCst);
        orderData.rolloverParams.dstCstToken = address(dstCst);
        orderData.rolloverParams.srcPoolId = MarketId.unwrap(srcCst.poolId());
        orderData.rolloverParams.dstPoolId = MarketId.unwrap(dstCst.poolId());
        orderData.rolloverParams.settler = address(settler);
    }

    function _usePartialSettler(RolloverTypes.OrderData memory orderData)
        internal
        view
        returns (RolloverTypes.OrderData memory)
    {
        orderData.allowPartialFills = true;
        orderData.settler = address(partialSettler);
        orderData.rolloverParams.settler = address(partialSettler);
        return orderData;
    }

    function _orderForMode(SettlerMode mode)
        internal
        view
        returns (RolloverTypes.OrderData memory orderData)
    {
        orderData = _baseOrder();
        if (mode == SettlerMode.Partial) {
            orderData = _usePartialSettler(orderData);
        }
    }

    function _settlerForMode(SettlerMode mode) internal view returns (ISettler) {
        return mode == SettlerMode.Partial
            ? ISettler(address(partialSettler))
            : ISettler(address(settler));
    }

    function _settlerAddressForMode(SettlerMode mode) internal view returns (address) {
        return mode == SettlerMode.Partial ? address(partialSettler) : address(settler);
    }

    /// @dev Zero-initialised `OrderData` for tests that exercise envelope/factory checks
    ///      which fire BEFORE the rolloverContract's `_validateOrderDataBinding`. The empty struct never
    ///      reaches the binding check on those paths; tests that DO hit the binding (positive
    ///      and negative fillContext ↔ orderData tests) build a real orderData via `_baseOrder()`.
    function _emptyOrderData() internal pure returns (RolloverTypes.OrderData memory od) {
        return od;
    }

    function _gasless(RolloverTypes.OrderData memory orderData)
        internal
        pure
        returns (ERC7683Types.GaslessCrossChainOrder memory g)
    {
        g = ERC7683Types.GaslessCrossChainOrder({
            originSettler: orderData.settler,
            user: orderData.user,
            nonce: orderData.orderSalt,
            originChainId: orderData.originChainId,
            openDeadline: uint32(orderData.openDeadline),
            fillDeadline: uint32(orderData.fillDeadline),
            orderDataType: CORK_ORDER_DATA_TYPE,
            orderData: abi.encode(orderData)
        });
    }

    function _onchain(RolloverTypes.OrderData memory orderData)
        internal
        pure
        returns (ERC7683Types.OnchainCrossChainOrder memory order)
    {
        order = ERC7683Types.OnchainCrossChainOrder({
            fillDeadline: uint32(orderData.fillDeadline),
            orderDataType: CORK_ORDER_DATA_TYPE,
            orderData: abi.encode(orderData)
        });
    }

    function _domainSeparator(address settler_) internal view returns (bytes32) {
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

    function _domainSeparator() internal view returns (bytes32) {
        return _domainSeparator(address(settler));
    }

    function _hashRolloverParamsMemory(RolloverTypes.RolloverParams memory p)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                Typehashes.ROLLOVER_PARAMS_TYPEHASH,
                p.srcCstToken,
                p.dstCstToken,
                p.minCaReceived,
                p.minSharesOut,
                p.srcPoolId,
                p.dstPoolId,
                p.settler,
                p.jitMarketHash
            )
        );
    }

    function _orderDigest(RolloverTypes.OrderData memory orderData)
        internal
        view
        returns (bytes32)
    {
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
        return
            keccak256(abi.encodePacked(hex"1901", _domainSeparator(orderData.settler), structHash));
    }

    function _signOrder(uint256 pk, RolloverTypes.OrderData memory orderData)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = _orderDigest(orderData);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signFillerAuthFor(
        address settler_,
        uint256 pk,
        bytes32 orderDigest,
        address destination,
        bytes32 subFiller
    ) internal view returns (bytes memory) {
        bytes32 digest = LibFillerAuth.hashFillerAuth(
            _domainSeparator(settler_), orderDigest, destination, subFiller
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signCancel(uint256 pk, bytes32 orderId, uint64 orderSalt)
        internal
        view
        returns (bytes memory)
    {
        return _signCancelFor(address(settler), pk, orderId, orderSalt);
    }

    function _signCancelFor(address settler_, uint256 pk, bytes32 orderId, uint64 orderSalt)
        internal
        view
        returns (bytes memory)
    {
        bytes32 inner = LibSettlerHashing.hashCancelOrder(orderId, orderSalt);
        bytes32 cancelDigest =
            keccak256(abi.encodePacked(hex"1901", _domainSeparator(settler_), inner));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, cancelDigest);
        return abi.encodePacked(r, s, v);
    }

    function _openOrder(RolloverTypes.OrderData memory orderData)
        internal
        returns (bytes32 orderDigest)
    {
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory sig = _signOrder(cptHolderPk, orderData);
        bytes memory empty;
        if (orderData.exclusiveFiller != address(0)) {
            vm.prank(orderData.exclusiveFiller);
        }
        ISettler(orderData.settler).openFor(g, sig, empty);
        return _orderDigest(orderData);
    }

    function _openSelf(RolloverTypes.OrderData memory orderData) internal returns (bytes32) {
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory sig = _signOrder(cptHolderPk, orderData);
        vm.prank(cptHolder);
        ISettler(orderData.settler).openFor(g, sig, "");
        return _orderDigest(orderData);
    }

    /// @dev 3-arg `_rolloverFillerData` helper for tests that have already opened an
    ///      order. Every `fill()` call carries an ATOMIC_TAG (255) envelope; the helper
    ///      wraps a rollover leg. The envelope's outer cPT-holder-sig is still supplied because
    ///      the rolloverContract needs it on the first hook phase even when `openFor` already admitted
    ///      the order.
    function _rolloverFillerData(
        uint256 fillAmount,
        RolloverTypes.RolloverIntent memory intent,
        bytes memory cptHolderSig
    ) internal view returns (bytes memory) {
        bytes memory rolloverLeg = _legacyRolloverLeg(fillAmount, intent);
        return abi.encode(uint8(255), rolloverLeg, uint256(1_000_000e18), cptHolderSig);
    }

    function _legacyRolloverLeg(uint256 fillAmount, RolloverTypes.RolloverIntent memory intent)
        internal
        view
        returns (bytes memory)
    {
        return abi.encode(
            uint8(RolloverTypes.HookPhase.ROLLOVER),
            fillAmount,
            uint256(0),
            filler,
            address(0),
            intent,
            uint256(0),
            bytes(""),
            bytes32(0),
            bytes("")
        );
    }

    /// @dev Variant that lets the caller pin a non-zero `subFiller` on the ROLLOVER leg —
    ///      used by partial-mode tests that exercise two sub-filler slots under the same
    ///      (msg.sender) filler.
    function _legacyRolloverLegWithSubFiller(
        uint256 fillAmount,
        RolloverTypes.RolloverIntent memory intent,
        bytes32 subFiller
    ) internal view returns (bytes memory) {
        return abi.encode(
            uint8(RolloverTypes.HookPhase.ROLLOVER),
            fillAmount,
            uint256(0),
            filler,
            address(0),
            intent,
            uint256(0),
            bytes(""),
            subFiller,
            bytes("")
        );
    }

    /// @notice Builds a 10-tuple ROLLOVER fillerData with an explicit cPT-holder sig over the
    ///         supplied `orderData`. Required for direct-fill admission tests that hit the
    ///         `status == None` branch; direct-fill admission verifies the cPT-holder EIP-712 sig
    ///         on that branch (INV-DIRECT-FILL-CPT-HOLDER-SIG). Tests that fill through `openFor` first
    ///         may continue to use the simpler `_rolloverFillerData` overload because the
    ///         Settler skips the check for already-`Opened` orders.
    /// @dev 4-arg `_rolloverFillerData` wraps the rollover leg into an ATOMIC_TAG envelope
    ///      with a cPT-holder EIP-712
    ///      sig over `orderData` (required for direct-fill on `status == None` admission).
    function _rolloverFillerData(
        uint256 fillAmount,
        RolloverTypes.RolloverIntent memory intent,
        RolloverTypes.OrderData memory orderData
    ) internal view returns (bytes memory) {
        bytes memory rolloverLeg = _legacyRolloverLeg(fillAmount, intent);
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);
        return abi.encode(uint8(255), rolloverLeg, uint256(1_000_000e18), cptHolderSig);
    }

    function _hook(address target, bytes memory cd)
        internal
        pure
        returns (RolloverTypes.Call memory)
    {
        return RolloverTypes.Call({
            target: target, value: 0, callData: cd, allowFailure: false, isDelegateCall: true
        });
    }

    function _emptyIntent(address rolloverContractAddr, bytes32 orderDigest)
        internal
        view
        returns (RolloverTypes.RolloverIntent memory intent)
    {
        intent = RolloverTypes.RolloverIntent({
            rolloverContract: rolloverContractAddr,
            orderDigest: orderDigest,
            deadline: uint64(block.timestamp + 2 days),
            nonce: 1,
            preRolloverHooks: new RolloverTypes.Call[](0),
            midRolloverHooks: new RolloverTypes.Call[](0),
            postRolloverHooks: new RolloverTypes.Call[](0),
            premiumHooks: new RolloverTypes.Call[](0)
        });
    }

    function _intentWithHooks(
        address rolloverContractAddr,
        bytes32 orderDigest,
        RolloverTypes.Call[] memory preHooks,
        RolloverTypes.Call[] memory midHooks,
        RolloverTypes.Call[] memory postHooks
    ) internal view returns (RolloverTypes.RolloverIntent memory intent) {
        intent = RolloverTypes.RolloverIntent({
            rolloverContract: rolloverContractAddr,
            orderDigest: orderDigest,
            deadline: uint64(block.timestamp + 2 days),
            nonce: 1,
            preRolloverHooks: preHooks,
            midRolloverHooks: midHooks,
            postRolloverHooks: postHooks,
            premiumHooks: new RolloverTypes.Call[](0)
        });
    }

    function _intentWithFourHooks(
        address rolloverContractAddr,
        bytes32 orderDigest,
        RolloverTypes.Call[] memory preHooks,
        RolloverTypes.Call[] memory midHooks,
        RolloverTypes.Call[] memory postHooks,
        RolloverTypes.Call[] memory premHooks
    ) internal view returns (RolloverTypes.RolloverIntent memory intent) {
        intent = RolloverTypes.RolloverIntent({
            rolloverContract: rolloverContractAddr,
            orderDigest: orderDigest,
            deadline: uint64(block.timestamp + 2 days),
            nonce: 1,
            preRolloverHooks: preHooks,
            midRolloverHooks: midHooks,
            postRolloverHooks: postHooks,
            premiumHooks: premHooks
        });
    }

    function _zeroDigestHash(RolloverTypes.RolloverIntent memory intent)
        internal
        pure
        returns (bytes32)
    {
        bytes32 saved = intent.orderDigest;
        intent.orderDigest = bytes32(0);
        bytes32 h = LibAuthenticatedHooks.intentStructHash(intent);
        intent.orderDigest = saved;
        return h;
    }

    function _subFillerKey(address account) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(account)));
    }

    function _fillContext(
        address filler_,
        uint256 fillAmount,
        bytes32 rolloverIntentHash,
        uint64 fillDeadline,
        bool allowPartialFills,
        uint256 orderSize,
        address originSettler,
        address premiumToken_,
        uint256 premium
    ) internal pure returns (RolloverTypes.FillContext memory) {
        return RolloverTypes.FillContext({
            filler: filler_,
            fillAmount: fillAmount,
            rolloverIntentHash: rolloverIntentHash,
            fillDeadline: fillDeadline,
            allowPartialFills: allowPartialFills,
            allowUnderfill: false,
            orderSize: orderSize,
            originSettler: originSettler,
            premiumToken: premiumToken_,
            premium: premium,
            subFiller: _subFillerKey(filler_)
        });
    }

    function _originData(RolloverTypes.OrderData memory orderData)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(_gasless(orderData));
    }

    /// @notice EIP-712 typehash for Permit2's `PermitBatchWitnessTransferFrom`
    ///         concatenated with the adapter's `EvcRolloverJobWitness` and the
    ///         canonical `TokenPermissions` stub — must exactly match the
    ///         string Permit2 reconstructs internally so the verifier-side and
    ///         signer-side digests agree.
    bytes32 internal constant _PERMIT_BATCH_WITNESS_TYPEHASH_STUB = keccak256(
        bytes(
            "PermitBatchWitnessTransferFrom(TokenPermissions[] permitted,address spender,uint256 nonce,uint256 deadline,EvcRolloverJobWitness witness)EvcRolloverJobWitness(address subaccount,address fundingAccount,address recipient,address srcCst,uint256 fillerSrcCst,address premiumToken,uint256 premium,uint256 minDstPerSrc,bytes32 intentHash,bytes32 orderDigest,uint256 nonce,uint256 deadline)TokenPermissions(address token,uint256 amount)"
        )
    );

    /// @notice EIP-712 typehash for Permit2's inner `TokenPermissions` struct
    ///         used per-token inside the batch witness signature.
    bytes32 internal constant _TOKEN_PERMISSIONS_TYPEHASH =
        keccak256("TokenPermissions(address token,uint256 amount)");

    /// @dev Create an EOA + private key, register it as its own EVC account owner,
    ///      and approve Permit2 for srcCst + premiumToken. Mints starting balances
    ///      to make the account spendable as a subaccount in EVC adapter tests.
    function _makeEvcAccount(string memory label, address evc_)
        internal
        returns (address account, uint256 pk)
    {
        (account, pk) = makeAddrAndKey(label);
        _MockEvcOwnerSetter(evc_).setAccountOwner(account, account);
        vm.prank(account);
        srcCst.approve(address(permit2), type(uint256).max);
        vm.prank(account);
        premiumToken.approve(address(permit2), type(uint256).max);
        srcCst.mint(account, 1_000_000e18);
        premiumToken.mint(account, 1_000_000e18);
    }

    /// @dev Sign the Permit2 PermitBatchWitnessTransferFrom envelope for a job.
    ///      The signed digest matches what `EvcRolloverAdapter._pullJobFundsAndAuthorize`
    ///      reconstructs at runtime: the spender is the adapter address (msg.sender
    ///      from Permit2's perspective).
    function _signPermit2WitnessForJob(
        EvcRolloverAdapter.EvcRolloverJob memory job,
        uint256 ownerPk,
        address adapter,
        address settlerForOrder,
        RolloverTypes.OrderData memory orderData
    ) internal view returns (bytes memory sig) {
        bytes32 witness = _computeJobWitness(job, settlerForOrder, orderData);
        bytes32 digest = _permit2BatchWitnessDigest(job, adapter, witness);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPk, digest);
        sig = abi.encodePacked(r, s, v);
    }

    /// @dev Variant that accepts a raw settler domain separator (for tests
    ///      using mock settlers whose `DOMAIN_SEPARATOR()` does not match the
    ///      canonical `_domainSeparator()` derivation, e.g. returns zero).
    function _signPermit2WitnessForJobWithSep(
        EvcRolloverAdapter.EvcRolloverJob memory job,
        uint256 ownerPk,
        address adapter,
        bytes32 settlerDomainSeparator,
        RolloverTypes.OrderData memory orderData
    ) internal view returns (bytes memory sig) {
        bytes32 witness = _computeJobWitnessWithSep(job, settlerDomainSeparator, orderData);
        bytes32 digest = _permit2BatchWitnessDigest(job, adapter, witness);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPk, digest);
        sig = abi.encodePacked(r, s, v);
    }

    function _computeJobWitnessWithSep(
        EvcRolloverAdapter.EvcRolloverJob memory job,
        bytes32 settlerDomainSeparator,
        RolloverTypes.OrderData memory orderData
    ) internal pure returns (bytes32) {
        bytes32 intentHash = LibAuthenticatedHooks.intentStructHash(job.intent);
        bytes32 orderDigest =
            LibSettlerHashing.computeOrderDigestMemory(orderData, settlerDomainSeparator);
        bytes memory prefix = abi.encode(
            _WITNESS_TYPEHASH,
            job.subaccount,
            job.fundingAccount,
            job.recipient,
            address(job.srcCst),
            job.fillerSrcCst,
            address(job.premiumToken),
            job.premium
        );
        bytes memory suffix =
            abi.encode(job.minDstPerSrc, intentHash, orderDigest, job.nonce, job.deadline);
        return keccak256(bytes.concat(prefix, suffix));
    }

    /// @notice EIP-712 typehash for the adapter's `EvcRolloverJobWitness` —
    ///         test-side mirror of `EvcRolloverAdapter.WITNESS_TYPEHASH` used
    ///         when reconstructing the per-job witness for signature helpers.
    bytes32 internal constant _WITNESS_TYPEHASH = keccak256(
        bytes(
            "EvcRolloverJobWitness(address subaccount,address fundingAccount,address recipient,address srcCst,uint256 fillerSrcCst,address premiumToken,uint256 premium,uint256 minDstPerSrc,bytes32 intentHash,bytes32 orderDigest,uint256 nonce,uint256 deadline)"
        )
    );

    function _computeJobWitness(
        EvcRolloverAdapter.EvcRolloverJob memory job,
        address settlerForOrder,
        RolloverTypes.OrderData memory orderData
    ) internal view returns (bytes32) {
        bytes32 intentHash = LibAuthenticatedHooks.intentStructHash(job.intent);
        bytes32 orderDigest = LibSettlerHashing.computeOrderDigestMemory(
            orderData, _domainSeparator(settlerForOrder)
        );
        bytes memory prefix = abi.encode(
            _WITNESS_TYPEHASH,
            job.subaccount,
            job.fundingAccount,
            job.recipient,
            address(job.srcCst),
            job.fillerSrcCst,
            address(job.premiumToken),
            job.premium
        );
        bytes memory suffix =
            abi.encode(job.minDstPerSrc, intentHash, orderDigest, job.nonce, job.deadline);
        return keccak256(bytes.concat(prefix, suffix));
    }

    function _permit2BatchWitnessDigest(
        EvcRolloverAdapter.EvcRolloverJob memory job,
        address adapter,
        bytes32 witness
    ) internal view returns (bytes32) {
        bytes32 tp0 = keccak256(
            abi.encode(
                _TOKEN_PERMISSIONS_TYPEHASH,
                ISignatureTransfer.TokenPermissions({
                    token: address(job.srcCst), amount: job.fillerSrcCst
                })
            )
        );
        bytes32 tp1 = keccak256(
            abi.encode(
                _TOKEN_PERMISSIONS_TYPEHASH,
                ISignatureTransfer.TokenPermissions({
                    token: address(job.premiumToken), amount: job.premium
                })
            )
        );
        bytes32 permissionsHash = keccak256(abi.encodePacked(tp0, tp1));
        bytes32 structHash = keccak256(
            abi.encode(
                _PERMIT_BATCH_WITNESS_TYPEHASH_STUB,
                permissionsHash,
                adapter,
                job.nonce,
                job.deadline,
                witness
            )
        );
        return keccak256(
            abi.encodePacked(
                hex"1901", IPermit2DomainSeparator(address(permit2)).DOMAIN_SEPARATOR(), structHash
            )
        );
    }
}

/// @notice Minimal interface shim — keeps BaseTest from importing the MockEVC
///         directly while still letting `_makeEvcAccount` register an owner.
interface _MockEvcOwnerSetter {
    /// @notice Register the EVC owner for `account` on the MockEVC.
    /// @param account EVC account / subaccount to register.
    /// @param owner Address to record as the account's owner.
    function setAccountOwner(address account, address owner) external;
}
