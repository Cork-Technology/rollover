// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { CommonBase } from "forge-std/Base.sol";
import { StdCheats } from "forge-std/StdCheats.sol";
import { StdUtils } from "forge-std/StdUtils.sol";

import { MockERC20 } from "../../mocks/MockERC20.sol";
import { MockCpt } from "../../mocks/MockPhoenix.sol";
import { ConsumeAllDstCptModule, SourceSrcCptModule } from "../../mocks/modules/HookModules.sol";
import { ExactSettler } from "src/ExactSettler.sol";
import { PartialSettler } from "src/PartialSettler.sol";
import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import { MarketId } from "src/interfaces/external/phoenix/IPoolManager.sol";
import { LibAuthenticatedHooks } from "src/libraries/LibAuthenticatedHooks.sol";
import { LibRolloverOrder } from "src/libraries/LibRolloverOrder.sol";
import { Typehashes } from "src/libraries/Typehashes.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice N-INV-FILLER-DESTINATION-NONZERO handler — actively drives exact
///         and partial rollover writes, then observes the recorded
///         `fillerDestination` slot across subsequent fills and time warps.
/// @custom:invariant N-INV-FILLER-DESTINATION-NONZERO
contract FillerDestinationHandler is CommonBase, StdCheats, StdUtils {
    /// @notice Fill amount used by every handler-authored leg.
    uint256 internal constant FILL = 100e18;
    /// @notice Alternate destination used to probe partial repeat-fill attempts.
    address internal constant ALT_DESTINATION = address(0xD357);

    /// @notice Exact settler reference.
    /// @return exactRef Stored exact settler ref.
    ExactSettler public immutable exactRef;
    /// @notice Partial settler reference.
    /// @return partialRef Stored partial settler ref.
    PartialSettler public immutable partialRef;
    /// @notice RolloverContract address.
    /// @return rolloverContractRef Stored rolloverContract address.
    address public immutable rolloverContractRef;
    /// @notice srcCST token.
    /// @return srcCst Stored srcCST token.
    MockERC20 public immutable srcCst;
    /// @notice dstCST token.
    /// @return dstCst Stored dstCST token.
    MockERC20 public immutable dstCst;
    /// @notice Premium token.
    /// @return premiumToken Stored premium token.
    MockERC20 public immutable premiumToken;
    /// @notice srcCPT token.
    /// @return srcCpt Stored srcCPT token.
    MockCpt public immutable srcCpt;
    /// @notice dstCPT token.
    /// @return dstCpt Stored dstCPT token.
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
    /// @notice Filler address.
    /// @return filler Stored filler.
    address public immutable filler;

    /// @notice cPT holder private key.
    uint256 internal immutable cptHolderPk;
    /// @notice Unique salt counter for handler-authored orders.
    uint64 internal nonceCounter = 7000;

    /// @notice Registered observation keys.
    /// @return observedKeys Stored observation keys array.
    bytes32[] public observedKeys;
    /// @notice Whether a tuple key has been registered.
    /// @return observed True if registered.
    mapping(bytes32 => bool) public observed;
    /// @notice Mode flag — true=partial, false=exact.
    /// @return keyIsPartial Mode for the registered tuple.
    mapping(bytes32 => bool) public keyIsPartial;
    /// @notice orderDigest for each registered tuple.
    /// @return keyToOrderId Stored orderDigest.
    mapping(bytes32 => bytes32) public keyToOrderId;
    /// @notice filler for each registered tuple.
    /// @return keyToFiller Stored filler address.
    mapping(bytes32 => address) public keyToFiller;
    /// @notice subFiller for each registered tuple.
    /// @return keyToSubFiller Stored subFiller key.
    mapping(bytes32 => bytes32) public keyToSubFiller;
    /// @notice First observed non-zero destination per key.
    /// @return firstSeenDestination Stored first non-zero destination.
    mapping(bytes32 => address) public firstSeenDestination;

    /// @notice Violation flag for zero, cleared, or rewritten destinations.
    /// @return setOnceViolated True if any invariant arm was falsified.
    bool public setOnceViolated;
    /// @notice Unexpected valid-fill revert flag.
    /// @return unexpectedRevert True if a handler-authored valid fill reverted.
    bool public unexpectedRevert;
    /// @notice Number of successful fill attempts.
    /// @return ghostSuccessfulFills Stored counter.
    uint64 public ghostSuccessfulFills;
    /// @notice Number of expected overwrite/second-fill reverts.
    /// @return ghostExpectedReverts Stored counter.
    uint64 public ghostExpectedReverts;
    /// @notice Number of observe calls.
    /// @return ghostObservations Stored counter.
    uint64 public ghostObservations;

    /// @notice Constructor wiring bundle.
    struct Wiring {
        ExactSettler exactSettler;
        PartialSettler partialSettler;
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
        partialRef = wiring.partialSettler;
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
        filler = address(this);
        srcCst.mint(address(this), 1_000_000e18);
        premiumToken.mint(address(this), 1_000_000e18);
        srcCst.approve(address(exactRef), type(uint256).max);
        srcCst.approve(address(partialRef), type(uint256).max);
        premiumToken.approve(address(exactRef), type(uint256).max);
        premiumToken.approve(address(partialRef), type(uint256).max);
    }

    /// @notice handler action: perform one successful exact rollover.
    function fillExact() external {
        (bytes32 orderDigest,) = _fill(false, filler);
        address current = exactRef.rolloverAccountingOf(orderDigest).settlementDestination;
        _captureObservation(_register(false, orderDigest, filler, bytes32(0)), current);
        ghostSuccessfulFills++;
    }

    /// @notice handler action: exact second fill must revert and keep destination stable.
    function attemptExactSecondFill() external {
        (bytes32 orderDigest, RolloverTypes.OrderData memory orderData) = _fill(false, filler);
        bytes32 key = _register(false, orderDigest, filler, bytes32(0));
        address first = exactRef.rolloverAccountingOf(orderDigest).settlementDestination;
        _captureObservation(key, first);
        bool ok = _attemptRollover(orderDigest, orderData, FILL, filler);
        address afterAttempt = exactRef.rolloverAccountingOf(orderDigest).settlementDestination;
        if (ok || afterAttempt != first) {
            setOnceViolated = true;
        }
    }

    /// @notice handler action: perform one successful partial rollover.
    function fillPartial() external {
        (bytes32 orderDigest,) = _fill(true, filler);
        bytes32 subFiller = bytes32(uint256(uint160(filler)));
        address current =
            partialRef.fillerSlotAccountingOf(orderDigest, filler, subFiller).settlementDestination;
        _captureObservation(_register(true, orderDigest, filler, subFiller), current);
        ghostSuccessfulFills++;
    }

    /// @notice handler action: same partial slot cannot fill twice, even with the same destination.
    function attemptPartialSecondFillSameDestination() external {
        (bytes32 orderDigest, RolloverTypes.OrderData memory orderData) = _fill(true, filler);
        bytes32 subFiller = bytes32(uint256(uint160(filler)));
        bytes32 key = _register(true, orderDigest, filler, subFiller);
        address first =
            partialRef.fillerSlotAccountingOf(orderDigest, filler, subFiller).settlementDestination;
        _captureObservation(key, first);
        bool ok = _attemptRollover(orderDigest, orderData, FILL, filler);
        address current =
            partialRef.fillerSlotAccountingOf(orderDigest, filler, subFiller).settlementDestination;
        if (ok || current != first) {
            setOnceViolated = true;
        }
    }

    /// @notice handler action: same partial slot cannot rewrite destination.
    function attemptPartialDestinationOverwrite() external {
        (bytes32 orderDigest, RolloverTypes.OrderData memory orderData) = _fill(true, filler);
        bytes32 subFiller = bytes32(uint256(uint160(filler)));
        bytes32 key = _register(true, orderDigest, filler, subFiller);
        address first =
            partialRef.fillerSlotAccountingOf(orderDigest, filler, subFiller).settlementDestination;
        _captureObservation(key, first);
        bool ok = _attemptRollover(orderDigest, orderData, FILL, ALT_DESTINATION);
        address current =
            partialRef.fillerSlotAccountingOf(orderDigest, filler, subFiller).settlementDestination;
        if (ok || current != first) {
            setOnceViolated = true;
        }
    }

    /// @notice handler action: observe a previously written tuple.
    /// @param indexSeed Fuzz seed used to pick a registered tuple.
    function observeTuple(uint256 indexSeed) external {
        uint256 n = observedKeys.length;
        if (n == 0) {
            return;
        }
        bytes32 key = observedKeys[bound(indexSeed, 0, n - 1)];
        _captureObservation(key, _readDestination(key));
        ghostObservations++;
    }

    /// @notice handler action: warp time forward.
    /// @param delta Fuzz seed for warp delta.
    function warpForward(uint64 delta) external {
        vm.warp(block.timestamp + bound(delta, 0, 1 hours));
    }

    function _fill(bool isPartial, address destination)
        internal
        returns (bytes32 orderDigest, RolloverTypes.OrderData memory orderData)
    {
        orderData = _buildOrder(isPartial, _nextNonce(), isPartial ? 3 * FILL : FILL);
        (orderDigest, orderData) = _prepare(orderData);
        _mustRollover(orderDigest, orderData, FILL, destination);
    }

    function _attemptRollover(
        bytes32 orderDigest,
        RolloverTypes.OrderData memory orderData,
        uint256 fillAmount,
        address destination
    ) internal returns (bool ok) {
        address target = orderData.settler;
        try ExactSettler(target)
            .fill(
                orderDigest,
                abi.encode(_gasless(orderData)),
                _rolloverFillerData(orderDigest, orderData, fillAmount, destination)
            ) {
            ok = true;
        } catch {
            ghostExpectedReverts++;
        }
    }

    function _mustRollover(
        bytes32 orderDigest,
        RolloverTypes.OrderData memory orderData,
        uint256 fillAmount,
        address destination
    ) internal {
        ExactSettler(orderData.settler)
            .fill(
                orderDigest,
                abi.encode(_gasless(orderData)),
                _rolloverFillerData(orderDigest, orderData, fillAmount, destination)
            );
    }

    function _rolloverFillerData(
        bytes32 orderDigest,
        RolloverTypes.OrderData memory orderData,
        uint256 fillAmount,
        address destination
    ) internal view returns (bytes memory) {
        RolloverTypes.RolloverIntent memory intent = _buildIntent(orderDigest, orderData.orderSalt);
        return abi.encode(
            uint8(RolloverTypes.HookPhase.ROLLOVER),
            fillAmount,
            uint256(0),
            destination,
            address(0),
            intent,
            uint256(0),
            new bytes(0),
            bytes32(0),
            _signOrder(orderData)
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

    function _buildOrder(bool isPartial, uint64 nonce, uint256 orderSize)
        internal
        view
        returns (RolloverTypes.OrderData memory orderData)
    {
        address settlerAddr = isPartial ? address(partialRef) : address(exactRef);
        orderData = RolloverTypes.OrderData({
            user: cptHolder,
            settler: settlerAddr,
            fillerHint: filler,
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
            orderSize: orderSize,
            minPremiumPerShare: 1e16,
            allowPartialFills: isPartial,
            allowUnderfill: isPartial,
            premiumPaymentMode: RolloverTypes.PREMIUM_PAYMENT_MODE_ATOMIC_OR_SEPARATE,
            rolloverIntentHash: bytes32(0),
            rolloverParams: RolloverTypes.RolloverParams({
                srcCstToken: address(srcCst),
                dstCstToken: address(dstCst),
                minCaReceived: 0,
                minSharesOut: 0,
                srcPoolId: MarketId.unwrap(srcCst.poolId()),
                dstPoolId: MarketId.unwrap(dstCst.poolId()),
                settler: settlerAddr,
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
                orderData.rolloverParams.settler,
                orderData.rolloverParams.jitMarketHash
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
            orderData.premiumPaymentMode,
            orderData.rolloverIntentHash,
            paramsHash
        );
        bytes32 structHash = keccak256(bytes.concat(prefix, suffix));
        bytes32 domainSeparator = orderData.allowPartialFills
            ? partialRef.DOMAIN_SEPARATOR()
            : exactRef.DOMAIN_SEPARATOR();
        return keccak256(abi.encodePacked(hex"1901", domainSeparator, structHash));
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

    function _register(bool isPartial, bytes32 orderDigest, address filler_, bytes32 subFiller)
        internal
        returns (bytes32 key)
    {
        key = keccak256(abi.encode(isPartial, orderDigest, filler_, subFiller));
        if (observed[key]) {
            return key;
        }
        observed[key] = true;
        observedKeys.push(key);
        keyIsPartial[key] = isPartial;
        keyToOrderId[key] = orderDigest;
        keyToFiller[key] = filler_;
        keyToSubFiller[key] = subFiller;
    }

    function _captureObservation(bytes32 key, address current) internal {
        if (current == address(0)) {
            setOnceViolated = true;
            return;
        }
        address first = firstSeenDestination[key];
        if (first == address(0)) {
            firstSeenDestination[key] = current;
        } else if (current != first) {
            setOnceViolated = true;
        }
    }

    function _readDestination(bytes32 key) internal view returns (address) {
        if (keyIsPartial[key]) {
            return partialRef.fillerSlotAccountingOf(
                keyToOrderId[key], keyToFiller[key], keyToSubFiller[key]
            )
            .settlementDestination;
        }
        return exactRef.rolloverAccountingOf(keyToOrderId[key]).settlementDestination;
    }

    function _nextNonce() internal returns (uint64) {
        unchecked {
            nonceCounter++;
        }
        return nonceCounter;
    }
}
