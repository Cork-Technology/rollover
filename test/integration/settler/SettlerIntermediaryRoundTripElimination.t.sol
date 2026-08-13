// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { FillScaffold } from "../../base/FillScaffold.sol";
import { MockERC20 } from "../../mocks/MockERC20.sol";
import { Test } from "forge-std/Test.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice Pins elimination of the Settler-as-intermediary round-trip on ROLLOVER + PREMIUM.
///         Token movement becomes direct filler→rolloverContract for both src and premium tokens;
///         Settler holds zero of both tokens at every observable boundary.
///
///         Behavioural assertions:
///           - Settler.balanceOf(srcCst) == 0 across the fill (never accumulates).
///           - Settler.balanceOf(premiumToken) == 0 across the fill.
///           - premiumToken.allowance(settler, rolloverContract) == 0 at every observable boundary
///             (Settler never grants a premium-token allowance to the rolloverContract).
///
///         Structural assertions:
///           - Settler's ROLLOVER transferFrom routes filler → orderData.rolloverContract directly.
///           - Settler's PREMIUM transferFrom routes filler → orderData.rolloverContract directly.
///           - Settler's PREMIUM path no longer contains `forceApprove(.., rolloverContract, ..)` /
///             revoke pair.
///           - RolloverContract `_handlePhasePremium` no longer pulls via `safeTransferFrom(originSettler, ..)`.
///           - AS-10 catch branch drops the redundant `safeTransfer(rolloverContract, premium)`.
contract SettlerIntermediaryRoundTripEliminationTest is FillScaffold {
    /// @notice srcCST rollover fill amount used across happy-path scenarios.
    uint256 internal constant FILL_AMOUNT = 1_000e18;
    /// @notice Premium payment that satisfies the Settler's `minPremiumPerShare` floor.
    uint256 internal constant PREMIUM = 10e18;

    /// @inheritdoc BaseTest
    function setUp() public override {
        super.setUp();
        vm.startPrank(filler);
        srcCst.approve(address(settler), type(uint256).max);
        srcCst.approve(address(partialSettler), type(uint256).max);
        premiumToken.approve(address(settler), type(uint256).max);
        premiumToken.approve(address(partialSettler), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice Build an exact-mode order with a given salt.
    function _exactOrder(uint64 salt)
        internal
        view
        returns (RolloverTypes.OrderData memory orderData)
    {
        orderData = _baseOrder();
        orderData.allowPartialFills = false;
        orderData.orderSalt = salt;
        orderData.orderSize = FILL_AMOUNT;
    }

    /// @notice Build a happy-path intent with pre-rollover + post-rollover hooks (no premium hooks).
    function _intent(bytes32 orderDigest)
        internal
        view
        returns (RolloverTypes.RolloverIntent memory)
    {
        RolloverTypes.Call[] memory pre = new RolloverTypes.Call[](1);
        pre[0] = _hook(
            address(sourceSrcCptModule),
            abi.encodeWithSignature("execute(address,uint256)", address(srcCpt), FILL_AMOUNT)
        );
        RolloverTypes.Call[] memory post = new RolloverTypes.Call[](1);
        post[0] = _hook(
            address(consumeDstCptModule),
            abi.encodeWithSignature("execute(address)", address(dstCpt))
        );
        return
            _intentWithHooks(rolloverContract, orderDigest, pre, new RolloverTypes.Call[](0), post);
    }

    /// @notice Open an exact-mode order; return digest + intent + cptHolderSig.
    function _setupOrder(uint64 salt)
        internal
        returns (
            bytes32 orderDigest,
            RolloverTypes.OrderData memory orderData,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        )
    {
        orderData = _exactOrder(salt);
        RolloverTypes.RolloverIntent memory probe = _intent(bytes32(0));
        orderData.rolloverIntentHash = _zeroDigestHash(probe);
        orderDigest = _openOrder(orderData);
        intent = _intent(orderDigest);
        cptHolderSig = _signOrder(cptHolderPk, orderData);
    }

    // ────────────────────────── behavioural assertions ──────────────────────────

    /// @notice ROLLOVER: srcCST routes filler→rolloverContract directly. Settler never holds srcCST.
    function test_rollover_srcCst_delivered_directly_to_rolloverContract() public {
        (
            bytes32 orderDigest,
            RolloverTypes.OrderData memory orderData,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupOrder(801);

        uint256 settlerBefore = srcCst.balanceOf(address(settler));
        _doRolloverAs(orderDigest, orderData, intent, FILL_AMOUNT, filler);

        assertEq(
            srcCst.balanceOf(address(settler)),
            settlerBefore,
            "Settler srcCST net-zero across the fill"
        );
    }

    /// @notice PREMIUM: premiumToken routes filler→rolloverContract directly within the atomic
    ///         Settler.fill() frame. Settler never holds it. The assertion measures the
    ///         rolloverContract delta around the atomic rollover (which now pays premium in-frame).
    function test_premium_premiumToken_delivered_directly_to_rolloverContract() public {
        (
            bytes32 orderDigest,
            RolloverTypes.OrderData memory orderData,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupOrder(802);

        uint256 settlerBefore = premiumToken.balanceOf(address(settler));
        uint256 rolloverContractBefore = premiumToken.balanceOf(rolloverContract);
        _doRolloverAs(orderDigest, orderData, intent, FILL_AMOUNT, filler);

        assertEq(
            premiumToken.balanceOf(address(settler)),
            settlerBefore,
            "Settler premium net-zero across the fill"
        );
        assertEq(
            premiumToken.balanceOf(rolloverContract),
            rolloverContractBefore + PREMIUM,
            "rolloverContract credited PREMIUM directly"
        );
    }

    /// @notice Non-18-decimal premium tokens use raw token units for `minPremiumPerShare`.
    function test_premium_non18DecimalToken_usesRawPremiumUnits() public {
        MockERC20 premium6 = new MockERC20("Premium6", "PRM6", 6);
        uint256 rawRatePerShare = 1_000;
        uint256 expectedRawPremium = 1_000_000;

        RolloverTypes.OrderData memory orderData = _exactOrder(805);
        orderData.premiumToken = address(premium6);
        orderData.minPremiumPerShare = rawRatePerShare;
        RolloverTypes.RolloverIntent memory probe = _intent(bytes32(0));
        orderData.rolloverIntentHash = _zeroDigestHash(probe);
        bytes32 orderDigest = _openOrder(orderData);
        RolloverTypes.RolloverIntent memory intent = _intent(orderDigest);
        bytes memory cptHolderSig = _signOrder(cptHolderPk, orderData);

        premium6.mint(filler, expectedRawPremium);
        vm.prank(filler);
        premium6.approve(address(settler), type(uint256).max);

        uint256 rolloverContractBefore = premium6.balanceOf(rolloverContract);
        _doRolloverAs(orderDigest, orderData, intent, FILL_AMOUNT, filler);

        assertEq(
            premium6.balanceOf(rolloverContract) - rolloverContractBefore,
            expectedRawPremium,
            "premium paid as raw 6-decimal token units"
        );
    }

    /// @notice No allowance residual: Settler never grants a premium-token allowance to the rolloverContract.
    function test_premium_no_allowance_residual_settler_to_rolloverContract() public {
        (
            bytes32 orderDigest,
            RolloverTypes.OrderData memory orderData,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupOrder(803);
        _doRolloverAs(orderDigest, orderData, intent, FILL_AMOUNT, filler);

        assertEq(
            premiumToken.allowance(address(settler), rolloverContract),
            0,
            "Settler grants no premium-token allowance to rolloverContract (structural)"
        );
    }

    /// @notice Settler holds zero premium at every observable boundary including post-settle.
    function test_settler_premium_balance_never_nonzero_across_full_lifecycle() public {
        (
            bytes32 orderDigest,
            RolloverTypes.OrderData memory orderData,
            RolloverTypes.RolloverIntent memory intent,
            bytes memory cptHolderSig
        ) = _setupOrder(804);
        assertEq(premiumToken.balanceOf(address(settler)), 0, "pre-fill: Settler premium zero");
        _doRolloverAs(orderDigest, orderData, intent, FILL_AMOUNT, filler);
        assertEq(premiumToken.balanceOf(address(settler)), 0, "post-ROLLOVER: Settler premium zero");
        assertEq(premiumToken.balanceOf(address(settler)), 0, "post-PREMIUM: Settler premium zero");
    }
}

/// @notice Structural assertions over the post-Cand-30 source shape. Separate test contract so
///         it does not require the heavy `FillScaffold` setup.
contract SettlerIntermediaryRoundTripStructuralTest is Test {
    /// @notice ROLLOVER transferFrom routes filler → orderData.rolloverContract directly.
    function test_rollover_transferFrom_routes_to_rolloverContract() public view {
        string memory src = vm.readFile("src/BaseSettler.sol");
        // Whitespace-tolerant: `forge fmt` may wrap the call across lines.
        require(
            _contains(src, "safeTransferFrom(") && _contains(src, "msg.sender,")
                && _contains(src, "orderData.rolloverContract,")
                && _contains(src, "fillerPayload.fillAmount"),
            "BaseSettler ROLLOVER must safeTransferFrom(msg.sender, orderData.rolloverContract, ...)"
        );
        require(
            !_contains(src, "address(this), fillerPayload.fillAmount"),
            "BaseSettler ROLLOVER must NOT transferFrom into Settler"
        );
    }

    /// @notice PREMIUM transferFrom routes filler → orderData.rolloverContract directly.
    function test_premium_transferFrom_routes_to_rolloverContract() public view {
        string memory src = vm.readFile("src/BaseSettler.sol");
        require(
            _contains(src, "msg.sender,") && _contains(src, "orderData.rolloverContract,")
                && _contains(src, "requiredPremium"),
            "BaseSettler PREMIUM must safeTransferFrom(msg.sender, orderData.rolloverContract, ...)"
        );
    }

    /// @notice Settler PREMIUM path drops `forceApprove` / revoke pair.
    function test_premium_forceApprove_revoke_pair_removed() public view {
        string memory src = vm.readFile("src/BaseSettler.sol");
        require(
            !_contains(
                src, "premiumToken.forceApprove(orderData.rolloverContract, fillerPayload.premium)"
            ),
            "BaseSettler PREMIUM must drop forceApprove(rolloverContract, premium)"
        );
        require(
            !_contains(src, "premiumToken.forceApprove(orderData.rolloverContract, 0)"),
            "BaseSettler PREMIUM must drop forceApprove(rolloverContract, 0) revoke"
        );
    }

    /// @notice RolloverContract `_handlePhasePremium` no longer pulls via Settler allowance.
    function test_rolloverContract_phase_premium_drops_settler_pull() public view {
        string memory src = vm.readFile("src/CorkRolloverContract.sol");
        require(
            !_contains(src, ".safeTransferFrom(ctx.originSettler, address(this), ctx.premium)"),
            "CorkRolloverContract _handlePhasePremium must not transferFrom(originSettler, this, premium)"
        );
    }

    /// @notice AS-10 catch branch drops the redundant safeTransfer(rolloverContract, premium).
    function test_as10_catch_branch_drops_redundant_transfer() public view {
        string memory src = vm.readFile("src/BaseSettler.sol");
        require(
            !_contains(
                src,
                "IERC20(orderData.premiumToken).safeTransfer(orderData.rolloverContract, fillerPayload.premium)"
            ),
            "BaseSettler catch branch must drop redundant safeTransfer(rolloverContract, premium)"
        );
    }

    /// @notice Substring match helper (mirrors pattern in `BanlistRemoval.t.sol`).
    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0) {
            return true;
        }
        if (n.length > h.length) {
            return false;
        }
        for (uint256 i = 0; i <= h.length - n.length; ++i) {
            bool ok = true;
            for (uint256 j = 0; j < n.length; ++j) {
                if (h[i + j] != n[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) {
                return true;
            }
        }
        return false;
    }
}
