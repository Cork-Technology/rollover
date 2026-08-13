// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { BaseFiller } from "src/BaseFiller.sol";
import {
    BaseFiller__ExpiryExceedsMaxDuration,
    BaseFiller__JitMarketHashMismatch,
    BaseFiller__JitNotConfigured,
    BaseFiller__JitPoolMismatch,
    BaseFiller__MaxExpiryDurationUnavailable,
    BaseFiller__RateUnavailable,
    BaseFiller__RecipeRejectedConstraint,
    BaseFiller__UnexpectedRateOverride,
    BaseFiller__ZeroMaxExpiryDuration
} from "src/errors/BaseFillerErrors.sol";
import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import { RecipeSource } from "src/interfaces/external/market-registry/IMarketRecipe.sol";
import { IMarketRegistry } from "src/interfaces/external/market-registry/IMarketRegistry.sol";
import { IDefaultCorkController } from "src/interfaces/external/phoenix/IDefaultCorkController.sol";
import { IPoolManager, Market, MarketId } from "src/interfaces/external/phoenix/IPoolManager.sol";
import { ISettler } from "src/interfaces/settlers/ISettler.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";
import { FillScaffold } from "test/base/FillScaffold.sol";
import { MockCorkController } from "test/mocks/MockCorkController.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import {
    MockMarketRecipe,
    MockMarketRegistry,
    MockRateOracle
} from "test/mocks/MockMarketRegistry.sol";
import { MockCpt } from "test/mocks/MockPhoenix.sol";

/// @notice Pool manager double whose `market` view always reverts. Phoenix implementations differ
///         on how they answer for an unknown pool — some return a zeroed struct, some revert — and
///         `BaseFiller` has to read both as "the pool does not exist yet".
/// @dev Deliberately not declared as `IPoolManager`: `market` is the only function `BaseFiller`
///      calls on its pool manager, so the rest of the interface would be dead weight.
contract RevertingMarketProbe {
    /// @notice Raised by the only function this double exposes.
    /// @param poolId Pool the lookup was attempted for.
    error RevertingMarketProbe__Unsupported(bytes32 poolId);

    /// @notice Always reverts, standing in for a Phoenix pool manager that throws on unknown pools.
    /// @param poolId Pool identifier.
    /// @return Never returned.
    function market(MarketId poolId) external pure returns (Market memory) {
        revert RevertingMarketProbe__Unsupported(MarketId.unwrap(poolId));
    }
}

