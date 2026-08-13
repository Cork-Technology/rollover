# Cork Rollover Invariants

This ledger consolidates every `@custom:invariant` mnemonic referenced in `src/`
plus the named invariants the source NatSpec calls out in body prose. Each entry:

  1. Statement — the invariant in human-readable form.
  2. Throw site — the code that enforces it (or `structural` when the property
     is a code-shape invariant rather than a runtime check).
  3. Tests — the unit test(s) that exercise the path.

`src/` NatSpec keeps codes as mnemonics, ALWAYS paired with a one-line
human-readable explanation on the same line. Bare `@custom:invariant CODE`
without an inline gloss is forbidden by the lintspec strict run.

## Filler / Settler invariants

### BS-ST-20

- **Statement:** `orderStatus[orderId]` only transitions on the canonical
  state-machine paths. Open paths (`open` / `openFor`) require the prior status
  to be `None`. ERC-7683 atomic `fill(...)` can admit either exact or partial
  orders from `None` when the envelope carries a valid cPT-holder signature, and can
  fill already-`Opened` orders until `fillDeadline`. Atomic fills perform
  admit → rollover → premium → settle in one frame; expiry admits only
  `Opened` / `Closing` status, while cancel requires non-terminal,
  non-`Closing` status.
- **Throw site:** `Settler.open`, `Settler.openFor`, `Settler.fill`,
  `Settler.markExpired`, `Settler.cancel` — each gated by
  `Settler__OrderInTerminalState`, `Settler__OrderNotExpirable`, or
  polarity-equivalent revert.
- **Tests:** `test/unit/rollover-contract/CorkRolloverContractTerminalBit.t.sol`,
  `test/integration/lifecycle/CancelOrderTypehashStability.t.sol`,
  `test/unit/settler/PartialFillFinality.t.sol`,
  `test/unit/settler/SettlerStrengthened.t.sol`.

### INV-NEW-POLARITY-GATE

- **Statement:** `bool isPartial = orderData.allowPartialFills` is read once at
  fill entry, BEFORE any fill-record state write. The rest of `fill` commits to
  one storage layout for the duration of the call.
- **Throw site:** structural — `Settler.fill` reads `isPartial` once and
  branches on it for every subsequent write.
- **Tests:** `test/integration/lifecycle/DirectFillValidation.t.sol`,
  `test/integration/settler/PartialSubFillerKeying.t.sol`,
  `test/unit/settler/AtomicFill.t.sol`.

### INV-NEW-POLARITY-ISOLATION

- **Statement:** Partial-mode and exact-mode write to disjoint storage slots.
  Partial writes `fillerRollovers`, `totalDstCstEscrowed`, `totalSrcCstConsumed`,
  `participantCount`, `fillerDstCstResidual`. Exact writes `exactFill`,
  `dstCstResidual`. Neither reads or writes the other's slots.
- **Throw site:** structural — partial-mode and exact-mode
  `_recordRolloverAccountingForMode` keep their writes disjoint by construction.
- **Tests:** `test/integration/rollover/AllowUnderfill.t.sol`,
  `test/unit/settler/PartialFillRecordFields.t.sol`.

### INV-DSTCST-FLOOR

- **Statement:** Filler-supplied `minDstPerSrc` (1e18-scaled, calldata-only)
  enforces `dstProduced >= floor(srcConsumed × minDstPerSrc / 1e18)` after the
  rollover hooks settle. `0` opts out (status quo behaviour). Floor rounding
  follows the phoenix `MathHelper` convention for filler-receives amounts
  (protocol-conservative side of the inequality). Per-fill drift bounded at
  1 wei dstCST in the filler's favour when the product is not divisible by
  1e18. Sister invariant `M-08` uses Ceil on the cPT-holder-protective side.
- **Throw site:** `Settler.fill` ROLLOVER branch reverts
  `Settler__InsufficientMintRate(required, actual)` when the floor is breached.
  Source form is `Math.mulDiv(srcConsumed, payload.minDstPerSrc, 1e18,
  Math.Rounding.Floor)` (explicit 4-arg annotation; Floor is the OZ default).
- **Tests:** `test/integration/rollover/FillerMintFloor.t.sol`,
  `test/integration/settler/InvDstCstFloorRounding.t.sol`,
  `test/invariant/failOnRevert/DstCstFloor.t.sol`,
  `test/invariant/continueOnRevert/DstCstFloor.t.sol`.

### INV-ROLLOVER-SRC-DELTA-FLOOR

- **Statement:** `BaseSettler._executeRolloverHooksAndVerifyDelivery` enforces a relaxed parity
  `reportedSrcLeftover <= fillAmount` before refund/accounting and
  `srcDelta >= reportedSrcLeftover` post-leg. When `srcDelta` exceeds the
  rolloverContract-reported leftover, the excess remains direct Settler token balance,
  is ignored by fill accounting, and may be rescued through `recoverToken`
  because srcCST has no tracked dstCST liability. Genuine shortfalls and
  impossible over-reports still revert. The `srcBefore` snapshot semantics
  prevent pre-existing dust from corrupting subsequent fills on the same token.
- **Throw site:** `BaseSettler._executeRolloverHooksAndVerifyDelivery` reverts
  `Settler__SrcLeftoverExceedsFillAmount(reported, fillAmount)` when the
  reported leftover exceeds the filler-supplied amount, and
  `Settler__SrcLeftoverDeliveryShortfall(reported, delivered)` when a genuine
  shortfall is observed.
- **Tests:** `test/integration/rollover/SrcDeltaDonationTolerance.t.sol`,
  `test/integration/rollover/RolloverSrcLeftoverAccounting.t.sol`,
  `test/integration/rollover/SrcCstSurplusAccounting.t.sol`,
  `test/invariant/failOnRevert/RolloverSrcDeltaFloor.t.sol`,
  `test/invariant/continueOnRevert/RolloverSrcDeltaFloor.t.sol`.

### INV-DSTCST-LIABILITY-BACKED

- **Statement:** `BaseSettler._executeRolloverHooksAndVerifyDelivery` enforces
  `delivered >= reportedDstProduced` post-leg (shortfalls revert via
  `Settler__DstProducedNotDelivered`). For each successful ROLLOVER leg,
  `dstCstLiability[dstCstToken]` increases by `reportedDstProduced`; it
  decreases only when owed dstCST actually leaves through settlement or
  reclaim. Generic token rescue computes recoverable balance as
  `IERC20(token).balanceOf(settler) - dstCstLiability[token]` and reverts if
  balance is below liability. Fill records, premium floors, and
  filler/destination proceeds use only `reportedDstProduced`; direct donations
  or overdelivery above liability are not auto-credited to the filler. The
  `settlerDstInitial` snapshot excludes pre-existing Settler dust from in-call
  production attribution. A backed high `reportedDstProduced` is credited as
  real production and may raise the required premium; the filler-supplied
  premium cap, not `minDstPerSrc`, is the upper-bound guard against forced
  premium payment.
- **Throw site:** `BaseSettler._executeRolloverHooksAndVerifyDelivery` reverts
  `Settler__DstProducedNotDelivered(reported, delivered)` when a genuine
  shortfall is observed; `recoverableTokenBalance` / `recoverToken` revert
  `Settler__UnderfundedDstCstLiability` when backing is already insufficient
  and `Settler__InsufficientRecoverableBalance` when rescue exceeds excess.
- **Tests:** `test/integration/rollover/DstCstSurplusAccounting.t.sol`,
  `test/integration/settler/AsyncPremiumOptIn.t.sol`,
  `test/unit/settler/DstIntegrityAndDocs.t.sol`.

### INV-SRC-CST-PREDEPOSITED

- **Statement:** srcCST flows directly from the filler to `orderData.rolloverContract`
  via `safeTransferFrom(msg.sender, orderData.rolloverContract, fillAmount)`; the
  Settler holds zero srcCST from this fill at any observable boundary. The
  downstream `srcDelta = balanceOf(Settler) - srcBefore` check measures only
  the rolloverContract's refund of unconsumed srcCST.
- **Throw site:** structural — `BaseSettler._executeRolloverHooksAndVerifyDelivery`
  transfer call.
- **Tests:** `test/integration/settler/SettlerIntermediaryRoundTripElimination.t.sol`.

### M-08

- **Statement:** Premium obligation is `Ceil(dstCstProduced × minPremiumPerShare / 1e18)`.
  Ceil-divide rounds toward the protocol so the filler's obligation rounds up,
  never down.
- **Throw site:** Atomic `Settler.fill(...)` computes the required premium
  immediately after the rollover leg, checks the submitted cap with
  `Settler__PremiumExceedsCap(cap, required)`, pins
  `premiumPayload.premium = requiredPremium`, and then `_handlePremiumFill`
  verifies measured premium-token delivery with `Settler__PremiumDeliveryMismatch`.
  There is no supported out-of-frame premium payment path.
- **Tests:** `test/unit/filler/BaseFillerExactPremium.t.sol`,
  `test/integration/premium/MinPremiumPerShareFloor.t.sol`,
  `test/invariant/failOnRevert/MinPremiumFloor.t.sol`,
  `test/invariant/continueOnRevert/MinPremiumFloor.t.sol`.

### M-11

- **Statement:** Premium may fire at most once per recorded rollover subject
  (the exact order record in exact mode, or the `(orderDigest, filler,
  subFiller)` slot in partial mode). Replay is blocked **Settler-side** by
  the per-record `premiumFired` bit (`rec.premiumFired` in partial mode,
  `exactRec.premiumFired` in exact mode), which is the authoritative
  protocol-wide replay gate. `_handlePremiumFill` sets the latch before the
  premium transfer and factory dispatch, but strict-revert semantics
  mean any premium transfer or premium hook failure reverts the current
  transaction and unwinds the latch. The rolloverContract-side mapping
  `CorkRolloverContract.premiumFiredFor[orderDigest][filler][subFiller]` remains local rolloverContract
  replay protection for successful premium hook execution; there is no
  supported post-revert Settler/rolloverContract latch divergence. The factory holds a
  transient `_originatingSettler` slot — active-dispatch provenance latch
  (mirrors `msg.sender` for rolloverContract `originatingSettler()` reads during the
  factory-to-rolloverContract call; cleared when the dispatch returns; revert rolls back) and is NOT a per-rolloverContract premium-filler mapping. No transient `premiumFiller` map exists at the
  factory, and there is no `CorkRolloverContractFactory__PremiumFillerMismatch`
  revert in source.
- **Throw site:** Settler-side: `_handlePremiumFill` rejects a second
  fire with `Settler__PremiumAlreadyFired` at the per-record check.
  RolloverContract-side (success-only): `CorkRolloverContract._handlePhasePremium` reverts
  `CorkRolloverContract__PremiumAlreadyFiredForFiller` at
  `src/CorkRolloverContract.sol:690-691`; ledger storage slot `:197`; set at
  `:693`. The factory's settler-latch
  (`src/CorkRolloverContractFactory.sol:123, 492-509`) may revert
  `CorkRolloverContractFactory__SettlerLatchMismatch` if `_originatingSettler` is already set
  to a different `msg.sender` (defensive; nested `executeIntentHooks` is practically
  blocked by `nonReentrant`) — separate concern from premium replay and from sequential
  mixed-settler batches. Factory `executeIntentHooks`
  policy-gate reverts (e.g. `__SettlerNotApproved`,
  [[INV-SETTLER-APPROVED]]) propagate through the strict premium path,
  rolling back the Settler-side latch and the premium pull (payer whole,
  no replay-state leakage).
- **Tests:** `test/integration/premium/PremiumFillerBinding.t.sol`,
  `test/integration/premium/PremiumFactoryRevocationPropagates.t.sol`
  (factory policy-gate revert rolls back the Settler latch),
  `test/unit/settler/SettlerLatchAssertion.t.sol`,
  `test/integration/settler/PartialSubFillerKeying.t.sol`.

### INV-EXACT-SUBFILLER-CANONICAL

- **Statement:** Exact-mode rollover storage is keyed by order, while
  partial-mode rollover storage is keyed by `(filler, subFiller)`. Atomic fill
  binds premium and settlement subject fields from the atomic rollover leg:
  exact mode ignores sub-filler for storage lookup, and partial mode preserves
  the rollover leg's `subFiller` for premium replay and residual settlement.
  The premium inner leg must encode zero sentinel subject fields and cannot
  redirect the subject.
- **Throw site:** `BaseSettler._fillAtomic(...)` overwrites the
  decoded premium payload with `premiumFor = msg.sender` and the rollover
  leg's `subFiller` before loading `PremiumPaymentContext` and calling
  `_payPremiumAndSettle`.
- **Tests:** `test/unit/settler/AtomicFill.t.sol`,
  `test/integration/settler/PartialSubFillerKeying.t.sol`,
  `test/integration/atomic-fill/ThreatModel.t.sol`.

### M-29

- **Statement:** Per-filler partial-mode records the actual srcCST PAID
  (`srcCstProvided`), not the dstCST produced, in the dedicated slot. Prevents
  the off-chain `fillerRolloverOf` view from corrupting any downstream account
  that reads `srcCstProvided` thinking it equals the original push.
- **Throw site:** structural — `_recordRolloverAccountingForMode` writes `srcConsumed`
  into `srcCstProvided`.
- **Tests:** `test/unit/settler/PartialFillRecordFields.t.sol`.

### F-PUSH

- **Statement:** Token movement is push-based: rollover srcCST flows directly
  `filler → rolloverContract`; dstCST and unconsumed srcCST leftover return
  `rolloverContract → Settler`; premium flows directly `premium payer/msg.sender → rolloverContract`.
  The Settler is not a rollover-srcCST or premium custodian. Residual dstCST is
  created by the rollover leg and settled to the recorded destination in the
  same atomic frame.
- **Throw site:** structural — `Settler.fill` and `_executeRolloverHooksAndVerifyDelivery`.
- **Tests:** end-to-end coverage across `test/unit/filler/Fillers.t.sol`,
  `test/unit/settler/SettlerCoverage.t.sol`,
  `test/integration/settler/SettlerIntermediaryRoundTripElimination.t.sol`.

### F-0024

- **Statement:** Settler and Factory `owner()` are Phoenix-style
  ENS/deployment identity surfaces, not protocol permissions. Settler role
  management, pause, unpause, and bounded ERC-20 rescue are role-gated.
  Factory Settler allowlist and defaults operations are gated by dedicated
  operational roles; `DEFAULT_ADMIN_ROLE` administers roles only.
  `recoverToken` requires `RECOVERY_ROLE` and cannot recover token balance
  that backs tracked dstCST liability. Factory and Settler ownership follow
  OZ `Ownable`: `transferOwnership` moves only the owner identity and
  `renounceOwnership` clears only that identity. Settler protocol/admin
  powers remain separate AccessControl roles.
- **Throw site:** structural — protocol management and bounded token rescue are
  role-gated; rescue is bounded by `dstCstLiability`.
- **Tests:** `test/unit/settler/SettlerAuthority.t.sol`,
  `test/admin-trust-rotation/AcdrShimCleanup.t.sol`,
  `test/unit/factory/CorkRolloverContractFactoryStrengthened.t.sol`.

### BS-FN-045

- **Statement:** Polarity-gated terminal accounting. Atomic settlement
  decrements either the per-filler residual (partial) or the order-level
  residual (exact). The dispatch is gated by `orderData.allowPartialFills`; the
  two paths never share storage.
- **Throw site:** structural — `_settlePaidRolloverRecord` branches are selected by
  `orderData.allowPartialFills` inside the atomic fill flow.
- **Tests:** `test/unit/settler/PartialFillFinality.t.sol`,
  `test/integration/lifecycle/DirectPreOpenPartialMetadata.t.sol`.

### INV-NO-ASYNC-RESIDUAL-RECOUP

- **Statement:** For orders with `premiumPaymentMode = 0`
  (`PREMIUM_PAYMENT_MODE_ATOMIC_ONLY`), atomic `fill(ATOMIC_TAG)` is
  all-or-nothing: every successful fill admits, rollovers, pays premium, and
  settles in one frame. There is no async rollover-only, premium-only,
  settle-only, or reclaim path for these orders. Premium hook failure reverts
  the same frame and unwinds rollover records, premium latch state, and token
  movement. Phase-tagged `fill` payloads revert on mode `0` orders.
- **Throw site:** structural — `BaseSettler.fill` dispatches only
  `LibAtomicFill.ATOMIC_TAG` for mode `0`; `_handlePhaseFill` gates mode `1`
  paths.
- **Tests:** `test/integration/atomic-fill/ThreatModel.t.sol`,
  `test/unit/settler/AtomicFill.t.sol`,
  `test/integration/settler/AsyncPremiumOptIn.t.sol` (`test_nonOptInPhaseTaggedFillReverts`).

### INV-DEFAULTER-RECOUP

