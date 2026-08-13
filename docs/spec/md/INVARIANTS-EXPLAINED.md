# Cork Rollover Invariants — Explained

> _Supplementary protocol reference. The canonical bundle for AI auditors is [`docs/agent-context/`](../../agent-context/README.md). Code in `src/` is the source of truth when docs disagree._

This is the long-form companion to [`docs/INVARIANTS.md`](../../INVARIANTS.md).
Where the ledger is one-line-per-invariant (Statement + Throw site + Tests),
this document expands each entry into a per-invariant section answering:
**what** is asserted, **why** it matters, **how** the code enforces it, and
**what attack opens up** if it breaks. Every `### CODE — <title>` heading
matches a ledger entry of the same `CODE`. Cross-references inside the
**Related invariants** lists use the same `CODE` form.

Symbol names are authoritative; line numbers are best-effort and may drift.

The clusters below mirror the ledger's H2 headings.

---

## Cluster: Filler / Settler invariants

### BS-ST-20 — canonical FSM transitions

**Statement**

`orderStatus[orderId]` only transitions on the canonical state-machine paths.
Open paths (`open` / `openFor`) require the prior status to be `None`. Fill
paths require status `Opened` (partial) or `Opened`/`None` (exact, the
fill-without-openFor variant). Settle / refund / cancel paths require
non-terminal status.

**Motivation**

The Settler's per-order status word is the single source of truth for fill-time
gating. Every state-mutating entrypoint must consult `_isHardTerminal` /
`_blocksRollover` predicates before progressing. Without a strict FSM gate, a
cPT holder could double-fill a finalised order, or a settle path could be replayed
after refund.

**Mechanism**

Predicates `_isHardTerminal` (rejects Settled / Expired / Cancelled) and
`_blocksRollover` (additionally rejects Closing) at
`src/ExactSettler.sol and src/PartialSettler.sol` are the canonical FSM gates. Every state-mutating
entrypoint guards against the polarity-correct predicate; the ROLLOVER fill
path uses `_blocksRollover`, PREMIUM/internal settlement uses `_isHardTerminal`,
and refund / reclaim / cancel guard their own status windows.

**Threat without**

Double-pay of dstCST residual to two distinct destinations; orphaned per-filler
residual that no longer drains via either in-frame premium settlement or `reclaim` (breach of
INV-DST-CST-REACHABLE); cPT-holder-driven cancel of a partially-paid order leaving
fillers unpaid.

**Defense site(s)**

- `src/ExactSettler.sol and src/PartialSettler.sol` (`_isHardTerminal`, `_blocksRollover`)
- `src/ExactSettler.sol and src/PartialSettler.sol` (`openFor` status gate via `_blocksRollover`)
- `src/ExactSettler.sol and src/PartialSettler.sol` (`_handleRolloverFill` entry gate)
- `src/ExactSettler.sol and src/PartialSettler.sol` (`_handlePremiumFill` entry gate)
- `src/ExactSettler.sol and src/PartialSettler.sol` (exact-mode settle)
- `src/ExactSettler.sol and src/PartialSettler.sol` (reclaim status window)
- `src/ExactSettler.sol and src/PartialSettler.sol` (cancel)

**Related invariants**

- INV-NEW-POLARITY-GATE
- INV-NEW-POLARITY-ISOLATION
- BS-FN-045
- INV-DST-CST-REACHABLE
- N-INV-ROLLED-MONOTONE-AND-BOUNDED

---

### INV-NEW-POLARITY-GATE — `isPartial` read once at fill entry

**Statement**

`bool isPartial = orderData.allowPartialFills` is read once at fill entry,
BEFORE any fill-record state write. The rest of `fill` commits to one storage
layout for the duration of the call.

**Motivation**

Polarity must be sampled exactly once into a stack local so the same boolean
drives every subsequent branch. A second re-read of `allowPartialFills` after a
state write would create a window for a hostile post-condition to flip
polarity mid-call and split a single fill across both storage layouts.

**Mechanism**

Structural — `_handleRolloverFill` and `_handlePremiumFill` accept
`bool isPartial` as a function parameter sampled once by the dispatcher in
`fill`, then branch on it for every subsequent write. No runtime check exists;
the property holds by code shape.

**Threat without**

A single order accumulating residual on both
`fillerDstCstResidual[orderId][filler]` AND `dstCstResidual[orderId]`, breaking
INV-DST-CST-REACHABLE because the settle path branches on polarity and would
touch only one of the two slot families.

**Defense site(s)**

- `src/ExactSettler.sol and src/PartialSettler.sol` (dispatcher branch on `phase` after polarity sample)
- `src/ExactSettler.sol and src/PartialSettler.sol` (`_writePartialFillRecord` / `_writeExactFillRecord`
  branch under structural `isPartial`)

**Related invariants**

- BS-ST-20
- INV-NEW-POLARITY-ISOLATION
- BS-FN-045

---

### INV-NEW-POLARITY-ISOLATION — disjoint per-polarity slots

**Statement**

Partial-mode and exact-mode write to disjoint storage slots. Partial writes
`fillerRollovers`, `totalDstCstEscrowed`, `participantCount`,
`fillerDstCstResidual`. Exact writes `exactFill`, `dstCstResidual`. Neither
reads nor writes the other's slots.

**Motivation**

If the two mode-specific writers shared a slot, internal settlement and `reclaim` — both
of which branch on polarity (BS-FN-045) — would drain only one half of the
actual residual; the other half would be unreachable.

**Mechanism**

Structural — `_writePartialFillRecord` (`src/ExactSettler.sol and src/PartialSettler.sol`) and
`_writeExactFillRecord` (`src/ExactSettler.sol and src/PartialSettler.sol`) write disjoint slot
families. The internal settlement / reclaim drainers
mirror that split by reading the slot family that the polarity flag selects.

**Threat without**

Stuck residual under one polarity that the other-polarity drain path skips;
failure of INV-DST-CST-REACHABLE.

**Defense site(s)**

- `src/ExactSettler.sol and src/PartialSettler.sol` (partial writer)
- `src/ExactSettler.sol and src/PartialSettler.sol` (exact writer)
- `src/ExactSettler.sol and src/PartialSettler.sol` (settle drain — partial / exact branches)
- `src/ExactSettler.sol and src/PartialSettler.sol` (reclaim drain — partial / exact branches)

**Related invariants**

- INV-NEW-POLARITY-GATE
- BS-FN-045
- INV-DST-CST-REACHABLE
- N-INV-PARTIAL-RESIDUAL-RECONCILES-TO-TOTAL

---

### INV-DSTCST-FLOOR — filler-supplied `minDstPerSrc`

**Statement**

Filler-supplied `minDstPerSrc` (1e18-scaled, calldata-only) enforces
`dstProduced >= mulDiv(srcConsumed, minDstPerSrc, 1e18)` after the rollover
hooks settle. `0` opts out (status quo behaviour).

**Motivation**

The filler can declare a minimum dst-mint rate at fill time. Without a floor a
hostile cPT holder could chain midHooks that produced near-zero dstCST while
still collecting the filler's srcCST + premium. The floor sits in the 8th
tuple slot of `fillerData` (filler self-binding, NOT signed by the cPT holder).

**Mechanism**

ROLLOVER branch of `Settler.fill` computes
`required = mulDiv(srcConsumed, payload.minDstPerSrc, 1e18)` and reverts
`Settler__InsufficientMintRate(required, dstProduced)` when the floor is
breached. The check fires BEFORE any persistent fill-record write so a breach
leaves no partial state on the failure path.

**Threat without**

Hostile-cPT-holder-with-zero-`minSharesOut`: the filler over-pays for near-zero dst
output and has no on-chain rescue path.

**Defense site(s)**

- `src/ExactSettler.sol and src/PartialSettler.sol` (`required` computation + revert)

**Related invariants**

- M-08
- F-PUSH
- INV-DST-CST-RECONCILES

---

### M-08 — premium Ceil floor

**Statement**

Premium obligation is `Ceil(dstCstProduced × minPremiumPerShare / 1e18)`. The
Ceil-divide rounds toward the protocol so the filler's obligation rounds up,
never down.

**Motivation**

