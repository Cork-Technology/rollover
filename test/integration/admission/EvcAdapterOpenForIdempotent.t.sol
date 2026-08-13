// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { CountingSettler } from "../../mocks/CountingSettler.sol";
import { MockEVC } from "../../mocks/MockEVC.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { EvcRolloverAdapter, IEVC } from "src/EvcRolloverAdapter.sol";
import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import { ISettler } from "src/interfaces/settlers/ISettler.sol";
import { LibSettlerHashing } from "src/libraries/LibSettlerHashing.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

import { ISignatureTransfer } from "permit2/interfaces/ISignatureTransfer.sol";

/// @notice Pins INV-OPENED-ORDERS-FILLABLE-UNTIL-FILLDEADLINE (EvcRolloverAdapter
///         helper half): the adapter computes orderId locally via
///         `LibSettlerHashing.computeOrderDigestMemory` (no `resolve` call) and
///         skips `openFor` when the cached status is `Opened`.
contract EvcAdapterOpenForIdempotentTest is BaseTest {
    /// @notice Controller address wired into the adapter under test.
    address internal constant CONTROLLER = address(0xC0F1E);

    /// @notice Shared faithful EVC mock fronting the adapter.
    MockEVC internal evcMock;
    /// @notice CountingSettler bound to the adapter's exact-mode slot.
    CountingSettler internal exactCount;
    /// @notice CountingSettler bound to the adapter's partial-mode slot.
    CountingSettler internal partialCount;
    /// @notice Adapter under test.
    EvcRolloverAdapter internal adapter;

    /// @notice EVC subaccount receiving test fills and refunds.
    address internal subaccount;
    /// @notice Private key for the funding account EOA — signs Permit2 witness.
    uint256 internal subaccountPk;
    /// @notice Owner-of-record used only as arbitrary trailing calldata bytes.
    address internal subaccountOwner;

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

        (subaccount, subaccountPk) = makeAddrAndKey("subaccount");
        subaccountOwner = makeAddr("subaccountOwner");
        evcMock.setAccountOwner(subaccount, subaccount);
        evcMock.setFrame(subaccount, true, CONTROLLER);

        vm.startPrank(subaccount);
        srcCst.approve(address(permit2), type(uint256).max);
        premiumToken.approve(address(permit2), type(uint256).max);
        vm.stopPrank();
    }

    function _job() internal view returns (EvcRolloverAdapter.EvcRolloverJob memory j) {
        RolloverTypes.OrderData memory orderData = _baseOrder();
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
            fillerSrcCst: 0,
            minDstPerSrc: 0,
            intent: intent,
            premium: 0,
            fillerAuthSig: "",
            nonce: uint256(keccak256(abi.encode("EvcAdapterOpenForIdempotent", block.timestamp))),
            deadline: block.timestamp + 1 hours,
            fundingSig: ""
        });
        // CountingSettler's DOMAIN_SEPARATOR mirrors the real ExactSettler's, so
        // we pass `address(settler)` to make BaseTest's helper compute the same
        // domain separator the adapter will use at runtime.
        j.fundingSig = _signPermit2WitnessForJob(
            j, subaccountPk, address(adapter), address(settler), orderData
        );
    }

    function _orderDigestOf(EvcRolloverAdapter.EvcRolloverJob memory j)
        internal
        view
        returns (bytes32)
    {
        RolloverTypes.OrderData memory od = abi.decode(j.order.orderData, (RolloverTypes.OrderData));
        return LibSettlerHashing.computeOrderDigestMemory(od, exactCount.DOMAIN_SEPARATOR());
    }

    /// @dev Drive execute through the shared MockEVC with unchanged calldata.
    function _callExecute(EvcRolloverAdapter.EvcRolloverJob memory j) internal {
        bytes memory data = abi.encodeCall(EvcRolloverAdapter.execute, (j));
        evcMock.proxy(subaccount, CONTROLLER, address(adapter), data);
    }

    /// @notice adapter computes orderId locally; the digest passed to atomic `fill` MUST
    ///         match the locally-computed digest, NOT the `0xDEADBEEF` sentinel
    ///         returned by the mock `resolve`.
    function test_runSettlementCommon_uses_localDigest_not_resolveReturn() public {
        EvcRolloverAdapter.EvcRolloverJob memory j = _job();
        bytes32 localDigest = _orderDigestOf(j);
        _callExecute(j);
        assertEq(exactCount.lastFillOrderId(), localDigest, "fill must use local digest");
        assertTrue(
            exactCount.lastFillOrderId() != bytes32(uint256(0xDEADBEEF)),
            "fill must not use resolve sentinel"
        );
    }

    /// @notice when status == None, adapter calls `openFor` exactly once.
    function test_runSettlementCommon_callsOpenFor_when_status_is_None() public {
        EvcRolloverAdapter.EvcRolloverJob memory j = _job();
        _callExecute(j);
        assertEq(exactCount.openForCalls(), 1, "openFor called once on None");
    }

    /// @notice when status == Opened, adapter MUST skip `openFor`.
    function test_runSettlementCommon_skipsOpenFor_when_status_is_Opened() public {
        EvcRolloverAdapter.EvcRolloverJob memory j = _job();
        bytes32 orderId = _orderDigestOf(j);
        exactCount.setStatus(orderId, uint8(RolloverTypes.OrderStatus.Opened));

        _callExecute(j);
        assertEq(exactCount.openForCalls(), 0, "openFor must be skipped on Opened");
    }

    /// @notice Real EVC forwards calldata unchanged; adapter ignores caller-supplied trailing bytes.
    function test_execute_ignoresCallerSuppliedCalldataSuffix_notEvcAuthTail() public {
        EvcRolloverAdapter.EvcRolloverJob memory j = _job();
        bytes32 localDigest = _orderDigestOf(j);
        bytes memory data = abi.encodeCall(EvcRolloverAdapter.execute, (j));
        // Extra trailing bytes are caller-supplied payload, not EVC-appended auth data.
        bytes memory payloadWithSuffix = abi.encodePacked(data, subaccountOwner);
        evcMock.proxy(subaccount, CONTROLLER, address(adapter), payloadWithSuffix);
        assertEq(
            exactCount.lastFillOrderId(),
            localDigest,
            "fill uses local digest; suffix is not consulted for auth"
        );
        assertEq(exactCount.openForCalls(), 1, "openFor still invoked once on None");
    }
}
