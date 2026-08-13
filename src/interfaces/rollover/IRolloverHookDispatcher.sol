// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @title IRolloverHookDispatcher
/// @notice Settler-facing factory surface for dispatching hook phases into deployed rolloverContracts and
///         exposing the transient origin-settler provenance latch.
interface IRolloverHookDispatcher {
    /// @notice Dispatch a hook phase from an approved Settler into a factory-deployed rolloverContract.
    /// @dev The factory enforces dispatch policy only: dispatchable phase, approved Settler,
    ///      nonzero `orderDigest`, `fillContext.originSettler == msg.sender`,
    ///      factory-deployed `rolloverContract`, and origin-settler latch consistency. It forwards the hook
    ///      payload to the rolloverContract for cPT-holder-signature, digest, context, and signed-order binding
    ///      checks.
    ///
    ///      During dispatch, the factory exposes `msg.sender` through `originatingSettler()` so
    ///      the rolloverContract can verify that `fillContext.originSettler` still matches the active factory
    ///      dispatch frame.
    /// @custom:invariant INV-SETTLER-APPROVED — dispatch requires `msg.sender` to be an
    ///                   currently approved Settler.
    /// @custom:invariant N-INV-FACTORY-ORIGIN-LATCH-SCOPED — the transient origin-settler latch
    ///                   is set for the rolloverContract call and cleared after dispatch.
    /// @param rolloverContract Factory-deployed rolloverContract to dispatch into. In the canonical Settler path this
    ///        is `orderData.rolloverContract`; the factory itself only checks factory deployment.
    /// @param orderDigest Settler-computed order digest; the factory checks nonzero and uses it
    ///        as forwarded dispatch context, while the rolloverContract validates it against `orderData`.
    /// @param phase Hook phase to dispatch; currently ROLLOVER or PREMIUM.
    /// @param intent Hook intent for this order/phase.
    /// @param cptHolderSig cPT-holder EIP-712 or ERC-1271 signature over `orderDigest`.
    /// @param fillContext Settler-supplied execution context. The factory checks
    ///        `fillContext.originSettler`; the rolloverContract validates the order-bound context fields
    ///        against the signed order data.
    /// @param orderData cPT-holder-signed order envelope forwarded to the rolloverContract for digest and
    ///        context binding.
    /// @return dstProduced Rollover-phase dstCST produced and returned to Settler accounting;
    ///         zero for premium phase.
    /// @return srcLeftover Rollover-phase srcCST left unused and returned to Settler accounting;
    ///         zero for premium phase.
    function executeIntentHooks(
        address rolloverContract,
        bytes32 orderDigest,
        RolloverTypes.HookPhase phase,
        RolloverTypes.RolloverIntent calldata intent,
        bytes calldata cptHolderSig,
        RolloverTypes.FillContext calldata fillContext,
        RolloverTypes.OrderData calldata orderData
    ) external returns (uint256 dstProduced, uint256 srcLeftover);

    /// @notice Read the Settler currently dispatching from the factory into a rolloverContract.
    /// @dev Transient latch set by `executeIntentHooks` before the rolloverContract call and cleared after
    ///      the call returns. Returns zero outside a factory-to-rolloverContract dispatch. The rolloverContract uses
    ///      this to verify `fillContext.originSettler`.
    /// @return originSettler Active dispatching Settler, or zero outside dispatch.
    function originatingSettler() external view returns (address originSettler);
}