A floor-divide here would let a filler atomise production into 1-wei dstCST
chunks and pay zero premium each. Ceil rounding closes that arbitrage so a
positive `dstCstProduced` always carries strictly positive premium.

**Mechanism**

PREMIUM branch of `Settler.fill` computes
`requiredPremium = mulDiv(produced, orderData.minPremiumPerShare, 1e18, Math.Rounding.Ceil)`
and reverts `Settler__PremiumExceedsCap(cap, required)` when the required
premium exceeds the filler-supplied cap. The premium transfer is then measured
against the rolloverContract balance delta and reverts `Settler__PremiumDeliveryMismatch`
on delivery shortfall.

**Threat without**

Premium-bypass: filler exits the rollover without funding the cPT holder's
premium leg; the cPT holder recovers no premium for `orderSize` consumed.

**Defense site(s)**

- `src/ExactSettler.sol and src/PartialSettler.sol` (Ceil floor + revert)

**Related invariants**

- M-11
- INV-PREMIUM-FIRED-MONOTONIC
- INV-DSTCST-FLOOR

---

### M-11 — premium-fire one-shot per `(orderDigest, filler[, subFiller])`

**Statement**

Premium may fire at most once per `(orderDigest, filler[, subFiller])`.
Authority lives **Settler-side**: atomic `fill` sets `rec.premiumFired` /
`exactRec.premiumFired` inside one frame; any failure reverts the latch with
the frame (`INV-PREMIUM-HOOK-REVERT-CASCADES`). A second `fill` on the same
slot reverts at Settler entry. RolloverContract `premiumFiredFor[orderDigest][filler][subFiller]`
is parallel local replay protection that commits only on successful atomic
completion. Factory `_originatingSettler` is the settler-latch — separate
from premium replay.

**Motivation**

Settler-side gating prevents double premium credit across frames. RolloverContract-side
latching prevents same-tx re-entry into `_handlePhasePremium` on the success
path (e.g. hostile premium hook calling back through the factory). There is no
catch-and-park path: hook revert aborts the entire fill.

**Mechanism**

Settler-side: `Settler._handlePremiumFill` flips the per-record bit
BEFORE the factory dispatch (CEI), reverting `Settler__PremiumAlreadyFired`
on a second fire. RolloverContract-side: `CorkRolloverContract._handlePhasePremium` reads
`premiumFiredFor[digest][filler][fillContext.subFiller]`, reverts
`CorkRolloverContract__PremiumAlreadyFiredForFiller`, and flips the latch on resolved
`fillContext.subFiller` (wire-zero → self-key per `LibFillerAuth`) before hooks run.
The factory-side `_originatingSettler` slot
(`src/CorkRolloverContractFactory.sol:162`, set/check at `:340-349`) is the
settler-latch that pins `fillContext.originSettler == msg.sender` across phases.

**Threat without**

Settler-side gate absent: catch-path premium double-fire via hostile cPT holder
arranging a reverting rolloverContract frame.
RolloverContract-side gate absent: same-tx rolloverContract re-entry from a hostile premium
hook within a successful frame.
Either: off-chain accounting divergence; possible duplicate cPT-holder
`orderSize` consumption depending on the cPT-holder hook chain.

**Defense site(s)**

- `src/BaseSettler.sol` atomic-fill frame — per-record `premiumFired` commits with
  rolloverContract dispatch or reverts entirely (`INV-ATOMIC-FILL-CANONICAL`)
- Factory policy-gate reverts propagate through the atomic frame and roll back
  latch + premium pull together ([[INV-SETTLER-APPROVED]])
- `CorkRolloverContract._handlePhasePremium` (rolloverContract-local read-revert-set on resolved `fillContext.subFiller`)
- `CorkRolloverContract` ERC-7201 `premiumFiredFor` mapping
- `src/CorkRolloverContractFactory.sol:162` (transient settler-latch slot)
- `src/CorkRolloverContractFactory.sol:340-349` (settler-latch assign / mismatch revert)

**Related invariants**

- M-08
- INV-PREMIUM-FIRED-MONOTONIC
- INV-SETTLER-APPROVED
- INV-PARAMS-SETTLER-PIN

---

### M-29 — write srcCstProvided, not dstCstProduced

**Statement**

Per-filler partial-mode records the actual srcCST PAID (`srcCstProvided`), not
the dstCST produced, in the dedicated slot. Prevents the off-chain
`fillerRolloverOf` view from corrupting any downstream account that reads
`srcCstProvided` thinking it equals the original push.

**Motivation**

Off-chain indexers and accounting tools key position-recovery on
`srcCstProvided`. Storing dstProduced under that name would silently mis-bind
every downstream consumer (audit-tool divergence, no on-chain economic harm
but reputational + accounting risk).

**Mechanism**

Structural — `_writePartialFillRecord` writes `srcProvided` (the actual srcCST
the filler pushed for this leg) into `rec.srcCstProvided` at
`src/PartialSettler.sol:283`. The dstProduced amount accumulates in the separate
`rec.dstCstProduced` slot at `src/PartialSettler.sol:282`.

**Threat without**

Off-chain accounting corruption; downstream tools that read `srcCstProvided`
interpret it as dstCST and mis-report user positions.

**Defense site(s)**

- `src/ExactSettler.sol and src/PartialSettler.sol` (`_writePartialFillRecord` field writes)

**Related invariants**

- INV-NEW-POLARITY-ISOLATION
- N-INV-PARTIAL-RESIDUAL-RECONCILES-TO-TOTAL

---

### F-PUSH — push-based token movement

**Statement**

Token movement is push-based: srcCST and premium flow `filler → rolloverContract`
directly (Settler orchestrates factory dispatch but does not custody either
leg). dstCST flows `rolloverContract → Settler → recorded settlement destination`;
residual dstCST sits at the Settler only between async rollover and either
premium settlement or reclaim.

**Motivation**

A pull-based design would create permanent allowance surface — every approval
is a future-loss vector for the approving address. Push-based keeps allowance
surface strictly per-tx and per-order. The Settler holds no standing approvals
to the rolloverContract or filler.

**Mechanism**

Structural — `Settler.fill` performs the srcCST `safeTransferFrom(filler, …)`
on entry then `safeTransfer(…, rolloverContract)` to push into the rolloverContract; the rolloverContract's
`_finalizeRolloverLeg` performs the dstCST `safeTransfer(params.settler, …)`
at `src/CorkRolloverContract.sol:903`; premium tokens flow from filler directly to the
rolloverContract inside the PREMIUM-phase fill body. `BaseFiller` mirrors the same
pattern for the cross-chain side.

**Threat without**

Standing allowances become harvestable by a compromised receiver; the
residual-at-Settler model breaks because arbitrary pull calls could drain
residual before settle.

**Defense site(s)**

- `src/ExactSettler.sol and src/PartialSettler.sol` (post-rollover write — Settler-side ledger)
- `src/CorkRolloverContract.sol:903` (rolloverContract-side dstCST push to settler)
- `src/ExactSettler.sol and src/PartialSettler.sol` (settle-side push to filler destination)
- `src/ExactSettler.sol and src/PartialSettler.sol` (reclaim-side push to rolloverContract)
- `src/BaseFiller.sol` (filler-side push leg)

**Related invariants**

- INV-DST-CST-REACHABLE
- INV-DST-CST-RECONCILES
- INV-PARAMS-SETTLER-PIN

---

### F-0024 — Settler owner is identity-only

**Statement**

`Settler.owner()` is a Phoenix-style ENS/deployment identity surface. Cork
retains protocol-management capability across the contract's lifetime because
role administration, pause, unpause, and bounded ERC-20 rescue are role-gated.
Rescue cannot recover token balance backing tracked dstCST liability.

**Motivation**

Phoenix core contracts keep an `ensOwner` identity while operational permissions
are handled by roles. The Settler mirrors that split with OZ `Ownable`: the
owner identity may transfer or renounce, while `DEFAULT_ADMIN_ROLE`,
`PAUSER_ROLE`, `UNPAUSER_ROLE`, `RECOVERY_ROLE`, and rescue authority cannot
move through ownership changes.

**Mechanism**

