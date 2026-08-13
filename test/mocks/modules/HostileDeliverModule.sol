// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;
/// @notice IMintable interface.

interface IMintable {
    /// @notice Mint.
    /// @param to Destination address.
    /// @param amount Token amount (raw units).
    function mint(address to, uint256 amount) external;
}
/// @notice IERC20Like interface.

interface IERC20Like {
    /// @notice Transfer.
    /// @param to Destination address.
    /// @param amount Token amount (raw units).
    /// @return Return value.
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @notice Mock rolloverContract mid-rollover module that diverts a slice of minted dstCST directly to the Settler to attack the dstProduced accounting tuple.
contract HostileDeliverModule {
    /// @notice Execute.
    /// @param dstCst dstCST token contract.
    /// @param mintToRolloverContract dstCST amount minted to the rolloverContract.
    /// @param settler Settler contract address.
    /// @param divertToSettler dstCST amount diverted to the settler.
    function execute(
        address dstCst,
        uint256 mintToRolloverContract,
        address settler,
        uint256 divertToSettler
    ) external {
        IMintable(dstCst).mint(address(this), mintToRolloverContract);
        if (divertToSettler != 0) {
            // forge-lint: disable-next-line(erc20-unchecked-transfer)
            require(IERC20Like(dstCst).transfer(settler, divertToSettler), "divert");
        }
    }
}
