// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { MockEVC } from "../../mocks/MockEVC.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { EvcRolloverAdapter, IEVC } from "src/EvcRolloverAdapter.sol";
import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import { ISettler } from "src/interfaces/settlers/ISettler.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

import { ISignatureTransfer } from "permit2/interfaces/ISignatureTransfer.sol";
import {
    EvcRolloverAdapter__CallerNotEvc,
    EvcRolloverAdapter__ControllerNotEnabled,
    EvcRolloverAdapter__FundingSigInvalid,
    EvcRolloverAdapter__OnBehalfMismatch
} from "src/errors/EvcRolloverAdapterErrors.sol";

/// @notice MockSettlerAuthz — minimal Settler stub that lets tests reach `_gateEvc`
///         while keeping the rest of the rollover settlement loop a no-op. The auth
///         gate fires before any settlement work, so revert-shape tests need only
///         a Settler that wouldn't itself revert if reached.
contract MockSettlerAuthz {
    /// @notice Premium token (recorded for surface parity; unused in auth-gate tests).
    address public premiumToken;
    /// @notice Sink address (recorded for surface parity; unused in auth-gate tests).
    address public sink;

    /// @notice Configurable dstProduced value the mock reports to the adapter.
    uint256 public produced;

    /// @notice Configure the premium-pull surface (sink + premium token).
    /// @param token_ Premium token address.
    /// @param partial_ Partial-premium amount (ignored by the mock).
    /// @param sink_ Sink address.
    // forge-lint: disable-next-line(missing-zero-check)
    function configurePartialPull(address token_, uint256 partial_, address sink_) external {
        partial_;
        premiumToken = token_;
        sink = sink_;
    }

    /// @notice Set the dstProduced value reported via `fillerDstProducedOf`.
    /// @param produced_ Configured dstProduced amount.
    function setProduced(uint256 produced_) external {
        produced = produced_;
    }

    /// @notice EIP-712 domain separator (stub).
    /// @return Stub domain separator (zero).
    // forge-lint: disable-next-line(mixed-case-function)
    function DOMAIN_SEPARATOR() external pure returns (bytes32) {
        return bytes32(0);
    }

    /// @notice Stub orderStatus consumed by the adapter's conditional-openFor guard.
    /// @param orderId Canonical order id (ignored).
    /// @return Returns the `None` status so the adapter always invokes `openFor`.
    function orderStatus(bytes32 orderId) external pure returns (uint8) {
        orderId;
        return 0;
    }

    /// @notice Report the configured dstProduced amount.
    /// @param orderId Canonical order id (ignored).
    /// @param filler Filler address (ignored).
    /// @return Configured dstProduced value.
    function fillerDstProducedOf(bytes32 orderId, address filler) external view returns (uint256) {
        orderId;
        filler;
        return produced;
    }

    /// @notice 3-arg overload — subFiller dimension (ignored, returns `produced`).
    /// @param orderId Canonical order id (ignored).
    /// @param filler Filler address (ignored).
    /// @param subFiller Sub-filler identity (ignored).
    /// @return Configured dstProduced value.
    function fillerDstProducedOf(bytes32 orderId, address filler, bytes32 subFiller)
        external
        view
        returns (uint256)
    {
        orderId;
        filler;
        subFiller;
        return produced;
    }

    /// @notice ERC-7683 openFor stub (no-op).
    /// @param order ERC-7683 order envelope (ignored).
    /// @param userSig cPT-holder signature (ignored).
    /// @param originFillerData Origin-side filler data (ignored).
    function openFor(
        ERC7683Types.GaslessCrossChainOrder calldata order,
        bytes calldata userSig,
        bytes calldata originFillerData
    ) external pure {
        order;
        userSig;
        originFillerData;
    }

    /// @notice ERC-7683 resolveFor stub returning a fixed orderId.
    /// @param order ERC-7683 order envelope (ignored).
    /// @param originFillerData Origin-side filler data (ignored).
    /// @return r Resolved order with a fixed `orderId`.
    function resolveFor(
        ERC7683Types.GaslessCrossChainOrder calldata order,
        bytes calldata originFillerData
    ) external pure returns (ERC7683Types.ResolvedCrossChainOrder memory r) {
        order;
        originFillerData;
        r.orderId = bytes32(uint256(0xCAFEC0DE));
    }

    /// @notice ERC-7683 fill stub (no-op).
    /// @param orderId Canonical order id (ignored).
    /// @param originData Origin-side data (ignored).
    /// @param fillerData Filler-side data (ignored).
    function fill(bytes32 orderId, bytes calldata originData, bytes calldata fillerData)
        external
        pure
    {
        orderId;
        originData;
        fillerData;
    }
}