`src/BaseSettler.sol` initializes OZ `Ownable` with `ensOwner_`.
`recoverToken` is `onlyRole(RECOVERY_ROLE)` and computes recoverable balance as
Settler token balance minus `dstCstLiability[token]`. If balance is below
liability, rescue fails closed. Role administration remains on
`DEFAULT_ADMIN_ROLE`.

**Threat without**

Using `owner()` as a protocol permission would create a second governance path
beside `DEFAULT_ADMIN_ROLE` and could confuse deployment and monitoring
expectations. The deployed role model keeps ownership transfer/renounce
identity-only and separate from AccessControl role powers.

**Defense site(s)**

- `src/BaseSettler.sol` inherits OZ `Ownable` and initializes it with `ensOwner_`
- `src/BaseSettler.sol` role-gated `recoverToken`, `pause`, `unpause`, and inherited `AccessControl`

**Related invariants**

- INV-PAUSE-GATES-ALL-ENTRYPOINTS
- INV-ROLLOVER_CONTRACT-OWNER-IMMUTABLE

---

### BS-FN-045 — polarity-gated terminal accounting

**Statement**

Internal settlement decrements either the per-filler residual (partial) or the
order-level residual (exact). The dispatch is gated by
`orderData.allowPartialFills`; the two paths never share storage.

**Motivation**

The settlement-time drain must mirror the fill-time write: the same
`allowPartialFills` boolean picks the storage half to zero. Combined with
INV-NEW-POLARITY-ISOLATION, this guarantees settlement drains exactly the
residual that the matching `fill` wrote.

**Mechanism**

Structural — internal settlement branches on `orderData.allowPartialFills`. The
partial branch zeroes `fillerDstCstResidual[orderId][filler]` and decrements
`totalDstCstEscrowed[orderId]`; the exact branch zeroes
`dstCstResidual[orderId]` and transitions the FSM to `Settled`.

**Threat without**

Partial-mode settlement decrementing `dstCstResidual[orderId]` (exact slot) while
leaving `fillerDstCstResidual[orderId][filler]` non-zero — stranded residual,
breach of INV-DST-CST-REACHABLE.

**Defense site(s)**

- `src/ExactSettler.sol and src/PartialSettler.sol` (partial-mode settlement branch)
- `src/ExactSettler.sol and src/PartialSettler.sol` (exact-mode settlement branch)

**Related invariants**

- BS-ST-20
- INV-NEW-POLARITY-ISOLATION
- INV-DST-CST-REACHABLE
- N-INV-FILLER-SETTLED-STICKY

---

### INV-DEFAULTER-RECOUP — defaulter residual → rolloverContract

**Statement**

For every order whose filler(s) rolled (`dstCstProduced > 0`) but never fired
PREMIUM, the dstCST residual escrowed at the Settler is reclaimable to the
originating cPT-holder rollover contract (`orderData.rolloverContract`) once
`block.timestamp > orderData.fillDeadline` AND
`orderStatus ∈ {None, Opened, Closing, Expired}`.

**Motivation**

The rolloverContract bore the rollover-capacity cost (burned srcCPT, minted dstCST);
routing the unpaid residual back to the rolloverContract is the economically symmetric
repair when the filler defaults on premium. Without `reclaim`, dstCST would
strand at the Settler — escrowed but undrainable to any party. The `None`
branch closes the equivalent gap for direct atomic `Settler.fill`
integrations that bypass `openFor`.

**Mechanism**

`Settler.reclaim` at `src/ExactSettler.sol and src/PartialSettler.sol` validates a four-status window
(`Expired`, `Closing`, `Opened`, `None`) via `Settler__OrderNotStopped`,
enforces a post-`fillDeadline` timing gate via
`Settler__FillerStillInFlight`, then branches on `orderData.allowPartialFills`.
The partial branch reads `fillerRollovers[orderId][defaulterFiller]`, asserts
`!rec.premiumFired` and `!fillerSettled[orderId][defaulterFiller][subFiller]`, latches
`fillerSettled = true`, zeroes the per-filler residual, decrements
`totalDstCstEscrowed`, and transfers `amount` to `orderData.rolloverContract`. The exact
branch is the order-level analogue.

**Threat without**

Permanently stuck residual at the Settler; rolloverContract takes a clean P&L loss with
no on-chain recovery route. The cPT holder can never recover capacity from a filler
that walked away from premium.

**Defense site(s)**

- `src/ExactSettler.sol and src/PartialSettler.sol` (`reclaim`)
- `src/ExactSettler.sol and src/PartialSettler.sol` (status window + deadline gate)
- `src/ExactSettler.sol and src/PartialSettler.sol` (partial branch latch + zero)
- `src/ExactSettler.sol and src/PartialSettler.sol` (exact branch latch + zero)
- `src/ExactSettler.sol and src/PartialSettler.sol` (push to `orderData.rolloverContract`)

**Related invariants**

- BS-ST-20
- INV-DST-CST-REACHABLE
- N-INV-FILLER-SETTLED-STICKY

---

### INV-DST-CST-REACHABLE — every residual drains

**Statement**

For every `(orderId, filler)` with
`fillerDstCstResidual[orderId][filler] > 0` (or `dstCstResidual[orderId] > 0`
in exact mode), there exists at least one callable Settler function that, if
its external `safeTransfer` succeeds, drains that residual to either
`fillerDestination[orderId][filler]` (premium-paid path via in-frame settlement) or
`orderData.rolloverContract` (defaulter path via `reclaim`).

**Motivation**

The Settler is designed to be a transient hop (F-PUSH). Any residual that has
no callable drain is, by construction, a custodianship bug. The invariant
pins Settler-internal reachability only — external receivability (filler
destination that reverts, bricked rolloverContract) is by-design out of protocol
mediation and tested as expected-revert, not invariant violation.

**Mechanism**

Structural — every `(orderId, filler)` whose residual is non-zero is reachable
by exactly one of two drain functions selected by FSM state and
`premiumFired`:
- Premium-paid → partial-mode in-frame settlement drains to
  `fillerDestination[orderId][filler]`; exact-mode in-frame settlement drains to the
  exact-record destination.
- Defaulter (post-deadline, `!premiumFired`) → `reclaim` drains to
  `orderData.rolloverContract`.

**Threat without**

Permanently stuck dstCST at the Settler — protocol's transient-custody promise
breaks; cPT holders and fillers both lose recourse.

**Defense site(s)**

- `src/ExactSettler.sol and src/PartialSettler.sol` (settle branches — partial / exact)
- `src/ExactSettler.sol and src/PartialSettler.sol` (reclaim branches — partial / exact)
- `src/ExactSettler.sol and src/PartialSettler.sol` (partial-mode writer keeps slots disjoint)

**Related invariants**

- F-PUSH
- BS-FN-045
- INV-DEFAULTER-RECOUP
- INV-DST-CST-RECONCILES
- N-INV-FILLER-SETTLED-STICKY
- N-INV-PARTIAL-RESIDUAL-RECONCILES-TO-TOTAL

---

## Cluster: RolloverContract invariants

### INV-TRUST-CONFIG-DELAY — configured-delay queue-and-apply

**Statement**

Trust-configuration changes on a rolloverContract are time-locked by a constructor-supplied
external per-rolloverContract trust-config `TimelockController`. cPT holder (rollover contract `owner`) calls
the safe/default `CorkRolloverContractFactory.queueFactoryDefaultTrustConfig()` path,
which snapshots current factory defaults at queue time, or the advanced/custom
`queueTrustConfig(threshold, attesters)` path. Both derive the target from
`rolloverContractOf[msg.sender]` and schedule a
`relayTrustConfig(rolloverContract, salt, threshold, attesters)` op on the timelock with
its configured delay and mirror the queued pair plus
salt into the factory's `pendingConfig[salt]` / `lastSalt[rolloverContract]` maps. After
the delay anyone calls
`applyTrustConfig(rolloverContract)`, which loads the queued salt/pair from the factory
mirror and routes through `TimelockController.execute` → `relayTrustConfig` →
`ICorkRolloverContract.setTrustConfig`. The relay only succeeds during that canonical
apply frame for the exact queued op id. The rolloverContract itself holds
NO pending-trust storage — `setTrustConfig` is gated `onlyFactory` and is the
sole live-trust writer. Re-queueing cancels any prior pending op for the
same rolloverContract and resets the trust-config timelock clock; `cancelTrustConfig()` is the
cPT-holder-only abort path for the caller's own pending config.

