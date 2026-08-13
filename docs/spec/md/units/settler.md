# Unit: Settler

> _Supplementary protocol reference. The canonical bundle for AI auditors is [`docs/agent-context/`](../../../agent-context/README.md). Code in `src/` is the source of truth when docs disagree._

## Source

`src/BaseSettler.sol` (abstract) holds the shared lifecycle; `src/ExactSettler.sol` and
`src/PartialSettler.sol` are the concrete mode contracts overriding internal hooks for the
Cork rollover flow. Implements `ISettler` (which extends `IOriginSettler`
and `IDestinationSettler`), provides ERC-7683 origin/destination
settler surfaces (`open` / `openFor` / `resolve` / `resolveFor` / `fill`), is
itself an EIP-712 verifier under domain `("CorkSettler", "1.0.0")`
(`src/BaseSettler.sol`), and brokers transient hops for srcCST / dstCST /
premium between filler, rolloverContract, and per-filler destination. Runtime polarity is
gated on `orderData.allowPartialFills`.

Audit-symbol shortcuts referenced below: `BS-ST-20` (cross-polarity FSM
invariant), `BS-FN-045`
(polarity-gated terminal accounting), `F-PUSH` (push-based token flow), `F-0024`
(Phoenix-style Settler owner identity), `M-08` (premium ceil-rounded floor), `M-11`
(Settler-side authoritative per-`(orderDigest, filler[, subFiller])` premium-fire latch;
rolloverContract's `premiumFiredFor` is local rolloverContract replay protection only), `M-29`
(write `srcCstProvided` not `dstCstProduced`), `SL-14` (distinct Phoenix pool
ids on open), `INV-NEW-POLARITY-GATE` / `INV-NEW-POLARITY-ISOLATION`,
`INV-DSTCST-FLOOR`, `INV-FILLER-AUTH`, `INV-PARAMS-SETTLER-PIN`,
`INV-DEFAULTER-RECOUP`, `INV-DST-CST-REACHABLE`, `INV-TRUST-CONFIG-DELAY`,
`INV-SETTLER-APPROVED`, `INV-PAUSE-GATES-ALL-ENTRYPOINTS`,
`N-INV-FILLER-SETTLED-STICKY`, `N-INV-PARTIAL-RESIDUAL-RECONCILES-TO-TOTAL`.
Ledger source: `docs/INVARIANTS.md`.

## Inheritance

| Base | File:line of `import` |
|------|------------------------|
| `ISettler` (extends `IOriginSettler`, `IDestinationSettler`) | `src/interfaces/settlers/ISettler.sol` |
| `EIP712` (OZ) | `src/BaseSettler.sol` |
| `AccessControl` (OZ) | `src/BaseSettler.sol` |
| `Ownable` (OZ) | `src/BaseSettler.sol` |
| `Pausable` (OZ) | `src/BaseSettler.sol` |
| `ReentrancyGuardTransient` (OZ) | `src/BaseSettler.sol` |

Inheritance list declared at `src/BaseSettler.sol:84-92` (`abstract contract BaseSettler`); `ExactSettler` / `PartialSettler` inherit `BaseSettler`.

## Storage

### ERC-7201 namespace

| Item | Value | Src |
|------|-------|-----|
| Exact namespace string | `cork.rollover.exact-settler` | `src/ExactSettler.sol` |
| Exact slot literal | `0x545e6593eaef4a0977611e4e3c66cf08833dc54fedd0a55f3f6572464c0e3900` | `src/ExactSettler.sol` |
| Partial namespace string | `cork.rollover.partial-settler` | `src/PartialSettler.sol` |
| Partial slot literal | `0xde4df9e562f99ce501d2218ebb94dfddd6f4be4f9c4423c45effffd6fd3f6f00` | `src/PartialSettler.sol` |
| Storage slot declarations | `bytes32 private constant` | `src/ExactSettler.sol`, `src/PartialSettler.sol` |
| Loader | `_s() private pure returns (... storage $)` | `src/ExactSettler.sol`, `src/PartialSettler.sol` |

The slot literals equal `cast index-erc7201 cork.rollover.exact-settler` and
`cast index-erc7201 cork.rollover.partial-settler`.

### Constants and immutables

| Symbol | Type | Purpose | Src |
|--------|------|---------|-----|
| `EXACT_SETTLER_STORAGE_SLOT` | `bytes32 private constant` | ERC-7201 slot for exact-fill storage. | `src/ExactSettler.sol` |
| `PARTIAL_SETTLER_STORAGE_SLOT` | `bytes32 private constant` | ERC-7201 slot for partial-fill storage. | `src/PartialSettler.sol` |
| `PAUSER_ROLE` | `bytes32 internal constant = keccak256("PAUSER_ROLE")` | AccessControl role for `pause()`. | `src/BaseSettler.sol` |
| `UNPAUSER_ROLE` | `bytes32 internal constant = keccak256("UNPAUSER_ROLE")` | AccessControl role for `unpause()`. Held by a key distinct from `PAUSER_ROLE`. | `src/BaseSettler.sol` |
| `RECOVERY_ROLE` | `bytes32 public constant = keccak256("RECOVERY_ROLE")` | AccessControl role that gates `recoverToken`. | `src/BaseSettler.sol` |
| `ROLLOVER_CONTRACT_FACTORY` | `address public immutable` | Trusted `ICorkRolloverContractFactory` for deployed-rolloverContract checks and intent-hook forwarding. | `src/BaseSettler.sol` |
| `CORK_POOL_MANAGER` | `address public immutable` | Phoenix `PoolManager` for canonical cST resolution and share-quantum checks. | `src/BaseSettler.sol` |

The Settler initializes OZ `Ownable.owner()` from `ensOwner_` for a
Phoenix-style ENS/deployment identity. Ownership can transfer or renounce via
OZ `Ownable`, but protocol/admin powers remain separate `AccessControl` roles.
OZ `EIP712` maintains its own cached `_HASHED_NAME` / `_HASHED_VERSION` /
`_CACHED_DOMAIN_SEPARATOR` on canonical EIP-712 parent slots; OZ
`ReentrancyGuardTransient` uses transient storage only. None of these collide
with the namespaced struct.

### Mode-specific ERC-7201 structs

Storage is split into two disjoint per-mode structs (there is no single
`BaseSettlerStorage`). Mapping bodies live at hashed slots; "offset" denotes head
position.

#### `ExactSettlerStorage`

Declared at `src/ExactSettler.sol:50-57`.

| Offset | Symbol | Type | Purpose | Src |
|--------|--------|------|---------|-----|
| `+0` | `orderStatus` | `mapping(bytes32 orderDigest => RolloverTypes.OrderStatus status)` | Per-order lifecycle status (`None=0` / `Opened` / `Settled` / `Expired` / `Cancelled` / `Closing`). BS-ST-20. | `src/ExactSettler.sol` |
| `+1` | `rolloverAccounting` | `mapping(bytes32 orderDigest => SettlerTypes.ExactRolloverAccounting record)` | Singleton exact-mode rollover record (includes `settlementDestination`, `dstCstProduced`, `premiumFired`). | `src/ExactSettler.sol` |
| `+2` | `dstCstResidual` | `mapping(bytes32 orderDigest => uint256 residual)` | Live order-level exact-mode dstCST residual; drains to zero on settlement or reclaim. | `src/ExactSettler.sol` |
| `+3` | `orderById` | `mapping(bytes32 orderId => RolloverTypes.OrderData orderData)` | Reserved former `orderById` slot; intentionally unused. | `src/ExactSettler.sol` |
| `+4` | `exactSubFiller` | `mapping(bytes32 orderDigest => bytes32 subFiller)` | Sub-filler key recorded at rollover, binding later exact premium payloads. | `src/ExactSettler.sol` |

#### `PartialSettlerStorage`

Declared at `src/PartialSettler.sol:65-92`.

| Offset | Symbol | Type | Purpose | Src |
|--------|--------|------|---------|-----|
| `+0` | `orderStatus` | `mapping(bytes32 orderDigest => RolloverTypes.OrderStatus status)` | Per-order lifecycle status. BS-ST-20. | `src/PartialSettler.sol` |
| `+1` | `fillerRollovers` | `mapping(bytes32 orderDigest => mapping(address filler => mapping(bytes32 subFiller => SettlerTypes.FillerRolloverAccounting)))` | Per-`(orderDigest, filler, subFiller)` slot rollover record. M-29: stores `srcCstProvided`. | `src/PartialSettler.sol` |
| `+2` | `totalDstCstEscrowed` | `mapping(bytes32 orderDigest => uint256 escrow)` | Live aggregate dstCST residual; participates in N-INV-PARTIAL-RESIDUAL-RECONCILES-TO-TOTAL. | `src/PartialSettler.sol` |
| `+3` | `totalDstCstPremiumed` | `mapping(bytes32 orderDigest => uint256 produced)` | Aggregate produced dstCST already included in premium calculations. | `src/PartialSettler.sol` |
| `+4` | `totalPremiumCharged` | `mapping(bytes32 orderDigest => uint256 premium)` | Aggregate premium already charged for the order. | `src/PartialSettler.sol` |
| `+5` | `totalSrcCstConsumed` | `mapping(bytes32 orderDigest => uint256 consumed)` | Historical aggregate srcCST actually consumed, net of per-fill leftovers. | `src/PartialSettler.sol` |
| `+6` | `participantCount` | `mapping(bytes32 orderDigest => uint32 count)` | Unique `(filler, subFiller)` slot counter. | `src/PartialSettler.sol` |
| `+7` | `fillerDstCstResidual` | `mapping(bytes32 orderDigest => mapping(address filler => mapping(bytes32 subFiller => uint256 residual)))` | Live per-slot drainable dstCST residual. | `src/PartialSettler.sol` |
| `+8` | `orderById` | `mapping(bytes32 orderId => RolloverTypes.OrderData orderData)` | Reserved former `orderById` slot; intentionally unused. | `src/PartialSettler.sol` |
| `+9` | `fillerDestination` | `mapping(bytes32 orderDigest => mapping(address filler => mapping(bytes32 subFiller => address destination)))` | Per-slot dstCST payout destination captured at ROLLOVER time. F-PUSH. | `src/PartialSettler.sol` |
| `+10` | `fillerSettled` | `mapping(bytes32 orderDigest => mapping(address filler => mapping(bytes32 subFiller => bool settled)))` | Per-slot double-claim latch. `N-INV-FILLER-SETTLED-STICKY`. | `src/PartialSettler.sol` |

### `FillerPayload` decoded shape

The `FillerPayload` struct is **not** local to the Settler; it lives in
`src/types/FillerTypes.sol`, while `LibFillerAuth` owns the 10-tuple decode helpers.
The Settler imports it (`src/BaseSettler.sol`) and references it inline via
`FillerPayload memory payload` (`src/BaseSettler.sol`).
ABI v2 wire format: `(uint8 phaseU8, uint256 fillAmount, uint256 premium,
address destination, address premiumFor, RolloverTypes.RolloverIntent intent,
uint256 minDstPerSrc, bytes fillerAuthSig, bytes32 subFiller, bytes cptHolderSig)`.
The trailing `fillerAuthSig` gates delegated-executor ROLLOVER fills under `INV-FILLER-AUTH`; async PREMIUM settlement uses the recorded slot and does not re-query live filler auth.

## Entrypoints

Modifier sources: `whenNotPaused` (OZ `Pausable`); `nonReentrant` (OZ
`ReentrancyGuardTransient`); `onlyRole(...)` (OZ `AccessControl`); `pure` /
`view` are language qualifiers.

| Function | Modifiers | Role gate | Revert paths | Source |
|----------|-----------|-----------|--------------|--------|
| `constructor(address rolloverContractFactory_, address phoenixPoolManager_, address ensOwner_, address initialAdmin_, address initialPauser_, address initialUnpauser_)` | `EIP712("CorkSettler","1.0.0")`; `Ownable(ensOwner_)`; `initialAdmin_` → `DEFAULT_ADMIN_ROLE` + `RECOVERY_ROLE`; `initialPauser_` → `PAUSER_ROLE`; `initialUnpauser_` → `UNPAUSER_ROLE` | constructor | `Settler__ZeroAddress` / OZ `OwnableInvalidOwner` for zero `ensOwner_` | `src/BaseSettler.sol` (`ExactSettler` / `PartialSettler` inherit) |
| `DOMAIN_SEPARATOR()` | `public view` | none | — | `src/BaseSettler.sol` |
| `version()` | `external pure` | none | — (returns `"1.0.0"`) | `src/BaseSettler.sol` |
| `owner()` | `public view` inherited from OZ `Ownable` | none | — | `src/BaseSettler.sol` |
| `transferOwnership(address)` / `renounceOwnership()` | inherited (`Ownable`) | `onlyOwner` | OZ `OwnableUnauthorizedAccount`, `OwnableInvalidOwner` | inherited |
| `dstCstLiabilityOf(address)` | `external view` | none | — | `src/BaseSettler.sol` |
| `recoverableTokenBalance(address)` | `external view` | none | `Settler__ZeroAddress`, `Settler__UnderfundedDstCstLiability` | `src/BaseSettler.sol` |
| `recoverToken(IERC20,address,uint256)` | `external nonReentrant onlyRole(RECOVERY_ROLE)` | `RECOVERY_ROLE` | `Settler__ZeroAddress`, `Settler__ZeroAmount`, `Settler__UnderfundedDstCstLiability`, `Settler__InsufficientRecoverableBalance`, OZ `AccessControlUnauthorizedAccount` | `src/BaseSettler.sol` |
| `pause()` | `external onlyRole(PAUSER_ROLE)` | `PAUSER_ROLE` | `EnforcedPause` (OZ), `AccessControlUnauthorizedAccount` | `src/BaseSettler.sol` |
| `unpause()` | `external onlyRole(UNPAUSER_ROLE)` | `UNPAUSER_ROLE` | `ExpectedPause` (OZ), `AccessControlUnauthorizedAccount` | `src/BaseSettler.sol` |
| `open(OnchainCrossChainOrder)` | `external whenNotPaused nonReentrant` | none | `msg.sender` must equal decoded `orderData.user`; `fillDeadline` / `orderDataType` / Cork shape gates match the gasless path; no signature required | `src/BaseSettler.sol` |
| `openFor(GaslessCrossChainOrder,bytes,bytes)` | `external whenNotPaused nonReentrant` | none | `Settler__BadUserSignature` + all `_validateOrderCommon` reverts (see below) + `Settler__OpenAfterOpenDeadline` + `Settler__OrderInTerminalState`; `originFillerData` ignored | `src/BaseSettler.sol` |
| `resolve(OnchainCrossChainOrder)` | `external view` | none | state-aware signature-free validation with the same abbreviated-envelope `fillDeadline` binding as on-chain `open` | `src/BaseSettler.sol` |
| `resolveFor(GaslessCrossChainOrder,bytes)` | `external view` | none | state-aware signature-free validation: `None` orders run `_validateOrderCommon` with `openDeadline`; `Opened` orders skip only the open-deadline gate; all paths reject `Settler__FillAfterDeadline`, `Settler__OrderInTerminalState`, and non-time `_validateOrderCommon` failures; `originFillerData` ignored | `src/BaseSettler.sol` |
| `fill(bytes32,bytes,bytes)` | `external override whenNotPaused nonReentrant` | none | `Settler__OrderIdMismatch`, `Settler__FillAfterDeadline`, `Settler__UnauthorizedFiller`, `Settler__UnknownPhase`; ROLLOVER adds `Settler__OrderInTerminalState`, `Settler__ZeroAddress` (zero destination), `Settler__PremiumAlreadyFiredRollover`, `Settler__ZeroMint`, `Settler__DstProducedNotDelivered`, `Settler__SrcLeftoverDeliveryShortfall`, `Settler__SrcLeftoverExceedsFillAmount`, `Settler__InsufficientMintRate`, `Settler__AlreadyFilled` (exact write), plus all `_validateOrderCommon` reverts when `status == None`; PREMIUM adds `Settler__OrderInTerminalState`, `Settler__NoRolloverLegForFiller`, `Settler__PremiumBeforeRollover`, `Settler__AlreadyFilled`, `Settler__PremiumExceedsCap`, `Settler__PremiumDeliveryMismatch` | `src/BaseSettler.sol` |
| `fillerAuthTypehash()` | `external pure` | none | — | `src/BaseSettler.sol` |
| `reclaim(bytes32,address,bytes32,bytes)` | `external whenNotPaused nonReentrant` | async/separate premium only (`premiumPaymentMode == PREMIUM_PAYMENT_MODE_ATOMIC_OR_SEPARATE`) | Decodes `GaslessCrossChainOrder` from `originData`, then decodes/binds Cork `OrderData` from `order.orderData` (`LibRolloverOrder__BadOrderType`, `Settler__OrderIdMismatch`), rejects non-reclaimable statuses (`Settler__OrderNotReclaimable`), rejects atomic-only orders (`Settler__AsyncPremiumOptInRequired`), requires `block.timestamp > fillDeadline` (`Settler__ReclaimBeforeFillDeadline`), then clears a reclaimable residual (`Settler__NoResidualToReclaim`). Exact mode releases the unpaid residual to `orderData.rolloverContract` and terminalizes non-`Expired` orders as `Expired`; already-`Expired` exact reclaim does not re-emit. Partial mode releases the slot residual to `orderData.rolloverContract`, leaves `Closing` orders open while other escrow remains, and terminalizes when aggregate escrow reaches zero. | `src/BaseSettler.sol:296-329` |
| `markExpired(bytes32,bytes)` | `external whenNotPaused nonReentrant` | none | `Settler__OrderInTerminalState`, `Settler__OrderIdMismatch`, `Settler__NotExpired`, `Settler__PremiumAlreadyFiredRefundBlocked` | `src/BaseSettler.sol:332-349` |
| `cancel(bytes32,bytes,bytes)` | `external whenNotPaused nonReentrant` | none (user EIP-712 / ERC-1271 sig) | `Settler__OrderInTerminalState`, `Settler__OrderIdMismatch`, `Settler__UnauthorizedCancel`, `Settler__OrderHasFills` | `src/BaseSettler.sol` |
| `orderStatus(bytes32)` | `external view` | none | — | `src/BaseSettler.sol` |
| `rolloverAccountingOf(bytes32)` (exact) | `external view` | none | — | `src/ExactSettler.sol` |
| `rolloverAccountingOf(bytes32)` (partial) | `external view` | none | — | `src/PartialSettler.sol` |
| `fillerSlotAccountingOf(bytes32,address,bytes32)` (partial) | `external view` | none | — | `src/PartialSettler.sol` |
| `hasRole(bytes32,address)` / `getRoleAdmin(bytes32)` / `grantRole(bytes32,address)` / `revokeRole(bytes32,address)` / `renounceRole(bytes32,address)` | inherited (`AccessControl`) | `onlyRole(admin)` for grant/revoke | OZ `AccessControlUnauthorizedAccount` | inherited |

`_validateOrderCommon` (`src/BaseSettler.sol`) is invoked from `openFor`,
direct-fill admission, and the resolver path. `openFor`, on-chain `open`, direct-fill
admission from `None`, and resolver calls for `None` orders enforce the
open-deadline gate. Resolver calls for already-`Opened` orders skip only that
gate and still run the non-time envelope checks plus all shared shape/canonical
validation. Its envelope/shape revert set is raised by
`LibSettlerAdmission.validateEnvelope` / `validateOrderShape`
(`src/libraries/LibSettlerAdmission.sol`):
`Settler__OriginSettlerMismatch`, `Settler__UserMismatch`,
`Settler__OrderSaltMismatch`, `Settler__OriginChainIdMismatch`,
`Settler__OpenDeadlineMismatch`, `Settler__FillDeadlineMismatch`,
`Settler__SettlerMismatch`, `Settler__OpenDeadlineAfterFillDeadline`,
`Settler__WrongOriginChain`, `Settler__WrongDestinationChain`,
`Settler__ZeroOrderSize`, `Settler__ZeroPremiumRate`,
`Settler__ZeroSrcCstToken`, `Settler__ZeroDstCstToken`,
`Settler__SrcCstEqualsPremiumToken`, `Settler__DstCstEqualsPremiumToken`,
`Settler__SamePoolId`,
`Settler__RolloverParamsSrcCstMismatch`,
`Settler__RolloverParamsDstCstMismatch`,
`Settler__ZeroRolloverIntentHash`, `Settler__SelfExclusiveFiller`.
`_validateOrderCommon` itself additionally enforces the factory-attested rolloverContract gate
(`Settler__RolloverContractNotDeployed`), the user==cPT-holder check (`Settler__UserNotRolloverContractOwner`),
canonical-cST resolution against `CORK_POOL_MANAGER` (`Settler__SrcCstNotCanonical` /
`Settler__DstCstNotCanonical`), share-quantum alignment via
`LibPhoenixShareQuantum.requireOrderSizeAligned`, the pool-expiry gate
(`Settler__FillDeadlineExceedsPoolExpiry`), and `_validateMode` mode dispatch.

## Internal helpers

Terminal-state predicates are free functions `isHardTerminal` / `blocksRollover` in
`src/types/SettlerTypes.sol` (imported into `BaseSettler`), not private methods.

| Helper | Visibility | Purpose | Src |
|--------|-----------|---------|-----|
| `_validateOrderForFill(orderData, order, orderDigest, cptHolderSig)` | `internal view` | Wraps `_validateOrderCommon` with the direct-fill open-deadline gate and cPT-holder signature check; called by `fill` when `status == None`. | `src/BaseSettler.sol:849` |
| `_validateOrderCommon(orderData, order)` | `internal view` | Shared non-time admission chain: delegates envelope/shape validation to `LibSettlerAdmission`, then enforces factory-attested rolloverContract, user==cPT-holder, canonical-cST resolution, share-quantum alignment, pool-expiry gate, and `_validateMode` dispatch. | `src/BaseSettler.sol:890` |
| `_resolveDecodedOrder(orderData, gaslessOrder)` | `private view returns (ResolvedCrossChainOrder)` | Reads order status, rejects terminal/Closing statuses and expired fill deadlines, then validates state-aware admission: `None` keeps openDeadline; `Opened` skips only openDeadline. It finally projects the ERC-7683 `ResolvedCrossChainOrder` via `LibRolloverOrder.buildResolvedOrder`. | `src/BaseSettler.sol:763` |
| `_gaslessEquivalentOrder(orderData, orderDataType, encodedOrderData)` | `private pure returns (GaslessCrossChainOrder)` | Converts the standard on-chain envelope payload into Cork's internal gasless-envelope shape for shared resolve/open projection. | `src/BaseSettler.sol:787` |
| `_orderDigestMemory(orderData)` | `internal view returns (bytes32)` | EIP-712 `OrderData` typed-data digest. | `src/BaseSettler.sol:932` |
| `_decodeFillDispatchContext(orderId, originData, fillerData)` | `private` | Decodes the shared fill context and the leading `fillerData` tag into a `FillDispatchContext`. | `src/BaseSettler.sol:553` |
| `_fillAtomic(context, fillerData)` | `private` | Atomic fill body: rollover validation → hooks + delivery verification → finalize → premium payout. | `src/BaseSettler.sol:578` |
| `_fillAsync(context, fillerData)` | `private` | Async fill body. | `src/BaseSettler.sol:659` |
| `_validateRolloverBeforeExecution(...)` | `private` | Rollover preflight: amount bounds, zero-destination guard (`Settler__ZeroAddress`), then `_validateRolloverBeforeExecutionForMode`. | `src/BaseSettler.sol:951` |
| `_executeRolloverHooksAndVerifyDelivery(...)` | `private` | Dispatches rolloverContract hooks and verifies dstCST/srcCST delivery against observed deltas. | `src/BaseSettler.sol:988` |
| `_finalizeVerifiedRollover(...)` | `private` | Applies the INV-DSTCST-FLOOR mint-rate floor and records mode accounting via `_recordRolloverAccountingForMode`. | `src/BaseSettler.sol:1052` |
| `_payPremiumAndReleaseDstCst(...)` | `private` | PREMIUM body: required-premium charge → balance-delta verify → release escrowed dstCST. | `src/BaseSettler.sol:1133` |
| `_dispatchToFactory(orderData, orderDigest, payload, fillContext)` | `private returns (uint256, uint256)` | Narrow external factory/rolloverContract dispatch boundary; calls `ICorkRolloverContractFactory(ROLLOVER_CONTRACT_FACTORY).executeIntentHooks`. | `src/BaseSettler.sol` |
| `_validateMode` / `_validateRolloverBeforeExecutionForMode` / `_recordRolloverAccountingForMode` / `_settlePaidRolloverRecord` / `_clearReclaimableResidualForMode` / `_cancelOrderForMode` | mode `virtual` overrides | Per-mode storage hooks implemented in `ExactSettler` / `PartialSettler`. | `src/ExactSettler.sol`, `src/PartialSettler.sol` |
| `_s()` | `private pure` | ERC-7201 storage loader via assembly (`ExactSettlerStorage` / `PartialSettlerStorage`). | `src/ExactSettler.sol`, `src/PartialSettler.sol` |

## Invariants touched

| Invariant | Where enforced on the Settler | Ledger reference |
|-----------|-------------------------------|------------------|
| **BS-ST-20** (cross-polarity FSM transitions) | All state-mutating paths via free functions `blocksRollover` / `isHardTerminal` (`src/types/SettlerTypes.sol`). `Settler__OrderInTerminalState` revert sites in `src/BaseSettler.sol`. | `docs/INVARIANTS.md:17` |
| **INV-NEW-POLARITY-GATE** (read `isPartial` before any state write) | Polarity resolved in `_validateOrderCommon` via `_validateMode`; mode dispatch occurs before any storage write. | `src/BaseSettler.sol`; `docs/INVARIANTS.md:36` |
| **INV-NEW-POLARITY-ISOLATION** (disjoint per-polarity slots) | `_recordRolloverAccountingForMode` writes only the active mode's storage struct (`ExactSettlerStorage` vs `PartialSettlerStorage`). | `src/ExactSettler.sol`, `src/PartialSettler.sol`; `docs/INVARIANTS.md:47` |
| **INV-DSTCST-FLOOR** (filler `minDstPerSrc` enforcement) | `dstProduced >= Math.mulDiv(srcConsumed, minDstPerSrc, 1e18, Math.Rounding.Floor)` in `_finalizeVerifiedRollover`; `0` opts out. | `src/BaseSettler.sol:953`; `docs/INVARIANTS.md:58` |
| **M-08** (premium ceil floor) | `requiredPremium = Math.mulDiv(produced, minPremiumPerShare, 1e18, Math.Rounding.Ceil)` computed by `LibAtomicFill.computeRequiredPremium`; revert `Settler__PremiumExceedsCap` when the required premium exceeds the submitted cap, and `Settler__PremiumDeliveryMismatch` if measured token delivery is short. | `src/libraries/LibAtomicFill.sol:100-106`; `docs/INVARIANTS.md:134` |
| **M-29** (partial mode writes `srcCstProvided` not `dstCstProduced`) | `_recordRolloverAccountingForMode` writes `srcProvided` into `rec.srcCstProvided` (`src/PartialSettler.sol`). | `docs/INVARIANTS.md:207` |
| **F-PUSH** (push-based token flow) | srcCST and premium: `safeTransferFrom(filler → rolloverContract)` directly (`src/BaseSettler.sol`). dstCST: `rolloverContract → Settler → destination` during in-frame settlement or to rolloverContract at reclaim. | `docs/INVARIANTS.md` `F-PUSH` |
| **F-0024** (Phoenix-style Settler owner identity) | Settler `owner()` is an OZ `Ownable` ENS/deployment identity only: transferable/renounceable, but not a protocol permission. Bounded token rescue is gated by `RECOVERY_ROLE`; role management stays on `DEFAULT_ADMIN_ROLE`. | `src/BaseSettler.sol`; `docs/INVARIANTS.md` |
| **BS-FN-045** (polarity-gated terminal accounting) | Internal settlement branches on mode; partial decrements per-slot; exact decrements order-level + transitions to `Settled`. | `src/ExactSettler.sol`, `src/PartialSettler.sol`; `docs/INVARIANTS.md:246` |
| **INV-DEFAULTER-RECOUP** (defaulter residual → rolloverContract) | `reclaim` gates `status ∈ {Expired, Closing, Opened, None}` and `block.timestamp > fillDeadline`; transfers to `orderData.rolloverContract`. | `src/BaseSettler.sol`; `docs/INVARIANTS.md:273` |
| **INV-DST-CST-REACHABLE** (every dstCST residual reachable via premium or reclaim) | Reachability matrix: premium-paid residual releases in the same `fill(... PREMIUM)` transaction; defaulter residual via `reclaim`. | `src/BaseSettler.sol`; `docs/INVARIANTS.md:322` |
| **INV-FILLER-AUTH** (ROLLOVER exclusive-filler gate) | `LibFillerAuth.isAuthorised` is called for ROLLOVER slot creation; async PREMIUM settlement uses the recorded destination/subFiller and releases dstCST only to that destination. | `src/libraries/LibFillerAuth.sol:91`; `docs/INVARIANTS.md:1014` |
| **SL-14** (distinct Phoenix pool ids on open) | `_validateOrderCommon` delegates to `LibSettlerAdmission.validateOrderShape`, which compares src/dst pool ids; revert `Settler__SamePoolId`. | `src/libraries/LibSettlerAdmission.sol`; `docs/INVARIANTS.md:719` |
| **INV-PAUSE-GATES-ALL-ENTRYPOINTS** (every external state-changing function `whenNotPaused`) | `open` / `openFor` / `fill` / `reclaim` / `markExpired` / `cancel`. | `src/BaseSettler.sol`; `docs/INVARIANTS.md:1261` |
| **N-INV-FILLER-SETTLED-STICKY** (partial-mode settlement latch monotone) | `fillerSettled[orderId][filler][subFiller] = true` written by internal settlement and reclaim; never reset. | `docs/INVARIANTS.md:1307` |
| **N-INV-PARTIAL-RESIDUAL-RECONCILES-TO-TOTAL** (`Σ_slot fillerDstCstResidual == totalDstCstEscrowed`) | Paired increments on rollover; paired decrements during in-frame settlement and `reclaim`. | `docs/INVARIANTS.md:1321` |

External invariants the Settler relies on but does not itself enforce:

- **INV-SETTLER-APPROVED** (factory allowlist; the factory rejects non-approved Settlers when `executeIntentHooks` is called) — `docs/INVARIANTS.md:955`.
- **INV-PARAMS-SETTLER-PIN** (rolloverContract pins `orderData.rolloverParams.settler == ctx.originSettler`); the Settler supplies `ctx.originSettler = address(this)` at `src/BaseSettler.sol` — `docs/INVARIANTS.md:1172`.
- **M-11** — protocol-wide premium-replay gate is **Settler-internal** (`rec.premiumFired`, keyed by `(orderDigest, filler[, subFiller])`), set inside the atomic-fill frame and reverted with the frame on failure. RolloverContract `premiumFiredFor[orderDigest][filler][subFiller]` is secondary local replay protection that commits atomically on success. The Settler supplies `ctx.filler = msg.sender` at `src/BaseSettler.sol` — `docs/INVARIANTS.md`.
- **INV-TRUST-CONFIG-DELAY** (rolloverContract trust-config time-lock) — `docs/INVARIANTS.md:340`.
- **INV-CPT-CONTAINED** (CPT containment rolloverContract-side) — `docs/INVARIANTS.md:730`.

Contract-local invariants (asserted in source but not promoted to top-level
ledger entries): pool-expiry strict-`<` gate (`src/BaseSettler.sol`),
payload self-binding (`src/libraries/LibSettlerAdmission.sol`), envelope/payload equality
(`src/libraries/LibSettlerAdmission.sol`), self-exclusive-filler DoS guard
(`src/libraries/LibSettlerAdmission.sol`), RolloverParams `src/dst` cross-check
(`src/libraries/LibSettlerAdmission.sol`), rolloverContract-intent binding (`src/libraries/LibSettlerAdmission.sol`),
zero-destination guard at ROLLOVER (`src/BaseSettler.sol:852-854`, reverts `Settler__ZeroAddress`),
dst-produced delivery `>=` post-condition (`src/BaseSettler.sol`),
exact premium-delivery `==` post-condition (`src/BaseSettler.sol`),
CEI ordering on settle/reclaim (latches and residual zeroing before
`safeTransfer`).

## Integrations

Outbound surfaces the Settler calls:

| Target | Interface / Method | Use site | Src |
|--------|--------------------|----------|-----|
| `ICorkRolloverContractFactory` (immutable `ROLLOVER_CONTRACT_FACTORY`) | `isDeployedRolloverContract(address)` (staticcall) | Allowlist gate inside `_validateOrderCommon`. | `src/BaseSettler.sol` |
| `ICorkRolloverContractFactory` | `executeIntentHooks(rolloverContract, orderDigest, phaseU8, intent, cptHolderSig, ctx, orderData)` | Dispatched by `_dispatchToFactory` from both ROLLOVER and PREMIUM branches; returns `(dstProduced, srcLeftover)`. | `src/BaseSettler.sol` |
| `IPoolManager` (Phoenix) | `shares(MarketId)` | Canonical-cST resolution against `CORK_POOL_MANAGER` inside `_validateOrderCommon`. | `src/BaseSettler.sol` |
| `IPoolShare` (Phoenix) | `expiry() returns (uint256)` | Pool-expiry gate inside `_validateOrderCommon`. | `src/BaseSettler.sol` |
| OZ `SignatureChecker` | `isValidSignatureNow(signer, digest, sig)` (ecrecover + ERC-1271 staticcall) | User sig on open (`src/BaseSettler.sol`); cPT-holder sig on cancel (`src/BaseSettler.sol`); filler-auth sig via `LibFillerAuth.isAuthorised` (`src/libraries/LibFillerAuth.sol:107`). | — |
| OZ `SafeERC20` | `safeTransfer` / `safeTransferFrom` | Direct srcCST + premium `msg.sender → rolloverContract` (`BaseSettler`); src refund on underfill; dstCST payout on settle/reclaim (`ExactSettler` / `PartialSettler`). No Settler premium custody or `forceApprove` broker to rolloverContract. | — |
| `LibSettlerHashing` | `hashCancelOrder(orderId, orderSalt)` | `cancel` typed-data hash. | `src/BaseSettler.sol` |
| `LibRolloverOrder` | `decodeOrderData` / `buildResolvedOrder` | `openFor`, `resolve` / `resolveFor`, `fill`. | `src/BaseSettler.sol` |
| `LibHookPhase` | `from(uint8) returns (RolloverTypes.HookPhase)` | Phase-tag parser in `fill`. | `src/BaseSettler.sol` |
| `LibFillerAuth` | `decodePayload` / `isAuthorised` / `hashFillerAuth` | 10-tuple decode + ROLLOVER exclusive-filler gate. Async PREMIUM does not re-query live auth after slot record. | `src/BaseSettler.sol` |
| `Typehashes` | `ORDER_DATA_TYPEHASH` / `ROLLOVER_PARAMS_TYPEHASH` / `FILLER_AUTH_TYPEHASH` | EIP-712 type pins. | `src/BaseSettler.sol` |

ERC dependencies:

- **ERC-7683** origin/destination settler surface (`open` / `openFor` / `resolve` / `resolveFor` / `fill`) via `ISettler` umbrella over `IOriginSettler` + `IDestinationSettler`. `src/BaseSettler.sol`.
- **EIP-712** typed-data signing under domain `(CorkSettler, 1.0.0)` rebuilt on chain-id drift by OZ `EIP712._domainSeparatorV4`. `src/BaseSettler.sol`.
- **ERC-1271** contract signatures via OZ `SignatureChecker.isValidSignatureNow` at user sig on open, cPT-holder signatures, and ROLLOVER filler-auth signatures (`src/libraries/LibFillerAuth.sol:107`). Async PREMIUM intentionally avoids a fresh live ERC-1271 filler-auth check after the rollover slot is recorded.
- **ERC-7484** registry-shaped attester checks — **not** implemented directly by the Settler; the factory performs this on the rolloverContract's behalf during `executeIntentHooks`. See `factory.md`.
- **ERC-20** via OZ `SafeERC20` for srcCST, dstCST, premium movements (`src/BaseSettler.sol`).

Inbound callers (informational; cross-ref `factory.md`, `fillers.md`):
relayers / openers call `open` / `openFor`; filler EOAs and contracts call
`fill`; permissionless keepers call `reclaim` / `markExpired`; users (or
their relayers carrying an EIP-712 cancel signature) call `cancel`.

## Tests

| Suite | Path | Coverage focus |
|-------|------|----------------|
| Settler unit tests | `test/unit/settler/` | Per-entrypoint unit coverage (open / openFor / fill ROLLOVER / fill PREMIUM / reclaim / markExpired / cancel). |
| Settler internal-fn harnesses | `test/harnesses/` | Direct exercising of `_validateOrderCommon`, `isHardTerminal` / `blocksRollover` (`src/types/SettlerTypes.sol`), `_orderDigestMemory`, and `_recordRolloverAccountingForMode`. |
| Invariant-tag tests | `test/integration/` | Regression coverage tied to invariants M-08, M-11, M-29 and the F-NN protocol-feature labels. |
| Invariant suites | `test/invariant/` | Handler-based property suites for BS-ST-20, INV-NEW-POLARITY-*, INV-DSTCST-FLOOR, M-08, F-PUSH, INV-DEFAULTER-RECOUP, N-INV-PARTIAL-RESIDUAL-RECONCILES-TO-TOTAL, N-INV-FILLER-SETTLED-STICKY. Invariant ledger gate: `scripts/ci/check-invariant-ledger.py`. |
| Cross-unit integration | `test/integration/` | Settler ↔ Factory ↔ RolloverContract fill flows. |
| Filler-side tests | `test/unit/filler/` | Construct `fillerData` and exercise `Settler.fill` end-to-end for in-scope `BaseFiller`; `EvcRolloverAdapter` tests are adapter context only unless explicitly re-added in `SCOPE.md`. |