- **Statement:** For cPT-holder-opt-in orders (`premiumPaymentMode = 1`) whose
  filler(s) rolled (`dstCstProduced > 0`) but never fired PREMIUM, the dstCST
  residual escrowed at the Settler is reclaimable to the originating cPT-holder rollover contract
  (`orderData.rolloverContract`) once `block.timestamp > orderData.fillDeadline` AND
  `orderStatus ∈ {None, Opened, Closing, Expired}`. Premium payer identity
  cannot redirect dstCST; PREMIUM phase-tagged `fill` must name the recorded
  rollover filler and canonical subFiller.
- **Throw site:** `Settler.reclaim` with mode-specific `_clearReclaimableResidualForMode`
  in `ExactSettler` and `PartialSettler`. Gate reverts:
  `Settler__OrderNotReclaimable`, `Settler__AsyncPremiumOptInRequired`,
  `Settler__ReclaimBeforeFillDeadline`, `Settler__NoResidualToReclaim`.
- **ABI note:** Source and docs use Defaulter for the role, but the emitted
  events remain `DefaulterResidualReclaimed` /
  `DefaulterResidualReclaimedWithSubFiller` where those ABI names still exist.
- **Tests:** `test/integration/lifecycle/ReclaimTerminalStatus.t.sol`,
  `test/integration/settler/AsyncPremiumOptIn.t.sol`,
  `test/invariant/failOnRevert/DefaulterRecoup.t.sol`.

### INV-CST-CANONICAL

- **Statement:** Every order admitted by `Settler._validateOrderCommon` MUST
  carry `srcCstToken` and `dstCstToken` that equal the canonical swap-tokens
  reported by the trusted Phoenix `PoolManager` singleton for the user-signed
  pool ids. Formally, for every accepted order:
  - `CORK_POOL_MANAGER.shares(rolloverParams.srcPoolId).swapToken == orderData.srcCstToken`
  - `CORK_POOL_MANAGER.shares(rolloverParams.dstPoolId).swapToken == orderData.dstCstToken`
  The pool ids are pulled from the EIP-712-signed `RolloverParams`, so the
  attacker cannot substitute a different poolId without breaking the user
  signature. `CORK_POOL_MANAGER` is a Settler immutable wired at construction;
  Phoenix deploys it as a per-chain singleton, so it is the canonical trust
  root for what counts as a valid cST.
- **Closes:** baptiste F-10 — *Non-canonical cST accepted at
  admission*. The naive defence (read `IPoolShare(token).poolManager()` and
  consult a factory allowlist) is bypassable because the `poolManager()` view
  runs in caller-controlled bytecode and can return any address, including
  the canonical one. INV-CST-CANONICAL inverts the trust direction: ask the
  trusted singleton "what is the canonical cST for poolId X?" and compare
  against the caller-supplied address. The result is unspoofable because the
  attacker cannot inject into the singleton's storage.
- **Throw site:** `ExactSettler.sol/PartialSettler.sol` — `Settler__SrcCstNotCanonical` /
  `Settler__DstCstNotCanonical` in `_validateOrderCommon`.
- **Tests:** `test/unit/settler/CstCanonicalGate.t.sol` covers the F-10 attack
  vectors (spoofed `poolManager()`, unbound poolId, src-vs-dst asymmetric
  spoofing) plus happy-path admission. Integration coverage:
  `test/integration/rollover/HookRestructure.t.sol` (signed-poolId mismatch
  cases now revert at the Settler-level canonical gate instead of the rolloverContract).
  Handler-driven coverage:
  `test/invariant/failOnRevert/CstCanonical.t.sol`,
  `test/invariant/continueOnRevert/CstCanonical.t.sol`.

### INV-DST-CST-REACHABLE

- **Statement:** Atomic fill never leaves an observable live dstCST residual
  after a successful transaction. Exact-mode and partial-mode settlement drain
  the residual to the recorded filler destination before `fill(...)` returns;
  if any downstream transfer or premium hook fails, the entire fill reverts and
  the residual write is unwound. The invariant pins Settler-internal
  reachability only; external receivability for a filler-chosen destination that
  reverts is tested as expected-revert, not invariant violation. Canonical
  Cork/Phoenix `PoolShare` cSTs are the supported token surface; non-standard
  outbound fee-on-transfer cSTs are out of scope for this invariant.
- **Throw site:** structural — `_fillAtomic` runs rollover, premium, and
  `_settlePaidRolloverRecord` in one transaction.
- **Tests:** `test/unit/settler/SettlerCoverage.t.sol`,
  `test/integration/atomic-fill/ThreatModel.t.sol`.

## RolloverContract invariants

### INV-TRUST-CONFIG-DELAY

- **Statement:** Trust-configuration changes on a rolloverContract are time-locked.
  The rolloverContract itself exposes only a synchronous setter
  `setTrustConfig(uint8, address[])` gated `msg.sender == _factory()`; the
  factory holds the queue. Owner-only queue paths resolve the target from
  `rolloverContractOf[msg.sender]`: `CorkRolloverContractFactory.queueFactoryDefaultTrustConfig()`
  snapshots the current factory default threshold and attester list at queue
  time, while `CorkRolloverContractFactory.queueTrustConfig(threshold, attesters)` accepts an
  explicit custom replacement config. Both paths schedule an op for the caller's own rolloverContract on the
  constructor-supplied external per-rolloverContract
  trust-config `TimelockController` (validated at construction with
  `getMinDelay() <= MAX_TRUST_CONFIG_DELAY`, factory proposer/canceller roles,
  and factory executor capability) and mirrors the queued
  `(threshold, attesters, salt)` into factory storage (`pendingConfig[salt]` +
  `lastSalt[rolloverContract]`, with `queueNonce[rolloverContract]` guaranteeing salt uniqueness
  across re-queues). `effectiveAt` is not stored in the factory; it is read from
  the external timelock via `getTimestamp(opId)`. Queued configs are
  fail-closed at queue time via `_validateTrustConfig`:
  `threshold > 0`, `attesters.length > 0`, `threshold <= attesters.length`,
  `attesters.length <= MAX_TRUST_ATTESTERS` (16), every attester is nonzero,
  and the attester list is strictly ascending (`attesters[i] > attesters[i - 1]`);
  uniqueness follows from strict ascending order. This matches the ERC-7484 / Rhinestone
  `isSortedAndUniquified` requirement so configs fail fast at queue time rather than
  late at the registry. The same rule applies to factory defaults and rolloverContract
  initialization.
  `CorkRolloverContractFactory.applyTrustConfig(rolloverContract)` is permissionless, loads the
  queued salt/threshold/attesters from the factory mirror, records the exact
  expected timelock op id in transient state, and routes through
  `TimelockController.execute`; the
  timelock reverts `TimelockController.TimelockUnexpectedOperationState`
  while the delay has not elapsed and `CorkRolloverContractFactory__NoQueuedTrustConfig`
  if nothing is queued for this rolloverContract. The relay callback must supply the
  current pending salt, match `(threshold, attesters)` exactly, and recompute to
  the transient expected op id or `CorkRolloverContractFactory__MismatchedApplyArgs` /
  `CorkRolloverContractFactory__UnexpectedTrustConfigRelay` reverts. Direct timelock
  execution fails because the transient expected op id is unset. Re-queuing
  via either queue path cancels any prior pending op on the timelock and resets
  the configured-delay clock for the replacement operation. Default-path queues do not auto-follow later
  `setDefaults` changes; owners must queue again to use newer defaults. The
  owner can also call
  `cancelTrustConfig()` to abort their own pending queue without applying
  it. The filler-facing `CorkRolloverContractFactory.pendingTrustConfig(rolloverContract)` view is
  a Factory mirror plus timelock timestamp view: `threshold` and `attesters`
  come from the Factory pending mirror, while `effectiveAt` is
  `trustConfigTimelock.getTimestamp(opId)` for that mirrored operation. Only
  the full zero tuple `(0, [], 0)` means no Factory pending mirror exists. A
  nonzero config with `effectiveAt > 0` means the mirror and timelock op both
  exist. A nonzero config with `effectiveAt == 0` means the mirror exists but
  the timelock op is absent, done, or unset, usually because an external
  canceller canceled the op directly; the owner recovers with
  `cancelTrustConfig()` or by requeueing. cPT holder is the deployment
  default, which is precisely why this delay is load-bearing.

  Zero delay is intentionally valid as deployment/governance policy. The
  protocol enforces `getMinDelay() <= MAX_TRUST_CONFIG_DELAY` and the canonical
  factory/timelock role wiring, but it does not enforce a nonzero lower bound or
  guarantee a nonzero observation window. The live
  `trustConfigTimelock.getMinDelay()` value and `pendingTrustConfig` are the
  operational signals for fillers, monitors, and deployment gates.

  **Cross-phase policy (P-09).** The configured trust-config timelock delay is
  the **simulation-stability window**, not a per-order snapshot. The per-order
  the cPT-holder-signed `OrderData.rolloverIntentHash` pins the canonical hook list
  the cPT holder signed; there is no persistent rolloverContract-side intent-auth snapshot.
  Trust revocation is **prospective only** for already-rolled fills,
  with one asymmetry between hook families:

  - **Rollover hooks** (pre / mid / post): module attestation is re-checked
    live at every phase via `_prevalidateIntentCalls` and the registry's
    `IERC7484.check`. An `applyTrustConfig` (or same-tx `trustAttesters` revoke
    on the underlying ERC-7484 registry) that lands between ROLLOVER
    sub-phases of an already-started order can therefore brick the rollover.
  - **Premium hooks**: attestation is **live-validated at PREMIUM execution**
    via the same `_prevalidateIntentCalls` + `IERC7484.check` path the
    rollover hooks use. Under strict premium-hook revert semantics, an
    `applyTrustConfig` between ROLLOVER and PREMIUM that invalidates a
    premium-hook module causes the atomic fill transaction to revert and unwind
    fully. The intra-hook trust-mutation guard
    (`CorkRolloverContract__TrustConfigMutatedDuringHook`) is still active for premium
    hooks. cPT holder emergency response for already-rolled in-flight orders is
    `Settler.pause()` (blunt instrument).

  Fillers and integrators MUST treat `CorkRolloverContractFactory.pendingTrustConfig`
  as a live operational signal: a filler that wants rollover-leg guarantees
  MUST land its ROLLOVER fill before any pending apply becomes effective.
  PREMIUM-leg liveness is evaluated inside the same atomic fill; invalidating
  trust rotations before the transaction lands cause the fill to revert instead
  of leaving a residual cleanup path.
- **Field-scope guard.** The delay cannot be bypassed by hook-driven writes
  to live trust slots. `_liveTrustHash` covers `liveTrustThreshold` and
  `liveTrustAttesters`; a hook that `sstore`s either slot mid-execution
  trips `CorkRolloverContract__TrustConfigMutatedDuringHook`. The rolloverContract no longer
  holds any pending-trust storage (queued state lives in the factory's
  `pendingConfig[salt]` mirror), so the historical bypass vector
  via `pendingTrust*` writes is closed by construction. Also:
  `erc7484Registry` is CWIA-immutable (trailer bytes 40-60), not a storage
  slot — no `sstore` vector exists for the registry pointer.
- **Explicit attester mirror (F-02).** Hook admission does not rely on the
  registry's effective-trust getters for `msg.sender`. `_prevalidateIntentCalls`
  copies `liveTrustThreshold` / `liveTrustAttesters` and calls the explicit
  `IERC7484.check(module, moduleType, attesters, threshold)` overload. During
  `_executeIntentCalls`, the local trust hash is snapshotted before hooks; after
  each delegatecall the hash is re-checked and
  `IERC7484.trustAttesters(threshold, attesters)` reseeds the registry from the
  rolloverContract mirror. A hook that calls `registry.trustAttesters(...)` as the rolloverContract
  cannot persist attacker attesters for later phases without detection.
- **Throw site:** `CorkRolloverContractFactory.queueTrustConfig` reverts
  `CorkRolloverContractFactory__InvalidThreshold` / `CorkRolloverContractFactory__ZeroAddress` /
  `CorkRolloverContractFactory__DuplicateAttester` /
  `CorkRolloverContractFactory__TooManyAttesters` for invalid trust configs.
  `CorkRolloverContractFactory.applyTrustConfig` reverts
  `CorkRolloverContractFactory__NoQueuedTrustConfig` (nothing queued for this rolloverContract)
  or `CorkRolloverContractFactory__MismatchedApplyArgs(expectedSalt)` (relay
  calldata/salt does not match the mirrored pending config, a
  stale/malicious/direct timelock callback was attempted, or the
  factory/timelock operation identity diverged). The timelock layer itself
  reverts `TimelockController.TimelockUnexpectedOperationState` while the
  configured delay has not elapsed.
- **Tests:** `test/unit/factory/TrustConfigQueue.t.sol` (queue / cancel /
  validation surface); `test/unit/rollover-contract/TrustConfigViaFactory.t.sol`
  (factory-only `setTrustConfig` gate); `test/integration/timelock/EndToEnd.t.sol`
  (queue → wait configured delay → apply path through `TimelockController`);
  `test/invariant/failOnRevert/FactoryIsSoleRolloverContractTrustWriter.t.sol`
  (no non-factory writer to live trust state);
  `test/invariant/failOnRevert/PendingTimelockMatchesFactoryMirror.t.sol`
  (factory mirror stays in lockstep with timelock);
  `test/integration/trust/DelegatecallTrustMutation.t.sol`
  (explicit attester check + registry restoration after hook delegatecall).

### INV-FACTORY-DEFAULTS-MANAGED

- **Statement:** Factory-wide default-trust-config rotation (threshold +
  attesters + registry) is gated by `DEFAULTS_MANAGER_ROLE`. If delayed
  governance is desired, deployment MUST assign `DEFAULTS_MANAGER_ROLE` to an
  external governance/timelock contract; CorkRolloverContractFactory itself does not own
  a factory-governance delay primitive. Affects only NEW rolloverContracts deployed after
  the update lands; existing rolloverContracts retain the snapshot they were seeded with
  at `deployRolloverContract` time and rotate their own live trust state through the
  per-rolloverContract trust-config timelock cycle (`queueFactoryDefaultTrustConfig` or
  `queueTrustConfig` / `applyTrustConfig`, `INV-TRUST-CONFIG-DELAY`). New values are validated with
  the same threshold / attester predicate as queued per-rolloverContract trust configs
  (non-empty attesters, no zero, strictly ascending, threshold in `[1, length]`,
  length ≤ `MAX_TRUST_ATTESTERS`, non-zero registry with deployed code; uniqueness follows
  from strict ascending order).
- **Throw site:** `CorkRolloverContractFactory.setDefaults` (`DEFAULTS_MANAGER_ROLE`;
  `CorkRolloverContractFactory__InvalidThreshold` / `CorkRolloverContractFactory__ZeroAddress` /
  `CorkRolloverContractFactory__DuplicateAttester` /
  `CorkRolloverContractFactory__UnsortedAttesters` /
  `CorkRolloverContractFactory__TooManyAttesters` on bad input,
  `CorkRolloverContractFactory__AddressHasNoCode` when registry has no code). Live
  defaults are read from the namespaced `FactoryStorage.defaultTrustThreshold`
  / `defaultAttesters` / `erc7484Registry` slots; `deployRolloverContract` forwards the
  live snapshot to every new rolloverContract's `initialize` and CWIA-trailer.
- **Tests:** `test/admin-trust-rotation/FactoryDefaultsRotation.t.sol`
  (`setDefaults` access control / validation / new-rolloverContract seed /
  existing-rolloverContract non-retroactivity);
  `test/invariant/handlers/FactoryDefaultsRotationHandler.sol`,
  `test/invariant/failOnRevert/FactoryDefaultsRotation.t.sol`,
  `test/invariant/continueOnRevert/FactoryDefaultsRotation.t.sol`.

### INV-NON-ROTATABLE-TRUST-ANCHORS

- **Statement:** Four trust anchors stay immutable post-construction by
  design:
  - `BaseSettler.ROLLOVER_CONTRACT_FACTORY` and `BaseSettler.CORK_POOL_MANAGER` — orders are
    bound to the Settler ↔ Factory ↔ PoolManager triple; rotation would
    break in-flight orders.
  - `CorkRolloverContractFactory.ROLLOVER_CONTRACT_IMPLEMENTATION` — CWIA-clone semantic; every
    existing rolloverContract is bound to the implementation it was cloned from.
  - `CorkRolloverContractFactory.trustConfigTimelock` — constructor-supplied external
    per-rolloverContract trust-config timelock. The address is immutable and rotation is a
    factory redeploy. The configured delay is mutable only through the
    Factory-governed `queueTrustConfigDelayUpdate` /
    `applyTrustConfigDelayUpdate` path, the replacement delay is bounded by
    `MAX_TRUST_CONFIG_DELAY`, and delay-update scheduling deliberately reads the
    raw live delay so an above-cap timelock can recover to a bounded value. Normal
    trust-config queues still fail closed while the live delay is above the cap,
    and factory proposer/canceller/executor wiring remains required.