**Motivation**

cPT holder. Without the delay, the cPT holder could swap the attester set
between a filler's simulation and the filler's on-chain tx — turning a green
simulation into a hostile production environment. The
`CorkRolloverContractFactory.pendingTrustConfig(rolloverContract)` view exposes the Factory pending
mirror plus the timelock timestamp for that mirrored op. Only the full zero
tuple `(0, [], 0)` means no Factory pending mirror exists; a nonzero
threshold/attester mirror with `effectiveAt == 0` means the timelock op is
absent, done, or unset and the owner must cancel or requeue to recover. The
trust-config timelock delay is the simulation-stability window, not a per-order
snapshot; intent identity is orthogonally pinned by `OrderData.rolloverIntentHash`.

**Mechanism**

`CorkRolloverContractFactory.queueFactoryDefaultTrustConfig` and `queueTrustConfig`
enforce owner/rolloverContract authorization in the entrypoints via `_requireCallerRolloverContract`
(`:959`), which resolves the rolloverContract from `$.rolloverContractOf[msg.sender]` and checks the
caller against the CWIA-decoded owner via `_requireRolloverContractOwner` (`:975`). They then
forward to `_scheduleTrustConfig` (`src/CorkRolloverContractFactory.sol:705`),
which performs factory-rolloverContract + pair validation: it calls `_requireFactoryRolloverContract`
and validates the pair via `_validateTrustConfig` (`:929`) raising
`CorkRolloverContractFactory__InvalidThreshold` / `__ZeroAddress` /
`__DuplicateAttester`, cancels any prior pending op for this rolloverContract,
computes a per-`(rolloverContract, queueNonce)` salt, calls
`TimelockController.schedule(address(this), 0, data, bytes32(0), salt, delay)`,
and mirrors the pair into `pendingConfig[salt]`.
The only other factory `schedule` call site is the bounded delay-update helper,
which validates the replacement delay, uses the raw live timelock delay as the
wait, and schedules `TimelockController.updateDelay(newDelay)` against the
immutable trust-config timelock itself. That recovery path can queue a bounded
decrease when the live delay is already above policy; normal trust-config queues
still fail closed until the live delay is back under the cap.
`applyTrustConfig` (`:453`) loads the queued values from the mirror
(`__NoQueuedTrustConfig` when nothing is queued), then invokes
`TimelockController.execute` — which reverts
`TimelockController.TimelockUnexpectedOperationState` while the delay has
not elapsed and otherwise calls `relayTrustConfig` (`:505`) →
`ICorkRolloverContract.setTrustConfig` (`src/CorkRolloverContract.sol:351`). The relay
raises `CorkRolloverContractFactory__MismatchedApplyArgs(expectedSalt)` when relay
calldata/salt does not match the factory pending mirror, a stale/malicious
direct timelock callback was attempted, or the factory/timelock operation
identity diverges. The rolloverContract's
`setTrustConfig` forwards the new pair to `IERC7484.trustAttesters` (`:362`)
against the rolloverContract's smart-account record.

**Threat without**

Mid-tx attester swap: the cPT holder front-runs the filler with trust-config queueing +
`applyTrustConfig` to install a hostile attester that approves an arbitrary
executor module. Filler simulation outcomes become non-actionable.

**Defense site(s)**

- `src/CorkRolloverContractFactory.sol` constructor validation of `trustConfigTimelock_`
- `src/CorkRolloverContractFactory.sol` (`queueFactoryDefaultTrustConfig` / `queueTrustConfig`) →
  `_scheduleTrustConfig`
- `src/CorkRolloverContractFactory.sol:453` (`applyTrustConfig`)
- `src/CorkRolloverContractFactory.sol:467` (`cancelTrustConfig`)
- `src/CorkRolloverContractFactory.sol:505` (`relayTrustConfig` — timelock-only)
- `src/CorkRolloverContract.sol:351` (`setTrustConfig` — `onlyFactory`)

**Related invariants**

- INV-ROLLOVER_CONTRACT-CPT-HOLDER-SIG-EVERY-DISPATCH
- INV-DEFAULT-ATTESTERS-FACTORY-SEEDED
- INV-PARAMS-SETTLER-PIN

---

### INV-ROLLOVER_CONTRACT-CPT-HOLDER-SIG-EVERY-DISPATCH — per-dispatch cPT-holder authorization

**Statement**

`OrderData.rolloverIntentHash` pins the canonical zero-digest intent hash for the
order. Every rollover-contract hook dispatch verifies the EIP-712 / ERC-1271 cPT holder
signature over `orderDigest` against the cPT holder. Atomic ROLLOVER and
atomic PREMIUM may reuse the same off-chain signature bytes, but both RolloverContract
dispatches verify them on-chain; authorization exists only as the successful
cPT-holder-signature check in the current dispatch.

**Motivation**

The binding ties every phase to the cPT-holder-signed hook body: an attacker cannot
substitute a benign body for signature recovery and a hostile body for actual
hook execution. Requiring a signature check on every RolloverContract dispatch removes
phase-specific authorization state from the model.

**Mechanism**

`_validateIntentHashBinding` checks the supplied intent against
`OrderData.rolloverIntentHash`. `_ensureOwnerAuthorized` checks
`SignatureChecker.isValidSignatureNow(_owner(), orderDigest, cptHolderSig)` on
every dispatch and writes no authorization state.

**Threat without**

Different intent body per phase: attacker substitutes a benign body for
phase-0 sig recovery, then swaps in a hostile body for the actual hook
execution.

**Defense site(s)**

- `src/CorkRolloverContract.sol` (`_validateIntentHashBinding`)
- `src/CorkRolloverContract.sol` (`_ensureOwnerAuthorized`)
- `src/CorkRolloverContract.sol:603,610` (`BadIntentSignature` reverts)
- `src/libraries/LibAuthenticatedHooks.sol:58-69` (dual-binding helper)

**Related invariants**

- INV-TRUST-CONFIG-DELAY
- M-11

---

## Cluster: Settler / pool invariants

### SL-14 — distinct Phoenix pool IDs on open

**Statement**

`srcCstToken` and `dstCstToken` MUST resolve to distinct Phoenix pool ids on
`open` / `openFor`. Same-pool routing collapses the rollover into a no-op
against the same risk surface.

**Motivation**

A same-pool rollover yields zero economic effect but still consumes premium
and burns CPT — pure griefing surface. The Settler reads each token's
`poolId()` view and reverts on equality before any state mutation.

**Mechanism**

`Settler._validateOrder` reverts `Settler__SamePoolId` at
`src/ExactSettler.sol and src/PartialSettler.sol` after reading the two pool ids from the source and
destination `IPoolShare` tokens.

**Threat without**

Filler can grief the cPT holder by collecting premium against a no-op rollover.

**Defense site(s)**

- `src/ExactSettler.sol and src/PartialSettler.sol` (`SamePoolId` revert)
- `src/ExactSettler.sol and src/PartialSettler.sol` (error declaration)

**Related invariants**

- BS-ST-20

---

## Cluster: RolloverContract-opinionated rollover invariants

### INV-CPT-CONTAINED — CPT is cPT-holder property only

**Statement**

srcCPT and dstCPT are cPT-holder property; the rolloverContract holds CPT only inside
the rollover leg's transient window (preHook → unwindMint; deposit → postHook).
After `_finalizeRolloverLeg` the rolloverContract's srcCPT and dstCPT balances must be
back at their leg-entry snapshots. Any residual or deficit reverts via
`CorkRolloverContract__DstCptNotRestored` / `CorkRolloverContract__SrcCptNotRestored`.
The standard dstCPT postHook reads the dynamic `dstCptAfterDeposit - dstCptBeforeDeposit`
transient register and routes only that net increase to the cPT roller, so it
does not require zero standing dstCPT. The rolloverContract issues NO standing
CPT allowances and never transfers CPT to a non-attested target.

**Motivation**

