# Cork Rollover — Audit Glossary

> _Supplementary protocol reference. The canonical bundle for AI auditors is [`docs/agent-context/`](../agent-context/README.md). Code in `src/` is the source of truth when docs disagree._

This glossary covers Cork-Rollover-specific terms — protocol-level vocabulary
that appears in source, NatSpec, the invariant ledger, and the `docs/spec/`
corpus. Cork-wide terms (cPT, cST, market mode) live in upstream Cork protocol
docs and are not duplicated here.

Scope note: `src/BaseFiller.sol` is in scope. `src/EvcRolloverAdapter.sol` is
adapter/integration context only and is out of audit scope unless explicitly
re-added in `SCOPE.md`.

Each term entry carries:

- a 1–3 sentence definition,
- a primary code site (`file:line`) verified against the spec pin,
- cross-references to other glossary entries,
- cross-references to invariant IDs from
  [`docs/INVARIANTS.md`](../INVARIANTS.md) where applicable.

---

### `allowPartialFills`

`OrderData` flag selected by the cPT holder at sign time. `true` routes the order
through the per-filler partial-fill state machine (per-filler escrow,
per-filler settle, per-filler `Closing` semantics); `false` selects exact-fill
(single-filler, order-level FSM). Polarity is read once at fill entry and
isolates storage into disjoint partial/exact maps.

**Primary code site:** `src/types/RolloverTypes.sol:148`
**Related terms:** `allowUnderfill`, `OrderData`, `OrderStatus`, `isPartial`,
`fill`, `Closing`
**Related invariants:** `INV-NEW-POLARITY-GATE`, `INV-NEW-POLARITY-ISOLATION`,
`BS-FN-045`, `BS-ST-20`

### `allowUnderfill`

`OrderData` flag permitting the rolloverContract to consume
less than `ctx.fillAmount` srcCST during a ROLLOVER leg, returning the
leftover srcCST to the Settler. When `false`, any underfill reverts at the
rolloverContract boundary.

**Primary code site:** `src/types/RolloverTypes.sol:149`
**Related terms:** `allowPartialFills`, `OrderData`, `RolloverParams`,
`FillContext`
**Related invariants:** `DSR-1`, `DSR-2`

### `applyTrustConfig`

Permissionless `CorkRolloverContractFactory` entrypoint that ratifies a previously
queued trust-config change after the external per-rolloverContract trust-config
`TimelockController` delay has elapsed. Routes through `relayTrustConfig` into
the rolloverContract's factory-gated `setTrustConfig`, which forwards the queued
`(threshold, attesters)` pair to the ERC-7484 registry via
`IERC7484.trustAttesters`. The factory mirror (`pendingConfig[salt]`,
`lastSalt[rolloverContract]`) is cleared on success.

**Primary code site:** `src/CorkRolloverContractFactory.sol:453`
**Related terms:** `queueFactoryDefaultTrustConfig`, `queueTrustConfig`, `cancelTrustConfig`,
`pendingTrustConfig`, `relayTrustConfig`, `setTrustConfig`,
`TimelockController`, `ERC-7484`, `trustAttesters`
**Related invariants:** `INV-TRUST-CONFIG-DELAY`, `INV-ROLLOVER_CONTRACT-TRUST-ONLY-VIA-FACTORY`, `INV-PENDING-MIRRORS-TIMELOCK`

### `approveSettler`

Factory-admin entrypoint (gated by `SETTLER_APPROVER_ROLE`) that adds an address
to the Settler allowlist. The allowlist is the sole gate on
`CorkRolloverContractFactory.executeIntentHooks`; instant `revokeSettler` is the
operational halt for a compromised approved Settler. Approval rejects zero and
no-code targets but does not verify a Settler interface; repeated approval is
idempotent and still emits `SettlerApproved`.

**Primary code site:** `src/CorkRolloverContractFactory.sol:354`
**Related terms:** `revokeSettler`, `executeIntentHooks`, `Settler`, `originSettler`
**Related invariants:** `INV-SETTLER-APPROVED`

### `BaseFiller`

Reference filler that orchestrates ROLLOVER + PREMIUM legs against
the `EXACT_SETTLER` / `PARTIAL_SETTLER` immutables it is bound to. Builds the 10-tuple `fillerData`, asserts settler
identity (`_assertExpectedSettler`), and emits `PremiumRefunded` when the
post-settlement premium-token balance exceeds the pre-fund snapshot (the
Settler charged less than `job.premiumCap`).

**Primary code site:** `src/BaseFiller.sol:106`
**Related terms:** `FillerJob`, `fillerData`, `premiumCap`, `minDstPerSrc`,
`Settler`; `EvcRolloverAdapter` is adapter context only.
**Related invariants:** `F-PUSH`, `INV-FILLER-AUTH`

### `EXACT_SETTLER_STORAGE_SLOT`

ERC-7201 namespaced storage root for `ExactSettler`
(`cork.rollover.exact-settler`). Exact order status, the reserved former
`orderById` slot, single fill record, residual, and destination maps hang off
this slot via the exact `_s()` accessor.

**Primary code site:** `src/ExactSettler.sol`
**Related terms:** `PARTIAL_SETTLER_STORAGE_SLOT`, `ROLLOVER_CONTRACT_STORAGE_SLOT`,
`FACTORY_STORAGE_SLOT`, `Settler`,

### `PARTIAL_SETTLER_STORAGE_SLOT`

ERC-7201 namespaced storage root for `PartialSettler`
(`cork.rollover.partial-settler`). Partial order status, the reserved former
`orderById` slot, per-filler records, residuals, participant count, and
settlement latches hang off this slot via the partial `_s()` accessor.

