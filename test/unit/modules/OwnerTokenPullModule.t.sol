// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Test } from "forge-std/Test.sol";
import { OnlyDelegatecall__DirectCallForbidden } from "src/modules/OnlyDelegatecall.sol";
import {
    OwnerTokenPullModule,
    OwnerTokenPullModule__NothingPullable,
    OwnerTokenPullModule__ZeroAmount,
    OwnerTokenPullModule__ZeroToken
} from "src/modules/OwnerTokenPullModule.sol";

/// @notice Delegatecall host with the `ICorkRolloverContract.owner()` surface required by
///         `OwnerTokenPullModule`.
contract OwnerTokenPullHost {
    /// @notice Owner returned to the module during delegatecall.
    address public owner;

    /// @notice Deploy with a fixed owner.
    /// @param owner_ Owner address mirrored through `owner()`.
    constructor(address owner_) {
        owner = owner_;
    }

    /// @notice Delegatecall `module` with `data` and bubble the underlying revert.
    /// @param module Module address.
    /// @param data Encoded call data.
    /// @return ret Raw delegatecall returndata.
    function exec(address module, bytes calldata data) external returns (bytes memory ret) {
        bool ok;
        (ok, ret) = module.delegatecall(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }
}

/// @title OwnerTokenPullModuleTest
/// @notice Unit coverage for owner-sourced ERC-20 pulls through a delegatecall host.
contract OwnerTokenPullModuleTest is Test {
    /// @notice Mirror of the production event for `vm.expectEmit`.
    /// @param executor Delegatecall host that receives the pulled tokens.
    /// @param token ERC-20 token pulled from the owner.
    /// @param owner Owner account used as the transfer source.
    /// @param amount Token amount pulled.
    event OwnerTokenPulled(
        address indexed executor, address indexed token, address indexed owner, uint256 amount
    );

    /// @notice Module under test.
    OwnerTokenPullModule internal module;
    /// @notice Delegatecall host that receives pulled tokens.
    OwnerTokenPullHost internal host;
    /// @notice ERC-20 mock pulled from the owner.
    ERC20Mock internal token;
    /// @notice Fixed source account returned by the host.
    address internal owner = makeAddr("owner");
    /// @notice Third-party executor used to prove caller independence.
    address internal caller = makeAddr("caller");
    /// @notice Non-owner account used to prove source cannot be caller-selected.
    address internal nonOwner = makeAddr("nonOwner");

    /// @notice Deploy the module, host, and ERC-20 fixture.
    function setUp() public {
        module = new OwnerTokenPullModule();
        host = new OwnerTokenPullHost(owner);
        token = new ERC20Mock();
        token.mint(owner, 1_000e18);
    }

    /// @notice Direct calls to the implementation are rejected by the delegatecall guard.
    function test_directExecute_revertsOnlyDelegatecall() public {
        vm.expectRevert(OnlyDelegatecall__DirectCallForbidden.selector);
        module.execute(IERC20(address(token)), 1e18, false);
    }

    /// @notice Exact mode pulls exactly the signed amount from the host owner into the host.
    function test_exactMode_pullsExactSignedAmountFromHostOwnerToHost() public {
        vm.prank(owner);
        token.approve(address(host), 100e18);

        host.exec(
            address(module),
            abi.encodeCall(OwnerTokenPullModule.execute, (IERC20(address(token)), 100e18, false))
        );

        assertEq(token.balanceOf(owner), 900e18, "owner debited exact amount");
        assertEq(token.balanceOf(address(host)), 100e18, "host credited exact amount");
        assertEq(token.balanceOf(address(module)), 0, "module contract balance stays zero");
    }

    /// @notice Underfill mode treats the signed amount as a maximum and pulls the owner balance.
    function test_underfillMode_pullsLessThanSignedAmountWhenOwnerBalanceIsLower() public {
        uint256 signedAmount = 100e18;
        uint256 ownerBalance = 70e18;
        ERC20Mock limitedToken = new ERC20Mock();
        limitedToken.mint(owner, ownerBalance);
        vm.prank(owner);
        limitedToken.approve(address(host), signedAmount);

        host.exec(
            address(module),
            abi.encodeCall(
                OwnerTokenPullModule.execute, (IERC20(address(limitedToken)), signedAmount, true)
            )
        );

        assertEq(limitedToken.balanceOf(owner), 0, "owner balance pulled");
        assertEq(limitedToken.balanceOf(address(host)), ownerBalance, "host credited pullable");
        assertEq(limitedToken.balanceOf(address(module)), 0, "module untouched");
    }

    /// @notice Underfill mode treats the signed amount as a maximum and pulls the allowance.
    function test_underfillMode_pullsLessThanSignedAmountWhenAllowanceIsLower() public {
        uint256 signedAmount = 100e18;
        uint256 allowance = 70e18;
        vm.prank(owner);
        token.approve(address(host), allowance);

        host.exec(
            address(module),
            abi.encodeCall(
                OwnerTokenPullModule.execute, (IERC20(address(token)), signedAmount, true)
            )
        );

        assertEq(token.balanceOf(owner), 930e18, "owner debited allowance");
        assertEq(token.balanceOf(address(host)), allowance, "host credited allowance");
        assertEq(token.allowance(owner, address(host)), 0, "allowance consumed");
    }

    /// @notice Underfill mode still requires a positive pullable amount.
    function test_underfillMode_revertsWhenNothingPositiveIsPullable() public {
        vm.expectRevert(OwnerTokenPullModule__NothingPullable.selector);
        host.exec(
            address(module),
            abi.encodeCall(OwnerTokenPullModule.execute, (IERC20(address(token)), 100e18, true))
        );
    }

    /// @notice Exact mode stays strict when allowance is below the signed amount.
    function test_exactMode_revertsWhenAllowanceBelowSignedAmount() public {
        vm.prank(owner);
        token.approve(address(host), 99e18);

        vm.expectRevert();
        host.exec(
            address(module),
            abi.encodeCall(OwnerTokenPullModule.execute, (IERC20(address(token)), 100e18, false))
        );
    }

    /// @notice Exact mode stays strict when owner balance is below the signed amount.
    function test_exactMode_revertsWhenBalanceBelowSignedAmount() public {
        ERC20Mock limitedToken = new ERC20Mock();
        limitedToken.mint(owner, 99e18);
        vm.prank(owner);
        limitedToken.approve(address(host), 100e18);

        vm.expectRevert();
        host.exec(
            address(module),
            abi.encodeCall(
                OwnerTokenPullModule.execute, (IERC20(address(limitedToken)), 100e18, false)
            )
        );
    }

    /// @notice A third party may trigger the host, but cannot change the source account.
    function test_thirdPartyCallerCanTriggerButSourceRemainsHostOwner() public {
        vm.prank(owner);
        token.approve(address(host), 75e18);
        uint256 nonOwnerBefore = token.balanceOf(nonOwner);

        vm.prank(caller);
        host.exec(
            address(module),
            abi.encodeCall(OwnerTokenPullModule.execute, (IERC20(address(token)), 75e18, false))
        );

        assertEq(token.balanceOf(owner), 925e18, "owner is source");
        assertEq(token.balanceOf(nonOwner), nonOwnerBefore, "non-owner unchanged");
        assertEq(token.balanceOf(address(host)), 75e18, "host is destination");
    }

    /// @notice Successful pulls emit executor, token, owner, and amount.
    function test_eventEmitsExecutorTokenOwnerAndAmount() public {
        vm.prank(owner);
        token.approve(address(host), 10e18);

        vm.expectEmit(true, true, true, true, address(host));
        emit OwnerTokenPulled(address(host), address(token), owner, 10e18);
        host.exec(
            address(module),
            abi.encodeCall(OwnerTokenPullModule.execute, (IERC20(address(token)), 10e18, false))
        );
    }

    /// @notice Event reports the actual pulled amount in underfill mode, not the signed maximum.
    function test_eventEmitsActualPulledAmountInUnderfillMode() public {
        vm.prank(owner);
        token.approve(address(host), 10e18);

        vm.expectEmit(true, true, true, true, address(host));
        emit OwnerTokenPulled(address(host), address(token), owner, 10e18);
        host.exec(
            address(module),
            abi.encodeCall(OwnerTokenPullModule.execute, (IERC20(address(token)), 50e18, true))
        );
    }

    /// @notice Zero token calldata is rejected before any transfer attempt.
    function test_zeroToken_reverts() public {
        vm.expectRevert(OwnerTokenPullModule__ZeroToken.selector);
        host.exec(
            address(module),
            abi.encodeCall(OwnerTokenPullModule.execute, (IERC20(address(0)), 1e18, false))
        );
    }

    /// @notice Zero amount calldata is rejected before any transfer attempt.
    function test_zeroAmount_reverts() public {
        vm.expectRevert(OwnerTokenPullModule__ZeroAmount.selector);
        host.exec(
            address(module),
            abi.encodeCall(OwnerTokenPullModule.execute, (IERC20(address(token)), 0, true))
        );
    }

    /// @notice Missing or insufficient allowance reverts without moving owner, host, or module balances.
    function test_missingOrLowAllowance_revertsAndLeavesBalancesUnchanged() public {
        vm.prank(owner);
        token.approve(address(host), 49e18);
        uint256 ownerBefore = token.balanceOf(owner);
        uint256 hostBefore = token.balanceOf(address(host));
        uint256 moduleBefore = token.balanceOf(address(module));

        vm.expectRevert();
        host.exec(
            address(module),
            abi.encodeCall(OwnerTokenPullModule.execute, (IERC20(address(token)), 50e18, false))
        );

        assertEq(token.balanceOf(owner), ownerBefore, "owner unchanged");
        assertEq(token.balanceOf(address(host)), hostBefore, "host unchanged");
        assertEq(token.balanceOf(address(module)), moduleBefore, "module unchanged");
    }

    /// @notice Repeated successful pulls credit only the delegatecall host, never the module address.
    function test_moduleContractNeverReceivesTokenBalanceAcrossSuccessfulPulls() public {
        vm.prank(owner);
        token.approve(address(host), 200e18);

        host.exec(
            address(module),
            abi.encodeCall(OwnerTokenPullModule.execute, (IERC20(address(token)), 80e18, false))
        );
        host.exec(
            address(module),
            abi.encodeCall(OwnerTokenPullModule.execute, (IERC20(address(token)), 20e18, true))
        );

        assertEq(token.balanceOf(address(module)), 0, "module balance remains zero");
        assertEq(token.balanceOf(address(host)), 100e18, "host receives pulls");
    }

    /// @notice Fuzzes fixed source and destination behavior for arbitrary callers and amounts.
    /// @param amountSeed Seed bounded to a nonzero pull amount.
    /// @param actor Caller that triggers the host delegatecall.
    function testFuzz_successfulPullOnlyMovesOwnerToDelegatecallHost(
        uint96 amountSeed,
        address actor
    ) public {
        vm.assume(actor != address(0));
        uint256 amount = bound(uint256(amountSeed), 1, 1_000e18);
        ERC20Mock fuzzToken = new ERC20Mock();
        fuzzToken.mint(owner, amount);
        fuzzToken.mint(nonOwner, amount);
        vm.prank(owner);
        fuzzToken.approve(address(host), amount);
        vm.prank(nonOwner);
        fuzzToken.approve(address(host), amount);

        uint256 ownerBefore = fuzzToken.balanceOf(owner);
        uint256 hostBefore = fuzzToken.balanceOf(address(host));
        uint256 nonOwnerBefore = fuzzToken.balanceOf(nonOwner);
        uint256 moduleBefore = fuzzToken.balanceOf(address(module));

        vm.prank(actor);
        host.exec(
            address(module),
            abi.encodeCall(
                OwnerTokenPullModule.execute, (IERC20(address(fuzzToken)), amount, false)
            )
        );

        assertEq(fuzzToken.balanceOf(owner), ownerBefore - amount, "owner is fixed source");
        assertEq(fuzzToken.balanceOf(address(host)), hostBefore + amount, "host is fixed sink");
        assertEq(fuzzToken.balanceOf(nonOwner), nonOwnerBefore, "caller cannot choose source");
        assertEq(fuzzToken.balanceOf(address(module)), moduleBefore, "module cannot accumulate");
    }
}
