// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import { LibFillerAuth } from "src/libraries/LibFillerAuth.sol";
import { LibFillerPayload } from "src/libraries/LibFillerPayload.sol";
import { FillerPayload } from "src/types/FillerTypes.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice Settler mock that tracks `openFor` invocations and records the orderId passed to
///         atomic `fill`. Reports a configurable `orderStatus` per orderId. Used to pin helper
///         idempotent-openFor behaviour: helpers MUST compute orderId locally (not depend on
///         `resolve`'s return) and MUST skip `openFor` when the cached status is `Opened`.
contract CountingSettler {
    /// @notice Number of times `openFor` has been invoked on this mock.
    uint256 public openForCalls;
    /// @notice Most recently observed orderId on `fill()` (atomic-fill records here).
    bytes32 public lastFillOrderId;
    /// @notice Rollover destination decoded from the latest atomic `fill()` call.
    address public lastRolloverDestination;
    /// @notice Per-orderId cached status (configurable per test).
    mapping(bytes32 => uint8) internal _status;
    /// @notice EIP-712 domain separator returned by `DOMAIN_SEPARATOR`.
    bytes32 internal _domainSeparator;

    /// @param domainSep Domain separator to return from `DOMAIN_SEPARATOR`.
    constructor(bytes32 domainSep) {
        _domainSeparator = domainSep;
    }

    /// @notice Configure the status reported for `orderId`.
    /// @param orderId Canonical order id.
    /// @param status `OrderStatus` packed as `uint8`.
    function setStatus(bytes32 orderId, uint8 status) external {
        _status[orderId] = status;
    }

    /// @notice EIP-712 domain separator stub.
    /// @return Configured domain separator value.
    // forge-lint: disable-next-line(mixed-case-function)
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparator;
    }

    /// @notice Report the configured status for `orderId`.
    /// @param orderId Canonical order id.
    /// @return Configured status, packed as `uint8`.
    function orderStatus(bytes32 orderId) external view returns (uint8) {
        return _status[orderId];
    }

    /// @notice openFor stub — increments the call counter.
    /// @param order ERC-7683 order envelope (ignored).
    /// @param sig cPT-holder signature (ignored).
    /// @param originFillerData Origin-side filler data (ignored).
    function openFor(
        ERC7683Types.GaslessCrossChainOrder calldata order,
        bytes calldata sig,
        bytes calldata originFillerData
    ) external {
        order;
        sig;
        originFillerData;
        openForCalls += 1;
    }

    /// @notice resolveFor stub returning a fixed sentinel orderId. Helpers MUST NOT depend on this
    ///         value (orderId is computed locally).
    /// @param order ERC-7683 order envelope (ignored).
    /// @param originFillerData Origin-side filler data (ignored).
    /// @return r Resolved order with `orderId = 0xDEADBEEF`.
    function resolveFor(
        ERC7683Types.GaslessCrossChainOrder calldata order,
        bytes calldata originFillerData
    ) external pure returns (ERC7683Types.ResolvedCrossChainOrder memory r) {
        order;
        originFillerData;
        r.orderId = bytes32(uint256(0xDEADBEEF));
    }

    /// @notice fill stub (no-op).
    /// @param orderId Canonical order id (ignored).
    /// @param originData Origin-side data (ignored).
    /// @param fillerData Filler-side data (ignored).
    function fill(bytes32 orderId, bytes calldata originData, bytes calldata fillerData) external {
        originData;
        (bytes memory rolloverData,,) = LibFillerPayload.decodeAtomicEnvelopeValidated(fillerData);
        FillerPayload memory payload = LibFillerAuth.decodePayloadMemory(rolloverData);
        lastRolloverDestination = payload.destination;
        lastFillOrderId = orderId;
    }

    /// @notice fillerDstProducedOf stub.
    /// @param orderId Canonical order id (ignored).
    /// @param filler Filler address (ignored).
    /// @return Constant zero.
    function fillerDstProducedOf(bytes32 orderId, address filler) external pure returns (uint256) {
        orderId;
        filler;
        return 0;
    }

    /// @notice 3-arg overload — subFiller dimension (ignored, returns 0).
    /// @param orderId Canonical order id (ignored).
    /// @param filler Filler address (ignored).
    /// @param subFiller Sub-filler identity (ignored).
    /// @return Constant zero.
    function fillerDstProducedOf(bytes32 orderId, address filler, bytes32 subFiller)
        external
        pure
        returns (uint256)
    {
        orderId;
        filler;
        subFiller;
        return 0;
    }
}
