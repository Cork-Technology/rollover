// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BaseTest } from "../../base/BaseTest.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { BaseFiller } from "src/BaseFiller.sol";
import { ERC7683Types } from "src/interfaces/external/erc7683/ERC7683Types.sol";
import { IMarketRegistry } from "src/interfaces/external/market-registry/IMarketRegistry.sol";
import { IDefaultCorkController } from "src/interfaces/external/phoenix/IDefaultCorkController.sol";
import { IPoolManager } from "src/interfaces/external/phoenix/IPoolManager.sol";
import { ISettler } from "src/interfaces/settlers/ISettler.sol";
import { LibRolloverOrder } from "src/libraries/LibRolloverOrder.sol";
import { RolloverTypes } from "src/types/RolloverTypes.sol";

/// @notice MockPartialPullSettler — pins BaseFillerCoverage behaviour for the Cork Rollover suite.
contract MockPartialPullSettler {
    /// @notice Premium token.
    /// @return premiumToken Stored premium token value.
    address public premiumToken;
    /// @notice Sink.
    /// @return sink Stored sink value.

    address public sink;
    /// @notice Produced.
    /// @return produced Stored produced value.

    uint256 public produced;
    /// @notice Mpps.
    /// @return mpps Stored mpps value.

    uint256 public mpps;

    /// @notice Configure.
    /// @param token_ Token contract.
    /// @param sink_ Sink address.
    /// @param produced_ Produced amount.
    /// @param mpps_ Minimum dst-per-src ratio table.

    // forge-lint: disable-next-line(missing-zero-check)
    function configure(address token_, address sink_, uint256 produced_, uint256 mpps_) external {
        premiumToken = token_;
        sink = sink_;
        produced = produced_;
        mpps = mpps_;
    }

    /// @notice Domain separator.
    /// @return Return value.

    // forge-lint: disable-next-line(mixed-case-function)
    function DOMAIN_SEPARATOR() external pure returns (bytes32) {
        return bytes32(uint256(0xD0));
    }

    /// @notice Report order status (defaults to `None` when unset).
    /// @param orderId_ Ignored order id.
    /// @return Configured status, packed as `uint8`.
    function orderStatus(bytes32 orderId_) external pure returns (uint8) {
        orderId_;
        return 0;
    }

    /// @notice Filler dst produced of.
    /// @param orderDigest_ Ignored order digest.
    /// @param filler_ Ignored filler address.
    /// @return Return value.

    function fillerDstProducedOf(bytes32 orderDigest_, address filler_)
        external
        view
        returns (uint256)
    {
        orderDigest_;
        filler_;
        return produced;
    }

    /// @notice 3-arg overload — subFiller dimension (ignored).
    /// @param orderDigest_ Ignored order digest.
    /// @param filler_ Ignored filler address.
    /// @param subFiller_ Ignored sub-filler id.
    /// @return Configured dstProduced value.
    function fillerDstProducedOf(bytes32 orderDigest_, address filler_, bytes32 subFiller_)
        external
        view
        returns (uint256)
    {
        orderDigest_;
        filler_;
        subFiller_;
        return produced;
    }
    /// @notice Open for.
    /// @param order_ Ignored order envelope.
    /// @param signature_ Ignored signature bytes.
    /// @param originData_ Ignored origin data.

    function openFor(
        ERC7683Types.GaslessCrossChainOrder calldata order_,
        bytes calldata signature_,
        bytes calldata originData_
    ) external pure {
        order_;
        signature_;
        originData_;
    }

    /// @notice Resolve for.
    /// @param order_ Ignored order envelope.
    /// @param originData_ Ignored origin data.
    /// @return r Computed result.
    function resolveFor(
        ERC7683Types.GaslessCrossChainOrder calldata order_,
        bytes calldata originData_
    ) external pure returns (ERC7683Types.ResolvedCrossChainOrder memory r) {
        order_;
        originData_;
        r.orderId = bytes32(uint256(0xCAFEC0DE));
    }

    /// @notice Fill.
    /// @param orderId_ Ignored order id.
    /// @param originData_ Ignored origin data.
    /// @param fillerData ERC-7683 filler-side data (encoded fill payload).

    /// @notice Under atomic-fill the BaseFiller sends an ATOMIC_TAG=255 envelope. The mock
    ///         decodes the envelope and pulls `required = produced * mpps / 1e18` (ceil)
    ///         premium from msg.sender (the BaseFiller, which has already pulled
    ///         `premiumCap` from the caller). The residual stays in BaseFiller for refund.
    function fill(bytes32 orderId_, bytes calldata originData_, bytes calldata fillerData)
        external
    {
        orderId_;
        originData_;
        // Atomic envelope: (uint8 tag, bytes rolloverLeg, uint256 cap, bytes cptHolderSig)
        (uint8 tag,,,) = abi.decode(fillerData, (uint8, bytes, uint256, bytes));
        if (tag != 255) {
            return;
        }
        // Compute required premium and pull from msg.sender (the BaseFiller).
        uint256 required = (produced * mpps + 1e18 - 1) / 1e18;
        if (required > 0) {
            require(
                IERC20(premiumToken).transferFrom(msg.sender, sink, required),
                "MockPartialPullSettler: transferFrom failed"
            );
        }
    }
}

