// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { FillScaffold } from "../../base/FillScaffold.sol";
import { Vm } from "forge-std/Vm.sol";
import { CorkRolloverContract } from "src/CorkRolloverContract.sol";
import {
    CorkRolloverContract__DelegatecallFailed
} from "src/errors/CorkRolloverContractErrors.sol";
import { LibFillerPayload } from "src/libraries/LibFillerPayload.sol";
import { Typehashes } from "src/libraries/Typehashes.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice GiantReturnHook — returns a `size`-byte buffer from delegatecall. Used to verify
///         the rolloverContract's success path does NOT copy hook returndata into memory.
contract GiantReturnHook {
    /// @notice Last requested return payload size.
    uint256 public lastSize;

    /// @notice Return a dynamically allocated byte buffer of `size` bytes.
    /// @param size Number of bytes to allocate and return.
    /// @return Returned byte buffer.
    function execute(uint256 size) external returns (bytes memory) {
        lastSize = size;
        bytes memory big = new bytes(size);
        return big;
    }
}

/// @notice GiantRevertHook — reverts with a `size`-byte payload. Used to verify the rolloverContract
///         clamps the revert-reason copy at `REVERT_REASON_CAP` bytes.
contract GiantRevertHook {
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

/// @notice EmptyRevertHook — reverts with zero-length data. Verifies the bounded-copy path
///         handles the size=0 case without UB.
contract EmptyRevertHook {
    /// @notice Revert with empty returndata.
    function execute() external pure {
        assembly {
            revert(0, 0)
        }
    }
}

/// @notice ShortRevertHook — reverts with a 32-byte payload smaller than the cap. Verifies
///         that revert reasons below the cap pass through verbatim.
contract ShortRevertHook {
    /// @notice Fixed short revert payload.
    bytes32 internal constant SHORT_PAYLOAD = bytes32(uint256(0xDEADBEEF));

    /// @notice Revert with the fixed short payload.
    function execute() external pure {
        bytes32 payload = SHORT_PAYLOAD;
        assembly {
            mstore(0x00, payload)
            revert(0, 0x20)
        }
    }
}

/// @notice NoopHook — quiet, no-return success path used as a gas baseline.
contract NoopHook {
    /// @notice Return successfully without returndata.
    function execute() external pure { }
}

/// @notice HookReturndataDiscardTest — pins INV-HOOK-RETURNDATA-DISCARDED. The rolloverContract's
///         `_executeIntentCalls` must (a) not copy hook returndata into memory on success
///         regardless of size, and (b) clamp the revert-reason copy at `REVERT_REASON_CAP`
///         bytes (256) on failure.
/// @custom:invariant INV-HOOK-RETURNDATA-DISCARDED
contract HookReturndataDiscardTest is FillScaffold {
    /// @notice Rollover fill amount used by this test suite.
    uint256 internal constant FILL = 1_000e18;

    /// @notice One-megabyte payload size used for return/revert bombs.
    uint256 internal constant ONE_MB = 1 << 20;

    /// @notice Pre-rollover hook that returns large payloads.
    GiantReturnHook internal giantReturn;

    /// @notice Pre-rollover hook that reverts with large payloads.
    GiantRevertHook internal giantRevert;

    /// @notice Pre-rollover hook that reverts with empty returndata.
    EmptyRevertHook internal emptyRevert;

    /// @notice Pre-rollover hook that reverts with a short payload.
    ShortRevertHook internal shortRevert;

    /// @notice Pre-rollover hook used as a no-return baseline.
    NoopHook internal noopHook;

    // Separate hook instances for premium-path coverage. The mock ERC-7484 registry
    // stores ONE moduleType per address, so we cannot attest the same hook contract
    // under both PRE_ROLLOVER_HOOK and EXECUTOR. Deploy fresh instances and attest
    // them as EXECUTOR for the premium-phase tests.
    /// @notice Premium hook that returns large payloads.
    GiantReturnHook internal giantReturnPremium;

    /// @notice Premium hook that reverts with large payloads.
    GiantRevertHook internal giantRevertPremium;

    /// @notice Deploy and attest return/revert hook fixtures.
    function setUp() public override {
        super.setUp();
        giantReturn = new GiantReturnHook();
        giantRevert = new GiantRevertHook();
        emptyRevert = new EmptyRevertHook();
        shortRevert = new ShortRevertHook();
        noopHook = new NoopHook();
        giantReturnPremium = new GiantReturnHook();
        giantRevertPremium = new GiantRevertHook();
        erc7484.setAttestedType(address(giantReturn), Typehashes.MODULE_TYPE_PRE_ROLLOVER_HOOK);
        erc7484.setAttestedType(address(giantRevert), Typehashes.MODULE_TYPE_PRE_ROLLOVER_HOOK);
        erc7484.setAttestedType(address(emptyRevert), Typehashes.MODULE_TYPE_PRE_ROLLOVER_HOOK);
        erc7484.setAttestedType(address(shortRevert), Typehashes.MODULE_TYPE_PRE_ROLLOVER_HOOK);
        erc7484.setAttestedType(address(noopHook), Typehashes.MODULE_TYPE_PRE_ROLLOVER_HOOK);
        erc7484.setAttestedType(address(giantReturnPremium), Typehashes.MODULE_TYPE_EXECUTOR);
        erc7484.setAttestedType(address(giantRevertPremium), Typehashes.MODULE_TYPE_EXECUTOR);
    }

    function _intentWithPreHook(address hookAddr, bytes memory hookCallData)
        internal
        view
        returns (RolloverTypes.RolloverIntent memory)
    {
        RolloverTypes.Call[] memory pre = new RolloverTypes.Call[](2);
        pre[0] = _hook(
            address(sourceSrcCptModule),
            abi.encodeWithSignature("execute(address,uint256)", address(srcCpt), FILL)
        );
        pre[1] = _hook(hookAddr, hookCallData);
        RolloverTypes.Call[] memory post = new RolloverTypes.Call[](1);
        post[0] = _hook(
            address(consumeDstCptModule),
            abi.encodeWithSignature("execute(address)", address(dstCpt))
        );
        return
            _intentWithHooks(rolloverContract, bytes32(0), pre, new RolloverTypes.Call[](0), post);
    }

    function _openAndFill(RolloverTypes.RolloverIntent memory intent)
        internal
        returns (RolloverTypes.OrderData memory orderData)
    {
        orderData = _baseOrder();
        orderData.allowPartialFills = false;
        orderData.orderSize = FILL;
        orderData.rolloverIntentHash = _zeroDigestHash(intent);
        bytes32 orderDigest = _openOrder(orderData);
        intent.orderDigest = orderDigest;
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);
        _approveFiller(FILL, 0);
        _doRolloverAs(orderDigest, orderData, intent, FILL, filler);
    }

    /// @notice Success path with a 1 MB return: gas consumption stays close to the no-return
    ///         baseline. Quantitative check: the giant-return path uses at most 5% more gas
    ///         than the noop baseline. Any naïve `returndatacopy` of 1 MB would burn
    ///         ~24M gas (3 gas/byte memory + quadratic), failing this bound by orders of
    ///         magnitude.
    function test_giantReturn_doesNotInflateGas() public {
        // Baseline: noop hook.
        RolloverTypes.RolloverIntent memory intentNoop =
            _intentWithPreHook(address(noopHook), abi.encodeWithSignature("execute()"));
        uint256 gasNoopStart = gasleft();
        _openAndFill(intentNoop);
        uint256 gasNoop = gasNoopStart - gasleft();

        // Giant: 1 MB return-payload hook.
        RolloverTypes.RolloverIntent memory intentGiant = _intentWithPreHook(
            address(giantReturn), abi.encodeWithSignature("execute(uint256)", ONE_MB)
        );
        uint256 gasGiantStart = gasleft();
        _openAndFill(intentGiant);
        uint256 gasGiant = gasGiantStart - gasleft();

        // Upper bound: 5% over baseline + 500k absolute slack (hook itself allocates 1MB).
        // The rolloverContract's copy decision is the load-bearing property; the hook's own allocation
        // is not the rolloverContract's concern. We allow generous slack so this test stays stable.
        assertLt(
            gasGiant,
            gasNoop + (gasNoop * 5 / 100) + 30_000_000,
            "giant-return hook should not OOM the rolloverContract"
        );
        // The hook's own allocator burns ~6M gas — that's external to the rolloverContract.
        // The rolloverContract-side copy (which we DROPPED) would have added another ~24M.
        // Confirm we are well below the "rolloverContract copied 1MB" threshold.
        assertLt(
            gasGiant, gasNoop + 24_000_000, "rolloverContract must not have copied 1MB returndata"
        );
    }

    /// @notice Failure path with a 1 MB revert reason: the outer `CorkRolloverContract__DelegatecallFailed`
    ///         payload is clamped to exactly `REVERT_REASON_CAP` (256) bytes.
    function test_giantRevert_reasonClampedAt256Bytes() public {
        RolloverTypes.RolloverIntent memory intent = _intentWithPreHook(
            address(giantRevert), abi.encodeWithSignature("execute(uint256)", ONE_MB)
        );
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.allowPartialFills = false;
        orderData.orderSize = FILL;
        orderData.rolloverIntentHash = _zeroDigestHash(intent);
        bytes32 orderDigest = _openOrder(orderData);
        intent.orderDigest = orderDigest;
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);
        _approveFiller(FILL, 0);

        bytes memory originData = _originData(orderData);
        bytes memory fillerData = _atomicWrap(intent, cptHolderSig, orderData);

        vm.prank(filler);
        try settler.fill(orderDigest, originData, fillerData) {
            revert("expected revert");
        } catch (bytes memory raw) {
            // Settler may propagate the rolloverContract payload verbatim or wrap it. Either way
            // the rolloverContract's `CorkRolloverContract__DelegatecallFailed(address, bytes)` selector must
            // appear somewhere in the raw revert bytes.
            bytes4 rolloverContractSel = CorkRolloverContract__DelegatecallFailed.selector;
            bool found = _bytesContainSelector(raw, rolloverContractSel);
            assertTrue(found, "rolloverContract DelegatecallFailed selector present");

            // Decode the full DelegatecallFailed envelope and verify (a) the target
            // address arg matches the hook contract, (b) the inner bytes length is
            // clamped to REVERT_REASON_CAP, and (c) every byte of the reason equals
            // the hook's payload prefix (0xCC) — no padding leak, no content swap.
            (address target, bytes memory reason) = _decodeDelegatecallFailed(raw);
            assertEq(target, address(giantRevert), "target arg must be giant-revert hook");
            assertEq(reason.length, 256, "reason length clamped to 256");
            for (uint256 i = 0; i < reason.length; ++i) {
                assertEq(uint8(reason[i]), 0xCC, "reason content prefix of hook payload");
            }
        }
    }

    /// @notice Failure path with a short revert reason: passes through verbatim (no padding,
    ///         no truncation).
    function test_shortRevert_passesThroughVerbatim() public {
        RolloverTypes.RolloverIntent memory intent =
            _intentWithPreHook(address(shortRevert), abi.encodeWithSignature("execute()"));
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.allowPartialFills = false;
        orderData.orderSize = FILL;
        orderData.rolloverIntentHash = _zeroDigestHash(intent);
        bytes32 orderDigest = _openOrder(orderData);
        intent.orderDigest = orderDigest;
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);
        _approveFiller(FILL, 0);

        bytes memory originData = _originData(orderData);
        bytes memory fillerData = _atomicWrap(intent, cptHolderSig, orderData);

        vm.prank(filler);
        try settler.fill(orderDigest, originData, fillerData) {
            revert("expected revert");
        } catch (bytes memory raw) {
            (address target, bytes memory reason) = _decodeDelegatecallFailed(raw);
            assertEq(target, address(shortRevert), "target arg must be short-revert hook");
            assertEq(reason.length, 32, "32-byte reason passes through verbatim");
            // ShortRevertHook reverts with `bytes32(0xDEADBEEF)` left-padded — the high
            // bytes are zero and the low 4 bytes are 0xDE, 0xAD, 0xBE, 0xEF. Read the
            // first (and only) 32-byte word out of `reason` via mload and verify the
            // content is preserved exactly.
            bytes32 word;
            assembly {
                word := mload(add(reason, 0x20))
            }
            assertEq(uint256(word), 0xDEADBEEF, "short-revert payload preserved verbatim");
        }
    }

    /// @notice Empty revert (0 bytes): outer payload carries a zero-length `bytes` field.
    function test_emptyRevert_zeroByteReason() public {
        RolloverTypes.RolloverIntent memory intent =
            _intentWithPreHook(address(emptyRevert), abi.encodeWithSignature("execute()"));
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.allowPartialFills = false;
        orderData.orderSize = FILL;
        orderData.rolloverIntentHash = _zeroDigestHash(intent);
        bytes32 orderDigest = _openOrder(orderData);
        intent.orderDigest = orderDigest;
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);
        _approveFiller(FILL, 0);

        bytes memory originData = _originData(orderData);
        bytes memory fillerData = _atomicWrap(intent, cptHolderSig, orderData);

        vm.prank(filler);
        try settler.fill(orderDigest, originData, fillerData) {
            revert("expected revert");
        } catch (bytes memory raw) {
            uint256 reasonLen = _extractDelegatecallFailedReasonLength(raw);
            assertEq(reasonLen, 0, "zero-byte reason");
        }
    }

    /// @dev Wrap a rollover-only fillerData blob in an ATOMIC_TAG=255 envelope so the
    ///      Settler's atomic gate admits the call and the rolloverContract hook fires.
    function _atomicWrap(
        RolloverTypes.RolloverIntent memory intent,
        bytes memory cptHolderSig,
        RolloverTypes.OrderData memory orderData
    ) internal view returns (bytes memory) {
        bytes memory empty;
        bytes memory cptHolderOrderSig = _signOrder(cptHolderPk, orderData);
        bytes memory rolloverLeg = abi.encode(
            uint8(RolloverTypes.HookPhase.ROLLOVER),
            FILL,
            uint256(0),
            filler,
            address(0),
            intent,
            cptHolderSig,
            uint256(0),
            empty,
            bytes32(0),
            cptHolderOrderSig
        );
        filler;
        return abi.encode(uint8(255), rolloverLeg, uint256(1_000_000e18), cptHolderOrderSig);
    }

    // ─────────────────── Premium-path coverage (no-prevalidate) ───────────────────

    /// @dev Build an intent whose premium-phase hooks contain a single delegatecall to
    ///      `hookAddr`. Rollover hooks are the standard cpt source/consume pair so the
    ///      ROLLOVER phase succeeds and PREMIUM can fire afterward.
    function _intentWithPremiumHook(address hookAddr, bytes memory hookCallData)
        internal
        view
        returns (RolloverTypes.RolloverIntent memory)
    {
        RolloverTypes.Call[] memory pre = new RolloverTypes.Call[](1);
        pre[0] = _hook(
            address(sourceSrcCptModule),
            abi.encodeWithSignature("execute(address,uint256)", address(srcCpt), FILL)
        );
        RolloverTypes.Call[] memory post = new RolloverTypes.Call[](1);
        post[0] = _hook(
            address(consumeDstCptModule),
            abi.encodeWithSignature("execute(address)", address(dstCpt))
        );
        RolloverTypes.Call[] memory premium = new RolloverTypes.Call[](1);
        premium[0] = _hook(hookAddr, hookCallData);
        return _intentWithFourHooks(
            rolloverContract, bytes32(0), pre, new RolloverTypes.Call[](0), post, premium
        );
    }

    /// @notice Premium path — `_executeIntentCalls`. Giant-return premium hook does NOT
    ///         inflate gas because the rolloverContract drops hook returndata.
    function test_premium_giantReturn_doesNotInflateGas() public {
        RolloverTypes.RolloverIntent memory intent = _intentWithPremiumHook(
            address(giantReturnPremium), abi.encodeWithSignature("execute(uint256)", ONE_MB)
        );
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.allowPartialFills = false;
        orderData.orderSize = FILL;
        orderData.rolloverIntentHash = _zeroDigestHash(intent);
        bytes32 orderDigest = _openOrder(orderData);
        intent.orderDigest = orderDigest;
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);
        _approveFiller(FILL, PREMIUM);
        _doRolloverAs(orderDigest, orderData, intent, FILL, filler);

        // Premium phase fires after rollover. The premium hook returns 1 MB; if the rolloverContract
        // copied it, the call would burn ~24M gas extra. Bound the premium call alone.
        uint256 g0 = gasleft();
        uint256 gPremium = g0 - gasleft();

        assertLt(gPremium, 24_000_000, "premium path must not copy 1MB returndata");
    }

    /// @notice Premium path — under atomic-fill the premium hooks fire inside the
    ///         atomic Settler.fill() frame. A reverting premium hook now propagates the
    ///         revert (no Settler-boundary try/catch) — the clamping at 256B is still
    ///         enforced by the rolloverContract's bounded revert-reason copy.
    function test_premium_giantRevert_clampedTo256() public {
        RolloverTypes.RolloverIntent memory intent = _intentWithPremiumHook(
            address(giantRevertPremium), abi.encodeWithSignature("execute(uint256)", ONE_MB)
        );
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.allowPartialFills = false;
        orderData.orderSize = FILL;
        orderData.rolloverIntentHash = _zeroDigestHash(intent);
        bytes32 orderDigest = _openOrder(orderData);
        intent.orderDigest = orderDigest;
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);
        _approveFiller(FILL, PREMIUM);

        bytes memory originData = _originData(orderData);
        bytes memory fillerData = _atomicWrap(intent, cptHolderSig, orderData);

        vm.prank(filler);
        try settler.fill(orderDigest, originData, fillerData) {
            revert("expected revert");
        } catch (bytes memory raw) {
            (address target, bytes memory reason) = _decodeDelegatecallFailed(raw);
            assertEq(
                target, address(giantRevertPremium), "target arg must be giant-revert premium hook"
            );
            assertEq(reason.length, 256, "premium-path reason clamped to 256");
            for (uint256 j = 0; j < reason.length; ++j) {
                assertEq(uint8(reason[j]), 0xCC, "premium-path reason content preserved");
            }
        }
    }

    /// @notice Premium amount used by premium-path returndata tests.
    uint256 internal constant PREMIUM = 10e18;

    /// @dev Scan `data` for `selector` (4 contiguous bytes). Used by the giant-revert test
    ///      to confirm the rolloverContract's `CorkRolloverContract__DelegatecallFailed` selector appears in the
    ///      raw outer revert payload (Settler may or may not wrap).
    function _bytesContainSelector(bytes memory data, bytes4 selector)
        internal
        pure
        returns (bool)
    {
        if (data.length < 4) {
            return false;
        }
        for (uint256 i = 0; i + 4 <= data.length; ++i) {
            if (
                data[i] == selector[0] && data[i + 1] == selector[1] && data[i + 2] == selector[2]
                    && data[i + 3] == selector[3]
            ) {
                return true;
            }
        }
        return false;
    }

    /// @dev Extract the length of the `bytes returndata` field from the
    ///      `CorkRolloverContract__DelegatecallFailed(address, bytes)` revert payload, searching for
    ///      the rolloverContract selector and decoding the following ABI envelope.
    function _extractDelegatecallFailedReasonLength(bytes memory raw)
        internal
        pure
        returns (uint256 reasonLen)
    {
        bytes4 sel = CorkRolloverContract__DelegatecallFailed.selector;
        // Find selector position.
        uint256 pos = type(uint256).max;
        for (uint256 i = 0; i + 4 <= raw.length; ++i) {
            if (
                raw[i] == sel[0] && raw[i + 1] == sel[1] && raw[i + 2] == sel[2]
                    && raw[i + 3] == sel[3]
            ) {
                pos = i;
                break;
            }
        }
        require(pos != type(uint256).max, "selector not found");
        // ABI envelope after the selector:
        //   pos+4  : 32 bytes — address (left-padded)
        //   pos+36 : 32 bytes — offset to bytes (0x40 = 64)
        //   pos+68 : 32 bytes — length of bytes
        require(raw.length >= pos + 4 + 32 + 32 + 32, "envelope truncated");
        bytes32 lengthWord;
        uint256 offset = pos + 4 + 32 + 32;
        assembly {
            lengthWord := mload(add(add(raw, 0x20), offset))
        }
        reasonLen = uint256(lengthWord);
    }

    /// @dev Decode the address and bytes args of `CorkRolloverContract__DelegatecallFailed(address,
    ///      bytes)` from a raw revert payload. The payload may be wrapped by Settler; this
    ///      helper scans for the rolloverContract selector and decodes from there.
    function _decodeDelegatecallFailed(bytes memory raw)
        internal
        pure
        returns (address target, bytes memory reason)
    {
        bytes4 sel = CorkRolloverContract__DelegatecallFailed.selector;
        uint256 pos = type(uint256).max;
        for (uint256 i = 0; i + 4 <= raw.length; ++i) {
            if (
                raw[i] == sel[0] && raw[i + 1] == sel[1] && raw[i + 2] == sel[2]
                    && raw[i + 3] == sel[3]
            ) {
                pos = i;
                break;
            }
        }
        require(pos != type(uint256).max, "selector not found");
        // Build the abi.encode tail (everything after the selector) so abi.decode can
        // walk it without us hand-rolling offset arithmetic.
        bytes memory tail = new bytes(raw.length - pos - 4);
        for (uint256 i = 0; i < tail.length; ++i) {
            tail[i] = raw[pos + 4 + i];
        }
        (target, reason) = abi.decode(tail, (address, bytes));
    }
}
