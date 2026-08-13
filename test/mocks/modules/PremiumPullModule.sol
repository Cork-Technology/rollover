// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Mock rolloverContract premium-hook module that pulls the premium token from the filler into the rolloverContract.
contract PremiumPullModule {
    /// @notice Execute.
    /// @param token Token contract.
    /// @param filler Filler address.
    /// @param premium Premium amount (raw units of the premium token).
    function execute(address token, address filler, uint256 premium) external {
        require(
            IERC20(token).transferFrom(filler, address(this), premium),
            "PremiumPullModule: transferFrom failed"
        );
    }
}
