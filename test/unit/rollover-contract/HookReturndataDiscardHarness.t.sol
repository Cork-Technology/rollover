// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Test } from "forge-std/Test.sol";

import { CorkRolloverContract } from "src/CorkRolloverContract.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

import { CorkRolloverContractHarness } from "../../harnesses/CorkRolloverContractHarness.sol";
import {
    CorkRolloverContract__DelegatecallFailed
} from "src/errors/CorkRolloverContractErrors.sol";

/// @notice ReturnSizedHook — returns a `size`-byte buffer from delegatecall. Allows the
///         harness tests to exercise the success path on any payload size.
contract ReturnSizedHook {
    /// @notice Return a dynamically allocated byte buffer of `size` bytes.
    /// @param size Number of bytes to allocate and return.
    /// @return Returned byte buffer.
    function execute(uint256 size) external pure returns (bytes memory) {
        return new bytes(size);
    }
}

/// @notice RevertSizedHook — reverts with a `size`-byte payload whose contents are a
///         repeating byte (0xCC). Allows the harness tests to assert clamping AND
///         content preservation across non-word-aligned sizes.
contract RevertSizedHook {
    /// @notice Revert with a `size`-byte payload.
    /// @param size Number of bytes to include in the revert payload.
    function execute(uint256 size) external pure {
        bytes memory payload = new bytes(size);
        for (uint256 i = 0; i < size; ++i) {
            payload[i] = bytes1(uint8(0xCC));
        }
        assembly {
            revert(add(payload, 0x20), size)
        }
    }
}

