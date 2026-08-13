// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { FillScaffold } from "../../base/FillScaffold.sol";
import { MockERC20 } from "../../mocks/MockERC20.sol";
import {
    LibPhoenixShareQuantum__OrderSizeNotQuantumAligned
} from "src/errors/LibPhoenixShareQuantumErrors.sol";
import {
    Settler__DstCstNotCanonical,
    Settler__ExactFillsNotSupported,
    Settler__FillAfterDeadline,
    Settler__FillDeadlineExceedsPoolExpiry,
    Settler__InvalidPremiumPaymentMode,
    Settler__OpenAfterOpenDeadline,
    Settler__OrderInTerminalState,
    Settler__PartialFillsNotSupported,
    Settler__RolloverContractNotDeployed,
    Settler__RolloverParamsDstCstMismatch,
    Settler__SamePoolId,
    Settler__SrcCstNotCanonical,
    Settler__UserMismatch,
    Settler__UserNotRolloverContractOwner,
    Settler__WrongDestinationChain,
    Settler__WrongOriginChain,
    Settler__ZeroOrderSize,
    Settler__ZeroPremiumRate
} from "src/errors/SettlerErrors.sol";
import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice Issue #137 — `resolve` / `resolveFor` must mirror the signature-free admission
///         shape (`_validateOrderCommon`), not the envelope-only `validateEnvelope`. Before the
///         fix the resolver projected a populated `ResolvedCrossChainOrder` for envelope-valid
///         but admission-invalid orders. These tests assert the resolver now rejects every
///         representative `_validateOrderCommon` failure, that valid output is unchanged, and
///         that `resolve` admits iff state-changing admission (`openFor`) admits.
contract ResolveAdmissionParityTest is FillScaffold {
    /// @notice Order size used across admission tests.
    uint256 internal constant ORDER = 1_000e18;

    /// @inheritdoc BaseTest
    function setUp() public override {
        super.setUp();
    }

    /*//////////////////////////////////////////////////////////////
                  REPRESENTATIVE _validateOrderCommon FAILURES
    //////////////////////////////////////////////////////////////*/

    /// @notice resolve rejects a wrong origin chain.
    function testRevert_resolve_wrongOriginChain() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        orderData.originChainId = orderData.originChainId + 1;
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        // Envelope binds order.originChainId to orderData.originChainId, so the envelope
        // check passes and the shape-level WrongOriginChain fires.
        g.originChainId = orderData.originChainId;
        vm.expectRevert(Settler__WrongOriginChain.selector);
        settler.resolveFor(g, "");
    }

    /// @notice resolve rejects a wrong destination chain.
    function testRevert_resolve_wrongDestinationChain() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        orderData.destinationChainId = orderData.destinationChainId + 1;
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        vm.expectRevert(Settler__WrongDestinationChain.selector);
        settler.resolveFor(g, "");
    }

    /// @notice resolve rejects zero orderSize.
    function testRevert_resolve_zeroOrderSize() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = 0;
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        vm.expectRevert(Settler__ZeroOrderSize.selector);
        settler.resolveFor(g, "");
    }

    /// @notice resolve rejects zero minPremiumPerShare.
    function testRevert_resolve_zeroMinPremiumPerShare() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        orderData.minPremiumPerShare = 0;
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        vm.expectRevert(Settler__ZeroPremiumRate.selector);
        settler.resolveFor(g, "");
    }

    /// @notice resolve rejects an invalid premium payment mode.
    function testRevert_resolve_invalidPremiumMode() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        orderData.premiumPaymentMode = 99;
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        vm.expectRevert(Settler__InvalidPremiumPaymentMode.selector);
        settler.resolveFor(g, "");
    }

    /// @notice resolve rejects same source/destination pool.
    function testRevert_resolve_samePoolId() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        orderData.dstCstToken = address(srcCst);
        orderData.rolloverParams.dstCstToken = address(srcCst);
        orderData.rolloverParams.dstPoolId = orderData.rolloverParams.srcPoolId;
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        vm.expectRevert(Settler__SamePoolId.selector);
        settler.resolveFor(g, "");
    }

    /// @notice resolve rejects a rollover-params dst-cST mirror mismatch.
    function testRevert_resolve_mirrorMismatch() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        orderData.rolloverParams.dstCstToken = address(0xDEAD);
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        vm.expectRevert(Settler__RolloverParamsDstCstMismatch.selector);
        settler.resolveFor(g, "");
    }

    /// @notice resolve rejects a non-factory rolloverContract.
    function testRevert_resolve_nonFactoryRolloverContract() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        orderData.rolloverContract = address(0xC0FFEE);
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        vm.expectRevert(
            abi.encodeWithSelector(Settler__RolloverContractNotDeployed.selector, orderData.user)
        );
        settler.resolveFor(g, "");
    }

    /// @notice resolve rejects user != rolloverContract.owner().
    function testRevert_resolve_userNotOwner() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        orderData.user = address(0xBEEF);
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        // Rebind the envelope user to the mutated owner so the envelope check passes and the
        // owner-binding check inside _validateOrderCommon is the one that fires.
        g.user = orderData.user;
        vm.expectRevert(
            abi.encodeWithSelector(
                Settler__UserNotRolloverContractOwner.selector,
                orderData.user,
                orderData.rolloverContract
            )
        );
        settler.resolveFor(g, "");
    }

    /// @notice resolve rejects a non-canonical source cST.
    function testRevert_resolve_nonCanonicalSrcCst() public {
        MockERC20 fakeSrc = new MockERC20("fakeSrc", "FSRC", 18);
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        // Keep the mirror check satisfied (rolloverParams.srcCstToken == srcCstToken) while the
        // pool's canonical cST stays srcCst, so the canonical-cST check fires.
        orderData.srcCstToken = address(fakeSrc);
        orderData.rolloverParams.srcCstToken = address(fakeSrc);
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        vm.expectRevert(Settler__SrcCstNotCanonical.selector);
        settler.resolveFor(g, "");
    }

    /// @notice resolve rejects a non-canonical destination cST.
    function testRevert_resolve_nonCanonicalDstCst() public {
        MockERC20 fakeDst = new MockERC20("fakeDst", "FDST", 18);
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        orderData.dstCstToken = address(fakeDst);
        orderData.rolloverParams.dstCstToken = address(fakeDst);
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        vm.expectRevert(Settler__DstCstNotCanonical.selector);
        settler.resolveFor(g, "");
    }

    /// @notice resolve rejects a quantum-misaligned orderSize.
    function testRevert_resolve_quantumMisaligned() public {
        // Rebind the source pool with 6-decimal collateral so the source-share quantum is 1e12
        // and orderSize = ORDER + 1 is misaligned.
        MockERC20 caSrc6 = new MockERC20("CA6", "CA6", 6);
        phoenixPool.bind(srcCst.poolId(), srcCst, srcCpt, caSrc6);

        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER + 1;
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        vm.expectRevert(
            abi.encodeWithSelector(
                LibPhoenixShareQuantum__OrderSizeNotQuantumAligned.selector,
                orderData.orderSize,
                10 ** (18 - 6)
            )
        );
        settler.resolveFor(g, "");
    }

    /// @notice resolve rejects fillDeadline at/after pool expiry.
    function testRevert_resolve_fillDeadlineExceedsPoolExpiry() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        uint256 srcExpiry = uint256(orderData.fillDeadline) - 1;
        srcCst.setExpiry(srcExpiry);
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        uint256 dstExpiry = dstCst.expiry();
        vm.expectRevert(
            abi.encodeWithSelector(
                Settler__FillDeadlineExceedsPoolExpiry.selector,
                orderData.fillDeadline,
                srcExpiry,
                dstExpiry
            )
        );
        settler.resolveFor(g, "");
    }

    /// @notice exact-mode resolver (settler) rejects a partial-flagged order.
    function testRevert_resolve_partialOrderOnExactSettler() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        orderData.allowPartialFills = true;
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        vm.expectRevert(Settler__PartialFillsNotSupported.selector);
        settler.resolveFor(g, "");
    }

    /// @notice partial-mode resolver (partialSettler) rejects an exact-flagged order.
    function testRevert_resolve_exactOrderOnPartialSettler() public {
        RolloverTypes.OrderData memory orderData = _usePartialSettler(_baseOrder());
        orderData.orderSize = ORDER;
        orderData.allowPartialFills = false;
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        vm.expectRevert(Settler__ExactFillsNotSupported.selector);
        partialSettler.resolveFor(g, "");
    }

    /// @notice resolveFor shares the resolver path: a representative admission failure reverts.
    function testRevert_resolveFor_rejectsAdmissionFailure() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = 0;
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        vm.expectRevert(Settler__ZeroOrderSize.selector);
        settler.resolveFor(g, "");
    }

    /*//////////////////////////////////////////////////////////////
                         STATE-AWARE RESOLVE
    //////////////////////////////////////////////////////////////*/

    /// @notice `None` orders still enforce the open-deadline admission ceiling.
    function testRevert_resolve_noneAfterOpenDeadline() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);

        vm.warp(orderData.openDeadline + 1);
        vm.expectRevert(Settler__OpenAfterOpenDeadline.selector);
        settler.resolveFor(g, "");
    }

    /// @notice Already-opened orders resolve after openDeadline until fillDeadline.
    function test_resolve_openedAfterOpenDeadlineBeforeFillDeadline() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory sig = _signOrder(cptHolderPk, orderData);
        settler.openFor(g, sig, "");

        vm.warp(orderData.openDeadline + 1);
        ERC7683Types.ResolvedCrossChainOrder memory resolved = settler.resolveFor(g, "");
        ERC7683Types.ResolvedCrossChainOrder memory resolvedFor = settler.resolveFor(g, "");

        assertEq(resolved.orderId, _orderDigest(orderData), "opened resolve orderId");
        assertEq(
            keccak256(abi.encode(resolvedFor)),
            keccak256(abi.encode(resolved)),
            "resolveFor matches resolve"
        );
    }

    /// @notice Opened-order resolve skips only openDeadline, not envelope binding checks.
    function testRevert_resolve_openedAfterOpenDeadlineStillChecksEnvelopeBinding() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory sig = _signOrder(cptHolderPk, orderData);
        settler.openFor(g, sig, "");

        g.user = address(0xBEEF);
        vm.warp(orderData.openDeadline + 1);
        vm.expectRevert(Settler__UserMismatch.selector);
        settler.resolveFor(g, "");
    }

    /// @notice Resolver rejects opened orders after fillDeadline.
    function testRevert_resolve_openedAfterFillDeadline() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory sig = _signOrder(cptHolderPk, orderData);
        settler.openFor(g, sig, "");

        vm.warp(orderData.fillDeadline + 1);
        vm.expectRevert(Settler__FillAfterDeadline.selector);
        settler.resolveFor(g, "");
    }

    /// @notice Resolver rejects terminal states even before fillDeadline.
    function testRevert_resolve_cancelledOrder() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory sig = _signOrder(cptHolderPk, orderData);
        settler.openFor(g, sig, "");

        bytes32 digest = _orderDigest(orderData);
        bytes memory cancelSig =
            _signCancelFor(orderData.settler, cptHolderPk, digest, orderData.orderSalt);
        settler.cancel(digest, _originData(orderData), cancelSig);

        vm.expectRevert(Settler__OrderInTerminalState.selector);
        settler.resolveFor(g, "");
    }

    /*//////////////////////////////////////////////////////////////
                        POSITIVE / PARITY REGRESSION
    //////////////////////////////////////////////////////////////*/

    /// @notice Valid orders still resolve, and the projection is unchanged: orderId equals the
    ///         canonical digest and the projected envelope fields match the signed order.
    function test_resolve_validOrderProjectionUnchanged() public view {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);

        ERC7683Types.ResolvedCrossChainOrder memory r = settler.resolveFor(g, "");
        assertEq(r.orderId, _orderDigest(orderData), "orderId must equal canonical digest");
        assertEq(r.user, orderData.user, "user unchanged");
        assertEq(r.originChainId, orderData.originChainId, "originChainId unchanged");
        assertEq(uint256(r.openDeadline), orderData.openDeadline, "openDeadline unchanged");
        assertEq(uint256(r.fillDeadline), orderData.fillDeadline, "fillDeadline unchanged");

        // originFillerData is ignored.
        ERC7683Types.ResolvedCrossChainOrder memory rf = settler.resolveFor(g, hex"deadbeef");
        assertEq(
            keccak256(abi.encode(rf)),
            keccak256(abi.encode(r)),
            "resolveFor projection must ignore originFillerData"
        );
    }

    /// @notice Parity: for a valid order, both `resolveFor` and state-changing admission
    ///         (`openFor`) succeed.
    function test_parity_validOrderAdmittedByBoth() public {
        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.orderSize = ORDER;
        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory sig = _signOrder(cptHolderPk, orderData);

        // resolveFor admits.
        settler.resolveFor(g, "");
        // state-changing admission admits.
        settler.openFor(g, sig, "");
        assertEq(
            uint8(settler.orderStatus(_orderDigest(orderData))),
            uint8(RolloverTypes.OrderStatus.Opened)
        );
    }

    /// @notice Parity: for an admission-invalid (but envelope-valid) order, both `resolveFor`
    ///         and `openFor` reject with the same selector. Asserts resolution admits iff
    ///         state-changing admission admits across representative non-signature shape mutations.
    function test_parity_invalidOrderRejectedByBothSameSelector() public {
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = Settler__ZeroOrderSize.selector;
        selectors[1] = Settler__ZeroPremiumRate.selector;
        selectors[2] = Settler__SamePoolId.selector;
        selectors[3] = Settler__RolloverParamsDstCstMismatch.selector;

        for (uint256 i = 0; i < selectors.length; i++) {
            RolloverTypes.OrderData memory orderData = _baseOrder();
            orderData.orderSize = ORDER;
            if (selectors[i] == Settler__ZeroOrderSize.selector) {
                orderData.orderSize = 0;
            } else if (selectors[i] == Settler__ZeroPremiumRate.selector) {
                orderData.minPremiumPerShare = 0;
            } else if (selectors[i] == Settler__SamePoolId.selector) {
                orderData.dstCstToken = address(srcCst);
                orderData.rolloverParams.dstCstToken = address(srcCst);
                orderData.rolloverParams.dstPoolId = orderData.rolloverParams.srcPoolId;
            } else {
                orderData.rolloverParams.dstCstToken = address(0xDEAD);
            }

            ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
            bytes memory sig = _signOrder(cptHolderPk, orderData);

            assertEq(
                _resolveForSelector(g),
                selectors[i],
                "resolveFor must reject with admission selector"
            );
            assertEq(
                _openForSelector(g, sig), selectors[i], "openFor must reject with the same selector"
            );
        }
    }

    /// @dev Returns the revert selector from `resolveFor`, or 0 if it did not revert.
    function _resolveForSelector(ERC7683Types.GaslessCrossChainOrder memory g)
        internal
        view
        returns (bytes4 sel)
    {
        try settler.resolveFor(g, "") returns (ERC7683Types.ResolvedCrossChainOrder memory) {
            return bytes4(0);
        } catch (bytes memory reason) {
            assembly {
                sel := mload(add(reason, 0x20))
            }
        }
    }

    /// @dev Returns the revert selector from `openFor`, or 0 if it did not revert.
    function _openForSelector(ERC7683Types.GaslessCrossChainOrder memory g, bytes memory sig)
        internal
        returns (bytes4 sel)
    {
        try settler.openFor(g, sig, "") {
            return bytes4(0);
        } catch (bytes memory reason) {
            assembly {
                sel := mload(add(reason, 0x20))
            }
        }
    }
}
