// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { FillScaffold } from "../../base/FillScaffold.sol";
import { MockERC7484 } from "../../mocks/MockERC7484.sol";
import { CorkRolloverContract } from "src/CorkRolloverContract.sol";
import {
    CorkRolloverContract__ModuleTypeMismatch
} from "src/errors/CorkRolloverContractErrors.sol";
import { IERC7484 } from "src/interfaces/external/erc7484/IERC7484.sol";
import { ICorkRolloverContract } from "src/interfaces/rollover/ICorkRolloverContract.sol";
import { Typehashes } from "src/libraries/Typehashes.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice Malicious pre-rollover hook: rewrites ERC-7484 registry trust as the rolloverContract.
contract RegistryTrustRewriteModule {
    /// @notice Call `trustAttesters` on the registry as `address(this)` (the rolloverContract).
    /// @param registry ERC-7484 registry address.
    /// @param threshold Attacker-chosen quorum.
    /// @param attester Sole attester to install.
    function execute(address registry, uint8 threshold, address attester) external {
        address[] memory att = new address[](1);
        att[0] = attester;
        IERC7484(registry).trustAttesters(threshold, att);
    }
}

/// @notice F-02 — Cork hook admission uses explicit local attester mirror, not registry getters.
contract DelegatecallTrustMutationTest is FillScaffold {
    /// @notice Fill size for happy-path checks.
    uint256 internal constant FILL = 1_000e18;

    /// @notice Hook that rewrites registry trust through rolloverContract delegatecall context.
    RegistryTrustRewriteModule internal maliciousHook;

    /// @notice Attester installed by the malicious hook in the external registry.
    address internal attackerAttester;

    /// @notice Deploy the malicious hook and attest it under the initial trusted mirror.
    function setUp() public override {
        super.setUp();
        maliciousHook = new RegistryTrustRewriteModule();
        attackerAttester = makeAddr("attackerAttester");
        erc7484.setAttestedType(address(maliciousHook), Typehashes.MODULE_TYPE_PRE_ROLLOVER_HOOK);
        erc7484.setAttestedTypeFor(
            defaultAttester, address(maliciousHook), Typehashes.MODULE_TYPE_PRE_ROLLOVER_HOOK
        );
    }

    function _intentWithTrustRewriteHook(bytes32 orderDigest, uint256 srcAmount)
        internal
        view
        returns (RolloverTypes.RolloverIntent memory)
    {
        RolloverTypes.Call[] memory pre = new RolloverTypes.Call[](2);
        pre[0] = _hook(
            address(sourceSrcCptModule),
            abi.encodeWithSignature("execute(address,uint256)", address(srcCpt), srcAmount)
        );
        pre[1] = _hook(
            address(maliciousHook),
            abi.encodeWithSignature(
                "execute(address,uint8,address)", address(erc7484), uint8(1), attackerAttester
            )
        );
        RolloverTypes.Call[] memory post = new RolloverTypes.Call[](1);
        post[0] = _hook(
            address(consumeDstCptModule),
            abi.encodeWithSignature("execute(address)", address(dstCpt))
        );
        return
            _intentWithHooks(rolloverContract, orderDigest, pre, new RolloverTypes.Call[](0), post);
    }

    /// @notice Registry `trustAttesters` during a hook is restored to the rolloverContract's local mirror.
    function test_delegatecallHookRegistryRewriteIsRestoredToLocalMirror() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.allowPartialFills = false;
        orderData.orderSize = FILL;

        RolloverTypes.RolloverIntent memory probe = _intentWithTrustRewriteHook(bytes32(0), FILL);
        orderData.rolloverIntentHash = _zeroDigestHash(probe);
        bytes32 orderDigest = _openOrder(orderData);

        RolloverTypes.RolloverIntent memory intent = _intentWithTrustRewriteHook(orderDigest, FILL);
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);

        ICorkRolloverContract.RolloverContractTrustSnapshot memory snapBefore =
            ICorkRolloverContract(rolloverContract).rolloverContractSnapshot();
        uint8 thresholdBefore = erc7484.lastThreshold(rolloverContract);

        _approveFiller(FILL, 0);
        _doRolloverAs(orderDigest, orderData, intent, FILL, filler);

        assertEq(
            erc7484.lastThreshold(rolloverContract), thresholdBefore, "registry threshold restored"
        );
        assertEq(
            erc7484.attestersOf(rolloverContract)[0],
            snapBefore.liveTrustAttesters[0],
            "registry attester restored"
        );
        ICorkRolloverContract.RolloverContractTrustSnapshot memory snapAfter =
            ICorkRolloverContract(rolloverContract).rolloverContractSnapshot();
        assertEq(snapAfter.liveTrustThreshold, snapBefore.liveTrustThreshold, "local threshold");
        assertEq(
            snapAfter.liveTrustAttesters[0], snapBefore.liveTrustAttesters[0], "local attester"
        );
        assertGt(thresholdBefore, 0, "sanity: registry had prior trust");
    }

    /// @notice Explicit-attester checks reject modules attested only by a different attester.
    function test_explicitAttesterCheckRejectsWrongAttester() public {
        address wrongAttester = makeAddr("wrongAttester");
        address[] memory att = new address[](1);
        att[0] = wrongAttester;
        vm.expectRevert(
            abi.encodeWithSelector(
                MockERC7484.MockERC7484__ThresholdNotMet.selector,
                address(maliciousHook),
                uint256(1),
                uint256(0)
            )
        );
        erc7484.check(address(maliciousHook), Typehashes.MODULE_TYPE_PRE_ROLLOVER_HOOK, att, 1);
    }

    /// @notice Explicit-attester checks reject unsatisfied thresholds.
    function test_explicitAttesterCheckRejectsThresholdBypass() public {
        address[] memory att = new address[](1);
        att[0] = defaultAttester;
        vm.expectRevert(
            abi.encodeWithSelector(
                MockERC7484.MockERC7484__ThresholdNotMet.selector,
                address(maliciousHook),
                uint256(2),
                uint256(1)
            )
        );
        erc7484.check(address(maliciousHook), Typehashes.MODULE_TYPE_PRE_ROLLOVER_HOOK, att, 2);
    }

    /// @notice Cork rejects unattested modules even when registry trust was rewritten mid-leg.
    function test_explicitAttesterCheckRejectsUnattestedModuleAfterRegistryRewrite() public {
        RegistryTrustRewriteModule rogueModule = new RegistryTrustRewriteModule();
        vm.prank(rolloverContract);
        address[] memory att = new address[](1);
        att[0] = attackerAttester;
        erc7484.trustAttesters(1, att);

        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.allowPartialFills = false;
        orderData.orderSize = FILL;

        RolloverTypes.Call[] memory pre = new RolloverTypes.Call[](1);
        pre[0] = _hook(
            address(rogueModule),
            abi.encodeWithSignature(
                "execute(address,uint8,address)", address(erc7484), uint8(1), attackerAttester
            )
        );
        RolloverTypes.Call[] memory post = new RolloverTypes.Call[](1);
        post[0] = _hook(
            address(consumeDstCptModule),
            abi.encodeWithSignature("execute(address)", address(dstCpt))
        );
        RolloverTypes.RolloverIntent memory probe =
            _intentWithHooks(rolloverContract, bytes32(0), pre, new RolloverTypes.Call[](0), post);
        orderData.rolloverIntentHash = _zeroDigestHash(probe);
        bytes32 orderDigest = _openOrder(orderData);

        RolloverTypes.RolloverIntent memory intent =
            _intentWithHooks(rolloverContract, orderDigest, pre, new RolloverTypes.Call[](0), post);
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);

        _approveFiller(FILL, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContract__ModuleTypeMismatch.selector,
                address(rogueModule),
                Typehashes.MODULE_TYPE_PRE_ROLLOVER_HOOK
            )
        );
        _doRolloverAs(orderDigest, orderData, intent, FILL, filler);
    }

    /// @notice Modules attested under the local mirror still pass after registry-only mutation.
    function test_explicitAttesterCheckAcceptsLocalMirrorAttestedModule() public {
        vm.prank(rolloverContract);
        address[] memory att = new address[](1);
        att[0] = attackerAttester;
        erc7484.trustAttesters(1, att);

        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.allowPartialFills = false;
        orderData.orderSize = FILL;

        RolloverTypes.RolloverIntent memory probe = _intentWithTrustRewriteHook(bytes32(0), FILL);
        orderData.rolloverIntentHash = _zeroDigestHash(probe);
        bytes32 orderDigest = _openOrder(orderData);

        RolloverTypes.RolloverIntent memory intent = _intentWithTrustRewriteHook(orderDigest, FILL);
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);

        _approveFiller(FILL, 0);
        _doRolloverAs(orderDigest, orderData, intent, FILL, filler);
    }

    /// @notice Factory/timelock trust path still updates both mirror and registry.
    function test_factoryTrustPathStillUpdatesRegistry() public {
        address[] memory att = new address[](1);
        att[0] = address(0xBEEF);
        vm.prank(address(factory));
        ICorkRolloverContract(rolloverContract).setTrustConfig(1, att);

        assertEq(erc7484.lastThreshold(rolloverContract), 1, "registry threshold");
        assertEq(erc7484.attestersOf(rolloverContract)[0], address(0xBEEF), "registry attester");
        ICorkRolloverContract.RolloverContractTrustSnapshot memory snap =
            ICorkRolloverContract(rolloverContract).rolloverContractSnapshot();
        assertEq(snap.liveTrustAttesters[0], address(0xBEEF), "local mirror attester");
    }
}