- **Recovery posture:** rotating any of these is a redeploy-and-migrate
  operation, not an in-place setter. New deployments form a new lineage;
  existing-rolloverContract state stays where it was cloned. The per-rolloverContract
  `setTrustConfig` flow (`INV-TRUST-CONFIG-DELAY`) and the factory
  `setDefaults` flow (`INV-FACTORY-DEFAULTS-MANAGED`) cover rotation needs for
  the mutable trust state.
- **Throw site:** structural — these are `immutable` storage slots assigned
  in their respective constructors; the compiler enforces non-reassignment.
- **Tests:** `test/admin-trust-rotation/NonRotatableAnchorsDocs.t.sol`
  (docs + immutable-keyword pin); `test/admin-trust-rotation/FactoryDefaultsRotation.t.sol`
  (companion rotation surface; demonstrates which surfaces ARE rotatable).

### INV-PREMIUM-PAID-RELEASES-DST

- **Statement:** Under the `ATOMIC_TAG` branch of `Settler.fill()`, the call
  admits, rolls over, pays premium, and settles within a single Settler frame.
  If the atomic frame returns successfully then on return
  `rec.premiumFired` (partial mode) or `exactRec.premiumFired` (exact mode) is
  `true`, the rolloverContract's `premiumFiredFor[orderDigest][filler][subFiller]` is
  `true`, the
  filler has been credited the `dstCstProduced`, and the premium has been pulled
  from the filler into the rolloverContract (the rolloverContract's premium hooks decide the final
  resting place — cPT-holder discretion). Any failure inside the atomic frame —
  factory policy-gate reverts (`CorkRolloverContractFactory__SettlerNotApproved`,
  `CorkRolloverContractFactory__PhaseNotDispatchable`,
  `CorkRolloverContractFactory__InvalidOrderBinding`,
  `CorkRolloverContractFactory__SettlerLatchMismatch`,
  `CorkRolloverContractFactory__SettlerNotOriginSettler`,
  `CorkRolloverContractFactory__UnknownRolloverContract`), rolloverContract-side hook reverts, trust-mutation
  guard reverts, the `Settler__PremiumExceedsCap` cap gate, or any other revert
  — propagates verbatim through the atomic frame and rolls back the entire
  transaction (no Settler latch is set, no premium is pulled, no dstCST changes
  hands). Admin kill-switches like `revokeSettler`
  ([[INV-SETTLER-APPROVED]]) remain effective for in-flight atomic fills.
- **Mechanism:** Premium dispatch is strict. There is no supported path where
  the Settler-side latch persists while the rolloverContract-side latch rolls back: the
  Settler latch is set inside the same transaction as the rolloverContract dispatch, and
  any failure in that transaction reverts the latch with it.
- **Throw site:** structural — every atomic fill ends in either a fully
  successful frame or a fully reverted frame.
- **Tests:** `test/integration/atomic-fill/ThreatModel.t.sol`,
  `test/integration/premium/PremiumFactoryRevocationPropagates.t.sol`,
  `test/integration/settler/SettlerIntermediaryRoundTripElimination.t.sol`,
  `test/invariant/handlers/PremiumPaidReleasesDstHandler.sol`,
  `test/invariant/failOnRevert/PremiumPaidReleasesDst.t.sol`,
  `test/invariant/continueOnRevert/PremiumPaidReleasesDst.t.sol`.

### INV-ATOMIC-FILL-CANONICAL

- **Statement:** The `ATOMIC_TAG = 255` envelope is the canonical atomic
  dispatch shape for helper-driven ERC-7683 fills. The envelope is the verbatim
  4-tuple
  `(uint8 ATOMIC_TAG, bytes rolloverFillerData, uint256 premiumCap, bytes cptHolderSig)`.
  Within one atomic frame the Settler admits the order (None → Opened
  transition via cPT-holder sig, or no-op for an already-Opened order), passes that
  same cPT-holder sig to the rolloverContract for first hook authorization, rolls over the
  position, pays the premium, and settles the filler's slot. The ROLLOVER /
  PREMIUM phase tags inside this envelope are inner-leg discriminants only and
  do not split the atomic frame.
- **Throw site:** `BaseSettler.fill` routes `LibAtomicFill.ATOMIC_TAG` to
  `_fillAtomic`; `BaseFiller` and `EvcRolloverAdapter` only construct this
  envelope when using their default helper dispatch.
- **Tests:** `test/unit/settler/AtomicFill.t.sol`,
  `test/integration/atomic-fill/ThreatModel.t.sol`.

### INV-FILL-TAG-DISPATCH

- **Statement:** `Settler.fill(orderId, originData, fillerData)` is a tag
  router. `ATOMIC_TAG = 255` dispatches the atomic 4-tuple envelope
  `(uint8 ATOMIC_TAG, bytes rolloverFillerData, uint256 premiumCap, bytes cptHolderSig)`
  and runs admit → rollover → premium → settle in one frame. For
  `premiumPaymentMode = 0`, public `HookPhase.ROLLOVER` and
  `HookPhase.PREMIUM` payloads revert with `Settler__AsyncPremiumOptInRequired`.
  For cPT-holder-opt-in `premiumPaymentMode = 1`, those phase tags enter the async
  lifecycle directly.
- **Throw site:** `BaseSettler.fill` peeks `fillerData` with
  `LibAtomicFill.peekDispatch`. `ATOMIC_TAG` enters `_fillAtomic`;
  ROLLOVER/PREMIUM enter `_fillAsync` and are mode-gated there; a failed async
  mode gate reverts `Settler__AsyncPremiumOptInRequired`, while every other tag
  reverts `Settler__AtomicFillRequired`.
- **Tests:** `test/unit/settler/AtomicFill.t.sol`,
  `test/integration/atomic-fill/ThreatModel.t.sol`,
  `test/integration/settler/AsyncPremiumOptIn.t.sol`.

### INV-ATOMIC-FILL-CONTEXT

- **Statement:** The atomic envelope carries no separate premium leg. After the
  rollover leg, `_fillAtomic` synthesizes the canonical premium payload from
  `rolloverPayload.intent`, pins `premiumFor` to `msg.sender`, `destination` to
  the rollover destination, `subFiller` to the rollover slot key, and leaves
  premium-only auth/routing fields unrepresentable on the wire. `requiredPremium`
  is computed once from observed dstCST produced inside `_payPremiumAndSettle`.
- **Throw site:** structural — `LibFillerPayload.decodeAtomicEnvelopeValidated`
  exposes only `rolloverFillerData`, `premiumCap`, and `cptHolderSig`, and
  `BaseSettler._synthesizeAtomicPremiumPayload` supplies all premium-frame
  fields from the validated rollover frame. `BaseSettler._payPremiumAndSettle` reverts
  `Settler__PremiumExceedsCap` when `requiredPremium > premiumCap`.
- **Tests:** `test/unit/settler/AtomicFill.t.sol`,
  `test/unit/libraries/LibFillerPayloadDecode.t.sol`,
  `test/integration/atomic-fill/ThreatModel.t.sol`.

### INV-PHOENIX-SHARE-QUANTUM

- **Statement:** Source order size, fill amount, and any non-zero partial
  residual must be multiples of Phoenix's minimum share quantum
  `10 ** (18 - collateralDecimals)` for the source pool. Collateral decimals
  above 18 revert `LibPhoenixShareQuantum__UnsupportedCollateralDecimals`. Settler admission validates
  `orderSize`; `_validateRolloverQuantum` validates fill/residual before token
  movement; `CorkRolloverContract._validateRolloverPreflight` and `_unwindLeg` mirror the
  same alignment via `LibPhoenixShareQuantum`.
- **Throw site:** `LibPhoenixShareQuantum__OrderSizeNotQuantumAligned`,
  `LibPhoenixShareQuantum__FillAmountNotQuantumAligned`,
  `LibPhoenixShareQuantum__ResidualNotQuantumAligned`,
  `LibPhoenixShareQuantum__UnsupportedCollateralDecimals`,
  `CorkRolloverContract__ShareAmountNotQuantumAligned`,
  `CorkRolloverContract__PartialResidualNotQuantumAligned`.
- **Tests:** `test/integration/rollover/AtomicFillPhoenixQuantization.t.sol`,
  `test/integration/rollover/F02_UnwindMintTruncation.t.sol`.

### INV-PREMIUM-HOOK-REVERT-CASCADES

- **Statement:** A reverting premium hook reverts the current premium
  transaction. Atomic fills unwind admit, rollover, premium, and settle in the
  same frame; no earlier rollover-only residual can remain parked by a failed
  premium leg. The rolloverContract's bounded revert-reason copy
  (`REVERT_REASON_CAP = 256`) is preserved: the propagated revert payload is
  clamped at 256 bytes inside `CorkRolloverContract__DelegatecallFailed(target, reason)`.
- **Throw site:** `CorkRolloverContract._delegatecallHookDiscardReturndata` propagates
  the clamped revert payload to the Settler frame, which re-raises it.
- **Tests:** `test/unit/rollover-contract/HookReturndataDiscard.t.sol`
  (`test_premium_giantRevert_clampedTo256`).

### INV-NO-DST-STRAND-IN-ATOMIC-FLOW

- **Statement:** Through the ERC-7683 `Settler.fill()` atomic path there is
  no route that mints dstCST to the filler's slot without also paying the
  premium. Every successful `Settler.fill()` either (a) admits + rollovers +
  pays premium + settles the slot all in one frame, OR (b) reverts and rolls
  everything back. No Cork-specific legacy entrypoint can intentionally leave
  an unpaid rollover residual.
- **Throw site:** structural — the atomic envelope binds rollover + premium
  in one Settler frame; no intermediate persistent state.
- **Tests:** `test/integration/atomic-fill/ThreatModel.t.sol`,
  `test/integration/rollover/AllowUnderfill.t.sol`
  (`test_partialUnderfillBelowOrderSizeDrainsEscrowButRemainsOpened`).

### INV-NO-FILLER-TOKEN-LOSS

- **Statement:** A successful `Settler.fill()` leaves the filler net-whole
  in srcCST and dstCST: any srcCST the filler does not consume (underfill
  refund) returns to the filler; the dstCST the rolloverContract mints is forwarded
  to the filler in the same frame; the premium pulled from the filler is
  bounded by the envelope-level `premiumCap`. The Settler never holds
  filler-owned dstCST or srcCST across frame boundaries — hostile
  donations to the Settler address remain stranded on the Settler (not
  forwarded), but never inflate the FillRecord or affect the filler's
  net P&L.
- **Throw site:** structural — the Settler's atomic dispatch reads the
  rolloverContract's actual dstCST delta and forwards exactly that amount; the
  envelope's `premiumCap` is enforced by `Settler__PremiumExceedsCap` in
  `_payPremiumAndSettle`.
- **Tests:** `test/unit/settler/DstIntegrityAndDocs.t.sol`,
  `test/integration/settler/SettlerIntermediaryRoundTripElimination.t.sol`,
  `test/integration/atomic-fill/ThreatModel.t.sol`.

### INV-PREMIUM-REQUIRES-ROLLOVER

- **Statement:** `CorkRolloverContract._handlePhasePremium` reverts when
  `rolled[orderDigest] == 0`; PREMIUM phase requires at least one prior
  ROLLOVER on the same `orderDigest`. Order-wide floor, not per-filler
  (per-filler ordering remains the Settler's responsibility via
  `rec.dstCstProduced != 0`). Defense-in-depth against a compromised
  approved Settler dispatching PREMIUM before any ROLLOVER has fired, which
  would otherwise latch the rolloverContract's
  `premiumFiredFor[orderDigest][filler][subFiller]` for an attacker-chosen
  filler and brick the legitimate atomic fill.
- **Throw site:** `CorkRolloverContract._handlePhasePremium` reverts
  `CorkRolloverContract__PremiumBeforeRollover()` at the head of the function (before
  the `premiumFiredFor` latch check and before any state mutation).
- **Tests:** `test/integration/rollover-contract/PremiumRequiresRollover.t.sol`,
  `test/invariant/handlers/PremiumRequiresRolloverHandler.sol`,
  `test/invariant/failOnRevert/PremiumRequiresRollover.t.sol`,
  `test/invariant/continueOnRevert/PremiumRequiresRollover.t.sol`.

### INV-ROLLOVER_CONTRACT-CPT-HOLDER-SIG-EVERY-DISPATCH

- **Statement:** `OrderData.rolloverIntentHash` commits the canonical zero-digest
  `RolloverIntent` hash. On every hook dispatch, including atomic PREMIUM, the
  rolloverContract verifies the cPT holder's EIP-712 / ERC-1271 signature over `orderDigest`
  against the cPT holder (`orderData.user == ICorkRolloverContract(orderData.rolloverContract).owner()`).
- **Throw site:** `CorkRolloverContract._ensureOwnerAuthorized` reverts
  `CorkRolloverContract__BadIntentSignature` on invalid cPT-holder signature.
- **Tests:** `test/integration/auth/RolloverIntentBinding.t.sol`,
  `test/integration/auth/CptHolderSigEveryDispatch.t.sol`,
  `test/integration/settler/AsyncPremiumOptIn.t.sol`,
  `test/unit/rollover-contract/CorkRolloverContractBranchCoverage.t.sol`.

## Settler / pool invariants

### SL-14

- **Statement:** `srcCstToken` and `dstCstToken` MUST resolve to distinct
  Phoenix pool ids on `open` / `openFor`. Same-pool routing collapses the
  rollover into a no-op against the same risk surface.
- **Throw site:** `Settler._validateOrder` reverts `Settler__SamePoolId`.
- **Tests:** `test/unit/modules/Modules.t.sol`,
  `test/unit/settler/SettlerStrengthened.t.sol`.

## RolloverContract-opinionated rollover invariants

### INV-CPT-CONTAINED

- **Statement:** srcCPT and dstCPT are cPT-holder property; the rolloverContract
  holds CPT only inside the rollover leg's transient window (preHook →
  unwindMint; deposit → postHook). After `_finalizeRolloverLeg` both
  srcCPT and dstCPT balances MUST equal their entry snapshots —
  bidirectional `!=` guards reject both residual leftover above entry
  snapshot AND silent sweep of pre-existing CPT below entry snapshot.
  The standard post-rollover dstCPT hook supports nonzero standing dstCPT by
  reading the dynamic `dstCptAfterDeposit - dstCptBeforeDeposit` transient register
  and routing only that net increase to the cPT roller; it never sweeps the
  full live dstCPT balance. The rolloverContract issues NO standing CPT
  allowances and never transfers CPT to a non-attested target.
- **Throw site:** `CorkRolloverContract._finalizeRolloverLeg` reverts
  `CorkRolloverContract__DstCptNotRestored(uint256 expected, uint256 actual)` when
  `dstCptAfter != dstCptBefore` and
  `CorkRolloverContract__SrcCptNotRestored(uint256 expected, uint256 actual)` when
  `srcCptAfter != srcCptBefore` at end of leg.
- **Tests:**
  `test/integration/rollover-contract/PostRolloverDstCptTransferModule.t.sol`;
  `test/integration/rollover-contract/InvCptContainedBidirectional.t.sol`;
  `test/integration/rollover/HookRestructure.t.sol`
  (forced-handle scenarios).

### DSR-1

- **Statement:** Both legs measure their output token via the rolloverContract's own
  balance delta — not via the pool's `unwindMint` / `deposit` return value.
  The pool's return is rejected when it is zero (DSR-1 zero-check); the
  delta is the source of truth for accounting downstream.
- **Throw site:** `CorkRolloverContract._unwindLeg` reverts
  `CorkRolloverContract__RolloverZeroUnwindMint` when `unwindMint` returns 0;
  `CorkRolloverContract._depositLeg` reverts `CorkRolloverContract__RolloverZeroDeposit` when
  `deposit` returns 0. Both legs derive their outbound amount from
  `balanceOf` deltas, not the pool's return value.
- **Tests:** `test/integration/rollover/HookRestructure.t.sol`.

### DSR-2

- **Statement:** `_depositLeg` does NOT re-read `caDst.balanceOf(rolloverContract)`
  between the approve and the deposit call — the value sampled before
  `forceApprove` is the same value passed as `caIn` to `deposit`.
  Re-reading would invite a hostile midHook to inflate caDst after the
  approve and trick the rolloverContract into depositing more than it intended.
- **Throw site:** structural — `_depositLeg` snapshots `caForDeposit` once.
- **Tests:** `test/integration/rollover/HookRestructure.t.sol`.

### DSR-2b