CPT carries cPT-holder capacity; standing balances on the rolloverContract would be either an
idle-capital sink or — in a CWIA multi-rolloverContract topology — a cross-position
contamination vector. The rolloverContract must hold zero CPT at rest.

**Mechanism**

`_finalizeRolloverLeg` writes the post-deposit dstCPT net increase into a
transient register, runs post-hooks, clears the register, then samples srcCPT
and dstCPT balances. It reverts
`CorkRolloverContract__DstCptNotRestored(expected, actual)` or
`CorkRolloverContract__SrcCptNotRestored(expected, actual)` when either token
exits with a balance different from its entry snapshot. The entry snapshots live
in the `_RolloverScratch` struct populated by `_populateScratch`.

**Threat without**

cPT-holder capacity stranded on the rolloverContract; in the worst case, capacity attributable
to cPT-holder A consumed by cPT-holder B's order through a CWIA-shared implementation bug.

**Defense site(s)**

- `_finalizeRolloverLeg` (`DstCptNotRestored` / `SrcCptNotRestored` revert)
- `src/errors/CorkRolloverContractErrors.sol:182` (`DstCptNotRestored` declaration), `:188` (`SrcCptNotRestored` declaration)

**Related invariants**

- INV-DST-FLOOR
- INV-5
- DSR-1
- DSR-2

---

### DSR-1 — leg output measured by balance delta

**Statement**

Both legs measure their output token via the rolloverContract's own balance delta — not
via the pool's `unwindMint` / `deposit` return value. The pool's return is
rejected when it is zero (DSR-1 zero-check); the delta is the source of truth
for accounting downstream.

**Motivation**

A buggy or hostile pool implementation could mis-report mint/burn amounts. The
rolloverContract's own balance is the only unforgeable source. The pool-reported amount
is used only as a zero-check; downstream arithmetic uses
`balanceAfter - balanceBefore`.

**Mechanism**

`_handlePhaseRollover` reverts `CorkRolloverContract__RolloverZeroUnwindMint` when
phoenix `unwindMint` reports zero and `CorkRolloverContract__RolloverZeroDeposit` when
phoenix `deposit` reports zero. Both leg helpers use `balanceOf` deltas to
compute the actual output amount consumed by downstream accounting.

**Threat without**

RolloverContract accounting diverges from actual token flow; settle-time `dstProduced`
carries the (potentially inflated) pool-reported value instead of the real
delta.

**Defense site(s)**

- `src/CorkRolloverContract.sol:375` (`RolloverZeroUnwindMint` decl)
- `src/CorkRolloverContract.sol:380` (`RolloverZeroDeposit` decl)
- `src/CorkRolloverContract.sol:692-741` (`_handlePhaseRollover` body — leg orchestration)

**Related invariants**

- DSR-2
- INV-CPT-CONTAINED
- INV-DST-FLOOR
- INV-5

---

### DSR-2 — no rebuf of `caForDeposit`

**Statement**

`_depositLeg` does NOT re-read `caDst.balanceOf(rolloverContract)` between the approve
and the deposit call — the value sampled before `forceApprove` is the
same value passed as `caIn` to `deposit`. Re-reading would invite a hostile
midHook to inflate caDst after the approve and trick the rolloverContract into
depositing more than it intended.

**Motivation**

Mid-bracket attacker control over CA-dst could let the attacker mint over
their actual contribution. The sealed snapshot is the only value the
deposit-leg sees.

**Mechanism**

Structural — `_depositLeg` snapshots `caForDeposit` once and reuses it for
both the approve and the deposit. No runtime check exists; the property
holds by code shape.

**Threat without**

RolloverContract deposits inflated CA-dst into the Phoenix pool, minting more dstCST
than the cPT holder actually contributed.

**Defense site(s)**

- `src/CorkRolloverContract.sol` `_depositLeg` body (single load-bearing site)

**Related invariants**

- DSR-1
- INV-DST-FLOOR
- INV-5

---

### INV-3 (CA non-decreasing across mid-bracket) — REMOVED

**Status**

REMOVED. The mid-hook caSrc no-drop guard blocked cross-CA rollover. Replaced
by `INV-DST-FLOOR`, which leans on the cPT-holder-signed `params.minSharesOut` floor
as the load-bearing safety against mid-hook value-skim. The mid-hook may now
freely consume caSrc; end-to-end value is bounded only by the deposit-side
floor.

**Replaced by**

`INV-DST-FLOOR` (see below).

**Prior mechanism (removed)**

`_handlePhaseRollover` previously reverted
`CorkRolloverContract__MidPhaseCollateralDrain(caBefore, caAfter)` when
`caAfterMid < caAfterUnwind`. The error declaration and revert have been
deleted from `src/CorkRolloverContract.sol`.

---

### INV-DST-FLOOR (cPT-holder-signed dst-side floor is load-bearing)

**Statement**

End-to-end value across a rollover leg is bounded by `params.minSharesOut` —
the cPT-holder-signed floor on `dstProduced` enforced after `_depositLeg`. The mid-
hook is a CA-composition step that MAY freely consume caSrc (cross-CA
rollover via an attested SwapModule); the rolloverContract enforces NO constraint on
caSrc balance during mid.

**Motivation**

The rollover contract's cPT-holder position is bounded by what the deposit step produces, not by
intermediate caSrc balance. Cross-CA rollover (e.g. src pool on USDC, dst
pool on DAI) requires the mid-hook to consume caSrc and produce caDst; the
prior INV-3 guard blocked this legitimate use case. The cPT holder signs
`minSharesOut` per intent, so the floor is fresh per rollover.

**Mechanism**

`_handlePhaseRollover` reverts
`CorkRolloverContract__UnwindDepositShortfall(produced, floor)` at
`src/CorkRolloverContract.sol:731` when `dstProduced < params.minSharesOut`. The
degenerate `caForDeposit == 0` path reverts
`CorkRolloverContract__CaInsufficientForDeposit()` at `src/CorkRolloverContract.sol:898`.

**Threat without**

A compromised-but-attested mid-hook produces fewer dstCST than the cPT holder signed
for — the rolloverContract forwards less value than the rollover committed to. Without
`minSharesOut`, the cPT holder would be silently shorted.

**Defense site(s)**

- `src/CorkRolloverContract.sol:731` (`UnwindDepositShortfall` revert)
- `src/CorkRolloverContract.sol:898` (`CaInsufficientForDeposit` revert)

**Related invariants**

- INV-5 (dstCST no-drain)
- INV-CPT-CONTAINED (dstCPT forced-handle)
- INV-TRUST-CONFIG-DELAY (mitigates attester-key compromise)
- DSR-2 (caForDeposit sampled once)

---

### INV-5 (dstCST no-drain across leg)

**Statement**

Across the rollover leg, the rolloverContract's dstCST balance MUST end at or above the
entry snapshot. Combined with the rolloverContract's tail transfer of `dstProduced` to
`params.settler`, a hostile post-hook cannot drain dstCST out of the rolloverContract
without tripping this guard.

**Motivation**

The rolloverContract's tail transfer is the single authorised path for dstCST to leave
the rolloverContract; a post-hook drain would short the Settler and break
INV-DST-CST-RECONCILES.

**Mechanism**

`_finalizeRolloverLeg` reverts
`CorkRolloverContract__MidPhaseDstCstDrain(dstBefore, dstAfter)` at
`src/CorkRolloverContract.sol:957` when `dstCstAfter < s.dstCstBefore`. Error
declaration at `src/errors/CorkRolloverContractErrors.sol:38`.

**Threat without**

Settler receives less dstCST than the rolloverContract reports as `dstProduced`; the
Settler's `delivered >= reported` check reverts as a defence-in-depth, but
the rolloverContract-side guard catches it first.

**Defense site(s)**

- `src/CorkRolloverContract.sol:957` (`MidPhaseDstCstDrain` revert)
- `src/errors/CorkRolloverContractErrors.sol:38` (error declaration)

**Related invariants**

- INV-DST-FLOOR
- INV-CPT-CONTAINED
- INV-DST-CST-REACHABLE
- INV-DST-CST-RECONCILES

---

## Cluster: Non-properties / explicit discretions

