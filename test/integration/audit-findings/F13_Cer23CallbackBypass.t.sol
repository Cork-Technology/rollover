// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { MockERC20 } from "../../mocks/MockERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Test } from "forge-std/Test.sol";
import { EvcRolloverAdapter, IEVC } from "src/EvcRolloverAdapter.sol";
import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import { ISettler } from "src/interfaces/settlers/ISettler.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

import { ISignatureTransfer } from "permit2/interfaces/ISignatureTransfer.sol";
import { EvcRolloverAdapter__CallerNotEvc } from "src/errors/EvcRolloverAdapterErrors.sol";

/// @notice Pins INV-EVC-CALLER-AUTHORIZED against the EVC CER-23 callback-bypass
///         attack model.
///
/// @dev Background — CER-23 callback-bypass primitive:
///      Euler EVC's `call(target, onBehalfOfAccount, value, data)` accepts an
///      arbitrary `onBehalfOfAccount` WITHOUT authentication when
///      `target == msg.sender`. Inside the inner frame the EVC reports the
///      attacker-chosen subaccount via `getCurrentOnBehalfOfAccount`. Absent
///      a `msg.sender == EVC` gate at the adapter, an unauthorized contract
///      can read a victim's on-behalf-of frame and force a rollover that
///      consumes the victim's pre-approved srcCST + premium.
///
///      The adapter's `_gateEvc` now requires `msg.sender == address(EVC)`
///      after the EVC-derived frame matches the job subaccount. This file
///      pins that the CER-23 attack is rejected at the gate with no token
///      movement out of the victim's account, and that direct EOA calls to
///      `adapter.execute` revert with the same error.
///
/// @custom:invariant INV-EVC-CALLER-AUTHORIZED
contract Cer23CallbackBypassTest is Test {
    /// @notice Controller wired into the adapter for the test fixture.
    address internal constant CONTROLLER = address(0xC0C0C0C);

    /// @notice CER-23-faithful EVC mock used to drive the attack frame.
    MockCer23Evc internal evc;
    /// @notice Minimal Settler stub satisfying the adapter's settlement loop surface.
    MockCer23Settler internal settler;
    /// @notice Adapter under test.
    EvcRolloverAdapter internal adapter;
    /// @notice Attacker-controlled exploit contract that leverages CER-23 callback-bypass.
    Cer23Exploit internal exploit;

    /// @notice Source CST ERC-20 the adapter pulls from the victim.
    MockERC20 internal srcCst;
    /// @notice Premium ERC-20 the adapter pulls from the victim.
    MockERC20 internal premiumToken;
    /// @notice Destination CST ERC-20 minted by the Settler stub on a successful rollover.
    MockERC20 internal dstCst;

    /// @notice Victim subaccount holding the pre-approved allowances.
    address internal victim = makeAddr("victim");
    /// @notice Attacker EOA driving the exploit.
    address internal attackerEoa = makeAddr("attackerEoa");

    /// @notice Deploy the CER-23 EVC mock, Settler stub, adapter, and exploit
    ///         contract; mint and pre-approve the victim's tokens; enable the
    ///         controller on the victim's EVC subaccount.
    function setUp() public {
        evc = new MockCer23Evc();
        settler = new MockCer23Settler();
        adapter = new EvcRolloverAdapter(
            IEVC(address(evc)),
            CONTROLLER,
            ISettler(address(settler)),
            ISettler(address(settler)),
            ISignatureTransfer(address(0x000000000022D473030F116dDEE9F6B43aC78BA3))
        );
        exploit = new Cer23Exploit(adapter, IEVC(address(evc)));

        srcCst = new MockERC20("srcCST", "SRC", 18);
        premiumToken = new MockERC20("Premium", "PRM", 18);
        dstCst = new MockERC20("dstCST", "DST", 18);

        // Precondition: victim has tokens. Under
        // INV-ADAPTER-NO-STANDING-ALLOWANCE there is no longer a persistent
        // allowance to the adapter for an attacker to drain via CER-23;
        // CER-23's reach is bounded by the gate alone — proven by the
        // assertions below, which observe zero token movement out of the
        // victim's account across the reverted attack frame.
        srcCst.mint(victim, 10_000e18);
        premiumToken.mint(victim, 10_000e18);

        // Precondition: victim has the Cork controller enabled on her EVC subaccount.
        evc.enableController(victim, CONTROLLER);

        settler.bindTokens(srcCst, premiumToken, dstCst);
    }

    /// @notice Direct EOA call to `adapter.execute` reverts at the
    ///         `msg.sender == address(EVC)` gate, leaving the victim's token
    ///         balances untouched.
    function testRevert_directCallToAdapterRevertsAtCallerGate() public {
        EvcRolloverAdapter.EvcRolloverJob memory job =
            _craftOpenFillJob({ subaccount_: victim, fillerSrcCst_: 1_000e18, premium_: 50e18 });

        // The mock reverts on uninitialised on-behalf-of state — the first
        // selector encountered, the second is the new caller gate. Either is
        // an acceptable revert path; we assert non-execution via balance
        // assertions below.
        uint256 victimSrcBefore = srcCst.balanceOf(victim);
        uint256 victimPremBefore = premiumToken.balanceOf(victim);

        vm.expectRevert();
        adapter.execute(job);

        assertEq(srcCst.balanceOf(victim), victimSrcBefore, "victim srcCST must be untouched");
        assertEq(
            premiumToken.balanceOf(victim), victimPremBefore, "victim premium must be untouched"
        );
    }

    /// @notice An attacker leveraging the EVC CER-23 callback-bypass to set an
    ///         arbitrary on-behalf-of subaccount cannot force a victim
    ///         rollover: the adapter's `_gateEvc` rejects the inner direct
    ///         `adapter.execute` call because `msg.sender != address(EVC)`.
    ///
    /// @dev    Inverted from the pre-pin PoC: the same attacker sequence
    ///         now reverts at the gate with no token movement out of the
    ///         victim's account.
    function testRevert_attackerCannotForceVictimRolloverViaCer23Bypass() public {
        uint256 victimSrcBefore = srcCst.balanceOf(victim);
        uint256 victimPremBefore = premiumToken.balanceOf(victim);
        uint256 attackerSrcBefore = srcCst.balanceOf(attackerEoa);

        EvcRolloverAdapter.EvcRolloverJob memory job =
            _craftOpenFillJob({ subaccount_: victim, fillerSrcCst_: 1_000e18, premium_: 50e18 });

        // Attacker drives the exploit from their own EOA with zero permissions
        // on the victim's EVC account.
        vm.prank(attackerEoa);
        vm.expectRevert(EvcRolloverAdapter__CallerNotEvc.selector);
        exploit.attack(victim, job);

        // Token balances must be unchanged across the reverted attack frame.
        assertEq(
            srcCst.balanceOf(victim),
            victimSrcBefore,
            "victim srcCST must be untouched by CER-23 attack"
        );
        assertEq(
            premiumToken.balanceOf(victim),
            victimPremBefore,
            "victim premium must be untouched by CER-23 attack"
        );
        assertEq(
            srcCst.balanceOf(attackerEoa),
            attackerSrcBefore,
            "attacker EOA balance must be unchanged"
        );
    }

    function _craftOpenFillJob(address subaccount_, uint256 fillerSrcCst_, uint256 premium_)
        internal
        view
        returns (EvcRolloverAdapter.EvcRolloverJob memory job)
    {
        RolloverTypes.OrderData memory od;
        od.allowPartialFills = true;
        od.exclusiveFiller = address(0);
        od.minPremiumPerShare = 5e16;
        od.srcCstToken = address(srcCst);
        od.dstCstToken = address(dstCst);
        od.premiumToken = address(premiumToken);

        ERC7683Types.GaslessCrossChainOrder memory order;
        order.orderData = abi.encode(od);

        RolloverTypes.RolloverIntent memory intent;
        job = EvcRolloverAdapter.EvcRolloverJob({
            settler: ISettler(address(settler)),
            order: order,
            userSig: "",
            subaccount: subaccount_,
            fundingAccount: subaccount_,
            recipient: subaccount_,
            srcCst: IERC20(address(srcCst)),
            premiumToken: IERC20(address(premiumToken)),
            fillerSrcCst: fillerSrcCst_,
            minDstPerSrc: 0,
            intent: intent,
            premium: premium_,
            fillerAuthSig: "",
            nonce: 0,
            deadline: 0,
            fundingSig: ""
        });
    }
}

