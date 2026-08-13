// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { FillScaffold } from "../../base/FillScaffold.sol";
import { Settler__UserNotRolloverContractOwner } from "src/errors/SettlerErrors.sol";
import { ISettler } from "src/interfaces/settlers/ISettler.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice The one-signature rollover design verifies the single cPT holder
///         signature against TWO addresses: `orderData.user` at the Settler boundary and
///         the rolloverContract `owner()` inside `CorkRolloverContract.executeIntentHookPhase`. That dual check
///         is only consistent because `BaseSettler._validateOrderCommon` requires
///         `orderData.user == ICorkRolloverContract(orderData.rolloverContract).owner()`.
///
///         This guard is therefore load-bearing for the whole authorization model: if any
///         path could reach the rolloverContract hook dispatch with `user != owner`, the Settler check
///         and the rolloverContract check would attest different signers. These tests pin the guard to
///         EVERY state-changing entrypoint that can lead to a rolloverContract dispatch:
///
///           - on-chain `open` / gasless `openFor` — the only ways to reach an `Opened`
///             order, and hence the only gate before async ROLLOVER / async PREMIUM fills.
///           - `fill` (atomic)       — the only fill that admits a fresh order from `None` and
///                                     dispatches hooks in-frame.
///
///         With both doors gated, no reachable path can dispatch a rolloverContract hook phase for an
///         order whose order user is not the rolloverContract owner.
contract UserOwnerCouplingGatesDispatchTest is FillScaffold {
    /// @notice Rollover fill amount for the test order.
    uint256 internal constant FILL = 1_000e18;
    /// @notice Destination amount in the rollover intent.
    uint256 internal constant DST = 1_000e18;
    /// @notice Premium token pull amount approved for the filler.
    uint256 internal constant PREMIUM = 10e18;

    /// @dev Build a fully-formed order whose `user` is a stranger (NOT the cPT holder `cptHolder`),
    ///      signed by that stranger so the cPT-holder signature itself is valid for `orderData.user`.
    ///      This isolates the failure to the `user == owner` guard rather than a bad signature.
    function _strangerOrder()
        internal
        returns (
            RolloverTypes.OrderData memory orderData,
            RolloverTypes.RolloverIntent memory intent,
            uint256 strangerPk,
            address stranger
        )
    {
        (stranger, strangerPk) = makeAddrAndKey("stranger-cpt-holder");

        orderData = _baseOrder();
        orderData.user = stranger; // rolloverContract is owned by `cptHolder`, so user != owner now
        orderData.allowPartialFills = false;
        orderData.orderSize = FILL;

        intent = _buildIntent(bytes32(0), FILL, DST);
        orderData.rolloverIntentHash = _zeroDigestHash(intent);
        intent.orderDigest = _orderDigest(orderData);
    }

    /// @notice On-chain `open` rejects an order whose order user is not the rolloverContract owner,
    ///         so a stranger-cpt-holder order can never reach `Opened` via on-chain admission.
    function testRevert_onchainOpenRejectsUserNotRolloverContractOwner() public {
        (RolloverTypes.OrderData memory orderData,, uint256 strangerPk, address stranger) =
            _strangerOrder();
        strangerPk;

        vm.expectRevert(
            abi.encodeWithSelector(
                Settler__UserNotRolloverContractOwner.selector, stranger, rolloverContract
            )
        );
        vm.prank(stranger);
        ISettler(orderData.settler).open(_onchain(orderData));
    }

    /// @notice `openFor` rejects an order whose order user is not the rolloverContract owner — same
    ///         ownership gate as on-chain `open`, but for the gasless/relayed admission surface.
    function testRevert_openForRejectsUserNotRolloverContractOwner() public {
        (RolloverTypes.OrderData memory orderData,, uint256 strangerPk, address stranger) =
            _strangerOrder();
        bytes memory sig = _signOrder(strangerPk, orderData);

        vm.expectRevert(
            abi.encodeWithSelector(
                Settler__UserNotRolloverContractOwner.selector, stranger, rolloverContract
            )
        );
        ISettler(orderData.settler).openFor(_gasless(orderData), sig, bytes(""));
    }

    /// @notice Atomic `fill` admits a fresh order from `None` and dispatches hooks in-frame;
    ///         it too rejects a stranger-cpt-holder order before any rolloverContract dispatch. The cPT holder
    ///         signature here is valid for `orderData.user`, so the only failing check is the
    ///         `user == owner` guard.
    function testRevert_atomicFillRejectsUserNotRolloverContractOwner() public {
        (
            RolloverTypes.OrderData memory orderData,
            RolloverTypes.RolloverIntent memory intent,
            uint256 strangerPk,
            address stranger
        ) = _strangerOrder();

        bytes32 orderDigest = _orderDigest(orderData);
        bytes memory cptHolderSig = _signOrder(strangerPk, orderData);

        _approveFiller(FILL, PREMIUM);
        bytes memory fillerData = _atomicFillerData(
            FILL, DEFAULT_PREMIUM_CAP, intent, filler, _subFillerKey(filler), cptHolderSig
        );

        vm.prank(filler);
        vm.expectRevert(
            abi.encodeWithSelector(
                Settler__UserNotRolloverContractOwner.selector, stranger, rolloverContract
            )
        );
        ISettler(orderData.settler).fill(orderDigest, _originData(orderData), fillerData);
    }

    /// @notice Positive control: when the order user IS the rolloverContract owner (`cptHolder`), the same envelope
    ///         clears the guard and the order opens. Proves the guard — not some unrelated
    ///         admission failure — is what rejects the stranger-cpt-holder cases above.
    function test_userEqualsOwnerPassesGuardAndOpens() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.allowPartialFills = false;
        orderData.orderSize = FILL;
        RolloverTypes.RolloverIntent memory intent = _buildIntent(bytes32(0), FILL, DST);
        orderData.rolloverIntentHash = _zeroDigestHash(intent);

        bytes memory sig = _signOrder(cptHolderPk, orderData);
        // Does not revert: user == owner == cptHolder.
        ISettler(orderData.settler).openFor(_gasless(orderData), sig, "");
    }
}