**Primary code site:** `src/PartialSettler.sol`
**Related terms:** `EXACT_SETTLER_STORAGE_SLOT`, `ROLLOVER_CONTRACT_STORAGE_SLOT`,
`FACTORY_STORAGE_SLOT`, `Settler`,
`ERC-7201`

### `cancel`

cPT-holder-signed Settler entrypoint that closes a non-terminal order. Exact-mode
with no fills → `Cancelled`; partial-mode with live dstCST escrow →
intermediate `Closing` state pending reclaim/refund; partial-mode without live escrow →
`Cancelled` directly.

**Primary code site:** `src/BaseSettler.sol:352`
**Related terms:** `markExpired`, `reclaim`, `OrderStatus`, `Closing`,
`allowPartialFills`
**Related invariants:** `BS-ST-20`, `INV-PAUSE-GATES-ALL-ENTRYPOINTS`

### `RolloverIntent`

EIP-712 struct (typehash `ROLLOVER_INTENT_TYPEHASH`) bundling four hook
lists — `preRolloverHooks`, `midRolloverHooks`, `postRolloverHooks`, and
`premiumHooks` — plus deadline and ERC-7484 attester binding. Its zero-digest
hash is committed by cPT-holder-signed `OrderData.rolloverIntentHash`; every RolloverContract
dispatch verifies the cPT-holder signature over the order digest.

**Primary code site:** `src/types/RolloverTypes.sol:76`
**Related terms:** `executeIntentHooks`, `HookPhase`, `RolloverParams`,
`rolloverIntentHash`, `premiumHooks`, `MODULE_TYPE_*_ROLLOVER_HOOK`
**Related invariants:** `INV-CPT-CONTAINED`, `INV-DST-FLOOR`, `INV-5`

### `rolloverIntentHash`

EIP-712 hash of a `RolloverIntent` with the order-digest field zeroed; serves
as the cPT-holder-signed hook commitment inside `OrderData`. Pins the
canonical hook list for the order — but is NOT a
trust-config snapshot (live attester revocation still wins via P-09).

**Primary code site:** `src/types/RolloverTypes.sol` (`OrderData.rolloverIntentHash`) /
`src/CorkRolloverContract.sol` (`_validateIntentHashBinding`)
**Related terms:** `RolloverIntent`, `executeIntentHooks`,
`pendingTrustConfig`

### `rolloverContractSnapshot`

RolloverContract-level lens view returning a typed `RolloverContractTrustSnapshot` (ERC-7484
registry + live trust config only). Pending/queued trust config moved to
the factory in PR2 — read it via `ICorkRolloverContractFactory.pendingTrustConfig(rolloverContract)`.
Callers SHOULD prefer the factory route `IRolloverContractLens.rolloverContractConfig(rolloverContract)`;
the direct view is retained for internal use.

**Primary code site:** `src/CorkRolloverContract.sol:397-406`
**Related terms:** `rolloverContractConfig`, `orderState`, `pendingTrustConfig`,
`IRolloverContractLens`
**Related invariants:** `INV-TRUST-CONFIG-DELAY`

### `ROLLOVER_CONTRACT_STORAGE_SLOT`

ERC-7201 namespaced storage root for `CorkRolloverContract`. Holds the trust-config
live pair, rollover hook-nonces bitmap, `premiumFiredFor`, and the `rolled[]`
accumulator.

**Primary code site:** `src/CorkRolloverContract.sol:165`
**Related terms:** `EXACT_SETTLER_STORAGE_SLOT`, `PARTIAL_SETTLER_STORAGE_SLOT`,
`FACTORY_STORAGE_SLOT`, `CorkRolloverContract`, `ERC-7201`

### `Closing`

Sixth `OrderStatus` enum value. Intermediate state for partial-mode orders
that were cancelled or expired while live dstCST escrow remains — gates further
fills while admitting reclaim / refund.

**Primary code site:** `src/types/RolloverTypes.sol:26` (enum value), Settler transitions
at `src/ExactSettler.sol and src/PartialSettler.sol` (`cancel`)
**Related terms:** `OrderStatus`, `cancel`, `reclaim`, `markExpired`,
`allowPartialFills`
**Related invariants:** `BS-ST-20`

### `CorkRolloverContract`

Per-cPT holder CWIA clone that owns the 4-hook `RolloverIntent`, trust-config
time-lock, per-dispatch cPT-holder authorization, `rolled[]` monotone accumulator, and
ERC-7484 attester gate. Calls phoenix `IPoolManager.unwindMint`/`deposit`
during the rollover leg.

**Primary code site:** `src/CorkRolloverContract.sol:1`
**Related terms:** `CorkRolloverContractFactory`, `RolloverIntent`, `executeIntentHooks`,
`IERC7484`, `IPoolManager`, `IPoolShare`
**Related invariants:** `INV-ROLLOVER_CONTRACT-OWNER-IMMUTABLE`, `INV-CPT-CONTAINED`,
`INV-DST-FLOOR`, `INV-5`, `DSR-1`, `DSR-2`, `INV-PARAMS-SETTLER-PIN`

### `CorkRolloverContractFactory`

CWIA clone factory; the dispatch root for `executeIntentHooks` calls coming
from approved Settlers. Holds the Settler allowlist, immutable trust
defaults, transient `_originatingSettler` latch, and `IRolloverContractLens` views.

**Primary code site:** `src/CorkRolloverContractFactory.sol:1`
**Related terms:** `CorkRolloverContract`, `deployRolloverContract`, `approveSettler`,
`revokeSettler`, `executeIntentHooks`, `originSettler`, `IRolloverContractLens`
**Related invariants:** `INV-SETTLER-APPROVED`,
`INV-DEFAULT-ATTESTERS-FACTORY-SEEDED`,
`INV-PAUSE-GATES-ALL-ENTRYPOINTS`

