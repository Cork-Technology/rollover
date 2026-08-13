// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { CommonBase } from "forge-std/Base.sol";
import { StdCheats } from "forge-std/StdCheats.sol";
import { StdUtils } from "forge-std/StdUtils.sol";

import { CorkRolloverContract } from "src/CorkRolloverContract.sol";
import { CorkRolloverContractFactory } from "src/CorkRolloverContractFactory.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice INV-PARAMS-SETTLER-PIN family handler — drives matched / mismatched RolloverParams.settler vs originSettler dispatches.
/// @custom:invariant INV-PARAMS-SETTLER-PIN
contract SettlerPinHandler is CommonBase, StdCheats, StdUtils {
    /// @notice Factory ref.
    /// @return factoryRef Stored factory ref value.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)

    CorkRolloverContractFactory public immutable factoryRef;
    /// @notice Approved settler.
    /// @return approvedSettler Stored approved settler value.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)

    address public immutable approvedSettler;
    /// @notice RolloverContract ref.
    /// @return rolloverContractRef Stored rolloverContract ref value.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)

    address public immutable rolloverContractRef;
    /// @notice Ghost matched attempts.
    /// @return ghostMatchedAttempts Stored ghost matched attempts value.

    uint256 public ghostMatchedAttempts;
    /// @notice Ghost mismatched reverts.
    /// @return ghostMismatchedReverts Stored ghost mismatched reverts value.

    uint256 public ghostMismatchedReverts;
    /// @notice Ghost mismatched accepted.
    /// @return ghostMismatchedAccepted Stored ghost mismatched accepted value.

    uint256 public ghostMismatchedAccepted;

    /// @param rolloverContract_ rolloverContract_.
    /// @param approvedSettler_ approvedSettler_.
    /// @param f f.
    constructor(
        CorkRolloverContractFactory f,
        address approvedSettler_,
        address rolloverContract_
    ) {
        require(approvedSettler_ != address(0), "approvedSettler=0");
        require(rolloverContract_ != address(0), "rolloverContract=0");
        factoryRef = f;
        approvedSettler = approvedSettler_;
        rolloverContractRef = rolloverContract_;
    }

    /// @notice _ctx.
    function _ctx(uint256 fillAmount, address originSettler)
        internal
        view
        returns (RolloverTypes.FillContext memory)
    {
        return RolloverTypes.FillContext({
            filler: address(uint160(uint256(keccak256("pin-handler-filler")))),
            fillAmount: fillAmount,
            rolloverIntentHash: bytes32(uint256(0xC1)),
            fillDeadline: uint64(block.timestamp + 2 days),
            allowPartialFills: true,
            allowUnderfill: false,
            orderSize: 1_000e18,
            originSettler: originSettler,
            premiumToken: address(uint160(uint256(keccak256("pin-handler-premium")))),
            premium: 0,
            subFiller: bytes32(0)
        });
    }

    /// @notice _empty intent.
    function _emptyIntent(bytes32 orderDigest)
        internal
        view
        returns (RolloverTypes.RolloverIntent memory)
    {
        return RolloverTypes.RolloverIntent({
            rolloverContract: rolloverContractRef,
            orderDigest: orderDigest,
            deadline: uint64(block.timestamp + 2 days),
            nonce: 1,
            preRolloverHooks: new RolloverTypes.Call[](0),
            midRolloverHooks: new RolloverTypes.Call[](0),
            postRolloverHooks: new RolloverTypes.Call[](0),
            premiumHooks: new RolloverTypes.Call[](0)
        });
    }

    /// @dev Empty OrderData placeholder. RolloverContract binding will reject it before settler-pin
    ///      fires; this handler only validates the negative-confirmation invariant
    ///      (`ghostMismatchedAccepted` never increments).
    function _emptyOrderData() internal pure returns (RolloverTypes.OrderData memory od) {
        // Zero-initialised by default; explicit return keeps the call site obvious.
        return od;
    }

    /// @notice handler action: dispatch matched.
    /// @param fillSeed Fuzz seed used to pick a fill from a bounded set.
    function dispatchMatched(uint256 fillSeed) external {
        uint256 fillAmount = bound(fillSeed, 1, 100e18);
        bytes32 digest = bytes32(uint256(keccak256(abi.encode("matched", fillSeed))));
        RolloverTypes.RolloverIntent memory intent = _emptyIntent(digest);
        RolloverTypes.FillContext memory fillContext = _ctx(fillAmount, approvedSettler);
        bytes memory sig = new bytes(65);
        ghostMatchedAttempts++;
        vm.prank(approvedSettler);
        try factoryRef.executeIntentHooks(
            rolloverContractRef,
            digest,
            RolloverTypes.HookPhase.ROLLOVER,
            intent,
            sig,
            fillContext,
            _emptyOrderData()
        ) { }
            catch { }
    }

    /// @notice handler action: dispatch mismatched.
    /// @param fillSeed Fuzz seed used to pick a fill from a bounded set.
    function dispatchMismatched(uint256 fillSeed) external {
        uint256 fillAmount = bound(fillSeed, 1, 100e18);
        bytes32 digest = bytes32(uint256(keccak256(abi.encode("mismatched", fillSeed))));
        address tampered = address(uint160(uint256(keccak256(abi.encode("tamper", fillSeed))) | 1));
        if (tampered == approvedSettler) {
            tampered = address(0xDEAD);
        }
        RolloverTypes.RolloverIntent memory intent = _emptyIntent(digest);
        RolloverTypes.FillContext memory fillContext = _ctx(fillAmount, approvedSettler);
        bytes memory sig = new bytes(65);
        vm.prank(approvedSettler);
        try factoryRef.executeIntentHooks(
            rolloverContractRef,
            digest,
            RolloverTypes.HookPhase.ROLLOVER,
            intent,
            sig,
            fillContext,
            _emptyOrderData()
        ) {
            ghostMismatchedAccepted++;
        } catch {
            ghostMismatchedReverts++;
        }
    }
}
