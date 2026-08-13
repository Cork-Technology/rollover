// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import { ERC20NoReturnMock } from "@openzeppelin/contracts/mocks/token/ERC20NoReturnMock.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import {
    ApproveModule,
    ApproveModule__SpenderCallFailed,
    ApproveModule__ZeroSpender
} from "src/modules/ApproveModule.sol";

/// @notice Spender that returns an oversized returndata blob on success.
contract BombReturnSpender {
    /// @notice Selector consumed by ApproveModule under the 4-arg signature.
    /// @param amount Amount forwarded by ApproveModule (unused).
    function consume(uint256 amount) external pure {
        amount;
        bytes memory bomb = new bytes(4096);
        assembly {
            return(add(bomb, 32), mload(bomb))
        }
    }
}

/// @notice Spender that reverts with oversized returndata.
contract BombRevertSpender {
    /// @notice Selector consumed by ApproveModule under the 4-arg signature.
    /// @param amount Amount forwarded by ApproveModule (unused).
    function consume(uint256 amount) external pure {
        amount;
        bytes memory bomb = new bytes(4096);
        assembly {
            revert(add(bomb, 32), mload(bomb))
        }
    }
}

/// @notice ERC-20 whose `approve` returns no returndata (legacy no-return token).
contract NoReturnApproveToken is ERC20NoReturnMock {
    /// @notice Deploy with a large balance minted to `recipient`.
    /// @param recipient Address that receives the initial mint.
    constructor(address recipient) ERC20("NoReturn", "NR") {
        _mint(recipient, type(uint256).max);
    }
}

/// @notice USDT-style token: changing a non-zero allowance to another non-zero value fails.
contract UsdtStyleApproveToken {
    /// @notice Allowance ledger keyed by owner and spender.
    mapping(address => mapping(address => uint256)) private _allowance;

    /// @notice ERC-20 allowance view.
    /// @param owner Token owner.
    /// @param spender Spender address.
    /// @return Allowance amount.
    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowance[owner][spender];
    }

    /// @notice Fails on non-zero→non-zero transitions; otherwise sets allowance and returns true.
    /// @param spender Spender address.
    /// @param amount Approval amount.
    /// @return True when the transition is allowed.
    function approve(address spender, uint256 amount) external returns (bool) {
        uint256 current = _allowance[msg.sender][spender];
        if (amount != 0 && current != 0) {
            return false;
        }
        _allowance[msg.sender][spender] = amount;
        return true;
    }

    /// @notice Stub balance for harness compatibility.
    /// @param account Account address (unused).
    /// @return Always max uint256.
    function balanceOf(address account) external pure returns (uint256) {
        account;
        return type(uint256).max;
    }
}

/// @notice Spender that records how many times `consume` was invoked.
contract ProbeSpender {
    /// @notice Number of successful `consume` invocations.
    uint256 public calls;

    /// @notice Selector consumed by ApproveModule under the 4-arg signature.
    /// @param amountHint Amount forwarded by ApproveModule (unused).
    function consume(uint256 amountHint) external {
        amountHint;
        calls++;
    }
}

/// @title MockSpender
/// @notice Records the allowance it observed when its handler ran and optionally pulls a partial
///         or full balance back through `transferFrom`. Used by the atomic-bracket suite to
///         prove the approve+call+revoke sequence executes in a single frame and that allowance
///         is zero on both the success and revert exit paths.
contract MockSpender {
    /// @notice Token whose allowance is observed during `consume`.
    IERC20 public token;
    /// @notice Address that approved this spender (the delegating host under delegatecall).
    address public approver;
    /// @notice Allowance read by the most recent `consume` invocation.
    uint256 public lastObservedAllowance;
    /// @notice Amount to pull via `transferFrom` on the next `consume` call.
    uint256 public pullAmount;
    /// @notice When true, the next `consume` call reverts with `revertData`.
    bool public shouldRevert;
    /// @notice Returndata used when `shouldRevert` is true.
    bytes public revertData;
    /// @notice Selector observed on the most recent invocation (fallback or `consume`).
    bytes4 public lastSelector;

    /// @notice Configure the spender against a token + approving address (the delegating host).
    /// @param _token Token whose allowance the spender will observe.
    /// @param _approver Address that will hold the allowance under delegatecall (the host).
    // Test spender is configured with arbitrary harness addresses.
    // forge-lint: disable-next-line(missing-zero-check)
    function configure(IERC20 _token, address _approver) external {
        token = _token;
        approver = _approver;
    }

    /// @notice Direct the next call to revert with `data`.
    /// @param _revert If true, the next `consume` call reverts.
    /// @param _data Revert returndata to emit.
    function setRevert(bool _revert, bytes calldata _data) external {
        shouldRevert = _revert;
        revertData = _data;
    }

    /// @notice Direct the next call to pull `amount` via `transferFrom`.
    /// @param _amount Amount to pull when `consume` is invoked.
    function setPull(uint256 _amount) external {
        pullAmount = _amount;
    }

    /// @notice Selector consumed by ApproveModule under the 4-arg signature.
    /// @dev Records the allowance at entry and optionally pulls funds.
    /// @param amountHint Ignored amount hint used to exercise selector encoding.
    function consume(uint256 amountHint) external {
        amountHint;
        lastSelector = this.consume.selector;
        lastObservedAllowance = token.allowance(approver, address(this));
        if (shouldRevert) {
            bytes memory d = revertData;
            assembly {
                revert(add(d, 32), mload(d))
            }
        }
        if (pullAmount > 0) {
            require(token.transferFrom(approver, address(this), pullAmount), "pull failed");
        }
    }

    /// @notice Default fallback used when a zero/unmatched selector is passed.
    fallback() external {
        lastSelector = msg.sig;
        lastObservedAllowance = token.allowance(approver, address(this));
    }
}

