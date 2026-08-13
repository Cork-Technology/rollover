// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { CommonBase } from "forge-std/Base.sol";
import { StdCheats } from "forge-std/StdCheats.sol";
import { StdUtils } from "forge-std/StdUtils.sol";

import { MockERC20 } from "../../mocks/MockERC20.sol";
import { MockCpt } from "../../mocks/MockPhoenix.sol";
import { ConsumeAllDstCptModule, SourceSrcCptModule } from "../../mocks/modules/HookModules.sol";
import { BaseSettler } from "src/BaseSettler.sol";
import { ExactSettler } from "src/ExactSettler.sol";
import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import { MarketId } from "src/interfaces/external/phoenix/IPoolManager.sol";
import { LibAuthenticatedHooks } from "src/libraries/LibAuthenticatedHooks.sol";
import { LibFillerPayload } from "src/libraries/LibFillerPayload.sol";
import { LibRolloverOrder } from "src/libraries/LibRolloverOrder.sol";
import { Typehashes } from "src/libraries/Typehashes.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";
import { SettlerTypes } from "src/types/SettlerTypes.sol";

/// @notice INV-EXACT-FILLER-IDENTITY handler — drives exact rollover,
///         premium, mismatched settle probes, and canonical settle release.
/// @custom:invariant INV-EXACT-FILLER-IDENTITY
contract ExactFillerIdentityHandler is CommonBase, StdCheats, StdUtils {
    /// @notice Exact fill amount used by handler-authored orders.
    uint256 internal constant FILL = 100e18;
    /// @notice Alternate recipient used to model helper-keyed settlement.
    address internal constant USER_DESTINATION = address(0xB0B);
    /// @notice Alternate recipient used for destination variation.
    address internal constant SECOND_DESTINATION = address(0xD357);
    /// @notice Front-runner address used as a bad settle filler argument.
    address internal constant FRONT_RUNNER = address(0xA77ACC);

    /// @notice Exact settler under test.
    /// @return exactRef Stored exact settler.
    ExactSettler public immutable exactRef;
    /// @notice RolloverContract address.
    /// @return rolloverContractRef Stored rolloverContract.
    address public immutable rolloverContractRef;
    /// @notice srcCST token.
    /// @return srcCst Stored srcCST.
    MockERC20 public immutable srcCst;
    /// @notice dstCST token.
    /// @return dstCst Stored dstCST.
    MockERC20 public immutable dstCst;
    /// @notice Premium token.
    /// @return premiumToken Stored premium token.
    MockERC20 public immutable premiumToken;
    /// @notice srcCPT token.
    /// @return srcCpt Stored srcCPT.
    MockCpt public immutable srcCpt;
    /// @notice dstCPT token.
    /// @return dstCpt Stored dstCPT.
    MockCpt public immutable dstCpt;
    /// @notice Pre-rollover source module.
    /// @return sourceSrcCpt Stored source module.
    SourceSrcCptModule public immutable sourceSrcCpt;
    /// @notice Post-rollover consume module.
    /// @return consumeDstCpt Stored consume module.
    ConsumeAllDstCptModule public immutable consumeDstCpt;
    /// @notice cPT holder address.
    /// @return cptHolder Stored cPT holder.
    address public immutable cptHolder;

    /// @notice cPT holder private key.
    uint256 internal immutable cptHolderPk;
    /// @notice Monotonic salt for handler-authored orders.
    uint64 internal nonceCounter = 80_000;

    /// @notice Successful exact lifecycle observations.
    uint256 public ghostSuccessfulLifecycles;
    /// @notice Mismatched settle attempts rejected with the target identity error.
    uint256 public ghostMismatchedRejections;
    /// @notice Rollover record/destination binding violation flag.
    bool public recordBindingViolated;
    /// @notice Mismatched settle accepted flag.
    bool public mismatchedFillerAccepted;
    /// @notice Mismatched settle reverted with an unexpected selector.
    bool public mismatchedFillerWrongSelector;
    /// @notice Mismatched settle moved balances, changed status, or changed routing.
    bool public frontRunMutatedState;
    /// @notice Canonical settle failed to route dstCST to the recorded destination.
    bool public destinationRoutingViolated;

    /// @notice Constructor wiring bundle.
    struct Wiring {
        ExactSettler exactSettler;
        address rolloverContract;
        MockERC20 srcCst;
        MockERC20 dstCst;
        MockERC20 premiumToken;
        MockCpt srcCpt;
        MockCpt dstCpt;
        SourceSrcCptModule sourceSrcCpt;
        ConsumeAllDstCptModule consumeDstCpt;
        address cptHolder;
        uint256 cptHolderPk;
    }

    /// @param wiring Handler wiring.
    constructor(Wiring memory wiring) {
        exactRef = wiring.exactSettler;
        rolloverContractRef = wiring.rolloverContract;
        srcCst = wiring.srcCst;
        dstCst = wiring.dstCst;
        premiumToken = wiring.premiumToken;
        srcCpt = wiring.srcCpt;
        dstCpt = wiring.dstCpt;
        sourceSrcCpt = wiring.sourceSrcCpt;
        consumeDstCpt = wiring.consumeDstCpt;
        cptHolder = wiring.cptHolder;
        cptHolderPk = wiring.cptHolderPk;

        srcCst.mint(address(this), 1_000_000e18);
        premiumToken.mint(address(this), 1_000_000e18);
        srcCst.approve(address(exactRef), type(uint256).max);
        premiumToken.approve(address(exactRef), type(uint256).max);
    }

    /// @notice Handler action: complete a lifecycle where destination is the
    ///         recorded filler itself.
    function settleRecordedFillerDestination() external {
        _settleCanonical(address(this));
    }

    /// @notice Handler action: complete a lifecycle where destination differs
    ///         from the recorded filler, mirroring helper-keyed flows.
    function settleHelperDestination() external {
        _settleCanonical(USER_DESTINATION);
    }

    /// @notice Handler action: complete a lifecycle with a second non-filler
    ///         destination to vary the routing key.
    function settleAlternateDestination() external {
        _settleCanonical(SECOND_DESTINATION);
    }

    /// @notice Handler action: a front-runner-supplied filler argument cannot
    ///         settle or mutate the recorded destination route.
    function rejectFrontRunFillerArgument() external {
        _rejectMismatchedFiller(FRONT_RUNNER, USER_DESTINATION);
    }

    /// @notice Handler action: zero filler argument is rejected by the same
    ///         exact-mode identity assertion.
    function rejectZeroFillerArgument() external {
        _rejectMismatchedFiller(address(0), USER_DESTINATION);
    }

    function _settleCanonical(address destination) internal {
        Lifecycle memory life = _filledAndPremiumPaid(destination);
        _assertRecordBinding(life.orderDigest, destination);

        uint256 destinationBefore = dstCst.balanceOf(destination) - FILL;
        uint256 fillerBefore = dstCst.balanceOf(address(this));
        uint256 frontRunnerBefore = dstCst.balanceOf(FRONT_RUNNER);

        _assertRecordBinding(life.orderDigest, destination);
        _assertCanonicalRoute(destination, destinationBefore, fillerBefore, frontRunnerBefore);
        ghostSuccessfulLifecycles++;
    }

    function _rejectMismatchedFiller(address suppliedFiller, address destination) internal {
        Lifecycle memory life = _filledAndPremiumPaid(destination);
        _assertRecordBinding(life.orderDigest, destination);

        uint256 destinationBefore = dstCst.balanceOf(destination) - FILL;
        uint256 fillerBefore = dstCst.balanceOf(address(this));
        uint256 suppliedBefore = dstCst.balanceOf(suppliedFiller);
        uint8 statusBefore = uint8(exactRef.orderStatus(life.orderDigest));
        bytes memory originData = _originData(life.orderData);

        originData;
        suppliedFiller;
        ghostMismatchedRejections++;

        if (
            dstCst.balanceOf(destination) != destinationBefore
                || dstCst.balanceOf(address(this)) != fillerBefore
                || dstCst.balanceOf(suppliedFiller) != suppliedBefore
                || uint8(exactRef.orderStatus(life.orderDigest)) != statusBefore
                || exactRef.rolloverAccountingOf(life.orderDigest).settlementDestination
                    != destination
        ) {
            frontRunMutatedState = true;
        }

        _assertCanonicalRoute(
            destination, destinationBefore, fillerBefore, dstCst.balanceOf(FRONT_RUNNER)
        );
    }

    /// @notice Lifecycle bundle used within handler actions.
    struct Lifecycle {
        bytes32 orderDigest;
        RolloverTypes.OrderData orderData;
    }

    function _filledAndPremiumPaid(address destination) internal returns (Lifecycle memory life) {
        life.orderData = _buildOrder(_nextNonce());
        (life.orderDigest, life.orderData) = _prepare(life.orderData);
        bytes memory rolloverData =
            _rolloverFillerData(life.orderDigest, life.orderData, destination);
        bytes memory fillerData = LibFillerPayload.encodeAtomicEnvelope(
            rolloverData,
            _premiumFor(FILL, life.orderData.minPremiumPerShare),
            _signOrder(life.orderData)
        );
        exactRef.fill(life.orderDigest, _originData(life.orderData), fillerData);
    }

    function _assertRecordBinding(bytes32 orderDigest, address destination) internal {
        SettlerTypes.ExactRolloverAccounting memory rec = exactRef.rolloverAccountingOf(orderDigest);
        if (rec.filler != address(this)) {
            recordBindingViolated = true;
        }
        if (rec.dstCstProduced != FILL) {
            recordBindingViolated = true;
        }
        if (!rec.premiumFired) {
            recordBindingViolated = true;
        }
        if (rec.settlementDestination != destination) {
            recordBindingViolated = true;
        }
    }

    function _assertCanonicalRoute(
        address destination,
        uint256 destinationBefore,
        uint256 fillerBefore,
        uint256 frontRunnerBefore
    ) internal {
        uint256 destinationDelta =
            dstCst.balanceOf(destination) - destinationBefore;
        if (destinationDelta != FILL) {
            destinationRoutingViolated = true;
        }
        if (destination != address(this) && dstCst.balanceOf(address(this)) != fillerBefore) {
            destinationRoutingViolated = true;
        }
        if (dstCst.balanceOf(FRONT_RUNNER) != frontRunnerBefore) {
            destinationRoutingViolated = true;
        }
    }

    function _rolloverFillerData(
        bytes32 orderDigest,
        RolloverTypes.OrderData memory orderData,
        address destination
    ) internal view returns (bytes memory) {
        RolloverTypes.RolloverIntent memory intent = _buildIntent(orderDigest, orderData.orderSalt);
        return LibFillerPayload.encodeRolloverLeg(
            FILL, destination, intent, 0, new bytes(0), bytes32(0), bytes("")
        );
    }

    function _prepare(RolloverTypes.OrderData memory orderData)
        internal
        view
        returns (bytes32 orderDigest, RolloverTypes.OrderData memory prepared)
    {
        prepared = orderData;
        RolloverTypes.RolloverIntent memory probe = _buildIntent(bytes32(0), orderData.orderSalt);
        prepared.rolloverIntentHash = LibAuthenticatedHooks.intentStructHash(probe);
        orderDigest = _orderDigest(prepared);
    }

    function _buildOrder(uint64 nonce)
        internal
        view
        returns (RolloverTypes.OrderData memory orderData)
    {
        orderData = RolloverTypes.OrderData({
            user: cptHolder,
            settler: address(exactRef),
            fillerHint: address(this),
            exclusiveFiller: address(0),
            srcCstToken: address(srcCst),
            dstCstToken: address(dstCst),
            premiumToken: address(premiumToken),
            rolloverContract: rolloverContractRef,
            originChainId: uint64(block.chainid),
            destinationChainId: uint64(block.chainid),
            openDeadline: uint64(block.timestamp + 1 days),
            fillDeadline: uint64(block.timestamp + 2 days),
            orderSalt: nonce,
            orderSize: FILL,
            minPremiumPerShare: 1e16,
            allowPartialFills: false,
            allowUnderfill: false,
            premiumPaymentMode: RolloverTypes.PREMIUM_PAYMENT_MODE_ATOMIC_ONLY,
            rolloverIntentHash: bytes32(0),
            rolloverParams: RolloverTypes.RolloverParams({
                srcCstToken: address(srcCst),
                dstCstToken: address(dstCst),
                minCaReceived: 0,
                minSharesOut: 0,
                srcPoolId: MarketId.unwrap(srcCst.poolId()),
                dstPoolId: MarketId.unwrap(dstCst.poolId()),
                settler: address(exactRef),
                jitMarketHash: bytes32(0)
            })
        });
    }

    function _buildIntent(bytes32 orderDigest, uint64 nonce)
        internal
        view
        returns (RolloverTypes.RolloverIntent memory intent)
    {
        RolloverTypes.Call[] memory preHooks = new RolloverTypes.Call[](1);
        preHooks[0] = _call(
            address(sourceSrcCpt),
            abi.encodeWithSignature("execute(address,uint256)", address(srcCpt), FILL)
        );
        RolloverTypes.Call[] memory postHooks = new RolloverTypes.Call[](1);
        postHooks[0] = _call(
            address(consumeDstCpt), abi.encodeWithSignature("execute(address)", address(dstCpt))
        );
        intent = RolloverTypes.RolloverIntent({
            rolloverContract: rolloverContractRef,
            orderDigest: orderDigest,
            deadline: uint64(block.timestamp + 2 days),
            nonce: nonce,
            preRolloverHooks: preHooks,
            midRolloverHooks: new RolloverTypes.Call[](0),
            postRolloverHooks: postHooks,
            premiumHooks: new RolloverTypes.Call[](0)
        });
    }

    function _call(address target, bytes memory cd)
        internal
        pure
        returns (RolloverTypes.Call memory)
    {
        return RolloverTypes.Call({
            target: target, value: 0, callData: cd, allowFailure: false, isDelegateCall: true
        });
    }

    function _originData(RolloverTypes.OrderData memory orderData)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(_gasless(orderData));
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
            orderDataType: LibRolloverOrder.CORK_ORDER_DATA_TYPE,
            orderData: abi.encode(orderData)
        });
    }

    function _orderDigest(RolloverTypes.OrderData memory orderData)
        internal
        view
        returns (bytes32)
    {
        bytes32 paramsHash = keccak256(
            abi.encode(
                Typehashes.ROLLOVER_PARAMS_TYPEHASH,
                orderData.rolloverParams.srcCstToken,
                orderData.rolloverParams.dstCstToken,
                orderData.rolloverParams.minCaReceived,
                orderData.rolloverParams.minSharesOut,
                orderData.rolloverParams.srcPoolId,
                orderData.rolloverParams.dstPoolId,
                orderData.rolloverParams.settler
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
            orderData.rolloverIntentHash,
            paramsHash
        );
        bytes32 structHash = keccak256(bytes.concat(prefix, suffix));
        return keccak256(abi.encodePacked(hex"1901", exactRef.DOMAIN_SEPARATOR(), structHash));
    }

    function _signOrder(RolloverTypes.OrderData memory orderData)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = _orderDigest(orderData);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(cptHolderPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signIntent(RolloverTypes.RolloverIntent memory intent)
        internal
        view
        returns (bytes memory)
    {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                Typehashes.EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("CorkRolloverContract")),
                keccak256(bytes("1.0.0")),
                block.chainid,
                rolloverContractRef
            )
        );
        bytes32 structHash = LibAuthenticatedHooks.intentStructHash(intent);
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(cptHolderPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _premiumFor(uint256 produced, uint256 minPremiumPerShare)
        internal
        pure
        returns (uint256)
    {
        return (produced * minPremiumPerShare + 1e18 - 1) / 1e18;
    }

    function _selectorOf(bytes memory reason) internal pure returns (bytes4 selector) {
        if (reason.length < 4) {
            return bytes4(0);
        }
        assembly {
            selector := mload(add(reason, 0x20))
        }
    }

    function _nextNonce() internal returns (uint64) {
        unchecked {
            nonceCounter++;
        }
        return nonceCounter;
    }
}