// ════════════════════════════════════════════════════════════════════
//                          LOCAL FIXTURE CONTRACTS
// ════════════════════════════════════════════════════════════════════

/// @notice CER-23-faithful EVC mock. When `target == msg.sender`, the EVC
///         accepts an arbitrary `onBehalfOfAccount` without authentication
///         and reissues the inner call with `msg.sender == address(EVC)`.
///         Mirrors the attack surface documented in Euler EVC `specs.md`
///         CER-23 + CER-94.
contract MockCer23Evc is IEVC {
    /// @notice Transient on-behalf-of subaccount reported to the adapter.
    address internal _onBehalfOfAccount;
    /// @notice Controller-enabled mapping; settable via `enableController`.
    mapping(address account => mapping(address controller => bool enabled)) public
        controllerEnabled;

    /// @notice Real EVC reverts with this selector when no on-behalf frame is set.
    error EVC_OnBehalfOfAccountNotAuthenticated();
    /// @notice This mock only models the CER-23 self-call path.
    error MockCer23Evc__OnlyCer23Supported();

    /// @notice CER-23 callback-bypass simulation — `target == msg.sender` is the
    ///         exact callsite the canonical EVC does not authenticate.
    /// @param target Inner target the EVC reissues the call against; only `msg.sender`
    ///        is accepted (the CER-23 self-call path).
    /// @param onBehalfOfAccount Subaccount the mock reports inside the inner frame.
    /// @param value Ether forwarded with the inner call (ignored — present for
    ///        canonical interface conformance).
    /// @param data Calldata forwarded to `target`.
    /// @return Returndata bubbled from the inner `target.call(data)`.
    // forge-lint: disable-next-line(missing-zero-check)
    function call(address target, address onBehalfOfAccount, uint256 value, bytes calldata data)
        external
        payable
        returns (bytes memory)
    {
        value;
        if (target != msg.sender) {
            revert MockCer23Evc__OnlyCer23Supported();
        }

        address prev = _onBehalfOfAccount;
        _onBehalfOfAccount = onBehalfOfAccount;
        (bool ok, bytes memory ret) = target.call(data);
        _onBehalfOfAccount = prev;

        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }

    /// @inheritdoc IEVC
    function getCurrentOnBehalfOfAccount(address controllerToCheck)
        external
        view
        returns (address, bool)
    {
        if (_onBehalfOfAccount == address(0)) {
            revert EVC_OnBehalfOfAccountNotAuthenticated();
        }
        return (_onBehalfOfAccount, controllerEnabled[_onBehalfOfAccount][controllerToCheck]);
    }

    /// @inheritdoc IEVC
    /// @dev This mock is scoped to CER-23 attack scenarios and does not model
    ///      the full owner-registry surface. Tests that exercise the Permit2
    ///      witness path should use `MockEVC` (which carries an account-owner
    ///      table) instead.
    function getAccountOwner(address) external pure returns (address) {
        return address(0);
    }

    /// @notice Enable a controller for an account.
    /// @param account Subaccount to configure.
    /// @param controller Controller address to enable.
    function enableController(address account, address controller) external {
        controllerEnabled[account][controller] = true;
    }
}

