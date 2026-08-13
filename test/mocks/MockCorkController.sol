// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { MockERC20 } from "./MockERC20.sol";
import { MockCpt, MockPhoenixPoolManager } from "./MockPhoenix.sol";
import { IDefaultCorkController } from "src/interfaces/external/phoenix/IDefaultCorkController.sol";
import { MarketId } from "src/interfaces/external/phoenix/IPoolManager.sol";

/// @notice Minimal stand-in for Phoenix's `DefaultCorkController`, carrying only the two things
///         just-in-time market creation depends on: the pool-creator role gate and `createNewPool`.
/// @dev The real controller forwards to `CorkPoolManager` and the whitelist manager. Here creation
///      binds the pool inside `MockPhoenixPoolManager` using a token triple the test registered in
///      advance, which is what makes a market "exist" for the rest of the suite.
contract MockCorkController is IDefaultCorkController {
    /// @notice Reverts when a caller without the pool-creator role tries to create a pool.
    /// @param caller The rejected caller.
    error MockCorkController__MissingPoolCreatorRole(address caller);

    /// @notice Role gating `createNewPool`, matching the real controller's identifier.
    /// @return POOL_CREATOR_ROLE Stored role identifier.
    bytes32 public constant POOL_CREATOR_ROLE = keccak256("POOL_CREATOR_ROLE");

    /// @notice Pool manager pools are bound into on creation.
    /// @return POOL_MANAGER Stored pool manager value.
    MockPhoenixPoolManager public immutable POOL_MANAGER;

    /// @notice Whether an account holds `POOL_CREATOR_ROLE`.
    /// @return granted Stored role flag.
    mapping(address account => bool granted) public hasPoolCreatorRole;

    /// @notice Number of pools created through this controller.
    /// @return createCallCount Stored creation count.
    uint256 public createCallCount;

    /// @notice Token triple a pool is bound to when it is created.
    /// @param cst Cork Swap Token (cST) for the pool.
    /// @param cpt Cork Principal Token (cPT) for the pool.
    /// @param ca Collateral asset (CA) for the pool.
    /// @param set Whether the test registered this binding.
    struct PendingBinding {
        MockERC20 cst;
        MockCpt cpt;
        MockERC20 ca;
        bool set;
    }

    /// @notice Pending token bindings keyed by the pool identifier.
    mapping(bytes32 poolId => PendingBinding binding) internal _bindings;
    /// @notice Parameters supplied to the most recent pool creation.
    PoolCreationParams internal _lastParams;

    /// @param poolManager_ Pool manager created pools are bound into.
    constructor(MockPhoenixPoolManager poolManager_) {
        POOL_MANAGER = poolManager_;
    }

    /// @notice Grant or revoke the pool-creator role.
    /// @param account Account to change.
    /// @param granted Whether the account holds the role.
    function setPoolCreatorRole(address account, bool granted) external {
        hasPoolCreatorRole[account] = granted;
    }

    /// @notice Register the tokens a pool is bound to once it is created.
    /// @param poolId Pool id the binding applies to.
    /// @param cst Cork Swap Token (cST) for the pool.
    /// @param cpt Cork Principal Token (cPT) for the pool.
    /// @param ca Collateral asset (CA) for the pool.
    function registerBinding(bytes32 poolId, MockERC20 cst, MockCpt cpt, MockERC20 ca) external {
        _bindings[poolId] = PendingBinding({ cst: cst, cpt: cpt, ca: ca, set: true });
    }

    /// @notice Create a Phoenix pool. Caller must hold `POOL_CREATOR_ROLE`.
    /// @param params Pool creation parameters.
    function createNewPool(PoolCreationParams calldata params) external {
        if (!hasPoolCreatorRole[msg.sender]) {
            revert MockCorkController__MissingPoolCreatorRole(msg.sender);
        }

        _lastParams = params;
        ++createCallCount;

        bytes32 poolId = keccak256(abi.encode(params.pool));
        PendingBinding storage binding = _bindings[poolId];
        if (binding.set) {
            POOL_MANAGER.bind(MarketId.wrap(poolId), binding.cst, binding.cpt, binding.ca);
        }
    }

    /// @notice Parameters the most recent `createNewPool` call carried.
    /// @return params Stored creation parameters.
    function lastParams() external view returns (PoolCreationParams memory params) {
        return _lastParams;
    }
}