### `CWIA` (Clone-With-Immutable-Args)

Deployment pattern: cPT holder (cPT holder address), factory pointer, and ERC-7484
registry address live in the 60-byte clone trailer (`owner ‖ factory ‖
erc7484Registry`) and are read via `_cwiaImmutableArgs`. No owner-transfer
primitive — cPT holdership is immutable for the lifetime of the clone.

**Primary code site:** `src/CorkRolloverContractFactory.sol:296`
(`Clones.cloneDeterministicWithImmutableArgs`)
**Related terms:** `deployRolloverContract`, `CorkRolloverContract`, `Settler`
**Related invariants:** `INV-ROLLOVER_CONTRACT-OWNER-IMMUTABLE`

### `deployRolloverContract`

Permissionless factory entrypoint that mints a new CWIA `CorkRolloverContract` clone,
seeds the factory's immutable trust defaults via the clone's `initialize`,
and registers `(owner, rolloverContract)` in the deployed-rolloverContract map.
The address is predicted by `predictRolloverContractOf(owner)` using the same
CREATE2 deployer, implementation, owner-derived salt, and CWIA args. Identical
cross-chain predictions require identical factory, implementation, owner, and registry.

**Primary code site:** `src/CorkRolloverContractFactory.sol:283`
**Related terms:** `CWIA`, `CorkRolloverContract`, `initialize`, `defaultAttesters`,
`DEFAULT_TRUST_THRESHOLD`
**Related invariants:** `INV-DEFAULT-ATTESTERS-FACTORY-SEEDED`

### `DSR-1` / `DSR-2`

"Delta is source of truth" pair: the rolloverContract measures dstCST and srcCST
movement via `balanceOf` deltas across the rollover bracket — never trusts
the value returned by `IPoolManager.unwindMint` / `deposit`. Defends against
pool-return manipulation.

**Primary code site:** `src/CorkRolloverContract.sol:928` (`_finalizeRolloverLeg`)
**Related terms:** `IPoolManager`, `unwindMint`, `_handlePhaseRollover`,
`allowUnderfill`
**Related invariants:** `DSR-1`, `DSR-2`

### `EvcRolloverAdapter`

Adapter/integration context only; out of audit scope unless explicitly
re-added in `SCOPE.md`. Filler adapter that integrates Euler EVC. Gates calls behind `_gateEvc`
(`getCurrentOnBehalfOfAccount` check + controller-enabled + on-behalf-of),
then routes through `execute` / `executePartial` into `_runSettlementCommon`.

**Primary code site:** `src/EvcRolloverAdapter.sol:632`
**Related terms:** `BaseFiller`, `EvcRolloverJob`, `Settler`, `fillerData`,
`fillerAuthSig`; adapter context only.
**Related invariants:** `F-PUSH`, `INV-FILLER-AUTH`

### `exclusiveFiller`

`OrderData` field naming a single filler authorised to consume the order.
When non-zero, `Settler.fill` requires either a direct call from
`exclusiveFiller` OR a `FillerAuth(orderDigest, destination, subFiller)` EIP-712
signature delivered in the 10-tuple `fillerData`. Destination + subFiller binding -
executor binding is intentionally omitted.

**Primary code site:** `src/types/RolloverTypes.sol:134` (struct), enforcement at
`src/libraries/LibFillerAuth.sol:91`
**Related terms:** `FillerAuth`, `fillerAuthSig`, `fillerData`, `OrderData`,
`LibFillerAuth`
**Related invariants:** `INV-FILLER-AUTH`

### `executeIntentHooks`

Two-tier entrypoint: factory's variant
(`src/CorkRolloverContractFactory.sol:310`) checks the Settler allowlist and
transient-latch dispatch; rolloverContract's variant (`src/CorkRolloverContract.sol:285`) is
`onlyFactory` and runs phase dispatch (`_handlePhaseRollover` /
`_handlePhasePremium`).

**Primary code site:** `src/CorkRolloverContract.sol:285`
**Related terms:** `CorkRolloverContract`, `CorkRolloverContractFactory`, `HookPhase`,
`originSettler`, `rolloverIntentHash`
**Related invariants:** `INV-SETTLER-APPROVED`, `INV-PARAMS-SETTLER-PIN`,
`INV-CPT-CONTAINED`, `INV-DST-FLOOR`, `INV-5`

### `FACTORY_STORAGE_SLOT`

ERC-7201 namespaced storage root for `CorkRolloverContractFactory`. Holds the approved
Settler set, deployed-rolloverContract map, transient origin-settler latch, and pending
factory/rolloverContract trust configuration queues.

**Primary code site:** `src/CorkRolloverContractFactory.sol:102`
**Related terms:** `EXACT_SETTLER_STORAGE_SLOT`, `PARTIAL_SETTLER_STORAGE_SLOT`,
`ROLLOVER_CONTRACT_STORAGE_SLOT`, `ERC-7201`

### `fill`

Settler's destination entrypoint. Branches by `HookPhase` →
`_handleRolloverFill` (`src/ExactSettler.sol and src/PartialSettler.sol`) or `_handlePremiumFill`
(`src/ExactSettler.sol and src/PartialSettler.sol`). Writes the fill record (polarity-gated), then
forwards to `CorkRolloverContractFactory.executeIntentHooks`. Sole consumer of the
`FillerAuth` signature.

**Primary code site:** `src/BaseSettler.sol:276`
**Related terms:** `openFor`, `reclaim`, `FillerAuth`, `fillerData`,
`HookPhase`, `isPartial`
**Related invariants:** `INV-NEW-POLARITY-GATE`,
`INV-NEW-POLARITY-ISOLATION`, `INV-FILLER-AUTH`, `F-PUSH`,
`INV-PAUSE-GATES-ALL-ENTRYPOINTS`

