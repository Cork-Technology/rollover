// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { FillScaffold } from "../../base/FillScaffold.sol";
import { MockERC20 } from "../../mocks/MockERC20.sol";
import { DstCstDrainModule } from "../../mocks/modules/DstCstDrainModule.sol";
import { HostileDeliverModule } from "../../mocks/modules/HostileDeliverModule.sol";
import { CorkRolloverContract } from "src/CorkRolloverContract.sol";
import { ExactSettler as Settler } from "src/ExactSettler.sol";
import {
    CorkRolloverContract__RolloverZeroDeposit
} from "src/errors/CorkRolloverContractErrors.sol";
import { Settler__PremiumExceedsCap } from "src/errors/SettlerErrors.sol";
import {
    ICorkRolloverContractFactory
} from "src/interfaces/rollover/ICorkRolloverContractFactory.sol";
import { IRolloverContractLens } from "src/interfaces/rollover/IRolloverContractLens.sol";
import { Typehashes } from "src/libraries/Typehashes.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";
import { SettlerTypes } from "src/types/SettlerTypes.sol";

/// @notice LyingFactoryMock — pins DstIntegrityAndDocs behaviour for the Cork Rollover suite.
contract LyingFactoryMock is ICorkRolloverContractFactory {
    /// @notice  originating settler.
    /// @return _originatingSettler Stored  originating settler value.
    address public _originatingSettler;
    /// @notice Reported dst produced.
    /// @return reportedDstProduced Stored reported dst produced value.

    uint256 public reportedDstProduced;
    /// @notice Delivered dst cst.
    /// @return deliveredDstCst Stored delivered dst cst value.

    uint256 public deliveredDstCst;
    /// @notice Dst cst token.
    /// @return dstCstToken Stored dst cst token value.

    address public dstCstToken;

    /// @notice Sets lie.
    /// @param reported Value reported by the hook (untrusted).
    /// @param delivered Value mechanically delivered (trusted).
    /// @param dst Destination address.

    // forge-lint: disable-next-line(missing-zero-check)
    function setLie(uint256 reported, uint256 delivered, address dst) external {
        reportedDstProduced = reported;
        deliveredDstCst = delivered;
        dstCstToken = dst;
    }

    /// @notice Sets originating settler.
    /// @param s String value or scratch value.

    // forge-lint: disable-next-line(missing-zero-check)
    function setOriginatingSettler(address s) external {
        _originatingSettler = s;
    }
    /// @notice Execute intent hooks.
    /// @param rolloverContract_ Ignored rolloverContract address.
    /// @param orderDigest_ Ignored order digest.
    /// @param phase_ Ignored hook phase.
    /// @param intent_ Ignored rollover intent.
    /// @param signature_ Ignored cPT-holder signature bytes.
    /// @param ctx_ Ignored fill context.
    /// @param orderData_ Ignored order data.
    /// @return Return value.
    /// @return Return value.

    function executeIntentHooks(
        address rolloverContract_,
        bytes32 orderDigest_,
        RolloverTypes.HookPhase phase_,
        RolloverTypes.RolloverIntent calldata intent_,
        bytes calldata signature_,
        RolloverTypes.FillContext calldata ctx_,
        RolloverTypes.OrderData calldata orderData_
    ) external returns (uint256, uint256) {
        rolloverContract_;
        orderDigest_;
        phase_;
        intent_;
        signature_;
        ctx_;
        orderData_;
        if (deliveredDstCst != 0) {
            // forge-lint: disable-next-line(erc20-unchecked-transfer)
            require(MockERC20(dstCstToken).transfer(msg.sender, deliveredDstCst), "deliver");
        }
        uint256 reported = reportedDstProduced;
        // 2-tuple wire shape: `(dstProduced, srcLeftover)`. The mock emits a "lying"
        // dstProduced with srcLeftover=0 to drive defence-in-depth tests on the
        // Settler's delta-balance reconciliation.
        // solhint-disable-next-line no-inline-assembly
        assembly {
            mstore(0x00, reported)
            mstore(0x20, 0)
            return(0x00, 0x40)
        }
    }
    /// @notice Originating settler.
    /// @return Return value.

    function originatingSettler() external view returns (address) {
        return _originatingSettler;
    }
    /// @notice Returns whether deployed rolloverContract.
    /// @param rolloverContract_ Ignored rolloverContract address.
    /// @return Return value.

    function isDeployedRolloverContract(address rolloverContract_) external pure returns (bool) {
        rolloverContract_;
        return true;
    }
    /// @notice RolloverContract of.
    /// @param user_ Ignored owner address.
    /// @return Return value.

    function rolloverContractOf(address user_) external pure returns (address) {
        user_;
        return address(0);
    }
    /// @notice Predict rolloverContract of.
    /// @param user_ Ignored owner address.
    /// @return Return value.

    function predictRolloverContractOf(address user_) external pure returns (address) {
        user_;
        return address(0);
    }

    /// @notice Deploy rolloverContract.
    /// @return Return value.

    function deployRolloverContract() external pure returns (address) {
        revert("not implemented");
    }
    /// @notice Approve settler.
    /// @param settler_ Ignored settler address.

    function approveSettler(address settler_) external pure {
        settler_;
    }
    /// @notice Revoke settler.
    /// @param settler_ Ignored settler address.

    function revokeSettler(address settler_) external pure {
        settler_;
    }
    /// @notice Approved settlers.
    /// @param settler_ Ignored settler address.
    /// @return Return value.

    function approvedSettlers(address settler_) external pure returns (bool) {
        settler_;
        return true;
    }
    /// @notice Version.
    /// @return Return value.

    function version() external pure returns (string memory) {
        return "mock";
    }

    /// @notice Trust-config timelock (mock returns zero address; trust-config flow is not exercised here).
    /// @return Return value.
    function trustConfigTimelock() external pure returns (address) {
        return address(0);
    }

    /// @notice Queue trust config (mock no-op).
    /// @param threshold_ Ignored threshold.
    /// @param attesters_ Ignored attester list.
    function queueTrustConfig(uint8 threshold_, address[] calldata attesters_) external pure { }

    /// @notice Queue current factory defaults (mock no-op).
    function queueFactoryDefaultTrustConfig() external pure { }

    /// @notice Queue trust-config delay update (mock no-op).
    /// @param newDelay_ Ignored new delay.
    function queueTrustConfigDelayUpdate(uint256 newDelay_) external pure {
        newDelay_;
    }

    /// @notice Cancel trust-config delay update (mock no-op).
    function cancelTrustConfigDelayUpdate() external pure { }

    /// @notice Apply trust-config delay update (mock no-op).
    function applyTrustConfigDelayUpdate() external pure { }

    /// @notice Apply trust config (mock no-op).
    /// @param rolloverContract_ Ignored rolloverContract address.
    function applyTrustConfig(address rolloverContract_) external pure {
        rolloverContract_;
    }

    /// @notice Relay trust config (mock no-op).
    /// @param rolloverContract_ Ignored rolloverContract address.
    /// @param salt_ Ignored operation salt.
    /// @param threshold_ Ignored threshold.
    /// @param attesters_ Ignored attester list.
    function relayTrustConfig(
        address rolloverContract_,
        bytes32 salt_,
        uint8 threshold_,
        address[] memory attesters_
    ) external pure { }

    /// @notice Cancel trust config (mock no-op).
    function cancelTrustConfig() external pure { }

    /// @notice Pending trust config (mock zero tuple).
    /// @param rolloverContract_ Ignored rolloverContract address.
    /// @return threshold Zero.
    /// @return attesters Empty list.
    /// @return effectiveAt Zero.
    function pendingTrustConfig(address rolloverContract_)
        external
        pure
        returns (uint8 threshold, address[] memory attesters, uint64 effectiveAt)
    {
        rolloverContract_;
        return (0, new address[](0), 0);
    }

    /// @notice Pending trust-config delay update (mock zero tuple).
    /// @return queued False.
    /// @return newDelay Zero.
    /// @return effectiveAt Zero.
    function pendingTrustConfigDelayUpdate()
        external
        pure
        returns (bool queued, uint256 newDelay, uint64 effectiveAt)
    {
        return (false, 0, 0);
    }
}

