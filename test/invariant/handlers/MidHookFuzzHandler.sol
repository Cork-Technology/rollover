// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { CommonBase } from "forge-std/Base.sol";
import { StdCheats } from "forge-std/StdCheats.sol";
import { StdUtils } from "forge-std/StdUtils.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ExactSettler } from "src/ExactSettler.sol";
import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import { MarketId } from "src/interfaces/external/phoenix/IPoolManager.sol";
import { LibAuthenticatedHooks } from "src/libraries/LibAuthenticatedHooks.sol";
import { LibFillerPayload } from "src/libraries/LibFillerPayload.sol";
import { LibRolloverOrder } from "src/libraries/LibRolloverOrder.sol";
import { Typehashes } from "src/libraries/Typehashes.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

import { MockERC20 } from "../../mocks/MockERC20.sol";
import { MockCpt } from "../../mocks/MockPhoenix.sol";
import {
    ConsumeDstCptModule,
    SourceSrcCptModule,
    SwapCaModule
} from "../../mocks/modules/HookModules.sol";

/// @notice Drives rollover legs with fuzzed mid-hook swap ratios; ghosts capture the
/// `dstProduced >= minSharesOut → success` relationship for the INV-DST-FLOOR invariant suite.
/// @custom:invariant INV-DST-FLOOR
contract MidHookFuzzHandler is CommonBase, StdCheats, StdUtils {
    /// @notice Selector of the now-deleted MidPhaseCollateralDrain error; ghost-tracked to assert no leg ever reverts with it under the new INV-DST-FLOOR regime.
    bytes4 internal constant DELETED_MID_DRAIN_SELECTOR = 0x7fbea310;

    /// @notice Floor used by the fuzz handler; chosen above 1 wei so that the floor=0 boundary case is not the only path.
    uint256 internal constant FILL = 1_000e18;

    // ---------- Wiring ----------------------------------------------------

    /// @notice Settler contract.
    /// @return SETTLER Stored settler value.
    ExactSettler public immutable SETTLER;
    /// @notice RolloverContract address.
    /// @return ROLLOVER_CONTRACT_ADDR Stored rolloverContract address value.

    address public immutable ROLLOVER_CONTRACT_ADDR;
    /// @notice srcCST token.
    /// @return SRC_CST Stored srcCST token value.

    MockERC20 public immutable SRC_CST;
    /// @notice dstCST token.
    /// @return DST_CST Stored dstCST token value.

    MockERC20 public immutable DST_CST;
    /// @notice Premium token.
    /// @return PREMIUM_TOKEN Stored premium token value.

    MockERC20 public immutable PREMIUM_TOKEN;
    /// @notice srcCST poolId raw bytes32.
    /// @return SRC_POOL_ID Stored srcCST pool id value.

    bytes32 public immutable SRC_POOL_ID;
    /// @notice dstCST poolId raw bytes32.
    /// @return DST_POOL_ID Stored dstCST pool id value.

    bytes32 public immutable DST_POOL_ID;
    /// @notice caSrc token.
    /// @return CA_SRC Stored caSrc token value.

    MockERC20 public immutable CA_SRC;
    /// @notice caDst token.
    /// @return CA_DST Stored caDst token value.

    MockERC20 public immutable CA_DST;
    /// @notice srcCPT token.
    /// @return SRC_CPT Stored srcCPT token value.

    MockCpt public immutable SRC_CPT;
    /// @notice dstCPT token.
    /// @return DST_CPT Stored dstCPT token value.

    MockCpt public immutable DST_CPT;
    /// @notice Pre-source srcCPT mid module address.
    /// @return SOURCE_SRC Stored source-src module value.

    SourceSrcCptModule public immutable SOURCE_SRC;
    /// @notice Mid-rollover swap module address.
    /// @return SWAP Stored swap module value.

    SwapCaModule public immutable SWAP;
    /// @notice Post-rollover dstCPT consumer module address.
    /// @return CONSUME Stored consume module value.

    ConsumeDstCptModule public immutable CONSUME;
    /// @notice cPT holder address.
    /// @return cPT holder value.

    address public immutable cptHolder;
    /// @notice Filler address.
    /// @return FILLER Stored filler value.

    address public immutable FILLER;
    /// @notice Sink address for caSrc consumed by the swap mock.
    /// @return SINK Stored sink address value.

    address public immutable SINK;
    /// @notice cPT holder private key for intent signing.
    uint256 internal immutable CPT_HOLDER_PK;

    // ---------- Ghosts ----------------------------------------------------

    /// @notice Nonce counter for unique order salts.
    uint64 internal nonceCounter = 1;

    /// @notice Total `attemptRollover` invocations.
    /// @return ghostAttempts Stored ghost attempts value.
    uint256 public ghostAttempts;
    /// @notice Legs that succeeded.
    /// @return ghostSuccesses Stored ghost successes value.

    uint256 public ghostSuccesses;
    /// @notice Legs that reverted.
    /// @return ghostReverts Stored ghost reverts value.

    uint256 public ghostReverts;
    /// @notice True if any attempt reverted with the deleted `MidPhaseCollateralDrain` selector.
    /// @return ghostMidDrainEmitted Stored ghost mid drain emitted value.

    bool public ghostMidDrainEmitted;
    /// @notice True if a leg with `dstProduced >= minSharesOut` ever reverted (must remain false — Property 1).
    /// @return ghostFloorClearedButReverted Stored ghost floor cleared but reverted value.

    bool public ghostFloorClearedButReverted;
    /// @notice True if a leg with `dstProduced < minSharesOut` ever succeeded (must remain false — Property 2).
    /// @return ghostBelowFloorButSucceeded Stored ghost below floor but succeeded value.

    bool public ghostBelowFloorButSucceeded;

    // ---------- Constructor -----------------------------------------------

    /// @notice Construct the fuzz handler with all references needed to author and submit rollover legs.
    /// @param settler_ Settler contract.
    /// @param rolloverContract_ RolloverContract address.
    /// @param srcCst_ srcCST token.
    /// @param dstCst_ dstCST token.
    /// @param premiumToken_ Premium token.
    /// @param caSrc_ caSrc token.
    /// @param caDst_ caDst token.
    /// @param srcCpt_ srcCPT token.
    /// @param dstCpt_ dstCPT token.
    /// @param wiring Modules + cPT holder key bundle (avoids exceeding the 5-positional-param cap).
    constructor(
        ExactSettler settler_,
        // forge-lint: disable-next-line(missing-zero-check)
        address rolloverContract_,
        MockERC20 srcCst_,
        MockERC20 dstCst_,
        MockERC20 premiumToken_,
        MockERC20 caSrc_,
        MockERC20 caDst_,
        MockCpt srcCpt_,
        MockCpt dstCpt_,
        Wiring memory wiring
    ) {
        SETTLER = settler_;
        ROLLOVER_CONTRACT_ADDR = rolloverContract_;
        SRC_CST = srcCst_;
        DST_CST = dstCst_;
        PREMIUM_TOKEN = premiumToken_;
        CA_SRC = caSrc_;
        CA_DST = caDst_;
        SRC_CPT = srcCpt_;
        DST_CPT = dstCpt_;
        SRC_POOL_ID = MarketId.unwrap(srcCst_.poolId());
        DST_POOL_ID = MarketId.unwrap(dstCst_.poolId());
        SOURCE_SRC = wiring.sourceSrc;
        SWAP = wiring.swap;
        CONSUME = wiring.consume;
        cptHolder = wiring.cptHolder;
        FILLER = wiring.filler;
        SINK = wiring.sink;
        CPT_HOLDER_PK = wiring.cptHolderPk;
    }

    /// @notice Constructor wiring bundle.
    struct Wiring {
        SourceSrcCptModule sourceSrc;
        SwapCaModule swap;
        ConsumeDstCptModule consume;
        address cptHolder;
        uint256 cptHolderPk;
        address filler;
        address sink;
    }

    // ---------- Action ----------------------------------------------------

    /// @notice Attempt a rollover leg with fuzzed swap ratio and floor.
    /// @param amountInRaw Raw fuzz input bounded to caSrc consumed in basis points of FILL.
    /// @param amountOutRaw Raw fuzz input bounded to caDst produced in basis points of FILL.
    /// @param floorRaw Raw fuzz input bounded to `minSharesOut` in basis points of FILL.
    function attemptRollover(uint256 amountInRaw, uint256 amountOutRaw, uint256 floorRaw) external {
        ghostAttempts++;

        uint256 amountIn = bound(amountInRaw, 0, FILL);
        uint256 amountOut = bound(amountOutRaw, 0, 2 * FILL);
        uint256 floor = bound(floorRaw, 0, 2 * FILL);

        // Build + sign + open + fill.
        unchecked {
            nonceCounter++;
        }
        RolloverTypes.OrderData memory orderData = _buildOrder(nonceCounter, floor);
        RolloverTypes.RolloverIntent memory intent = _buildIntent(amountIn, amountOut);
        // intent.orderDigest is bytes32(0) at this point (built fresh); pass directly.
        orderData.rolloverIntentHash = LibAuthenticatedHooks.intentStructHash(intent);

        bytes32 orderDigest = _orderDigest(orderData);
        bytes memory orderSig = _signOrder(orderData);

        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        vm.prank(cptHolder);
        try SETTLER.openFor(g, orderSig, "") { }
        catch {
            // Skip if open rejected (replay / deadline / etc).
            return;
        }

        intent.orderDigest = orderDigest;
        bytes memory originData = abi.encode(g);
        bytes memory cptHolderOrderSig = _signOrder(orderData);
        bytes memory rolloverLeg = abi.encode(
            uint8(RolloverTypes.HookPhase.ROLLOVER),
            FILL,
            uint256(0),
            FILLER,
            address(0),
            intent,
            uint256(0),
            new bytes(0),
            bytes32(0),
            cptHolderOrderSig
        );
        bytes memory fillerData =
            abi.encode(uint8(255), rolloverLeg, uint256(1_000_000e18), cptHolderOrderSig);

        vm.prank(FILLER);
        try SETTLER.fill(orderDigest, originData, fillerData) {
            ghostSuccesses++;
            // Property 2: if dstProduced < floor, leg must have reverted.
            // dstProduced equals amountOut produced by the swap (mock deposit 1:1).
            if (amountOut < floor) {
                ghostBelowFloorButSucceeded = true;
            }
        } catch (bytes memory revertData) {
            ghostReverts++;
            // Property 3: no revert ever carries the deleted selector.
            if (revertData.length >= 4) {
                // forge-lint: disable-next-line(unsafe-typecast)
                bytes4 sel = bytes4(revertData);
                if (sel == DELETED_MID_DRAIN_SELECTOR) {
                    ghostMidDrainEmitted = true;
                }
            }
            // Property 1: if dstProduced >= floor AND amountOut != 0, leg should have succeeded.
            // We approximate dstProduced by amountOut (mock deposit returns 1:1).
            if (amountOut >= floor && amountOut != 0) {
                ghostFloorClearedButReverted = true;
            }
        }
    }

    // ---------- Builders --------------------------------------------------

    function _buildOrder(uint64 nonce, uint256 floor)
        internal
        view
        returns (RolloverTypes.OrderData memory orderData)
    {
        orderData.user = cptHolder;
        orderData.settler = address(SETTLER);
        orderData.fillerHint = FILLER;
        orderData.exclusiveFiller = address(0);
        orderData.srcCstToken = address(SRC_CST);
        orderData.dstCstToken = address(DST_CST);
        orderData.premiumToken = address(PREMIUM_TOKEN);
        orderData.rolloverContract = ROLLOVER_CONTRACT_ADDR;
        orderData.originChainId = uint64(block.chainid);
        orderData.destinationChainId = uint64(block.chainid);
        orderData.openDeadline = uint64(block.timestamp + 1 days);
        orderData.fillDeadline = uint64(block.timestamp + 2 days);
        orderData.orderSalt = nonce;
        orderData.orderSize = FILL;
        orderData.minPremiumPerShare = 1e16;
        orderData.allowPartialFills = false;
        orderData.allowUnderfill = false;
        // rolloverIntentHash filled in caller after intent is built.
        orderData.rolloverParams = RolloverTypes.RolloverParams({
            srcCstToken: address(SRC_CST),
            dstCstToken: address(DST_CST),
            minCaReceived: 0,
            minSharesOut: floor,
            srcPoolId: SRC_POOL_ID,
            dstPoolId: DST_POOL_ID,
            settler: address(SETTLER),
            jitMarketHash: bytes32(0)
        });
    }

    function _buildIntent(uint256 amountIn, uint256 amountOut)
        internal
        view
        returns (RolloverTypes.RolloverIntent memory intent)
    {
        RolloverTypes.Call[] memory preHooks = new RolloverTypes.Call[](1);
        preHooks[0] = _call(
            address(SOURCE_SRC),
            abi.encodeWithSignature("execute(address,uint256)", address(SRC_CPT), FILL)
        );

        RolloverTypes.Call[] memory midHooks = new RolloverTypes.Call[](1);
        midHooks[0] = _call(
            address(SWAP),
            abi.encodeWithSignature(
                "execute(address,address,uint256,address,uint256)",
                address(CA_SRC),
                SINK,
                amountIn,
                address(CA_DST),
                amountOut
            )
        );

        RolloverTypes.Call[] memory postHooks = new RolloverTypes.Call[](1);
        postHooks[0] = _call(
            address(CONSUME),
            abi.encodeWithSignature("execute(address,uint256)", address(DST_CPT), amountOut)
        );

        intent = RolloverTypes.RolloverIntent({
            rolloverContract: ROLLOVER_CONTRACT_ADDR,
            orderDigest: bytes32(0),
            deadline: uint64(block.timestamp + 2 days),
            nonce: nonceCounter,
            preRolloverHooks: preHooks,
            midRolloverHooks: midHooks,
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
        view
        returns (ERC7683Types.GaslessCrossChainOrder memory g)
    {
        g.originSettler = address(SETTLER);
        g.user = orderData.user;
        g.nonce = orderData.orderSalt;
        g.originChainId = orderData.originChainId;
        g.openDeadline = uint32(orderData.openDeadline);
        g.fillDeadline = uint32(orderData.fillDeadline);
        g.orderDataType = LibRolloverOrder.CORK_ORDER_DATA_TYPE;
        g.orderData = abi.encode(orderData);
    }

    // ---------- Hashing + Signing ----------------------------------------

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
            orderData.premiumPaymentMode,
            orderData.rolloverIntentHash,
            paramsHash
        );
        bytes32 structHash = keccak256(bytes.concat(prefix, suffix));
        return keccak256(abi.encodePacked(hex"1901", SETTLER.DOMAIN_SEPARATOR(), structHash));
    }

    function _signOrder(RolloverTypes.OrderData memory orderData)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = _orderDigest(orderData);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(CPT_HOLDER_PK, digest);
        return abi.encodePacked(r, s, v);
    }
}
