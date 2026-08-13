// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { MockCpt } from "../MockPhoenix.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
/// @notice IMintable interface.

interface IMintable {
    /// @notice Mint.
    /// @param to Destination address.
    /// @param amount Token amount (raw units).
    function mint(address to, uint256 amount) external;
}

/// @notice Mock pre-rollover hook that mints srcCPT into the rolloverContract to mirror Phoenix issuance.
contract SourceSrcCptModule {
    /// @notice Execute.
    /// @param srcCpt srcCPT (Cork Principal Token) contract.
    /// @param amount Token amount (raw units).
    function execute(address srcCpt, uint256 amount) external {
        IMintable(srcCpt).mint(address(this), amount);
    }
}

/// @notice Mock post-rollover hook that burns a specified amount of dstCPT held by the rolloverContract.
contract ConsumeDstCptModule {
    /// @notice Execute.
    /// @param dstCpt dstCPT (Cork Principal Token) contract.
    /// @param amount Token amount (raw units).
    function execute(address dstCpt, uint256 amount) external {
        MockCpt(dstCpt).burn(address(this), amount);
    }
}

/// @notice Mock post-rollover hook that burns the rolloverContract's entire dstCPT balance to clear residual principal.
contract ConsumeAllDstCptModule {
    /// @notice Execute.
    /// @param dstCpt dstCPT (Cork Principal Token) contract.
    function execute(address dstCpt) external {
        uint256 bal = MockCpt(dstCpt).balanceOf(address(this));
        if (bal != 0) {
            MockCpt(dstCpt).burn(address(this), bal);
        }
    }
}

/// @notice Mock rolloverContract hook that forwards dstCPT to an arbitrary sink to test post-rollover routing.
contract DepositDstCptModule {
    using SafeERC20 for IERC20;
    /// @notice Execute.
    /// @param dstCpt dstCPT (Cork Principal Token) contract.
    /// @param sink Sink address.
    /// @param amount Token amount (raw units).

    function execute(address dstCpt, address sink, uint256 amount) external {
        IERC20(dstCpt).safeTransfer(sink, amount);
    }
}

/// @notice Mock rolloverContract hook that mints collateral asset (CA) into the rolloverContract to simulate Phoenix unwindMint output.
contract DonateCaModule {
    /// @notice Execute.
    /// @param collateralAsset Collateral asset contract.
    /// @param amount Token amount (raw units).
    function execute(address collateralAsset, uint256 amount) external {
        IMintable(collateralAsset).mint(address(this), amount);
    }
}

/// @notice Mock mid-rollover hook that simulates a SwapModule: transfers `amountIn` of `tokenIn` (caSrc) out to `sink` and mints `amountOut` of `tokenOut` (caDst) into the rolloverContract — both legs run in the rolloverContract's delegatecall frame.
contract SwapCaModule {
    using SafeERC20 for IERC20;
    /// @notice Execute.
    /// @param tokenIn Token being consumed (caSrc).
    /// @param sink Destination address for the consumed `tokenIn`.
    /// @param amountIn Amount of `tokenIn` to transfer out (zero is a no-op for this leg).
    /// @param tokenOut Token being produced (caDst).
    /// @param amountOut Amount of `tokenOut` to mint into the rolloverContract (zero is a no-op for this leg).

    function execute(
        address tokenIn,
        address sink,
        uint256 amountIn,
        address tokenOut,
        uint256 amountOut
    ) external {
        if (amountIn != 0) {
            IERC20(tokenIn).safeTransfer(sink, amountIn);
        }
        if (amountOut != 0) {
            IMintable(tokenOut).mint(address(this), amountOut);
        }
    }
}

/// @notice Mock rolloverContract hook that drains collateral asset out of the rolloverContract to exercise INV-CPT-CONTAINED guards.
contract DrainCaModule {
    using SafeERC20 for IERC20;
    /// @notice Execute.
    /// @param collateralAsset Collateral asset contract.
    /// @param sink Sink address.
    /// @param amount Token amount (raw units).

    function execute(address collateralAsset, address sink, uint256 amount) external {
        IERC20(collateralAsset).safeTransfer(sink, amount);
    }
}

/// @notice Mock pre-rollover hook that mints excess srcCPT to stress polarity-gate accounting.
contract OverSourceSrcCptModule {
    /// @notice Execute.
    /// @param srcCpt srcCPT (Cork Principal Token) contract.
    /// @param amount Token amount (raw units).
    function execute(address srcCpt, uint256 amount) external {
        IMintable(srcCpt).mint(address(this), amount);
    }
}

/// @notice Mock pre-rollover hook with no side effects, used as a non-empty hook placeholder in tests.
contract NoopPreModule {
    /// @notice Execute.
    function execute() external pure { }
}

/// @notice Mock rolloverContract premium-hook that routes premium tokens out of the rolloverContract to a chosen sink.
contract PremiumRouteModule {
    using SafeERC20 for IERC20;
    /// @notice Execute.
    /// @param premiumToken Premium token contract.
    /// @param sink Sink address.
    /// @param amount Token amount (raw units).

    function execute(address premiumToken, address sink, uint256 amount) external {
        IERC20(premiumToken).safeTransfer(sink, amount);
    }
}

/// @notice Mock of a minimal yield vault used as a destination for premium-routing hook tests.
contract MockYieldVault {
    using SafeERC20 for IERC20;
    /// @notice Deposit of.
    /// @return depositOf Stored deposit of value.

    mapping(address => uint256) public depositOf;
    /// @notice Deposit.
    /// @param asset Asset contract.
    /// @param amount Token amount (raw units).

    function deposit(address asset, uint256 amount) external {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        depositOf[msg.sender] += amount;
    }
}

/// @notice Mock rolloverContract premium-hook that approves and deposits premium tokens into a MockYieldVault.
contract PremiumDepositIntoVaultModule {
    using SafeERC20 for IERC20;
    /// @notice Execute.
    /// @param premiumToken Premium token contract.
    /// @param vault Vault contract.
    /// @param amount Token amount (raw units).

    function execute(address premiumToken, address vault, uint256 amount) external {
        IERC20(premiumToken).forceApprove(vault, amount);
        MockYieldVault(vault).deposit(premiumToken, amount);
    }
}