/// @notice NoopReceiver — pins DstIntegrityAndDocs behaviour for the Cork Rollover suite.
/// @dev Exposes `owner()` so the Settler's `INV-USER-IS-ROLLOVER_CONTRACT-OWNER` admission check passes
///      through to the bug-reporting branch this fixture is targeting. `_user` is set by the
///      test to the order's `user` field before `fill` is invoked.
contract NoopReceiver {
    /// @notice CWIA-owner mock. Settable by tests to satisfy the Settler's
    ///         `INV-USER-IS-ROLLOVER_CONTRACT-OWNER` admission check.
    address public owner;

    /// @notice Set the cPT holder returned by the `owner()` view.
    /// @param o Address to mirror as the CWIA-baked owner.
    // Minimal mock mirrors arbitrary owner values supplied by tests.
    // forge-lint: disable-next-line(missing-zero-check)
    function setOwner(address o) external {
        owner = o;
    }
}

/// @notice DstIntegrityAndDocsTest — pins DstIntegrityAndDocs behaviour for the Cork Rollover suite.
contract DstIntegrityAndDocsTest is FillScaffold {
    /// @notice Hostile deliver.
    HostileDeliverModule internal hostileDeliver;
    /// @notice Dst drain.

    DstCstDrainModule internal dstDrain;
    /// @notice Order size.

    uint256 internal constant ORDER_SIZE = 1_000e18;
    /// @notice Attacker EOA used across the test harness.

    address internal attacker = address(0xBADD);
    /// @notice Test fixture setup.

    function setUp() public override {
        super.setUp();
        hostileDeliver = new HostileDeliverModule();
        dstDrain = new DstCstDrainModule();

        erc7484.setAttestedType(address(hostileDeliver), Typehashes.MODULE_TYPE_POST_ROLLOVER_HOOK);
        erc7484.setAttestedType(address(dstDrain), Typehashes.MODULE_TYPE_POST_ROLLOVER_HOOK);
        vm.label(address(hostileDeliver), "hostileDeliver");
        vm.label(address(dstDrain), "dstDrain");
        vm.label(attacker, "attacker");

        vm.startPrank(filler);
        srcCst.approve(address(settler), type(uint256).max);
        srcCst.approve(address(partialSettler), type(uint256).max);
        premiumToken.approve(address(settler), type(uint256).max);
        premiumToken.approve(address(partialSettler), type(uint256).max);
        vm.stopPrank();
    }

    function _orderExact(uint64 nonce)
        internal
        view
        returns (RolloverTypes.OrderData memory orderData)
    {
        orderData = _baseOrder();
        orderData.allowPartialFills = false;
        orderData.orderSize = ORDER_SIZE;
        orderData.orderSalt = nonce;
    }

    function _intentHostileDeliver(
        bytes32 orderDigest,
        uint256 mintToRolloverContract,
        uint256 divertToSettler
    ) internal view returns (RolloverTypes.RolloverIntent memory) {
        RolloverTypes.Call[] memory pre = new RolloverTypes.Call[](1);
        pre[0] = _hook(
            address(sourceSrcCptModule),
            abi.encodeWithSignature(
                "execute(address,uint256)", address(srcCpt), mintToRolloverContract
            )
        );
        RolloverTypes.Call[] memory post = new RolloverTypes.Call[](2);

        post[0] = _hook(
            address(hostileDeliver),
            abi.encodeWithSignature(
                "execute(address,uint256,address,uint256)",
                address(dstCst),
                divertToSettler + 1,
                address(settler),
                divertToSettler
            )
        );
        post[1] = _hook(
            address(consumeDstCptModule),
            abi.encodeWithSignature("execute(address)", address(dstCpt))
        );
        return
            _intentWithHooks(rolloverContract, orderDigest, pre, new RolloverTypes.Call[](0), post);
    }

    function _intentSeedThenDrain(bytes32 orderDigest, uint256, uint256 drainAmount)
        internal
        view
        returns (RolloverTypes.RolloverIntent memory)
    {
        RolloverTypes.Call[] memory pre = new RolloverTypes.Call[](1);
        pre[0] = _hook(
            address(sourceSrcCptModule),
            abi.encodeWithSignature("execute(address,uint256)", address(srcCpt), ORDER_SIZE)
        );
        RolloverTypes.Call[] memory post = new RolloverTypes.Call[](2);
        post[0] = _hook(
            address(dstDrain),
            abi.encodeWithSignature(
                "execute(address,address,uint256)", address(dstCst), attacker, drainAmount
            )
        );
        post[1] = _hook(
            address(consumeDstCptModule),
            abi.encodeWithSignature("execute(address)", address(dstCpt))
        );
        return
            _intentWithHooks(rolloverContract, orderDigest, pre, new RolloverTypes.Call[](0), post);
    }

    function _openWithIntent(
        RolloverTypes.OrderData memory orderData,
        RolloverTypes.RolloverIntent memory intent
    )
        internal
        returns (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory bound,
            bytes memory cptHolderSig
        )
    {
        orderData.rolloverIntentHash = _zeroDigestHash(intent);
        orderDigest = _openOrder(orderData);
        bound = intent;
        bound.orderDigest = orderDigest;
        cptHolderSig = _signOrder(cptHolderPk, orderData);
    }

    function _fillRollover(
        bytes32 orderDigest,
        RolloverTypes.OrderData memory orderData,
        RolloverTypes.RolloverIntent memory intent,
        bytes memory cptHolderSig
    ) internal {
        _doRolloverAs(orderDigest, orderData, intent, ORDER_SIZE, filler);
    }

    /// @notice Pins behaviour: dst Produced returned From RolloverContract matches Fill Record.
    ///         Under atomic-fill the dstCST is forwarded to the filler in the same frame.
    function test_dstProduced_returnedFromRolloverContract_matchesRolloverAccounting() public {
        RolloverTypes.OrderData memory orderData = _orderExact(1);
        RolloverTypes.RolloverIntent memory probe = _buildIntent(bytes32(0), ORDER_SIZE, ORDER_SIZE);

        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _openWithIntent(orderData, probe);

        uint256 fillerDstBefore = dstCst.balanceOf(filler);
        _fillRollover(orderDigest, orderData, intent, cptHolderSig);

        SettlerTypes.ExactRolloverAccounting memory rec = settler.rolloverAccountingOf(orderDigest);
        assertEq(
            rec.dstCstProduced, ORDER_SIZE, "rollover accounting records rolloverContract mint"
        );
        assertEq(
            dstCst.balanceOf(filler) - fillerDstBefore,
            ORDER_SIZE,
            "filler holds mint (atomic-fill)"
        );
    }

    /// @notice Pins behaviour: donation Inflation does Not Inflate Fill Record.
    ///         Under atomic-fill the rolloverContract-minted dstCST is forwarded to the filler;
    ///         the standalone donation remains on the settler.
    function test_donationInflation_doesNotInflateRolloverAccounting() public {
        RolloverTypes.OrderData memory orderData = _orderExact(2);
        RolloverTypes.RolloverIntent memory probe = _buildIntent(bytes32(0), ORDER_SIZE, ORDER_SIZE);

        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _openWithIntent(orderData, probe);

        uint256 donation = 7e18;
        dstCst.mint(address(settler), donation);

        uint256 fillerDstBefore = dstCst.balanceOf(filler);
        _fillRollover(orderDigest, orderData, intent, cptHolderSig);

        SettlerTypes.ExactRolloverAccounting memory rec = settler.rolloverAccountingOf(orderDigest);
        assertEq(
            rec.dstCstProduced,
            ORDER_SIZE,
            "rollover accounting == rolloverContract mint, NOT mint + donation"
        );
        assertEq(
            dstCst.balanceOf(filler) - fillerDstBefore,
            ORDER_SIZE,
            "filler holds mint (donation stranded on settler)"
        );
        assertEq(dstCst.balanceOf(address(settler)), donation, "settler holds donation only");
        assertEq(settler.recoverableTokenBalance(address(dstCst)), donation, "dust recoverable");
    }

    /// @notice Pins behaviour: hostile Hook Donation does Not Inflate Fill Record.
    ///         Under atomic-fill: honest mint forwards to filler; hostile-diverted dstCST
    ///         remains recoverable on the settler. The rollover accounting must capture the
    ///         honest mint only.
    function test_hostileHookDonation_doesNotInflateRolloverAccounting() public {
        uint256 honestMint = ORDER_SIZE;
        uint256 divertToSettler = 100e18;

        RolloverTypes.OrderData memory orderData = _orderExact(3);
        RolloverTypes.RolloverIntent memory probe =
            _intentHostileDeliver(bytes32(0), honestMint, divertToSettler);

        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _openWithIntent(orderData, probe);

        uint256 fillerDstBefore = dstCst.balanceOf(filler);
        _fillRollover(orderDigest, orderData, intent, cptHolderSig);

        SettlerTypes.ExactRolloverAccounting memory rec = settler.rolloverAccountingOf(orderDigest);

        assertEq(
            rec.dstCstProduced, honestMint, "rollover accounting == honest rolloverContract mint"
        );

        assertEq(
            dstCst.balanceOf(filler) - fillerDstBefore,
            honestMint,
            "filler holds honest mint (atomic-fill)"
        );
        assertEq(
            dstCst.balanceOf(address(settler)), divertToSettler, "settler holds hostile donation"
        );
        assertEq(
            settler.recoverableTokenBalance(address(dstCst)),
            divertToSettler,
            "in-call surplus recoverable separately from rollover accounting"
        );
    }

    /// @notice Pins behaviour: rolloverContract Bug Reporting reverts Distinctly.
    function test_rolloverContractBugReporting_revertsDistinctly() public {
        LyingFactoryMock lying = new LyingFactoryMock();
        Settler altSettler = new Settler(
            address(lying),
            address(phoenixPool),
            address(this),
            address(this),
            address(this),
            address(this)
        );
        lying.setOriginatingSettler(address(altSettler));

        uint256 reported = 500e18;
        uint256 delivered = 100e18;
        dstCst.mint(address(lying), delivered);
        lying.setLie(reported, delivered, address(dstCst));

        NoopReceiver noopRolloverContract = new NoopReceiver();
        RolloverTypes.OrderData memory orderData = _baseOrder();
        noopRolloverContract.setOwner(orderData.user); // satisfy INV-USER-IS-ROLLOVER_CONTRACT-OWNER admission
        orderData.allowPartialFills = false;
        orderData.orderSize = ORDER_SIZE;
        orderData.orderSalt = 4;
        orderData.settler = address(altSettler);
        orderData.rolloverParams.settler = address(altSettler);
        orderData.rolloverContract = address(noopRolloverContract);
        bytes32 orderDigest = _orderDigestFor(address(altSettler), orderData);

        vm.startPrank(filler);
        srcCst.approve(address(altSettler), type(uint256).max);
        vm.stopPrank();

        RolloverTypes.RolloverIntent memory intent = _emptyIntent(rolloverContract, orderDigest);
        bytes memory cptHolderSig = new bytes(65);

        vm.expectRevert(
            abi.encodeWithSignature(
                "Settler__DstProducedNotDelivered(uint256,uint256)", reported, delivered
            )
        );
        // _doRolloverAs builds an atomic-fill envelope and pranks the filler. orderData.settler
        // already points at the altSettler so the dispatcher targets the lying factory path.
        _doRolloverAs(orderDigest, orderData, intent, ORDER_SIZE, filler);
    }

    /// @notice Pins behaviour: backed high dstCST reports can raise required premium, but the
    ///         atomic premium cap prevents forced payment and unwinds the rollover frame.
    function testRevert_backedHighDstReport_premiumCapPreventsForcedPayment() public {
        LyingFactoryMock lying = new LyingFactoryMock();
        Settler altSettler = new Settler(
            address(lying),
            address(phoenixPool),
            address(this),
            address(this),
            address(this),
            address(this)
        );
        lying.setOriginatingSettler(address(altSettler));

        NoopReceiver noopRolloverContract = new NoopReceiver();
        RolloverTypes.OrderData memory orderData = _baseOrder();
        noopRolloverContract.setOwner(orderData.user); // satisfy INV-USER-IS-ROLLOVER_CONTRACT-OWNER admission
        orderData.allowPartialFills = false;
        orderData.orderSize = ORDER_SIZE;
        orderData.orderSalt = 44;
        orderData.settler = address(altSettler);
        orderData.rolloverParams.settler = address(altSettler);
        orderData.rolloverContract = address(noopRolloverContract);
        bytes32 orderDigest = _orderDigestFor(address(altSettler), orderData);

        uint256 reportedAndDelivered = 2_000e18;
        uint256 requiredPremium =
            (reportedAndDelivered * orderData.minPremiumPerShare + 1e18 - 1) / 1e18;
        uint256 premiumCap = requiredPremium - 1;
        dstCst.mint(address(lying), reportedAndDelivered);
        lying.setLie(reportedAndDelivered, reportedAndDelivered, address(dstCst));

        vm.prank(filler);
        srcCst.approve(address(altSettler), type(uint256).max);

        RolloverTypes.RolloverIntent memory intent =
            _emptyIntent(address(noopRolloverContract), orderDigest);
        bytes memory cptHolderSig = new bytes(65);

        vm.expectRevert(
            abi.encodeWithSelector(Settler__PremiumExceedsCap.selector, premiumCap, requiredPremium)
        );
        _doRolloverAsWithCap(orderDigest, orderData, intent, ORDER_SIZE, filler, premiumCap);

        assertEq(dstCst.balanceOf(address(altSettler)), 0, "atomic revert unwinds dst delivery");
        assertEq(
            dstCst.balanceOf(address(lying)),
            reportedAndDelivered,
            "atomic revert restores factory balance"
        );
    }

    /// @notice Pins behaviour: zero Mint reverts Through RolloverContract Return.
    function testRevert_zeroMint_revertsThroughRolloverContractReturn() public {
        phoenixPool.setReportZeroDeposit(dstCst.poolId(), true);
        RolloverTypes.OrderData memory orderData = _orderExact(5);
        RolloverTypes.RolloverIntent memory probe = _buildIntent(bytes32(0), ORDER_SIZE, 0);

        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _openWithIntent(orderData, probe);

        vm.expectRevert(abi.encodeWithSignature("CorkRolloverContract__RolloverZeroDeposit()"));
        _doRolloverAs(orderDigest, orderData, intent, ORDER_SIZE, filler);
    }

    /// @notice Pins behaviour: dst Drain reverts With Named Error.
    function testRevert_dstDrain_revertsWithNamedError() public {
        uint256 seed = 50e18;
        uint256 drain = 30e18;

        dstCst.mint(rolloverContract, seed);

        RolloverTypes.OrderData memory orderData = _orderExact(6);
        RolloverTypes.RolloverIntent memory probe = _intentSeedThenDrain(bytes32(0), 0, drain);

        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _openWithIntent(orderData, probe);

        vm.expectRevert(
            abi.encodeWithSignature(
                "CorkRolloverContract__MidPhaseDstCstDrain(uint256,uint256)", seed, seed - drain
            )
        );
        _doRolloverAs(orderDigest, orderData, intent, ORDER_SIZE, filler);
    }

    /// @notice Pins behaviour: dst Neutral Hooks do Not Revert.
    function test_dstNeutralHooks_doNotRevert() public {
        phoenixPool.setPartialDeposit(dstCst.poolId(), 1, ORDER_SIZE);
        RolloverTypes.OrderData memory orderData = _orderExact(7);
        RolloverTypes.RolloverIntent memory probe = _buildIntent(bytes32(0), ORDER_SIZE, 1);

        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _openWithIntent(orderData, probe);

        _fillRollover(orderDigest, orderData, intent, cptHolderSig);

        SettlerTypes.ExactRolloverAccounting memory rec = settler.rolloverAccountingOf(orderDigest);
        assertEq(rec.dstCstProduced, 1, "neutral mint of 1 wei records cleanly");
    }

    /// @notice Pins behaviour: dst Minting Hooks pass Through.
    function test_dstMintingHooks_passThrough() public {
        RolloverTypes.OrderData memory orderData = _orderExact(8);
        RolloverTypes.RolloverIntent memory probe = _buildIntent(bytes32(0), ORDER_SIZE, ORDER_SIZE);

        (
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _openWithIntent(orderData, probe);

        _fillRollover(orderDigest, orderData, intent, cptHolderSig);

        assertEq(
            IRolloverContractLens(address(factory))
            .orderState(rolloverContract, orderDigest)
            .rolled,
            ORDER_SIZE,
            "rolled == orderSize"
        );
    }

    /// @notice M-03 TDD boundary: deployment docs must state the trusted delegatecall-hook policy.
    function test_docs_delegatecallHookDeploymentPolicy_coversM03() public view {
        string memory deploy = vm.readFile("docs/DEPLOY.md");

        assertTrue(_contains(deploy, "M-03"), "docs/DEPLOY.md must identify M-03");
        assertTrue(
            _contains(deploy, "delegatecall hooks"), "docs/DEPLOY.md must cover delegatecall hooks"
        );
        assertTrue(
            _contains(deploy, "privileged trusted modules"),
            "docs/DEPLOY.md must treat hooks as privileged trusted modules"
        );
        assertTrue(
            _contains(deploy, "immutable, reviewed, storage-safe hook modules"),
            "docs/DEPLOY.md must require immutable reviewed storage-safe hook modules"
        );
        assertTrue(
            _contains(deploy, "upgradeable/proxy hook targets"),
            "docs/DEPLOY.md must cover upgradeable/proxy hook targets"
        );
        assertTrue(
            _contains(deploy, "explicit risk acceptance"),
            "docs/DEPLOY.md must require explicit risk acceptance"
        );
    }

    /// @notice M-04 TDD boundary: deployment docs must state the Phoenix dependency policy.
    function test_docs_phoenixDependencyPolicy_coversM04() public view {
        string memory deploy = vm.readFile("docs/DEPLOY.md");

        assertTrue(_contains(deploy, "M-04"), "docs/DEPLOY.md must identify M-04");
        assertTrue(
            _contains(deploy, "PoolShare.poolManager immutability"),
            "docs/DEPLOY.md must rely on PoolShare.poolManager immutability"
        );
        assertTrue(
            _contains(deploy, "Phoenix upgrade governance"),
            "docs/DEPLOY.md must cover Phoenix upgrade governance"
        );
        assertTrue(
            _contains(deploy, "standard no-fee ERC-20"),
            "docs/DEPLOY.md must require standard no-fee ERC-20 collateral"
        );
        assertTrue(
            _contains(deploy, "fee-on-transfer"),
            "docs/DEPLOY.md must identify fee-on-transfer collateral as unsupported"
        );
        assertTrue(
            _contains(deploy, "rebasing"),
            "docs/DEPLOY.md must identify rebasing collateral as unsupported"
        );
        assertTrue(
            _contains(deploy, "deflationary"),
            "docs/DEPLOY.md must identify deflationary collateral as unsupported"
        );
        assertTrue(
            _contains(deploy, "balance-mutating"),
            "docs/DEPLOY.md must identify balance-mutating collateral as unsupported"
        );
        assertTrue(
            _contains(deploy, "no Cork runtime manager-pinning change"),
            "docs/DEPLOY.md must state there is no Cork runtime manager-pinning change"
        );
    }

    function _orderDigestFor(address settlerAddr, RolloverTypes.OrderData memory orderData)
        internal
        view
        returns (bytes32)
    {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                Typehashes.EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("CorkSettler")),
                keccak256(bytes("1.0.0")),
                block.chainid,
                settlerAddr
            )
        );
        bytes memory prefix = abi.encode(
            Typehashes.ORDER_DATA_TYPEHASH,
            orderData.user,
            orderData.settler,
            orderData.fillerHint,
            orderData.exclusiveFiller,
            orderData.srcCstToken,
            orderData.dstCstToken,
            orderData.premiumToken,
            orderData.rolloverContract,
            orderData.originChainId,
            orderData.destinationChainId
        );
        bytes memory suffix = abi.encode(
            orderData.openDeadline,
            orderData.fillDeadline,
            orderData.orderSalt,
            orderData.orderSize,
            orderData.minPremiumPerShare,
            orderData.allowPartialFills,
            orderData.allowUnderfill,
            orderData.premiumPaymentMode,
            orderData.rolloverIntentHash,
            _hashRolloverParamsMemory(orderData.rolloverParams)
        );
        bytes32 structHash = keccak256(bytes.concat(prefix, suffix));
        return keccak256(abi.encodePacked(hex"1901", domainSeparator, structHash));
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0) {
            return true;
        }
        if (n.length > h.length) {
            return false;
        }

        for (uint256 i = 0; i <= h.length - n.length; ++i) {
            bool found = true;
            for (uint256 j = 0; j < n.length; ++j) {
                if (h[i + j] != n[j]) {
                    found = false;
                    break;
                }
            }
            if (found) {
                return true;
            }
        }

        return false;
    }
}
