// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { MockERC20 } from "./MockERC20.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { IPoolManager, Market, MarketId } from "src/interfaces/external/phoenix/IPoolManager.sol";

/// @notice Mock of a Phoenix Cork Principal Token (cPT) ERC20 for unwindMint and deposit accounting tests.
contract MockCpt {
    /// @notice Name.
    /// @return name Stored name value.
    string public name;
    /// @notice Symbol.
    /// @return symbol Stored symbol value.

    string public symbol;
    /// @notice Decimals.
    /// @return decimals Stored decimals value.
    // forge-lint: disable-next-line(screaming-snake-case-const)

    uint8 public constant decimals = 18;
    /// @notice Total supply.
    /// @return totalSupply Stored total supply value.

    uint256 public totalSupply;
    /// @notice Balance of.
    /// @return balanceOf Stored balance of value.

    mapping(address => uint256) public balanceOf;
    /// @notice Allowance.
    /// @return allowance Stored allowance value.

    mapping(address => mapping(address => uint256)) public allowance;
    /// @notice Emitted on transfer.
    /// @param from Source address.
    /// @param to Destination address.
    /// @param value Numeric value.

    event Transfer(address indexed from, address indexed to, uint256 value);
    /// @notice Emitted on approval.
    /// @param owner Owner address.
    /// @param spender Spender address.
    /// @param value Numeric value.

    event Approval(address indexed owner, address indexed spender, uint256 value);
    /// @param n Count or size value.
    /// @param s String value or scratch value.

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }
    /// @notice Mint.
    /// @param to Destination address.
    /// @param amount Token amount (raw units).

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }
    /// @notice Burn.
    /// @param from Source address.
    /// @param amount Token amount (raw units).

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }
    /// @notice Transfer.
    /// @param to Destination address.
    /// @param amount Token amount (raw units).
    /// @return Return value.

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }
    /// @notice Transfer from.
    /// @param from Source address.
    /// @param to Destination address.
    /// @param amount Token amount (raw units).
    /// @return Return value.

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            if (a < amount) {
                revert IERC20Errors.ERC20InsufficientAllowance(msg.sender, a, amount);
            }
            allowance[from][msg.sender] = a - amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
    /// @notice Approve.
    /// @param spender Spender address.
    /// @param amount Token amount (raw units).
    /// @return Return value.

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
}