/// @title DelegatingHost
/// @notice Tiny harness that mirrors `CorkRolloverContract._executeIntentCalls`'s delegatecall shape so
///         module functions can be invoked from a delegating frame in unit tests.
contract DelegatingHost {
    /// @notice Delegatecall `module` with the provided calldata. Bubbles up the underlying
    ///         revert reason unchanged so callers can `vm.expectRevert` against the module's
    ///         own error selectors.
    /// @param module Module address to delegatecall.
    /// @param data ABI-encoded calldata to forward.
    /// @return ret Raw returndata from the successful delegatecall.
    // Delegatecall harness accepts arbitrary module targets by construction.
    // forge-lint: disable-next-line(missing-zero-check)
    function exec(address module, bytes calldata data) external returns (bytes memory ret) {
        bool ok;
        (ok, ret) = module.delegatecall(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }
}

/// @title ApproveModuleAtomicBracketTest
/// @notice Pins atomic-bracket invariants on `ApproveModule.execute` (`SafeERC20.forceApprove`).
contract ApproveModuleAtomicBracketTest is Test {
    /// @notice Event topic used to detect completed approve module brackets in logs.
    bytes32 private constant APPROVE_MODULE_EXECUTED_TOPIC =
        keccak256("ApproveModuleExecuted(address,address,address,bytes4,uint256)");

    /// @notice Mirror of `ApproveModuleExecuted` for `vm.expectEmit`.
    /// @param executor Delegatecall host whose token allowance was bracketed.
    /// @param token ERC-20 token whose allowance was granted then revoked.
    /// @param spender Spender approved and called by the bracket.
    /// @param selector Selector invoked on `spender`.
    /// @param amount Allowance amount granted for the spender call.
    event ApproveModuleExecuted(
        address indexed executor,
        address indexed token,
        address indexed spender,
        bytes4 selector,
        uint256 amount
    );

    /// @notice Module under test.
    ApproveModule internal module;
    /// @notice Delegating host that invokes the module via delegatecall.
    DelegatingHost internal host;
    /// @notice Test ERC-20 used throughout the suite.
    ERC20Mock internal token;
    /// @notice Mock spender that receives the bracketed call.
    MockSpender internal spender;

    /// @notice Standard set-up.
    function setUp() public {
        module = new ApproveModule();
        host = new DelegatingHost();
        token = new ERC20Mock();
        spender = new MockSpender();
        spender.configure(IERC20(address(token)), address(host));
        token.mint(address(host), 1_000e18);
    }

    /// @notice Pins behaviour: approve, call spender, then revoke — all in one delegatecall frame.
    function test_execute_approves_calls_revokes_in_one_frame() public {
        vm.expectEmit(true, true, true, true, address(host));
        emit ApproveModuleExecuted(
            address(host), address(token), address(spender), MockSpender.consume.selector, 100e18
        );
        host.exec(
            address(module),
            abi.encodeCall(
                ApproveModule.execute,
                (IERC20(address(token)), address(spender), MockSpender.consume.selector, 100e18)
            )
        );
        assertEq(spender.lastObservedAllowance(), 100e18, "spender saw mid-bracket allowance");
        assertEq(token.allowance(address(host), address(spender)), 0, "allowance revoked at end");
    }

    /// @notice Pins behaviour: zero spender reverts before any approval.
    function test_execute_zeroSpender_reverts() public {
        vm.expectRevert(ApproveModule__ZeroSpender.selector);
        host.exec(
            address(module),
            abi.encodeCall(
                ApproveModule.execute,
                (IERC20(address(token)), address(0), MockSpender.consume.selector, 1e18)
            )
        );
    }

    /// @notice Pins behaviour: spender revert propagates as ApproveModule__SpenderCallFailed
    ///         AND allowance is zero on the revert path.
    function test_execute_spender_call_revert_reverts_whole_bracket() public {
        bytes memory rd = hex"deadbeef";
        spender.setRevert(true, rd);
        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSelector(ApproveModule__SpenderCallFailed.selector, rd));
        host.exec(
            address(module),
            abi.encodeCall(
                ApproveModule.execute,
                (IERC20(address(token)), address(spender), MockSpender.consume.selector, 100e18)
            )
        );
        assertEq(
            token.allowance(address(host), address(spender)),
            0,
            "no residual allowance after revert"
        );
        assertFalse(
            _hasApproveModuleExecutedLog(vm.getRecordedLogs()),
            "reverted bracket must not emit completion"
        );
    }

    /// @notice Pins behaviour: spender consumes full allowance via transferFrom; bracket revokes.
    function test_execute_spender_call_consumes_full_allowance() public {
        spender.setPull(100e18);
        host.exec(
            address(module),
            abi.encodeCall(
                ApproveModule.execute,
                (IERC20(address(token)), address(spender), MockSpender.consume.selector, 100e18)
            )
        );
        assertEq(token.balanceOf(address(spender)), 100e18, "spender pulled full amount");
        assertEq(token.allowance(address(host), address(spender)), 0, "allowance revoked");
    }

    /// @notice Pins behaviour: spender pulls partial; bracket revokes the remaining allowance.
    function test_execute_spender_call_consumes_partial_allowance() public {
        spender.setPull(40e18);
        host.exec(
            address(module),
            abi.encodeCall(
                ApproveModule.execute,
                (IERC20(address(token)), address(spender), MockSpender.consume.selector, 100e18)
            )
        );
        assertEq(token.balanceOf(address(spender)), 40e18, "spender pulled partial");
        assertEq(token.allowance(address(host), address(spender)), 0, "residual allowance revoked");
    }

    /// @notice Oversized spender success returndata is discarded; bracket still revokes allowance.
    function test_execute_spenderOversizedReturn_completesAndRevokes() public {
        BombReturnSpender bombSpender = new BombReturnSpender();
        host.exec(
            address(module),
            abi.encodeCall(
                ApproveModule.execute,
                (
                    IERC20(address(token)),
                    address(bombSpender),
                    BombReturnSpender.consume.selector,
                    1e18
                )
            )
        );
        assertEq(token.allowance(address(host), address(bombSpender)), 0, "allowance revoked");
    }

    /// @notice Oversized spender revert returndata is capped in `ApproveModule__SpenderCallFailed`.
    function test_execute_spenderOversizedRevert_cappedReturndata() public {
        BombRevertSpender bombSpender = new BombRevertSpender();
        bytes memory err = _captureHostRevert(
            abi.encodeCall(
                ApproveModule.execute,
                (
                    IERC20(address(token)),
                    address(bombSpender),
                    BombRevertSpender.consume.selector,
                    1e18
                )
            )
        );
        // Custom-error selector is always the first 4 bytes of revert data.
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(bytes4(err), ApproveModule__SpenderCallFailed.selector, "selector");
        bytes memory embedded = abi.decode(_stripSelector(err), (bytes));
        assertEq(embedded.length, 256, "capped returndata");
        assertEq(token.allowance(address(host), address(bombSpender)), 0, "no residual allowance");
    }

    /// @notice Legacy no-return approve tokens still succeed through SafeERC20.
    function test_execute_noReturnApproveToken_succeedsAndRevokes() public {
        NoReturnApproveToken noReturn = new NoReturnApproveToken(address(host));
        ProbeSpender probe = new ProbeSpender();
        host.exec(
            address(module),
            abi.encodeCall(
                ApproveModule.execute,
                (IERC20(address(noReturn)), address(probe), ProbeSpender.consume.selector, 50e18)
            )
        );
        assertEq(probe.calls(), 1, "spender called");
        assertEq(noReturn.allowance(address(host), address(probe)), 0, "allowance revoked");
    }

    /// @notice USDT-style zero-first retry path succeeds and revokes allowance.
    function test_execute_usdtStyleZeroFirstRetry_succeedsAndRevokes() public {
        UsdtStyleApproveToken usdt = new UsdtStyleApproveToken();
        ProbeSpender probe = new ProbeSpender();
        vm.prank(address(host));
        usdt.approve(address(probe), 1);
        host.exec(
            address(module),
            abi.encodeCall(
                ApproveModule.execute,
                (IERC20(address(usdt)), address(probe), ProbeSpender.consume.selector, 100e18)
            )
        );
        assertEq(probe.calls(), 1, "spender called");
        assertEq(usdt.allowance(address(host), address(probe)), 0, "allowance revoked");
    }

    /// @notice Capture revert data from a delegatecall bracket that is expected to fail.
    /// @param callData ABI-encoded `ApproveModule.execute` calldata forwarded to the host.
    /// @return err Raw revert bytes bubbled from the host.
    function _captureHostRevert(bytes memory callData) internal returns (bytes memory err) {
        try this._execOnHost(callData) { }
        catch (bytes memory revertData) {
            err = revertData;
        }
    }

    /// @notice External wrapper so try/catch can capture the bubbled module revert.
    /// @param callData ABI-encoded `ApproveModule.execute` calldata forwarded to the host.
    function _execOnHost(bytes calldata callData) external {
        host.exec(address(module), callData);
    }

    function _stripSelector(bytes memory data) private pure returns (bytes memory) {
        bytes memory payload = new bytes(data.length - 4);
        for (uint256 i = 0; i < payload.length; ++i) {
            payload[i] = data[i + 4];
        }
        return payload;
    }

    function _hasApproveModuleExecutedLog(Vm.Log[] memory logs) private pure returns (bool) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == APPROVE_MODULE_EXECUTED_TOPIC) {
                return true;
            }
        }
        return false;
    }

    /// @notice Pins behaviour: the INV-APPROVE-MODULE-NO-RESIDUAL invariant holds end-to-end
    ///         under a delegatecall bracket — allowance returns to its pre-bracket value (0).
    function test_execute_via_delegatecall_host_invariant() public {
        uint256 pre = token.allowance(address(host), address(spender));
        host.exec(
            address(module),
            abi.encodeCall(
                ApproveModule.execute,
                (IERC20(address(token)), address(spender), MockSpender.consume.selector, 7e18)
            )
        );
        assertEq(
            token.allowance(address(host), address(spender)),
            pre,
            "allowance returns to pre-bracket value"
        );
    }

    /// @notice Pins behaviour: zero-amount path executes cleanly (approve 0, call, revoke 0).
    function test_execute_zero_amount_no_op_path() public {
        host.exec(
            address(module),
            abi.encodeCall(
                ApproveModule.execute,
                (IERC20(address(token)), address(spender), MockSpender.consume.selector, 0)
            )
        );
        assertEq(token.allowance(address(host), address(spender)), 0, "zero allowance preserved");
    }

    /// @notice Pins behaviour: zero spender is rejected inside the delegatecall module path.
    function testRevert_execute_zeroSpender() public {
        vm.expectRevert(ApproveModule__ZeroSpender.selector);
        host.exec(
            address(module),
            abi.encodeCall(
                ApproveModule.execute,
                (IERC20(address(token)), address(0), MockSpender.consume.selector, 100e18)
            )
        );
    }

    /// @notice Pins behaviour: ApproveAllModule.sol is deleted from the source tree.
    function test_approveAllModule_deleted_regression() public view {
        try this.readApproveAllModuleSource() returns (bool exists) {
            assertFalse(exists, "ApproveAllModule.sol must not exist");
        } catch { }
    }

    /// @notice Helper for the deletion regression test (separate function so try/catch works).
    /// @return True if the deleted source file exists (used to assert it does NOT).
    function readApproveAllModuleSource() external view returns (bool) {
        bytes memory data = vm.readFileBinary("src/modules/ApproveAllModule.sol");
        return data.length > 0;
    }

    /// @notice Pins behaviour: zero selector still propagates faithfully to the spender's
    ///         fallback() handler.
    function test_execute_selector_zero_propagates_to_spender() public {
        host.exec(
            address(module),
            abi.encodeCall(
                ApproveModule.execute, (IERC20(address(token)), address(spender), bytes4(0), 1e18)
            )
        );
        assertEq(spender.lastSelector(), bytes4(0), "selector bytes4(0) propagated");
        assertEq(
            token.allowance(address(host), address(spender)),
            0,
            "allowance revoked post zero-selector"
        );
    }
}
