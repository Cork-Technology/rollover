// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {
    LibPhoenixShareQuantum__FillAmountNotQuantumAligned,
    LibPhoenixShareQuantum__OrderSizeNotQuantumAligned,
    LibPhoenixShareQuantum__ResidualNotQuantumAligned,
    LibPhoenixShareQuantum__UnsupportedCollateralDecimals
} from "src/errors/LibPhoenixShareQuantumErrors.sol";
import { IPoolManager, MarketId } from "src/interfaces/external/phoenix/IPoolManager.sol";

/// @notice Phoenix source-share quantum helpers for low-decimal collateral assets.
library LibPhoenixShareQuantum {
    /// @notice Return the minimum source-share increment accepted by Phoenix for a source pool.
    /// @param poolManager Phoenix pool manager.
    /// @param srcPoolId Source Phoenix market id.
    /// @return Minimum source-share quantum for the source market collateral decimals.
    function srcShareQuantum(IPoolManager poolManager, bytes32 srcPoolId)
        internal
        view
        returns (uint256)
    {
        return _srcShareQuantum(poolManager, srcPoolId);
    }

    /// @notice Revert unless `orderSize` is a multiple of the Phoenix source-share quantum.
    /// @param poolManager Phoenix pool manager.
    /// @param srcPoolId Source Phoenix market id.
    /// @param orderSize Order size to validate.
    function requireOrderSizeAligned(IPoolManager poolManager, bytes32 srcPoolId, uint256 orderSize)
        internal
        view
    {
        uint256 quantum = _srcShareQuantum(poolManager, srcPoolId);
        if (orderSize % quantum != 0) {
            revert LibPhoenixShareQuantum__OrderSizeNotQuantumAligned(orderSize, quantum);
        }
    }

    /// @notice Revert unless a requested source fill and post-leg residual are quantum-aligned.
    /// @param fillAmount Requested source CST fill amount.
    /// @param residual Source CST amount remaining after the leg.
    /// @param quantum Phoenix source-share quantum for the source pool.
    function requireFillAndResidualQuantumAligned(
        uint256 fillAmount,
        uint256 residual,
        uint256 quantum
    ) internal pure {
        if (fillAmount % quantum != 0) {
            revert LibPhoenixShareQuantum__FillAmountNotQuantumAligned(fillAmount, quantum);
        }
        if (residual != 0 && residual % quantum != 0) {
            revert LibPhoenixShareQuantum__ResidualNotQuantumAligned(residual, quantum);
        }
    }

    function _srcShareQuantum(IPoolManager poolManager, bytes32 srcPoolId)
        private
        view
        returns (uint256)
    {
        address caSrc = poolManager.market(MarketId.wrap(srcPoolId)).collateralAsset;
        uint8 decimals = IERC20Metadata(caSrc).decimals();
        if (decimals > 18) {
            revert LibPhoenixShareQuantum__UnsupportedCollateralDecimals(decimals);
        }
        return 10 ** (18 - decimals);
    }
}
