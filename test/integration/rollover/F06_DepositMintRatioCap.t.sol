// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { FillScaffold } from "../../base/FillScaffold.sol";
import { MockERC20 } from "../../mocks/MockERC20.sol";
import { MockCpt, MockPhoenixPoolManager } from "../../mocks/MockPhoenix.sol";
import { CorkRolloverContract } from "src/CorkRolloverContract.sol";
import { CorkRolloverContract__DepositOverMint } from "src/errors/CorkRolloverContractErrors.sol";
import { MarketId } from "src/interfaces/external/phoenix/IPoolManager.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice Regression coverage: `_depositLeg` caps the observed dstCST mint at the
///         canonical Phoenix `previewDeposit` quote (INV-DST-CST-MINT-RATIO-BOUNDED).
///
///         Before this guard, `_depositLeg` derived `sharesOut` from a balance delta with no upper
///         bound on what the PoolManager was permitted to mint. A buggy / governance-
///         compromised / future-upgraded Phoenix could over-mint dstCST relative to
///         `caForDeposit`, inflating per-order share supply against fixed CA backing —
///         honest fillers pay inflated premium for shares whose Phoenix-side redemption
///         value is degraded.
///
///         Current behavior: `_depositLeg` quotes the canonical mint via
///         `IPoolManager.previewDeposit(dstPoolId, caForDeposit)` and reverts
///         `CorkRolloverContract__DepositOverMint(sharesOut, canonical)` when the observed mint
///         exceeds the quote. Under-mint (future Phoenix protocol-fee models) remains
///         allowed by design.
contract F06_DepositMintRatioCapTest is FillScaffold {
    /// @notice 2x over-mint → revert.
    function testRevert_F06_overMint2x_revertsAtDepositLeg() public {
        // Phoenix mints 2 dstCST per 1 caForDeposit while previewDeposit still reports the
        // canonical 1:1. The rolloverContract's local-delta sharesOut MUST exceed `canonical` and
        // trip the gate.
        phoenixPool.setPartialDeposit(dstCst.poolId(), 2, 1);

        (
            bytes32 orderDigest,
            RolloverTypes.OrderData memory orderData,
            RolloverTypes.RolloverIntent memory intent,,
            uint256 fillAmount
        ) = _openF06Order(11);

        vm.expectPartialRevert(CorkRolloverContract__DepositOverMint.selector);
        _doRolloverAs(orderDigest, orderData, intent, fillAmount, filler);
    }

    /// @notice 10x over-mint → revert (extreme variant).
    function testRevert_F06_overMint10x_revertsAtDepositLeg() public {
        phoenixPool.setPartialDeposit(dstCst.poolId(), 10, 1);

        (
            bytes32 orderDigest,
            RolloverTypes.OrderData memory orderData,
            RolloverTypes.RolloverIntent memory intent,,
            uint256 fillAmount
        ) = _openF06Order(12);

        vm.expectPartialRevert(CorkRolloverContract__DepositOverMint.selector);
        _doRolloverAs(orderDigest, orderData, intent, fillAmount, filler);
    }

    /// @notice Canonical 1:1 mint (no `setPartialDeposit` knob) → passes (happy-path
    ///         regression that the gate does not over-fire).
    function test_F06_canonicalMint_passes() public {
        (
            bytes32 orderDigest,
            RolloverTypes.OrderData memory orderData,
            RolloverTypes.RolloverIntent memory intent,,
            uint256 fillAmount
        ) = _openF06Order(13);

        _doRolloverAs(orderDigest, orderData, intent, fillAmount, filler);
    }

    /// @notice Under-mint (99/100 — simulates a future Phoenix 1% protocol fee) → passes.
    ///         The gate is strictly an UPPER bound; under-mint is intentionally allowed.
    function test_F06_underMint_allowed_belowCanonical() public {
        phoenixPool.setPartialDeposit(dstCst.poolId(), 99, 100);

        (
            bytes32 orderDigest,
            RolloverTypes.OrderData memory orderData,
            RolloverTypes.RolloverIntent memory intent,,
            uint256 fillAmount
        ) = _openF06Order(14);

        _doRolloverAs(orderDigest, orderData, intent, fillAmount, filler);
    }

    /// @notice Non-18-decimal CA path. The rolloverContract reads the canonical mint via the
    ///         PoolManager's `previewDeposit`, which normalizes the native-decimal CA
    ///         input to the canonical 18-decimal share output. Validates the mock's
    ///         normalization (`caIn * 10**(18-d)`) and the rolloverContract's gate handles
    ///         non-18-decimal caDst correctly. Pure mock-level check — `_depositLeg` will
    ///         consume the same `previewDeposit` surface in production.
    function test_F06_nonEighteenDecimalCa_normalizedCanonical() public {
        // Fresh mock pool with a 6-dec CA, bound under a unique MarketId. The pool's
        // previewDeposit MUST scale up to 18-dec space: 1 caUSDC (1e6) → 1e18 shares.
        MockPhoenixPoolManager pm = new MockPhoenixPoolManager();
        MockERC20 ca6 = new MockERC20("CA6", "CA6", 6);
        MockERC20 cst6 = new MockERC20("cST6", "C6", 18);
        MockCpt cpt6 = new MockCpt("cPT6", "P6");
        pm.bind(cst6.poolId(), cst6, cpt6, ca6);

        uint256 caIn = 1_000 * 1e6; // 1000 USDC in native 6-dec units.
        uint256 expectedCanonical = 1_000 * 1e18; // Same amount normalized to 18-dec.
        uint256 quoted = pm.previewDeposit(cst6.poolId(), caIn);
        assertEq(quoted, expectedCanonical, "previewDeposit must scale 6-dec CA to 18-dec shares");
    }

    /// @notice The cap must reference the PRE-deposit canonical quote, not a post-deposit
    ///         re-sample. The mock mints 2x (`setPartialDeposit`) AND inflates `previewDeposit`
    ///         to 2x once a `deposit` has run (`setPostDepositQuote`), modelling a hypothetical
    ///         future Phoenix whose quote becomes state-dependent after the mutating deposit.
    ///
    ///         A correct PRE-deposit sample reads canonical == 1x == `fillAmount`, so the observed
    ///         2x mint trips the gate and the error payload carries the pre-deposit canonical
    ///         (`fillAmount`). A buggy POST-deposit re-sample would read canonical == 2x ==
    ///         `2 * fillAmount`, leaving `sharesOut == canonical` and letting the over-mint slip
    ///         through. The exact-payload `expectRevert` below pins the canonical to the
    ///         pre-deposit value (INV-DST-CST-MINT-RATIO-BOUNDED).
    function testRevert_F06_preDepositQuoteDrivesCap() public {
        phoenixPool.setPartialDeposit(dstCst.poolId(), 2, 1);
        phoenixPool.setPostDepositQuote(dstCst.poolId(), 2, 1);

        (
            bytes32 orderDigest,
            RolloverTypes.OrderData memory orderData,
            RolloverTypes.RolloverIntent memory intent,,
            uint256 fillAmount
        ) = _openF06Order(17);

        // Pre-deposit canonical (1:1) == fillAmount; observed 2x mint == 2 * fillAmount.
        bytes memory expected = abi.encodeWithSelector(
            CorkRolloverContract__DepositOverMint.selector, 2 * fillAmount, fillAmount
        );
        vm.expectRevert(expected);
        _doRolloverAs(orderDigest, orderData, intent, fillAmount, filler);
    }

    /// @notice The named error carries (sharesOut, canonical) so off-chain tooling can
    ///         observe the ratio. We force a 3x over-mint and decode the revert payload.
    function testRevert_F06_errorCarriesSharesOutAndCanonical() public {
        phoenixPool.setPartialDeposit(dstCst.poolId(), 3, 1);

        (
            bytes32 orderDigest,
            RolloverTypes.OrderData memory orderData,
            RolloverTypes.RolloverIntent memory intent,,
            uint256 fillAmount
        ) = _openF06Order(16);

        // `caForDeposit` mirrors the rolloverContract's local computation; with the harness having
        // no pre/mid hooks that touch caDst, `caForDeposit == fillAmount` and canonical
        // (1:1) == fillAmount. A 3x over-mint produces sharesOut == 3 * fillAmount.
        bytes memory expected = abi.encodeWithSelector(
            CorkRolloverContract__DepositOverMint.selector, 3 * fillAmount, fillAmount
        );
        vm.expectRevert(expected);
        _doRolloverAs(orderDigest, orderData, intent, fillAmount, filler);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Build, open and approve an exact-mode F-06 order. Mirrors the
    ///      PartialFillerRolloverFields harness but uses the default ExactSettler and a
    ///      per-test orderSalt to keep digests unique.
    function _openF06Order(uint64 salt)
        internal
        returns (
            bytes32 orderDigest,
            RolloverTypes.OrderData memory orderData,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig,
            uint256 fillAmount
        )
    {
        orderData = _baseOrder();
        orderData.orderSalt = salt;
        fillAmount = orderData.orderSize;

        intent = _buildIntent(bytes32(0), fillAmount, fillAmount);
        orderData.rolloverIntentHash = _zeroDigestHash(intent);
        orderDigest = _openOrder(orderData);
        intent.orderDigest = orderDigest;
        cptHolderSig = _signOrder(cptHolderPk, orderData);

        _approveFiller(fillAmount, 0);
    }
}