### RolloverContract premium routing discretion — non-invariant

**Statement**

The rolloverContract's premium handler runs `intent.premiumHooks` under a
standing-balance tripwire (`INV-PREMIUM-HOOKS-CANNOT-SWEEP-STANDING-BALANCE`):
hooks may spend up to `fillContext.premium` of the just-delivered premium but must not
net-reduce the rolloverContract's pre-leg standing balance. The cPT holder freely
decides downstream routing within that envelope by selecting the `premiumHooks`
chain at intent-signing time. Enforced structure also includes: (a) ERC-7484
attester gate on every premium hook target; (b) atomic-fill: Settler transfers
premium `filler → rolloverContract` directly, verifies balance delta, then factory
dispatch — hook or policy-gate revert rolls back the whole frame
(`INV-PREMIUM-HOOK-REVERT-CASCADES`, `INV-PREMIUM-PAID-RELEASES-DST`); (c)
factory transient `_originatingSettler` latch; (d) rolloverContract
`premiumFiredFor[orderDigest][filler][subFiller]` and `PremiumFired` with
resolved `fillContext.subFiller`; (e) intra-hook trust-mutation guard.

**Motivation**

Premium routing is deliberately a cPT-holder policy decision — treasury wallet, yield
vault, filler refund, distribution module — not a protocol property.
Documenting this here keeps the absence of a bracket from being read as a bug
by future reviewers.

**Mechanism**

Structural — `_handlePhasePremium` runs the premium hook chain through
`_executeIntentCalls` (with live ERC-7484 prevalidation) and takes no balance
snapshot. The surviving gates are: the live ERC-7484 check at PREMIUM
execution; atomic-fill frame delivering dstCST + premium together or reverting
(`INV-PREMIUM-HOOK-REVERT-CASCADES`); factory settler-latch; Settler-side M-11
latch with rolloverContract `premiumFiredFor` mirroring on success; intra-hook
trust-mutation guard (`CorkRolloverContract__TrustConfigMutatedDuringHook`).

**Threat without**

N/A — the absence of a bracket is by design.

**Defense site(s)**

- `CorkRolloverContract._handlePhasePremium`
- `src/CorkRolloverContractFactory.sol:340-349` (settler-latch)

**Related invariants**

- M-11
- INV-PREMIUM-FIRED-MONOTONIC
- INV-SETTLER-APPROVED

---

## Cluster: Factory invariants

### INV-SETTLER-APPROVED — factory allowlist

**Statement**

Every successful `CorkRolloverContractFactory.executeIntentHooks` call originated from a
Settler currently flagged `approvedSettlers[msg.sender] == true`. The factory
is default-deny; `SETTLER_APPROVER_ROLE` holders approve Settlers via
`approveSettler`, and `SETTLER_REVOKER_ROLE` holders may revoke at any time via
`revokeSettler` (instant kill-switch for BOTH ROLLOVER and PREMIUM legs).
Under atomic-fill, `revokeSettler` causes in-flight `fill` calls to revert at
the factory policy gate and roll back the entire transaction. `deployRolloverContract` does NOT auto-approve — genesis approver MUST approve the
exact and partial Settlers before the first order.

For an in-flight `Settler.fill` where srcCST has already left the filler
before the factory dispatch is reached, factory revocation cannot pull that
caller back — `Settler.pause()` (`PAUSER_ROLE`) is the operational emergency
stop for those flows.

**Motivation**

Without an allowlist, any contract could call `executeIntentHooks` and route a
rollover through any rolloverContract. The Settler is the trust root for filler
authentication and order FSM — that authority cannot be unscoped.

**Mechanism**

`executeIntentHooks` at `src/CorkRolloverContractFactory.sol:310` enforces the allowlist
via `_requireApprovedSettler` (`:330`), which reads
`$.approvedSettlers[settler]` (`:983`) and reverts
`CorkRolloverContractFactory__SettlerNotApproved(msg.sender)` when the bit is unset. The
operational paths live at `src/CorkRolloverContractFactory.sol:354` (`approveSettler`) and
`:368` (`revokeSettler`); they are gated by `SETTLER_APPROVER_ROLE` and
`SETTLER_REVOKER_ROLE`, respectively.
`approveSettler` additionally rejects `address(0)` and code-less addresses,
but does not verify a Settler interface. `revokeSettler` is idempotent and
performs no zero/code checks.

**Threat without**

Arbitrary contracts dispatch into rolloverContract hook chains; entire FSM and
filler-auth surface bypassed.

**Defense site(s)**

- `src/CorkRolloverContractFactory.sol:141` (`approvedSettlers` slot)
- `src/CorkRolloverContractFactory.sol:330,983` (allowlist gate via `_requireApprovedSettler`)
- `src/CorkRolloverContractFactory.sol:354` (`approveSettler`)
- `src/CorkRolloverContractFactory.sol:368` (`revokeSettler`)
- `src/interfaces/rollover/ICorkRolloverContractFactory.sol` (policy-gate errors propagate through atomic fill)
- `src/BaseSettler.sol` (atomic-fill envelope; factory policy-gate reverts roll back the frame)

**Related invariants**

- INV-PARAMS-SETTLER-PIN
- INV-DEFAULT-ATTESTERS-FACTORY-SEEDED
- M-11

---

## Cluster: Settler invariants (filler authorisation)

### INV-FILLER-AUTH — three-branch fill gate

**Statement**

Every successful `Settler.fill` call satisfies one of: (a)
`orderData.exclusiveFiller == address(0)` (no gate), (b)
`msg.sender == orderData.exclusiveFiller` (direct call), or (c) a valid
EIP-712 / ERC-1271 signature by `exclusiveFiller` over
`FillerAuth(orderDigest, destination, subFiller)` (delegated executor). `openFor`
performs NO filler attestation — `originFillerData` is opaque and is not
consulted by the Cork Settler implementation.

**Motivation**

Executor-binding would force every exclusiveFiller to re-sign per-executor.
Destination + subFiller binding closes the griefing window — an attacker that
replays the sig must use the same destination and sub-filler slot, so dstCST
still lands at the exclusiveFiller's pre-committed receiver and the attacker's
P&L is strictly net-negative.

**Mechanism**

`Settler.fill` calls `LibFillerAuth.isAuthorised` at `src/ExactSettler.sol and src/PartialSettler.sol`
and reverts `Settler__UnauthorizedFiller(exclusiveFiller, msg.sender)` on
failure. The helper at `src/libraries/LibFillerAuth.sol:91` evaluates the
three branches; the typehash
`FillerAuth(bytes32 orderDigest,address destination,bytes32 subFiller)` lives at
`src/libraries/Typehashes.sol:35-36`.

**Threat without**

A delegated-fill replay could redirect dstCST to an attacker-chosen
destination; or worse, a missing gate would let any party trigger a fill
against an exclusive order.

**Defense site(s)**

- `src/ExactSettler.sol and src/PartialSettler.sol` (`isAuthorised` call + revert)
- `src/libraries/LibFillerAuth.sol:91-108` (helper body)
- `src/libraries/Typehashes.sol:35-36` (`FILLER_AUTH_TYPEHASH`)
- `src/ExactSettler.sol and src/PartialSettler.sol` (error declaration)

**Related invariants**

- BS-ST-20
- F-PUSH

---

## Cluster: RolloverContract invariants (allowlist composition)

### INV-PARAMS-SETTLER-PIN — rolloverContract defence-in-depth

**Statement**

Every `_handlePhaseRollover` dstCST `safeTransfer` lands at
`orderData.rolloverParams.settler == fillContext.originSettler == msg.sender == an
approved Settler`. Jointly enforced by the factory's
`fillContext.originSettler == msg.sender` latch + the allowlist gate
(INV-SETTLER-APPROVED) + the rolloverContract's signed-settler pin in
`_validateOrderDataBinding`.

**Motivation**

A compromised approved Settler that forwarded signed order data for a different
settler could otherwise route dstCST to an attacker contract that simply
absorbs it. The rolloverContract's local pin breaks that scenario even if the
factory-side gate is somehow subverted — it is defence in depth, not the first
line.

**Mechanism**