### `FillContext`

Struct passed from `Settler.fill` through the factory into the rolloverContract; carries
fill-time scalars (filler address, originSettler, fillAmount, premium,
rolloverIntentHash, orderDigest, etc.). The rolloverContract's preflight enforces
`ctx.originSettler == msg.sender`.

**Primary code site:** `src/types/RolloverTypes.sol:171`
**Related terms:** `fill`, `executeIntentHooks`, `originSettler`,
`rolloverIntentHash`
**Related invariants:** `INV-PARAMS-SETTLER-PIN`

### `FillerAuth`

EIP-712 struct `FillerAuth(bytes32 orderDigest,address destination,bytes32 subFiller)`. An
optional exclusive-filler signature consumed only at `Settler.fill` — never
at `openFor`. Destination + subFiller binding defeats race attacks (the executor
field is deliberately not bound).

**Primary code site:** `src/libraries/LibFillerAuth.sol:67`
(`hashFillerAuth`)
**Related terms:** `exclusiveFiller`, `fillerAuthSig`, `fillerData`,
`LibFillerAuth`, `fill`
**Related invariants:** `INV-FILLER-AUTH`

### `fillerData`

10-tuple ABI-encoded calldata blob passed to `Settler.fill`:
`(phase, fillAmount, premium, destination, premiumFor, intent,
minDstPerSrc, fillerAuthSig, subFiller, cptHolderSig)`. `premiumFor` is only meaningful in PREMIUM:
it is mandatory and must identify the recorded rollover filler being paid for.
The premium payer never controls the settlement destination. ROLLOVER payloads
must set `premiumFor` to zero.
Decoded by `LibFillerAuth.decodePayload`.

**Primary code site:** `src/types/FillerTypes.sol:45` (`FillerPayload`
struct)
**Related terms:** `fill`, `FillerAuth`, `fillerAuthSig`, `minDstPerSrc`,
`BaseFiller`; `EvcRolloverAdapter` is adapter context only.
**Related invariants:** `INV-FILLER-AUTH`, `INV-DSTCST-FLOOR`

### `FillerJob`

Struct consumed by `BaseFiller.execute`. Bundles the Settler target, intent +
cPT-holder signature, fillAmount, premium cap, destination, minDstPerSrc floor, and
optional `fillerAuthSig`.

**Primary code site:** `src/BaseFiller.sol:54`
**Related terms:** `BaseFiller`, `EvcRolloverJob`, `fillerData`, `premiumCap`
**Related invariants:** `F-PUSH`

### `FillerPayload`

Library-side struct representing the decoded 10-tuple `fillerData`. Source
of truth for field naming and order.

**Primary code site:** `src/types/FillerTypes.sol:45`
**Related terms:** `fillerData`, `LibFillerAuth`, `FillerAuth`
**Related invariants:** `INV-FILLER-AUTH`

### `FillerRolloverAccounting` / `FillerSlotAccounting`

Per-filler partial-mode storage row tracking `dstCstProduced`, `srcCstProvided`,
`filledAt`, and `premiumFired` (wrapped by `FillerSlotAccounting` with
`settlementDestination` and the `settled` latch). Exposed via
`Settler.fillerSlotAccountingOf`.

**Primary code site:** `src/types/SettlerTypes.sol:57`
**Related terms:** `OrderData`, `reclaim`, `allowPartialFills`,
`isPartial`
**Related invariants:** `N-INV-FILLER-SETTLED-STICKY`,
`N-INV-PARTIAL-RESIDUAL-RECONCILES-TO-TOTAL`,
`N-INV-ROLLED-MONOTONE-AND-BOUNDED`

### `ExactRolloverAccounting`

Exact-mode (single-filler) fill record. Exposed via `Settler.rolloverAccountingOf`.

**Primary code site:** `src/types/SettlerTypes.sol:42`
**Related terms:** `FillerRolloverAccounting`, `allowPartialFills`, `isPartial`, `fill`,
internal settlement
**Related invariants:** `INV-NEW-POLARITY-ISOLATION`

### `HookPhase`

2-value enum (`ROLLOVER` / `PREMIUM`). Decoded
via `LibHookPhase.from(uint8)`; used by `Settler.fill` to branch into
ROLLOVER vs PREMIUM handlers and by the rolloverContract to dispatch hook lists.

**Primary code site:** `src/types/RolloverTypes.sol:30`
**Related terms:** `RolloverIntent`, `executeIntentHooks`,
`MODULE_TYPE_PRE_ROLLOVER_HOOK`, `MODULE_TYPE_MID_ROLLOVER_HOOK`,
`MODULE_TYPE_POST_ROLLOVER_HOOK`, `MODULE_TYPE_EXECUTOR`, `LibHookPhase`

### `IRolloverContractLens`

Read-side interface implemented by `CorkRolloverContractFactory`. Provides
`orderState`, `premiumFiredFor`, and `rolloverContractConfig` — the
canonical read entrypoints for SDKs and indexers.

**Primary code site:** `src/interfaces/rollover/IRolloverContractLens.sol:1`
**Related terms:** `rolloverContractSnapshot`, `CorkRolloverContractFactory`, `orderState`,
`premiumFiredFor`

### `IERC7484`

Module-attestation registry interface used by `CorkRolloverContract`. `check(addr,
ModuleType)` is called LIVE at every phase against every hook target; the
rolloverContract's own `trustAttesters` forwarding handles cPT holder registration.

**Primary code site:** `src/interfaces/external/erc7484/IERC7484.sol:7`
**Related terms:** `trustAttesters`, `queueFactoryDefaultTrustConfig`, `queueTrustConfig`, `applyTrustConfig`,
`pendingTrustConfig`, `MODULE_TYPE_*`
**Related invariants:** `INV-TRUST-CONFIG-DELAY`,
`INV-DEFAULT-ATTESTERS-FACTORY-SEEDED`

