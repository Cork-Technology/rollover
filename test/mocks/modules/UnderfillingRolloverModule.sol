// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;
/// @notice IMintable interface.

interface IMintable {
    /// @notice Mint.
    /// @param to Destination address.
    /// @param amount Token amount (raw units).
    function mint(address to, uint256 amount) external;
}

/// @notice Mock rolloverContract mid-rollover module that simulates partial-fill underfilling by minting only a subset of expected dstCST and refunding srcCST.
contract UnderfillingRolloverModule {
    /// @notice Execute.
    /// @param srcCst srcCST token contract.
    /// @param dstCst dstCST token contract.
    /// @param srcRefundAmount srcCST refund amount.
    /// @param dstMintAmount dstCST mint amount.
    function execute(address srcCst, address dstCst, uint256 srcRefundAmount, uint256 dstMintAmount)
        external
    {
        if (srcRefundAmount > 0) {
            IMintable(srcCst).mint(address(this), srcRefundAmount);
        }
        if (dstMintAmount > 0) {
            IMintable(dstCst).mint(address(this), dstMintAmount);
        }
    }
}