/// @notice Mock of the Phoenix PoolManager exposing shares/market/unwindMint/deposit with knobs for zero-output and partial-deposit scenarios.
contract MockPhoenixPoolManager is IPoolManager {
    /// @notice PoolBinding struct.
    struct PoolBinding {
        MockERC20 cst;
        MockCpt cpt;
        MockERC20 ca;
        bool initialised;
    }
    /// @notice  pools.

    mapping(MarketId => PoolBinding) internal _pools;
    /// @notice Report zero unwind.
    /// @return reportZeroUnwind Stored report zero unwind value.

    mapping(MarketId => bool) public reportZeroUnwind;
    /// @notice Report zero deposit.
    /// @return reportZeroDeposit Stored report zero deposit value.

    mapping(MarketId => bool) public reportZeroDeposit;
    /// @notice Partial deposit numerator.
    /// @return partialDepositNumerator Stored partial deposit numerator value.

    mapping(MarketId => uint256) public partialDepositNumerator;
    /// @notice Partial deposit denominator.
    /// @return partialDepositDenominator Stored partial deposit denominator value.

    mapping(MarketId => uint256) public partialDepositDenominator;
    /// @notice Post-deposit `previewDeposit` quote numerator.
    /// @return postDepositQuoteNumerator Stored post-deposit quote numerator value.

    mapping(MarketId => uint256) public postDepositQuoteNumerator;
    /// @notice Post-deposit `previewDeposit` quote denominator.
    /// @return postDepositQuoteDenominator Stored post-deposit quote denominator value.

    mapping(MarketId => uint256) public postDepositQuoteDenominator;
    /// @notice Whether a `deposit` has been recorded for a market (arms the post-deposit quote).
    /// @return depositOccurred Stored deposit-occurred flag.

    mapping(MarketId => bool) public depositOccurred;
    /// @notice Bind.
    /// @param id Identifier.
    /// @param cst Cork Swap Token (cST).
    /// @param cpt Cork Principal Token (cPT).
    /// @param ca Collateral asset (CA).

    function bind(MarketId id, MockERC20 cst, MockCpt cpt, MockERC20 ca) external {
        _pools[id] = PoolBinding({ cst: cst, cpt: cpt, ca: ca, initialised: true });
    }
    /// @notice Sets report zero unwind.
    /// @param id Identifier.
    /// @param flag Boolean toggle.

    function setReportZeroUnwind(MarketId id, bool flag) external {
        reportZeroUnwind[id] = flag;
    }
    /// @notice Sets report zero deposit.
    /// @param id Identifier.
    /// @param flag Boolean toggle.

    function setReportZeroDeposit(MarketId id, bool flag) external {
        reportZeroDeposit[id] = flag;
    }
    /// @notice Sets partial deposit.
    /// @param id Identifier.
    /// @param num Numerator.
    /// @param den Denominator.

    function setPartialDeposit(MarketId id, uint256 num, uint256 den) external {
        partialDepositNumerator[id] = num;
        partialDepositDenominator[id] = den;
    }
    /// @notice Sets the post-deposit `previewDeposit` quote scaling for a market.
    /// @dev Once a `deposit` has been recorded for `id`, subsequent `previewDeposit` calls return
    ///      the canonical quote scaled by `num/den`. Models a hypothetical future Phoenix whose
    ///      quote becomes state-dependent (changes after the mutating `deposit`). Used to prove
    ///      `_depositLeg` samples the PRE-deposit quote (INV-DST-CST-MINT-RATIO-BOUNDED).
    /// @param id Identifier.
    /// @param num Numerator.
    /// @param den Denominator.

    function setPostDepositQuote(MarketId id, uint256 num, uint256 den) external {
        postDepositQuoteNumerator[id] = num;
        postDepositQuoteDenominator[id] = den;
    }
    /// @notice Shares.
    /// @param id Identifier.
    /// @return principalToken Cork Principal Token (cPT) contract.
    /// @return swapToken Cork Swap Token (cST) contract.

    function shares(MarketId id) external view returns (address principalToken, address swapToken) {
        PoolBinding storage p = _pools[id];
        principalToken = address(p.cpt);
        swapToken = address(p.cst);
    }
    /// @notice Market.
    /// @param id Identifier.
    /// @return Return value.

    function market(MarketId id) external view returns (Market memory) {
        PoolBinding storage p = _pools[id];
        return Market({
            collateralAsset: address(p.ca),
            referenceAsset: address(0),
            expiryTimestamp: type(uint256).max,
            rateMin: 0,
            rateMax: type(uint256).max,
            rateChangePerDayMax: 0,
            rateChangeCapacityMax: 0,
            rateOracle: address(0)
        });
    }
    /// @notice Unwind mint.
    /// @param id Identifier.
    /// @param sharesIn Input shares amount.
    /// @param owner Owner address.
    /// @param receiver Receiver address.
    /// @return caOut Output collateral-asset amount.

    function unwindMint(MarketId id, uint256 sharesIn, address owner, address receiver)
        external
        returns (uint256 caOut)
    {
        PoolBinding storage p = _pools[id];
        require(p.initialised, "MockPhoenix: pool not bound");
        // Mirror Phoenix CorkPoolManager truncation: shares are normalised to a multiple of
        // `minimumShares = 10**(18 - CAdecimals)` before the burn so the mock matches the
        // real pool's silent truncation semantics. For 18-dec CAs minimumShares == 1 and
        // this is a no-op; for low-dec CAs (e.g. 6-dec USDC) the truncation strands residue.
        uint8 caDecimals = p.ca.decimals();
        uint256 minimumShares = 10 ** (18 - caDecimals);
        uint256 effectivelyBurned = sharesIn - (sharesIn % minimumShares);
        p.cst.burn(owner, effectivelyBurned);
        p.cpt.burn(owner, effectivelyBurned);
        p.ca.mint(receiver, effectivelyBurned);
        caOut = reportZeroUnwind[id] ? 0 : effectivelyBurned;
    }
    /// @notice Deposit.
    /// @param id Identifier.
    /// @param caIn Input collateral-asset amount.
    /// @param receiver Receiver address.
    /// @return sharesOut Output shares amount.

    function deposit(MarketId id, uint256 caIn, address receiver)
        external
        returns (uint256 sharesOut)
    {
        PoolBinding storage p = _pools[id];
        require(p.initialised, "MockPhoenix: pool not bound");
        depositOccurred[id] = true;
        p.ca.burn(msg.sender, caIn);
        uint256 mintAmount = _previewDepositRaw(p, caIn);
        uint256 den = partialDepositDenominator[id];
        if (den != 0) {
            mintAmount = (mintAmount * partialDepositNumerator[id]) / den;
        }
        p.cst.mint(receiver, mintAmount);
        p.cpt.mint(receiver, mintAmount);
        sharesOut = reportZeroDeposit[id] ? 0 : mintAmount;
    }

    /// @notice Quote the canonical paired-share mint amount for a given collateral input.
    /// @dev Mirrors Phoenix's `tokenNativeDecimalsToFixed(caIn, caDecimals)` — independent of
    ///      the `setPartialDeposit` knob, which only perturbs the actual `deposit()` mint.
    ///      Consumed by `CorkRolloverContract._depositLeg` as the live upper bound (INV-DST-CST-MINT-
    ///      RATIO-BOUNDED).
    /// @param id Identifier.
    /// @param caIn Input collateral-asset amount.
    /// @return sharesOut Canonical paired-share amount for `caIn`.
    function previewDeposit(MarketId id, uint256 caIn) external view returns (uint256 sharesOut) {
        PoolBinding storage p = _pools[id];
        require(p.initialised, "MockPhoenix: pool not bound");
        sharesOut = _previewDepositRaw(p, caIn);
        uint256 den = postDepositQuoteDenominator[id];
        if (depositOccurred[id] && den != 0) {
            sharesOut = (sharesOut * postDepositQuoteNumerator[id]) / den;
        }
    }

    function _previewDepositRaw(PoolBinding storage p, uint256 caIn)
        internal
        view
        returns (uint256 canonical)
    {
        uint8 d = p.ca.decimals();
        if (d == 18) {
            return caIn;
        }
        if (d < 18) {
            return caIn * (10 ** (18 - uint256(d)));
        }
        return caIn / (10 ** (uint256(d) - 18));
    }
}

