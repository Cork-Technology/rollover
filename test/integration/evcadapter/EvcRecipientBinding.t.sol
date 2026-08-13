// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { CountingSettler } from "../../mocks/CountingSettler.sol";
import { MockEVC } from "../../mocks/MockEVC.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ISignatureTransfer } from "permit2/interfaces/ISignatureTransfer.sol";
import { EvcRolloverAdapter, IEVC } from "src/EvcRolloverAdapter.sol";
import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import { ISettler } from "src/interfaces/settlers/ISettler.sol";
import { LibFillerAuth } from "src/libraries/LibFillerAuth.sol";
import { LibFillerPayload } from "src/libraries/LibFillerPayload.sol";
import { FillerPayload } from "src/types/FillerTypes.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice C-01 — explicit `recipient` binds settlement outputs and tail refunds.
contract EvcRecipientBindingTest is BaseTest {
    /// @notice Controller address enabled by the EVC mock frame.
    address internal constant CONTROLLER = address(0xC0F1E);

    /// @notice EVC mock used to dispatch adapter calls under an on-behalf-of frame.
    MockEVC internal evcMock;

    /// @notice Settler mock that records the rollover destination passed through filler data.
    CountingSettler internal exactCount;

    /// @notice Adapter under test.
    EvcRolloverAdapter internal adapter;

    /// @notice Permit2 funding signer and token owner.
    address internal fundingAccount;

    /// @notice Private key for `fundingAccount`.
    uint256 internal fundingPk;

    /// @notice EVC subaccount used as the authenticated execution subject.
    address internal subaccount;

    /// @notice Explicit recipient for settlement output and tail refunds.
    address internal recipient;

    /// @notice Deploy the adapter fixture and fund the Permit2 funding account.
    function setUp() public override {
        super.setUp();
        bytes32 domainSep = settler.DOMAIN_SEPARATOR();
        evcMock = new MockEVC();
        exactCount = new CountingSettler(domainSep);
        adapter = new EvcRolloverAdapter(
            IEVC(address(evcMock)),
            CONTROLLER,
            ISettler(address(exactCount)),
            ISettler(address(partialSettler)),
            ISignatureTransfer(address(permit2))
        );

        (fundingAccount, fundingPk) = makeAddrAndKey("funding");
        subaccount = makeAddr("evc-subaccount");
        recipient = makeAddr("tailRecipient");
        evcMock.setAccountOwner(subaccount, fundingAccount);
        evcMock.setFrame(subaccount, true, CONTROLLER);

        vm.startPrank(fundingAccount);
        srcCst.approve(address(permit2), type(uint256).max);
        premiumToken.approve(address(permit2), type(uint256).max);
        vm.stopPrank();
        srcCst.mint(fundingAccount, 1_000_000e18);
        premiumToken.mint(fundingAccount, 1_000_000e18);
    }

    function _job(uint256 srcAmt, uint256 premiumAmt)
        internal
        view
        returns (EvcRolloverAdapter.EvcRolloverJob memory j, RolloverTypes.OrderData memory od)
    {
        od = _baseOrder();
        od.settler = address(exactCount);
        od.rolloverParams.settler = address(exactCount);
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(od);
        j = EvcRolloverAdapter.EvcRolloverJob({
            settler: ISettler(address(exactCount)),
            order: g,
            userSig: "",
            subaccount: subaccount,
            fundingAccount: fundingAccount,
            recipient: recipient,
            srcCst: IERC20(address(srcCst)),
            premiumToken: IERC20(address(premiumToken)),
            fillerSrcCst: srcAmt,
            minDstPerSrc: 0,
            intent: RolloverTypes.RolloverIntent({
                rolloverContract: address(0),
                orderDigest: bytes32(0),
                deadline: 0,
                nonce: 0,
                preRolloverHooks: new RolloverTypes.Call[](0),
                midRolloverHooks: new RolloverTypes.Call[](0),
                postRolloverHooks: new RolloverTypes.Call[](0),
                premiumHooks: new RolloverTypes.Call[](0)
            }),
            premium: premiumAmt,
            fillerAuthSig: "",
            nonce: uint256(keccak256("c01-nonce")),
            deadline: block.timestamp + 1 hours,
            fundingSig: ""
        });
    }

    function _execute(EvcRolloverAdapter.EvcRolloverJob memory j) internal {
        bytes memory data = abi.encodeCall(EvcRolloverAdapter.execute, (j));
        evcMock.proxy(subaccount, CONTROLLER, address(adapter), data);
    }

    /// @notice dstCST settlement and premium tail refunds route to `recipient`, not bare subaccount.
    function test_rolloverLegBindsRecipientAsDestination() public view {
        (EvcRolloverAdapter.EvcRolloverJob memory j,) = _job(10e18, 0);
        bytes32 subFiller = bytes32(uint256(uint160(j.subaccount)));
        bytes memory rolloverData = LibFillerPayload.encodeRolloverLeg(
            j.fillerSrcCst, j.recipient, j.intent, j.minDstPerSrc, j.fillerAuthSig, subFiller, ""
        );
        FillerPayload memory payload = LibFillerAuth.decodePayloadMemory(rolloverData);
        assertEq(payload.destination, recipient, "destination");
        assertTrue(recipient != subaccount, "recipient distinct from subaccount");
    }

    /// @notice Adapter tail refunds and rollover destination bind to `recipient`, not subaccount.
    function test_execute_routesTailsAndDestinationToRecipient() public {
        (EvcRolloverAdapter.EvcRolloverJob memory j, RolloverTypes.OrderData memory od) =
            _job(10e18, 5e18);

        assertTrue(j.recipient != j.subaccount, "recipient distinct from subaccount");

        j.fundingSig = _signPermit2WitnessForJobWithSep(
            j, fundingPk, address(adapter), exactCount.DOMAIN_SEPARATOR(), od
        );

        uint256 recipientSrcBefore = srcCst.balanceOf(j.recipient);
        uint256 recipientPremiumBefore = premiumToken.balanceOf(j.recipient);
        uint256 subSrcBefore = srcCst.balanceOf(j.subaccount);
        uint256 subPremiumBefore = premiumToken.balanceOf(j.subaccount);

        _execute(j);

        assertEq(srcCst.balanceOf(j.recipient), recipientSrcBefore + j.fillerSrcCst, "srcCst tail");
        assertEq(
            premiumToken.balanceOf(j.recipient), recipientPremiumBefore + j.premium, "premium tail"
        );
        assertEq(srcCst.balanceOf(j.subaccount), subSrcBefore, "subaccount srcCst");
        assertEq(premiumToken.balanceOf(j.subaccount), subPremiumBefore, "subaccount premium");
        assertEq(exactCount.lastRolloverDestination(), j.recipient, "rollover destination");
    }

    /// @notice Witness mismatch when recipient is tampered after signing reverts.
    function testRevert_witnessMismatchOnRecipientTamper() public {
        (EvcRolloverAdapter.EvcRolloverJob memory j, RolloverTypes.OrderData memory od) =
            _job(10e18, 5e18);
        j.fundingSig = _signPermit2WitnessForJobWithSep(
            j, fundingPk, address(adapter), exactCount.DOMAIN_SEPARATOR(), od
        );
        j.recipient = makeAddr("other-recipient");
        vm.expectRevert();
        _execute(j);
    }
}
