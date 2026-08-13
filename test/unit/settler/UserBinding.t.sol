// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { FillScaffold } from "../../base/FillScaffold.sol";
import { BaseSettler } from "src/BaseSettler.sol";
import { ExactSettler as Settler } from "src/ExactSettler.sol";
import {
    Settler__RolloverContractNotDeployed,
    Settler__UserNotRolloverContractOwner
} from "src/errors/SettlerErrors.sol";
import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import { ICorkRolloverContract } from "src/interfaces/rollover/ICorkRolloverContract.sol";
import { LibFillerPayload } from "src/libraries/LibFillerPayload.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice UserBindingTest — pins `INV-USER-IS-ROLLOVER_CONTRACT-OWNER`: the Settler refuses any order
///         whose `orderData.user` is not the rolloverContract's CWIA-baked owner. The check sits inside
///         `_validateOrderCommon`, so both the `openFor` admission path and the pre-open
///         `fill(ROLLOVER)` admission path are bound by it.
contract UserBindingTest is FillScaffold {
    /// @notice Stranger EOA whose key is recoverable for signing experiments.
    address internal stranger;
    /// @notice Private key for `stranger`.
    uint256 internal strangerPk;

    /// @notice Test fixture setup.
    function setUp() public override {
        super.setUp();
        (stranger, strangerPk) = makeAddrAndKey("stranger");

        // Fund the stranger so an end-to-end fill cannot fail upstream for trivial reasons.
        srcCst.mint(stranger, 1_000_000e18);
        premiumToken.mint(stranger, 1_000_000e18);
    }

    /// @notice openFor MUST revert when `orderData.user` is not the rolloverContract's CWIA owner.
    function test_openFor_revertsWhenUserNotRolloverContractOwner() public {
        _assertOpenForRevertsWhenUserNotRolloverContractOwner(SettlerMode.Exact);
        _assertOpenForRevertsWhenUserNotRolloverContractOwner(SettlerMode.Partial);
    }

    function _assertOpenForRevertsWhenUserNotRolloverContractOwner(SettlerMode mode) internal {
        RolloverTypes.OrderData memory orderData = _orderForMode(mode);
        orderData.user = stranger;

        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory sig = _signOrder(strangerPk, orderData);
        bytes memory empty;

        vm.expectRevert(
            abi.encodeWithSelector(
                Settler__UserNotRolloverContractOwner.selector, stranger, rolloverContract
            )
        );
        _settlerForMode(mode).openFor(g, sig, empty);
    }

    /// @notice openFor MUST succeed when `orderData.user == rolloverContract.owner()`.
    function test_openFor_succeedsWhenUserMatchesRolloverContractOwner() public {
        _assertOpenForSucceedsWhenUserMatchesRolloverContractOwner(SettlerMode.Exact);
        _assertOpenForSucceedsWhenUserMatchesRolloverContractOwner(SettlerMode.Partial);
    }

    function _assertOpenForSucceedsWhenUserMatchesRolloverContractOwner(SettlerMode mode) internal {
        RolloverTypes.OrderData memory orderData = _orderForMode(mode); // user already equals cptHolder == owner
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory sig = _signOrder(cptHolderPk, orderData);
        bytes memory empty;

        _settlerForMode(mode).openFor(g, sig, empty);

        assertEq(
            orderData.user,
            ICorkRolloverContract(rolloverContract).owner(),
            "user must equal cPT holder"
        );
    }

    /// @notice `isDeployedRolloverContract` MUST run before the user-binding check: an undeployed rolloverContract
    ///         reverts with `Settler__RolloverContractNotDeployed` even when the user is also mismatched.
    function test_isDeployedRolloverContractPrecedesUserBinding() public {
        _assertIsDeployedRolloverContractPrecedesUserBinding(SettlerMode.Exact);
        _assertIsDeployedRolloverContractPrecedesUserBinding(SettlerMode.Partial);
    }

    function _assertIsDeployedRolloverContractPrecedesUserBinding(SettlerMode mode) internal {
        RolloverTypes.OrderData memory orderData = _orderForMode(mode);
        orderData.rolloverContract = address(0xDEAD); // never deployed via the factory
        orderData.user = stranger; // user is also bad

        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory sig = _signOrder(strangerPk, orderData);
        bytes memory empty;

        vm.expectRevert(
            abi.encodeWithSelector(Settler__RolloverContractNotDeployed.selector, stranger)
        );
        _settlerForMode(mode).openFor(g, sig, empty);
    }

    /// @notice Pre-open `fill(ROLLOVER)` MUST revert with the binding error when the order's
    ///         user is not the cPT holder — the gas-station / relayer fast path is bound
    ///         identically to `openFor`.
    function test_fill_preOpen_revertsWhenUserNotRolloverContractOwner() public {
        _assertFillPreOpenRevertsWhenUserNotRolloverContractOwner(SettlerMode.Exact);
        _assertFillPreOpenRevertsWhenUserNotRolloverContractOwner(SettlerMode.Partial);
    }

    function _assertFillPreOpenRevertsWhenUserNotRolloverContractOwner(SettlerMode mode) internal {
        RolloverTypes.OrderData memory orderData = _orderForMode(mode);
        orderData.user = stranger;
        bytes32 orderDigest = _orderDigest(orderData);

        // No openFor; status is `None`. Build a valid intent so the only reason to revert is
        // the user binding inside `_validateOrderForFill`.
        RolloverTypes.RolloverIntent memory intent = _signedIntent(orderDigest, 500e18, 500e18);

        _approveFiller(500e18, 0);

        bytes memory empty;
        bytes memory cptHolderOrderSig = _signOrder(cptHolderPk, orderData);
        bytes memory rolloverLeg = abi.encode(
            uint8(RolloverTypes.HookPhase.ROLLOVER),
            uint256(500e18),
            uint256(0),
            filler,
            address(0),
            intent,
            uint256(0),
            empty,
            bytes32(0),
            cptHolderOrderSig
        );
        bytes memory fillerData =
            abi.encode(uint8(255), rolloverLeg, uint256(1_000_000e18), cptHolderOrderSig);

        vm.prank(filler);
        vm.expectRevert(
            abi.encodeWithSelector(
                Settler__UserNotRolloverContractOwner.selector, stranger, rolloverContract
            )
        );
        _settlerForMode(mode).fill(orderDigest, _originData(orderData), fillerData);
    }

    /// @notice Pre-open `fill(ROLLOVER)` MUST succeed when `orderData.user == rolloverContract.owner()`.
    /// @dev Exercises the None-branch admission via `_validateOrderForFill` end-to-end.
    function test_fill_preOpen_succeedsWhenUserMatchesRolloverContractOwner() public {
        _assertFillPreOpenSucceedsWhenUserMatchesRolloverContractOwner(SettlerMode.Exact);
    }

    /// @notice Partial pre-open `fill(ROLLOVER)` also admits only the cPT holder.
    function test_fill_preOpen_partial_succeedsWhenUserMatchesRolloverContractOwner() public {
        _assertFillPreOpenSucceedsWhenUserMatchesRolloverContractOwner(SettlerMode.Partial);
    }

    function _assertFillPreOpenSucceedsWhenUserMatchesRolloverContractOwner(SettlerMode mode)
        internal
    {
        // Build a draft intent first so its zero-digest hash can be pinned into the order.
        RolloverTypes.RolloverIntent memory draft = _buildIntent(bytes32(0), 500e18, 500e18);

        RolloverTypes.OrderData memory orderData = _orderForMode(mode); // user == cptHolder == owner
        // INV-EXACT-FILL-SIZE-BINDING: probe drives a partial-amount fill (500e18 on a 1000e18
        // order); allowUnderfill must be true so the strict-exact admission gate accepts it
        // (partial mode is unaffected — the universal `<= orderSize` check still applies).
        orderData.allowUnderfill = true;
        orderData.rolloverIntentHash = _zeroDigestHash(draft);

        bytes32 orderDigest = _orderDigest(orderData);

        RolloverTypes.RolloverIntent memory intent = _signedIntent(orderDigest, 500e18, 500e18);

        _approveFiller(500e18, 0);

        _doRolloverAs(orderDigest, orderData, intent, 500e18, filler);

        assertEq(
            orderData.user,
            ICorkRolloverContract(rolloverContract).owner(),
            "user must equal cPT holder"
        );
    }

    /// @notice Property: any order admitted by `openFor` has `orderData.user == rolloverContract.owner()`.
    /// @dev Stateless fuzz — Foundry picks `keySeed` and we drive both signature and the
    ///      `user` field with the derived EOA. Either the open reverts (user != owner) or the
    ///      open succeeds (user == owner). There is no third outcome.
    /// @param keySeed Fuzz seed bounded into a valid secp256k1 private-key range.
    function testFuzz_acceptedOrdersHaveUserEqualsRolloverContractOwner(uint256 keySeed) public {
        // Foundry vm.sign rejects 0 and curve-order values; bound into a safe range.
        uint256 pk = bound(keySeed, 1, type(uint128).max);
        address candidate = vm.addr(pk);

        RolloverTypes.OrderData memory orderData = _orderForMode(SettlerMode.Exact);
        orderData.user = candidate;

        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory sig = _signOrder(pk, orderData);
        bytes memory empty;

        address rolloverContractOwner = ICorkRolloverContract(rolloverContract).owner();

        if (candidate != rolloverContractOwner) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    Settler__UserNotRolloverContractOwner.selector, candidate, rolloverContract
                )
            );
            settler.openFor(g, sig, empty);
        } else {
            settler.openFor(g, sig, empty);
            assertEq(
                orderData.user, rolloverContractOwner, "accepted order user must equal cPT holder"
            );
        }
    }
}
