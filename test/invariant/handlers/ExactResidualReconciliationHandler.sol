// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { CommonBase } from "forge-std/Base.sol";
import { StdCheats } from "forge-std/StdCheats.sol";
import { StdUtils } from "forge-std/StdUtils.sol";

/// @notice Suite-owned exact residual reconciliation driver.
interface IExactResidualReconciliationDriver {
    /// @notice Drive one async rollover that leaves exact dstCST residual escrowed.
    /// @param saltSeed Fuzz seed mixed into the order salt.
    /// @return ok True when the operation completed.
    function driveExactAsyncRollover(uint64 saltSeed) external returns (bool ok);

    /// @notice Drive premium settlement for one unpaid async exact residual.
    /// @param indexSeed Fuzz seed selecting a record.
    /// @return ok True when an eligible record was settled or no-op skipped.
    function driveExactPremiumSettle(uint256 indexSeed) external returns (bool ok);

    /// @notice Drive reclaim for one unpaid async exact residual.
    /// @param indexSeed Fuzz seed selecting a record.
    /// @return ok True when an eligible record was reclaimed or no-op skipped.
    function driveExactReclaim(uint256 indexSeed) external returns (bool ok);

    /// @notice Drive one atomic exact fill that produces and drains residual in-frame.
    /// @param saltSeed Fuzz seed mixed into the order salt.
    /// @return ok True when the operation completed.
    function driveExactAtomicFill(uint64 saltSeed) external returns (bool ok);

    /// @notice Observe exact residual reconciliation and fill-record set-once status.
    /// @return residualSum Sum of ghost live exact residuals.
    /// @return settlerBalance Live dstCST balance at the exact settler.
    /// @return producedSetOnce True if every observed rollover accounting stayed stable.
    /// @return residualBounded True if every ghost residual is less than or equal to produced.
    function observeExactResiduals()
        external
        view
        returns (
            uint256 residualSum,
            uint256 settlerBalance,
            bool producedSetOnce,
            bool residualBounded
        );
}

/// @notice N-INV-EXACT-RESIDUAL-RECONCILES-TO-FILL-RECORD handler — drives exact
///         async/atomic flows and observes residual reconciliation.
/// @custom:invariant N-INV-EXACT-RESIDUAL-RECONCILES-TO-FILL-RECORD
contract ExactResidualReconciliationHandler is CommonBase, StdCheats, StdUtils {
    /// @notice Driver implemented by the invariant suite.
    IExactResidualReconciliationDriver public immutable driver;

    /// @notice True if a handler-authored valid operation unexpectedly reverted.
    bool public unexpectedRevert;

    /// @notice True if live exact residual balance diverged from ghost residual sum.
    bool public residualMismatch;

    /// @notice True if any exact residual exceeded its rollover accounting production.
    bool public residualExceededProduced;

    /// @notice True if `dstCstProduced` changed after first nonzero observation.
    bool public producedSetOnceViolated;

    /// @notice Handler operation counter.
    uint64 public ghostOperations;

    /// @param driver_ Driver implemented by the invariant suite.
    constructor(IExactResidualReconciliationDriver driver_) {
        driver = driver_;
    }

    /// @notice Drive one async exact rollover.
    /// @param saltSeed Fuzz seed mixed into order salt.
    function asyncRollover(uint64 saltSeed) external {
        try driver.driveExactAsyncRollover(saltSeed) returns (bool ok) {
            if (!ok) {
                unexpectedRevert = true;
            }
            _observe();
            ghostOperations++;
        } catch {
            unexpectedRevert = true;
        }
    }

    /// @notice Settle one unpaid exact residual via async premium.
    /// @param indexSeed Fuzz seed selecting a record.
    function premiumSettle(uint256 indexSeed) external {
        try driver.driveExactPremiumSettle(indexSeed) returns (bool ok) {
            if (!ok) {
                unexpectedRevert = true;
            }
            _observe();
            ghostOperations++;
        } catch {
            unexpectedRevert = true;
        }
    }

    /// @notice Reclaim one unpaid exact residual.
    /// @param indexSeed Fuzz seed selecting a record.
    function reclaim(uint256 indexSeed) external {
        try driver.driveExactReclaim(indexSeed) returns (bool ok) {
            if (!ok) {
                unexpectedRevert = true;
            }
            _observe();
            ghostOperations++;
        } catch {
            unexpectedRevert = true;
        }
    }

    /// @notice Drive one atomic exact fill.
    /// @param saltSeed Fuzz seed mixed into order salt.
    function atomicFill(uint64 saltSeed) external {
        try driver.driveExactAtomicFill(saltSeed) returns (bool ok) {
            if (!ok) {
                unexpectedRevert = true;
            }
            _observe();
            ghostOperations++;
        } catch {
            unexpectedRevert = true;
        }
    }

    /// @notice Observe exact residual reconciliation.
    function observe() external {
        _observe();
    }

    function _observe() internal {
        (uint256 residualSum, uint256 settlerBalance, bool producedSetOnce, bool residualBounded) =
            driver.observeExactResiduals();
        if (residualSum != settlerBalance) {
            residualMismatch = true;
        }
        if (!producedSetOnce) {
            producedSetOnceViolated = true;
        }
        if (!residualBounded) {
            residualExceededProduced = true;
        }
    }
}