/// @notice EvcCallerAuthzTest — pins INV-EVC-CALLER-AUTHORIZED against the faithful EVC model.
contract EvcCallerAuthzTest is BaseTest {
    /// @notice Controller address wired into the adapter under test.
    address internal constant CONTROLLER = address(0xC011704);

    /// @notice Mock EVC instance the adapter is bound to.
    MockEVC internal evcMock;
    /// @notice Mock Settler exercised by adapter dispatches.
    MockSettlerAuthz internal mockSettler;
    /// @notice Adapter under test.
    EvcRolloverAdapter internal adapter;

    /// @notice EVC subaccount whose approvals the adapter consumes.
    address internal subaccount;
    /// @notice Owner-of-record for `subaccount`.
    address internal owner;
    /// @notice Address present in an open EVC frame but not authorized for `subaccount`.
    address internal unauthorizedThirdParty;

    /// @notice Test fixture setup.
    function setUp() public override {
        super.setUp();
        evcMock = new MockEVC();
        mockSettler = new MockSettlerAuthz();
        adapter = new EvcRolloverAdapter(
            IEVC(address(evcMock)),
            CONTROLLER,
            ISettler(address(mockSettler)),
            ISettler(address(mockSettler)),
            ISignatureTransfer(address(permit2))
        );

        subaccount = makeAddr("evcSubaccount");
        owner = makeAddr("subaccountOwner");
        unauthorizedThirdParty = makeAddr("unauthorizedThirdParty");

        evcMock.setFrame(subaccount, true, CONTROLLER);

        srcCst.mint(subaccount, 1e18);
        premiumToken.mint(subaccount, 1e18);
        // These gate-revert tests do not exercise the Permit2 funding path —
        // every assertion targets `_gateEvc` (INV-EVC-CALLER-AUTHORIZED) which
        // fires before any token movement. No allowance to the adapter or
        // Permit2 is required.
    }

    function _job(bool isPartial)
        internal
        view
        returns (EvcRolloverAdapter.EvcRolloverJob memory j)
    {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        if (isPartial) {
            orderData = _usePartialSettler(orderData);
        } else {
            orderData.allowPartialFills = false;
        }
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);

        RolloverTypes.RolloverIntent memory intent;
        bytes memory empty;
        j = EvcRolloverAdapter.EvcRolloverJob({
            settler: ISettler(address(mockSettler)),
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
            nonce: 0,
            deadline: 0,
            fundingSig: ""
        });
    }

    /// @notice Direct call to adapter (no EVC proxy) reverts CallerNotEvc.
    function test_GateEvc_RevertsWhenCallerNotEvc() public {
        EvcRolloverAdapter.EvcRolloverJob memory j = _job(false);
        vm.expectRevert(EvcRolloverAdapter__CallerNotEvc.selector);
        vm.prank(unauthorizedThirdParty);
        adapter.execute(j);
    }

    /// @notice On-behalf mismatch between EVC frame and job subaccount reverts.
    function test_GateEvc_RevertsWhenOnBehalfMismatch() public {
        address subA = makeAddr("subA");
        bytes memory data = abi.encodeCall(EvcRolloverAdapter.execute, (_job(false)));
        vm.expectRevert(
            abi.encodeWithSelector(EvcRolloverAdapter__OnBehalfMismatch.selector, subA, subaccount)
        );
        evcMock.proxy(subA, CONTROLLER, address(adapter), data);
    }

    /// @notice Disabled controller frame reverts ControllerNotEnabled.
    function test_GateEvc_RevertsWhenControllerNotEnabled() public {
        EvcRolloverAdapter.EvcRolloverJob memory j = _job(false);
        evcMock.setFrame(subaccount, false, CONTROLLER);
        vm.prank(address(evcMock));
        vm.expectRevert(EvcRolloverAdapter__ControllerNotEnabled.selector);
        adapter.execute(j);
    }

    /// @notice Empty on-behalf frame reverts at the mock's faithful
    ///         `EVC_OnBehalfOfAccountNotAuthenticated`. The canonical Euler EVC reverts
    ///         internally with the same selector before the adapter's defensive
    ///         `onBehalf == address(0)` branch can execute; that branch is therefore
    ///         unreachable in production.
    function test_GateEvc_RevertsWhenNoEvcContext() public {
        bytes memory data = abi.encodeCall(EvcRolloverAdapter.execute, (_job(false)));
        vm.expectRevert(MockEVC.EVC_OnBehalfOfAccountNotAuthenticated.selector);
        evcMock.proxy(address(0), CONTROLLER, address(adapter), data);
    }

    /// @notice Valid EVC frame allows owner-driven execute through the gate.
    /// @dev Post-Permit2 migration: the gate passes successfully, then the
    ///      funding pull reverts because `_job(false)` ships an empty
    ///      `fundingSig`. The gate-pass property under test is satisfied by
    ///      observing the downstream funding-sig revert (the gate did not
    ///      block the call).
    function test_GateEvc_SucceedsForValidEvcFrame() public {
        bytes memory data = abi.encodeCall(EvcRolloverAdapter.execute, (_job(false)));
        vm.prank(owner);
        vm.expectRevert(EvcRolloverAdapter__FundingSigInvalid.selector);
        evcMock.proxy(subaccount, CONTROLLER, address(adapter), data);
    }

    /// @notice Trailing calldata suffix bytes are not consulted for authorization.
    ///         The adapter ignores the suffix and the
    ///         gate passes (funding revert downstream confirms gate-pass).
    function test_GateEvc_CalldataSuffixCannotBypass() public {
        bytes memory data = abi.encodeCall(EvcRolloverAdapter.execute, (_job(false)));
        bytes memory payload = abi.encodePacked(data, owner);
        vm.prank(unauthorizedThirdParty);
        vm.expectRevert(EvcRolloverAdapter__FundingSigInvalid.selector);
        evcMock.proxy(subaccount, CONTROLLER, address(adapter), payload);
    }
}
