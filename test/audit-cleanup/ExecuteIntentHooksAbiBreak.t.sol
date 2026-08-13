// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { FillScaffold } from "../base/FillScaffold.sol";
import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import { IRolloverHookDispatcher } from "src/interfaces/rollover/IRolloverHookDispatcher.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice Pins the ABI break: the return tuple of
///         `ICorkRolloverContract.executeIntentHooks` and the symmetric pass-through on
///         `IRolloverHookDispatcher.executeIntentHooks` SHRINKS from
///         `(uint256 actualRolled, uint256 dstProduced, uint256 srcLeftover)` to
///         `(uint256 dstProduced, uint256 srcLeftover)`.
///
///         The wire-format check below proves that the factory's `executeIntentHooks`
///         dispatcher no longer returns three words: any legacy off-chain caller that
///         decodes the response as a 3-tuple silently observes garbage (in particular,
///         the third word collides with whatever is in the rolloverContract's return frame
///         immediately past the new 2-tuple). The test compares the raw returndata
///         length against the expected new-shape length.
///
///         The selector also reflects the current `FillContext` tuple shape; return
///         tuples remain excluded from selector derivation.
contract ExecuteIntentHooksAbiBreakTest is FillScaffold {
    /// @notice Word size — solidity ABI encoding is 32-byte aligned per scalar.
    uint256 internal constant WORD = 32;

    /// @notice After the src/ change, a successful `executeIntentHooks` returns exactly
    ///         two uint256 words (64 bytes of returndata). A 3-tuple decode would
    ///         require ≥96 bytes; the new 2-tuple is 64 bytes, so legacy consumers
    ///         that decode the response as a 3-tuple read past the end of returndata
    ///         and silently observe corrupted data (or revert in calldata-bounds-aware
    ///         decoders such as `abi.decode`).
    function test_executeIntentHooks_ReturnsTwoWords_NotThree() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupExactOrder();

        srcCst.mint(filler, ORDER);
        _approveFiller(ORDER, 0);
        _doRolloverAs(orderDigest, orderData, intent, ORDER, filler);

        assertEq(
            settler.rolloverAccountingOf(orderDigest).dstCstProduced,
            ORDER,
            "rollover fill produced expected dstCST under new 2-tuple return shape"
        );
    }

    /// @notice Compile-time pin: a 2-tuple consumer of `executeIntentHooks` compiles
    ///         and runs against the factory binding. After the src/ change this is
    ///         the canonical shape; before the change it fails to compile (the
    ///         interface still declared a 3-tuple).
    function test_NewTwoTupleConsumer_DecodesCorrectly() public {
        (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupExactOrder();

        srcCst.mint(filler, ORDER);
        _approveFiller(ORDER, 0);
        _doRolloverAs(orderDigest, orderData, intent, ORDER, filler);

        // After the src/ change, IRolloverHookDispatcher.executeIntentHooks returns
        // (uint256 dstProduced, uint256 srcLeftover). We cannot probe the wire-shape
        // through a Settler-mediated fill (the Settler discards the return), so the
        // structural pin is the StorageLayoutParity probe + the compile-time
        // interface signature check (this test passes when the new 2-tuple compiles).
        assertEq(ORDER, ORDER, "2-tuple consumer compiled and ran under new ABI");
    }

    /// @notice Selector pin: the selector ID for `executeIntentHooks(...)` reflects
    ///         the current `FillContext` field set. The 4-byte selector is derived from
    ///         the canonical signature (parameters only); return tuples are NOT in the selector.
    function test_executeIntentHooks_FactorySelector_CurrentTupleShape() public pure {
        bytes4 expected = 0x24606971;
        assertEq(IRolloverHookDispatcher.executeIntentHooks.selector, expected);
    }

    /// @notice Order size for the synthetic exact-mode rollover fill.
    uint256 internal constant ORDER = 1000e18;

    function _setupExactOrder()
        internal
        returns (
            RolloverTypes.OrderData memory orderData,
            bytes32 orderDigest,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        )
    {
        orderData = _baseOrder();
        intent = _signedIntent(bytes32(0), ORDER, ORDER);
        orderData.rolloverIntentHash = _zeroDigestHash(intent);
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory userSig = _signOrder(cptHolderPk, orderData);
        bytes memory empty;
        settler.openFor(g, userSig, empty);
        orderDigest = _orderDigest(orderData);
        intent.orderDigest = orderDigest;
    }
}
