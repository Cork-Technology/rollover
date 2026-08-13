// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { IPoolManager, MarketId } from "src/interfaces/external/phoenix/IPoolManager.sol";

/// @notice Mock of a Phoenix PoolShare-shaped ERC20 (with poolId, expiry, and poolManager getters) for RolloverContract and Settler tests.
contract MockERC20 {
    /// @notice Name.
    /// @return name Stored name value.
    string public name;
    /// @notice Symbol.
    /// @return symbol Stored symbol value.

    string public symbol;
    /// @notice Decimals.
    /// @return decimals Stored decimals value.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)

    uint8 public immutable decimals;
    /// @notice Total supply.
    /// @return totalSupply Stored total supply value.

    uint256 public totalSupply;
    /// @notice Balance of.
    /// @return balanceOf Stored balance of value.

    mapping(address => uint256) public balanceOf;
    /// @notice Allowance.
    /// @return allowance Stored allowance value.

    mapping(address => mapping(address => uint256)) public allowance;
    /// @notice  pool id.

    MarketId private _poolId;
    /// @notice  expiry.

    uint256 private _expiry = type(uint64).max;
    /// @notice  pool manager.

    IPoolManager private _poolManager;
    /// @notice Emitted on transfer.
    /// @param from Source address.
    /// @param to Destination address.
    /// @param value Numeric value.

    event Transfer(address indexed from, address indexed to, uint256 value);
    /// @notice Emitted on approval.
    /// @param owner Owner address.
    /// @param spender Spender address.
    /// @param value Numeric value.

    event Approval(address indexed owner, address indexed spender, uint256 value);
    /// @param n Count or size value.
    /// @param s String value or scratch value.
    /// @param d Generic input.

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
        _poolId = MarketId.wrap(keccak256(abi.encodePacked(address(this))));
    }
    /// @notice Pool id.
    /// @return Return value.

    function poolId() external view returns (MarketId) {
        return _poolId;
    }
    /// @notice Sets pool id.
    /// @param id Identifier.

    function setPoolId(MarketId id) external {
        _poolId = id;
    }
    /// @notice Expiry.
    /// @return expiryTimestamp Pool expiry timestamp.

    function expiry() external view returns (uint256 expiryTimestamp) {
        return _expiry;
    }
    /// @notice Sets expiry.
    /// @param expiryTimestamp Pool expiry timestamp.

    function setExpiry(uint256 expiryTimestamp) external {
        _expiry = expiryTimestamp;
    }
    /// @notice Pool manager.
    /// @return Return value.

    function poolManager() external view returns (IPoolManager) {
        return _poolManager;
    }
    /// @notice Sets pool manager.
    /// @param m Generic input.

    function setPoolManager(IPoolManager m) external {
        _poolManager = m;
    }
    /// @notice Mint.
    /// @param to Destination address.
    /// @param amount Token amount (raw units).

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }
    /// @notice Burn.
    /// @param from Source address.
    /// @param amount Token amount (raw units).

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }
    /// @notice Transfer.
    /// @param to Destination address.
    /// @param amount Token amount (raw units).
    /// @return Return value.

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }
    /// @notice Transfer from.
    /// @param from Source address.
    /// @param to Destination address.
    /// @param amount Token amount (raw units).
    /// @return Return value.

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            allowance[from][msg.sender] = a - amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
    /// @notice Approve.
    /// @param spender Spender address.
    /// @param amount Token amount (raw units).
    /// @return Return value.

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
}
