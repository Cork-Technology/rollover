// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { CountingSettler } from "../../mocks/CountingSettler.sol";
import { MockERC20 } from "../../mocks/MockERC20.sol";
import { MockEVC } from "../../mocks/MockEVC.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { EvcRolloverAdapter, IEVC } from "src/EvcRolloverAdapter.sol";
import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import { ISettler } from "src/interfaces/settlers/ISettler.sol";
import { LibSettlerHashing } from "src/libraries/LibSettlerHashing.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

import { ISignatureTransfer } from "permit2/interfaces/ISignatureTransfer.sol";
import {
    EvcRolloverAdapter__FundingAccountMismatch,
    EvcRolloverAdapter__FundingSigInvalid,
    EvcRolloverAdapter__SubaccountAuthorityMissing
} from "src/errors/EvcRolloverAdapterErrors.sol";

/// @notice Mirrors Permit2's `SignatureExpired` revert — redeclared locally
///         because the upstream package pragma pins to `=0.8.17` and cannot
///         be imported into 0.8.34.
/// @param signatureDeadline Deadline encoded in the expired Permit2 signature.
error SignatureExpired(uint256 signatureDeadline);

/// @notice Mirrors Permit2's `InvalidNonce` revert — redeclared locally for
///         the same 0.8.17 pragma-pin reason.
error InvalidNonce();

/// @notice Subset of `SignatureVerification` errors raised by Permit2.
library PermitVerifyErrors {
    /// @notice Mirrors Permit2's `InvalidSigner` revert (witness or signer
    ///         mismatch) — redeclared locally for the 0.8.17 pragma-pin reason.
    error InvalidSigner();

    /// @notice Mirrors Permit2's `InvalidContractSignature` revert — redeclared
    ///         locally for the 0.8.17 pragma-pin reason.
    error InvalidContractSignature();
}

/// @notice Minimal EIP-1271 contract that returns MAGIC only for the exact
///         (hash, sigPrefix) pair primed via `setExpected`. Demonstrates the
///         stateful-1271 priming attack class — and that witness-bound sigs
///         remain safe because the *hash* (not just sig) is signed bytes.
contract StatefulMock1271 {
    /// @notice Currently-approved hash for `isValidSignature`. Mutable to model
    ///         the stateful-1271 priming attack class A-10 demonstrates.
    bytes32 public expectedHash;
    /// @notice Currently-approved leading 32 bytes of the signature blob.
    bytes32 public expectedSigPrefix;
    /// @notice ERC-1271 magic value returned on a valid match.
    bytes4 internal constant MAGIC = 0x1626ba7e;

    /// @notice Approve the `(hash, sigPrefix)` tuple. Switches state for A-10.
    /// @param h Hash the verifier will accept as valid.
    /// @param sigPrefix First 32 bytes of the signature blob to match.
    function setExpected(bytes32 h, bytes32 sigPrefix) external {
        expectedHash = h;
        expectedSigPrefix = sigPrefix;
    }

    /// @notice ERC-1271 verification entrypoint — returns `MAGIC` only when the
    ///         caller-provided `(hash, sig)` matches the primed expectation.
    /// @param hash 32-byte digest the consumer claims this contract signed.
    /// @param sig Caller-supplied signature blob; must be at least 32 bytes.
    /// @return ERC-1271 magic value on match; sentinel `0xffffffff` otherwise.
    function isValidSignature(bytes32 hash, bytes calldata sig) external view returns (bytes4) {
        if (sig.length >= 32 && hash == expectedHash && bytes32(sig[0:32]) == expectedSigPrefix) {
            return MAGIC;
        }
        return 0xffffffff;
    }
}

