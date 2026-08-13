// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;
/// @notice IMintable interface.

interface IMintable {
    /// @notice Mint.
    /// @param to Destination address.
    /// @param amount Token amount (raw units).
    function mint(address to, uint256 amount) external;
}

/// @notice Mock rolloverContract mid-rollover module that mints dstCST into the rolloverContract to simulate a normal phoenix deposit leg.
contract RolloverDepositModule {
    /// @notice Execute.
    /// @param token Ignored source token argument.
    /// @param dstCst dstCST token contract.
    /// @param amount Ignored source amount argument.
    /// @param dstAmount dstCST amount.
    function execute(address token, address dstCst, uint256 amount, uint256 dstAmount) external {
        token;
        amount;
        IMintable(dstCst).mint(address(this), dstAmount);
    }
}