- **Statement:** `_depositLeg` derives `sharesOut` from a local
  `dstCstAtDeposit` snapshot taken AFTER pre/mid hooks have run, NOT from
  the entry snapshot `s.dstCstBefore` sealed in `_populateScratch`.
  Anchoring `sharesOut` on the entry snapshot would let a pre/mid-hook
  drain of `X` dstCST be silently absorbed into `sharesOut = D - X`: the
  rolloverContract would `safeTransfer` only `D - X` to the settler, the residual
  rolloverContract balance would equal the entry snapshot, and the INV-5 floor
  check would pass while `X` dstCST sits with a hook-chosen recipient
  that paid no premium. Sampling the snapshot AFTER the hook brackets
  closes the deposit-as-refill arithmetic gap (competition finding
  F-01 / heri, against the pre-fix branch). Asymmetric with DSR-2c
  (caDst pre-pre-hook anchor) by design.
- **Throw site:** structural — `_depositLeg` samples `dstCstAtDeposit`
  immediately before `forceApprove` and uses it as the subtrahend.
- **Tests:** `test/integration/rollover/F01_DstCstDrainBracket.t.sol`,
  `test/invariant/handlers/Dsr2bHandler.sol`,
  `test/invariant/failOnRevert/Dsr2b.t.sol`,
  `test/invariant/continueOnRevert/Dsr2b.t.sol`.

### DSR-2c