/// @notice Acceptance tests A-1..A-15 covering Permit2 witness-bound funding.
/// @dev Validates INV-ADAPTER-JOB-AUTHORIZED and INV-ADAPTER-NO-STANDING-ALLOWANCE.
contract Permit2WitnessAuthorizationTest is BaseTest {
    /// @notice Controller wired into the adapter under test.
    address internal constant CONTROLLER = address(0xC0F1E);

    /// @notice Shared MockEVC fronting the adapter.
    MockEVC internal evcMock;
    /// @notice CountingSettler bound to the exact slot.
    CountingSettler internal exactCount;
    /// @notice CountingSettler bound to the partial slot.
    CountingSettler internal partialCount;
    /// @notice Adapter under test.
    EvcRolloverAdapter internal adapter;

    /// @notice EOA subaccount receiving test fills and refunds.
    address internal subaccount;
    /// @notice Subaccount private key.
    uint256 internal subaccountPk;

    /// @inheritdoc BaseTest
    function setUp() public override {
        super.setUp();
        bytes32 domainSep = settler.DOMAIN_SEPARATOR();
        evcMock = new MockEVC();
        exactCount = new CountingSettler(domainSep);
        partialCount = new CountingSettler(domainSep);
        adapter = new EvcRolloverAdapter(
            IEVC(address(evcMock)),
            CONTROLLER,
            ISettler(address(exactCount)),
            ISettler(address(partialCount)),
            ISignatureTransfer(address(permit2))
        );

        (subaccount, subaccountPk) = makeAddrAndKey("permit2-subaccount");
        evcMock.setAccountOwner(subaccount, subaccount);
        evcMock.setFrame(subaccount, true, CONTROLLER);
        vm.startPrank(subaccount);
        srcCst.approve(address(permit2), type(uint256).max);
        premiumToken.approve(address(permit2), type(uint256).max);
        vm.stopPrank();
        srcCst.mint(subaccount, 1_000_000e18);
        premiumToken.mint(subaccount, 1_000_000e18);
    }

    function _baseJob(uint256 fillerSrc, uint256 premiumAmt)
        internal
        view
        returns (
            EvcRolloverAdapter.EvcRolloverJob memory j,
            RolloverTypes.OrderData memory orderData
        )
    {
        orderData = _baseOrder();
        orderData.settler = address(exactCount);
        orderData.rolloverParams.settler = address(exactCount);
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        RolloverTypes.RolloverIntent memory intent;
        bytes memory empty;
        j = EvcRolloverAdapter.EvcRolloverJob({
            settler: ISettler(address(exactCount)),
            order: g,
            userSig: empty,
            subaccount: subaccount,
            fundingAccount: subaccount,
            recipient: subaccount,
            srcCst: IERC20(address(srcCst)),
            premiumToken: IERC20(address(premiumToken)),
            fillerSrcCst: fillerSrc,
            minDstPerSrc: 0,
            intent: intent,
            premium: premiumAmt,
            fillerAuthSig: "",
            nonce: uint256(keccak256(abi.encode(block.timestamp, fillerSrc, premiumAmt))),
            deadline: block.timestamp + 1 hours,
            fundingSig: ""
        });
    }

    function _signJob(
        EvcRolloverAdapter.EvcRolloverJob memory j,
        uint256 pk,
        RolloverTypes.OrderData memory orderData
    ) internal view returns (bytes memory) {
        return _signPermit2WitnessForJob(j, pk, address(adapter), address(settler), orderData);
    }

    function _call(EvcRolloverAdapter.EvcRolloverJob memory j) internal {
        bytes memory data = abi.encodeCall(EvcRolloverAdapter.execute, (j));
        evcMock.proxy(subaccount, CONTROLLER, address(adapter), data);
    }

    function _callPartial(EvcRolloverAdapter.EvcRolloverJob memory j) internal {
        bytes memory data = abi.encodeCall(EvcRolloverAdapter.executePartial, (j));
        evcMock.proxy(subaccount, CONTROLLER, address(adapter), data);
    }

    /// @notice A-1: empty fundingSig reverts with `__FundingSigInvalid`.
    function testRevert_A1_emptyFundingSig() public {
        (EvcRolloverAdapter.EvcRolloverJob memory j,) = _baseJob(10e18, 5e18);
        // fundingSig left empty by default.
        vm.expectRevert(EvcRolloverAdapter__FundingSigInvalid.selector);
        _call(j);
    }

    /// @notice A-2: wrong token in permit (sign for srcCst, swap to dstCst) reverts.
    function testRevert_A2_wrongToken() public {
        (EvcRolloverAdapter.EvcRolloverJob memory j, RolloverTypes.OrderData memory od) =
            _baseJob(10e18, 5e18);
        j.fundingSig = _signJob(j, subaccountPk, od);
        // Mutate token AFTER sign - witness was over original srcCst but job now ships dstCst.
        j.srcCst = IERC20(address(dstCst));
        vm.expectRevert(PermitVerifyErrors.InvalidSigner.selector);
        _call(j);
    }

    /// @notice A-3: amount less than `fillerSrcCst` in permit - sign for 10e18 then bump to 20e18.
    function testRevert_A3_amountLessThanFiller() public {
        (EvcRolloverAdapter.EvcRolloverJob memory j, RolloverTypes.OrderData memory od) =
            _baseJob(10e18, 5e18);
        j.fundingSig = _signJob(j, subaccountPk, od);
        // Bump fillerSrcCst after signing: witness mismatch.
        j.fillerSrcCst = 20e18;
        vm.expectRevert(PermitVerifyErrors.InvalidSigner.selector);
        _call(j);
    }

    /// @notice A-4: deadline in past reverts with Permit2 `SignatureExpired`.
    function testRevert_A4_deadlineInPast() public {
        (EvcRolloverAdapter.EvcRolloverJob memory j, RolloverTypes.OrderData memory od) =
            _baseJob(10e18, 5e18);
        vm.warp(100);
        j.deadline = 50;
        j.fundingSig = _signJob(j, subaccountPk, od);
        vm.expectRevert(abi.encodeWithSelector(SignatureExpired.selector, uint256(50)));
        _call(j);
    }

    /// @notice A-5: replay attack - same sig used twice reverts on second use (InvalidNonce).
    function test_A5_replayConsumesNonce() public {
        (EvcRolloverAdapter.EvcRolloverJob memory j, RolloverTypes.OrderData memory od) =
            _baseJob(10e18, 5e18);
        j.fundingSig = _signJob(j, subaccountPk, od);
        _call(j);
        vm.expectRevert(InvalidNonce.selector);
        _call(j);
    }

    /// @notice A-6: happy path moves exactly `fillerSrcCst` + `premium`; no
    ///         adapter-side allowance lingers.
    function test_A6_happyPathMovesExactAmountsZeroAllowance() public {
        uint256 fillerSrc = 10e18;
        uint256 premiumAmt = 5e18;
        (EvcRolloverAdapter.EvcRolloverJob memory j, RolloverTypes.OrderData memory od) =
            _baseJob(fillerSrc, premiumAmt);
        j.fundingSig = _signJob(j, subaccountPk, od);

        uint256 subSrcPre = srcCst.balanceOf(subaccount);
        uint256 subPremPre = premiumToken.balanceOf(subaccount);

        _call(j);

        // Adapter refunds any unused tail; CountingSettler does not move tokens, so
        // the entire pulled amount is refunded.
        assertEq(
            srcCst.balanceOf(subaccount),
            subSrcPre,
            "A-6: srcCst tail refunded - net delta zero against CountingSettler"
        );
        assertEq(
            premiumToken.balanceOf(subaccount),
            subPremPre,
            "A-6: premium tail refunded - net delta zero against CountingSettler"
        );
        // Zero standing allowance on the adapter (INV-ADAPTER-NO-STANDING-ALLOWANCE).
        assertEq(srcCst.allowance(subaccount, address(adapter)), 0);
        assertEq(premiumToken.allowance(subaccount, address(adapter)), 0);
    }

    /// @notice A-7: same property as A-6 for executePartial.
    function test_A7_happyPathPartialMovesExactAmounts() public {
        uint256 fillerSrc = 10e18;
        uint256 premiumAmt = 5e18;
        (EvcRolloverAdapter.EvcRolloverJob memory j, RolloverTypes.OrderData memory od) =
            _baseJob(fillerSrc, premiumAmt);
        od = _usePartialSettler(od);
        od.settler = address(partialCount);
        od.rolloverParams.settler = address(partialCount);
        j.order = _gasless(od);
        j.settler = ISettler(address(partialCount));
        j.fundingSig = _signJob(j, subaccountPk, od);

        uint256 subSrcPre = srcCst.balanceOf(subaccount);
        _callPartial(j);
        assertEq(srcCst.balanceOf(subaccount), subSrcPre);
        assertEq(srcCst.allowance(subaccount, address(adapter)), 0);
    }

    /// @notice A-8: witness mismatch - sig for params X used with params Y reverts.
    function testRevert_A8_witnessMismatch() public {
        (EvcRolloverAdapter.EvcRolloverJob memory j, RolloverTypes.OrderData memory od) =
            _baseJob(10e18, 5e18);
        j.fundingSig = _signJob(j, subaccountPk, od);
        // Mutate minDstPerSrc after sign: witness no longer matches.
        j.minDstPerSrc = 999;
        vm.expectRevert(PermitVerifyErrors.InvalidSigner.selector);
        _call(j);
    }

    /// @notice A-9: operator-replay - sig for jobA used by an operator firing jobB.
    function testRevert_A9_operatorReplay() public {
        (EvcRolloverAdapter.EvcRolloverJob memory jobA, RolloverTypes.OrderData memory odA) =
            _baseJob(10e18, 5e18);
        jobA.fundingSig = _signJob(jobA, subaccountPk, odA);

        // Job B has a different fillerSrcCst; reuse jobA's signature.
        (EvcRolloverAdapter.EvcRolloverJob memory jobB,) = _baseJob(20e18, 5e18);
        jobB.fundingSig = jobA.fundingSig;
        vm.expectRevert(PermitVerifyErrors.InvalidSigner.selector);
        _call(jobB);
    }

    /// @notice A-10: stateful EIP-1271 priming attack - even if a contract subaccount
    ///         mutates its 1271 state mid-fill, witness-bound sig still rejects because
    ///         the signed bytes carry the original params.
    function testRevert_A10_stateful1271WitnessStillRejects() public {
        StatefulMock1271 contractSub = new StatefulMock1271();
        evcMock.setAccountOwner(address(contractSub), address(contractSub));
        evcMock.setFrame(address(contractSub), true, CONTROLLER);

        srcCst.mint(address(contractSub), 1_000e18);
        premiumToken.mint(address(contractSub), 1_000e18);
        vm.startPrank(address(contractSub));
        srcCst.approve(address(permit2), type(uint256).max);
        premiumToken.approve(address(permit2), type(uint256).max);
        vm.stopPrank();

        (EvcRolloverAdapter.EvcRolloverJob memory j, RolloverTypes.OrderData memory od) =
            _baseJob(10e18, 5e18);
        j.subaccount = address(contractSub);
        j.fundingAccount = address(contractSub);
        // Sign with a random key (irrelevant: 1271 path).
        (, uint256 randPk) = makeAddrAndKey("rand");
        j.fundingSig = _signJob(j, randPk, od);
        // Prime 1271 to accept the (originalDigest, originalSigPrefix) pair so the
        // attacker has staged a "valid" signature against the unmutated witness.
        bytes32 originalWitness = _computeJobWitness(j, address(settler), od);
        bytes32 originalDigest = _permit2BatchWitnessDigest(j, address(adapter), originalWitness);
        contractSub.setExpected(originalDigest, bytes32(j.fundingSig));
        // Mutate witness after sign — the new digest will not match `expectedHash`,
        // so 1271 returns 0xffffffff and Permit2 raises InvalidContractSignature.
        j.minDstPerSrc = 7;
        vm.expectRevert(PermitVerifyErrors.InvalidContractSignature.selector);
        bytes memory data = abi.encodeCall(EvcRolloverAdapter.execute, (j));
        evcMock.proxy(address(contractSub), CONTROLLER, address(adapter), data);
    }

    /// @notice A-11: EOA-owned subaccount via XOR-derived sub (Permit2 signer = primary EOA).
    function test_A11_xorDerivedSubaccount() public {
        (address primary, uint256 primaryPk) = makeAddrAndKey("xor-primary");
        address xorSub = address(uint160(primary) ^ uint160(1));
        evcMock.setAccountOwner(xorSub, primary);
        evcMock.setFrame(xorSub, true, CONTROLLER);

        srcCst.mint(primary, 1_000e18);
        premiumToken.mint(primary, 1_000e18);
        vm.startPrank(primary);
        srcCst.approve(address(permit2), type(uint256).max);
        premiumToken.approve(address(permit2), type(uint256).max);
        vm.stopPrank();

        (EvcRolloverAdapter.EvcRolloverJob memory j, RolloverTypes.OrderData memory od) =
            _baseJob(10e18, 5e18);
        j.subaccount = xorSub;
        j.fundingAccount = primary;
        j.fundingSig = _signJob(j, primaryPk, od);

        bytes memory data = abi.encodeCall(EvcRolloverAdapter.execute, (j));
        evcMock.proxy(xorSub, CONTROLLER, address(adapter), data);
        // No revert - Permit2 signer = primary EOA via getAccountOwner.
    }

    /// @notice A-12: contract-owned subaccount via EIP-1271 - minimal mock returns
    ///         the magic value for the exact prepared signature.
    function test_A12_contract1271Subaccount() public {
        StatefulMock1271 ownerContract = new StatefulMock1271();
        address sub = makeAddr("contract-sub-1271");
        evcMock.setAccountOwner(sub, address(ownerContract));
        evcMock.setFrame(sub, true, CONTROLLER);

        // Permit2 pulls from the resolved owner (the 1271 contract), so the
        // contract holds tokens + approval.
        srcCst.mint(address(ownerContract), 1_000e18);
        premiumToken.mint(address(ownerContract), 1_000e18);
        vm.startPrank(address(ownerContract));
        srcCst.approve(address(permit2), type(uint256).max);
        premiumToken.approve(address(permit2), type(uint256).max);
        vm.stopPrank();

        (EvcRolloverAdapter.EvcRolloverJob memory j, RolloverTypes.OrderData memory od) =
            _baseJob(10e18, 5e18);
        j.subaccount = sub;
        j.fundingAccount = address(ownerContract);
        // Sign with a placeholder key - actual verification routes via 1271.
        (, uint256 pk) = makeAddrAndKey("placeholder");
        j.fundingSig = _signJob(j, pk, od);
        // Prime 1271 to accept the (digest, sigPrefix) tuple our job will present.
        bytes32 witness = _computeJobWitness(j, address(settler), od);
        bytes32 digest = _permit2BatchWitnessDigest(j, address(adapter), witness);
        ownerContract.setExpected(digest, bytes32(j.fundingSig));

        bytes memory data = abi.encodeCall(EvcRolloverAdapter.execute, (j));
        evcMock.proxy(sub, CONTROLLER, address(adapter), data);
        // No revert - 1271 path approves; adapter completes funding pull.
    }

    /// @notice A-13: subaccount with no registered EVC owner reverts with
    ///         `__SubaccountAuthorityMissing` (MockEVC `getAccountOwner` reverts).
    function testRevert_A13_subaccountAuthorityMissing() public {
        address orphan = makeAddr("orphan-no-owner");
        evcMock.setFrame(orphan, true, CONTROLLER);
        // No setAccountOwner - getAccountOwner will revert.
        (EvcRolloverAdapter.EvcRolloverJob memory j, RolloverTypes.OrderData memory od) =
            _baseJob(10e18, 5e18);
        j.subaccount = orphan;
        // fundingSig non-empty to pass the first check.
        j.fundingSig = _signJob(j, subaccountPk, od);

        bytes memory data = abi.encodeCall(EvcRolloverAdapter.execute, (j));
        vm.expectRevert(EvcRolloverAdapter__SubaccountAuthorityMissing.selector);
        evcMock.proxy(orphan, CONTROLLER, address(adapter), data);
    }

    /// @notice A-14: fundingAccount is explicit and must match the EVC owner.
    function testRevert_A14_fundingAccountMustMatchEvcOwner() public {
        (address impostor, uint256 impostorPk) = makeAddrAndKey("funding-impostor");
        (EvcRolloverAdapter.EvcRolloverJob memory j, RolloverTypes.OrderData memory od) =
            _baseJob(10e18, 5e18);
        j.fundingAccount = impostor;
        j.fundingSig = _signJob(j, impostorPk, od);

        bytes memory data = abi.encodeCall(EvcRolloverAdapter.execute, (j));
        vm.expectRevert(
            abi.encodeWithSelector(
                EvcRolloverAdapter__FundingAccountMismatch.selector, subaccount, impostor
            )
        );
        evcMock.proxy(subaccount, CONTROLLER, address(adapter), data);
    }

    /// @notice A-15: a registered zero owner trips the adapter's defensive zero-signer guard.
    function testRevert_A15_zeroRegisteredOwner() public {
        address zeroOwnerSubaccount = makeAddr("zero-owner-subaccount");
        evcMock.setFrame(zeroOwnerSubaccount, true, CONTROLLER);
        evcMock.setAccountOwner(zeroOwnerSubaccount, address(0));

        (EvcRolloverAdapter.EvcRolloverJob memory j, RolloverTypes.OrderData memory od) =
            _baseJob(10e18, 5e18);
        j.subaccount = zeroOwnerSubaccount;
        j.fundingSig = _signJob(j, subaccountPk, od);

        bytes memory data = abi.encodeCall(EvcRolloverAdapter.execute, (j));
        vm.expectRevert(EvcRolloverAdapter__SubaccountAuthorityMissing.selector);
        evcMock.proxy(zeroOwnerSubaccount, CONTROLLER, address(adapter), data);
    }
}
