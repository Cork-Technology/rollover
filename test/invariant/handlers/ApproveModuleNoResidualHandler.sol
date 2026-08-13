// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { CommonBase } from "forge-std/Base.sol";
import { StdCheats } from "forge-std/StdCheats.sol";
import { StdUtils } from "forge-std/StdUtils.sol";
import { ApproveModule } from "src/modules/ApproveModule.sol";

/// @notice Delegatecall host that mirrors the rolloverContract module invocation shape.
contract ApproveModuleNoResidualHost {
    /// @notice Delegatecall `module` with `data` and bubble returndata on revert.
    /// @param module Module address to delegatecall.
    /// @param data ABI encoded module calldata.
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

/// @notice Actor spender used to observe and optionally consume the bracketed allowance.
contract ApproveModuleNoResidualSpender {
    /// @notice Token whose allowance is observed during calls.
    IERC20 public token;
    /// @notice Host address that owns the allowance under delegatecall.
    address public approver;
    /// @notice Last selector received by `consume` or fallback.
    bytes4 public lastSelector;
    /// @notice Last host-to-this allowance observed inside the spender call.
    uint256 public lastObservedAllowance;
    /// @notice Amount to pull through `transferFrom` during `consume`.
    uint256 public pullAmount;
    /// @notice Whether the next spender entrypoint should revert.
    bool public shouldRevert;
    /// @notice Revert data emitted when `shouldRevert` is true.
    bytes public revertData;

    /// @notice Configure the spender for one handler step.
    /// @param _token Token whose allowance is observed.
    /// @param _approver Host address that owns the allowance.
    // Invariant spender is reconfigured with fuzz-selected handler tokens.
    // forge-lint: disable-next-line(missing-zero-check)
    function configure(IERC20 _token, address _approver) external {
        token = _token;
        approver = _approver;
    }

    /// @notice Configure optional revert behavior.
    /// @param _shouldRevert Whether calls should revert.
    /// @param _revertData Data to return on revert.
    function setRevert(bool _shouldRevert, bytes calldata _revertData) external {
        shouldRevert = _shouldRevert;
        revertData = _revertData;
    }

    /// @notice Configure optional allowance consumption.
    /// @param _pullAmount Amount to transfer from the host during `consume`.
    function setPull(uint256 _pullAmount) external {
        pullAmount = _pullAmount;
    }

    /// @notice Selector-compatible entrypoint for `ApproveModule.execute`.
    /// @param amountHint Amount forwarded by the module.
    function consume(uint256 amountHint) external {
        amountHint;
        lastSelector = this.consume.selector;
        lastObservedAllowance = token.allowance(approver, address(this));
        _maybeRevert();
        if (pullAmount > 0) {
            require(token.transferFrom(approver, address(this), pullAmount), "pull failed");
        }
    }

    /// @notice Fallback entrypoint for zero or arbitrary selectors.
    fallback() external {
        lastSelector = msg.sig;
        lastObservedAllowance = token.allowance(approver, address(this));
        _maybeRevert();
    }

    /// @notice Revert with configured returndata when requested.
    function _maybeRevert() internal view {
        if (!shouldRevert) {
            return;
        }
        bytes memory data = revertData;
        assembly {
            revert(add(data, 32), mload(data))
        }
    }
}

/// @notice INV-APPROVE-MODULE-NO-RESIDUAL handler — drives delegate-invoked approve brackets
///         across success, spender-revert, zero-selector, fallback-selector, and pull paths.
/// @custom:invariant INV-APPROVE-MODULE-NO-RESIDUAL
contract ApproveModuleNoResidualHandler is CommonBase, StdCheats, StdUtils {
    /// @notice Number of token actors in the handler pool.
    uint256 internal constant TOKEN_COUNT = 3;
    /// @notice Number of spender actors in the handler pool.
    uint256 internal constant SPENDER_COUNT = 4;
    /// @notice Maximum bounded approval amount.
    uint256 internal constant MAX_AMOUNT = 1_000_000e18;
    /// @notice ObservedPair test fixture data.

    struct ObservedPair {
        ERC20Mock token;
        address spender;
    }

    /// @notice Module under test.
    ApproveModule public immutable module;
    /// @notice Delegatecall host whose allowance must not retain residue.
    ApproveModuleNoResidualHost public immutable host;
    /// @notice Ghost flag set when any observed `(token, spender)` allowance remains nonzero.
    bool public residualAllowanceObserved;
    /// @notice Number of delegatecall bracket attempts.
    uint256 public ghostExecutions;
    /// @notice Number of bracket attempts that completed successfully.
    uint256 public ghostSuccesses;
    /// @notice Number of bracket attempts that reverted and were observed by the handler.
    uint256 public ghostReverts;
    /// @notice Largest residual allowance observed after a bracket attempt.
    uint256 public ghostMaxResidualAllowance;
    /// @notice Token actor pool.
    ERC20Mock[] internal tokens;
    /// @notice Spender actor pool.
    ApproveModuleNoResidualSpender[] internal spenders;
    /// @notice Observed token/spender pairs.
    ObservedPair[] internal observedPairs;
    /// @notice Whether a token/spender pair has already been recorded.
    mapping(address token => mapping(address spender => bool seen)) internal pairSeen;

    /// @notice Deploy a small token/spender actor pool for invariant campaigns.
    constructor() {
        module = new ApproveModule();
        host = new ApproveModuleNoResidualHost();
        for (uint256 i = 0; i < TOKEN_COUNT; ++i) {
            tokens.push(new ERC20Mock());
        }
        for (uint256 i = 0; i < SPENDER_COUNT; ++i) {
            spenders.push(new ApproveModuleNoResidualSpender());
        }
    }

    /// @notice Number of distinct `(token, spender)` pairs observed by the handler.
    /// @return Number of observed pairs.
    function observedPairCount() external view returns (uint256) {
        return observedPairs.length;
    }

    /// @notice Handler action: execute one fuzz-selected approve bracket through delegatecall.
    /// @param tokenSeed Seed selecting the token actor.
    /// @param spenderSeed Seed selecting the spender actor.
    /// @param amountSeed Raw amount seed, bounded to `MAX_AMOUNT`.
    /// @param selectorSeed Seed selecting consume, zero, or arbitrary fallback selector.
    /// @param behaviorSeed Seed selecting call success versus call revert.
    /// @param pullSeed Raw pull seed, bounded to the approved amount on consume success paths.
    /// @param revertSeed Seed used to derive spender revert data.
    function executeBracket(
        uint256 tokenSeed,
        uint256 spenderSeed,
        uint256 amountSeed,
        uint256 selectorSeed,
        uint256 behaviorSeed,
        uint256 pullSeed,
        bytes32 revertSeed
    ) external {
        ERC20Mock token = tokens[tokenSeed % tokens.length];
        ApproveModuleNoResidualSpender spender = spenders[spenderSeed % spenders.length];
        uint256 amount = bound(amountSeed, 0, MAX_AMOUNT);
        bytes4 selector = _selector(selectorSeed);
        bool callShouldRevert = behaviorSeed & 1 == 1;
        uint256 pullAmount = selector == spender.consume.selector && !callShouldRevert
            ? bound(pullSeed, 0, amount)
            : 0;

        _registerPair(address(token), address(spender));
        token.mint(address(host), amount);
        spender.configure(IERC20(address(token)), address(host));
        spender.setPull(pullAmount);
        spender.setRevert(callShouldRevert, abi.encodeWithSelector(bytes4(revertSeed), revertSeed));

        try host.exec(
            address(module),
            abi.encodeCall(
                ApproveModule.execute, (IERC20(address(token)), address(spender), selector, amount)
            )
        ) {
            ghostSuccesses++;
        } catch {
            ghostReverts++;
        }

        ghostExecutions++;
        _observeAllowance(token, address(spender));
    }

    /// @notice Handler action: probe zero-spender revert path through delegatecall.
    /// @param tokenSeed Seed selecting the token actor.
    /// @param amountSeed Raw amount seed, bounded to `MAX_AMOUNT`.
    function executeZeroSpender(uint256 tokenSeed, uint256 amountSeed) external {
        ERC20Mock token = tokens[tokenSeed % tokens.length];
        uint256 amount = bound(amountSeed, 0, MAX_AMOUNT);
        _registerPair(address(token), address(0));

        try host.exec(
            address(module),
            abi.encodeCall(
                ApproveModule.execute,
                (
                    IERC20(address(token)),
                    address(0),
                    ApproveModuleNoResidualSpender.consume.selector,
                    amount
                )
            )
        ) {
            ghostSuccesses++;
        } catch {
            ghostReverts++;
        }

        ghostExecutions++;
        _observeAllowance(token, address(0));
    }

    /// @notice Observe all pairs seen so far. Useful for invariant assertions after a run.
    function observeAllPairs() external {
        for (uint256 i = 0; i < observedPairs.length; ++i) {
            ObservedPair memory pair = observedPairs[i];
            _observeAllowance(pair.token, pair.spender);
        }
    }

    function _selector(uint256 seed) internal pure returns (bytes4) {
        uint256 mode = seed % 4;
        if (mode == 0) {
            return ApproveModuleNoResidualSpender.consume.selector;
        }
        if (mode == 1) {
            return bytes4(0);
        }
        if (mode == 2) {
            return bytes4(keccak256(abi.encode("fallback", seed)));
        }
        return bytes4(0xffffffff);
    }

    function _registerPair(address token, address spender) internal {
        if (pairSeen[token][spender]) {
            return;
        }
        pairSeen[token][spender] = true;
        observedPairs.push(ObservedPair({ token: ERC20Mock(token), spender: spender }));
    }

    function _observeAllowance(ERC20Mock token, address spender) internal {
        uint256 allowance = token.allowance(address(host), spender);
        if (allowance == 0) {
            return;
        }
        residualAllowanceObserved = true;
        if (allowance > ghostMaxResidualAllowance) {
            ghostMaxResidualAllowance = allowance;
        }
    }
}