### `IPoolManager`

Cork Phoenix external interface (`market`, `shares`, `unwindMint`,
`deposit`). RolloverContract derives the PoolManager per-call from
`IPoolShare(srcCstToken).poolManager()`; no cached pointer.

**Primary code site:**
`src/interfaces/external/phoenix/IPoolManager.sol:1`
**Related terms:** `IPoolShare`, `unwindMint`, `CorkRolloverContract`
**Related invariants:** `DSR-1`, `DSR-2`, `INV-DST-FLOOR`, `INV-5`

### `IPoolShare`

Cork Phoenix cST ERC20 with `poolManager`, `poolId`, `decimals`, `expiry`.
The Settler preflight uses `expiry()` for the pool-expiry gate
(`src/BaseSettler.sol:805-806`); the rolloverContract preflight uses `poolId()`.

**Primary code site:** `src/interfaces/external/phoenix/IPoolShare.sol:1`
**Related terms:** `IPoolManager`, `RolloverParams`, `INV-CST-IDENTITY`
**Related invariants:** `INV-DST-CST-REACHABLE`

### `isPartial`

Local bool inside `Settler.fill` that snapshots `orderData.allowPartialFills`
once at entry, then routes all subsequent reads/writes through the
polarity-isolated storage maps.

**Primary code site:** `src/ExactSettler.sol and src/PartialSettler.sol`
**Related terms:** `allowPartialFills`, `fill`, `ExactRolloverAccounting`, `FillerRolloverAccounting`
**Related invariants:** `INV-NEW-POLARITY-GATE`,
`INV-NEW-POLARITY-ISOLATION`

### `LibFillerAuth`

Library that decodes the 10-tuple `fillerData`, hashes `FillerAuth`, and
verifies exclusive-filler signatures via OZ `SignatureChecker` (EOA + 1271).

**Primary code site:** `src/libraries/LibFillerAuth.sol:91`
(`isAuthorised`)
**Related terms:** `FillerAuth`, `fillerData`, `FillerPayload`,
`exclusiveFiller`, `fill`
**Related invariants:** `INV-FILLER-AUTH`

### `LibSettlerHashing`

Library that computes EIP-712 hashes for `RolloverParams`, `OrderData`, and
order digests. Calldata and memory variants are both exposed.

**Primary code site:** `src/libraries/LibSettlerHashing.sol:11`
**Related terms:** `RolloverParams`, `OrderData`, `Typehashes`, `openFor`,
`fill`

### `minDstPerSrc`

Filler-supplied mint-rate floor in `fillerData` for ROLLOVER legs. Filler
sets their own risk floor at fill time; passing zero opts out. Closes the
historical hostile cPT-holder-with-zero-minSharesOut vector.

**Primary code site:** `src/types/FillerTypes.sol:58` (`FillerPayload`);
adapter-context analogue at `src/EvcRolloverAdapter.sol:124`
(`EvcRolloverJob` field) is out of audit scope unless explicitly re-added in
`SCOPE.md`.
**Related terms:** `fillerData`, `FillerJob`, `premiumCap`;
`EvcRolloverJob` is adapter context only.
**Related invariants:** `INV-DSTCST-FLOOR`, `M-08`

### `MODULE_TYPE_PRE_ROLLOVER_HOOK` / `MID` / `POST` / `EXECUTOR`

ERC-7484 `ModuleType` constants used by the rolloverContract to gate hook targets per
phase. PRE = `0xc0c0_0001`, MID = `0xc0c0_0002`, POST = `0xc0c0_0003`,
EXECUTOR = `0xc0c0_0004` (used for the PREMIUM phase). Re-checked live every
phase.

**Primary code site:** `src/libraries/Typehashes.sol:45-55`
**Related terms:** `IERC7484`, `RolloverIntent`, `HookPhase`,
`executeIntentHooks`, `trustAttesters`
**Related invariants:** `INV-TRUST-CONFIG-DELAY`

### `openFor`

ERC-7683 origin entrypoint that registers a `GaslessCrossChainOrder`
on-chain. No filler attestation by design — `FillerAuth` is consumed only
at `Settler.fill`. Idempotent w.r.t. an already-opened order.

**Primary code site:** `src/BaseSettler.sol:250`
**Related terms:** `open`, `fill`, `OrderData`, `RolloverParams`,
`GaslessCrossChainOrder`
**Related invariants:** `BS-ST-20`, `INV-PAUSE-GATES-ALL-ENTRYPOINTS`

### `OrderData`

EIP-712 struct (typehash `ORDER_DATA_TYPEHASH`) carrying `rolloverContract`,
`orderSize`, `allowPartialFills`, `allowUnderfill`, `exclusiveFiller`,
`openDeadline`, `fillDeadline`, etc. Signed by the cPT holder. Source of truth for
order-level FSM decisions.

**Primary code site:** `src/types/RolloverTypes.sol:126`
**Related terms:** `RolloverParams`, `RolloverIntent`, `openFor`, `fill`,
`cancel`, `markExpired`, `exclusiveFiller`, `allowPartialFills`, `allowUnderfill`
**Related invariants:** `BS-ST-20`, `INV-NEW-POLARITY-GATE`, `BS-FN-045`

### `orderDigest`

EIP-712 hash of `(OrderData, RolloverParams, Settler-domain)` — the canonical
order identifier carried in events, lens views, and `FillerAuth`.

**Primary code site:** `src/libraries/LibSettlerHashing.sol:74`
**Related terms:** `OrderData`, `RolloverParams`, `LibSettlerHashing`,
`FillerAuth`, `orderStatus`, `orderState`

