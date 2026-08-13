// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

import { FillScaffold } from "../../base/FillScaffold.sol";
import { CorkRolloverContract } from "src/CorkRolloverContract.sol";
import { ModuleType } from "src/interfaces/external/erc7484/IERC7484.sol";
import { MarketId } from "src/interfaces/external/phoenix/IPoolManager.sol";
import { ICorkRolloverContract } from "src/interfaces/rollover/ICorkRolloverContract.sol";
import { Typehashes } from "src/libraries/Typehashes.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

import { CorkRolloverContractHarness } from "../../harnesses/CorkRolloverContractHarness.sol";
import { MockERC20 } from "../../mocks/MockERC20.sol";
import { MockCpt } from "../../mocks/MockPhoenix.sol";
import {
    CorkRolloverContract__BadIntentSignature,
    CorkRolloverContract__DstPoolIdMismatch,
    CorkRolloverContract__HookTargetNoCode,
    CorkRolloverContract__InvalidThreshold,
    CorkRolloverContract__MayNotAllowFailure,
    CorkRolloverContract__MayNotHaveValue,
    CorkRolloverContract__ModuleTypeMismatch,
    CorkRolloverContract__MustBeDelegateCall,
    CorkRolloverContract__OverfillCeiling,
    CorkRolloverContract__PhaseAlreadyConsumed,
    CorkRolloverContract__SettlerMismatch,
    CorkRolloverContract__SrcCptNotRestored,
    CorkRolloverContract__SrcPoolIdMismatch,
    CorkRolloverContract__UnderfillNotAllowed,
    CorkRolloverContract__ZeroRollover
} from "src/errors/CorkRolloverContractErrors.sol";

/// @notice No-op executor hook for CorkRolloverContract intent-call branch coverage.
contract BranchCoverageNoopHook {
    /// @notice No-op delegatecall target.
    function execute() external pure { }
}

/// @notice Delegatecall target that mutates the harness-local CorkRolloverContract trust mirror.
contract BranchCoverageTrustMutator {
    /// @notice Storage slot mirrored from the CorkRolloverContract harness for delegatecall mutation coverage.
    bytes32 private constant ROLLOVER_CONTRACT_STORAGE_SLOT_HARNESS =
        0xb4cefcf1cd721ac7aa7779687f98e0bf77365d8cc544d423bc3152971ed5cc00;

    /// @notice Minimal CorkRolloverContract harness storage layout needed by the delegatecall mutator.
    struct RolloverContractStorage {
        mapping(bytes32 => uint256) hookNonces;
        mapping(bytes32 => uint256) rolled;
        mapping(bytes32 => mapping(address => mapping(bytes32 => bool))) premiumFiredFor;
        uint8 liveTrustThreshold;
        address[] liveTrustAttesters;
    }

    /// @notice Mutates the live trust threshold in delegatecall context.
    /// @param threshold New threshold value.
    function mutate(uint8 threshold) external {
        _sHarness().liveTrustThreshold = threshold;
    }

    function _sHarness() private pure returns (RolloverContractStorage storage $) {
        bytes32 slot = ROLLOVER_CONTRACT_STORAGE_SLOT_HARNESS;
        assembly {
            $.slot := slot
        }
    }
}

/// @notice Delegatecall target that transfers token balance out of the calling rolloverContract.
contract BranchCoverageTokenSweepHook {
    /// @notice Transfers tokens from the delegatecall caller context.
    /// @param token Token to transfer.
    /// @param to Recipient.
    /// @param amount Amount to transfer.
    function sweep(address token, address to, uint256 amount) external {
        MockERC20(token).transfer(to, amount);
    }
}

