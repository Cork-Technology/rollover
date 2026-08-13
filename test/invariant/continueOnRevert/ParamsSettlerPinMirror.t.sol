// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { FillScaffold } from "../../base/FillScaffold.sol";
import {
    IParamsSettlerPinMirrorHarness,
    ParamsSettlerPinMirrorHandler
} from "../handlers/ParamsSettlerPinMirrorHandler.sol";
import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import { ISettler } from "src/interfaces/settlers/ISettler.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice INV-PARAMS-SETTLER-PIN-MIRROR — continue-on-revert invariant suite:
///         admission rejects non-canonical `orderData.rolloverParams.settler`.
/// @dev Companion at test/invariant/failOnRevert/ParamsSettlerPinMirror.t.sol.
/// @custom:invariant INV-PARAMS-SETTLER-PIN-MIRROR
contract ParamsSettlerPinMirrorContinueOnRevertTest is
    FillScaffold,
    IParamsSettlerPinMirrorHarness
{
    /// @notice Handler under test.
    ParamsSettlerPinMirrorHandler internal handler;

    /// @notice Deploy the handler and seed filler balances.
    function setUp() public override {
        super.setUp();
        handler = new ParamsSettlerPinMirrorHandler(this);
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = handler.attemptExact.selector;
        selectors[1] = handler.attemptPartial.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));

        srcCst.mint(filler, 10_000_000e18);
        premiumToken.mint(filler, 10_000_000e18);
        _approveFiller(type(uint256).max, type(uint256).max);
    }

    /// @inheritdoc IParamsSettlerPinMirrorHarness
    function attemptParamsSettlerPinMirror(
        bool isPartial,
        bool directFill,
        uint8 variant,
        uint64 saltSeed
    ) external returns (bool accepted, bool canonical) {
        RolloverTypes.OrderData memory orderData =
            isPartial ? _usePartialSettler(_baseOrder()) : _baseOrder();
        orderData.orderSalt = uint64(
            uint256(
                keccak256(
                    abi.encode(
                        "params-settler-pin-mirror", isPartial, directFill, variant, saltSeed
                    )
                )
            )
        );
        if (orderData.orderSalt == 0) {
            orderData.orderSalt = 1;
        }
        canonical = variant == 0;
        if (variant == 1) {
            orderData.rolloverParams.settler = address(0);
        } else if (variant == 2) {
            orderData.rolloverParams.settler = address(0xBEEF);
        }

        ERC7683Types.GaslessCrossChainOrder memory order = _gasless(orderData);
        bytes memory sig = _signOrder(cptHolderPk, orderData);
        bytes memory empty;
        try ISettler(orderData.settler).openFor(order, sig, empty) {
            accepted = true;
        } catch {
            if (!directFill) {
                return (false, canonical);
            }
        }

        if (directFill) {
            bytes32 orderDigest = _orderDigest(orderData);
            RolloverTypes.RolloverIntent memory intent =
                _signedIntent(orderDigest, orderData.orderSize, orderData.orderSize);
            try this.driveDirectFill(orderDigest, orderData, intent) {
                accepted = true;
            } catch {
                accepted = false;
            }
        }
    }

    /// @param orderDigest Order digest under test.
    /// @param orderData Encoded order or filler data under test.
    /// @param intent Rollover intent under test.
    /// @notice External wrapper so handler-driven attempts can catch direct-fill reverts.
    function driveDirectFill(
        bytes32 orderDigest,
        RolloverTypes.OrderData memory orderData,
        RolloverTypes.RolloverIntent memory intent
    ) external {
        _doRolloverAs(orderDigest, orderData, intent, orderData.orderSize, filler);
    }

    /// @notice No non-canonical inner Settler tuple was admitted.
    /// @custom:invariant INV-PARAMS-SETTLER-PIN-MIRROR
    function invariant_paramsSettlerPinMirror() public view {
        assertTrue(
            handler.noMismatchedInnerSettlerAccepted(),
            "INV-PARAMS-SETTLER-PIN-MIRROR: mismatched inner settler accepted"
        );
    }
}
