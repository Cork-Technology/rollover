// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { FillScaffold } from "../base/FillScaffold.sol";
import { IOriginDataDriver, OriginDataHandler } from "./handlers/OriginDataHandler.sol";
import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import { LibRolloverOrder } from "src/libraries/LibRolloverOrder.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice Shared driver for N-INV-LIFECYCLE-ORIGINDATA-DIGEST-BINDING.
abstract contract OriginDataInvariantBase is FillScaffold, IOriginDataDriver {
    /// @notice Fill amount used by handler-authored orders.
    uint256 internal constant ORIGINDATA_FILL = 1_000e18;

    /// @notice Salt base reserved for this handler.
    uint64 internal constant ORIGINDATA_SALT_BASE = 80_000;

    /// @notice Handler under test.
    OriginDataHandler internal originDataHandler;

    /// @notice Canonical originData observation owned by the handler driver.
    struct OriginDataRecord {
        /// @notice Order digest key.
        bytes32 orderDigest;
        /// @notice Canonical single-envelope originData emitted/used for lifecycle calls.
        bytes originData;
    }

    /// @notice OriginData records available for later observations.
    OriginDataRecord[] internal originDataRecords;

    function _setUpOriginDataInvariant() internal {
        _approveFiller(type(uint256).max, type(uint256).max);
        originDataHandler = new OriginDataHandler(IOriginDataDriver(address(this)));
        targetContract(address(originDataHandler));

        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = originDataHandler.admitOrder.selector;
        selectors[1] = originDataHandler.observeOriginData.selector;
        targetSelector(FuzzSelector({ addr: address(originDataHandler), selectors: selectors }));
    }

    /// @inheritdoc IOriginDataDriver
    function driveOriginData(uint64 saltSeed, bool usePartial, bool directFill)
        external
        returns (bytes32 orderDigest, bytes32 originDataHash, bytes32 originDataDigest)
    {
        require(msg.sender == address(originDataHandler), "OriginData: only handler");
        RolloverTypes.OrderData memory orderData = _baseOrder();
        if (usePartial) {
            orderData = _usePartialSettler(orderData);
        }
        orderData.orderSize = ORIGINDATA_FILL;
        orderData.orderSalt = uint64(
            uint256(ORIGINDATA_SALT_BASE) + originDataRecords.length + uint256(saltSeed % 1024)
                * 10_000
        );

        RolloverTypes.RolloverIntent memory probe =
            _buildIntent(bytes32(0), ORIGINDATA_FILL, ORIGINDATA_FILL);
        orderData.rolloverIntentHash = _zeroDigestHash(probe);

        if (directFill) {
            orderDigest = _orderDigest(orderData);
            RolloverTypes.RolloverIntent memory intent =
                _buildIntent(orderDigest, ORIGINDATA_FILL, ORIGINDATA_FILL);
            _doRolloverAs(orderDigest, orderData, intent, ORIGINDATA_FILL, filler);
        } else {
            orderDigest = _openOrder(orderData);
        }

        bytes memory originData = _originData(orderData);
        originDataRecords.push(
            OriginDataRecord({ orderDigest: orderDigest, originData: originData })
        );
        return _observe(orderDigest, originData);
    }

    /// @inheritdoc IOriginDataDriver
    function observeOriginData(uint256 indexSeed)
        external
        view
        returns (
            bytes32 orderDigest,
            bytes32 originDataHash,
            bytes32 originDataDigest,
            bool skipped
        )
    {
        require(msg.sender == address(originDataHandler), "OriginData: only handler");
        uint256 n = originDataRecords.length;
        if (n == 0) {
            return (bytes32(0), bytes32(0), bytes32(0), true);
        }
        OriginDataRecord storage rec = originDataRecords[bound(indexSeed, 0, n - 1)];
        (orderDigest, originDataHash, originDataDigest) = _observe(rec.orderDigest, rec.originData);
    }

    function _observe(bytes32 orderDigest, bytes memory originData)
        internal
        view
        returns (bytes32, bytes32 originDataHash, bytes32 originDataDigest)
    {
        ERC7683Types.GaslessCrossChainOrder memory order =
            abi.decode(originData, (ERC7683Types.GaslessCrossChainOrder));
        RolloverTypes.OrderData memory decoded = LibRolloverOrder.decodeOrderDataMemory(order);
        originDataHash = keccak256(originData);
        originDataDigest = _orderDigest(decoded);
        return (orderDigest, originDataHash, originDataDigest);
    }
}