/// @notice BaseFillerJitMarketTest — covers `BaseFiller.executeWithMarket`, the path that creates
///         the destination Phoenix pool just in time before running the ordinary fill.
contract BaseFillerJitMarketTest is FillScaffold {
    /// @notice Emitted when a fill created the destination pool it was rolling into.
    /// @param poolId Pool id created by this fill.
    /// @param rateOracle Oracle the pool adopted.
    /// @param recipe Recipe that verified the carried constraint.
    event JITMarketCreated(bytes32 indexed poolId, address indexed rateOracle, address recipe);

    /// @notice Everything one just-in-time destination market needs: its tokens, its signed pool
    ///         id, and the market instruction that reproduces that id.
    /// @param dst Destination Cork Swap Token (cST) for the market.
    /// @param dstCptToken Destination Cork Principal Token (cPT) for the market.
    /// @param poolId Pool id the assembled market hashes to.
    /// @param params Market instruction carried alongside the job.
    struct Fixture {
        MockERC20 dst;
        MockCpt dstCptToken;
        bytes32 poolId;
        BaseFiller.JITMarketParams params;
    }

    /// @notice One full job plus the order state needed to sign and dispatch it.
    /// @param orderData Decoded order.
    /// @param g ERC-7683 gasless order envelope.
    /// @param userSig cPT-holder signature over the order.
    /// @param intent Rollover intent the fill carries.
    /// @param orderDigest Canonical order digest.
    struct Setup {
        RolloverTypes.OrderData orderData;
        ERC7683Types.GaslessCrossChainOrder g;
        bytes userSig;
        RolloverTypes.RolloverIntent intent;
        bytes32 orderDigest;
    }

    /// @notice Rate the fixed-rate oracle is deployed at in these tests.
    uint256 internal constant FIXED_RATE = 1.05e18;
    /// @notice Swap fee the created pool is configured with, 18 decimals.
    uint256 internal constant SWAP_FEE = 0.003e18;
    /// @notice Unwind swap fee the created pool is configured with, 18 decimals.
    uint256 internal constant UNWIND_FEE = 0.001e18;
    /// @notice Market expiry; must outlast every order's fill deadline.
    uint256 internal constant MARKET_EXPIRY = type(uint64).max;
    /// @notice Premium cap each job carries. Comfortably above the required premium for these
    ///         fixtures, and small enough that a caller can fund several fills in one test.
    uint256 internal constant JIT_PREMIUM_CAP = 100e18;

    /// @notice Mock registry used by just-in-time market creation tests.
    MockMarketRegistry internal registry;
    /// @notice Mock Phoenix controller used by just-in-time market creation tests.
    MockCorkController internal controller;
    /// @notice Fixed-rate recipe fixture.
    MockMarketRecipe internal fixedRecipe;
    /// @notice NAV recipe fixture.
    MockMarketRecipe internal navRecipe;
    /// @notice Price recipe fixture.
    MockMarketRecipe internal priceRecipe;
    /// @notice Fixed-rate oracle fixture.
    MockRateOracle internal fixedOracle;
    /// @notice NAV oracle fixture.
    MockRateOracle internal navOracle;
    /// @notice Price oracle fixture.
    MockRateOracle internal priceOracle;
    /// @notice Reference asset used by market fixtures.
    MockERC20 internal refAsset;

    /// @notice Filler wired for market creation.
    BaseFiller internal jitFiller;
    /// @notice Same wiring, but reading pool existence off a `market` view that reverts.
    BaseFiller internal probeFiller;
    /// @notice Filler holding a controller but no registry, for the half-configured revert.
    BaseFiller internal halfConfiguredFiller;

    /// @notice Caller authorized to trigger just-in-time market creation.
    address internal jitCaller;

    /// @notice Test fixture setup.
    function setUp() public override {
        super.setUp();

        refAsset = new MockERC20("Reference", "REF", 18);
        registry = new MockMarketRegistry();
        controller = new MockCorkController(phoenixPool);

        fixedOracle = new MockRateOracle(FIXED_RATE);
        navOracle = new MockRateOracle(1.01e18);
        priceOracle = new MockRateOracle(0.99e18);

        fixedRecipe = new MockMarketRecipe(RecipeSource.FIXED);
        navRecipe = new MockMarketRecipe(RecipeSource.NAV);
        priceRecipe = new MockMarketRecipe(RecipeSource.PRICE);
        registry.setRecipe(address(fixedRecipe), true);
        registry.setRecipe(address(navRecipe), true);
        registry.setRecipe(address(priceRecipe), true);

        registry.setFixedOracle(FIXED_RATE, address(fixedOracle));
        registry.setPairOracle(
            address(caSrc), address(refAsset), IMarketRegistry.OracleMode.NAV, address(navOracle)
        );
        registry.setPairOracle(
            address(caSrc),
            address(refAsset),
            IMarketRegistry.OracleMode.PRICE,
            address(priceOracle)
        );

        jitFiller = new BaseFiller(
            ISettler(address(settler)),
            ISettler(address(partialSettler)),
            IPoolManager(address(phoenixPool)),
            IDefaultCorkController(address(controller)),
            IMarketRegistry(address(registry))
        );
        probeFiller = new BaseFiller(
            ISettler(address(settler)),
            ISettler(address(partialSettler)),
            IPoolManager(address(new RevertingMarketProbe())),
            IDefaultCorkController(address(controller)),
            IMarketRegistry(address(registry))
        );
        halfConfiguredFiller = new BaseFiller(
            ISettler(address(settler)),
            ISettler(address(partialSettler)),
            IPoolManager(address(phoenixPool)),
            IDefaultCorkController(address(controller)),
            IMarketRegistry(address(0))
        );

        controller.setPoolCreatorRole(address(jitFiller), true);
        controller.setPoolCreatorRole(address(probeFiller), true);

        jitCaller = makeAddr("jitCaller");
        srcCst.mint(jitCaller, 1_000_000e18);
        premiumToken.mint(jitCaller, 1_000_000e18);
        vm.startPrank(jitCaller);
        srcCst.approve(address(jitFiller), type(uint256).max);
        premiumToken.approve(address(jitFiller), type(uint256).max);
        srcCst.approve(address(probeFiller), type(uint256).max);
        premiumToken.approve(address(probeFiller), type(uint256).max);
        srcCst.approve(address(baseFiller), type(uint256).max);
        premiumToken.approve(address(baseFiller), type(uint256).max);
        srcCst.approve(address(halfConfiguredFiller), type(uint256).max);
        premiumToken.approve(address(halfConfiguredFiller), type(uint256).max);
        vm.stopPrank();
    }

    ///======================================================///
    ///===================== HELPERS ========================///
    ///======================================================///

    function _constraint() internal pure returns (IMarketRegistry.ResolvedConstraint memory) {
        return IMarketRegistry.ResolvedConstraint({
            rateMin: 0.9e18,
            rateMax: 1.2e18,
            rateChangePerDayMax: 0.01e18,
            rateChangeCapacityMax: 0.05e18
        });
    }

    function _marketFor(BaseFiller.JITMarketParams memory params, address oracle)
        internal
        pure
        returns (Market memory)
    {
        return Market({
            collateralAsset: params.collateralAsset,
            referenceAsset: params.referenceAsset,
            expiryTimestamp: params.expiryTimestamp,
            rateMin: params.constraint.rateMin,
            rateMax: params.constraint.rateMax,
            rateChangePerDayMax: params.constraint.rateChangePerDayMax,
            rateChangeCapacityMax: params.constraint.rateChangeCapacityMax,
            rateOracle: oracle
        });
    }

    /// @dev Builds the destination tokens, derives the pool id the assembled market hashes to, and
    ///      pre-registers the binding the controller installs when the pool is created. The pool
    ///      itself is deliberately left unbound so creation is what brings it into existence.
    function _fixture(MockMarketRecipe recipe, address oracle, uint256 rateOverride)
        internal
        returns (Fixture memory f)
    {
        f.dst = new MockERC20("jitDST", "JDST", 18);
        f.dstCptToken = new MockCpt("jitDCPT", "JDCPT");

        f.params = BaseFiller.JITMarketParams({
            collateralAsset: address(caSrc),
            referenceAsset: address(refAsset),
            expiryTimestamp: MARKET_EXPIRY,
            recipe: address(recipe),
            rateOverride: rateOverride,
            constraint: _constraint(),
            additionalData: "",
            swapFeePercentage: SWAP_FEE,
            unwindSwapFeePercentage: UNWIND_FEE
        });

        f.poolId = keccak256(abi.encode(_marketFor(f.params, oracle)));
        f.dst.setPoolId(MarketId.wrap(f.poolId));
        f.dst.setPoolManager(phoenixPool);
        controller.registerBinding(f.poolId, f.dst, f.dstCptToken, caSrc);
    }

    /// @dev Marks the fixture's pool as already existing, so creation should be skipped.
    function _bindExisting(Fixture memory f) internal {
        phoenixPool.bind(MarketId.wrap(f.poolId), f.dst, f.dstCptToken, caSrc);
    }

    /// @dev Replaces a fixture's expiry and re-derives every pool-id binding that depends on it.
    /// @param f Fixture to update.
    /// @param oracle Oracle included in the market identity.
    /// @param expiryTimestamp New market expiry.
    function _setExpiry(Fixture memory f, address oracle, uint256 expiryTimestamp) internal {
        f.params.expiryTimestamp = expiryTimestamp;
        f.poolId = keccak256(abi.encode(_marketFor(f.params, oracle)));
        f.dst.setPoolId(MarketId.wrap(f.poolId));
        controller.registerBinding(f.poolId, f.dst, f.dstCptToken, caSrc);
    }

    /// @dev Proves a rejected missing pool leaves neither registry deployment bookkeeping nor
    ///      Phoenix controller/pool state behind.
    /// @param f Rejected fixture whose pool must remain missing.
    function _assertNoCreationMutation(Fixture memory f) internal view {
        assertEq(registry.deployCallCount(), 0, "pair-oracle deployment rolled back");
        assertEq(registry.deployFixedCallCount(), 0, "fixed-oracle deployment rolled back");
        assertEq(controller.createCallCount(), 0, "controller creation not persisted");
        assertEq(
            phoenixPool.market(MarketId.wrap(f.poolId)).collateralAsset,
            address(0),
            "pool remains missing"
        );
    }

    function _jitIntent(Fixture memory f, uint256 srcAmount)
        internal
        view
        returns (RolloverTypes.RolloverIntent memory)
    {
        RolloverTypes.Call[] memory preHooks = new RolloverTypes.Call[](1);
        preHooks[0] = _hook(
            address(sourceSrcCptModule),
            abi.encodeWithSignature("execute(address,uint256)", address(srcCpt), srcAmount)
        );
        RolloverTypes.Call[] memory postHooks = new RolloverTypes.Call[](1);
        postHooks[0] = _hook(
            address(consumeDstCptModule),
            abi.encodeWithSignature("execute(address)", address(f.dstCptToken))
        );
        return _intentWithHooks(
            rolloverContract, bytes32(0), preHooks, new RolloverTypes.Call[](0), postHooks
        );
    }

    function _prepare(Fixture memory f, uint256 fillAmount, uint64 salt)
        internal
        view
        returns (Setup memory s)
    {
        s.orderData = _baseOrder();
        s.orderData.dstCstToken = address(f.dst);
        s.orderData.rolloverParams.dstCstToken = address(f.dst);
        s.orderData.rolloverParams.dstPoolId = f.poolId;
        s.orderData.rolloverParams.jitMarketHash = jitFiller.hashJITMarketParams(f.params);
        s.orderData.orderSize = fillAmount;
        s.orderData.orderSalt = salt;

        s.intent = _jitIntent(f, fillAmount);
        s.orderData.rolloverIntentHash = _zeroDigestHash(s.intent);

        s.orderDigest = _orderDigest(s.orderData);
        s.intent.orderDigest = s.orderDigest;
        s.g = _gasless(s.orderData);
        s.userSig = _signOrder(cptHolderPk, s.orderData);
    }

    function _job(Setup memory s, uint256 fillAmount)
        internal
        view
        returns (BaseFiller.FillerJob memory)
    {
        return BaseFiller.FillerJob({
            settler: ISettler(s.orderData.settler),
            order: s.g,
            userSig: s.userSig,
            srcCst: IERC20(address(srcCst)),
            premiumToken: IERC20(address(premiumToken)),
            fillerSrcCst: fillAmount,
            intent: s.intent,
            premiumCap: JIT_PREMIUM_CAP,
            minDstPerSrc: 0,
            fillerAuthSig: ""
        });
    }

    /// @dev Dispatches a prepared job. Kept separate from `_prepare` because `_prepare` makes
    ///      external calls of its own, and `vm.expectRevert` binds to the next one it sees.
    function _call(BaseFiller filler, Setup memory s, Fixture memory f, uint256 fillAmount)
        internal
    {
        vm.prank(jitCaller);
        filler.executeWithMarket(_job(s, fillAmount), f.params);
    }

    function _run(BaseFiller filler, Fixture memory f, uint256 fillAmount, uint64 salt) internal {
        Setup memory s = _prepare(f, fillAmount, salt);
        _call(filler, s, f, fillAmount);
    }

    /// @dev Prepares the job first, then arms the expected revert, so the cheatcode binds to the
    ///      `executeWithMarket` call rather than to a helper's incidental call.
    function _expectRevertOnRun(BaseFiller filler, Fixture memory f, bytes memory expectedError)
        internal
    {
        uint256 fill = 1_000e18;
        Setup memory s = _prepare(f, fill, 1);
        vm.expectRevert(expectedError);
        _call(filler, s, f, fill);
    }

    ///======================================================///
    ///================ CONFIGURATION GATES =================///
    ///======================================================///

    /// @notice A filler deployed without the market-creation wiring rejects any job that carries a
    ///         market instruction, rather than silently falling back to the existing-market path.
    function testRevert_executeWithMarket_controllerUnset() public {
        Fixture memory f = _fixture(fixedRecipe, address(fixedOracle), FIXED_RATE);
        Setup memory s = _prepare(f, 1_000e18, 1);

        vm.prank(jitCaller);
        vm.expectRevert(BaseFiller__JitNotConfigured.selector);
        baseFiller.executeWithMarket(_job(s, 1_000e18), f.params);
    }

    /// @notice Half-wired is still unwired: a controller without a registry cannot verify the
    ///         recipe behind a market, so creation is refused.
    function testRevert_executeWithMarket_registryUnset() public {
        Fixture memory f = _fixture(fixedRecipe, address(fixedOracle), FIXED_RATE);
        Setup memory s = _prepare(f, 1_000e18, 1);

        vm.prank(jitCaller);
        vm.expectRevert(BaseFiller__JitNotConfigured.selector);
        halfConfiguredFiller.executeWithMarket(_job(s, 1_000e18), f.params);
    }

    /// @notice The filler must hold `POOL_CREATOR_ROLE` on the controller for creation to work.
    function testRevert_createNewPool_withoutPoolCreatorRole() public {
        controller.setPoolCreatorRole(address(jitFiller), false);
        Fixture memory f = _fixture(fixedRecipe, address(fixedOracle), FIXED_RATE);

        _expectRevertOnRun(
            jitFiller,
            f,
            abi.encodeWithSelector(
                MockCorkController.MockCorkController__MissingPoolCreatorRole.selector,
                address(jitFiller)
            )
        );
    }

    ///======================================================///
    ///=================== RECIPE GATES =====================///
    ///======================================================///

    /// @notice An unregistered recipe is rejected before any oracle is deployed, so an order can
    ///         never name an arbitrary contract as its recipe and have that contract wave its own
    ///         constraint through.
    function testRevert_unregisteredRecipe_rejectedBeforeOracleDeploy() public {
        MockMarketRecipe rogue = new MockMarketRecipe(RecipeSource.FIXED);
        Fixture memory f = _fixture(rogue, address(fixedOracle), FIXED_RATE);

        vm.expectCall(
            address(registry),
            abi.encodeCall(IMarketRegistry.deployFixedRateOracle, (FIXED_RATE)),
            0
        );
        _expectRevertOnRun(
            jitFiller,
            f,
            abi.encodeWithSelector(IMarketRegistry.RecipeNotRegistered.selector, address(rogue))
        );
    }

    /// @notice A non-fixed recipe never reads a rate override, so carrying one is rejected rather
    ///         than quietly ignored.
    function testRevert_nonFixedRecipe_withRateOverride() public {
        Fixture memory f = _fixture(navRecipe, address(navOracle), 0);
        f.params.rateOverride = 1e18;

        _expectRevertOnRun(
            jitFiller,
            f,
            abi.encodeWithSelector(BaseFiller__UnexpectedRateOverride.selector, address(navRecipe))
        );
    }

    /// @notice The recipe has the final say on the constraint the order carries.
    function testRevert_recipeRejectsConstraint() public {
        fixedRecipe.setAccept(false);
        Fixture memory f = _fixture(fixedRecipe, address(fixedOracle), FIXED_RATE);

        _expectRevertOnRun(
            jitFiller,
            f,
            abi.encodeWithSelector(
                BaseFiller__RecipeRejectedConstraint.selector, address(fixedRecipe)
            )
        );
    }

    /// @notice The recipe is handed the oracle that was just deployed, the market's two assets, the
    ///         signed constraint, and the order's additional data. Pinning each of those on the
    ///         recipe and having the fill succeed proves all four arrive intact.
    function test_recipeReceivesAssembledMarketInputs() public {
        Fixture memory f = _fixture(fixedRecipe, address(fixedOracle), FIXED_RATE);
        f.params.additionalData = hex"c0ffee";
        // Additional data is not part of market identity, so the pool id does not move with it.

        fixedRecipe.setRequiredOracle(address(fixedOracle));
        fixedRecipe.setRequiredAssets(address(caSrc), address(refAsset));
        fixedRecipe.setRequiredRateMin(_constraint().rateMin);
        fixedRecipe.setRequiredAdditionalData(hex"c0ffee");

        _run(jitFiller, f, 1_000e18, 1);

        assertEq(controller.createCallCount(), 1, "pool created");
    }

    /// @notice A recipe handed the wrong oracle rejects, which is how the test observes that the
    ///         oracle the filler passes is the one it just deployed.
    function testRevert_recipeRejects_whenOracleIsNotTheDeployedOne() public {
        Fixture memory f = _fixture(fixedRecipe, address(fixedOracle), FIXED_RATE);
        fixedRecipe.setRequiredOracle(address(navOracle));

        _expectRevertOnRun(
            jitFiller,
            f,
            abi.encodeWithSelector(
                BaseFiller__RecipeRejectedConstraint.selector, address(fixedRecipe)
            )
        );
    }

    ///======================================================///
    ///=============== ORACLE MODE SELECTION ================///
    ///======================================================///

    /// @notice A fixed recipe takes the fixed-rate oracle deployed at the order's rate override.
    function test_fixedRecipe_deploysFixedRateOracle() public {
        Fixture memory f = _fixture(fixedRecipe, address(fixedOracle), FIXED_RATE);

        _run(jitFiller, f, 1_000e18, 1);

        assertEq(registry.deployFixedCallCount(), 1, "fixed oracle deployed once");
        assertEq(registry.lastFixedRate(), FIXED_RATE, "deployed at the signed override");
        assertEq(registry.deployCallCount(), 0, "pair oracle untouched");
    }

    /// @notice A net-asset-value recipe takes a pair oracle in net-asset-value mode.
    function test_navRecipe_deploysPairOracleInNavMode() public {
        Fixture memory f = _fixture(navRecipe, address(navOracle), 0);

        _run(jitFiller, f, 1_000e18, 1);

        assertEq(registry.deployCallCount(), 1, "pair oracle deployed once");
        assertEq(
            uint256(registry.lastMode()),
            uint256(IMarketRegistry.OracleMode.NAV),
            "net-asset-value mode"
        );
        assertEq(registry.lastCollateralAsset(), address(caSrc), "collateral asset forwarded");
        assertEq(registry.lastReferenceAsset(), address(refAsset), "reference asset forwarded");
        assertEq(registry.deployFixedCallCount(), 0, "fixed oracle untouched");
    }

    /// @notice A price recipe takes a pair oracle in price mode.
    function test_priceRecipe_deploysPairOracleInPriceMode() public {
        Fixture memory f = _fixture(priceRecipe, address(priceOracle), 0);

        _run(jitFiller, f, 1_000e18, 1);

        assertEq(registry.deployCallCount(), 1, "pair oracle deployed once");
        assertEq(
            uint256(registry.lastMode()), uint256(IMarketRegistry.OracleMode.PRICE), "price mode"
        );
    }

    ///======================================================///
    ///================= POOL IDENTITY ======================///
    ///======================================================///

    /// @notice The assembled market must hash to the pool id the cPT holder signed. Changing the
    ///         collateral asset moves the derived id, so a filler cannot steer the fill into a
    ///         market backed by a different asset.
    function testRevert_poolIdMismatch_collateralAsset() public {
        Fixture memory f = _fixture(fixedRecipe, address(fixedOracle), FIXED_RATE);
        f.params.collateralAsset = address(new MockERC20("Other", "OTH", 18));

        _expectMismatch(f, address(fixedOracle));
    }

    /// @notice Changing the reference asset moves the derived id.
    function testRevert_poolIdMismatch_referenceAsset() public {
        Fixture memory f = _fixture(fixedRecipe, address(fixedOracle), FIXED_RATE);
        f.params.referenceAsset = address(new MockERC20("Other", "OTH", 18));

        _expectMismatch(f, address(fixedOracle));
    }

    /// @notice Changing the expiry moves the derived id; that signed identity check wins even when
    ///         the later expiry-bound getter is unavailable.
    function testRevert_poolIdMismatch_expiry() public {
        Fixture memory f = _fixture(fixedRecipe, address(fixedOracle), FIXED_RATE);
        f.params.expiryTimestamp = MARKET_EXPIRY - 1;
        registry.setMaxExpiryDurationResponse(MockMarketRegistry.MaxExpiryDurationResponse.Revert);

        _expectMismatch(f, address(fixedOracle));
        _assertNoCreationMutation(f);
    }

    /// @notice Changing any of the four rate limits moves the derived id, so the constraint the
    ///         cPT holder signed is the constraint the pool is created with.
    function testRevert_poolIdMismatch_rateLimits() public {
        Fixture memory f = _fixture(fixedRecipe, address(fixedOracle), FIXED_RATE);
        f.params.constraint.rateMax = 2e18;

        _expectMismatch(f, address(fixedOracle));
    }

    /// @notice Changing the rate override moves the fixed-rate oracle, and the oracle is part of
    ///         market identity, so the derived id moves with it.
    function testRevert_poolIdMismatch_rateOverride() public {
        Fixture memory f = _fixture(fixedRecipe, address(fixedOracle), FIXED_RATE);
        MockRateOracle otherOracle = new MockRateOracle(1.5e18);
        registry.setFixedOracle(1.5e18, address(otherOracle));
        f.params.rateOverride = 1.5e18;

        _expectMismatch(f, address(otherOracle));
    }

    /// @dev Runs the mutated fixture and asserts the derived id differs from the signed one.
    /// @param f Fixture whose `params` were mutated after its pool id was fixed.
    /// @param oracle Oracle the mutated instruction now resolves to.
    function _expectMismatch(Fixture memory f, address oracle) internal {
        bytes32 derived = keccak256(abi.encode(_marketFor(f.params, oracle)));
        assertTrue(derived != f.poolId, "mutation must move the derived id");

        _expectRevertOnRun(
            jitFiller,
            f,
            abi.encodeWithSelector(BaseFiller__JitPoolMismatch.selector, f.poolId, derived)
        );
    }

    ///======================================================///
    ///=============== EXPIRY GOVERNANCE ====================///
    ///======================================================///

    /// @notice A FIXED market may expire exactly at the registry's current duration boundary.
    function test_maxExpiryDuration_fixed_acceptsExactBoundary() public {
        _assertExactExpiryBoundaryAccepted(fixedRecipe, address(fixedOracle), FIXED_RATE);
    }

    /// @notice A PRICE market may expire exactly at the registry's current duration boundary.
    function test_maxExpiryDuration_price_acceptsExactBoundary() public {
        _assertExactExpiryBoundaryAccepted(priceRecipe, address(priceOracle), 0);
    }

    /// @notice A NAV market may expire exactly at the registry's current duration boundary.
    function test_maxExpiryDuration_nav_acceptsExactBoundary() public {
        _assertExactExpiryBoundaryAccepted(navRecipe, address(navOracle), 0);
    }

    /// @notice A missing FIXED market one second beyond the current boundary is rejected.
    function testRevert_maxExpiryDuration_fixed_rejectsBoundaryPlusOne() public {
        _assertExpiryBoundaryPlusOneRejected(fixedRecipe, address(fixedOracle), FIXED_RATE);
    }

    /// @notice A missing PRICE market one second beyond the current boundary is rejected.
    function testRevert_maxExpiryDuration_price_rejectsBoundaryPlusOne() public {
        _assertExpiryBoundaryPlusOneRejected(priceRecipe, address(priceOracle), 0);
    }

    /// @notice A missing NAV market one second beyond the current boundary is rejected.
    function testRevert_maxExpiryDuration_nav_rejectsBoundaryPlusOne() public {
        _assertExpiryBoundaryPlusOneRejected(navRecipe, address(navOracle), 0);
    }

    /// @notice A zero registry bound explicitly disables missing-pool creation.
    function testRevert_maxExpiryDuration_zero_rejectsMissingPool() public {
        Fixture memory f = _fixture(fixedRecipe, address(fixedOracle), FIXED_RATE);
        registry.setMaxExpiryDuration(0);

        _expectRevertOnRun(
            jitFiller, f, abi.encodeWithSelector(BaseFiller__ZeroMaxExpiryDuration.selector)
        );
        _assertNoCreationMutation(f);
    }

    /// @notice A reverting bound getter fails closed with the filler's typed registry error.
    function testRevert_maxExpiryDuration_revertingGetter_rejectsMissingPool() public {
        Fixture memory f = _fixture(fixedRecipe, address(fixedOracle), FIXED_RATE);
        registry.setMaxExpiryDurationResponse(MockMarketRegistry.MaxExpiryDurationResponse.Revert);

        _expectRevertOnRun(
            jitFiller, f, abi.encodeWithSelector(BaseFiller__MaxExpiryDurationUnavailable.selector)
        );
        _assertNoCreationMutation(f);
    }

    /// @notice An empty getter response is malformed and fails closed with the typed registry error.
    function testRevert_maxExpiryDuration_malformedGetter_rejectsMissingPool() public {
        Fixture memory f = _fixture(fixedRecipe, address(fixedOracle), FIXED_RATE);
        registry.setMaxExpiryDurationResponse(
            MockMarketRegistry.MaxExpiryDurationResponse.Malformed
        );

        _expectRevertOnRun(
            jitFiller, f, abi.encodeWithSelector(BaseFiller__MaxExpiryDurationUnavailable.selector)
        );
        _assertNoCreationMutation(f);
    }

    /// @notice The expiry gate runs before rate availability for a missing pool.
    function testRevert_maxExpiryDuration_precedesRateCheck() public {
        uint256 currentTimestamp = block.timestamp;
        uint256 maxDuration = 1;
        uint256 expiryTimestamp = currentTimestamp + maxDuration + 1;
        registry.setMaxExpiryDuration(maxDuration);
        fixedOracle.setRate(0);

        Fixture memory f = _fixture(fixedRecipe, address(fixedOracle), FIXED_RATE);
        _setExpiry(f, address(fixedOracle), expiryTimestamp);
        _expectRevertOnRun(
            jitFiller,
            f,
            abi.encodeWithSelector(
                BaseFiller__ExpiryExceedsMaxDuration.selector,
                expiryTimestamp,
                currentTimestamp,
                maxDuration
            )
        );
        _assertNoCreationMutation(f);
    }

    /// @notice Tightening governance after creation cannot strand fills into the existing pool.
    function test_maxExpiryDuration_existingPoolBypassesTightenedBound() public {
        Fixture memory f = _fixture(fixedRecipe, address(fixedOracle), FIXED_RATE);
        _run(jitFiller, f, 1_000e18, 1);
        assertEq(controller.createCallCount(), 1, "first fill created the pool");

        registry.setMaxExpiryDuration(1);
        assertGt(f.params.expiryTimestamp, block.timestamp + 1, "new bound excludes this expiry");

        _run(jitFiller, f, 1_000e18, 2);

        assertEq(controller.createCallCount(), 1, "existing pool was not recreated");
    }

    /// @dev Runs one recipe source at the inclusive duration boundary.
    /// @param recipe Recipe source under test.
    /// @param oracle Oracle the recipe resolves to.
    /// @param rateOverride FIXED rate, or zero for pair-oracle recipes.
    function _assertExactExpiryBoundaryAccepted(
        MockMarketRecipe recipe,
        address oracle,
        uint256 rateOverride
    ) internal {
        uint256 maxDuration = 30 days;
        uint256 expiryTimestamp = block.timestamp + maxDuration;
        registry.setMaxExpiryDuration(maxDuration);

        Fixture memory f = _fixture(recipe, oracle, rateOverride);
        _setExpiry(f, oracle, expiryTimestamp);
        _run(jitFiller, f, 1_000e18, 1);

        assertEq(controller.createCallCount(), 1, "exact-boundary pool created");
    }

    /// @dev Runs one recipe source one second outside the duration boundary and proves all
    ///      deployment and controller mutations roll back.
    /// @param recipe Recipe source under test.
    /// @param oracle Oracle the recipe resolves to.
    /// @param rateOverride FIXED rate, or zero for pair-oracle recipes.
    function _assertExpiryBoundaryPlusOneRejected(
        MockMarketRecipe recipe,
        address oracle,
        uint256 rateOverride
    ) internal {
        uint256 currentTimestamp = block.timestamp;
        uint256 maxDuration = 30 days;
        uint256 expiryTimestamp = currentTimestamp + maxDuration + 1;
        registry.setMaxExpiryDuration(maxDuration);

        Fixture memory f = _fixture(recipe, oracle, rateOverride);
        _setExpiry(f, oracle, expiryTimestamp);
        _expectRevertOnRun(
            jitFiller,
            f,
            abi.encodeWithSelector(
                BaseFiller__ExpiryExceedsMaxDuration.selector,
                expiryTimestamp,
                currentTimestamp,
                maxDuration
            )
        );
        _assertNoCreationMutation(f);
    }

    ///======================================================///
    ///================ RATE AVAILABILITY ===================///
    ///======================================================///

    /// @notice A pool is permanent, so a market is never anchored to an oracle that is reporting
    ///         nothing at the moment of creation.
    function testRevert_rateUnavailable_atCreation() public {
        Fixture memory f = _fixture(fixedRecipe, address(fixedOracle), FIXED_RATE);
        fixedOracle.setRate(0);

        _expectRevertOnRun(
            jitFiller, f, abi.encodeWithSelector(BaseFiller__RateUnavailable.selector)
        );
    }

    /// @notice The rate check guards creation only. An existing pool is already anchored, so a
    ///         silent oracle does not block a fill into it.
    function test_rateCheckSkipped_whenPoolAlreadyExists() public {
        Fixture memory f = _fixture(fixedRecipe, address(fixedOracle), FIXED_RATE);
        _bindExisting(f);
        fixedOracle.setRate(0);

        _run(jitFiller, f, 1_000e18, 1);

        assertEq(controller.createCallCount(), 0, "no creation for an existing pool");
    }

    ///======================================================///
    ///================== CREATION PATH =====================///
    ///======================================================///

    /// @notice Happy path: the destination pool does not exist, the fill creates it, and the
    ///         rollover then settles into it in the same transaction.
    function test_createsPoolThenFills() public {
        Fixture memory f = _fixture(fixedRecipe, address(fixedOracle), FIXED_RATE);
        assertEq(phoenixPool.market(MarketId.wrap(f.poolId)).collateralAsset, address(0), "unbound");

        uint256 fill = 1_000e18;
        Setup memory s = _prepare(f, fill, 1);

        vm.expectEmit(true, true, false, true, address(jitFiller));
        emit JITMarketCreated(f.poolId, address(fixedOracle), address(fixedRecipe));

        vm.prank(jitCaller);
        jitFiller.executeWithMarket(_job(s, fill), f.params);

        assertEq(controller.createCallCount(), 1, "pool created once");
        assertEq(
            phoenixPool.market(MarketId.wrap(f.poolId)).collateralAsset,
            address(caSrc),
            "pool now exists"
        );
        (, address canonicalDstCst) = phoenixPool.shares(MarketId.wrap(f.poolId));
        assertEq(canonicalDstCst, address(f.dst), "created pool owns the signed destination cST");
        assertEq(
            uint256(settler.orderStatus(s.orderDigest)),
            uint256(RolloverTypes.OrderStatus.Settled),
            "order settled in the same call"
        );
        assertGt(f.dst.balanceOf(jitCaller), 0, "filler received destination cST from the new pool");
    }

    /// @notice The created pool carries the cPT-holder/filler-negotiated signed fees, and its
    ///         whitelist is disabled — Phoenix gates `deposit` on the caller, and that caller is
    ///         the cPT holder's rollover contract rather than anything this filler controls.
    function test_createdPool_carriesNegotiatedFeesAndDisabledWhitelist() public {
        Fixture memory f = _fixture(fixedRecipe, address(fixedOracle), FIXED_RATE);
        f.params.swapFeePercentage = 0.007e18;
        f.params.unwindSwapFeePercentage = 0.002e18;

        _run(jitFiller, f, 1_000e18, 1);

        IDefaultCorkController.PoolCreationParams memory p = controller.lastParams();
        assertEq(p.swapFeePercentage, 0.007e18, "negotiated swap fee forwarded");
        assertEq(p.unwindSwapFeePercentage, 0.002e18, "negotiated unwind fee forwarded");
        assertFalse(p.isWhitelistEnabled, "whitelist disabled at creation");

        Market memory expected = _marketFor(f.params, address(fixedOracle));
        assertEq(keccak256(abi.encode(p.pool)), keccak256(abi.encode(expected)), "market as signed");
    }

    /// @notice A caller cannot alter the negotiated swap fee after signing; the commitment check
    ///         wins even while the later expiry-bound getter is unavailable.
    function testRevert_tamperedSwapFee_doesNotCreatePool() public {
        Fixture memory f = _fixture(fixedRecipe, address(fixedOracle), FIXED_RATE);
        uint256 fill = 1_000e18;
        Setup memory s = _prepare(f, fill, 1);
        bytes32 signedHash = s.orderData.rolloverParams.jitMarketHash;

        f.params.swapFeePercentage += 1;
        bytes32 tamperedHash = jitFiller.hashJITMarketParams(f.params);
        registry.setMaxExpiryDurationResponse(MockMarketRegistry.MaxExpiryDurationResponse.Revert);

        vm.expectRevert(
            abi.encodeWithSelector(
                BaseFiller__JitMarketHashMismatch.selector, signedHash, tamperedHash
            )
        );
        vm.prank(jitCaller);
        jitFiller.executeWithMarket(_job(s, fill), f.params);

        _assertNoCreationMutation(f);
    }

    /// @notice A caller cannot alter the negotiated unwind fee after the cPT holder signs the order.
    function testRevert_tamperedUnwindFee_doesNotCreatePool() public {
        Fixture memory f = _fixture(fixedRecipe, address(fixedOracle), FIXED_RATE);
        uint256 fill = 1_000e18;
        Setup memory s = _prepare(f, fill, 1);
        bytes32 signedHash = s.orderData.rolloverParams.jitMarketHash;

        f.params.unwindSwapFeePercentage += 1;
        bytes32 tamperedHash = jitFiller.hashJITMarketParams(f.params);

        vm.expectRevert(
            abi.encodeWithSelector(
                BaseFiller__JitMarketHashMismatch.selector, signedHash, tamperedHash
            )
        );
        vm.prank(jitCaller);
        jitFiller.executeWithMarket(_job(s, fill), f.params);

        assertEq(controller.createCallCount(), 0, "tampered fee cannot create a pool");
    }

    /// @notice The second fill into a market finds the pool already there and skips creation.
    function test_secondFillIntoSamePool_skipsCreation() public {
        Fixture memory f = _fixture(fixedRecipe, address(fixedOracle), FIXED_RATE);

        _run(jitFiller, f, 1_000e18, 1);
        assertEq(controller.createCallCount(), 1, "created on the first fill");

        _run(jitFiller, f, 1_000e18, 2);
        assertEq(controller.createCallCount(), 1, "not created again");
    }

    /// @notice Phoenix implementations differ on how they answer for an unknown pool. A `market`
    ///         view that reverts reads as "does not exist", so creation still goes ahead.
    function test_revertingMarketProbe_readsAsPoolMissing() public {
        Fixture memory f = _fixture(fixedRecipe, address(fixedOracle), FIXED_RATE);

        _run(probeFiller, f, 1_000e18, 1);

        assertEq(controller.createCallCount(), 1, "pool created despite the reverting probe");
    }

    ///======================================================///
    ///================ EXISTING-MARKET PATH ================///
    ///======================================================///

    /// @notice `execute` is unchanged by the market wiring: a fill into an existing market never
    ///         touches the controller.
    function test_plainExecute_onJitFiller_neverCreatesAMarket() public {
        Fixture memory f = _fixture(fixedRecipe, address(fixedOracle), FIXED_RATE);
        _bindExisting(f);

        uint256 fill = 1_000e18;
        Setup memory s = _prepare(f, fill, 1);

        vm.prank(jitCaller);
        jitFiller.execute(_job(s, fill));

        assertEq(controller.createCallCount(), 0, "controller untouched");
        assertEq(
            uint256(settler.orderStatus(s.orderDigest)),
            uint256(RolloverTypes.OrderStatus.Settled),
            "order settled"
        );
    }
}
