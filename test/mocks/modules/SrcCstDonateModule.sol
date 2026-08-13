// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;
/// @notice IMintableSrcCst interface.

interface IMintableSrcCst {
    /// @notice Mint.
    /// @param to Destination address.
    /// @param amount Token amount (raw units).
    function mint(address to, uint256 amount) external;
}

/// @notice Mock rolloverContract module that donates srcCST into the Settler to exercise unsolicited-transfer accounting.
contract SrcCstDonateModule {
    /// @notice Execute.
    /// @param srcCst srcCST token contract.
    /// @param settler Settler contract address.
    /// @param amount Token amount (raw units).
    function execute(address srcCst, address settler, uint256 amount) external {
        IMintableSrcCst(srcCst).mint(settler, amount);
    }
}