- **Statement:** `_depositLeg`'s `caForDeposit = caDstAfterMid -
  caDstBefore` uses the pre-pre-hook `caDstBefore` snapshot from
  `_populateScratch`. cPT-holder-signed pre-rollover hooks that credit caDst to
  the rolloverContract INTENTIONALLY widen the deposit bracket and are minted into
  the deposit; the inflated dstCST routes to the settler. cPT-holder discretion
  per `accepted-03` ("cPT-holder hook discretion, no balance bracket by
  design"). Asymmetric with DSR-2b: caDst wider bracket = cPT-holder-discretion
  design; dstCST tight bracket = INV-5 security closure. cPT holders that
  intend pre-hook caDst credits to remain in the rolloverContract must route via a
  post-rollover hook; `params.minSharesOut` is a FLOOR, not a CEILING.
- **Throw site:** structural — `_populateScratch` snapshots
  `caDstBefore` BEFORE the pre-rollover hooks execute; `_depositLeg`
  subtracts that value from `caDstAfterMid` (sampled after pre/mid
  hooks).
- **Tests:** `test/integration/rollover-contract/Dsr2cAsymmetryDocumentation.t.sol`.

### INV-3 (CA non-decreasing across mid-bracket) — REMOVED

- **Status:** REMOVED. The mid-hook caSrc no-drop guard blocked cross-CA
  rollover (e.g. src pool on USDC, dst pool on DAI with a cPT-holder-signed
  SwapModule swapping caSrc -> caDst between `unwindMint` and `deposit`).
  Replaced by `INV-DST-FLOOR`, which leans on the cPT-holder-signed
  `params.minSharesOut` floor as the load-bearing safety against mid-hook
  value-skim. The mid-hook may now freely consume caSrc; end-to-end value
  is bounded only by the deposit-side floor.
- **Replaced by:** `INV-DST-FLOOR` (see below).
- **Prior throw site (removed):**
  `CorkRolloverContract._handlePhaseRollover` previously reverted
  `CorkRolloverContract__MidPhaseCollateralDrain(uint256 before, uint256 after)`
  when `caAfterMid < caAfterUnwind`. The error declaration and revert
  have been deleted from `src/CorkRolloverContract.sol`.
- **Heading retained for traceability** — earlier audit notes referencing
  `INV-3` should be updated to `INV-DST-FLOOR` for the equivalent property.

### INV-DST-FLOOR (cPT-holder-signed dst-side floor is load-bearing)

- **Statement:** End-to-end value across a rollover leg is bounded by
  `params.minSharesOut` — the cPT-holder-signed floor on `dstProduced` enforced
  after `_depositLeg`. The mid-hook is a CA-composition step that MAY
  freely consume caSrc (cross-CA rollover via an attested SwapModule);
  the rolloverContract enforces NO constraint on caSrc balance during mid. Any
  attempt to under-produce dstCST below the floor trips the guard.
- **Throw site:** `CorkRolloverContract._handlePhaseRollover` reverts
  `CorkRolloverContract__UnwindDepositShortfall(uint256 produced, uint256 floor)`
  when `dstProduced < params.minSharesOut`. `CorkRolloverContract__CaInsufficientForDeposit()`
  catches the degenerate `caForDeposit == 0` path.
- **Tests:** `test/unit/rollover-contract/MidHookDstFloor.t.sol`,
  `test/invariant/continueOnRevert/MidHookFuzz.t.sol`,
  `test/invariant/failOnRevert/MidHookFuzz.t.sol`.
- **Note:** This invariant is the load-bearing safety after the INV-3
  removal. Compromised-but-attested mid-hook modules are the residual
  threat; operational mitigation is timelock-gated attester rotation
  (`INV-TRUST-CONFIG-DELAY`) plus the Settler OZ Pausable kill-switch.

### INV-5 (dstCST no-drain across leg)

- **Statement:** Across the rollover leg, the rolloverContract's dstCST balance MUST
  end at or above the entry snapshot. Combined with the rolloverContract's tail
  transfer of `dstProduced` to `params.settler` and DSR-2b's local
  snapshot for `sharesOut`, a hostile hook in ANY bracket (pre, mid, or
  post) cannot drain dstCST out of the rolloverContract without tripping this
  guard.
- **Throw site:** `CorkRolloverContract._finalizeRolloverLeg` reverts
  `CorkRolloverContract__MidPhaseDstCstDrain(uint256 before, uint256 after)`
  when `dstCstAfter < dstCstBefore`.
- **Coverage with DSR-2b:** INV-5 is load-bearing for the POST bucket
  (deposit math has already executed, so a POST drain shows up as a
  net balance drop below the entry snapshot). For the PRE/MID bucket,
  DSR-2b is the structural anchor that prevents the deposit math from
  absorbing the drain into `sharesOut`; once `sharesOut` is truthful,
  the tail `safeTransfer(settler, sharesOut)` leaves the rolloverContract
  visibly short of the entry snapshot and INV-5 fires.
- **Tests:** `test/unit/settler/DstIntegrityAndDocs.t.sol`,
  `test/integration/rollover/HookRestructure.t.sol`,
  `test/integration/rollover/F01_DstCstDrainBracket.t.sol`,
  `test/invariant/handlers/DstCstNoDrainHandler.sol`,
  `test/invariant/failOnRevert/DstCstNoDrain.t.sol`,
  `test/invariant/continueOnRevert/DstCstNoDrain.t.sol`.

### INV-DST-CST-MINT-RATIO-BOUNDED

- **Statement:** `_depositLeg` caps the observed dstCST mint at the live
  canonical quote returned by
  `IPoolManager.previewDeposit(dstPoolId, caForDeposit)`. Defense-in-depth
  against a buggy / governance-compromised / future-upgraded PoolManager
  that over-mints dstCST relative to `caForDeposit`. The anchor is the
  Phoenix PoolManager's own view (`CorkPoolManager.previewDeposit`), so
  the cap auto-tracks any deliberate Phoenix formula change — divergence
  reflects mint-pipeline drift between `deposit` and `previewDeposit` on
  the same PoolManager, not a missing constant in the rolloverContract. Under-mint
  (e.g. future Phoenix protocol-fee models that mint <1:1) remains
  allowed by design; this is strictly an UPPER bound.
- **Throw site:** `CorkRolloverContract._depositLeg` reverts
  `CorkRolloverContract__DepositOverMint(uint256 sharesOut, uint256 canonical)`
  when the rolloverContract's local balance delta exceeds the canonical quote.
- **Cross-references:** Deposit-side counterpart of the unwind-side
  containment family — `INV-CPT-CONTAINED`, `INV-5`, `DSR-1`, `DSR-2`.
  Orthogonal to the admission-side PoolManager allowlist (which gates
  WHICH PoolManager is wired in); this invariant gates WHAT an approved
  PoolManager is permitted to mint at runtime.
- **Tests:** `test/integration/rollover/F06_DepositMintRatioCap.t.sol`,
  `test/invariant/handlers/DstCstMintRatioBoundedHandler.sol`,
  `test/invariant/failOnRevert/DstCstMintRatioBounded.t.sol`,
  `test/invariant/continueOnRevert/DstCstMintRatioBounded.t.sol`.

### INV-SRC-CST-RETURNED (srcCST drains exactly fillAmount across leg)

- **Statement:** Across the rollover leg, the rolloverContract's srcCST balance MUST
  end exactly at `s.srcCstBefore - fillContext.fillAmount`. `s.srcCstBefore` is
  sampled by `_populateScratch` AFTER the Settler has already transferred
  `fillAmount` srcCST into the rolloverContract (per `BaseSettler.fill`: the
  `safeTransferFrom(filler, rolloverContract, fillAmount)` runs before
  `executeIntentHooks`). The legitimate path then drains exactly
  `fillAmount` srcCST from the rolloverContract — Phoenix `unwindMint` burns
  `effectivelyBurned`, and `srcLeftover = fillAmount - effectivelyBurned`
  is forwarded back to the Settler. Any deviation indicates an unexpected
  src-side mutation (Phoenix truncation semantic shift, donation absorbed
  mid-leg, hook mutating the rolloverContract's srcCST balance) and must brick the
  leg. Defense-in-depth symmetric with INV-5.
- **Throw site:** `CorkRolloverContract._finalizeRolloverLeg` reverts
  `CorkRolloverContract__SrcCstNotReturned(uint256 expected, uint256 actual)` when
  `srcCstAfter != s.srcCstBefore - fillContext.fillAmount`.
- **Falsifier:** A future hook or mutation that lets rolloverContract srcCST drift
  off the entry snapshot, or a regression in `_unwindLeg`'s truncation
  reconciliation (Phoenix burns less than `effectivelyBurned`, residue
  not forwarded to Settler, etc.). The guard fires regardless of why the
  net delta is non-zero.
- **Tests:** `test/integration/rollover/F02_UnwindMintTruncation.t.sol`,
  `test/invariant/handlers/SrcCstReturnedHandler.sol`,
  `test/invariant/failOnRevert/SrcCstReturned.t.sol`,
  `test/invariant/continueOnRevert/SrcCstReturned.t.sol`.

## Non-properties / explicit discretions

### RolloverContract premium routing discretion

- **Statement (non-invariant):** The rolloverContract's premium handler runs
  `intent.premiumHooks` with a standing-balance tripwire, not a hard cap on
  downstream routing. The cPT holder freely decides where
  premium goes — treasury wallet, yield vault, filler refund, distribution
  module — by selecting the `premiumHooks` chain at intent-signing time.
  Hooks may spend up to `fillContext.premium` of the just-delivered premium but MUST
  NOT net-reduce the rolloverContract's pre-leg standing balance
  (`INV-PREMIUM-HOOKS-CANNOT-SWEEP-STANDING-BALANCE`). Enforced structure
  also includes: (a) ERC-7484 attester gate on every premium hook target;
  (b) factory-side transient `_originatingSettler` active-dispatch latch
  pinning `fillContext.originSettler == msg.sender` during the rolloverContract call; (c) rolloverContract
  `premiumFiredFor[orderDigest][filler][subFiller]` latch and `PremiumFired`
  emit with resolved `fillContext.subFiller`.
- **Throw site:** structural — `CorkRolloverContract._handlePhasePremium` snapshots
  `standingBalanceBeforeHooks`, runs `_executeIntentCalls(MODULE_TYPE_EXECUTOR)`, then
  reverts `CorkRolloverContract__PremiumHookSweptExcess` if the post-hook balance falls below it.
- **Tests:** `test/integration/rollover/HookRestructure.t.sol`
  (premium scenarios 16–19).

## Factory invariants

### INV-SETTLER-APPROVED

- **Statement:** Every successful `CorkRolloverContractFactory.executeIntentHooks` call
  originated from a Settler currently flagged `approvedSettlers[msg.sender] ==
  true`. The factory is default-deny; `SETTLER_APPROVER_ROLE` holders approve
  Settlers via `approveSettler`, and `SETTLER_REVOKER_ROLE` holders may revoke
  at any time via `revokeSettler` (instant kill-switch). After revocation the
  next factory dispatch from that Settler
  fails before rolloverContract execution — for BOTH ROLLOVER and PREMIUM legs. Premium
  dispatch is strict: factory policy-gate reverts roll back the current atomic
  fill transaction, including any premium pull and Settler-side premium latch.
  `deployRolloverContract` does NOT auto-approve — genesis
  admin MUST approve the exact and partial Settlers before the first order.
  Downstream rolloverContracts trust the factory's origin-settler latch and do not
  re-validate the Settler address per call.
  The allowlist bit is not a behavioral verifier. Canonical `ExactSettler` and
  `PartialSettler` are the supported default; custom Settlers are not approved
  unless governance has explicitly reviewed conformance with the same token-flow
  and release semantics: srcCST predeposit into the rolloverContract
  ([[INV-SRC-CST-PREDEPOSITED]]), dstCST delivery to the Settler
  ([[INV-DSTCST-LIABILITY-BACKED]]), srcLeftover return/refund
  ([[INV-ROLLOVER-SRC-DELTA-FLOOR]]), the signed-settler pin, and premium/dst
  release behavior matching the canonical Settlers.
- **Throw site:** `CorkRolloverContractFactory.executeIntentHooks` reverts
  `CorkRolloverContractFactory__SettlerNotApproved` (declared on
  `ICorkRolloverContractFactory`). Admin path: `CorkRolloverContractFactory.approveSettler`
  rejects `address(0)` with `CorkRolloverContractFactory__ZeroAddress` and code-less
  addresses with `CorkRolloverContractFactory__AddressHasNoCode`; it does not verify a
  Settler interface. `revokeSettler` is idempotent and performs no zero/code
  checks.
- **Premium rollback:** The set of propagated selectors is exactly the
  `executeIntentHooks` policy-gate errors declared at the top of
  `src/interfaces/rollover/ICorkRolloverContractFactory.sol`; failures revert the caller's
  transaction rather than producing any partial premium state.
- **Emergency stop for in-flight already-rolled fills (non-PREMIUM
  context):** Settler exposes a separate `PAUSER_ROLE` (`Settler.pause()` /
  `unpause()`); factory revocation alone disables the FUTURE factory and
  rolloverContract dispatches, but a filler with already-pulled srcCST mid-`fill` is
  past the factory gate. `Settler.pause()` is the user-facing emergency stop
  for those flows.
- **Tests:** `test/unit/factory/SettlerAllowlist.t.sol`,
  `test/unit/settler/SettlerLatchAssertion.t.sol`,
  `test/integration/premium/PremiumFactoryRevocationPropagates.t.sol`,
  `test/invariant/failOnRevert/SettlerApproved.t.sol`,
  `test/invariant/continueOnRevert/SettlerApproved.t.sol`,
  `test/invariant/FactoryInvariants.t.sol`.

### N-INV-FACTORY-ORIGIN-LATCH-SCOPED

- **Statement:** During each factory-to-rolloverContract hook dispatch,
  `CorkRolloverContractFactory._originatingSettler` mirrors the approved Settler caller
  and is cleared after the rolloverContract call returns. Outside an active dispatch frame
  `originatingSettler()` returns zero; reverts after the latch write roll back
  the transient write.
- **Throw site:** `CorkRolloverContractFactory.executeIntentHooks` sets the latch only
  after the phase / allowlist / nonzero-digest / origin-settler / known-rolloverContract
  gates, reverts `CorkRolloverContractFactory__SettlerLatchMismatch` if an existing latch
  belongs to a different Settler, and clears `_originatingSettler` after the
  rolloverContract call. The dispatch also requires `fillContext.originSettler == msg.sender`
  (`CorkRolloverContractFactory__SettlerNotOriginSettler`). `nonReentrant` is the
  practical nested-dispatch guard; the mismatch branch is defensive.
- **Tests:** `test/unit/settler/SettlerLatchAssertion.t.sol`,
  `test/unit/factory/SettlerAllowlist.t.sol`,
  `test/invariant/FactoryInvariants.t.sol`.

## Settler invariants (filler authorisation)

### INV-FILLER-AUTH

- **Statement:** Every successful ROLLOVER leg of `Settler.fill` satisfies one of:
  (a) `orderData.exclusiveFiller == address(0)` (no gate),
  (b) `msg.sender == orderData.exclusiveFiller` (direct call), or
  (c) a valid EIP-712 / ERC-1271 signature by `exclusiveFiller` over
  `FillerAuth(orderDigest, destination, subFiller)` (delegated executor).
  `openFor` performs NO filler attestation — `originFillerData` is opaque
  and is not consulted by the Cork Settler implementation. Async PREMIUM does
  not re-query live `FillerAuth` after a ROLLOVER slot is recorded; it relies on
  the stored rollover filler/destination/subFiller, cPT-holder signature, premium
  payment, and destination-mismatch checks, and releases dstCST only to the
  recorded destination. Destination + subFiller binding makes any griefing replay
  across executors or sub-filler slots strictly net-negative for the attacker;
  executor-binding is deliberately omitted.
- **Throw site:** The ROLLOVER branch of `Settler.fill` reverts
  `Settler__UnauthorizedFiller(exclusiveFiller, msg.sender)` when
  `LibFillerAuth.isAuthorised` returns false on the delegated-with-invalid-sig branch.
- **Tests:** `test/unit/settler/FillerAuth.t.sol`,
  `test/integration/auth/SettlerTrustConsolidation.t.sol`,
  `test/invariant/failOnRevert/FillerAuth.t.sol`,
  `test/invariant/continueOnRevert/FillerAuth.t.sol`.

## RolloverContract invariants (allowlist composition)

### INV-FILL-CONTEXT-MATCHES-ORDER

- **Statement:** Every `fillContext.*` field that semantically duplicates an `orderData.*`
  field MUST equal the cPT-holder-signed value at rolloverContract admission. Specifically:
  `fillContext.orderSize == orderData.orderSize`,
  `fillContext.fillDeadline == orderData.fillDeadline`,
  `fillContext.allowPartialFills == orderData.allowPartialFills`,
  `fillContext.allowUnderfill == orderData.allowUnderfill`, and
  `fillContext.rolloverIntentHash == orderData.rolloverIntentHash` across both phases;
  `fillContext.premiumToken == orderData.premiumToken` during PREMIUM (ROLLOVER tolerates
  `fillContext.premiumToken == address(0)` because the field is unused on that path).
  Defence in depth against a compromised approved Settler that fabricates the
  Settler-supplied dispatch context.
- **Throw site:** `CorkRolloverContract._validateOrderDataBinding`
  (`src/CorkRolloverContract.sol`) reverts one of `CorkRolloverContract__OrderSizeMismatch`,
  `CorkRolloverContract__FillDeadlineMismatch`, `CorkRolloverContract__AllowPartialFillsMismatch`,
  `CorkRolloverContract__AllowUnderfillMismatch`, `CorkRolloverContract__RolloverIntentHashCtxMismatch`,
  or `CorkRolloverContract__PremiumTokenMismatch` per field. Runs immediately after
  `_validateFillEnvelope` on every `executeIntentHooks` dispatch.
- **Tests:** `test/integration/rollover-contract/FillContextOrderDataBinding.t.sol`,
  `test/invariant/handlers/CompromisedSettlerDispatchHandler.sol`,
  `test/invariant/failOnRevert/CompromisedSettlerFillContext.t.sol`,
  `test/invariant/continueOnRevert/CompromisedSettlerFillContext.t.sol`.

### INV-ORDER-DIGEST-RE-DERIVED-ROLLOVER_CONTRACT-SIDE

- **Statement:** The rolloverContract re-derives the EIP-712 `orderDigest` from the
  forwarded `orderData` envelope using `LibSettlerHashing.computeOrderDigest`
  against the Settler's own `DOMAIN_SEPARATOR()` (read via
  `ISettler(fillContext.originSettler).DOMAIN_SEPARATOR()`); the derived digest
  MUST equal the dispatched `orderDigest`. The rolloverContract never trusts the
  Settler-supplied digest alone — a compromised Settler that swaps in a
  digest that does not correspond to the forwarded `orderData` is rejected.
- **Throw site:** `CorkRolloverContract._validateOrderDataBinding` reverts
  `CorkRolloverContract__OrderDataDigestMismatch(expected, supplied)` when the
  re-derived digest disagrees with the dispatched digest. Note: distinct
  from `CorkRolloverContract__OrderDigestMismatch`, which fires when
  `intent.orderDigest` itself disagrees with the dispatch argument.
- **Tests:** `test/integration/rollover-contract/FillContextOrderDataBinding.t.sol`
  (digest-mismatch on any tampered `orderData.*` field; foreign chain-id
  / foreign domain-separator paths);
  `test/invariant/handlers/CompromisedSettlerDispatchHandler.sol`,
  `test/invariant/failOnRevert/CompromisedSettlerDigest.t.sol`,
  `test/invariant/continueOnRevert/CompromisedSettlerDigest.t.sol`.

### INV-PARAMS-MATCH-ORDER

- **Statement:** Rollover parameters used by the rolloverContract come only from the
  cPT-holder-signed `orderData.rolloverParams`. `executeIntentHooks` no longer
  accepts a separate runtime `RolloverParams` argument, so a compromised
  approved Settler cannot validate one signed parameter set while executing
  another at the rolloverContract boundary. Any mutation of `orderData.rolloverParams`
  changes the re-derived order digest and is rejected before the rollover or
  premium phase executes.
- **Throw site:** `CorkRolloverContract._validateOrderDataBinding` re-derives the order
  digest from the forwarded `OrderData` and reverts
  `CorkRolloverContract__OrderDataDigestMismatch(expected, supplied)` when any signed
  field, including any nested `rolloverParams` field, disagrees with
  `orderDigest`.
- **Tests:** `test/integration/rollover-contract/FillContextOrderDataBinding.t.sol`
  (`testRevert_orderDataRolloverParamsTampered_digestMismatch` and shared
  order-data binding matrix), plus the compromised-Settler invariant harness
  that now mutates `orderData.rolloverParams` and expects digest mismatch.

### INV-PREMIUM-HOOKS-CANNOT-SWEEP-STANDING-BALANCE

- **Statement:** Premium-hook execution inside `CorkRolloverContract._handlePhasePremium`
  MUST NOT reduce the rolloverContract's balance of `fillContext.premiumToken` below the value
  observed at PREMIUM entry. Equivalently: the net token-flow attributable to
  the premium-hook frame is at most `fillContext.premium`. Defends against full-balance
  sweep modules (removed full-balance transfer/split logic) consuming the rolloverContract's pre-existing balance
  — cPT holder's stale `premiumToken` deposits remain available for `withdraw`
  recovery.
- **Throw site:** Premium is already at the rolloverContract before `_handlePhasePremium`
  (Settler direct `filler → rolloverContract` transfer + balance-delta check). The handler
  sets `standingBalanceBeforeHooks = IERC20(fillContext.premiumToken).balanceOf(address(this)) - fillContext.premium`,
  writes `LibLastDeliveredPremium`, runs premium hooks, then requires
  `balanceAfterHooks >= standingBalanceBeforeHooks` else
  `CorkRolloverContract__PremiumHookSweptExcess(deficit, fillContext.premium)`.
  Hooks may route the just-delivered `fillContext.premium` but must not sweep
  pre-existing rolloverContract premium-token balance.
- **Tests:** `test/integration/atomic-fill/ThreatModel.t.sol`
  (`test_PremiumHookLogicRevertCascades`,
  `test_PremiumHookRevertNoLongerParksAtRolloverContract`),
  `test/integration/rollover/HookRestructure.t.sol`
  (premium routing and vault deposit scenarios), and
  `test/unit/rollover-contract/CorkRolloverContractBranchCoverage.t.sol`
  (`testRevert_handlePhasePremiumDetectsStandingBalanceSweep`).

### INV-ATTESTED-MODULES-ARE-AMOUNT-SCOPED

- **Statement:** Every NEW executor module attested under
  `MODULE_TYPE_EXECUTOR` for premium-hook usage MUST take an explicit `amount`
  parameter; full-balance reads (`token.balanceOf(address(this))`) are
  forbidden in new modules. The replacement modules `ScopedSplitModule` and
  `ScopedTransferModule` accept `amount == type(uint256).max` as a sentinel
  that reads the rolloverContract's per-token transient slot via
  `LibLastDeliveredPremium.read`. `_handlePhasePremium` populates that slot
  AFTER the Settler delivery check and explicitly clears it (writes zero) AFTER
  the premium-hook frame and the post-hook trip-wire have run; EIP-1153 tx-end
  clearing is only a fallback boundary. `SplitModule` and `TransferAllModule`
  are removed; neither is a current new-order premium template. Any
  full-balance over-sweep behaviour from a reintroduced or externally attested
  module is contained by
  [[INV-PREMIUM-HOOKS-CANNOT-SWEEP-STANDING-BALANCE]].
- **Throw site:** Structural — no runtime check. Enforced by attestation
  policy and module source review.
- **Tests:**
  - `test/unit/libraries/LibLastDeliveredPremium.t.sol` — slot derivation
    determinism, per-token isolation, write/read round-trip, and write-zero
    clear.
  - `test/unit/modules/OnlyDelegatecall.t.sol` — `ScopedSplitModule` /
    `ScopedTransferModule` delegatecall surface.
  - `test/integration/atomic-fill/ThreatModel.t.sol` — premium hook revert
    cascades through the atomic frame.

### INV-HOOK-RETURNDATA-DISCARDED

- **Statement:** `CorkRolloverContract._executeIntentCalls` MUST NOT copy
  hook-returndata into memory on the success path, and MUST clamp the
  revert-reason copy at `REVERT_REASON_CAP` (256) bytes on failure. Defends
  against attested-but-malicious modules that gas-grief the filler's `fill()`
  by returning or reverting with megabytes of data; the rolloverContract consumes
  nothing from the returndata semantically — only `ok` carries signal.
- **Throw site:** The execution loop delegates to
  `_delegatecallHookDiscardReturndata(RolloverTypes.Call calldata)`, which
  invokes `delegatecall(gas(), target, argsPtr, cdLen, 0, 0)` (output region
  `0, 0` → no copy on success), then on failure reads `returndatasize()`,
  clamps to `min(size, REVERT_REASON_CAP)`, allocates a bounded `bytes memory
  reason`, and reverts `CorkRolloverContract__DelegatecallFailed(target, reason)`. The
  pre-existing `_liveTrustHash` mutation guard and
  `_prevalidateIntentCalls` envelope remain unchanged.
- **Tests:** `test/unit/rollover-contract/HookReturndataDiscard.t.sol` (1 MB return-path
  gas bound, 1 MB revert-reason clamp, ≤256-byte verbatim pass-through,
  zero-byte empty-revert).

### INV-PARAMS-SETTLER-PIN

- **Statement:** Every `_handlePhaseRollover` dstCST `safeTransfer` lands at
  `orderData.rolloverParams.settler == fillContext.originSettler == msg.sender == an
  approved Settler`. The factory enforces the approved-Settler gate and
  `fillContext.originSettler == msg.sender`; the rolloverContract enforces the signed settler
  pin once during `_validateOrderDataBinding`, before either ROLLOVER or
  PREMIUM dispatch. Rollover then reads `orderData.rolloverParams` internally.
- **Throw site:** `CorkRolloverContract._validateOrderDataBinding` reverts
  `CorkRolloverContract__SignedSettlerOriginMismatch(signedSettler, originSettler)` when
  `orderData.rolloverParams.settler != fillContext.originSettler`. A zero signed
  settler is rejected by the same check because the factory requires a
  non-zero approved Settler caller as `fillContext.originSettler`.
- **Tests:** `test/unit/rollover-contract/RolloverPreflightSettlerPin.t.sol`,
  `test/integration/rollover-contract/PremiumSignedSettlerBinding.t.sol`,
  `test/invariant/failOnRevert/ParamsSettlerPin.t.sol`,
  `test/invariant/continueOnRevert/ParamsSettlerPin.t.sol`.

## Settler invariants (operational halt)

### INV-DEFAULT-ATTESTERS-FACTORY-SEEDED

- **Statement:** Every rolloverContract deployed by factory `F` starts life with attester
  set equal to `F`'s `defaultAttesters()` and threshold equal to `F`'s
  `DEFAULT_TRUST_THRESHOLD`. The seed pair is mirrored into the rolloverContract's
  `liveTrustThreshold` / `liveTrustAttesters` storage and forwarded to
  `IERC7484.trustAttesters` against the rolloverContract's own smart-account record at
  `initialize` time. cPT holder updates flow through the queue/apply trust-config cycle
  using the configured trust-config timelock delay; the safe/default path queues
  a snapshot of current factory defaults.
  The factory's defaults are validated at construction and on `setDefaults`
  updates (non-empty, no zero addresses, strictly ascending, threshold in
  `[1, length]`, `length <= MAX_TRUST_ATTESTERS` (16)); uniqueness follows from
  strict ascending order.
- **Throw site:** `CorkRolloverContractFactory.constructor` validates the seed and
  stores it in immutable / write-once storage; `CorkRolloverContractFactory.deployRolloverContract`
  forwards the seed to `CorkRolloverContract.initialize`; `CorkRolloverContract.initialize`
  mirrors and forwards it. The post-init mirror is the load-bearing source
  of truth for `rolloverContractSnapshot` and `rolloverContractConfig`.
- **Tests:** `test/unit/factory/CorkRolloverContractFactoryDefaults.t.sol`,
  `test/unit/rollover-contract/CorkRolloverContractDefaultsInit.t.sol`,
  `test/unit/rollover-contract/CorkRolloverContractCptHolderOverride.t.sol`,
  `test/invariant/handlers/DefaultAttestersSeedHandler.sol`,
  `test/invariant/failOnRevert/DefaultAttestersSeed.t.sol`,
  `test/invariant/continueOnRevert/DefaultAttestersSeed.t.sol`.

### INV-USER-IS-ROLLOVER_CONTRACT-OWNER

- **Statement:** Every order accepted by the Settler has
  `orderData.user == ICorkRolloverContract(orderData.rolloverContract).owner()`. The Settler
  enforces the binding inside `_validateOrderCommon` immediately after the
  factory-deployment check and before pool-id / intent-hash validation, so
  `openFor` and pre-open atomic `fill(...)` admission paths are bound
  identically. The rolloverContract's
  `owner()` view returns the CWIA-baked cPT-holder address
  (`INV-ROLLOVER_CONTRACT-OWNER-IMMUTABLE`), so the binding pins each order to a single
  immutable owner address per rolloverContract. That owner may be an EOA or an ERC-1271
  contract; the code intentionally does not enforce an EOA-only owner. This
  binding is load-bearing for rolloverContract hook authorization because the rolloverContract now
  accepts the cPT-holder signature over `orderDigest` as the owner authorization for
  the `RolloverIntent` hash committed in signed `OrderData`.
- **Throw site:** `Settler._validateOrderCommon` reverts with
  `Settler__UserNotRolloverContractOwner(orderData.user, orderData.rolloverContract)` when the
  binding fails. The check is reached by `Settler.open`, `Settler.openFor`, and
  pre-open `Settler.fill(...)` admission (None-branch via
  `_validateOrderForFill`).
- **Tests:** `test/unit/settler/UserBinding.t.sol`
  (`test_openFor_revertsWhenUserNotRolloverContractOwner`,
  `test_openFor_succeedsWhenUserMatchesRolloverContractOwner`,
  `test_isDeployedRolloverContractPrecedesUserBinding`,
  `test_fill_preOpen_revertsWhenUserNotRolloverContractOwner`,
  `test_fill_preOpen_succeedsWhenUserMatchesRolloverContractOwner`,
  `testFuzz_acceptedOrdersHaveUserEqualsRolloverContractOwner`),
  `test/invariant/handlers/UserIsRolloverContractOwnerHandler.sol`,
  `test/invariant/failOnRevert/UserIsRolloverContractOwner.t.sol`,
  `test/invariant/continueOnRevert/UserIsRolloverContractOwner.t.sol`.

### INV-ROLLOVER_CONTRACT-OWNER-IMMUTABLE

- **Statement:** The CWIA-baked cPT holder is fixed for the rolloverContract's
  lifetime. There is no owner-transfer primitive — the owner address lives
  in the clone's 60-byte CWIA trailer (bytes 0..20, with `factory` at bytes
  20..40 and `erc7484Registry` at bytes 40..60), is decoded by
  `_cwiaImmutableArgs`, and has no setter. The rolloverContract's `erc7484Registry`
  field is structurally similar: assigned write-once by `initialize` (one-shot
  per OZ `Initializable`) and never mutated afterwards.
- **Throw site:** structural — no transfer/setter exists on the rolloverContract surface.
  `_cwiaImmutableArgs` decodes the trailer on every read; `initialize` is
  gated by `onlyFactory` + `initializer` so the registry write happens
  exactly once.
- **Tests:** `test/unit/rollover-contract/CorkRolloverContractDefaultsInit.t.sol#test_InitializeIsOneShot`,
  `test/unit/rollover-contract/RolloverContractLens.t.sol` owner / factory CWIA decode assertions.

### INV-PAUSE-GATES-ALL-ENTRYPOINTS

- **Statement:** When `Settler.paused()`, every external state-changing
  entrypoint (`open`, `openFor`, `fill`, `reclaim`, `markExpired`, `cancel`) MUST
  revert with OZ `Pausable.EnforcedPause`. View functions
  (`orderStatus`, `resolve`, `resolveFor`, `participantCountOf`, etc.)
  remain reachable. Pause authority is split: `PAUSER_ROLE` halts;
  `UNPAUSER_ROLE` resumes; the two roles are held by separate keys so a
  single compromised credential cannot drive a full halt-resume cycle.