`_validateOrderDataBinding` re-derives the digest from `orderData`, then checks
`orderData.rolloverParams.settler == fillContext.originSettler`. It reverts
`CorkRolloverContract__SignedSettlerOriginMismatch(signedSettler, originSettler)` on a
signed-settler mismatch; mutation of any other rollover parameter changes the
order digest and reverts `CorkRolloverContract__OrderDataDigestMismatch`.

**Threat without**

dstCST tail transfer routed to an attacker; entire INV-DST-CST-REACHABLE chain
breaks because the rolloverContract pushes to a hostile settler proxy.

**Defense site(s)**

- `src/CorkRolloverContract.sol` (`_validateOrderDataBinding`)
- `src/CorkRolloverContract.sol:699` (call site inside `_handlePhaseRollover`)
- `src/errors/CorkRolloverContractErrors.sol:159` (`SignedSettlerOriginMismatch` declaration), `:214` (`OrderDataDigestMismatch` declaration)

**Related invariants**

- INV-SETTLER-APPROVED
- M-11
- INV-DST-CST-REACHABLE

---

## Cluster: Settler invariants (operational halt)

### INV-DEFAULT-ATTESTERS-FACTORY-SEEDED — factory-baked default attester seed

**Statement**

Every rolloverContract deployed by factory `F` starts life with attester set equal to
`F`'s `defaultAttesters()` view and threshold equal to `F`'s
`DEFAULT_TRUST_THRESHOLD()` view. The seed pair is read from factory storage
`$.defaultTrustThreshold` / `$.defaultAttesters`. The seed pair is mirrored into the rolloverContract's
`liveTrustThreshold` / `liveTrustAttesters` storage and forwarded to
`IERC7484.trustAttesters` against the rolloverContract's own smart-account record at
`initialize` time. cPT holder updates flow through the queue/apply trust-config cycle
using the configured trust-config timelock delay; the safe/default path queues
a snapshot of current factory defaults.
The factory's defaults are validated at construction and on `setDefaults`
updates.

**Motivation**

Without a baked default seed, a freshly-deployed rolloverContract would sit in an
unsigned-state window between `deployRolloverContract()` and the cPT holder's first
`CorkRolloverContractFactory.applyTrustConfig` — every hook target would fail the
ERC-7484 check until the cPT holder manually queued an attester set on the factory.
The seed closes that window and makes Cork-recommended attesters the
default-safe configuration.

**Mechanism**

`CorkRolloverContractFactory` constructor at `src/CorkRolloverContractFactory.sol:203-270`
validates `defaultAttesters_` (non-empty, no zero entries, no duplicates,
threshold in `[1, length]`) and writes to storage `$.defaultAttesters` and
`$.defaultTrustThreshold`. `deployRolloverContract` forwards the pair to
`CorkRolloverContract.initialize` (`src/CorkRolloverContract.sol:255`), which mirrors into
`$.liveTrustThreshold` / `$.liveTrustAttesters` at `:271-272` and calls
`IERC7484(registry).trustAttesters(initialTrustThreshold, initialTrustAttesters)`
at `:274`.

**Threat without**

Unsigned-state window on fresh rolloverContracts; cPT holder must manually configure attesters
before first use; user-experience and security regression.

**Defense site(s)**

- `src/CorkRolloverContractFactory.sol:554` (`DEFAULT_TRUST_THRESHOLD()` view over `$.defaultTrustThreshold`)
- `src/CorkRolloverContractFactory.sol:152` (`$.defaultTrustThreshold` slot), `:154` (`$.defaultAttesters` slot)
- `src/CorkRolloverContractFactory.sol:203-270` (constructor validation)
- `src/CorkRolloverContract.sol:255` (`initialize` mirror + forward)

**Related invariants**

- INV-TRUST-CONFIG-DELAY
- INV-ROLLOVER_CONTRACT-OWNER-IMMUTABLE

---

### INV-ROLLOVER_CONTRACT-OWNER-IMMUTABLE — CWIA-baked cPT holder is fixed

**Statement**

The CWIA-baked cPT holder is fixed for the rolloverContract's lifetime. There is no
owner-transfer primitive — the owner address lives in the clone's 60-byte
CWIA trailer (bytes 0..20, with `factory` at bytes 20..40 and
`erc7484Registry` at bytes 40..60), is decoded by `_cwiaImmutableArgs`, and
has no setter. The `erc7484Registry` field is structurally identical: also
CWIA-immutable, with no setter and no storage slot, so the registry pointer
has no `sstore` vector.

**Motivation**

CWIA topology multiplexes a single implementation across many per-cPT-holder rolloverContracts.
If owner transfer existed, an attacker who compromised one rolloverContract's owner key
could swap ownership across clones. The immutable trailer eliminates the
attack surface entirely.

**Mechanism**

Structural — no transfer or setter exists on the rolloverContract surface.
`_cwiaImmutableArgs` at `src/CorkRolloverContract.sol:1166` decodes the 60-byte
trailer on every read via `Clones.fetchCloneArgs`. `initialize` at
`src/CorkRolloverContract.sol:255` is gated by `onlyFactory initializer` (modifier
order pinned per OZ `Initializable` semantics — `onlyFactory` MUST precede
`initializer`); it seeds the live trust-config mirror and forwards to
`IERC7484.trustAttesters` exactly once. The registry pointer itself is read
from the CWIA trailer via `_registry()` (`src/CorkRolloverContract.sol:1164`), so there is
no `initialize`-time registry write at all.

**Threat without**

Cross-clone ownership theft via a single compromised key; a single
implementation bug becomes a protocol-wide owner-rotation surface.

**Defense site(s)**

- `src/CorkRolloverContract.sol:1166` (CWIA decode helper)
- `src/CorkRolloverContract.sol:255` (`initialize` — one-shot registry write)
- `src/CorkRolloverContract.sol:258-259` (`onlyFactory initializer` modifier order)

**Related invariants**

- INV-DEFAULT-ATTESTERS-FACTORY-SEEDED
- F-0024

---

### INV-PAUSE-GATES-ALL-ENTRYPOINTS — Settler-wide pause gate

**Statement**

When `Settler.paused()`, every external state-changing entrypoint (`open`,
`openFor`, `fill`, `reclaim`, `markExpired`, `cancel`) MUST revert with
OZ `Pausable.EnforcedPause`. View functions remain reachable. Pause authority
is split: `PAUSER_ROLE` halts; `UNPAUSER_ROLE` resumes; the two roles are
held by separate keys so a single compromised credential cannot drive a full
halt-resume cycle.

**Motivation**

Operational halt is the canonical emergency response. Splitting
pause/unpause across two roles ensures the emergency-pause key can be the
"loud and visible" one while resume requires a separate (e.g., multisig)
authorisation — a compromised pause key cannot unpause and grief the system
back open.

**Mechanism**

OZ `Pausable._requireNotPaused()` reverts `EnforcedPause()` via the
`whenNotPaused` modifier placed before `nonReentrant` on every gated
entrypoint. Roles declared at `src/ExactSettler.sol and src/PartialSettler.sol,71`; granted to the
deployer at `:357-358`. `pause()` and `unpause()` at `:380,389` are
`onlyRole(PAUSER_ROLE)` and `onlyRole(UNPAUSER_ROLE)` respectively.

**Threat without**

No emergency stop for a discovered exploit; a single compromised pause-role
holder could oscillate the contract between paused and unpaused, denying
service to legitimate users.

**Defense site(s)**

- `src/ExactSettler.sol and src/PartialSettler.sol,71` (role declarations)
- `src/ExactSettler.sol and src/PartialSettler.sol` (initial role grants)
- `src/ExactSettler.sol and src/PartialSettler.sol` (`pause`)
- `src/ExactSettler.sol and src/PartialSettler.sol` (`unpause`)
- `src/ExactSettler.sol and src/PartialSettler.sol,576,765,1073,1175,1227,1262` (`whenNotPaused` on every
  external state-changing entrypoint)

**Related invariants**

- F-0024
- INV-SETTLER-APPROVED

---

### N-INV-ROLLED-MONOTONE-AND-BOUNDED — rolled accumulator never regresses

**Statement**