/// @notice BaseFillerCoverageTest — pins BaseFillerCoverage behaviour for the Cork Rollover suite.
contract BaseFillerCoverageTest is BaseTest {
    /// @notice Emitted on transfer.
    /// @param from Source address.
    /// @param to Destination address.
    /// @param value Numeric value.
    event Transfer(address indexed from, address indexed to, uint256 value);
    /// @notice Emitted on premium refunded.
    /// @param orderDigest EIP-712 order digest.
    /// @param filler Filler address.
    /// @param premiumToken Premium token address.
    /// @param amount Token amount (raw units).
    event PremiumRefunded(
        bytes32 indexed orderDigest,
        address indexed filler,
        address indexed premiumToken,
        uint256 amount
    );
    /// @notice Caller eoa.

    address internal callerEoa;
    /// @notice Mock settler.

    MockPartialPullSettler internal mockSettler;
    /// @notice Test fixture setup.

    function setUp() public override {
        super.setUp();
        callerEoa = makeAddr("baseFillerCaller");
        mockSettler = new MockPartialPullSettler();
        baseFiller = new BaseFiller(
            ISettler(address(mockSettler)),
            ISettler(address(mockSettler)),
            IPoolManager(address(0)),
            IDefaultCorkController(address(0)),
            IMarketRegistry(address(0))
        );
        vm.label(address(mockSettler), "mockPartialPullSettler");
        vm.label(callerEoa, "callerEoa");
    }

    /// @notice Pins behaviour: execute Refunds Leftover Premium Tail To Caller.
    function test_executeRefundsLeftoverPremiumTailToCaller() public {
        uint256 producedV = 1000e18;
        uint256 mppsV = 1e16;
        uint256 required = (producedV * mppsV) / 1e18;
        uint256 premiumCap = required * 5;
        uint256 expectedResidual = premiumCap - required;

        mockSettler.configure(address(premiumToken), address(0xDEAD), producedV, mppsV);

        premiumToken.mint(callerEoa, premiumCap);
        vm.prank(callerEoa);
        premiumToken.approve(address(baseFiller), premiumCap);

        RolloverTypes.OrderData memory orderData = _baseOrder();
        orderData.minPremiumPerShare = mppsV;
        ERC7683Types.GaslessCrossChainOrder memory g;
        g.orderDataType = LibRolloverOrder.CORK_ORDER_DATA_TYPE;
        g.orderData = abi.encode(orderData);
        bytes memory userSig;
        RolloverTypes.RolloverIntent memory intent;

        uint256 callerPre = premiumToken.balanceOf(callerEoa);
        uint256 fillerPre = premiumToken.balanceOf(address(baseFiller));

        vm.expectEmit(true, true, false, true, address(premiumToken));
        emit Transfer(address(baseFiller), callerEoa, expectedResidual);

        vm.prank(callerEoa);
        baseFiller.execute(
            BaseFiller.FillerJob({
                settler: ISettler(address(mockSettler)),
                order: g,
                userSig: userSig,
                srcCst: IERC20(address(srcCst)),
                premiumToken: IERC20(address(premiumToken)),
                fillerSrcCst: 0,
                intent: intent,
                premiumCap: premiumCap,
                minDstPerSrc: 0,
                fillerAuthSig: ""
            })
        );

        uint256 callerPost = premiumToken.balanceOf(callerEoa);
        uint256 fillerPost = premiumToken.balanceOf(address(baseFiller));

        assertEq(callerPre - callerPost, required, "caller premium delta equals required");

        assertEq(fillerPost, fillerPre, "BaseFiller premium balance restored");

        assertEq(
            premiumToken.balanceOf(address(0xDEAD)), required, "mock sink received required premium"
        );
    }
}