### `orderState`

Per-order lens view returning a typed `RolloverContractOrderState` (flattens the rolloverContract's
hook-nonces bitmap to `rolloverTerminal` + premium-fired status). Exposed at
both the rolloverContract (`src/CorkRolloverContract.sol:409`) and the factory
(`src/CorkRolloverContractFactory.sol:606`); factory is the canonical SDK route.

**Primary code site:** `src/CorkRolloverContractFactory.sol:606`
**Related terms:** `rolloverContractSnapshot`, `premiumFiredFor`, `IRolloverContractLens`,
`orderStatus`

### `OrderStatus`

Six-value enum: `None`, `Opened`, `Settled`, `Expired`, `Cancelled`,
`Closing`. `Closing` is the intermediate partial-mode terminal. Drives the
FSM in `BS-ST-20`.

**Primary code site:** `src/types/RolloverTypes.sol:20`
**Related terms:** `Closing`, `cancel`, `markExpired`, `reclaim`,
`openFor`, `fill`
**Related invariants:** `BS-ST-20`, `INV-NEW-POLARITY-GATE`,
`INV-NEW-POLARITY-ISOLATION`

### `originSettler`

ERC-7683 term for the Settler that opened/dispatched an order; surfaced as
`FillContext.originSettler` and `CorkRolloverContractFactory._originatingSettler`. The
rolloverContract enforces `orderData.rolloverParams.settler == ctx.originSettler == msg.sender` at the
preflight gate.

**Primary code site:** `src/CorkRolloverContract.sol:520`
(`_validateOrderDataBinding`) / `src/CorkRolloverContract.sol:545` (`_validateFillEnvelope`)
**Related terms:** `executeIntentHooks`, `FillContext`, `Settler`, `RolloverParams`
**Related invariants:** `INV-PARAMS-SETTLER-PIN`, `INV-SETTLER-APPROVED`

### `PAUSER_ROLE` / `UNPAUSER_ROLE`

Split AccessControl roles on `Settler`. Held by separate keys so the recovery
path is independent of the halt path. `pause` and `unpause` are instant.

**Primary code site:** `src/BaseSettler.sol:106` (PAUSER_ROLE) /
`src/BaseSettler.sol:110` (UNPAUSER_ROLE)
**Related terms:** `pause`, `unpause`, `Settler`
**Related invariants:** `INV-PAUSE-GATES-ALL-ENTRYPOINTS`

### `pendingTrustConfig`

`ICorkRolloverContractFactory` view returning `(threshold, attesters, effectiveAt)`
for the Factory-mirrored pending trust-config change on a rolloverContract. `threshold`
and `attesters` come from the factory's `pendingConfig[lastSalt[rolloverContract]]`
mirror; `effectiveAt` comes from live `TimelockController.getTimestamp(opId)`.
The full zero tuple means no Factory pending mirror exists. A nonzero config
with `effectiveAt == 0` means the mirror exists but the timelock op is absent,
done, or unset. Fillers MUST treat any nonzero tuple member as a live
operational signal under cross-phase policy P-09.

**Primary code site:** `src/CorkRolloverContractFactory.sol:648`; declaration at
`src/interfaces/rollover/ICorkRolloverContractFactory.sol:177`
**Related terms:** `queueTrustConfig`, `applyTrustConfig`,
`cancelTrustConfig`, `TimelockController`,
`trustAttesters`
**Related invariants:** `INV-TRUST-CONFIG-DELAY`, `INV-PENDING-MIRRORS-TIMELOCK`

### `premiumCap`

Filler-side ceiling on the PREMIUM-leg cost in `FillerJob` / `EvcRolloverJob`.
If the rolloverContract's `dstCstProduced`-derived `requiredPremium` is strictly less
than `premiumCap`, the filler refunds the difference and emits
`PremiumRefunded`.

**Primary code site:** `src/BaseFiller.sol:54` (FillerJob field), refund
emit site in `BaseFiller`
**Related terms:** `BaseFiller`, `FillerJob`, `fillerData`,
`PremiumRefunded`; `EvcRolloverAdapter` is adapter context only.
**Related invariants:** `F-PUSH`

### `premiumFiredFor`

Per-`(orderDigest, filler, subFiller)` boolean latch set by the rolloverContract's `_handlePhasePremium`
success path. Local rolloverContract replay protection only — prevents same-tx re-entry
into the rolloverContract premium frame. NOT the protocol-wide M-11 gate: that lives
**Settler-side** (`rec.premiumFired` partial / `exactRec.premiumFired` exact)
and commits/reverts atomically with the PR87 atomic-fill frame. Keyed by
`(orderDigest, filler, subFiller)`. Exposed read-only at the rolloverContract and via
factory lens `premiumFiredFor(rolloverContract, orderDigest, filler, subFiller)`.

**Primary code site:** `CorkRolloverContract.premiumFiredFor` / `CorkRolloverContractFactory.premiumFiredFor` (lens)
**Related terms:** `HookPhase`, `executeIntentHooks`, `orderState`,
`IRolloverContractLens`, `PremiumFired`

### `PremiumFired`

RolloverContract event emitted at the end of a successful `_handlePhasePremium`:
`(orderDigest, filler, subFiller, premium)` with **three indexed topics** including
`subFiller`. The emitted `subFiller` is always resolved `ctx.subFiller` from the
atomic frame (direct-EOA wire-zero → self-key per `LibFillerAuth`).

**Primary code site:** `CorkRolloverContract.PremiumFired` / `CorkRolloverContract._handlePhasePremium`
**Related terms:** `premiumFiredFor`, `FillContext`, `LibFillerAuth`
**Tests:** `test/unit/rolloverContract/PremiumFiredEvent.t.sol`

### `premiumHooks`