- **Throw site:** OZ `Pausable._requireNotPaused()` reverts
  `EnforcedPause()` via the `whenNotPaused` modifier placed before
  `nonReentrant` on every gated entrypoint. `pause()` / `unpause()` revert
  `AccessControlUnauthorizedAccount` on unauthorised callers.
- **Tests:** `test/unit/settler/SettlerPause.t.sol`,
  `test/invariant/handlers/SettlerPauseHandler.sol`,
  `test/invariant/failOnRevert/SettlerPauseGates.t.sol`,
  `test/invariant/continueOnRevert/SettlerPauseGates.t.sol`.

### N-INV-ROLLED-MONOTONE-AND-BOUNDED

- **Statement:** For every `orderDigest`, the rolloverContract's
  `$.rolled[orderDigest]` accumulator tracks the srcCST actually burned by
  Phoenix (post-truncation), not the calldata-supplied request.
  `_unwindLeg` mirrors Phoenix's truncation policy
  (`effectivelyBurned = srcSharesToBurn - (srcSharesToBurn % minimumShares)`,
  `minimumShares = 10**(18 - CAdecimals)`) before recording the credit; the
  truncation residue srcCST is forwarded to the Settler as `srcLeftover` and
  refunded to the filler, and the truncation residue srcCPT is swept to the
  cPT holder under INV-CPT-CONTAINED. The accumulator is strictly
  non-decreasing across the order's lifetime and never exceeds
  `fillContext.orderSize` latched at the first successful ROLLOVER phase. The
  `PHASE_0_TERMINAL_BIT` in `$.hookNonces[orderDigest]` is set-only — once
  set it stays set, and no subsequent ROLLOVER phase can clear it or push
  `rolled` further. The preflight at `_validateRolloverPreflight` rejects
  any fill while the terminal bit is set and any fill that would push
  `rolled + fillAmount` past `fillContext.orderSize`.
- **Throw site:** `CorkRolloverContract._validateRolloverPreflight` rejects overfill
  and post-terminal fills. The load-bearing accumulator write and
  OR-into-bitfield live in `_applyRolloverAccounting`, called by
  `_finalizeRolloverLeg`. Falsifier: future code that (a) writes a
  smaller value to `rolled[orderDigest]`, (b) clears the terminal bit by
  AND-mask, or (c) accepts a ROLLOVER fill after the terminal bit is set.
- **Tests:** `test/invariant/handlers/RolledMonotoneHandler.sol`,
  `test/invariant/failOnRevert/RolledMonotone.t.sol`,
  `test/invariant/continueOnRevert/RolledMonotone.t.sol`.

### N-INV-FILLER-SETTLED-STICKY

- **Statement:** For every `(orderId, filler, subFiller)` tuple, the Settler's
  partial-mode `fillerSettled` latch is set-only. Once flipped true by atomic
  settlement, it stays true for the contract's lifetime. Corollary: a partial
  slot is paid out exactly once.
- **Throw site:** Partial-mode `_settlePaidRolloverRecord` pre-checks the latch and
  reverts with `Settler__FillerAlreadySettled` before flipping the bit.
  Falsifier: any future writer that clears `fillerSettled[id][f][subFiller]`
  back to false, or any alternate payout path that bypasses the latch.
- **Tests:** `test/invariant/handlers/FillerSettledStickyHandler.sol`,
  `test/invariant/failOnRevert/FillerSettledSticky.t.sol`,
  `test/invariant/continueOnRevert/FillerSettledSticky.t.sol`.

### N-INV-PARTIAL-RESIDUAL-RECONCILES-TO-TOTAL

- **Statement:** For every partial-mode `orderDigest`, the sum of
  `$.fillerDstCstResidual[orderDigest][filler]` across every filler that
  has ever rolled equals the order-level accumulator
  `$.totalDstCstEscrowed[orderDigest]` at every observable moment between
  transactions. The two slots move together inside atomic fill: rollover
  increments both by `dstProduced`, and settlement zeros the per-filler slot
  while decrementing the order accumulator by the same `residual`.
- **Throw site:** Paired writes in `PartialSettler._recordRolloverAccountingForMode`
  and `PartialSettler._settlePaidRolloverRecord`.
  Falsifier: any future writer that drops one of the paired writes
  (e.g., forgets to decrement the order accumulator on settle)
  produces a cross-tx interleaving where the per-filler residual sum
  diverges from the order escrow accumulator.
- **Tests:** `test/invariant/handlers/PartialResidualReconciliationHandler.sol`,
  `test/invariant/failOnRevert/PartialResidualReconciliation.t.sol`,
  `test/invariant/continueOnRevert/PartialResidualReconciliation.t.sol`.

### INV-FACTORY-QUEUE-CHECKS-OWNER

- **Statement:** Every owner-only code path that schedules an operation on the
  external per-rolloverContract trust-config `TimelockController` derives the target
  rolloverContract from `rolloverContractOf[msg.sender]`, verifies it is a deployed factory rolloverContract,
  and operates only on that rolloverContract. No path lets an owner supply another target
  rolloverContract. No path schedules an op for a non-factory rolloverContract.
- **Throw site:** `_requireCallerRolloverContract` in `src/CorkRolloverContractFactory.sol`
  reverts with `CorkRolloverContractFactory__CallerHasNoRolloverContract(caller)`,
  `CorkRolloverContractFactory__NotFactoryRolloverContract(rolloverContract)`, or
  `CorkRolloverContractFactory__NotRolloverContractOwner(caller, rolloverContract)` before any
  `trustConfigTimelock.schedule` call. `cancelTrustConfig` enforces the same
  caller-owned-rolloverContract resolution before `trustConfigTimelock.cancel`.
- **Tests:** `test/unit/factory/TrustConfigQueue.t.sol`,
  `test/integration/timelock/EndToEnd.t.sol`,
  `test/invariant/handlers/FactoryQueueChecksOwnerHandler.sol`,
  `test/invariant/failOnRevert/FactoryQueueChecksOwner.t.sol`,
  `test/invariant/continueOnRevert/FactoryQueueChecksOwner.t.sol`.

### INV-SCHEDULE-VIA-HELPERS-ONLY

- **Statement:** `_scheduleTrustConfig` and `_scheduleTrustConfigDelayUpdate`
  are the only call sites of `TimelockController.schedule` in
  `src/CorkRolloverContractFactory.sol`. Any future contributor adding another
  `trustConfigTimelock.schedule` call site must refactor through a canonical
  helper or break this invariant by design.
  `_scheduleTrustConfig` validates the live timelock delay before normal
  trust-config queues; `_scheduleTrustConfigDelayUpdate` validates only the new
  bounded delay and uses the raw live delay so it can recover an above-cap
  timelock.
- **Throw site:** Structural — the helper is `internal` and every
  external queue entrypoint (`queueFactoryDefaultTrustConfig`,
  `queueTrustConfig`, and `queueTrustConfigDelayUpdate`) routes through one of
  the helpers. Tested
  with a meta-grep against the factory source.
- **Tests:** `test/integration/timelock/EndToEnd.t.sol`
  (`test_invFactoryQueueChecksOwner_grep`).

### INV-ROLLOVER_CONTRACT-TRUST-ONLY-VIA-FACTORY

- **Statement:** Every function that writes `liveTrust*` storage on the
  rolloverContract (`liveTrustThreshold`, `liveTrustAttesters`) gates on
  `msg.sender == _factory()`. There is no cPT-holder-direct or permissionless
  path to mutate live trust state on a rolloverContract; the only writer is the
  factory's `relayTrustConfig` (which itself is callable only by the external
  per-rolloverContract trust-config timelock and requires the matching pending salt,
  mirror values, and transient op id set by the canonical `applyTrustConfig`
  execution frame).
- **Throw site:** `CorkRolloverContract.setTrustConfig` reverts
  `CorkRolloverContract__NotFactory()` for any caller other than the rolloverContract's
  CWIA-baked factory. `CorkRolloverContractFactory.relayTrustConfig` reverts
  `CorkRolloverContractFactory__NotTimelock(caller)` for direct calls that do not
  originate from the trust-config timelock, and
  `CorkRolloverContractFactory__UnexpectedTrustConfigRelay` for raw timelock execution
  outside `applyTrustConfig`. `initialize` runs once during
  `deployRolloverContract` with the same `onlyFactory` modifier.
- **Tests:** `test/unit/rollover-contract/TrustConfigViaFactory.t.sol`,
  `test/invariant/failOnRevert/FactoryIsSoleRolloverContractTrustWriter.t.sol`,
  `test/invariant/continueOnRevert/FactoryIsSoleRolloverContractTrustWriter.t.sol`,
  `test/invariant/handlers/FactorySoleTrustWriterHandler.sol`.

### INV-TRUST-CONFIG-TIMELOCK-WIRED

- **Statement:** The factory does not deploy an internal timelock. The
  constructor binds an external per-rolloverContract trust-config `TimelockController`
  and rejects zero/code-less controllers, initial `minDelay > MAX_TRUST_CONFIG_DELAY`,
  missing factory `PROPOSER_ROLE`, missing factory `CANCELLER_ROLE`, and missing
  factory `EXECUTOR_ROLE`. It also rejects open execution via
  `EXECUTOR_ROLE(address(0))`, and `verify-deploy` mirrors those role checks.
  This timelock is not
  factory governance; factory-wide admin/defaults policy is external role
  wiring through `DEFAULT_ADMIN_ROLE`, `DEFAULTS_MANAGER_ROLE`,
  `TRUST_CONFIG_DELAY_MANAGER_ROLE`, `SETTLER_APPROVER_ROLE`, and
  `SETTLER_REVOKER_ROLE`.
- **Throw site:** `CorkRolloverContractFactory` constructor validation of
  `trustConfigTimelock_`.
- **Tests:** `test/unit/factory/CorkRolloverContractFactoryDefaults.t.sol`
  constructor validation tests and `test/script/VerifyDeploy.t.sol` gate-1
  factory shape checks.

### INV-PENDING-MIRRORS-TIMELOCK

- **Statement:** For every rolloverContract `c` with `lastSalt[c] != bytes32(0)`,
  the factory's `pendingConfig[lastSalt[c]]` stores exactly the
  `(threshold, attesters)` encoded with `lastSalt[c]` in the timelock's queued
  op for `c`. Factory-mediated cancellation, application, and overwrite
  operations clear or replace both halves in lockstep. If an external timelock
  canceller unsets the op directly, `pendingTrustConfig(c)` deliberately keeps
  returning the Factory mirror with `effectiveAt == 0` so operators can detect
  mirror/timelock divergence and recover with owner `cancelTrustConfig()` or
  requeue.
- **Throw site:** `_scheduleTrustConfig`, `applyTrustConfig`, and
  `cancelTrustConfig` paired writes/deletes in
  `src/CorkRolloverContractFactory.sol`.
- **Tests:**
  `test/invariant/failOnRevert/PendingTimelockMatchesFactoryMirror.t.sol`,
  `test/invariant/continueOnRevert/PendingTimelockMatchesFactoryMirror.t.sol`,
  `test/invariant/handlers/PendingTimelockMirrorHandler.sol`.

## EVC adapter invariants

### INV-EVC-CALLER-AUTHORIZED

**Statement.** A call into `EvcRolloverAdapter`'s gated functions is rejected unless: (a) `msg.sender == EVC` — the call originates from the Euler Vault Connector contract; (b) `EVC.getCurrentOnBehalfOfAccount(CONTROLLER)` returns `(onBehalfOfAccount = subaccount, controllerEnabled = true)`. Owner/operator authorization is performed by the EVC itself BEFORE dispatch (real EVC validates `authenticationData` and then forwards calldata unchanged via `target.call(data)`); the adapter does not — and cannot — re-derive the authenticated principal from calldata.

**Why this is faithful.** Euler EVC does not append the authenticated principal to the calldata tail. The adapter previously read `calldataload(sub(calldatasize(), 20))` and treated it as the principal; that read returns arbitrary attacker-controlled bytes and is therefore not a safety check. The corrected gate relies exclusively on EVC's published context API (`getCurrentOnBehalfOfAccount`), which EVC populates after performing its own owner/operator validation.

**Sources.**
- Euler docs — Authentication & Authorization: https://docs.euler.finance/concepts/core/evc/#authentication-and-authorization
- EVC call internals: https://evc.wtf/docs/concepts/internals/call/
- EVC source — `callWithContextInternal` forwards calldata unchanged: https://github.com/euler-xyz/ethereum-vault-connector/blob/master/src/EthereumVaultConnector.sol#L867

**Enforced at.** `EvcRolloverAdapter._gateEvc` — `src/EvcRolloverAdapter.sol`.

**Tested by.** `test/integration/evcadapter/EvcCallerAuthz.t.sol` — 6 scenarios including `test_GateEvc_CalldataSuffixCannotBypass`; `test/invariant/handlers/EvcCallerAuthzHandler.sol`; `test/invariant/failOnRevert/EvcCallerAuthz.t.sol`; `test/invariant/continueOnRevert/EvcCallerAuthz.t.sol`.

### INV-ADAPTER-JOB-AUTHORIZED

