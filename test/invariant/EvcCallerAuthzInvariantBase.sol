// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../base/BaseTest.sol";
import { MockEVC } from "../mocks/MockEVC.sol";
import { EvcCallerAuthzHandler, IEvcCallerAuthzDriver } from "./handlers/EvcCallerAuthzHandler.sol";
import { ISignatureTransfer } from "permit2/interfaces/ISignatureTransfer.sol";
import { EvcRolloverAdapter, IEVC } from "src/EvcRolloverAdapter.sol";
import { ISettler } from "src/interfaces/settlers/ISettler.sol";

/// @notice Test harness exposing EvcRolloverAdapter's load-bearing EVC gate.
contract EvcCallerAuthzGateHarness is EvcRolloverAdapter {
    /// @param evc_ EVC contract.
    /// @param controller_ Controller address whose context gates entry.
    /// @param exactSettler_ Exact-mode Settler address.
    /// @param partialSettler_ Partial-mode Settler address.
    /// @param permit2_ Permit2 instance required by the adapter constructor.
    constructor(
        IEVC evc_,
        address controller_,
        ISettler exactSettler_,
        ISettler partialSettler_,
        ISignatureTransfer permit2_
    ) EvcRolloverAdapter(evc_, controller_, exactSettler_, partialSettler_, permit2_) { }

    /// @notice Expose `_gateEvc` for focused invariant probing.
    /// @param subaccount Job subaccount submitted to the gate.
    function probeGate(address subaccount) external view {
        _gateEvc(subaccount);
    }
}

/// @notice Shared active driver for the EVC caller-authorization invariant suites.
abstract contract EvcCallerAuthzInvariantBase is BaseTest, IEvcCallerAuthzDriver {
    /// @notice Controller wired into the gate harness.
    address internal constant EVC_AUTHZ_CONTROLLER = address(0xC011704);
    /// @notice Wrong controller used to fuzz controller-address mismatches.
    address internal constant EVC_AUTHZ_WRONG_CONTROLLER = address(0xBADC0117);

    /// @notice Faithful EVC mock used by the handler.
    MockEVC internal evcAuthzMock;
    /// @notice Gate harness under test.
    EvcCallerAuthzGateHarness internal evcAuthzHarness;
    /// @notice Active handler.
    EvcCallerAuthzHandler internal evcAuthzHandler;

    /// @notice Sets up the active EVC authorization handler and targets its actions.
    function _setUpEvcCallerAuthzInvariant() internal {
        evcAuthzMock = new MockEVC();
        evcAuthzHarness = new EvcCallerAuthzGateHarness(
            IEVC(address(evcAuthzMock)),
            EVC_AUTHZ_CONTROLLER,
            ISettler(address(settler)),
            ISettler(address(partialSettler)),
            ISignatureTransfer(address(permit2))
        );

        evcAuthzHandler = new EvcCallerAuthzHandler(IEvcCallerAuthzDriver(address(this)));
        targetContract(address(evcAuthzHandler));
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = evcAuthzHandler.probeGate.selector;
        selectors[1] = evcAuthzHandler.probeDirectCaller.selector;
        selectors[2] = evcAuthzHandler.probeAuthorizedEvc.selector;
        selectors[3] = evcAuthzHandler.probeBadEvcFrame.selector;
        targetSelector(FuzzSelector({ addr: address(evcAuthzHandler), selectors: selectors }));
    }

    /// @inheritdoc IEvcCallerAuthzDriver
    function driveEvcCallerAuthzProbe(
        uint256 subSeed,
        uint256 frameSeed,
        uint256 callerSeed,
        bool viaEvc,
        bool matchingFrame,
        bool controllerEnabled,
        bool controllerMatches,
        bool trailingSuffix
    ) external returns (bool accepted, bool authorized) {
        require(msg.sender == address(evcAuthzHandler), "EVCAuthz: only handler");

        address subaccount = _derivedAccount("evc-authz-subaccount", subSeed);
        address onBehalf = matchingFrame
            ? subaccount
            : _distinctAccount("evc-authz-onbehalf", frameSeed, subaccount);
        address frameController =
            controllerMatches ? EVC_AUTHZ_CONTROLLER : EVC_AUTHZ_WRONG_CONTROLLER;
        address directCaller =
            _distinctAccount("evc-authz-caller", callerSeed, address(evcAuthzMock));

        evcAuthzMock.setFrame(onBehalf, controllerEnabled, frameController);
        bytes memory payload = _probePayload(subaccount, trailingSuffix, callerSeed);

        if (viaEvc) {
            vm.prank(address(evcAuthzMock));
        } else {
            vm.prank(directCaller);
        }
        (accepted,) = address(evcAuthzHarness).call(payload);

        authorized = viaEvc && matchingFrame && controllerEnabled && controllerMatches;
    }

    function _probePayload(address subaccount, bool trailingSuffix, uint256 suffixSeed)
        internal
        pure
        returns (bytes memory payload)
    {
        payload = abi.encodeCall(EvcCallerAuthzGateHarness.probeGate, (subaccount));
        if (trailingSuffix) {
            payload = bytes.concat(payload, abi.encodePacked(_suffix(suffixSeed)));
        }
    }

    function _derivedAccount(string memory salt, uint256 seed) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(salt, seed))) | 1));
    }

    function _distinctAccount(string memory salt, uint256 seed, address avoid)
        internal
        pure
        returns (address account)
    {
        account = _derivedAccount(salt, seed);
        if (account == avoid) {
            account = _derivedAccount(salt, seed + 1);
        }
    }

    function _suffix(uint256 seed) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("evc-authz-suffix", seed));
    }
}