`RolloverIntent` hook list executed during the PREMIUM phase. Module-type
gated by `MODULE_TYPE_EXECUTOR`. RolloverContract premium-routing discretion is
explicitly **non-invariant** (see "RolloverContract premium routing discretion" in the
ledger).

**Primary code site:** `src/types/RolloverTypes.sol:76` (RolloverIntent definition);
dispatch in `CorkRolloverContract._handlePhasePremium`
**Related terms:** `RolloverIntent`, `HookPhase`, `MODULE_TYPE_EXECUTOR`,
`PremiumFired`, `premiumFiredFor`

### `queueFactoryDefaultTrustConfig`

cPT-holder-only (rolloverContract `owner`) `CorkRolloverContractFactory` entrypoint that snapshots the
factory's current default trust threshold and attester list, then queues that
config on the external per-rolloverContract trust-config `TimelockController`. It shares
the same delay, cancel, pending mirror, and permissionless apply lifecycle as
`queueTrustConfig`. It does not auto-follow future `setDefaults` changes.

**Primary code site:** `src/CorkRolloverContractFactory.sol`
**Related terms:** `queueTrustConfig`, `setDefaults`, `applyTrustConfig`,
`pendingTrustConfig`

### `queueTrustConfig`

cPT-holder-only (rolloverContract `owner`) `CorkRolloverContractFactory` entrypoint that schedules a custom
`(rolloverContract, threshold, attesters)` trust-config change on the external per-rolloverContract
trust-config `TimelockController` to take effect after its configured `minDelay`.
Re-queueing cancels any prior pending op for the same rolloverContract and resets
the trust-config timelock clock. The rolloverContract's own surface accepts trust-config writes only via
the factory-gated `setTrustConfig` (see `INV-ROLLOVER_CONTRACT-TRUST-ONLY-VIA-FACTORY`).

**Primary code site:** `src/CorkRolloverContractFactory.sol:418`
(`_scheduleTrustConfig` at `:705`)
**Related terms:** `applyTrustConfig`, `cancelTrustConfig`,
`pendingTrustConfig`, `relayTrustConfig`, `setTrustConfig`,
`TimelockController`, `IERC7484`, `trustAttesters`
**Related invariants:** `INV-TRUST-CONFIG-DELAY`,
`INV-ROLLOVER_CONTRACT-TRUST-ONLY-VIA-FACTORY`, `INV-PENDING-MIRRORS-TIMELOCK`

### `reclaim`

Permissionless Settler entrypoint that recoups a defaulter filler's unpaid
dstCST and routes it to `orderData.rolloverContract` after `fillDeadline`. PR #N
(`feature_f01_unopened_reclaim`) extends the status guard to admit
`OrderStatus.None` for direct-fill-from-None integrations.

**Primary code site:** `src/BaseSettler.sol:296`
**Related terms:** `defaulter`, `internal settlement`, `markExpired`, `OrderStatus`, `cancel`
**Related invariants:** `INV-DEFAULTER-RECOUP`, `INV-DST-CST-REACHABLE`

### `markExpired`

Permissionless expiry entrypoint, callable after `fillDeadline`
`block.timestamp > order.fillDeadline`. Routes leftover srcCST back to the
cPT holder.

**Primary code site:** `src/BaseSettler.sol:332`
**Related terms:** `cancel`, `reclaim`, `internal settlement`, `OrderStatus`,
`fillDeadline`
**Related invariants:** `BS-ST-20`, `INV-PAUSE-GATES-ALL-ENTRYPOINTS`

### `revokeSettler`

Factory-admin entrypoint (gated by `SETTLER_REVOKER_ROLE`) that removes a
Settler from the allowlist. Instant — this is the operational halt for a
compromised approved Settler. Version migration is atomic
`approve(v2) + revoke(v1)`.

**Primary code site:** `src/CorkRolloverContractFactory.sol:368`
**Related terms:** `approveSettler`, `executeIntentHooks`, `pause`
**Related invariants:** `INV-SETTLER-APPROVED`

### `RolloverParams`

EIP-712 struct (typehash `ROLLOVER_PARAMS_TYPEHASH`) carrying
`srcCstToken`, `dstCstToken`, `minCaReceived`, `minSharesOut`, `srcPoolId`,
`dstPoolId`, `settler`. Co-signed with
`OrderData` to form the order digest.

**Primary code site:** `src/types/RolloverTypes.sol:57`
**Related terms:** `OrderData`, `LibSettlerHashing`, `originSettler`,
`IPoolShare`, `INV-CST-IDENTITY`
**Related invariants:** `INV-PARAMS-SETTLER-PIN`, `INV-DST-CST-REACHABLE`

### `Settler`

The sole state-mutating ERC-7683 origin+destination settler. Holds the order
FSM, per-filler escrow, EIP-712 + ERC-1271 signature verification, and OZ
`Pausable + AccessControl` halt rig.

**Primary code site:** `src/ExactSettler.sol and src/PartialSettler.sol`
**Related terms:** `CorkRolloverContract`, `CorkRolloverContractFactory`, `BaseFiller`,
`open`, `openFor`, `fill`, `reclaim`,
`markExpired`, `cancel`, `pause`, `unpause`
**Related invariants:** `BS-ST-20`, `INV-NEW-POLARITY-GATE`,
`INV-NEW-POLARITY-ISOLATION`, `INV-FILLER-AUTH`, `INV-DEFAULTER-RECOUP`,
`INV-PAUSE-GATES-ALL-ENTRYPOINTS`, `F-0024`, `F-PUSH`

### internal settlement

Settler internal payout step. Atomic fill and cPT-holder-opt-in async PREMIUM both
settle in-frame after premium succeeds; there is no public `settle(...)`
selector.

