// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { CommonBase } from "forge-std/Base.sol";
import { StdCheats } from "forge-std/StdCheats.sol";
import { StdUtils } from "forge-std/StdUtils.sol";

import { FillScaffold } from "../../base/FillScaffold.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { BaseFiller } from "src/BaseFiller.sol";
import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import { ISettler } from "src/interfaces/settlers/ISettler.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice Suite-owned driver for opened-order fillability probes.
interface IOpenedOrdersFillableUntilFillDeadlineDriver {
    /// @notice Open and store one handler-authored order before or at `openDeadline`.
    /// @param deadlineSeed Fuzz seed for the open-deadline offset.
    /// @param openWarpSeed Fuzz seed for the open timestamp.
    /// @param openPathSeed Fuzz seed selecting `open` or `openFor`.
    /// @param isPartial True to use PartialSettler, false to use ExactSettler.
    /// @return opened True if the order reached `Opened`.
    /// @return atOpenDeadline True if the order was opened exactly at `openDeadline`.
    function driveOpenOrder(
        uint64 deadlineSeed,
        uint64 openWarpSeed,
        uint8 openPathSeed,
        bool isPartial
    ) external returns (bool opened, bool atOpenDeadline);

    /// @notice Fill one previously opened order through a direct or helper-style path.
    /// @param recordSeed Fuzz seed selecting an opened order.
    /// @param timingSeed Fuzz seed selecting before/at/after fillDeadline.
    /// @param isHelper True for `BaseFiller.execute`, false for direct Settler fill.
    /// @return attempted True if an opened unconsumed record was selected.
    /// @return accepted True if the fill path returned without reverting.
    /// @return shouldFill True if the selected timestamp is not past `fillDeadline`.
    /// @return isPartial True when the selected record targets PartialSettler.
    /// @return statusBefore Order status before the fill attempt.
    /// @return statusAfter Order status after the fill attempt.
    function driveOpenedOrderFill(uint256 recordSeed, uint64 timingSeed, bool isHelper)
        external
        returns (
            bool attempted,
            bool accepted,
            bool shouldFill,
            bool isPartial,
            uint8 statusBefore,
            uint8 statusAfter
        );
}