/// @notice HookReturndataDiscardHarnessTest — pins INV-HOOK-RETURNDATA-DISCARDED at the
///         helper level. Uses `CorkRolloverContractHarness.exposed_delegatecallHookDiscardReturndata`
///         so each assertion targets the assembly helper directly, with no surrounding
///         rollover-fill machinery to dilute the signal.
/// @custom:invariant INV-HOOK-RETURNDATA-DISCARDED
contract HookReturndataDiscardHarnessTest is Test {
    /// @notice One-megabyte payload size used for return/revert bombs.
    uint256 internal constant ONE_MB = 1 << 20;

    /// @notice CorkRolloverContract harness exposing the bounded delegatecall helper.
    CorkRolloverContractHarness internal harness;

    /// @notice Hook that returns byte buffers of arbitrary size.
    ReturnSizedHook internal returnHook;

    /// @notice Hook that reverts with byte buffers of arbitrary size.
    RevertSizedHook internal revertHook;

    /// @notice Deploy helper-level return/revert hook fixtures.
    function setUp() public {
        harness = new CorkRolloverContractHarness();
        returnHook = new ReturnSizedHook();
        revertHook = new RevertSizedHook();
    }

    function _hook(address target, bytes memory data)
        internal
        pure
        returns (RolloverTypes.Call memory)
    {
        return RolloverTypes.Call({
            target: target, callData: data, value: 0, allowFailure: false, isDelegateCall: true
        });
    }

    // ─────────────────────────── Success path ───────────────────────────

    /// @notice Targeted gas: helper-only path, no full-fill machinery. RolloverContract overhead on a
    ///         1 MB return-bomb is bounded near the noop baseline. Tight slack (~50k) on top
    ///         of the noop call cost — the asm out=(0,0) does NOT touch the 1 MB returndata
    ///         buffer, so the rolloverContract-side cost is constant. The 1 MB allocation by the hook
    ///         itself is external to the helper and is the same in baseline and giant cases?
    ///         No — only the giant case allocates 1 MB. The slack absorbs that allocator
    ///         cost (≈6 M for 1 MB). We compare against the *naive copy* threshold which
    ///         would add another ~3 gas/byte = ~3 M for the linear copy plus quadratic
    ///         memory expansion. Bound: helper-side overhead < 1 M gas above baseline once
    ///         the hook's own allocation is subtracted out by using the same hook for both
    ///         (size=0 return vs size=1MB return).
    function test_giantReturn_targetedGas() public {
        RolloverTypes.Call memory zeroCall =
            _hook(address(returnHook), abi.encodeWithSignature("execute(uint256)", uint256(0)));
        RolloverTypes.Call memory giantCall =
            _hook(address(returnHook), abi.encodeWithSignature("execute(uint256)", ONE_MB));

        // Warm both targets so the gas accounting reflects steady-state, not first-touch.
        harness.exposed_delegatecallHookDiscardReturndata(zeroCall);

        uint256 g0 = gasleft();
        harness.exposed_delegatecallHookDiscardReturndata(zeroCall);
        uint256 gZero = g0 - gasleft();

        uint256 g1 = gasleft();
        harness.exposed_delegatecallHookDiscardReturndata(giantCall);
        uint256 gGiant = g1 - gasleft();

        // The hook's own 1 MB allocator costs ~6 M gas. The rolloverContract's helper costs 0 extra
        // because out=(0,0) discards returndata. A naïve `returndatacopy(reason, 0, 1MB)`
        // followed by ABI-encoded re-emission would add at minimum ~3 M gas (3 gas/byte
        // copy) + quadratic memory expansion. We bound the giant case at hook-allocator +
        // 1 M slack so any regression that re-introduces a copy fails this test loudly.
        uint256 hookAllocatorBudget = 8_000_000;
        uint256 rolloverContractHelperSlack = 1_000_000;
        assertLt(
            gGiant,
            gZero + hookAllocatorBudget + rolloverContractHelperSlack,
            "rolloverContract helper added measurable cost on a 1MB return"
        );

        // Sanity: the asm path never costs more than the hook itself; verify our zero-size
        // baseline is small (no inadvertent copy of even an empty buffer).
        assertLt(gZero, 50_000, "zero-size return baseline must stay small");
    }

    /// @notice Success path with a 32 KB return: rolloverContract helper cost stays constant — the
    ///         out=(0,0) decision is independent of returndatasize. Compares to a same-shape
    ///         32-byte return.
    function test_mediumReturn_helperCostIsConstant() public {
        RolloverTypes.Call memory smallCall =
            _hook(address(returnHook), abi.encodeWithSignature("execute(uint256)", uint256(32)));
        RolloverTypes.Call memory mediumCall = _hook(
            address(returnHook), abi.encodeWithSignature("execute(uint256)", uint256(32_768))
        );

        // Warm both.
        harness.exposed_delegatecallHookDiscardReturndata(smallCall);

        uint256 gs0 = gasleft();
        harness.exposed_delegatecallHookDiscardReturndata(smallCall);
        uint256 gSmall = gs0 - gasleft();

        uint256 gm0 = gasleft();
        harness.exposed_delegatecallHookDiscardReturndata(mediumCall);
        uint256 gMedium = gm0 - gasleft();

        // Both cases differ only in the hook-side `new bytes(n)` allocation cost. The rolloverContract
        // helper itself adds no per-byte cost. Bound: medium minus small < 2 M gas (the hook
        // alone costs ~150 k for 32 KB allocation + zero-fill); rolloverContract contribution is zero.
        assertLt(gMedium - gSmall, 2_000_000, "rolloverContract helper cost grew with return size");
    }

    // ─────────────────────────── Failure path: clamping ───────────────────────────

    /// @notice 1 MB revert: outer payload is exactly 256 B and the bytes content is the
    ///         first 256 B of the hook's payload (0xCC repeated).
    function test_giantRevert_clampedTo256_andContent() public {
        RolloverTypes.Call memory call =
            _hook(address(revertHook), abi.encodeWithSignature("execute(uint256)", ONE_MB));

        try harness.exposed_delegatecallHookDiscardReturndata(call) {
            revert("expected revert");
        } catch (bytes memory raw) {
            (address target, bytes memory reason) = _decodeDelegatecallFailed(raw);
            assertEq(target, address(revertHook), "target arg must match hook address");
            assertEq(reason.length, 256, "reason length clamped to REVERT_REASON_CAP");
            for (uint256 i = 0; i < reason.length; ++i) {
                assertEq(uint8(reason[i]), 0xCC, "reason content must be hook payload prefix");
            }
        }
    }

    /// @notice 32-byte revert: passes through verbatim, content preserved.
    function test_word_revert_verbatim() public {
        _assertRevertContent(32);
    }

    /// @notice 1-byte revert: smallest non-empty, exercises size%32 == 1 padding edge.
    function test_oneByte_revert_verbatim() public {
        _assertRevertContent(1);
    }

    /// @notice 31-byte revert: size just below a word, exercises size%32 == 31 padding edge.
    function test_thirtyOneByte_revert_verbatim() public {
        _assertRevertContent(31);
    }

    /// @notice 255-byte revert: size just below the cap, exercises size%32 == 31 plus
    ///         near-cap copy path.
    function test_twoFiftyFiveByte_revert_verbatim() public {
        _assertRevertContent(255);
    }

    /// @notice 256-byte revert: equal to cap, content preserved verbatim (no truncation).
    function test_atCap_revert_verbatim() public {
        _assertRevertContent(256);
    }

    /// @notice 257-byte revert: cap+1, content clamped to first 256 bytes.
    function test_capPlusOne_revert_clamped() public {
        RolloverTypes.Call memory call =
            _hook(address(revertHook), abi.encodeWithSignature("execute(uint256)", uint256(257)));

        try harness.exposed_delegatecallHookDiscardReturndata(call) {
            revert("expected revert");
        } catch (bytes memory raw) {
            (address target, bytes memory reason) = _decodeDelegatecallFailed(raw);
            assertEq(target, address(revertHook), "target arg must match hook address");
            assertEq(reason.length, 256, "reason clamped to REVERT_REASON_CAP");
            for (uint256 i = 0; i < reason.length; ++i) {
                assertEq(uint8(reason[i]), 0xCC, "reason content must be hook payload prefix");
            }
        }
    }

    /// @notice 0-byte revert: outer payload carries a zero-length bytes field.
    function test_emptyRevert_zeroLength() public {
        RolloverTypes.Call memory call =
            _hook(address(revertHook), abi.encodeWithSignature("execute(uint256)", uint256(0)));

        try harness.exposed_delegatecallHookDiscardReturndata(call) {
            revert("expected revert");
        } catch (bytes memory raw) {
            (address target, bytes memory reason) = _decodeDelegatecallFailed(raw);
            assertEq(target, address(revertHook), "target arg must match hook address");
            assertEq(reason.length, 0, "empty revert produces zero-length reason");
        }
    }

    // ─────────────────────────── Helpers ───────────────────────────

    /// @dev Drive a `size`-byte revert through the helper and assert the outer payload
    ///      contains the rolloverContract selector, the correct target address, AND the full content
    ///      verbatim (no truncation, no padding leak). Used for sizes ≤ cap.
    function _assertRevertContent(uint256 size) internal {
        require(size <= 256, "_assertRevertContent: use clamped helper for sizes > cap");
        RolloverTypes.Call memory call =
            _hook(address(revertHook), abi.encodeWithSignature("execute(uint256)", size));

        try harness.exposed_delegatecallHookDiscardReturndata(call) {
            revert("expected revert");
        } catch (bytes memory raw) {
            (address target, bytes memory reason) = _decodeDelegatecallFailed(raw);
            assertEq(target, address(revertHook), "target arg must match hook address");
            assertEq(reason.length, size, "reason length matches verbatim");
            for (uint256 i = 0; i < reason.length; ++i) {
                assertEq(uint8(reason[i]), 0xCC, "reason content must be hook payload");
            }
        }
    }

    /// @dev Decode `CorkRolloverContract__DelegatecallFailed(address, bytes)` from raw revert bytes.
    ///      The harness returns the rolloverContract payload directly (no Settler wrapping).
    function _decodeDelegatecallFailed(bytes memory raw)
        internal
        pure
        returns (address target, bytes memory reason)
    {
        require(raw.length >= 4, "raw too short");
        bytes4 sel = CorkRolloverContract__DelegatecallFailed.selector;
        bytes4 head;
        assembly {
            head := mload(add(raw, 0x20))
        }
        require(head == sel, "unexpected revert selector");
        // Strip the 4-byte selector and abi.decode the (address, bytes) tail.
        bytes memory tail = new bytes(raw.length - 4);
        for (uint256 i = 0; i < tail.length; ++i) {
            tail[i] = raw[i + 4];
        }
        (target, reason) = abi.decode(tail, (address, bytes));
    }
}
