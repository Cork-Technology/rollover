// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { CommonBase } from "forge-std/Base.sol";
import { StdCheats } from "forge-std/StdCheats.sol";
import { StdUtils } from "forge-std/StdUtils.sol";

/// @notice Suite-owned driver for compromised-settler rolloverContract-dispatch probes.
interface ICompromisedSettlerDispatchDriver {
    /// @notice Drive one fillContext/orderData binding tamper.
    /// @param fieldSeed Fuzz seed selecting the fillContext field to tamper.
    /// @param isPartial True to use PartialSettler, false to use ExactSettler.
    /// @return accepted True if the tampered dispatch returned without reverting.
    /// @return wrongSelector True if the dispatch reverted with a non-target selector.
    /// @return field Selected fillContext field.
    function driveFillContextMatchesOrderTamper(uint8 fieldSeed, bool isPartial)
        external
        returns (bool accepted, bool wrongSelector, uint8 field);

    /// @notice Drive one orderDigest/orderData binding tamper.
    /// @param fieldSeed Fuzz seed selecting the order-data field or supplied digest to tamper.
    /// @param isPartial True to use PartialSettler, false to use ExactSettler.
    /// @return accepted True if the tampered dispatch returned without reverting.
    /// @return wrongSelector True if the dispatch reverted with a non-target selector.
    /// @return field Selected tamper field.
    function driveOrderDigestTamper(uint8 fieldSeed, bool isPartial)
        external
        returns (bool accepted, bool wrongSelector, uint8 field);

    /// @notice Drive one runtime params/orderData.rolloverParams binding tamper.
    /// @param fieldSeed Fuzz seed selecting the rollover params field to tamper.
    /// @param isPartial True to use PartialSettler, false to use ExactSettler.
    /// @return accepted True if the tampered dispatch returned without reverting.
    /// @return wrongSelector True if the dispatch reverted with a non-target selector.
    /// @return field Selected rollover params field.
    function driveRolloverParamsTamper(uint8 fieldSeed, bool isPartial)
        external
        returns (bool accepted, bool wrongSelector, uint8 field);

    /// @notice Drive one real Settler.fill fill-size binding probe.
    /// @param scenarioSeed Fuzz seed selecting the fill-size scenario.
    /// @param amountSeed Fuzz seed selecting the order size.
    /// @return invalidAccepted True if an invalid fill-size tuple accepted.
    /// @return invalidWrongSelector True if an invalid tuple reverted at a non-target guard.
    /// @return validUnexpectedRevert True if a valid fill-size tuple unexpectedly reverted.
    /// @return scenario Selected fill-size scenario.
    function driveExactFillSizeBindingProbe(uint8 scenarioSeed, uint256 amountSeed)
        external
        returns (
            bool invalidAccepted,
            bool invalidWrongSelector,
            bool validUnexpectedRevert,
            uint8 scenario
        );
}

