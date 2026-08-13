// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../base/BaseTest.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { BaseFiller } from "src/BaseFiller.sol";
import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import { ISettler } from "src/interfaces/settlers/ISettler.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice BaseFiller cross-cutting invariants — filler-auth signature gate and CPT containment.
/// @custom:invariant INV-FILLER-AUTH
/// @custom:invariant INV-CPT-CONTAINED
contract BaseFillerInvariantsTest is BaseTest {
    /// @notice fresh filler holds zero token balance.
    function test_freshFillerHoldsZeroTokenBalance() public view {
        assertEq(srcCst.balanceOf(address(baseFiller)), 0);
        assertEq(dstCst.balanceOf(address(baseFiller)), 0);
        assertEq(premiumToken.balanceOf(address(baseFiller)), 0);
    }

    /// @notice fresh filler has no stuck approvals.
    function test_freshFillerHasNoStuckApprovals() public view {
        assertEq(srcCst.allowance(address(baseFiller), address(settler)), 0);
        assertEq(dstCst.allowance(address(baseFiller), address(settler)), 0);
        assertEq(premiumToken.allowance(address(baseFiller), address(settler)), 0);
        assertEq(srcCst.allowance(address(baseFiller), address(partialSettler)), 0);
        assertEq(dstCst.allowance(address(baseFiller), address(partialSettler)), 0);
        assertEq(premiumToken.allowance(address(baseFiller), address(partialSettler)), 0);
    }

    /// @notice reverts when execute against zero settler.
    function testRevert_executeAgainstZeroSettler() public {
        ERC7683Types.GaslessCrossChainOrder memory g;
        bytes memory empty;
        RolloverTypes.RolloverIntent memory intent = _emptyIntent(rolloverContract, bytes32(0));
        vm.expectRevert();
        baseFiller.execute(
            BaseFiller.FillerJob({
                settler: ISettler(address(0)),
                order: g,
                userSig: empty,
                srcCst: IERC20(address(srcCst)),
                premiumToken: IERC20(address(premiumToken)),
                fillerSrcCst: 0,
                intent: intent,
                premiumCap: 0,
                minDstPerSrc: 0,
                fillerAuthSig: ""
            })
        );
    }

    /// @notice reverts when execute against malformed envelope.
    function testRevert_executeAgainstMalformedEnvelope() public {
        ERC7683Types.GaslessCrossChainOrder memory g;
        bytes memory empty;
        RolloverTypes.RolloverIntent memory intent = _emptyIntent(rolloverContract, bytes32(0));

        vm.expectRevert();
        baseFiller.execute(
            BaseFiller.FillerJob({
                settler: ISettler(address(settler)),
                order: g,
                userSig: empty,
                srcCst: IERC20(address(srcCst)),
                premiumToken: IERC20(address(premiumToken)),
                fillerSrcCst: 0,
                intent: intent,
                premiumCap: 0,
                minDstPerSrc: 0,
                fillerAuthSig: ""
            })
        );
    }

    /// @notice reentrancy lock initialised to zero.
    function test_reentrancyLockInitialisedToZero() public view {
        bytes32 lockSlot = bytes32(uint256(0));
        bytes32 v = vm.load(address(baseFiller), lockSlot);
        assertEq(uint256(v), 0, "reentrancy lock initially zero");
    }

    /// @notice base filler has no admin surface.
    function test_baseFillerHasNoAdminSurface() public view {
        (bool ok,) = address(baseFiller).staticcall(abi.encodeWithSignature("owner()"));
        assertFalse(ok, "owner() must not be callable - no admin surface");
    }

    /// @notice premium allowance consumed and zeroed after execute.
    function test_premiumAllowanceConsumedAndZeroedAfterExecute() public {
        address fillerEoa = makeAddr("fillerEoa_F2_premium");
        uint256 fillerSrc = 1_000e18;
        uint256 premiumAmount = 10e18;
        uint256 dstMinted = 900e18;

        srcCst.mint(fillerEoa, fillerSrc);
        premiumToken.mint(fillerEoa, premiumAmount);

        vm.startPrank(fillerEoa);
        IERC20(address(srcCst)).approve(address(baseFiller), fillerSrc);
        IERC20(address(premiumToken)).approve(address(baseFiller), premiumAmount);
        vm.stopPrank();

        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.allowPartialFills = false;
        orderData.orderSize = fillerSrc;
        orderData.rolloverParams.minCaReceived = 0;
        orderData.rolloverParams.minSharesOut = 0;
        orderData.minPremiumPerShare = 1;

        phoenixPool.setPartialDeposit(dstCst.poolId(), dstMinted, fillerSrc);
        RolloverTypes.Call[] memory rolloverHooks = new RolloverTypes.Call[](1);
        rolloverHooks[0] = _hook(
            address(sourceSrcCptModule),
            abi.encodeWithSignature("execute(address,uint256)", address(srcCpt), fillerSrc)
        );
        RolloverTypes.Call[] memory empty = new RolloverTypes.Call[](0);
        RolloverTypes.Call[] memory postHooks = new RolloverTypes.Call[](1);
        postHooks[0] = _hook(
            address(consumeDstCptModule),
            abi.encodeWithSignature("execute(address)", address(dstCpt))
        );

        RolloverTypes.RolloverIntent memory intent =
            _intentWithHooks(rolloverContract, bytes32(0), rolloverHooks, empty, postHooks);
        orderData.rolloverIntentHash = _zeroDigestHash(intent);

        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory sig = _signOrder(cptHolderPk, orderData);
        bytes32 orderDigestVal = _orderDigest(orderData);
        intent.orderDigest = orderDigestVal;

        vm.prank(fillerEoa);
        baseFiller.execute(
            BaseFiller.FillerJob({
                settler: ISettler(address(settler)),
                order: g,
                userSig: sig,
                srcCst: IERC20(address(srcCst)),
                premiumToken: IERC20(address(premiumToken)),
                fillerSrcCst: fillerSrc,
                intent: intent,
                premiumCap: premiumAmount,
                minDstPerSrc: 0,
                fillerAuthSig: ""
            })
        );

        assertEq(
            premiumToken.allowance(fillerEoa, address(baseFiller)),
            0,
            "F2 premium: fillerEoa -> BaseFiller allowance must be consumed"
        );
        assertEq(
            dstCst.balanceOf(fillerEoa),
            dstMinted,
            "exact BaseFiller.execute settles dstCST to the signed destination"
        );
        assertEq(
            uint8(settler.orderStatus(orderDigestVal)),
            uint8(RolloverTypes.OrderStatus.Settled),
            "exact BaseFiller.execute terminally settles the order"
        );

        assertEq(
            premiumToken.allowance(address(baseFiller), address(settler)),
            0,
            "F2 premium: BaseFiller -> Settler allowance must be zeroed"
        );
        assertEq(
            premiumToken.allowance(address(baseFiller), address(partialSettler)),
            0,
            "F2 premium: BaseFiller -> PartialSettler allowance must stay zero"
        );
    }

    /// @notice helper-routed atomic fill accepts delegated exclusive-filler auth.
    function test_executeWithDelegatedExclusiveFillerAuthSucceeds() public {
        address delegatedExecutor = makeAddr("baseFillerDelegatedExecutor");
        (address exclusiveFiller, uint256 exclusivePk) = makeAddrAndKey("baseFillerExclusive");

        bytes32 orderDigest =
            _executeBaseFillerDelegatedExclusive(delegatedExecutor, exclusiveFiller, exclusivePk);

        assertEq(dstCst.balanceOf(delegatedExecutor), 900e18);
        assertEq(uint8(settler.orderStatus(orderDigest)), uint8(RolloverTypes.OrderStatus.Settled));
    }

    function _executeBaseFillerDelegatedExclusive(
        address delegatedExecutor,
        address exclusiveFiller,
        uint256 exclusivePk
    ) private returns (bytes32 orderDigest) {
        uint256 fillerSrc = 1_000e18;
        uint256 premiumAmount = 10e18;
        _fundDelegatedBaseFillerCaller(delegatedExecutor, fillerSrc, premiumAmount);

        RolloverTypes.OrderData memory orderData =
            _baseFillerDelegatedOrderData(exclusiveFiller, fillerSrc);
        RolloverTypes.RolloverIntent memory intent = _baseFillerDelegatedIntent(fillerSrc);
        orderData.rolloverIntentHash = _zeroDigestHash(intent);
        orderDigest = _orderDigest(orderData);
        intent.orderDigest = orderDigest;

        bytes32 subFiller = bytes32(uint256(uint160(delegatedExecutor)));
        bytes memory fillerAuthSig = _signFillerAuthFor(
            address(settler), exclusivePk, orderDigest, delegatedExecutor, subFiller
        );

        vm.prank(delegatedExecutor);
        baseFiller.execute(
            BaseFiller.FillerJob({
                settler: ISettler(address(settler)),
                order: _gasless(orderData),
                userSig: _signOrder(cptHolderPk, orderData),
                srcCst: IERC20(address(srcCst)),
                premiumToken: IERC20(address(premiumToken)),
                fillerSrcCst: fillerSrc,
                intent: intent,
                premiumCap: premiumAmount,
                minDstPerSrc: 0,
                fillerAuthSig: fillerAuthSig
            })
        );
    }

    function _fundDelegatedBaseFillerCaller(
        address delegatedExecutor,
        uint256 fillerSrc,
        uint256 premiumAmount
    ) private {
        srcCst.mint(delegatedExecutor, fillerSrc);
        premiumToken.mint(delegatedExecutor, premiumAmount);
        vm.startPrank(delegatedExecutor);
        IERC20(address(srcCst)).approve(address(baseFiller), fillerSrc);
        IERC20(address(premiumToken)).approve(address(baseFiller), premiumAmount);
        vm.stopPrank();
    }

    function _baseFillerDelegatedOrderData(address exclusiveFiller, uint256 fillerSrc)
        private
        returns (RolloverTypes.OrderData memory orderData)
    {
        uint256 dstMinted = 900e18;
        orderData = _baseOrder();
        orderData.exclusiveFiller = exclusiveFiller;
        orderData.allowPartialFills = false;
        orderData.orderSize = fillerSrc;
        orderData.rolloverParams.minCaReceived = 0;
        orderData.rolloverParams.minSharesOut = 0;
        orderData.minPremiumPerShare = 1;

        phoenixPool.setPartialDeposit(dstCst.poolId(), dstMinted, fillerSrc);
    }

    function _baseFillerDelegatedIntent(uint256 fillerSrc)
        private
        view
        returns (RolloverTypes.RolloverIntent memory intent)
    {
        RolloverTypes.Call[] memory rolloverHooks = new RolloverTypes.Call[](1);
        rolloverHooks[0] = _hook(
            address(sourceSrcCptModule),
            abi.encodeWithSignature("execute(address,uint256)", address(srcCpt), fillerSrc)
        );
        RolloverTypes.Call[] memory empty = new RolloverTypes.Call[](0);
        RolloverTypes.Call[] memory postHooks = new RolloverTypes.Call[](1);
        postHooks[0] = _hook(
            address(consumeDstCptModule),
            abi.encodeWithSignature("execute(address)", address(dstCpt))
        );

        intent = _intentWithHooks(rolloverContract, bytes32(0), rolloverHooks, empty, postHooks);
    }

    /// @notice partial-mode execute settles this filler residual and keeps order status non-terminal.
    function test_partialExecuteSettlesFillerResidualSameTransaction() public {
        address fillerEoa = makeAddr("fillerEoa_partial");
        uint256 fillerSrc = 1_000e18;
        uint256 premiumAmount = 10e18;
        uint256 dstMinted = 900e18;

        srcCst.mint(fillerEoa, fillerSrc);
        premiumToken.mint(fillerEoa, premiumAmount);

        vm.startPrank(fillerEoa);
        IERC20(address(srcCst)).approve(address(baseFiller), fillerSrc);
        IERC20(address(premiumToken)).approve(address(baseFiller), premiumAmount);
        vm.stopPrank();

        RolloverTypes.OrderData memory orderData = _usePartialSettler(_baseOrder());
        orderData.orderSize = fillerSrc;
        orderData.rolloverParams.minCaReceived = 0;
        orderData.rolloverParams.minSharesOut = 0;
        orderData.minPremiumPerShare = 1;

        phoenixPool.setPartialDeposit(dstCst.poolId(), dstMinted, fillerSrc);
        RolloverTypes.Call[] memory rolloverHooks = new RolloverTypes.Call[](1);
        rolloverHooks[0] = _hook(
            address(sourceSrcCptModule),
            abi.encodeWithSignature("execute(address,uint256)", address(srcCpt), fillerSrc)
        );
        RolloverTypes.Call[] memory empty = new RolloverTypes.Call[](0);
        RolloverTypes.Call[] memory postHooks = new RolloverTypes.Call[](1);
        postHooks[0] = _hook(
            address(consumeDstCptModule),
            abi.encodeWithSignature("execute(address)", address(dstCpt))
        );

        RolloverTypes.RolloverIntent memory intent =
            _intentWithHooks(rolloverContract, bytes32(0), rolloverHooks, empty, postHooks);
        orderData.rolloverIntentHash = _zeroDigestHash(intent);

        ERC7683Types.GaslessCrossChainOrder memory g = _gasless(orderData);
        bytes memory sig = _signOrder(cptHolderPk, orderData);
        intent.orderDigest = _orderDigest(orderData);

        vm.prank(fillerEoa);
        baseFiller.execute(
            BaseFiller.FillerJob({
                settler: ISettler(address(partialSettler)),
                order: g,
                userSig: sig,
                srcCst: IERC20(address(srcCst)),
                premiumToken: IERC20(address(premiumToken)),
                fillerSrcCst: fillerSrc,
                intent: intent,
                premiumCap: premiumAmount,
                minDstPerSrc: 0,
                fillerAuthSig: ""
            })
        );

        assertEq(
            dstCst.balanceOf(fillerEoa),
            dstMinted,
            "partial BaseFiller.execute settles dstCST to the signed destination"
        );
        assertEq(
            dstCst.balanceOf(address(partialSettler)),
            0,
            "partial BaseFiller.execute drains this filler residual"
        );

        assertEq(srcCst.allowance(address(baseFiller), address(partialSettler)), 0);
        assertEq(premiumToken.allowance(address(baseFiller), address(partialSettler)), 0);
        assertEq(srcCst.allowance(address(baseFiller), address(settler)), 0);
        assertEq(premiumToken.allowance(address(baseFiller), address(settler)), 0);

        bytes32 orderDigest = _orderDigest(orderData);
        // INV-FSM-TERMINAL-WRITE-COMPLETE — BaseFiller.execute consumes the full partial
        // order and drains the only filler residual in the same tx, so the order settles.
        assertEq(
            uint8(partialSettler.orderStatus(orderDigest)),
            uint8(RolloverTypes.OrderStatus.Settled),
            "partial per-filler settle promotes to Settled after full aggregate consumption"
        );
        // BaseFiller routed `fillerEoa` so the slot's subFiller is bytes32(fillerEoa).
        // Delegate to a helper to dodge stack-too-deep.
        _assertFillerSettledForSubFiller(orderDigest, fillerEoa);
        assertEq(partialSettler.rolloverAccountingOf(orderDigest).dstCstEscrowed, 0);
    }

    function _assertFillerSettledForSubFiller(bytes32 orderDigest, address subFillerEoa)
        internal
        view
    {
        assertTrue(
            partialSettler.fillerSlotAccountingOf(
                orderDigest, address(baseFiller), bytes32(uint256(uint160(subFillerEoa)))
            )
            .settled
        );
    }
}
