// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;
/// @notice IERC20DrainLike interface.

interface IERC20DrainLike {
    /// @notice Transfer.
    /// @param to Destination address.
    /// @param amount Token amount (raw units).
    /// @return Return value.
    function transfer(address to, uint256 amount) external returns (bool);
    /// @notice Balance of.
    /// @param who Subject address.
    /// @return Return value.

    function balanceOf(address who) external view returns (uint256);
}

/// @notice Mock rolloverContract module that drains dstCST out of the rolloverContract mid-rollover, used to trip INV-DSTCST-FLOOR / INV-5 guards.
contract DstCstDrainModule {
    /// @notice Execute.
    /// @param dstCst dstCST token contract.
    /// @param attacker Attacker address (test scenario).
    /// @param drainAmount Drain amount used by the adversarial scenario.
    function execute(address dstCst, address attacker, uint256 drainAmount) external {
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        require(IERC20DrainLike(dstCst).transfer(attacker, drainAmount), "drain");
    }
}