/// @notice INV-OPENED-ORDERS-FILLABLE-UNTIL-FILLDEADLINE handler — opens
///         exact/partial orders before or at `openDeadline`, then probes direct
///         Settler fills and helper-style BaseFiller executions until and after
///         `fillDeadline`.
/// @custom:invariant INV-OPENED-ORDERS-FILLABLE-UNTIL-FILLDEADLINE
contract OpenedOrdersFillableUntilFillDeadlineHandler is CommonBase, StdCheats, StdUtils {
    /// @notice Suite-owned fillability driver.
    /// @return driver Stored driver.
    IOpenedOrdersFillableUntilFillDeadlineDriver public immutable driver;

    /// @notice True if an opened order rejected at or before `fillDeadline`.
    /// @return fillableOpenedOrderRejected Stored flag.
    bool public fillableOpenedOrderRejected;
    /// @notice True if an opened order accepted a fill after `fillDeadline`.
    /// @return expiredOpenedOrderAccepted Stored flag.
    bool public expiredOpenedOrderAccepted;
    /// @notice True if opening a handler-authored valid order unexpectedly failed.
    /// @return validOpenRejected Stored flag.
    bool public validOpenRejected;
    /// @notice True if the suite driver reverted unexpectedly.
    /// @return driverReverted Stored flag.
    bool public driverReverted;
    /// @notice Count of successfully opened handler records.
    /// @return ghostOpenedOrders Stored counter.
    uint64 public ghostOpenedOrders;
    /// @notice Count of orders opened exactly at `openDeadline`.
    /// @return ghostOpenedAtOpenDeadline Stored counter.
    uint64 public ghostOpenedAtOpenDeadline;
    /// @notice Count of direct-fill probes.
    /// @return ghostDirectProbes Stored counter.
    uint64 public ghostDirectProbes;
    /// @notice Count of helper-style probes.
    /// @return ghostHelperProbes Stored counter.
    uint64 public ghostHelperProbes;
    /// @notice Count of accepted direct fills at or before `fillDeadline`.
    /// @return ghostDirectFillableAccepted Stored counter.
    uint64 public ghostDirectFillableAccepted;
    /// @notice Count of accepted helper fills at or before `fillDeadline`.
    /// @return ghostHelperFillableAccepted Stored counter.
    uint64 public ghostHelperFillableAccepted;
    /// @notice Count of rejected direct fills after `fillDeadline`.
    /// @return ghostDirectExpiredRejected Stored counter.
    uint64 public ghostDirectExpiredRejected;
    /// @notice Count of rejected helper fills after `fillDeadline`.
    /// @return ghostHelperExpiredRejected Stored counter.
    uint64 public ghostHelperExpiredRejected;
    /// @notice Count of unexpected rejections at or before `fillDeadline`.
    /// @return ghostUnexpectedFillableRejects Stored counter.
    uint64 public ghostUnexpectedFillableRejects;
    /// @notice Count of unexpected accepts after `fillDeadline`.
    /// @return ghostUnexpectedExpiredAccepts Stored counter.
    uint64 public ghostUnexpectedExpiredAccepts;
    /// @notice Count of fill probes skipped because no opened unconsumed order existed.
    /// @return ghostSkippedNoRecord Stored counter.
    uint64 public ghostSkippedNoRecord;
    /// @notice Count of exact-mode fill probes.
    /// @return ghostExactFillProbes Stored counter.
    uint64 public ghostExactFillProbes;
    /// @notice Count of partial-mode fill probes.
    /// @return ghostPartialFillProbes Stored counter.
    uint64 public ghostPartialFillProbes;

    /// @param driver_ Suite-owned driver.
    constructor(IOpenedOrdersFillableUntilFillDeadlineDriver driver_) {
        driver = driver_;
    }

    /// @param deadlineSeed Fuzz seed selecting the scenario value.
    /// @param openWarpSeed Fuzz seed selecting the scenario value.
    /// @param openPathSeed Fuzz seed selecting the scenario value.

    /// @notice handler action: open one exact-mode order before or at openDeadline.
    function openExact(uint64 deadlineSeed, uint64 openWarpSeed, uint8 openPathSeed) external {
        _open(deadlineSeed, openWarpSeed, openPathSeed, false);
    }

    /// @param deadlineSeed Fuzz seed selecting the scenario value.
    /// @param openWarpSeed Fuzz seed selecting the scenario value.
    /// @param openPathSeed Fuzz seed selecting the scenario value.

    /// @notice handler action: open one partial-mode order before or at openDeadline.
    function openPartial(uint64 deadlineSeed, uint64 openWarpSeed, uint8 openPathSeed) external {
        _open(deadlineSeed, openWarpSeed, openPathSeed, true);
    }

    /// @param recordSeed Fuzz seed selecting the scenario value.
    /// @param timingSeed Fuzz seed selecting the scenario value.

    /// @notice handler action: fill a stored opened order directly through Settler.fill.
    function probeDirect(uint256 recordSeed, uint64 timingSeed) external {
        _probe(recordSeed, timingSeed, false);
    }

    /// @param recordSeed Fuzz seed selecting the scenario value.
    /// @param timingSeed Fuzz seed selecting the scenario value.

    /// @notice handler action: fill a stored opened order through BaseFiller.execute.
    function probeHelper(uint256 recordSeed, uint64 timingSeed) external {
        _probe(recordSeed, timingSeed, true);
    }

    function _open(uint64 deadlineSeed, uint64 openWarpSeed, uint8 openPathSeed, bool isPartial)
        internal
    {
        try driver.driveOpenOrder(deadlineSeed, openWarpSeed, openPathSeed, isPartial) returns (
            bool opened, bool atOpenDeadline
        ) {
            if (!opened) {
                validOpenRejected = true;
                return;
            }
            ghostOpenedOrders++;
            if (atOpenDeadline) {
                ghostOpenedAtOpenDeadline++;
            }
        } catch {
            driverReverted = true;
            validOpenRejected = true;
        }
    }

    function _probe(uint256 recordSeed, uint64 timingSeed, bool isHelper) internal {
        try driver.driveOpenedOrderFill(recordSeed, timingSeed, isHelper) returns (
            bool attempted,
            bool accepted,
            bool shouldFill,
            bool isPartial,
            uint8 statusBefore,
            uint8 statusAfter
        ) {
            _capture(
                attempted, accepted, shouldFill, isHelper, isPartial, statusBefore, statusAfter
            );
        } catch {
            driverReverted = true;
            fillableOpenedOrderRejected = true;
        }
    }

    function _capture(
        bool attempted,
        bool accepted,
        bool shouldFill,
        bool isHelper,
        bool isPartial,
        uint8 statusBefore,
        uint8 statusAfter
    ) internal {
        statusAfter;
        if (!attempted) {
            ghostSkippedNoRecord++;
            return;
        }

        if (isHelper) {
            ghostHelperProbes++;
        } else {
            ghostDirectProbes++;
        }
        if (isPartial) {
            ghostPartialFillProbes++;
        } else {
            ghostExactFillProbes++;
        }

        if (statusBefore != uint8(RolloverTypes.OrderStatus.Opened)) {
            driverReverted = true;
            fillableOpenedOrderRejected = true;
            return;
        }

        if (shouldFill) {
            if (accepted) {
                if (isHelper) {
                    ghostHelperFillableAccepted++;
                } else {
                    ghostDirectFillableAccepted++;
                }
            } else {
                fillableOpenedOrderRejected = true;
                ghostUnexpectedFillableRejects++;
            }
        } else if (accepted) {
            expiredOpenedOrderAccepted = true;
            ghostUnexpectedExpiredAccepts++;
        } else if (isHelper) {
            ghostHelperExpiredRejected++;
        } else {
            ghostDirectExpiredRejected++;
        }
    }
}

