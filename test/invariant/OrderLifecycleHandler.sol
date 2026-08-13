// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { CommonBase } from "forge-std/Base.sol";
import { StdCheats } from "forge-std/StdCheats.sol";
import { StdUtils } from "forge-std/StdUtils.sol";

import { MockERC20 } from "../mocks/MockERC20.sol";
import { CorkRolloverContract } from "src/CorkRolloverContract.sol";
import { ExactSettler as Settler } from "src/ExactSettler.sol";
import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import { LibRolloverOrder } from "src/libraries/LibRolloverOrder.sol";
import { Typehashes } from "src/libraries/Typehashes.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice Open/cancel/expire driver — exercises the Settler FSM under fuzzed inputs.
contract OrderLifecycleHandler is CommonBase, StdCheats, StdUtils {
    /// @notice Settler.
    /// @return SETTLER Stored settler value.
    Settler public immutable SETTLER;
    /// @notice RolloverContract.
    /// @return ROLLOVER_CONTRACT Stored rolloverContract value.

    CorkRolloverContract public immutable ROLLOVER_CONTRACT;
    /// @notice Factory addr.
    /// @return FACTORY_ADDR Stored factory addr value.

    address public immutable FACTORY_ADDR;
    /// @notice Src cst.
    /// @return SRC_CST Stored src cst value.

    MockERC20 public immutable SRC_CST;
    /// @notice Dst cst.
    /// @return DST_CST Stored dst cst value.

    MockERC20 public immutable DST_CST;
    /// @notice Premium token.
    /// @return PREMIUM_TOKEN Stored premium token value.

    MockERC20 public immutable PREMIUM_TOKEN;
    /// @notice cPT holder.
    /// @return cPT holder value.

    address public immutable cptHolder;

    /// @notice cPT holder private key.
    uint256 internal immutable CPT_HOLDER_PK;
    /// @notice Opened digests.
    /// @return openedDigests Stored opened digests value.

    bytes32[] public openedDigests;
    /// @notice Exists.
    /// @return exists Stored exists value.

    mapping(bytes32 => bool) public exists;
    /// @notice Max observed status.
    /// @return maxObservedStatus Stored max observed status value.

    mapping(bytes32 => uint8) public maxObservedStatus;

    /// @notice Stored order.
    mapping(bytes32 => RolloverTypes.OrderData) internal storedOrder;
    /// @notice Ghost opens.
    /// @return ghostOpens Stored ghost opens value.

    uint256 public ghostOpens;
    /// @notice Ghost cancels.
    /// @return ghostCancels Stored ghost cancels value.

    uint256 public ghostCancels;
    /// @notice Ghost expiries.
    /// @return ghostExpiries Stored ghost expiries value.

    uint256 public ghostExpiries;

    /// @notice Nonce counter.
    uint64 internal nonceCounter = 1;

    /// @param s s.
    /// @param c c.
    /// @param f f.
    /// @param src src.
    /// @param dst dst.
    /// @param prem prem.
    /// @param user user.
    /// @param userPk userPk.
    constructor(
        Settler s,
        CorkRolloverContract c,
        // forge-lint: disable-next-line(missing-zero-check)
        address f,
        MockERC20 src,
        MockERC20 dst,
        MockERC20 prem,
        // forge-lint: disable-next-line(missing-zero-check)
        address user,
        uint256 userPk
    ) {
        SETTLER = s;
        ROLLOVER_CONTRACT = c;
        FACTORY_ADDR = f;
        SRC_CST = src;
        DST_CST = dst;
        PREMIUM_TOKEN = prem;
        cptHolder = user;
        CPT_HOLDER_PK = userPk;
    }

    /// @notice _base order.
    function _baseOrder(uint64 nonce)
        internal
        view
        returns (RolloverTypes.OrderData memory orderData)
    {
        orderData.user = cptHolder;
        orderData.settler = address(SETTLER);
        orderData.fillerHint = address(0);
        orderData.exclusiveFiller = address(0);
        orderData.srcCstToken = address(SRC_CST);
        orderData.dstCstToken = address(DST_CST);
        orderData.premiumToken = address(PREMIUM_TOKEN);
        orderData.rolloverContract = address(ROLLOVER_CONTRACT);
        orderData.originChainId = uint64(block.chainid);
        orderData.destinationChainId = uint64(block.chainid);
        orderData.openDeadline = uint64(block.timestamp + 1 days);
        orderData.fillDeadline = uint64(block.timestamp + 2 days);
        orderData.orderSalt = nonce;
        orderData.orderSize = 1_000e18;
        orderData.minPremiumPerShare = 1e18;
        orderData.allowPartialFills = false;
        orderData.allowUnderfill = false;
        orderData.rolloverIntentHash = keccak256("OrderLifecycleHandler.rolloverContractIntent");
        orderData.rolloverParams.srcCstToken = address(SRC_CST);
        orderData.rolloverParams.dstCstToken = address(DST_CST);
        orderData.rolloverParams.minCaReceived = 0;
        orderData.rolloverParams.minSharesOut = 0;
    }

    /// @notice _gasless.
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
    /// @notice Legit open.
    /// @param step Step index within a multi-step sequence.

    function legitOpen(uint16 step) external {
        unchecked {
            nonceCounter += 1 + uint64(step % 17);
        }
        RolloverTypes.OrderData memory orderData = _baseOrder(nonceCounter);
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes32 d = _digestOf(orderData);
        if (exists[d]) {
            return;
        }
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(CPT_HOLDER_PK, d);
        bytes memory sig = abi.encodePacked(r, s, v);
        vm.prank(cptHolder);
        try SETTLER.openFor(g, sig, "") {
            openedDigests.push(d);
            exists[d] = true;
            storedOrder[d] = orderData;
            ghostOpens++;

            if (uint8(RolloverTypes.OrderStatus.Opened) > maxObservedStatus[d]) {
                maxObservedStatus[d] = uint8(RolloverTypes.OrderStatus.Opened);
            }
        } catch { }
    }

    /// @notice _digest of.
    function _digestOf(RolloverTypes.OrderData memory orderData) internal view returns (bytes32) {
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
    /// @notice Legit cancel.
    /// @param seed Fuzz seed.

    function legitCancel(uint256 seed) external {
        if (openedDigests.length == 0) {
            return;
        }
        bytes32 d = openedDigests[seed % openedDigests.length];

        uint8 s = uint8(SETTLER.orderStatus(d));
        if (s != uint8(RolloverTypes.OrderStatus.Opened)) {
            return;
        }

        ghostCancels++;
    }
    /// @notice Legit markExpired.
    /// @param seed Fuzz seed.

    function legitMarkExpired(uint256 seed) external {
        if (openedDigests.length == 0) {
            return;
        }
        bytes32 d = openedDigests[seed % openedDigests.length];
        uint8 s = uint8(SETTLER.orderStatus(d));
        if (s != uint8(RolloverTypes.OrderStatus.Opened)) {
            return;
        }
        RolloverTypes.OrderData memory orderData = storedOrder[d];

        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp <= orderData.fillDeadline) {
            return;
        }
        try SETTLER.markExpired(d, abi.encode(_gasless(orderData))) {
            ghostExpiries++;
            if (uint8(RolloverTypes.OrderStatus.Expired) > maxObservedStatus[d]) {
                maxObservedStatus[d] = uint8(RolloverTypes.OrderStatus.Expired);
            }
        } catch { }
    }
    /// @notice Digests count.
    /// @return Return value.

    function digestsCount() external view returns (uint256) {
        return openedDigests.length;
    }
}