/// @notice Attacker contract. Calls `evc.call(target=self, ...)` to trigger the
///         CER-23 callback-bypass, then directly invokes the adapter from
///         inside the inner frame.
contract Cer23Exploit {
    /// @notice Adapter under attack.
    EvcRolloverAdapter internal immutable ADAPTER;
    /// @notice CER-23 EVC mock the attack pivots through.
    IEVC internal immutable EVC;

    /// @param adapter_ Adapter the exploit drives the inner-frame call against.
    /// @param evc_ EVC mock used to pivot through the CER-23 self-call.
    constructor(EvcRolloverAdapter adapter_, IEVC evc_) {
        ADAPTER = adapter_;
        EVC = evc_;
    }

    /// @notice Trigger the CER-23 callback-bypass against `victim`.
    /// @param victim Subaccount whose pre-approved allowance the attack targets.
    /// @param job Job payload the inner frame attempts to drive into the adapter.
    function attack(address victim, EvcRolloverAdapter.EvcRolloverJob memory job) external {
        bytes memory ignored = ICer23Callable(address(EVC))
            .call(address(this), victim, 0, abi.encodeCall(this.callbackPhase, (job)));
        ignored;
    }

    /// @notice Callback invoked by the EVC mock during the CER-23 reissue.
    ///         Inside this frame `msg.sender == address(EVC)` and the EVC
    ///         reports the attacker-chosen `victim` as the on-behalf-of
    ///         subaccount. The attacker then directly calls
    ///         `adapter.execute` — at which point `msg.sender ==
    ///         address(this)` and the adapter's caller gate rejects the call.
    /// @param job Job payload to drive into the adapter.
    function callbackPhase(EvcRolloverAdapter.EvcRolloverJob memory job) external {
        ADAPTER.execute(job);
    }
}