/// @notice Mock of a Phoenix PoolManager that omits the shares() getter, used to exercise rolloverContract fallback paths.
contract MockPhoenixPoolManagerNoCptGetter {
    /// @notice PoolBinding struct.
    struct PoolBinding {
        MockERC20 cst;
        MockCpt cpt;
        MockERC20 ca;
        bool initialised;
    }
    /// @notice  pools.

    mapping(MarketId => PoolBinding) internal _pools;
    /// @notice Bind.
    /// @param id Identifier.
    /// @param cst Cork Swap Token (cST).
    /// @param cpt Cork Principal Token (cPT).
    /// @param ca Collateral asset (CA).

    function bind(MarketId id, MockERC20 cst, MockCpt cpt, MockERC20 ca) external {
        _pools[id] = PoolBinding({ cst: cst, cpt: cpt, ca: ca, initialised: true });
    }
    /// @notice Market.
    /// @param id Identifier.
    /// @return Return value.

    function market(MarketId id) external view returns (Market memory) {
        PoolBinding storage p = _pools[id];
        return Market({
            collateralAsset: address(p.ca),
            referenceAsset: address(0),
            expiryTimestamp: type(uint256).max,
            rateMin: 0,
            rateMax: type(uint256).max,
            rateChangePerDayMax: 0,
            rateChangeCapacityMax: 0,
            rateOracle: address(0)
        });
    }
    /// @notice Unwind mint.
    /// @param id Identifier.
    /// @param sharesIn Input shares amount.
    /// @param owner Owner address.
    /// @param receiver Receiver address.
    /// @return caOut Output collateral-asset amount.

    function unwindMint(MarketId id, uint256 sharesIn, address owner, address receiver)
        external
        returns (uint256 caOut)
    {
        PoolBinding storage p = _pools[id];
        require(p.initialised, "MockPhoenixNoCpt: pool not bound");
        p.cst.burn(owner, sharesIn);
        p.cpt.burn(owner, sharesIn);
        p.ca.mint(receiver, sharesIn);
        caOut = sharesIn;
    }
    /// @notice Deposit.
    /// @param id Identifier.
    /// @param caIn Input collateral-asset amount.
    /// @param receiver Receiver address.
    /// @return sharesOut Output shares amount.

    function deposit(MarketId id, uint256 caIn, address receiver)
        external
        returns (uint256 sharesOut)
    {
        PoolBinding storage p = _pools[id];
        require(p.initialised, "MockPhoenixNoCpt: pool not bound");
        p.ca.burn(msg.sender, caIn);
        p.cst.mint(receiver, caIn);
        p.cpt.mint(receiver, caIn);
        sharesOut = caIn;
    }

    /// @notice Quote the canonical paired-share mint amount for a given collateral input.
    /// @param id Identifier.
    /// @param caIn Input collateral-asset amount.
    /// @return sharesOut Canonical paired-share amount for `caIn`.
    function previewDeposit(MarketId id, uint256 caIn) external view returns (uint256 sharesOut) {
        PoolBinding storage p = _pools[id];
        require(p.initialised, "MockPhoenixNoCpt: pool not bound");
        uint8 d = p.ca.decimals();
        if (d == 18) {
            return caIn;
        }
        if (d < 18) {
            return caIn * (10 ** (18 - uint256(d)));
        }
        return caIn / (10 ** (uint256(d) - 18));
    }
}
