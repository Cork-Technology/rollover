// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { FillScaffold } from "../base/FillScaffold.sol";
import { IOpenDeadlineDriver, OpenDeadlineHandler } from "./handlers/OpenDeadlineHandler.sol";
import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice Shared active driver for the open-deadline admission invariant suites.
abstract contract OpenDeadlineInvariantBase is FillScaffold, IOpenDeadlineDriver {
    /// @notice Fill amount used by handler-authored admission probes.
    uint256 internal constant OPEN_DEADLINE_FILL = 500e18;
    /// @notice Salt base reserved for handler-authored orders.
    uint64 internal constant OPEN_DEADLINE_SALT_BASE = 50_000;

    /// @notice Active handler.
    OpenDeadlineHandler internal openDeadlineHandler;
    /// @notice Monotonic salt offset for handler-authored orders.
    uint64 internal nextOpenDeadlineSalt;

    /// @notice Sets up the active deadline handler and targets its actions.
    function _setUpOpenDeadlineInvariant() internal {
        nextOpenDeadlineSalt = OPEN_DEADLINE_SALT_BASE;
        _approveFiller(type(uint256).max, type(uint256).max);

        openDeadlineHandler = new OpenDeadlineHandler(IOpenDeadlineDriver(address(this)));
        targetContract(address(openDeadlineHandler));
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = openDeadlineHandler.probeExactAdmission.selector;
        selectors[1] = openDeadlineHandler.probePartialAdmission.selector;
        targetSelector(FuzzSelector({ addr: address(openDeadlineHandler), selectors: selectors }));
    }

    /// @inheritdoc IOpenDeadlineDriver
    function driveOpenDeadlineAdmission(
        uint256 saltSeed,
        uint64 deadlineSeed,
        uint64 warpSeed,
        uint8 pathSeed,
        bool isPartial
    ) external returns (bool accepted, bool shouldAdmit, uint8 statusBefore, uint8 statusAfter) {
        require(msg.sender == address(openDeadlineHandler), "OpenDeadline: only handler");

        SettlerMode mode = isPartial ? SettlerMode.Partial : SettlerMode.Exact;
        uint64 deadlineOffset = uint64(bound(deadlineSeed, 1, 1 days));
        uint64 warpOffset = uint64(bound(warpSeed, 0, 2 days));
        shouldAdmit = warpOffset <= deadlineOffset;

        RolloverTypes.OrderData memory orderData =
            _openDeadlineOrder(mode, saltSeed, deadlineOffset);
        bytes32 orderDigest = _orderDigest(orderData);
        statusBefore = uint8(_settlerForMode(mode).orderStatus(orderDigest));

        vm.warp(block.timestamp + warpOffset);

        uint8 path = pathSeed % 3;
        if (path == 0) {
            accepted = _tryOpen(mode, orderData);
        } else if (path == 1) {
            accepted = _tryOpenFor(mode, orderData);
        } else {
            accepted = _tryDirectFill(mode, orderDigest, orderData);
        }

        statusAfter = uint8(_settlerForMode(mode).orderStatus(orderDigest));
    }

    function _openDeadlineOrder(SettlerMode mode, uint256, uint64 deadlineOffset)
        internal
        returns (RolloverTypes.OrderData memory orderData)
    {
        orderData = _orderForMode(mode);
        orderData.orderSalt = nextOpenDeadlineSalt++;
        orderData.orderSize = OPEN_DEADLINE_FILL;
        orderData.openDeadline = uint64(block.timestamp + deadlineOffset);
        orderData.fillDeadline = uint64(orderData.openDeadline + 2 days);

        RolloverTypes.RolloverIntent memory draft =
            _buildIntent(bytes32(0), OPEN_DEADLINE_FILL, OPEN_DEADLINE_FILL);
        draft.nonce = orderData.orderSalt;
        draft.deadline = orderData.fillDeadline;
        orderData.rolloverIntentHash = _zeroDigestHash(draft);
    }

    function _tryOpen(SettlerMode mode, RolloverTypes.OrderData memory orderData)
        internal
        returns (bool accepted)
    {
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory sig = _signOrder(cptHolderPk, orderData);
        try this.openDeadlineOpenProbe(mode, g, sig) {
            accepted = true;
        } catch {
            accepted = false;
        }
    }

    function _tryOpenFor(SettlerMode mode, RolloverTypes.OrderData memory orderData)
        internal
        returns (bool accepted)
    {
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory sig = _signOrder(cptHolderPk, orderData);
        bytes memory empty;
        try this.openDeadlineOpenForProbe(mode, g, sig, empty) {
            accepted = true;
        } catch {
            accepted = false;
        }
    }

    function _tryDirectFill(
        SettlerMode mode,
        bytes32 orderDigest,
        RolloverTypes.OrderData memory orderData
    ) internal returns (bool accepted) {
        RolloverTypes.RolloverIntent memory intent =
            _buildIntent(orderDigest, OPEN_DEADLINE_FILL, OPEN_DEADLINE_FILL);
        intent.nonce = orderData.orderSalt;
        intent.deadline = orderData.fillDeadline;
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);
        try this.openDeadlineDirectFillProbe(mode, orderDigest, orderData, intent, cptHolderSig) {
            accepted = true;
        } catch {
            accepted = false;
        }
    }

    /// @notice External probe wrapper so driver can catch `open` reverts.
    /// @param mode Settler mode used for admission.
    /// @param g Gasless order envelope submitted to open.
    /// @param sig cPT-holder signature for the order.
    function openDeadlineOpenProbe(
        SettlerMode mode,
        ERC7683Types.GaslessCrossChainOrder calldata g,
        bytes calldata sig
    ) external {
        require(msg.sender == address(this), "OpenDeadline: only self");
        vm.prank(cptHolder);
        _settlerForMode(mode).openFor(g, sig, "");
    }

    /// @notice External probe wrapper so driver can catch `openFor` reverts.
    /// @param mode Settler mode used for admission.
    /// @param g Gasless order envelope submitted to openFor.
    /// @param sig cPT-holder signature for the order.
    /// @param originFillerData Origin filler data submitted to openFor.
    function openDeadlineOpenForProbe(
        SettlerMode mode,
        ERC7683Types.GaslessCrossChainOrder calldata g,
        bytes calldata sig,
        bytes calldata originFillerData
    ) external {
        require(msg.sender == address(this), "OpenDeadline: only self");
        _settlerForMode(mode).openFor(g, sig, originFillerData);
    }

    /// @notice External probe wrapper so driver can catch direct-fill reverts.
    /// @param mode Settler mode used for direct fill.
    /// @param orderDigest Order digest submitted to fill.
    /// @param orderData Order data encoded into originData.
    /// @param intent Rollover intent encoded into fillerData.
    /// @param cptHolderSig Legacy helper parameter; atomic helpers sign `OrderData` internally.
    function openDeadlineDirectFillProbe(
        SettlerMode mode,
        bytes32 orderDigest,
        RolloverTypes.OrderData calldata orderData,
        RolloverTypes.RolloverIntent calldata intent,
        bytes calldata cptHolderSig
    ) external {
        require(msg.sender == address(this), "OpenDeadline: only self");
        _doRolloverAs(orderDigest, orderData, intent, OPEN_DEADLINE_FILL, filler);
        mode;
    }
}