**Statement.** Every `EvcRolloverAdapter.execute` / `executePartial` call MUST be authorised by a Permit2 `permitWitnessTransferFrom` signature whose witness binds the exact job parameters: `(subaccount, fundingAccount, recipient, srcCst, fillerSrcCst, premiumToken, premium, minDstPerSrc, intentHash, orderDigest, nonce, deadline)`. `fundingAccount` is the Permit2 token owner and MUST equal `EVC.getAccountOwner(subaccount)` — for an EOA-owned subaccount, the primary EOA; for a contract-owned subaccount, the contract address itself (Permit2's `SignatureVerification.verify` falls back to EIP-1271 `isValidSignature` when the resolved signer is a contract). `recipient` is the settlement destination and tail-refund recipient; it is distinct from `subaccount` (EVC authorization identity and partial-mode `subFiller` key). The funding pull, the per-job authorisation, and the parameter binding are one cryptographic primitive — the witness is part of the signed bytes, not derived from a separately-fetched intent.

**Why this is load-bearing.** Closes two compounding risks in the prior standing-allowance model:

1. **Operator-authority gap (arch-review #4).** `_gateEvc` (INV-EVC-CALLER-AUTHORIZED) confirms the call originates from the EVC for the named subaccount, but it cannot confirm that the subaccount's authority actually consented to *these specific job parameters*. An enabled EVC operator (canonical Cork keeper) could otherwise fire `execute` with attacker-chosen `dstCst`, `minDstPerSrc=0`, or any `fillerSrcCst` ≤ the standing allowance. Witness binding makes per-job authorisation a precondition of fund movement.
2. **Stateful-1271 priming (arch-review #5).** When `_owner()` is a stateful EIP-1271 contract, an attacker who can prime the verifier's storage in batch-step-1 could otherwise run rollovers with crafted intents in batch-step-2. Witness binding makes the job parameters part of the signed bytes — there is no separately-fetched intent to substitute.

**Enforced at.** `EvcRolloverAdapter._pullJobFundsAndAuthorize` — `src/EvcRolloverAdapter.sol`. Reverts `__FundingSigInvalid` on empty sig, `__ZeroFundingAccount` on zero `fundingAccount`, `__SubaccountAuthorityMissing` when `EVC.getAccountOwner(subaccount)` returns zero or reverts, and `__FundingAccountMismatch` when the declared token owner is not the EVC owner of `subaccount`. All other failure modes (deadline, nonce reuse, amount mismatch, token mismatch, witness mismatch) revert inside Permit2 with its canonical selectors.

**Tested by.** `test/integration/evcadapter/Permit2WitnessAuthorization.t.sol` — A-1..A-15 (empty sig, wrong token, amount underflow, expired deadline, nonce replay, exact happy path, partial happy path, witness param mismatch, operator-replay, stateful-1271 priming-attack rejection, EOA XOR-derived subaccount, contract-1271 subaccount, missing-authority, funding-account mismatch, registered zero owner),
  `test/integration/evcadapter/EvcRecipientBinding.t.sol`,
  `test/invariant/handlers/AdapterJobAuthorizedHandler.sol`,
  `test/invariant/failOnRevert/AdapterJobAuthorized.t.sol`,
  `test/invariant/continueOnRevert/AdapterJobAuthorized.t.sol`.

### INV-EVC-RECIPIENT-BOUND

**Statement.** `EvcRolloverAdapter` routes rollover settlement to `job.recipient`
(not `job.subaccount`) and refunds post-fill srcCST/premium tails to
`job.recipient`. `recipient` is bound in the Permit2 witness; tampering after
signature reverts inside Permit2. Zero `recipient` reverts
`EvcRolloverAdapter__ZeroRecipient`.

**Enforced at.** `EvcRolloverAdapter._buildRolloverInnerBlob`, `_refundTails`,
`_pullJobFundsAndAuthorize` — `src/EvcRolloverAdapter.sol`.

**Tested by.** `test/integration/evcadapter/EvcRecipientBinding.t.sol`,
  `test/integration/evcadapter/Permit2WitnessAuthorization.t.sol`.

### INV-ADAPTER-NO-STANDING-ALLOWANCE

**Statement.** `EvcRolloverAdapter` MUST NOT consume any direct ERC-20 standing allowance from `job.subaccount` to itself. Funding flows exclusively through `PERMIT2.permitWitnessTransferFrom` and requires a per-call signature; the user's only persistent allowance is the canonical `token.approve(Permit2, …)` pattern.

**Why this is load-bearing.** Eliminates the long-tail liability identified in arch-review #6. A revoked operator / compromised keeper / mis-configured controller cannot exfiltrate funds via a one-line `safeTransferFrom(fundingAccount, …)` call because there is no direct adapter allowance to pull from. The blast radius of any single key compromise is bounded to whatever the user actively signs for that job.

**Enforced at.** `EvcRolloverAdapter.execute` / `executePartial` — `src/EvcRolloverAdapter.sol`. No `safeTransferFrom(job.subaccount, …)` call exists on the funding path; refund tails still flow through `safeTransfer` (adapter → `job.recipient`), which does not consume allowance.

**Tested by.** `test/integration/evcadapter/Permit2WitnessAuthorization.t.sol` — A-6 / A-7 assert zero `allowance(subaccount, adapter)` across the happy paths; `test/invariant/handlers/AdapterNoStandingAllowanceHandler.sol`; `test/invariant/failOnRevert/AdapterNoStandingAllowance.t.sol`; `test/invariant/continueOnRevert/AdapterNoStandingAllowance.t.sol`.

## Module invariants

### INV-REFERENCE-MODULES-DELEGATECALL-ONLY

- **Statement:** Reference hook modules under `src/modules/` revert
  direct calls (`address(this) == _SELF`); execution is permitted only
  via delegatecall from a delegating host (e.g.,
  `CorkRolloverContract._executeIntentCalls`). Defends against accidentally-
  deposited token sweep at the module's standalone address.
- **Throw site:** `src/modules/OnlyDelegatecall.sol::onlyDelegatecall`
  modifier, inherited and applied to `execute` on
  `src/modules/ApproveModule.sol`,
  `src/modules/OwnerTokenPullModule.sol`,
  `src/modules/PostRolloverDstCptTransferModule.sol`,
  `src/modules/ScopedSplitModule.sol`,
  `src/modules/ScopedTransferModule.sol`,
  `src/modules/PreRolloverReferenceModule.sol`,
  `src/modules/MidRolloverReferenceModule.sol`,
  `src/modules/PostRolloverReferenceModule.sol`.
- **Tests:** `test/unit/modules/OnlyDelegatecall.t.sol`.

`OwnerTokenPullModule` is generalized by token but is not a generic transfer
gadget: signed calldata supplies only the token, explicit nonzero amount, and
whether that amount is exact or a maximum bounded by owner balance and allowance,
while the source is always `ICorkRolloverContract(address(this)).owner()` and
the destination is always the delegatecall host. The rolloverContract does not
parse owner-pull calldata or cap arbitrary ERC-20 raw units against source-share
accounting. Useful rollover delivery is enforced by `_unwindLeg`, which observes
only the real sibling `srcCPT` delta before Phoenix `unwindMint`; underfill
outcomes remain governed by `_applyRolloverAccounting`.

### INV-APPROVE-MODULE-NO-RESIDUAL

- **Statement:** `ApproveModule.execute` MUST leave
  `IERC20(token).allowance(host, spender)` at its pre-bracket value
  (typically `0`) on every successful return. The bundled
  approve+call+revoke atomic shape eliminates residual
  `(token, spender)` allowance state at hook bracket close. On the
  revert path the surrounding delegatecall frame unwinds, so no
  allowance can persist either.
- **Throw site:** `src/modules/ApproveModule.sol::execute` — the
  terminating `token.forceApprove(spender, 0)`.
- **Tests:**
  `test/unit/modules/ApproveModuleAtomicBracket.t.sol`,
  `test/invariant/failOnRevert/ApproveModuleNoResidual.t.sol`,
  `test/invariant/continueOnRevert/ApproveModuleNoResidual.t.sol`.

### INV-WIRE-ORDER-STABILITY

- **Statement:** `OrderData` and `RolloverParams` EIP-712 wire field order is
  frozen post-launch; any reorder invalidates every in-flight cPT-holder-signed
  `OrderData` digest under the Settler EIP-712 domain AND breaks
  `rolloverIntentHash` continuity across deployed rolloverContracts.
  `FillerPayload` calldata field order is ABI-bound to `BaseFiller` /
  `EvcRolloverAdapter` encoders; reorders require an encoder version bump but
  do NOT invalidate cPT-holder-signed intents (FillerPayload is not EIP-712-hashed).
- **Throw site:** Structural - `Typehashes.ORDER_DATA_TYPEHASH` and
  `Typehashes.ROLLOVER_PARAMS_TYPEHASH` literal preimages are pinned by tests;
  any field reorder in `RolloverTypes.OrderData`, `RolloverTypes.RolloverParams`,
  or `FillerPayload` is caught at compile-time (wire-format
  mismatch) and/or test-time (typehash literal regression + struct-decode
  round-trip).
- **Tests:**
  `test/integration/admission/OrderDataWireStability.t.sol`
  (typehash literal pins, struct-decode round-trip, NatSpec discipline,
  view-param + storage-mapping-key naming).

## Settler invariants (admission)

### INV-PREMIUM-TOKEN-NONZERO

- **Statement:** `BaseSettler._validateOrderCommon` rejects any order
  with `orderData.premiumToken == address(0)`. A cPT holder signing
  `premiumToken == 0` previously admitted at openFor (vacuous
  src/dst-vs-premium mismatch checks) and would have forced downstream premium
  accounting to interact with `IERC20(0)`. Closing the admission boundary keeps
  the atomic fill from reaching that invalid premium path.
- **Throw site:** `src/BaseSettler.sol::_validateOrderCommon` reverts
  `Settler__ZeroPremiumToken()`.
- **Tests:**
  `test/integration/admission/PremiumTokenZeroAdmission.t.sol`.

### INV-OPENDEADLINE-ADMISSION-CEILING

- **Statement:** Past `orderData.openDeadline`, no path may transition
  an order from status `None` to any non-`None` status. Reading B
  unification: `openDeadline` is the cPT-holder-signed signature-staleness
  ceiling and bounds every `None` admission, whether via `openFor`,
  on-chain `open`, direct-fill (`fill` at status `None`), or
  `resolve` / `resolveFor` before an order has been opened.
  Already-`Opened` resolver calls skip only the open-deadline gate; they do not
  transition state and still enforce non-time envelope binding, fillDeadline,
  and terminal/Closing exclusions.
- **Throw site:** `BaseSettler.openFor`, on-chain `open`, `_validateOrderForFill`,
  and `_resolveDecodedOrder` enforce `Settler__OpenAfterOpenDeadline()` when
  `block.timestamp > orderData.openDeadline` for a `None` admission path.
- **Tests:**
  `test/integration/admission/OpenDeadlineDirectFill.t.sol`,
  `test/audit-findings/resolve-admission-parity/ResolveAdmissionParity.t.sol`,
  `test/invariant/handlers/OpenDeadlineHandler.sol`,
  `test/invariant/failOnRevert/OpenDeadlineAdmission.t.sol`,
  `test/invariant/continueOnRevert/OpenDeadlineAdmission.t.sol`.

### INV-DIRECT-FILL-CPT-HOLDER-SIG

- **Statement:** Direct-fill admission at status `None` requires a valid
  EIP-712 cPT-holder signature over `orderDigest`. Atomic `Settler.fill(...)` takes
  that signature from the atomic envelope `cptHolderSig`. The inner payload's
  `cptHolderSig` slot is ignored on supported paths.
  This mirrors the `openFor` admission contract — both paths verify the same
  EIP-712 signature against `orderData.user` on the canonical
  `orderDigest`. Already-`Opened` orders skip the signature check because
  admission already established the order, while fill/cancel/expiry/reclaim
  consumers still re-decode canonical `OrderData` from the single-envelope
  `originData` payload and bind it back to `orderId`. Verification uses OpenZeppelin
  `SignatureChecker.isValidSignatureNow`, so ERC-1271 smart-account cPT holders are
  supported alongside EOA cPT holders.
- **Throw site:** `src/BaseSettler.sol::_validateOrderForFill` calls
  `_requireCptHolderSig(orderData.user, orderDigest, cptHolderSig)` which reverts
  `Settler__BadUserSignature()` on a failed check — the same selector used
  by `openFor`'s cPT-holder-sig gate, since the two admission paths verify the
  same EIP-712 signature.
- **Tests:**
  `test/integration/admission/DirectFillCptHolderSignature.t.sol`,
  `test/invariant/handlers/DirectFillCptHolderSigHandler.sol`,
  `test/invariant/failOnRevert/DirectFillCptHolderSig.t.sol`,
  `test/invariant/continueOnRevert/DirectFillCptHolderSig.t.sol`.

### INV-OPENED-ORDERS-FILLABLE-UNTIL-FILLDEADLINE

- **Statement:** Once an order is `Opened`, it remains fillable via
  direct `fill`, helper-driven paths, and resolvable through
  `resolve` / `resolveFor` until `fillDeadline`, regardless of
  `openDeadline`. Helpers compute the canonical `orderId` locally via
  `LibSettlerHashing.computeOrderDigestMemory` (no `resolve` round-trip) and
  skip `openFor` when the cached `orderStatus` is `Opened`, so a helper-driven
  fill past `openDeadline` cannot revert at the helper's `openFor` call. The
  `fillDeadline` gate at `BaseSettler.fill` bounds every subsequent fill of an
  Opened order; the resolver path mirrors that deadline and rejects terminal or
  Closing statuses.
- **Throw site:** Structural. `src/BaseSettler.sol::fill` reverts
  `Settler__FillAfterDeadline()` when
  `block.timestamp > orderData.fillDeadline`;
  `src/EvcRolloverAdapter.sol::_runSettlementCommon` and
  `src/BaseFiller.sol::_runSettlement` skip `openFor` on Opened
  orders. The invariant is the absence of an admission-side gate on
  the fill path of an Opened order.
- **Tests:**
  `test/integration/admission/OpenDeadlineDirectFill.t.sol`,
  `test/integration/admission/EvcAdapterOpenForIdempotent.t.sol`,
  `test/integration/admission/BaseFillerOpenForIdempotent.t.sol`,
  `test/invariant/handlers/OpenedOrdersFillableUntilFillDeadlineHandler.sol`,
  `test/invariant/failOnRevert/OpenedOrdersFillableUntilFillDeadline.t.sol`,
  `test/invariant/continueOnRevert/OpenedOrdersFillableUntilFillDeadline.t.sol`.

### INV-PARAMS-SETTLER-PIN-MIRROR

- **Statement:** `BaseSettler._validateOrderCommon` rejects any order
  whose `orderData.rolloverParams.settler != orderData.settler`.
  Pattern-consistent with the existing `srcCstToken` and `dstCstToken`
  mirror cross-checks against `orderData.rolloverParams`. Closes the
  cPT-holder self-grief class where a non-canonical inner
  `rolloverParams.settler` admits at openFor and reverts every
  subsequent fill at the rolloverContract's `_validateRolloverPreflight`. The
  rolloverContract-side check ([[INV-PARAMS-SETTLER-PIN]]) remains as defence
  in depth on runtime-tampered `params` that pass the upstream
  binding.
- **Throw site:** `src/BaseSettler.sol::_validateOrderCommon` reverts
  `Settler__RolloverParamsSettlerMismatch()`.
- **Tests:**
  `test/integration/admission/RolloverParamsSettlerMirror.t.sol`,
  `test/invariant/handlers/ParamsSettlerPinMirrorHandler.sol`,
  `test/invariant/failOnRevert/ParamsSettlerPinMirror.t.sol`,
  `test/invariant/continueOnRevert/ParamsSettlerPinMirror.t.sol`.

### INV-ROLLOVER-FILL-AMOUNT-RANGE

- **Statement:** `BaseSettler._validateRolloverBeforeExecution` enforces a universal
  admission gate `payload.fillAmount != 0` and
  `payload.fillAmount <= orderData.orderSize` on both exact and partial fills
  (zero fills and overfills are never legal at admission).
- **Throw sites:** `src/BaseSettler.sol::_validateRolloverBeforeExecution` reverts
  `Settler__RolloverAmountOutOfBounds(orderSize, fillAmount)` for
  zero fills and overfills.
- **Tests:**
  `test/integration/admission/ExactFillSizeBinding.t.sol`,
  `test/invariant/handlers/CompromisedSettlerDispatchHandler.sol`,
  `test/invariant/CompromisedSettlerDispatchInvariantBase.sol`,
  `test/invariant/failOnRevert/ExactFillSizeBinding.t.sol`,
  `test/invariant/continueOnRevert/ExactFillSizeBinding.t.sol`.

### INV-EXACT-FILL-SIZE-BINDING

- **Statement:** `ExactSettler._validateRolloverBeforeExecutionForMode` enforces
  `payload.fillAmount == orderData.orderSize` when `!orderData.allowUnderfill`
  (strict-exact admission). The paired `BaseSettler._finalizeVerifiedRollover`
  check asserts `srcLeftover == 0` post-execution as defence-in-depth — the
  rolloverContract contract must consume the full signed order on a strict-exact leg.
  PartialSettler has no order-size-equality invariant; it relies on
  [[INV-ROLLOVER-FILL-AMOUNT-RANGE]] plus aggregate partial accounting.
  Closes the F-01 dust-fill grief class where an attacker latches an exact
  `!allowUnderfill` order with a 1-wei fill, blocking honest fillers from
  completing.
- **Throw sites:** `src/ExactSettler.sol::_validateRolloverBeforeExecutionForMode` reverts
  `Settler__ExactFillRequiresFullOrderSize(orderSize, fillAmount)`.
  `src/BaseSettler.sol::_finalizeVerifiedRollover` reverts
  `Settler__ExactNoUnderfillRolloverContractReturnedLeftover(srcLeftover)` if the
  rolloverContract reports nonzero `srcLeftover` on a `!allowUnderfill` leg.
- **Tests:**
  `test/integration/admission/ExactFillSizeBinding.t.sol`,
  `test/invariant/handlers/CompromisedSettlerDispatchHandler.sol`,
  `test/invariant/CompromisedSettlerDispatchInvariantBase.sol`,
  `test/invariant/failOnRevert/ExactFillSizeBinding.t.sol`,
  `test/invariant/continueOnRevert/ExactFillSizeBinding.t.sol`.

### INV-PARTIAL-AGGREGATE-SRC-CONSUMED

- **Statement:** Partial-mode order-level `Settled` promotion requires
  `totalSrcCstConsumed >= orderSize` AND `totalDstCstEscrowed == 0`. Per-fill
  admission rejects any fill whose `fillAmount` would push cumulative srcCST
  consumption above `orderSize`. A single under-sized partial fill that drains
  only its sub-filler escrow MUST NOT terminalize the order. When aggregate
  `totalSrcCstConsumed < orderSize` but `totalDstCstEscrowed == 0` (all live
  dstCST escrow drained), cPT-holder `cancel` routes to `Cancelled` — canceling the
  unfilled remainder without requiring aggregate consumption to reach
  `orderSize`.
- **Throw sites:** `src/PartialSettler.sol::_validateRolloverBeforeExecutionForMode`,
  `_recordRolloverAccountingForMode`, `_settlePaidRolloverRecord`, `_cancelOrderForMode`.
- **Tests:** `test/unit/settler/PartialFillFinality.t.sol`.

### INV-PARTIAL-SUBFILLER-KEYING

- **Statement:** `PartialSettler` partial-fill accounting keys all four
  per-slot mappings (`fillerRollovers`, `fillerDstCstResidual`,
  `fillerDestination`, `fillerSettled`) by the triple
  `(orderDigest, msg.sender, subFiller)`. Shared filler contracts
  (`BaseFiller`, `EvcRolloverAdapter`) derive `subFiller` from the
  upstream caller identity so multiple users routing through the same
  filler proxy each occupy an independent slot. Direct-EOA fills accept
  `subFiller == bytes32(0)` and self-key via
  `bytes32(uint256(uint160(msg.sender)))` substitution inside
  `LibFillerAuth.decodePayload`. `participantCount` counts unique
  `(filler, subFiller)` PAIRS. The `FillerAuth` EIP-712 typehash rotates
  to include `subFiller`, scoping a routed delegation signature to a
  single sub-filler slot. Closes the F-02 architectural mismatch
  between shared-filler product semantics and Settler's per-msg.sender
  accounting.
- **Throw sites:** `src/PartialSettler.sol::_validateRolloverBeforeExecutionForMode`
  reverts `Settler__PremiumAlreadyFiredRollover()` (L240) when a
  `(filler, subFiller)` slot's premium has already fired, and
  `Settler__AlreadyFilled()` (L243) on a repeat rollover for the same slot.
  `_loadPremiumPaymentContext` reverts `Settler__NoRolloverLegForFiller()`
  (L320) or `Settler__FillerAlreadySettled()` (L326) per the per-slot lookup.
- **Tests:** `test/integration/settler/PartialSubFillerKeying.t.sol`,
  `test/invariant/handlers/PartialSubfillerKeyingHandler.sol`,
  `test/invariant/failOnRevert/PartialSubfillerKeying.t.sol`,
  `test/invariant/continueOnRevert/PartialSubfillerKeying.t.sol`.

### INV-SUBFILLER-PROVENANCE

- **Statement:** Shared filler contracts (`BaseFiller`,
  `EvcRolloverAdapter`) MUST derive `subFiller` from caller identity
  (`bytes32(uint256(uint160(msg.sender)))` for BaseFiller;
  `bytes32(uint256(uint160(job.subaccount)))` for EvcRolloverAdapter)
  and MUST NOT accept caller-supplied `subFiller`. Direct-EOA paths
  accept `subFiller == bytes32(0)` which the decoder substitutes with
  `bytes32(msg.sender)` so direct-EOA self-keys to its own address. The
  `subFiller` field on every `BaseFiller`/`EvcRolloverAdapter`-built
  `fillerData` blob therefore matches the contract that called
  `Settler.fill` on each user's behalf.
- **Throw sites:** No new error sites; provenance is structural — the
  encoder threads the derived value and the decoder substitutes the
  caller default. Misuse manifests as an `[ASSUMPTION-DEP]` integration
  bug at routing layers above the Settler boundary.
- **Tests:** `test/integration/settler/PartialSubFillerKeying.t.sol`.

### INV-FSM-TERMINAL-WRITE-COMPLETE

- **Statement:** Every canonical terminal path on the order FSM writes a
  terminal `orderStatus` AND emits the corresponding `Order*` lifecycle event.
  Specifically:
    1. Exact-mode in-frame settlement promotes the order to `Settled` and emits
       `OrderSettled`.
    2. Partial-mode in-frame settlement promotes the order to `Settled` and emits
       `OrderSettled` IFF the last filler drains `totalDstCstEscrowed` to zero,
       aggregate srcCST consumption has reached `orderSize`, and the current
       status is not hard-terminal; paid settlement rejects `Cancelled`,
       `Settled`, and `Expired`, so post-deadline unpaid cleanup belongs to
       `reclaim`.
       `allowUnderfill` permits per-leg short consumption/refund; it does not
       make partial order-level finality occur below `orderSize`.
    3. `markExpired` promotes the order to `Expired` and emits `OrderExpired`.
    4. `cancel` promotes the order to `Cancelled` (no fills present) or
       `Closing` (partial-mode with live escrow) and emits `OrderCancelled` or
       `OrderClosing` respectively.
    5. `reclaim` terminalization is mode-aware. Exact mode (and any partial
       reclaim from a non-`Closing` status) writes `Expired` and emits
       `OrderExpired` on the first unpaid reclaim. A cPT-holder-cancelled
       partial order in `Closing` stays `Closing` with no terminal event while
       live escrow remains, and finalizes as `Cancelled` (emitting
       `OrderCancelled`, never `OrderExpired`) when the final residual drains
       through reclaim — converging with the paid-settlement `Closing ->
       Cancelled` path. `Closing` can therefore drain through settle for paid
       slots or reclaim for unpaid slots until escrow is gone. `reclaim` never
       writes `Cancelled` while escrow
       remains, because `Cancelled` blocks reclaim and would brick the
       remaining unpaid slots. An already-`Expired` order does not re-emit.
  Closes the heri F-09 / F-15 FSM-observability gaps: integrators and indexers
  reading `orderStatus(orderId)` or subscribing to lifecycle events observe a
  canonical terminal code for every fully-resolved order, regardless of mode
  or recovery path.
- **Throw sites:** structural — write+emit pairs at
  `src/ExactSettler.sol::_settlePaidRolloverRecord` /
  `_finalizeReclaimStatusForMode`,
  `src/PartialSettler.sol::_settlePaidRolloverRecord` /
  `_finalizeReclaimStatusForMode`,
  `src/BaseSettler.sol::reclaim` (delegates terminalization to
  `_finalizeReclaimStatusForMode`) / `markExpired` / `cancel`.
- **Tests:** `test/unit/settler/PartialFillFinality.t.sol`
  (partial settle + cancel + terminal promotion),
  `test/integration/lifecycle/CancelOrderTypehashStability.t.sol` (cancel routing),
  `test/integration/lifecycle/ReclaimTerminalStatus.t.sol`,
  `test/integration/settler/AsyncPremiumOptIn.t.sol`
  (`test_partialCancel_finalUnpaidResidualReclaim_terminalizesCancelled`,
  `test_partialCancel_nonFinalResidualReclaim_staysClosing`, mixed-drain
  ordering, and the non-cancelled Expired regression).

### INV-EXACT-FILLER-IDENTITY

- **Statement:** `ExactSettler._settlePaidRolloverRecord` asserts that the settlement
  filler selected by atomic-fill matches the recorded `exactRec.filler` from
  the rollover record. The argument is identity-asserting only; it is NOT used
  as a key for recipient resolution. Recipient resolution remains keyed by
  `$.rolloverAccounting[orderDigest].settlementDestination`, which preserves
  helper-keyed flows (`BaseFiller`, `EvcRolloverAdapter`) where the recorded
  filler is the helper contract address and the stored destination is the
  upstream user subaccount. The lookup is keyed directly off the order's
  rollover accounting record and any mismatching-arg path reverts before token
  movement. The
  previously-unused `address(0)` fallback in `_settlePaidRolloverRecord` is dropped
  as redundant with
  `INV-FILLER-DESTINATION-NONZERO` (the universal admission gate at
  `BaseSettler._validateRolloverBeforeExecution` rejects `payload.destination == address(0)`,
  so `$.rolloverAccounting[orderDigest].settlementDestination` is non-zero after any
  successful rollover record write).
- **Throw site:** `src/ExactSettler.sol::_settlePaidRolloverRecord` reverts
  `Settler__ExactFillerMismatch(recorded, supplied)` when
  `filler != exactRec.filler`.
- **Tests:** `test/unit/settler/AtomicFill.t.sol`,
  `test/unit/settler/PartialFillFinality.t.sol`
  (atomic settlement and cancel terminal paths on partial polarity),
  `test/invariant/handlers/ExactFillerIdentityHandler.sol`,
  `test/invariant/failOnRevert/ExactFillerIdentity.t.sol`,
  `test/invariant/continueOnRevert/ExactFillerIdentity.t.sol`.

### N-INV-FILLER-DESTINATION-NONZERO

- **Statement:** For every successful ROLLOVER record write,
  `rolloverAccounting[orderDigest].settlementDestination` (exact mode) and
  `fillerDestination[orderDigest][filler][subFiller]` (partial mode) is set
  on the record-write path, is never `address(0)` after the write completes,
  and is never overwritten with a different value by any subsequent code
  path. Equivalently: the slot is "set-once and non-zero" across the order's
  lifetime. Partial mode rejects repeat fills for the same `(orderDigest,
  filler, subFiller)` triple before the record writer is reached, and no
  settle / refund / reclaim / cancel path clears or rotates the slot.
- **Why:** Closes a permissionless-misrouting class. The universal admission
  gate at `BaseSettler._validateRolloverBeforeExecution` rejects
  `payload.destination == address(0)` before any token movement, and the
  *only* writers are `_recordRolloverAccountingForMode` in
  `ExactSettler.sol` (L226, writes `rec.settlementDestination`) and
  `PartialSettler.sol` (L276, writes `fillerDestination`). This invariant
  was previously cited only as a parenthetical inside
  `INV-EXACT-FILLER-IDENTITY` and as inline `// INV-FILLER-DESTINATION-NONZERO`
  comments at the `_loadPremiumPaymentContext` / `_settlePaidRolloverRecord` read sites,
  with no dedicated ledger entry. Any future writer that adds a `delete`,
  a recipient-override path, or a fallback overwrite would silently
  reintroduce the F-07 misrouting class.
- **Throw site:** structural — only `_recordRolloverAccountingForMode` writes the slot,
  the value is `payload.destination`, and the zero-destination admission gate
  at `BaseSettler._validateRolloverBeforeExecution` blocks zero values before the writer
  is reached.
- **Tests:**
  `test/invariant/handlers/FillerDestinationHandler.sol`,
  `test/invariant/failOnRevert/FillerDestination.t.sol`
  (`invariant_fillerDestination_setOnceNeverZero`),
  `test/invariant/continueOnRevert/FillerDestination.t.sol`
  (loose-mode companion).

### N-INV-ROLLOVER-CONTRACT-OF-IMMUTABLE-AFTER-SET

- **Statement:** For every `user` for which `CorkRolloverContractFactory.rolloverContractOf[user]
  != address(0)` at some block N, the value is identical at every block ≥ N.
  The factory has exactly one writer (`deployRolloverContract`, L283), it pre-checks
  `rolloverContractOf[owner] != 0` before writing (L287) and writes both slots at
  L298-299, and no other code path
  writes or clears the slot. Corollary: the structurally-mirrored
  `isDeployedRolloverContract[rolloverContract]` slot is also set-once and never cleared once
  flipped — both `rolloverContractOf` and `isDeployedRolloverContract` move in lockstep inside
  `deployRolloverContract`. One rolloverContract address per user for the factory's lifetime.
  The address is deterministic CREATE2 CWIA: `predictRolloverContractOf(user)` uses the
  same owner-derived salt and `owner ‖ factory ‖ erc7484Registry` trailer as deployment.
  The factory nonce and prior deployment order MUST NOT affect the address:
  prediction must match deployment, unrelated owners deployed first must not move
  a target owner's address, distinct owners must not collide under the same
  factory inputs, and same owner + identical factory + identical implementation
  + identical live registry must predict the same address independent of
  `chainid`. The registry remains part of the CWIA initcode, so registry changes
  intentionally change predictions for undeployed owners and must be documented.
- **Why:** Codifies the "one rollover contract per cPT holder" architectural property that
  downstream invariants (`INV-USER-IS-ROLLOVER_CONTRACT-OWNER`, `INV-ROLLOVER_CONTRACT-OWNER-IMMUTABLE`)
  implicitly rely upon. Catches a bug class where a future refactor adds a
  re-bind path (e.g., "redeploy with new attesters", "migrate user to v2
  rolloverContract"), a `delete` on `cancel`-equivalent, or a second `deployRolloverContract`
  slipping past the guard under a feature flag. Any of those would silently
  invalidate the CWIA-owner ↔ rolloverContract mapping that the rollover order
  admission gate trusts. It also catches nonce-based CREATE deployment for
  per-owner identity contracts, which can be locally access-control sound while
  still breaking cross-chain address identity used by operators or SDKs.
- **Throw site:** structural — only `deployRolloverContract` writes either slot, the
  pre-write guard reverts `CorkRolloverContractFactory__AlreadyDeployed(owner)`
  for any re-attempt, and no clearer or rewriter exists in `CorkRolloverContractFactory.sol`.
- **Tests:**
  `test/invariant/handlers/FactoryRolloverContractOfHandler.sol`,
  `test/invariant/failOnRevert/FactoryRolloverContractOf.t.sol`
  (`invariant_rolloverContractOf_setOnceImmutable`),
  `test/invariant/continueOnRevert/FactoryRolloverContractOf.t.sol`
  (loose-mode companion),
  `test/unit/factory/CorkRolloverContractFactoryDeterministic.t.sol`.

### N-INV-HELPER-FUNDING-RESTORES-SNAPSHOTS

- **Statement:** Every successful `BaseFiller.execute`,
  `EvcRolloverAdapter.execute`, or `EvcRolloverAdapter.executePartial` restores
  the helper's `srcCst` and `premiumToken` balances to their pre-funding
  snapshots and leaves zero helper-to-settler allowance for both job tokens.
- **Why:** Helper execution temporarily pulls filler funding into a contract
  that also approves a mode-specific settler. Snapshot restoration and
  allowance clearing prevent a successful helper call from retaining token
  residue or standing spend authority after settlement completes.
- **Throw site:** `src/BaseFiller.sol::execute` snapshots balances via
  `_pullFunding`, drives settlement, and calls `_refundTails` after the
  settlement path clears settler allowances. `src/EvcRolloverAdapter.sol::execute`
  and `executePartial` mirror the same sequence for the EVC entrypoints.
- **Tests:**
  `test/invariant/handlers/HelperFundingRestoresSnapshotsHandler.sol`,
  `test/invariant/failOnRevert/HelperFundingRestoresSnapshots.t.sol`,
  `test/invariant/continueOnRevert/HelperFundingRestoresSnapshots.t.sol`.

### N-INV-LIFECYCLE-ORIGINDATA-DIGEST-BINDING

- **Statement:** Every lifecycle path that consumes ERC-7683 `originData` decodes
  exactly one canonical `GaslessCrossChainOrder`, then decodes Cork `OrderData`
  from `order.orderData`, and the re-derived Settler domain digest must equal
  the `orderId` being mutated. Admitted `originData` is set-once per digest in
  the invariant ghost state and cannot be replaced by tuple-shaped or
  mismatched payloads.
- **Why:** ERC-7683 observability should expose the signed order envelope once,
  while Cork economics remain bound inside `GaslessCrossChainOrder.orderData`.
  Accepting redundant `(GaslessCrossChainOrder, OrderData)` tuples would create
  a second body that can drift from the cPT-holder-signed payload.
- **Throw site:** `BaseSettler._decodeBoundOriginData` decodes the single
  envelope, rejects non-canonical ABI bytes by re-encoding the envelope, rejects
  bad Cork `orderDataType` via `LibRolloverOrder`, and reverts
  `Settler__OrderIdMismatch` if the embedded `OrderData` does not hash to the
  lifecycle `orderId`.
- **Tests:**
  `test/invariant/handlers/OriginDataHandler.sol`,
  `test/invariant/failOnRevert/OriginData.t.sol`,
  `test/invariant/continueOnRevert/OriginData.t.sol`.

### N-INV-FACTORY-QUEUE-NONCE-SALT-UNIQUE

- **Statement:** For every factory-deployed rolloverContract, each successful
  `queueFactoryDefaultTrustConfig` or `queueTrustConfig` consumes exactly one
  per-rolloverContract queue nonce and derives the timelock salt as
  `keccak256(abi.encode(rolloverContract, nonce))`. The next
  successful queue for the same rolloverContract must use the next nonce, so timelock
  operation ids are never reused even when a pending config is overwritten or
  canceled before the next queue.
- **Why:** Per-rolloverContract trust-config queues are overwriteable. Reusing a salt
  would let a new queue collide with a prior timelock operation id, breaking
  the factory mirror's one-live-op model and making cancel/apply behavior
  depend on stale timelock state instead of the latest owner intent.
- **Throw site:** structural — `_scheduleTrustConfig` reads
  `queueNonce[rolloverContract]`, computes `salt = keccak256(abi.encode(rolloverContract,
  nonce))`, schedules the timelock operation, then increments
  `queueNonce[rolloverContract]` while writing the pending mirror for that salt.
- **Tests:**
  `test/invariant/handlers/FactoryQueueNonceSaltHandler.sol`,
  `test/invariant/failOnRevert/FactoryQueueNonceSalt.t.sol`,
  `test/invariant/continueOnRevert/FactoryQueueNonceSalt.t.sol`.


### N-INV-EXACT-RESIDUAL-RECONCILES-TO-FILL-RECORD

- **Statement:** In exact mode, `exactFill[orderDigest].dstCstProduced` is
  written once by the rollover record and never changed. The live unpaid
  residual for an exact order is bounded by that produced amount, equals the
  produced amount after an async rollover before premium settlement, and is
  zero after premium settlement or reclaim. Across observed exact orders, the
  sum of live unpaid residuals equals the ExactSettler's dstCST balance.
- **Why:** Exact async premium intentionally parks dstCST between rollover and
  premium/reclaim. Reconciliation binds that parked balance to the immutable
  fill record and catches future paths that double-count, overwrite produced
  amounts, forget to zero residual on payout, or leave stranded dstCST after
  reclaim.
- **Throw site:** structural — `ExactSettler._recordRolloverAccountingForMode` records
  `dstCstProduced` and initializes residual, `_settlePaidRolloverRecord` zeros the
  residual before releasing dstCST to the recorded destination, and
  `_clearReclaimableResidualForMode` zeros the residual before returning unpaid dstCST to
  the rolloverContract.
- **Tests:**
  `test/invariant/handlers/ExactResidualReconciliationHandler.sol`,
  `test/invariant/failOnRevert/ExactResidualReconciliation.t.sol`,
  `test/invariant/continueOnRevert/ExactResidualReconciliation.t.sol`.