For every `orderDigest`, the rolloverContract's `$.rolled[orderDigest]` accumulator is
strictly non-decreasing across the order's lifetime and never exceeds
`fillContext.orderSize` latched at the first successful ROLLOVER phase. The
`PHASE_0_TERMINAL_BIT` in `$.hookNonces[orderDigest]` is set-only — once set
it stays set, and no subsequent ROLLOVER phase can clear it or push `rolled`
further.

**Motivation**

The rolled accumulator is the canonical "how much of this order has actually
been filled" counter. A regression would let a cPT holder double-fill against the
same `orderSize`; a missing ceiling would let fills exceed the cPT holder's
committed size. Bit-OR-into-bitfield with no clear path makes the terminal
latch tamper-resistant.

**Mechanism**

Preflight at `src/CorkRolloverContract.sol:755` rejects any fill while the terminal
bit is set (`CorkRolloverContract__PhaseAlreadyConsumed`) and at `:761` any fill that would
push `rolled + fillAmount > fillContext.orderSize` (`CorkRolloverContract__OverfillCeiling`). The
load-bearing accumulator write at `src/CorkRolloverContract.sol:988-989` adds
`actualRolled` to `$.rolled[orderDigest]`; the terminal bit OR at `:991` sets
`PHASE_0_TERMINAL_BIT` when either `newRolled == fillContext.orderSize` or the order
disallows partial fills.

**Threat without**

Double-fill across the same `orderSize`; rollover contract capacity counted twice;
INV-DST-CST-REACHABLE may still hold (Settler ledger remains consistent) but
cPT-holder capacity accounting silently corrupts.

**Defense site(s)**

- `src/CorkRolloverContract.sol:169` (`PHASE_0_TERMINAL_BIT` constant)
- `src/CorkRolloverContract.sol:755,761` (preflight gates)
- `src/CorkRolloverContract.sol:988-989` (accumulator write)
- `src/CorkRolloverContract.sol:991` (terminal-bit OR)

**Related invariants**

- BS-ST-20
- INV-PARAMS-SETTLER-PIN
- INV-DST-FLOOR
- INV-5

---

### N-INV-FILLER-SETTLED-STICKY — settlement latch is set-only

**Statement**

For every `(orderId, filler, subFiller)` tuple, the Settler's
`$.fillerSettled[orderId][filler][subFiller]` latch in PartialSettler's storage
struct (`src/PartialSettler.sol:91`) is set-only.
Once flipped true — whether by partial-mode in-frame settlement or defaulter `reclaim` —
it stays true for the contract's lifetime. Corollary: a `(orderId, filler, subFiller)`
tuple is paid out exactly once across the union of in-frame settlement and `reclaim`.

**Motivation**

The same filler must not be paid twice for the same residual. The latch
unifies partial-mode settlement and defaulter `reclaim` into a single
exactly-once payout space, regardless of which path actually drained the
residual.

**Mechanism**

Partial-mode settlement at `src/PartialSettler.sol` pre-checks the latch
(revert `Settler__FillerAlreadySettled`) and flips it at `:394`. Defaulter
`reclaim` at `src/PartialSettler.sol` pre-checks (revert
`Settler__NoResidualToReclaim`) and flips the latch at `:438`. No path
clears `fillerSettled[id][f][subFiller]` back to false.

**Threat without**

Double-pay: a filler whose residual was already drained by `reclaim` could
otherwise trigger settlement (or vice versa) and collect a second time;
INV-DST-CST-REACHABLE silently inverts into INV-DST-CST-DOUBLE-DRAIN.

**Defense site(s)**

- `src/ExactSettler.sol and src/PartialSettler.sol` (`fillerSettled` slot in `BaseSettlerStorage`)
- `src/ExactSettler.sol and src/PartialSettler.sol` (partial settlement pre-check + flip)
- `src/ExactSettler.sol and src/PartialSettler.sol` (defaulter `reclaim` pre-check + flip)

**Related invariants**

- INV-DST-CST-REACHABLE
- BS-FN-045
- INV-DEFAULTER-RECOUP

---

### N-INV-PARTIAL-RESIDUAL-RECONCILES-TO-TOTAL — escrow accumulator equals sum of per-filler

**Statement**

For every partial-mode `orderDigest`, the sum of
`$.fillerDstCstResidual[orderDigest][filler][subFiller]` across every filler that has
ever rolled equals the order-level accumulator
`$.totalDstCstEscrowed[orderDigest]` at every observable moment between
transactions. The two slots move together: a fill increments both by
`dstProduced`, partial-mode in-frame settlement decrements both by `residual`, and a
defaulter `reclaim` decrements both by `amount`.

**Motivation**

The order-level accumulator is the canonical "how much dstCST is escrowed
for this order" — used by off-chain indexers and by chain-internal
view helpers. If it drifts from the per-filler sum, downstream accounting
diverges and INV-DST-CST-RECONCILES (the Settler-balance pin) can no longer
be derived from per-order ledgers.

**Mechanism**

Paired writes at three load-bearing sites in `src/PartialSettler.sol`:
- `_writePartialFillRecord` at `:285-286` increments both
  `totalDstCstEscrowed[orderDigest]` and
  `fillerDstCstResidual[orderDigest][filler][subFiller]` by `dstProduced`.
- Partial settlement reads `residual`, zeroes the per-filler
  slot, and `-= residual` on the order accumulator.
- Defaulter `reclaim` at `:438-440` reads `amount`, zeroes the per-filler
  slot, and `-= amount` on the order accumulator.

**Threat without**

Any future writer that drops one of the three paired writes (e.g., forgets
to decrement the order accumulator on settlement) produces a cross-tx
interleaving where the per-filler residual sum diverges from the order
escrow accumulator; off-chain indexers double-count residual; on-chain
overflow eventually possible on the accumulator slot.

**Defense site(s)**

- `src/ExactSettler.sol and src/PartialSettler.sol` (`_writePartialFillRecord` paired increment)
- `src/ExactSettler.sol and src/PartialSettler.sol` (partial settlement paired decrement)
- `src/ExactSettler.sol and src/PartialSettler.sol` (defaulter `reclaim` paired decrement)

**Related invariants**

- INV-DST-CST-REACHABLE
- N-INV-FILLER-SETTLED-STICKY
- INV-NEW-POLARITY-ISOLATION
- BS-FN-045

---

## Appendix — handler-to-invariant map

| Handler (`test/invariant/handlers/`) | Invariants exercised |
| --- | --- |
| `OrderStateMachineHandler.sol` | BS-ST-20; INV-NEW-POLARITY-GATE; BS-FN-045 (indirect) |
| `DstCstReconcileHandler.sol` | INV-NEW-POLARITY-ISOLATION; N-INV-PARTIAL-RESIDUAL-RECONCILES-TO-TOTAL |
| `DstCstReachabilityHandler.sol` | INV-DST-CST-REACHABLE; BS-FN-045 |
| `DefaulterReclaimHandler.sol` | INV-DEFAULTER-RECOUP |
| `FillerAuthHandler.sol` | INV-FILLER-AUTH |
| `ApprovedSettlerHandler.sol` | INV-SETTLER-APPROVED |
| `SettlerPinHandler.sol` | INV-PARAMS-SETTLER-PIN |
| `PendingTimelockMirrorHandler.sol` / `FactorySoleTrustWriterHandler.sol` / `FactoryQueueChecksOwnerHandler.sol` | INV-TRUST-CONFIG-DELAY |
| `RolloverContractRolloverHandler.sol` | INV-CPT-CONTAINED; INV-DST-FLOOR; INV-5; DSR-1; DSR-2 |
| `DefaultAttestersSeedHandler.sol` | INV-DEFAULT-ATTESTERS-FACTORY-SEEDED |
| `SettlerPauseHandler.sol` | INV-PAUSE-GATES-ALL-ENTRYPOINTS |
| `RolledMonotoneHandler.sol` | N-INV-ROLLED-MONOTONE-AND-BOUNDED |
| `FillerSettledStickyHandler.sol` | N-INV-FILLER-SETTLED-STICKY |
| `PartialResidualReconciliationHandler.sol` | N-INV-PARTIAL-RESIDUAL-RECONCILES-TO-TOTAL |