/// @notice CorkRolloverContract branch-counter coverage for duplicated defensive internal guards.
contract CorkRolloverContractBranchCoverageTest is FillScaffold {
    /// @notice Harness-local terminal bit for rollover phase.
    uint256 internal constant PHASE_0_TERMINAL_BIT = 1;

    /// @notice Harness clone with CWIA args and exposed internal methods.
    CorkRolloverContractHarness internal harness;

    /// @notice No-op hook used by prevalidation tests.
    BranchCoverageNoopHook internal noopHook;

    /// @notice Trust-mutating hook used by executor mutation tests.
    BranchCoverageTrustMutator internal trustMutator;

    /// @notice Token-sweeping hook used by premium sweep tests.
    BranchCoverageTokenSweepHook internal sweepHook;

    /// @notice Post-rollover hook that mints srcCPT into the rolloverContract.
    SourceSrcCptCoverageHook internal sourceSrcCptHook;

    /// @notice Test fixture setup.
    function setUp() public override {
        super.setUp();

        CorkRolloverContractHarness harnessImpl = new CorkRolloverContractHarness();
        bytes memory args = abi.encodePacked(cptHolder, address(factory), address(erc7484));
        harness =
            CorkRolloverContractHarness(Clones.cloneWithImmutableArgs(address(harnessImpl), args));

        noopHook = new BranchCoverageNoopHook();
        trustMutator = new BranchCoverageTrustMutator();
        sweepHook = new BranchCoverageTokenSweepHook();
        sourceSrcCptHook = new SourceSrcCptCoverageHook();
        erc7484.setAttestedType(address(noopHook), Typehashes.MODULE_TYPE_EXECUTOR);
        erc7484.setAttestedType(address(trustMutator), Typehashes.MODULE_TYPE_EXECUTOR);
        erc7484.setAttestedType(address(sweepHook), Typehashes.MODULE_TYPE_EXECUTOR);
        erc7484.setAttestedType(
            address(sourceSrcCptHook), Typehashes.MODULE_TYPE_POST_ROLLOVER_HOOK
        );
        _seedHarnessTrust();
    }

    function _signDigest(uint256 pk, bytes32 digest) internal returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @notice Covers public rolloverContract trust config validation for zero and duplicate attesters.
    function testRevert_setTrustConfigRejectsZeroAndDuplicateAttesters() public {
        address[] memory zeroAttesters = new address[](1);
        zeroAttesters[0] = address(0);
        vm.prank(address(factory));
        vm.expectRevert(CorkRolloverContract__InvalidThreshold.selector);
        ICorkRolloverContract(rolloverContract).setTrustConfig(1, zeroAttesters);

        address[] memory duplicateAttesters = new address[](2);
        duplicateAttesters[0] = defaultAttester;
        duplicateAttesters[1] = defaultAttester;
        vm.prank(address(factory));
        vm.expectRevert(CorkRolloverContract__InvalidThreshold.selector);
        ICorkRolloverContract(rolloverContract).setTrustConfig(1, duplicateAttesters);
    }

    /// @notice Covers initialize's threshold greater than default attester count branch.
    function testRevert_initializeRejectsThresholdAboveDefaultAttesters() public {
        CorkRolloverContract freshImpl = new CorkRolloverContract();
        bytes memory args = abi.encodePacked(cptHolder, address(this), address(erc7484));
        address freshRolloverContract = Clones.cloneWithImmutableArgs(address(freshImpl), args);
        address[] memory defaults = new address[](1);
        defaults[0] = defaultAttester;

        vm.expectRevert(CorkRolloverContract__InvalidThreshold.selector);
        ICorkRolloverContract(freshRolloverContract).initialize(2, defaults);
    }

    /// @notice Covers rollover preflight terminal, zero-fill, overfill, pool-pin, and quantum guards.
    function testRevert_validateRolloverPreflightBranchMatrix() public {
        bytes32 digest = bytes32(uint256(0xA11CE));
        RolloverTypes.RolloverParams memory params = _baseOrder().rolloverParams;

        harness.exposed_seedHookNonces(digest, PHASE_0_TERMINAL_BIT);
        vm.expectRevert(CorkRolloverContract__PhaseAlreadyConsumed.selector);
        harness.exposed_validateRolloverPreflight(digest, _fillContext(100e18, 1_000e18), params);
        harness.exposed_seedHookNonces(digest, 0);

        vm.expectRevert(CorkRolloverContract__ZeroRollover.selector);
        harness.exposed_validateRolloverPreflight(digest, _fillContext(0, 1_000e18), params);

        harness.exposed_seedRolled(digest, 900e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContract__OverfillCeiling.selector, 900e18, 200e18, 1_000e18
            )
        );
        harness.exposed_validateRolloverPreflight(digest, _fillContext(200e18, 1_000e18), params);
        harness.exposed_seedRolled(digest, 0);

        RolloverTypes.RolloverParams memory badSrcPool = params;
        badSrcPool.srcPoolId = bytes32(uint256(0xBAD5));
        vm.expectRevert(CorkRolloverContract__SrcPoolIdMismatch.selector);
        harness.exposed_validateRolloverPreflight(
            digest, _fillContext(100e18, 1_000e18), badSrcPool
        );

        RolloverTypes.RolloverParams memory badDstPool = _baseOrder().rolloverParams;
        badDstPool.dstPoolId = bytes32(uint256(0xBAD6));
        vm.expectRevert(CorkRolloverContract__DstPoolIdMismatch.selector);
        harness.exposed_validateRolloverPreflight(
            digest, _fillContext(100e18, 1_000e18), badDstPool
        );

        _rebindSrcPoolToSixDecimalCollateral();
        RolloverTypes.RolloverParams memory quantumParams = _baseOrder().rolloverParams;
        vm.expectRevert();
        harness.exposed_validateRolloverPreflight(
            digest, _fillContext(100e18, 1_000e18 + 1), quantumParams
        );

        quantumParams = _baseOrder().rolloverParams;
        vm.expectRevert();
        harness.exposed_validateRolloverPreflight(
            digest, _fillContext(100e18 + 1, 1_000e18), quantumParams
        );

        harness.exposed_seedRolled(digest, 1);
        quantumParams = _baseOrder().rolloverParams;
        vm.expectRevert();
        harness.exposed_validateRolloverPreflight(
            digest, _fillContext(999e18, 1_000e18), quantumParams
        );
    }

    /// @notice Covers envelope branches that factory dispatch state normally preempts.
    function testRevert_validateFillEnvelopeBranchMatrix() public {
        bytes32 digest = bytes32(uint256(0xE11));
        RolloverTypes.RolloverIntent memory intent = _emptyIntent(address(harness), digest);

        vm.expectRevert(CorkRolloverContract__SettlerMismatch.selector);
        harness.exposed_validateFillEnvelope(intent, _fillContextWithOrigin(address(settler)));
    }

    /// @notice cPT holder authorization rejects an empty or invalid signature.
    function testRevert_ensureOwnerAuthorizedBadSignatureReverts() public {
        bytes32 digest = bytes32(uint256(0xA18));

        vm.expectRevert(CorkRolloverContract__BadIntentSignature.selector);
        harness.exposed_ensureOwnerAuthorized(digest, bytes(""));
    }

    /// @notice cPT holder authorization accepts a valid owner signature.
    function test_ensureOwnerAuthorizedValidCptHolderSig() public {
        bytes32 digest = bytes32(uint256(0xA19));

        harness.exposed_ensureOwnerAuthorized(digest, _signDigest(cptHolderPk, digest));
    }

    /// @notice A previous valid dispatch does not authorize a later dispatch without a signature.
    function testRevert_ensureOwnerAuthorizedDoesNotCacheValidSignature() public {
        bytes32 digest = bytes32(uint256(0xA20));

        harness.exposed_ensureOwnerAuthorized(digest, _signDigest(cptHolderPk, digest));

        vm.expectRevert(CorkRolloverContract__BadIntentSignature.selector);
        harness.exposed_ensureOwnerAuthorized(digest, bytes(""));
    }

    /// @notice Covers intent-call prevalidation guard branches.
    function testRevert_executeIntentCallsPrevalidationBranchMatrix() public {
        RolloverTypes.Call[] memory hooks = new RolloverTypes.Call[](1);
        hooks[0] = _coverageHook(address(noopHook), abi.encodeCall(noopHook.execute, ()));
        hooks[0].isDelegateCall = false;
        vm.expectRevert(CorkRolloverContract__MustBeDelegateCall.selector);
        harness.exposed_executeIntentCalls(hooks, Typehashes.MODULE_TYPE_EXECUTOR);

        hooks[0] = _coverageHook(address(noopHook), abi.encodeCall(noopHook.execute, ()));
        hooks[0].allowFailure = true;
        vm.expectRevert(CorkRolloverContract__MayNotAllowFailure.selector);
        harness.exposed_executeIntentCalls(hooks, Typehashes.MODULE_TYPE_EXECUTOR);

        hooks[0] = _coverageHook(address(noopHook), abi.encodeCall(noopHook.execute, ()));
        hooks[0].value = 1;
        vm.expectRevert(CorkRolloverContract__MayNotHaveValue.selector);
        harness.exposed_executeIntentCalls(hooks, Typehashes.MODULE_TYPE_EXECUTOR);

        address noCode = makeAddr("no-code-hook");
        hooks[0] = _coverageHook(noCode, bytes(""));
        vm.expectRevert(
            abi.encodeWithSelector(CorkRolloverContract__HookTargetNoCode.selector, noCode)
        );
        harness.exposed_executeIntentCalls(hooks, Typehashes.MODULE_TYPE_EXECUTOR);

        BranchCoverageNoopHook unattested = new BranchCoverageNoopHook();
        hooks[0] = _coverageHook(address(unattested), abi.encodeCall(unattested.execute, ()));
        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContract__ModuleTypeMismatch.selector,
                address(unattested),
                Typehashes.MODULE_TYPE_EXECUTOR
            )
        );
        harness.exposed_executeIntentCalls(hooks, Typehashes.MODULE_TYPE_EXECUTOR);
    }

    /// @notice Covers the live-trust mutation guard after a successful delegatecall hook.
    function testRevert_executeIntentCallsDetectsLiveTrustMutation() public {
        RolloverTypes.Call[] memory hooks = new RolloverTypes.Call[](1);
        hooks[0] = _coverageHook(address(trustMutator), abi.encodeCall(trustMutator.mutate, (2)));

        vm.expectRevert();
        harness.exposed_executeIntentCalls(hooks, Typehashes.MODULE_TYPE_EXECUTOR);
    }

    /// @notice Covers the premium hook standing-balance sweep trip-wire.
    function testRevert_handlePhasePremiumDetectsStandingBalanceSweep() public {
        bytes32 digest = bytes32(uint256(0xBEEF));
        uint256 premium = 10e18;
        uint256 standing = 5e18;
        premiumToken.mint(address(harness), premium + standing);
        harness.exposed_seedRolled(digest, 1);

        RolloverTypes.Call[] memory hooks = new RolloverTypes.Call[](1);
        hooks[0] = _coverageHook(
            address(sweepHook),
            abi.encodeCall(
                sweepHook.sweep, (address(premiumToken), makeAddr("premium-sink"), premium + 1)
            )
        );

        vm.expectRevert();
        harness.exposed_handlePhasePremium(digest, _premiumFillContext(premium), hooks);
    }

    /// @notice Coverage-only: earlier public rollover paths preempt this finalizer guard.
    function testRevert_finalizeRolloverLegRejectsNoUnderfillMismatch() public {
        bytes32 digest = bytes32(uint256(0xF110));
        RolloverTypes.RolloverParams memory params = _baseOrder().rolloverParams;
        RolloverTypes.RolloverIntent memory intent = _emptyIntent(address(harness), digest);
        RolloverTypes.FillContext memory fillContext = _fillContext(100e18, 100e18);

        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContract__UnderfillNotAllowed.selector, 100e18, 99e18
            )
        );
        harness.exposed_finalizeRolloverLeg(
            digest,
            fillContext,
            params,
            intent,
            CorkRolloverContractHarness.FinalizeScratchArgs({
                srcSharesToBurn: 99e18,
                srcCstBefore: 100e18,
                srcCptBefore: 0,
                dstCstBefore: 0,
                dstCptBefore: 0,
                srcCpt: address(srcCpt),
                dstCpt: address(dstCpt)
            }),
            0
        );
    }

    /// @notice Coverage-only: a targeted post-hook source-CPT mutation trips the finalizer guard.
    function testRevert_finalizeRolloverLegRejectsSourceCptNotRestored() public {
        bytes32 digest = bytes32(uint256(0xF111));
        uint256 fillAmount = 100e18;
        RolloverTypes.RolloverParams memory params = _baseOrder().rolloverParams;
        RolloverTypes.FillContext memory fillContext = _fillContext(fillAmount, fillAmount);

        dstCst.mint(address(harness), fillAmount);
        srcCst.mint(address(harness), fillAmount);

        RolloverTypes.Call[] memory hooks = new RolloverTypes.Call[](1);
        hooks[0] = _coverageHook(
            address(sourceSrcCptHook),
            abi.encodeCall(sourceSrcCptHook.execute, (address(srcCpt), 1))
        );
        RolloverTypes.RolloverIntent memory intent =
            _intentWithHooks(address(harness), digest, _emptyHooks(), _emptyHooks(), hooks);

        vm.expectRevert(
            abi.encodeWithSelector(CorkRolloverContract__SrcCptNotRestored.selector, 0, 1)
        );
        harness.exposed_finalizeRolloverLeg(
            digest,
            fillContext,
            params,
            intent,
            CorkRolloverContractHarness.FinalizeScratchArgs({
                srcSharesToBurn: fillAmount,
                srcCstBefore: fillAmount,
                srcCptBefore: 0,
                dstCstBefore: 0,
                dstCptBefore: 0,
                srcCpt: address(srcCpt),
                dstCpt: address(dstCpt)
            }),
            fillAmount
        );
    }

    function _seedHarnessTrust() internal {
        address[] memory attesters = new address[](1);
        attesters[0] = defaultAttester;
        harness.exposed_seedLiveTrust(1, attesters);
    }

    function _coverageHook(address target, bytes memory callData)
        internal
        pure
        returns (RolloverTypes.Call memory)
    {
        return RolloverTypes.Call({
            target: target, callData: callData, value: 0, allowFailure: false, isDelegateCall: true
        });
    }

    function _fillContext(uint256 fillAmount, uint256 orderSize)
        internal
        view
        returns (RolloverTypes.FillContext memory)
    {
        return _fillContext(
            filler,
            fillAmount,
            bytes32(uint256(0xCAFE)),
            uint64(block.timestamp + 1 days),
            true,
            orderSize,
            address(settler),
            address(premiumToken),
            0
        );
    }

    function _premiumFillContext(uint256 premium)
        internal
        view
        returns (RolloverTypes.FillContext memory)
    {
        return _fillContext(
            filler,
            0,
            bytes32(uint256(0xCAFE)),
            uint64(block.timestamp + 1 days),
            true,
            1_000e18,
            address(settler),
            address(premiumToken),
            premium
        );
    }

    function _fillContextWithOrigin(address originSettler)
        internal
        view
        returns (RolloverTypes.FillContext memory)
    {
        return _fillContext(
            filler,
            100e18,
            bytes32(uint256(0xCAFE)),
            uint64(block.timestamp + 1 days),
            true,
            1_000e18,
            originSettler,
            address(premiumToken),
            0
        );
    }

    function _rebindSrcPoolToSixDecimalCollateral() internal {
        MockERC20 ca6 = new MockERC20("CA6", "CA6", 6);
        phoenixPool.bind(srcCst.poolId(), srcCst, srcCpt, ca6);
        srcCst.setPoolManager(phoenixPool);
    }
}

/// @notice Delegatecall post-hook that mints srcCPT into the calling rolloverContract.
contract SourceSrcCptCoverageHook {
    /// @notice Mint source CPT to the delegatecall caller context.
    /// @param srcCpt Source CPT token.
    /// @param amount Amount to mint.
    function execute(address srcCpt, uint256 amount) external {
        MockCpt(srcCpt).mint(address(this), amount);
    }
}