**Primary code site:** `src/ExactSettler.sol and src/PartialSettler.sol`
**Related terms:** `fill`, `reclaim`, `markExpired`, `cancel`, `FillerRolloverAccounting`,
`ExactRolloverAccounting`, `allowPartialFills`, `isPartial`
**Related invariants:** `N-INV-FILLER-SETTLED-STICKY`,
`N-INV-PARTIAL-RESIDUAL-RECONCILES-TO-TOTAL`, `BS-ST-20`

### `srcCstToken` / `dstCstToken`

The two phoenix `PoolShare` tokens involved in a rollover — source-side
(unwound via `IPoolManager.unwindMint`) and destination-side (minted via
`IPoolManager.deposit`). Their identities are pinned by `RolloverParams`
plus `INV-CST-IDENTITY`.

**Primary code site:** `src/types/RolloverTypes.sol:57` (`RolloverParams` field
declarations)
**Related terms:** `RolloverParams`, `IPoolShare`, `IPoolManager`,
`unwindMint`, `allowUnderfill`
**Related invariants:** `INV-DST-FLOOR`, `INV-5`, `INV-DST-CST-REACHABLE`,
`INV-DSTCST-FLOOR`

### `trustAttesters`

ERC-7484 registry write that registers a `(threshold, attesters)` pair for
the caller (the rolloverContract, acting as a smart account). Forwarded by the rolloverContract
from `initialize` (defaults) and `setTrustConfig` (factory-only update path,
reached via `CorkRolloverContractFactory.applyTrustConfig` → `TimelockController.execute`
→ `relayTrustConfig`).

**Primary code site:** `src/interfaces/external/erc7484/IERC7484.sol:30`
**Related terms:** `IERC7484`, `queueTrustConfig`, `applyTrustConfig`,
`defaultAttesters`, `pendingTrustConfig`
**Related invariants:** `INV-TRUST-CONFIG-DELAY`,
`INV-DEFAULT-ATTESTERS-FACTORY-SEEDED`

### Trust-config timelock delay

Externally configured `minDelay` of the constructor-supplied per-rolloverContract
trust-config `TimelockController` that gates `CorkRolloverContractFactory.applyTrustConfig`.
The single load-bearing operational delay in the protocol; backs
`INV-TRUST-CONFIG-DELAY`.

**Primary code site:** `CorkRolloverContractFactory.trustConfigTimelock`
**Related terms:** `queueTrustConfig`, `applyTrustConfig`,
`cancelTrustConfig`, `pendingTrustConfig`, `TimelockController`
**Related invariants:** `INV-TRUST-CONFIG-DELAY`

### `Typehashes`

Library of EIP-712 typehash constants: `ORDER_DATA_TYPEHASH`,
`ROLLOVER_PARAMS_TYPEHASH`, `FILLER_AUTH_TYPEHASH`, `ROLLOVER_INTENT_TYPEHASH`,
`OUTPUT_TYPEHASH`, `CANCEL_ORDER_TYPEHASH`, `EIP712_DOMAIN_TYPEHASH`, plus the
`MODULE_TYPE_*` constants.

**Primary code site:** `src/libraries/Typehashes.sol:1`
**Related terms:** `OrderData`, `RolloverParams`, `RolloverIntent`,
`FillerAuth`, `LibSettlerHashing`, `MODULE_TYPE_PRE_ROLLOVER_HOOK`

### `unwindMint`

Phoenix `IPoolManager` call used by the rolloverContract to convert srcCST into the
unwound underlying during the mid-rollover bracket. Its return value is
**not** trusted — `DSR-1` mandates delta-measurement via `balanceOf`.

**Primary code site:**
`src/interfaces/external/phoenix/IPoolManager.sol:1`
**Related terms:** `IPoolManager`, `IPoolShare`, `CorkRolloverContract`, `srcCstToken`,
`DSR-1`, `DSR-2`
**Related invariants:** `DSR-1`, `INV-DST-FLOOR`, `INV-5`

### `defaulter`

A filler that completes the destination (ROLLOVER) leg but fails to settle
the PREMIUM leg, stranding unpaid dstCST inside the Settler. The defaulter
class is closed by the permissionless `reclaim` path
(`INV-DEFAULTER-RECOUP`) which routes residuals to `orderData.rolloverContract`.

**Primary code site:** `src/ExactSettler.sol and src/PartialSettler.sol` (`reclaim` — primary
mitigation surface)
**Related terms:** `reclaim`, `internal settlement`, `dstCstToken`, `M-O-1`
**Related invariants:** `INV-DEFAULTER-RECOUP`, `INV-DST-CST-REACHABLE`

### `whenNotPaused`

OZ `Pausable` modifier applied to every Settler state-changing entrypoint
(`open`, `openFor`, `fill`, `reclaim`, `markExpired`, `cancel`). The
backbone of `INV-PAUSE-GATES-ALL-ENTRYPOINTS`.

**Primary code site:** `src/BaseSettler.sol:244` (first applied site, `open`)
**Related terms:** `pause`, `unpause`, `PAUSER_ROLE`, `UNPAUSER_ROLE`
**Related invariants:** `INV-PAUSE-GATES-ALL-ENTRYPOINTS`

### `withdraw`

`CorkRolloverContract` owner-only entrypoint that moves an arbitrary ERC20 balance
out of the rolloverContract. Bracketed by `nonReentrant onlyOwner`; the cPT holder retains
full custody of rolloverContract-held assets between rollover brackets.

**Primary code site:** `src/CorkRolloverContract.sol:315`
**Related terms:** `CorkRolloverContract`, `CWIA`
**Related invariants:** `INV-ROLLOVER_CONTRACT-OWNER-IMMUTABLE`

---

*Code in `src/` is the source of truth when this doc disagrees.*
