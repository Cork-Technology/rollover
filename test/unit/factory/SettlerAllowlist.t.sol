// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {
    CorkRolloverContractFactory__AddressHasNoCode,
    CorkRolloverContractFactory__SettlerNotApproved,
    CorkRolloverContractFactory__ZeroAddress
} from "src/errors/CorkRolloverContractFactoryErrors.sol";

import { BaseTest } from "../../base/BaseTest.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { Vm } from "forge-std/Vm.sol";
import { CorkRolloverContractFactory } from "src/CorkRolloverContractFactory.sol";
import { ExactSettler } from "src/ExactSettler.sol";
import { MarketId } from "src/interfaces/external/phoenix/IPoolManager.sol";
import {
    ICorkRolloverContractFactory
} from "src/interfaces/rollover/ICorkRolloverContractFactory.sol";
import {
    ICorkRolloverContractFactoryAdmin
} from "src/interfaces/rollover/ICorkRolloverContractFactoryAdmin.sol";
import { IRolloverHookDispatcher } from "src/interfaces/rollover/IRolloverHookDispatcher.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice SettlerAllowlistTest — pins SettlerAllowlist behaviour for the Cork Rollover suite.
contract SettlerAllowlistTest is BaseTest {
    /// @notice Factory namespace slot (ERC-7201 namespace `cork.factory.storage.v3`).
    bytes32 internal constant FACTORY_NAMESPACE_SLOT =
        0x33e161bf0309d8211c87f71dbb3e2f85e82ce7cff87a5e8b28dd7396ad330700;

    /// @notice Role allowed to approve settler contracts.
    bytes32 internal constant SETTLER_APPROVER_ROLE = keccak256("SETTLER_APPROVER_ROLE");
    /// @notice Role allowed to revoke settler contract approvals.
    bytes32 internal constant SETTLER_REVOKER_ROLE = keccak256("SETTLER_REVOKER_ROLE");

    function _newSettler(CorkRolloverContractFactory f) internal returns (ExactSettler) {
        return new ExactSettler(
            address(f), address(this), address(this), address(this), address(this), address(this)
        );
    }

    /// @notice Initial admin receives role-admin plus all factory operational roles.
    function test_constructor_grantsInitialAdminOperationalRoles() public view {
        assertTrue(factory.hasRole(factory.DEFAULT_ADMIN_ROLE(), address(this)), "admin");
        assertTrue(factory.hasRole(SETTLER_APPROVER_ROLE, address(this)), "approver");
        assertTrue(factory.hasRole(SETTLER_REVOKER_ROLE, address(this)), "revoker");
        assertTrue(factory.hasRole(factory.DEFAULTS_MANAGER_ROLE(), address(this)), "defaults");
    }

    /// @notice Pins behaviour: unapproved ExactSettler Reverts.
    function testRevert_unapprovedSettlerReverts() public {
        ExactSettler rogue = _newSettler(factory);
        RolloverTypes.OrderData memory orderData = _baseOrder();
        bytes32 orderDigest = _openOrder(orderData);
        RolloverTypes.RolloverIntent memory intent = _emptyIntent(rolloverContract, orderDigest);
        bytes memory sig = new bytes(65);
        RolloverTypes.FillContext memory fillContext = _fillContext({
            filler_: filler,
            fillAmount: 1,
            rolloverIntentHash: orderData.rolloverIntentHash,
            fillDeadline: orderData.fillDeadline,
            allowPartialFills: orderData.allowPartialFills,
            orderSize: orderData.orderSize,
            originSettler: address(rogue),
            premiumToken_: address(premiumToken),
            premium: 0
        });
        vm.prank(address(rogue));
        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContractFactory__SettlerNotApproved.selector, address(rogue)
            )
        );
        factory.executeIntentHooks(
            rolloverContract,
            orderDigest,
            RolloverTypes.HookPhase.ROLLOVER,
            intent,
            sig,
            fillContext,
            orderData
        );
    }

    /// @notice Pins behaviour: revoke Mid Run Reverts.
    function test_revokeMidRunReverts() public {
        factory.revokeSettler(address(settler));
        assertFalse(factory.approvedSettlers(address(settler)));

        RolloverTypes.OrderData memory orderData = _baseOrder();
        bytes32 orderDigest = _openOrder(orderData);
        RolloverTypes.RolloverIntent memory intent = _emptyIntent(rolloverContract, orderDigest);
        bytes memory sig = new bytes(65);
        RolloverTypes.FillContext memory fillContext = _fillContext({
            filler_: filler,
            fillAmount: 1,
            rolloverIntentHash: orderData.rolloverIntentHash,
            fillDeadline: orderData.fillDeadline,
            allowPartialFills: orderData.allowPartialFills,
            orderSize: orderData.orderSize,
            originSettler: address(settler),
            premiumToken_: address(premiumToken),
            premium: 0
        });
        vm.prank(address(settler));
        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContractFactory__SettlerNotApproved.selector, address(settler)
            )
        );
        factory.executeIntentHooks(
            rolloverContract,
            orderDigest,
            RolloverTypes.HookPhase.ROLLOVER,
            intent,
            sig,
            fillContext,
            orderData
        );
    }

    /// @notice Pins behaviour: double Approve Idempotent.
    function test_doubleApproveIdempotent() public {
        ExactSettler s = _newSettler(factory);
        factory.approveSettler(address(s));
        factory.approveSettler(address(s));
        assertTrue(factory.approvedSettlers(address(s)));
    }

    /// @notice Pins behaviour: duplicate approve emits even when already approved.
    function test_doubleApproveEmitsAgain() public {
        ExactSettler s = _newSettler(factory);
        factory.approveSettler(address(s));

        vm.expectEmit(true, false, false, false, address(factory));
        emit ICorkRolloverContractFactoryAdmin.SettlerApproved(address(s));
        factory.approveSettler(address(s));
    }

    /// @notice Pins behaviour: revoke Never Approved Noop.
    function test_revokeNeverApprovedNoop() public {
        address s = makeAddr("never-approved");
        factory.revokeSettler(s);
        assertFalse(factory.approvedSettlers(s));
    }

    /// @notice Pins behaviour: revoke zero address is an idempotent no-op.
    function test_revokeZeroAddressNoop() public {
        factory.revokeSettler(address(0));
        assertFalse(factory.approvedSettlers(address(0)));
    }

    /// @notice Pins behaviour: reverts when approve ExactSettler Zero Address.
    function testRevert_approveSettlerZeroAddress() public {
        vm.expectRevert(CorkRolloverContractFactory__ZeroAddress.selector);
        factory.approveSettler(address(0));
    }

    /// @notice Pins behaviour: reverts when approve ExactSettler Code Less Address.
    function testRevert_approveSettlerCodeLessAddress() public {
        address eoa = makeAddr("settler-eoa");
        vm.expectRevert(
            abi.encodeWithSelector(CorkRolloverContractFactory__AddressHasNoCode.selector, eoa)
        );
        factory.approveSettler(eoa);
    }

    /// @notice Pins behaviour: genesis Deploy Requires Approval.
    function test_genesisDeployRequiresApproval() public {
        address[] memory defaults = new address[](1);
        defaults[0] = defaultAttester;
        TimelockController tl = _deployTrustConfigTimelockForNextFactory();
        CorkRolloverContractFactory fresh = new CorkRolloverContractFactory(
            address(rolloverContractImpl),
            address(erc7484),
            1,
            defaults,
            address(tl),
            address(this),
            address(this),
            address(this),
            address(this),
            address(this)
        );
        ExactSettler freshSettler = _newSettler(fresh);

        vm.prank(cptHolder);
        address freshRolloverContract = fresh.deployRolloverContract();

        RolloverTypes.OrderData memory orderData = _baseOrder();
        bytes32 orderDigest = bytes32(uint256(0xDEAD));
        RolloverTypes.RolloverIntent memory intent =
            _emptyIntent(freshRolloverContract, orderDigest);
        bytes memory sig = new bytes(65);
        RolloverTypes.FillContext memory fillContext = _fillContext({
            filler_: filler,
            fillAmount: 1,
            rolloverIntentHash: orderData.rolloverIntentHash,
            fillDeadline: orderData.fillDeadline,
            allowPartialFills: orderData.allowPartialFills,
            orderSize: orderData.orderSize,
            originSettler: address(freshSettler),
            premiumToken_: address(premiumToken),
            premium: 0
        });
        vm.prank(address(freshSettler));
        vm.expectRevert(
            abi.encodeWithSelector(
                CorkRolloverContractFactory__SettlerNotApproved.selector, address(freshSettler)
            )
        );
        fresh.executeIntentHooks(
            freshRolloverContract,
            orderDigest,
            RolloverTypes.HookPhase.ROLLOVER,
            intent,
            sig,
            fillContext,
            orderData
        );
    }

    /// @notice Pins behaviour: atomic Migration Approve V2 Revoke V1.
    function test_atomicMigrationApproveV2RevokeV1() public {
        ExactSettler v1 = settler;
        ExactSettler v2 = _newSettler(factory);

        factory.approveSettler(address(v2));
        factory.revokeSettler(address(v1));

        assertFalse(factory.approvedSettlers(address(v1)), "v1 must be revoked");
        assertTrue(factory.approvedSettlers(address(v2)), "v2 must be approved");
    }

    /// @notice Pins behaviour: settler Approved Event Emitted.
    function test_settlerApprovedEventEmitted() public {
        ExactSettler s = _newSettler(factory);
        vm.expectEmit(true, false, false, false, address(factory));
        emit ICorkRolloverContractFactoryAdmin.SettlerApproved(address(s));
        factory.approveSettler(address(s));
    }

    /// @notice Pins behaviour: settler Revoked Event Emitted.
    function test_settlerRevokedEventEmitted() public {
        ExactSettler s = _newSettler(factory);
        factory.approveSettler(address(s));
        vm.expectEmit(true, false, false, false, address(factory));
        emit ICorkRolloverContractFactoryAdmin.SettlerRevoked(address(s));
        factory.revokeSettler(address(s));
    }

    /// @notice Pins behaviour: duplicate revoke emits even when already unapproved.
    function test_doubleRevokeEmitsAgain() public {
        ExactSettler s = _newSettler(factory);
        factory.approveSettler(address(s));
        factory.revokeSettler(address(s));

        vm.expectEmit(true, false, false, false, address(factory));
        emit ICorkRolloverContractFactoryAdmin.SettlerRevoked(address(s));
        factory.revokeSettler(address(s));
    }

    /// @notice Pins behaviour: reverts when approve ExactSettler Access Control.
    function testRevert_approveSettlerAccessControl() public {
        address stranger = makeAddr("stranger-approve");
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                stranger,
                SETTLER_APPROVER_ROLE
            )
        );
        vm.prank(stranger);
        factory.approveSettler(makeAddr("target"));
    }

    /// @notice Pins behaviour: reverts when revoke ExactSettler Access Control.
    function testRevert_revokeSettlerAccessControl() public {
        address stranger = makeAddr("stranger-revoke");
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                stranger,
                SETTLER_REVOKER_ROLE
            )
        );
        vm.prank(stranger);
        factory.revokeSettler(makeAddr("target"));
    }

    /// @notice Pins behaviour: blocklist Events Removed.
    function test_blocklistEventsRemoved() public {
        ExactSettler s = _newSettler(factory);
        vm.recordLogs();
        factory.approveSettler(address(s));
        factory.revokeSettler(address(s));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 blocked = keccak256("SettlerBlocked(address)");
        bytes32 unblocked = keccak256("SettlerUnblocked(address)");
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length == 0) {
                continue;
            }
            assertTrue(
                logs[i].topics[0] != blocked, "legacy SettlerBlocked topic must not be emitted"
            );
            assertTrue(
                logs[i].topics[0] != unblocked, "legacy SettlerUnblocked topic must not be emitted"
            );
        }
    }

    /// @notice Pins behaviour: approved Settlers View Returns True.
    function test_approvedSettlersViewReturnsTrue() public {
        ExactSettler s = _newSettler(factory);
        factory.approveSettler(address(s));
        assertTrue(factory.approvedSettlers(address(s)));
    }

    /// @notice Pins behaviour: approved Settlers View Returns False.
    function test_approvedSettlersViewReturnsFalse() public {
        ExactSettler s = _newSettler(factory);
        factory.approveSettler(address(s));
        factory.revokeSettler(address(s));
        assertFalse(factory.approvedSettlers(address(s)));
    }

    /// @notice Pins behaviour: approved Settlers View Returns False For Unknown.
    function test_approvedSettlersViewReturnsFalseForUnknown() public {
        address unknown = makeAddr("unknown");
        assertFalse(factory.approvedSettlers(unknown));
    }

    /// @notice Pins the v3 ERC-7201 namespace slot for `FactoryStorage`. Storage layout
    ///         changes intentionally bump the namespace name; this test must be updated in
    ///         lockstep with the constant in `src/CorkRolloverContractFactory.sol`.
    function test_storage_factoryNamespaceSlotV3() public pure {
        bytes32 expected = keccak256(abi.encode(uint256(keccak256("cork.factory.storage.v3")) - 1))
            & ~bytes32(uint256(0xff));
        assertEq(expected, FACTORY_NAMESPACE_SLOT);
    }
}