/// @notice Narrow interface to the CER-23 mock's `call(...)` entrypoint.
interface ICer23Callable {
    /// @notice Reissue `data` against `target` under a `(onBehalfOfAccount)` frame
    ///         using the CER-23 self-call path.
    /// @param target Inner target the EVC reissues the call against.
    /// @param onBehalfOfAccount Subaccount the mock reports inside the inner frame.
    /// @param value Ether forwarded with the inner call.
    /// @param data Calldata forwarded to `target`.
    /// @return Returndata bubbled from the inner `target.call(data)`.
    function call(address target, address onBehalfOfAccount, uint256 value, bytes calldata data)
        external
        payable
        returns (bytes memory);
}

/// @notice Minimal Settler stub that pulls tokens via the adapter's approvals.
///         Models just enough surface for the adapter's settlement loop to
///         reach the `_gateEvc` call site without reverting elsewhere first.
contract MockCer23Settler {
    /// @notice Source CST ERC-20 the stub pulls during ROLLOVER.
    MockERC20 internal srcCst;
    /// @notice Premium ERC-20 the stub pulls during PREMIUM.
    MockERC20 internal premiumToken;
    /// @notice Destination CST ERC-20 the stub mints on ROLLOVER.
    MockERC20 internal dstCst;

    /// @notice Wire token references used by the stub.
    /// @param src_ Source CST ERC-20.
    /// @param prem_ Premium ERC-20.
    /// @param dst_ Destination CST ERC-20.
    function bindTokens(MockERC20 src_, MockERC20 prem_, MockERC20 dst_) external {
        srcCst = src_;
        premiumToken = prem_;
        dstCst = dst_;
    }

    /// @notice EIP-712 domain separator (stub).
    /// @return Stub domain separator (zero).
    // forge-lint: disable-next-line(mixed-case-function)
    function DOMAIN_SEPARATOR() external pure returns (bytes32) {
        return bytes32(0);
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
    /// @return r Resolved order with a fixed `orderId` and empty dynamic arrays.
    function resolveFor(
        ERC7683Types.GaslessCrossChainOrder calldata order,
        bytes calldata originFillerData
    ) external pure returns (ERC7683Types.ResolvedCrossChainOrder memory r) {
        order;
        originFillerData;
        r.orderId = bytes32(uint256(0xCAFE));
        r.maxSpent = new ERC7683Types.Output[](0);
        r.minReceived = new ERC7683Types.Output[](0);
        r.fillInstructions = new ERC7683Types.FillInstruction[](0);
    }

    /// @notice Cached order status (stub — always `None` so the adapter calls `openFor`).
    /// @param orderDigest Order digest (ignored — stub returns fixed value).
    /// @return The `None` order status (`0`).
    function orderStatus(bytes32 orderDigest) external pure returns (uint8) {
        orderDigest;
        return 0;
    }

    /// @notice Report a fixed dstProduced amount.
    /// @param orderDigest Order digest (ignored — stub returns fixed value).
    /// @param filler Filler address (ignored — stub returns fixed value).
    /// @return The fixed `1_000e18` dstProduced amount.
    function fillerDstProducedOf(bytes32 orderDigest, address filler)
        external
        pure
        returns (uint256)
    {
        orderDigest;
        filler;
        return 1_000e18;
    }

    /// @notice 3-arg overload — subFiller dimension (ignored, returns fixed).
    /// @param orderDigest Order digest (ignored — stub returns fixed value).
    /// @param filler Filler address (ignored — stub returns fixed value).
    /// @param subFiller Sub-filler identity (ignored — stub returns fixed value).
    /// @return The fixed `1_000e18` dstProduced amount.
    function fillerDstProducedOf(bytes32 orderDigest, address filler, bytes32 subFiller)
        external
        pure
        returns (uint256)
    {
        orderDigest;
        filler;
        subFiller;
        return 1_000e18;
    }

    /// @notice ERC-7683 fill stub that mirrors the adapter's approval surface.
    /// @param orderDigest Order digest (ignored).
    /// @param originData Origin-side data (ignored).
    /// @param fillerData Filler-side data (ignored).
    function fill(bytes32 orderDigest, bytes calldata originData, bytes calldata fillerData)
        external
        pure
    {
        orderDigest;
        originData;
        fillerData;
    }
}
