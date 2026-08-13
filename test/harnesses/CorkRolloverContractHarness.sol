// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { CorkRolloverContract } from "src/CorkRolloverContract.sol";
import { ModuleType } from "src/interfaces/external/erc7484/IERC7484.sol";
import { IPoolManager } from "src/interfaces/external/phoenix/IPoolManager.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice Test harness exposing CorkRolloverContract internal hooks (owner/factory readouts, intent-call execution, preflight, phase rollover, premium routing, sibling cPT resolution) for direct unit testing.
contract CorkRolloverContractHarness is CorkRolloverContract {
    /// @notice RolloverContract storage slot harness.
    bytes32 private constant ROLLOVER_CONTRACT_STORAGE_SLOT_HARNESS =
        0xb4cefcf1cd721ac7aa7779687f98e0bf77365d8cc544d423bc3152971ed5cc00;

    /// @notice Test-only scratch inputs for `exposed_finalizeRolloverLeg`.
    struct FinalizeScratchArgs {
        uint256 srcSharesToBurn;
        uint256 srcCstBefore;
        uint256 srcCptBefore;
        uint256 dstCstBefore;
        uint256 dstCptBefore;
        address srcCpt;
        address dstCpt;
    }

    /// @notice Exposes the internal CWIA-decoded owner address.
    /// @return Return value.
    function exposed_owner() external view returns (address) {
        return _owner();
    }

    /// @notice Exposes the internal CWIA-decoded factory address.
    /// @return Return value.
    function exposed_factory() external view returns (address) {
        return _factory();
    }

    /// @notice Exposes the internal intent-call executor for a specific module type so attestation paths can be unit-tested.
    /// @param hooks Encoded hook payload.
    /// @param moduleType ERC-7484 module type (uint256 enum).
    function exposed_executeIntentCalls(RolloverTypes.Call[] calldata hooks, ModuleType moduleType)
        external
    {
        _executeIntentCalls(hooks, moduleType);
    }

    /// @notice Exposes the internal rollover preflight (Settler-pin, rolloverContract-pin, attester checks) for direct unit testing.
    /// @param orderDigest EIP-712 order digest.
    /// @param fillContext Phase context (router state passed into hook callbacks).
    /// @param params Decoded rollover parameters.
    function exposed_validateRolloverPreflight(
        bytes32 orderDigest,
        RolloverTypes.FillContext calldata fillContext,
        RolloverTypes.RolloverParams calldata params
    ) external view {
        _validateRolloverPreflight(_sHarness(), orderDigest, fillContext, params);
    }

    /// @notice Exposes envelope validation for branch-counter unit testing.
    /// @param intent Encoded RolloverIntent payload.
    /// @param fillContext Phase context.
    function exposed_validateFillEnvelope(
        RolloverTypes.RolloverIntent calldata intent,
        RolloverTypes.FillContext calldata fillContext
    ) external view {
        _validateFillEnvelope(intent, fillContext);
    }

    /// @notice Exposes the mid-rollover phase handler (unwindMint + deposit + dstProduced accounting) for direct unit testing.
    /// @param orderDigest EIP-712 order digest.
    /// @param fillContext Phase context (router state passed into hook callbacks).
    /// @param params Decoded rollover parameters.
    /// @param intent Encoded RolloverIntent payload.
    /// @return actualRolled srcCST actually rolled into the dst leg.
    /// @return dstProduced Reported dstCST produced by the rolloverContract hook.
    /// @return srcLeftover srcCST left over after the rolloverContract hook (refundable to filler).
    function exposed_handlePhaseRollover(
        bytes32 orderDigest,
        RolloverTypes.FillContext calldata fillContext,
        RolloverTypes.RolloverParams calldata params,
        RolloverTypes.RolloverIntent calldata intent
    ) external returns (uint256 actualRolled, uint256 dstProduced, uint256 srcLeftover) {
        return _handlePhaseRollover(_sHarness(), orderDigest, fillContext, params, intent);
    }

    /// @notice Exposes the premium-phase handler for direct unit testing of premium routing hooks.
    /// @param orderDigest EIP-712 order digest.
    /// @param fillContext Phase context (router state passed into hook callbacks).
    /// @param premiumHooks Encoded premium-phase hook payload.
    function exposed_handlePhasePremium(
        bytes32 orderDigest,
        RolloverTypes.FillContext calldata fillContext,
        RolloverTypes.Call[] calldata premiumHooks
    ) external {
        _handlePhasePremium(_sHarness(), orderDigest, fillContext, premiumHooks);
    }

    /// @notice Exposes the rollover finalizer for coverage-only guard tests whose public
    ///         paths are preempted by earlier Phoenix/accounting validation.
    /// @param orderDigest EIP-712 order digest.
    /// @param fillContext Phase context.
    /// @param params Decoded rollover parameters.
    /// @param intent Encoded RolloverIntent payload.
    /// @param args Scratch values.
    /// @param dstProduced Destination CST produced.
    /// @return actualRolled Finalized rolled amount.
    /// @return srcLeftover Finalized source leftover amount.
    function exposed_finalizeRolloverLeg(
        bytes32 orderDigest,
        RolloverTypes.FillContext calldata fillContext,
        RolloverTypes.RolloverParams calldata params,
        RolloverTypes.RolloverIntent calldata intent,
        FinalizeScratchArgs calldata args,
        uint256 dstProduced
    ) external returns (uint256 actualRolled, uint256 srcLeftover) {
        _RolloverScratch memory s;
        s.srcSharesToBurn = args.srcSharesToBurn;
        s.srcCstBefore = args.srcCstBefore;
        s.srcCptBefore = args.srcCptBefore;
        s.dstCstBefore = args.dstCstBefore;
        s.dstCptBefore = args.dstCptBefore;
        s.srcCpt = args.srcCpt;
        s.dstCpt = args.dstCpt;
        return _finalizeRolloverLeg(
            _sHarness(), orderDigest, fillContext, params, intent, s, dstProduced, args.dstCptBefore
        );
    }

    /// @notice Exposes the internal asm-delegatecall hook helper for direct unit testing of
    ///         INV-HOOK-RETURNDATA-DISCARDED (success path drops returndata, failure path
    ///         clamps revert reason at REVERT_REASON_CAP bytes). Bypasses prevalidation and
    ///         the live trust-config mutation guard so tests can target the helper alone.
    /// @param c Single delegatecall hook descriptor.
    function exposed_delegatecallHookDiscardReturndata(RolloverTypes.Call calldata c) external {
        _delegatecallHookDiscardReturndata(c);
    }

    /// @notice Exposes the internal sibling-cPT resolver that pairs a cST PoolShare with its cPT via the Phoenix PoolManager.
    /// @param pm Pool manager address.
    /// @param poolIdRaw Encoded Phoenix pool id.
    /// @param cstToken Cork Swap Token contract.
    /// @return cpt Cork Principal Token (cPT).
    function exposed_siblingCptToken(IPoolManager pm, bytes32 poolIdRaw, address cstToken)
        external
        view
        returns (address cpt)
    {
        return _siblingCptToken(pm, poolIdRaw, cstToken);
    }

    /// @notice Seeds harness-local rollover accounting for branch-counter unit tests.
    /// @param orderDigest EIP-712 order digest.
    /// @param rolledAmount Cumulative rolled amount to store.
    function exposed_seedRolled(bytes32 orderDigest, uint256 rolledAmount) external {
        _sHarness().rolled[orderDigest] = rolledAmount;
    }

    /// @notice Seeds harness-local hook nonce flags for branch-counter unit tests.
    /// @param orderDigest EIP-712 order digest.
    /// @param nonces Hook nonce bitfield to store.
    function exposed_seedHookNonces(bytes32 orderDigest, uint256 nonces) external {
        _sHarness().hookNonces[orderDigest] = nonces;
    }

    /// @notice Seeds harness-local premium replay state for branch-counter unit tests.
    /// @param orderDigest EIP-712 order digest.
    /// @param filler Filler address.
    /// @param subFiller Sub-filler key.
    /// @param fired Whether the premium leg should be marked fired.
    function exposed_seedPremiumFired(
        bytes32 orderDigest,
        address filler,
        bytes32 subFiller,
        bool fired
    ) external {
        _sHarness().premiumFiredFor[orderDigest][filler][subFiller] = fired;
    }

    /// @notice Seeds harness-local live trust config for branch-counter unit tests.
    /// @param threshold Required attester threshold.
    /// @param attesters Trusted attester list.
    function exposed_seedLiveTrust(uint8 threshold, address[] calldata attesters) external {
        RolloverContractStorage storage $ = _sHarness();
        $.liveTrustThreshold = threshold;
        $.liveTrustAttesters = attesters;
    }

    /// @notice Exposes owner-authorization validation for branch-counter unit tests.
    /// @param orderDigest EIP-712 order digest.
    /// @param cptHolderSig cPT-holder signature checked on every dispatch.
    function exposed_ensureOwnerAuthorized(bytes32 orderDigest, bytes calldata cptHolderSig)
        external
        view
    {
        _ensureOwnerAuthorized(orderDigest, cptHolderSig);
    }

    function _sHarness() private pure returns (RolloverContractStorage storage $) {
        bytes32 slot = ROLLOVER_CONTRACT_STORAGE_SLOT_HARNESS;
        assembly {
            $.slot := slot
        }
    }
}