/// @notice Shared compromised-settler dispatch handler. This commit targets
///         fillContext, digest, params, and Settler fill-size invariants across separate suites.
/// @custom:invariant INV-FILL-CONTEXT-MATCHES-ORDER
/// @custom:invariant INV-ORDER-DIGEST-RE-DERIVED-ROLLOVER_CONTRACT-SIDE
/// @custom:invariant INV-PARAMS-MATCH-ORDER
/// @custom:invariant INV-EXACT-FILL-SIZE-BINDING
contract CompromisedSettlerDispatchHandler is CommonBase, StdCheats, StdUtils {
    /// @notice Suite-owned driver.
    /// @return driver Stored driver.
    ICompromisedSettlerDispatchDriver public immutable driver;

    /// @notice Violation flag: a fillContext-tampered dispatch accepted.
    /// @return fillContextTamperAccepted Stored flag.
    bool public fillContextTamperAccepted;
    /// @notice Violation flag: a fillContext-tampered dispatch reverted with the wrong selector.
    /// @return fillContextTamperWrongSelector Stored flag.
    bool public fillContextTamperWrongSelector;
    /// @notice Count of fillContext tamper probes.
    /// @return ghostFillContextTamperProbes Stored counter.
    uint64 public ghostFillContextTamperProbes;
    /// @notice Count of fillContext tamper probes by selected field.
    /// @return count Stored counter for a selected field.
    mapping(uint8 field => uint64 count) public ghostFillContextFieldProbes;
    /// @notice Count of accepted fillContext tamper probes.
    /// @return ghostFillContextTamperAccepted Stored counter.
    uint64 public ghostFillContextTamperAccepted;
    /// @notice Count of wrong-selector fillContext tamper probes.
    /// @return ghostFillContextWrongSelector Stored counter.
    uint64 public ghostFillContextWrongSelector;
    /// @notice Violation flag: a digest-tampered dispatch accepted.
    /// @return digestTamperAccepted Stored flag.
    bool public digestTamperAccepted;
    /// @notice Violation flag: a digest-tampered dispatch reverted with the wrong selector.
    /// @return digestTamperWrongSelector Stored flag.
    bool public digestTamperWrongSelector;
    /// @notice Count of digest tamper probes.
    /// @return ghostDigestTamperProbes Stored counter.
    uint64 public ghostDigestTamperProbes;
    /// @notice Count of digest tamper probes by selected field.
    /// @return count Stored counter for a selected field.
    mapping(uint8 field => uint64 count) public ghostDigestFieldProbes;
    /// @notice Count of accepted digest tamper probes.
    /// @return ghostDigestTamperAccepted Stored counter.
    uint64 public ghostDigestTamperAccepted;
    /// @notice Count of wrong-selector digest tamper probes.
    /// @return ghostDigestWrongSelector Stored counter.
    uint64 public ghostDigestWrongSelector;
    /// @notice Violation flag: a params-tampered dispatch accepted.
    /// @return paramsTamperAccepted Stored flag.
    bool public paramsTamperAccepted;
    /// @notice Violation flag: a params-tampered dispatch reverted with the wrong selector.
    /// @return paramsTamperWrongSelector Stored flag.
    bool public paramsTamperWrongSelector;
    /// @notice Count of params tamper probes.
    /// @return ghostParamsTamperProbes Stored counter.
    uint64 public ghostParamsTamperProbes;
    /// @notice Count of params tamper probes by selected field.
    /// @return count Stored counter for a selected field.
    mapping(uint8 field => uint64 count) public ghostParamsFieldProbes;
    /// @notice Count of accepted params tamper probes.
    /// @return ghostParamsTamperAccepted Stored counter.
    uint64 public ghostParamsTamperAccepted;
    /// @notice Count of wrong-selector params tamper probes.
    /// @return ghostParamsWrongSelector Stored counter.
    uint64 public ghostParamsWrongSelector;
    /// @notice Violation flag: an invalid fill-size tuple accepted.
    /// @return fillSizeInvalidAccepted Stored flag.
    bool public fillSizeInvalidAccepted;
    /// @notice Violation flag: an invalid fill-size tuple reverted at the wrong guard.
    /// @return fillSizeWrongSelector Stored flag.
    bool public fillSizeWrongSelector;
    /// @notice Violation flag: a valid fill-size tuple unexpectedly reverted.
    /// @return fillSizeValidUnexpectedRevert Stored flag.
    bool public fillSizeValidUnexpectedRevert;
    /// @notice Count of fill-size probes.
    /// @return ghostFillSizeProbes Stored counter.
    uint64 public ghostFillSizeProbes;
    /// @notice Count of fill-size probes by selected scenario.
    /// @return count Stored counter for a selected scenario.
    mapping(uint8 scenario => uint64 count) public ghostFillSizeScenarioProbes;
    /// @notice Count of accepted invalid fill-size probes.
    /// @return ghostFillSizeInvalidAccepted Stored counter.
    uint64 public ghostFillSizeInvalidAccepted;
    /// @notice Count of wrong-selector invalid fill-size probes.
    /// @return ghostFillSizeWrongSelector Stored counter.
    uint64 public ghostFillSizeWrongSelector;
    /// @notice Count of unexpected valid fill-size reverts.
    /// @return ghostFillSizeValidUnexpectedRevert Stored counter.
    uint64 public ghostFillSizeValidUnexpectedRevert;

    /// @param driver_ Suite-owned dispatch driver.
    constructor(ICompromisedSettlerDispatchDriver driver_) {
        driver = driver_;
    }

    /// @notice handler action: fuzz one exact-mode fillContext tamper.
    /// @param fieldSeed Fuzz seed selecting the fillContext field to tamper.
    function probeExactFillContextTamper(uint8 fieldSeed) external {
        _probeFillContext(fieldSeed, false);
    }

    /// @notice handler action: fuzz one partial-mode fillContext tamper.
    /// @param fieldSeed Fuzz seed selecting the fillContext field to tamper.
    function probePartialFillContextTamper(uint8 fieldSeed) external {
        _probeFillContext(fieldSeed, true);
    }

    /// @notice handler action: fuzz one exact-mode digest/orderData tamper.
    /// @param fieldSeed Fuzz seed selecting the order-data field or supplied digest to tamper.
    function probeExactDigestTamper(uint8 fieldSeed) external {
        _probeDigest(fieldSeed, false);
    }

    /// @notice handler action: fuzz one partial-mode digest/orderData tamper.
    /// @param fieldSeed Fuzz seed selecting the order-data field or supplied digest to tamper.
    function probePartialDigestTamper(uint8 fieldSeed) external {
        _probeDigest(fieldSeed, true);
    }

    /// @notice handler action: fuzz one exact-mode params/orderData tamper.
    /// @param fieldSeed Fuzz seed selecting the rollover params field to tamper.
    function probeExactParamsTamper(uint8 fieldSeed) external {
        _probeParams(fieldSeed, false);
    }

    /// @notice handler action: fuzz one partial-mode params/orderData tamper.
    /// @param fieldSeed Fuzz seed selecting the rollover params field to tamper.
    function probePartialParamsTamper(uint8 fieldSeed) external {
        _probeParams(fieldSeed, true);
    }

    /// @notice handler action: fuzz one real Settler.fill fill-size binding scenario.
    /// @param scenarioSeed Fuzz seed selecting exact/partial and valid/invalid tuple.
    /// @param amountSeed Fuzz seed selecting the order size.
    function probeExactFillSizeBinding(uint8 scenarioSeed, uint256 amountSeed) external {
        try driver.driveExactFillSizeBindingProbe(scenarioSeed, amountSeed) returns (
            bool invalidAccepted,
            bool invalidWrongSelector,
            bool validUnexpectedRevert,
            uint8 scenario
        ) {
            ghostFillSizeProbes++;
            ghostFillSizeScenarioProbes[scenario]++;
            if (invalidAccepted) {
                fillSizeInvalidAccepted = true;
                ghostFillSizeInvalidAccepted++;
            }
            if (invalidWrongSelector) {
                fillSizeWrongSelector = true;
                ghostFillSizeWrongSelector++;
            }
            if (validUnexpectedRevert) {
                fillSizeValidUnexpectedRevert = true;
                ghostFillSizeValidUnexpectedRevert++;
            }
        } catch {
            fillSizeValidUnexpectedRevert = true;
            ghostFillSizeValidUnexpectedRevert++;
        }
    }

    function _probeFillContext(uint8 fieldSeed, bool isPartial) internal {
        try driver.driveFillContextMatchesOrderTamper(fieldSeed, isPartial) returns (
            bool accepted, bool wrongSelector, uint8 field
        ) {
            ghostFillContextTamperProbes++;
            ghostFillContextFieldProbes[field]++;
            if (accepted) {
                fillContextTamperAccepted = true;
                ghostFillContextTamperAccepted++;
            }
            if (wrongSelector) {
                fillContextTamperWrongSelector = true;
                ghostFillContextWrongSelector++;
            }
        } catch {
            fillContextTamperWrongSelector = true;
            ghostFillContextWrongSelector++;
        }
    }

    function _probeDigest(uint8 fieldSeed, bool isPartial) internal {
        try driver.driveOrderDigestTamper(fieldSeed, isPartial) returns (
            bool accepted, bool wrongSelector, uint8 field
        ) {
            ghostDigestTamperProbes++;
            ghostDigestFieldProbes[field]++;
            if (accepted) {
                digestTamperAccepted = true;
                ghostDigestTamperAccepted++;
            }
            if (wrongSelector) {
                digestTamperWrongSelector = true;
                ghostDigestWrongSelector++;
            }
        } catch {
            digestTamperWrongSelector = true;
            ghostDigestWrongSelector++;
        }
    }

    function _probeParams(uint8 fieldSeed, bool isPartial) internal {
        try driver.driveRolloverParamsTamper(fieldSeed, isPartial) returns (
            bool accepted, bool wrongSelector, uint8 field
        ) {
            ghostParamsTamperProbes++;
            ghostParamsFieldProbes[field]++;
            if (accepted) {
                paramsTamperAccepted = true;
                ghostParamsTamperAccepted++;
            }
            if (wrongSelector) {
                paramsTamperWrongSelector = true;
                ghostParamsWrongSelector++;
            }
        } catch {
            paramsTamperWrongSelector = true;
            ghostParamsWrongSelector++;
        }
    }
}
