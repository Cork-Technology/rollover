// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { CommonBase } from "forge-std/Base.sol";
import { StdCheats } from "forge-std/StdCheats.sol";
import { StdUtils } from "forge-std/StdUtils.sol";

/// @notice Suite-owned driver for canonical originData admission paths.
interface IOriginDataDriver {
    /// @notice Drive an open/openFor or direct-fill path and return originData observations.
    /// @param saltSeed Fuzz seed mixed into order salt.
    /// @param usePartial Whether to use the partial settler.
    /// @param directFill Whether to admit through direct fill instead of openFor.
    /// @return orderDigest Order digest.
    /// @return originDataHash ABI hash of canonical originData.
    /// @return originDataDigest Digest re-derived from originData's embedded order data.
    function driveOriginData(uint64 saltSeed, bool usePartial, bool directFill)
        external
        returns (bytes32 orderDigest, bytes32 originDataHash, bytes32 originDataDigest);

    /// @notice Reobserve previously recorded canonical originData.
    /// @param indexSeed Fuzz seed selecting the stored record.
    /// @return orderDigest Order digest.
    /// @return originDataHash ABI hash of canonical originData.
    /// @return originDataDigest Digest re-derived from originData's embedded order data.
    /// @return skipped True when no record exists.
    function observeOriginData(uint256 indexSeed)
        external
        view
        returns (
            bytes32 orderDigest,
            bytes32 originDataHash,
            bytes32 originDataDigest,
            bool skipped
        );
}

/// @notice N-INV-LIFECYCLE-ORIGINDATA-DIGEST-BINDING handler — drives order admission
///         and checks canonical originData immutability plus digest coherence.
/// @custom:invariant N-INV-LIFECYCLE-ORIGINDATA-DIGEST-BINDING
contract OriginDataHandler is CommonBase, StdCheats, StdUtils {
    /// @notice Driver implemented by the invariant suite.
    IOriginDataDriver public immutable driver;

    /// @notice Observed order digests.
    bytes32[] public observedDigests;

    /// @notice Whether a digest has been registered.
    mapping(bytes32 => bool) public observed;

    /// @notice First canonical originData ABI hash.
    mapping(bytes32 => bytes32) public firstOriginDataHash;

    /// @notice True if canonical originData was cleared or rewritten.
    bool public setOnceViolated;

    /// @notice True if originData does not rehash to its order digest.
    bool public digestMismatch;

    /// @notice True if a handler-authored valid admission unexpectedly reverted.
    bool public unexpectedRevert;

    /// @notice Successful admissions.
    uint64 public ghostAdmissions;

    /// @notice OriginData observations.
    uint64 public ghostObservations;

    /// @param driver_ Driver implemented by the invariant suite.
    constructor(IOriginDataDriver driver_) {
        driver = driver_;
    }

    /// @notice Drive one canonical-originData admission path.
    /// @param saltSeed Fuzz seed mixed into order salt.
    /// @param usePartial Whether to use the partial settler.
    /// @param directFill Whether to admit through direct fill.
    function admitOrder(uint64 saltSeed, bool usePartial, bool directFill) external {
        try driver.driveOriginData(saltSeed, usePartial, directFill) returns (
            bytes32 orderDigest, bytes32 originDataHash, bytes32 originDataDigest
        ) {
            _capture(orderDigest, originDataHash, originDataDigest);
            ghostAdmissions++;
        } catch {
            unexpectedRevert = true;
        }
    }

    /// @notice Reobserve an existing originData record.
    /// @param indexSeed Fuzz seed selecting a record.
    function observeOriginData(uint256 indexSeed) external {
        try driver.observeOriginData(indexSeed) returns (
            bytes32 orderDigest, bytes32 originDataHash, bytes32 originDataDigest, bool skipped
        ) {
            if (skipped) {
                return;
            }
            _capture(orderDigest, originDataHash, originDataDigest);
            ghostObservations++;
        } catch {
            unexpectedRevert = true;
        }
    }

    function _capture(bytes32 orderDigest, bytes32 originDataHash, bytes32 originDataDigest)
        internal
    {
        if (orderDigest == bytes32(0) || originDataHash == bytes32(0)) {
            setOnceViolated = true;
            return;
        }
        if (!observed[orderDigest]) {
            observed[orderDigest] = true;
            observedDigests.push(orderDigest);
        }
        bytes32 first = firstOriginDataHash[orderDigest];
        if (first == bytes32(0)) {
            firstOriginDataHash[orderDigest] = originDataHash;
        } else if (first != originDataHash) {
            setOnceViolated = true;
        }
        if (originDataDigest != orderDigest) {
            digestMismatch = true;
        }
    }
}