/// @notice Shared active driver for
///         INV-OPENED-ORDERS-FILLABLE-UNTIL-FILLDEADLINE invariant suites.
abstract contract OpenedOrdersFillableUntilFillDeadlineInvariantBase is
    FillScaffold,
    IOpenedOrdersFillableUntilFillDeadlineDriver
{
    /// @notice Fill size for handler-authored opened-order records.
    uint256 internal constant OPENED_FILL_SIZE = 500e18;
    /// @notice Salt base reserved for this invariant's handler-authored orders.
    uint64 internal constant OPENED_FILLABLE_SALT_BASE = 140_000;

    /// @notice Handler-owned opened order record.
    struct OpenedRecord {
        RolloverTypes.OrderData orderData;
        bytes32 orderDigest;
        bool isPartial;
        bool consumed;
    }

    /// @notice Active handler.
    OpenedOrdersFillableUntilFillDeadlineHandler internal openedOrdersFillableHandler;
    /// @notice Monotonic salt cursor for handler-authored records.
    uint64 internal nextOpenedFillableSalt;
    /// @notice Opened order records available to fill probes.
    OpenedRecord[] internal openedRecords;

    /// @notice Sets up the active handler and targets its open/fill actions.
    function _setUpOpenedOrdersFillableUntilFillDeadlineInvariant() internal {
        nextOpenedFillableSalt = OPENED_FILLABLE_SALT_BASE;
        _approveFiller(type(uint256).max, type(uint256).max);
        vm.startPrank(filler);
        srcCst.approve(address(baseFiller), type(uint256).max);
        premiumToken.approve(address(baseFiller), type(uint256).max);
        vm.stopPrank();

        openedOrdersFillableHandler = new OpenedOrdersFillableUntilFillDeadlineHandler(
            IOpenedOrdersFillableUntilFillDeadlineDriver(address(this))
        );
        targetContract(address(openedOrdersFillableHandler));
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = openedOrdersFillableHandler.openExact.selector;
        selectors[1] = openedOrdersFillableHandler.openPartial.selector;
        selectors[2] = openedOrdersFillableHandler.probeDirect.selector;
        selectors[3] = openedOrdersFillableHandler.probeHelper.selector;
        targetSelector(
            FuzzSelector({ addr: address(openedOrdersFillableHandler), selectors: selectors })
        );
    }

    /// @inheritdoc IOpenedOrdersFillableUntilFillDeadlineDriver
    function driveOpenOrder(
        uint64 deadlineSeed,
        uint64 openWarpSeed,
        uint8 openPathSeed,
        bool isPartial
    ) external returns (bool opened, bool atOpenDeadline) {
        require(msg.sender == address(openedOrdersFillableHandler), "OpenedFillable: only handler");

        SettlerMode mode = isPartial ? SettlerMode.Partial : SettlerMode.Exact;
        uint64 openOffset = uint64(bound(deadlineSeed, 1, 1 days));
        uint64 openWarp = uint64(bound(openWarpSeed, 0, openOffset));
        RolloverTypes.OrderData memory orderData = _openedFillableOrder(mode, openOffset);

        vm.warp(block.timestamp + openWarp);
        atOpenDeadline = block.timestamp == orderData.openDeadline;
        opened = openPathSeed % 2 == 0
            ? _tryOpenedFillableOpen(mode, orderData)
            : _tryOpenedFillableOpenFor(mode, orderData);

        bytes32 orderDigest = _orderDigest(orderData);
        opened = opened
            && uint8(_settlerForMode(mode).orderStatus(orderDigest))
                == uint8(RolloverTypes.OrderStatus.Opened);
        if (opened) {
            openedRecords.push(
                OpenedRecord({
                    orderData: orderData,
                    orderDigest: orderDigest,
                    isPartial: isPartial,
                    consumed: false
                })
            );
        }
    }

    /// @inheritdoc IOpenedOrdersFillableUntilFillDeadlineDriver
    function driveOpenedOrderFill(uint256 recordSeed, uint64 timingSeed, bool isHelper)
        external
        returns (
            bool attempted,
            bool accepted,
            bool shouldFill,
            bool isPartial,
            uint8 statusBefore,
            uint8 statusAfter
        )
    {
        require(msg.sender == address(openedOrdersFillableHandler), "OpenedFillable: only handler");

        (attempted, recordSeed) = _selectOpenedRecord(recordSeed);
        if (!attempted) {
            return (false, false, false, false, 0, 0);
        }

        OpenedRecord storage rec = openedRecords[recordSeed];
        rec.consumed = true;
        isPartial = rec.isPartial;
        SettlerMode mode = isPartial ? SettlerMode.Partial : SettlerMode.Exact;

        uint256 targetTimestamp = _fillProbeTimestamp(rec.orderData, timingSeed);
        vm.warp(targetTimestamp);
        shouldFill = block.timestamp <= rec.orderData.fillDeadline;
        statusBefore = uint8(_settlerForMode(mode).orderStatus(rec.orderDigest));

        accepted = isHelper
            ? _tryOpenedFillableHelper(mode, rec.orderDigest, rec.orderData)
            : _tryOpenedFillableDirect(mode, rec.orderDigest, rec.orderData);

        statusAfter = uint8(_settlerForMode(mode).orderStatus(rec.orderDigest));
    }

    function _openedFillableOrder(SettlerMode mode, uint64 openOffset)
        internal
        returns (RolloverTypes.OrderData memory orderData)
    {
        orderData = _orderForMode(mode);
        orderData.orderSalt = nextOpenedFillableSalt++;
        orderData.orderSize = OPENED_FILL_SIZE;
        orderData.allowUnderfill = mode == SettlerMode.Partial;
        orderData.openDeadline = uint64(block.timestamp + openOffset);
        orderData.fillDeadline = uint64(orderData.openDeadline + 2 days);

        RolloverTypes.RolloverIntent memory draft = _openedFillableIntent(bytes32(0), orderData);
        orderData.rolloverIntentHash = _zeroDigestHash(draft);
    }

    function _openedFillableIntent(bytes32 orderDigest, RolloverTypes.OrderData memory orderData)
        internal
        view
        returns (RolloverTypes.RolloverIntent memory intent)
    {
        intent = _buildIntent(orderDigest, OPENED_FILL_SIZE, OPENED_FILL_SIZE);
        intent.nonce = orderData.orderSalt;
        intent.deadline = orderData.fillDeadline;
    }

    function _fillProbeTimestamp(RolloverTypes.OrderData memory orderData, uint64 timingSeed)
        internal
        pure
        returns (uint256)
    {
        uint8 timing = uint8(timingSeed % 5);
        if (timing == 0) {
            return orderData.openDeadline;
        }
        if (timing == 1) {
            return uint256(orderData.openDeadline)
                + (uint256(orderData.fillDeadline) - orderData.openDeadline) / 2;
        }
        if (timing == 2) {
            return orderData.fillDeadline;
        }
        if (timing == 3) {
            return uint256(orderData.fillDeadline) + 1 + uint256(timingSeed % 1 days);
        }
        return orderData.openDeadline > 0 ? uint256(orderData.openDeadline) - 1 : 0;
    }

    function _selectOpenedRecord(uint256 seed) internal view returns (bool found, uint256 index) {
        uint256 n = openedRecords.length;
        if (n == 0) {
            return (false, 0);
        }
        uint256 start = bound(seed, 0, n - 1);
        for (uint256 i; i < n; ++i) {
            uint256 candidate = (start + i) % n;
            if (!openedRecords[candidate].consumed) {
                return (true, candidate);
            }
        }
        return (false, 0);
    }

    function _tryOpenedFillableOpen(SettlerMode mode, RolloverTypes.OrderData memory orderData)
        internal
        returns (bool accepted)
    {
        try this.openedFillableOpenProbe(
            mode, _gasless(orderData), _signOrder(cptHolderPk, orderData)
        ) {
            accepted = true;
        } catch {
            accepted = false;
        }
    }

    function _tryOpenedFillableOpenFor(SettlerMode mode, RolloverTypes.OrderData memory orderData)
        internal
        returns (bool accepted)
    {
        bytes memory empty;
        try this.openedFillableOpenForProbe(
            mode, _gasless(orderData), _signOrder(cptHolderPk, orderData), empty
        ) {
            accepted = true;
        } catch {
            accepted = false;
        }
    }

    function _tryOpenedFillableDirect(
        SettlerMode mode,
        bytes32 orderDigest,
        RolloverTypes.OrderData memory orderData
    ) internal returns (bool accepted) {
        RolloverTypes.RolloverIntent memory intent = _openedFillableIntent(orderDigest, orderData);
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);
        try this.openedFillableDirectProbe(mode, orderDigest, orderData, intent, cptHolderSig) {
            accepted = true;
        } catch {
            accepted = false;
        }
    }

    function _tryOpenedFillableHelper(
        SettlerMode mode,
        bytes32 orderDigest,
        RolloverTypes.OrderData memory orderData
    ) internal returns (bool accepted) {
        RolloverTypes.RolloverIntent memory intent = _openedFillableIntent(orderDigest, orderData);
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);
        uint256 premiumCap = _openedFillablePremiumCap(orderData);
        try this.openedFillableHelperProbe(
            mode,
            _gasless(orderData),
            _signOrder(cptHolderPk, orderData),
            intent,
            cptHolderSig,
            premiumCap
        ) {
            accepted = true;
        } catch {
            accepted = false;
        }
    }

    function _openedFillablePremiumCap(RolloverTypes.OrderData memory orderData)
        internal
        pure
        returns (uint256)
    {
        return (OPENED_FILL_SIZE * orderData.minPremiumPerShare + 1e18 - 1) / 1e18;
    }

    /// @param mode Settler mode under test.
    /// @param order Input value under test.
    /// @param userSig Signature bytes under test.

    /// @notice External probe wrapper so the driver can catch `open` reverts.
    function openedFillableOpenProbe(
        SettlerMode mode,
        ERC7683Types.GaslessCrossChainOrder calldata order,
        bytes calldata userSig
    ) external {
        require(msg.sender == address(this), "OpenedFillable: only self");
        vm.prank(cptHolder);
        _settlerForMode(mode).openFor(order, userSig, "");
    }

    /// @param mode Settler mode under test.
    /// @param order Input value under test.
    /// @param userSig Signature bytes under test.
    /// @param originFillerData Encoded order or filler data under test.

    /// @notice External probe wrapper so the driver can catch `openFor` reverts.
    function openedFillableOpenForProbe(
        SettlerMode mode,
        ERC7683Types.GaslessCrossChainOrder calldata order,
        bytes calldata userSig,
        bytes calldata originFillerData
    ) external {
        require(msg.sender == address(this), "OpenedFillable: only self");
        _settlerForMode(mode).openFor(order, userSig, originFillerData);
    }

    /// @param mode Settler mode under test.
    /// @param orderDigest Order digest under test.
    /// @param orderData Encoded order or filler data under test.
    /// @param intent Rollover intent under test.
    /// @param cptHolderSig Signature bytes under test.

    /// @notice External probe wrapper so the driver can catch direct-fill reverts.
    function openedFillableDirectProbe(
        SettlerMode mode,
        bytes32 orderDigest,
        RolloverTypes.OrderData calldata orderData,
        RolloverTypes.RolloverIntent calldata intent,
        bytes calldata cptHolderSig
    ) external {
        require(msg.sender == address(this), "OpenedFillable: only self");
        _doRolloverAs(orderDigest, orderData, intent, OPENED_FILL_SIZE, filler);
        mode;
    }

    /// @param mode Settler mode under test.
    /// @param order Input value under test.
    /// @param userSig Signature bytes under test.
    /// @param intent Rollover intent under test.
    /// @param ignoredSig Ignored signature bytes under test.
    /// @param premiumCap Input value under test.

    /// @notice External probe wrapper so the driver can catch BaseFiller reverts.
    function openedFillableHelperProbe(
        SettlerMode mode,
        ERC7683Types.GaslessCrossChainOrder calldata order,
        bytes calldata userSig,
        RolloverTypes.RolloverIntent calldata intent,
        bytes calldata ignoredSig,
        uint256 premiumCap
    ) external {
        require(msg.sender == address(this), "OpenedFillable: only self");
        ignoredSig;
        ISettler targetSettler = _settlerForMode(mode);
        vm.prank(filler);
        baseFiller.execute(
            BaseFiller.FillerJob({
                settler: targetSettler,
                order: order,
                userSig: userSig,
                srcCst: IERC20(address(srcCst)),
                premiumToken: IERC20(address(premiumToken)),
                fillerSrcCst: OPENED_FILL_SIZE,
                intent: intent,
                premiumCap: premiumCap,
                minDstPerSrc: 0,
                fillerAuthSig: ""
            })
        );
    }
}
