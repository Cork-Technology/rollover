# Cork Rollover — Protocol Spec

This document is the entry point into the Cork Rollover spec documentation
set. It catalogs every per-unit and cross-cutting markdown file, defines the
domain vocabulary used across them, and recommends a reading order for new
contributors, integrators, and auditors.

The spec set describes the contracts under `src/`. `docs/agent-context/` is the
canonical curated bundle for audit agents; this `docs/spec/` tree is
supplementary protocol reference.

Scope alignment: `src/BaseFiller.sol` is in scope.
`src/EvcRolloverAdapter.sol` is adapter/integration context only and is out of
audit scope unless explicitly re-added in `SCOPE.md`.

`scripts/ci/check-spec-citations.py` runs in CI as a doc-integrity lint,
verifying that `file:line` references in this tree resolve against the source
tree.

For deployment operations (RPC endpoints, registry onboarding, multisig
runbooks), see **[`docs/DEPLOY.md`](../DEPLOY.md)** — operational and out of
spec scope.

---

## Table of Contents

### Per-unit deep dives (`docs/spec/md/units/`)

| Unit | File | Scope |
| --- | --- | --- |
| Settler | [units/settler.md](md/units/settler.md) | `src/ExactSettler.sol and src/PartialSettler.sol` — origin/destination intent settler, the only state-mutating entry point for the rollover flow. |
| RolloverContract | [units/rolloverContract.md](md/units/rolloverContract.md) | `src/CorkRolloverContract.sol` — per-pool rolloverContract that owns the rollover hook stack, premium accounting, and dstCST minting. |
| Factory | [units/factory.md](md/units/factory.md) | `src/CorkRolloverContractFactory.sol` — CWIA clone factory, allowlist registry, settler pin, IRolloverContractLens dispatcher. |
| Fillers | [units/fillers.md](md/units/fillers.md) | `src/BaseFiller.sol` is in scope. `src/EvcRolloverAdapter.sol` is adapter/integration context only and is out of audit scope unless explicitly re-added in `SCOPE.md`. |
| Modules | [units/modules.md](md/units/modules.md) | `src/modules/` — pluggable adapters (e.g. `ApproveModule`, `ScopedTransferModule`) attached via Cork module registry. |
| Libraries | [units/libraries.md](md/units/libraries.md) | `src/libraries/` — pure helpers (typehashes, order hashing, math, fillerData codec). |
| Interfaces | [units/interfaces.md](md/units/interfaces.md) | `src/interfaces/` — external ABI surface (`ICorkRolloverContract`, `IRolloverContractLens`, `IPoolShare`, ERC-7683, etc.). |
| Phoenix integration | [units/phoenix-integration.md](md/units/phoenix-integration.md) | Boundary with Cork Phoenix — `CorkPoolManager`, `PoolShare`, `unwindMint`/`deposit`, registry lookups. |

### Cross-cutting analyses (`docs/spec/md/`)

| Topic | File | Purpose |
| --- | --- | --- |
| Threat model | [THREAT-MODEL.md](md/THREAT-MODEL.md) | STRIDE-style enumeration of cross-unit threats with mitigation pointers. |
| Actor matrix | [ACTOR-MATRIX.md](md/ACTOR-MATRIX.md) | Roles (cPT holder, filler, settler-admin, factory-owner, attester, end-user) with capabilities and trust assumptions. |
| Token flows | [TOKEN-FLOWS.md](md/TOKEN-FLOWS.md) | Per-phase movement of srcCST, dstCST, premium, and ERC-20 collateral across actors. |
| Interaction diagrams | [INTERACTION-DIAGRAMS.md](md/INTERACTION-DIAGRAMS.md) | Sequence diagrams for `open`/`openFor`/`fill`/in-frame settlement/`markExpired`/`cancel`/`reclaim`. |
| ERC dependencies | [ERC-DEPS.md](md/ERC-DEPS.md) | ERCs the protocol consumes or implements (ERC-712, ERC-1271, ERC-1967, ERC-7201, ERC-7484, ERC-7683, ERC-20 family). |
| Invariants (explained) | [INVARIANTS-EXPLAINED.md](md/INVARIANTS-EXPLAINED.md) | Narrative companion to `docs/INVARIANTS.md` — what each invariant defends and where it is enforced. |

### Companion glossary

| File | Purpose |
| --- | --- |
| [AUDIT-GLOSSARY.md](AUDIT-GLOSSARY.md) | Decodes audit-symbol families (`F-NN`, `H-NN`, `O-N`, `FAC-N`, `M-O-N`, `S-N`, `D-N`, `L-N`, `M-N`, `N-N`, `NIT-N`, `PR-N`) and provides stable anchors for cross-doc links. |

---

## Reading order

1. **Orient.** Start here (`SPEC.md`) for vocabulary and TOC. Skim the
   [actor matrix](md/ACTOR-MATRIX.md) and [token flows](md/TOKEN-FLOWS.md) for
   the mental model.
2. **Lifecycle walk-through.** Read [interaction diagrams](md/INTERACTION-DIAGRAMS.md)
   end-to-end — one happy path (`open` → `fill` with in-frame settlement) plus one failure
   path (`markExpired` and `reclaim`).
3. **Core unit deep-dives.** [Settler](md/units/settler.md), then
   [RolloverContract](md/units/rolloverContract.md), then [Factory](md/units/factory.md). These
   three units own ~90 % of mutating logic.
4. **Periphery.** [Fillers](md/units/fillers.md),
   [Modules](md/units/modules.md),
   [Libraries](md/units/libraries.md), [Interfaces](md/units/interfaces.md).
5. **Boundary.** [Phoenix integration](md/units/phoenix-integration.md) for the
   off-tree contracts the rolloverContract talks to.
6. **Adversarial lens.** [Threat model](md/THREAT-MODEL.md),
   [invariants](md/INVARIANTS-EXPLAINED.md), and the
   [audit glossary](AUDIT-GLOSSARY.md) for finding-symbol decoding.
7. **ERC conformance.** [ERC dependencies](md/ERC-DEPS.md) when integrating an
   external protocol or wallet.

Auditors with a specific finding-symbol in hand (e.g. `[H-02]` or `[O-5]`) can
jump straight to the [glossary](AUDIT-GLOSSARY.md) for the originating memo.

---

## Atomic-fill lifecycle (`Settler.fill`)

`Settler.fill(orderId, originData, fillerData)` is the ERC-7683 destination
fill surface and is now an explicit tag router. `ATOMIC_TAG = 255` wraps
rollover + premium inner legs, `premiumCap`, and `cptHolderSig` and runs the
atomic lifecycle. `HookPhase.ROLLOVER` and `HookPhase.PREMIUM` route to the
cPT-holder-opt-in async premium lifecycle and require signed
`premiumPaymentMode = ATOMIC_OR_SEPARATE`. Unsupported tags revert with
`Settler__AtomicFillRequired`. There is no `fillAtomic` selector.

There are no separate named async premium entrypoints. cPT-holder-opt-in async uses
the same `fill(...)` surface with ROLLOVER / PREMIUM phase tags: rollover-only
residual, premium-later, and reclaim for cPT holders that opt into it.

A single successful atomic `fill` runs admit → rollover → premium → settle in
one transaction frame. Any factory/rollover-contract/hook/prevalidation revert rolls back
the entire frame (no premium catch/park, no partial latch commit).

### Canonical happy path (status `Opened` or direct-fill from `None`)

1. **Envelope decode.** `LibFillerPayloadExternal.decodeAtomicPayloads`
   peels the envelope and decodes both inner payloads in one external library
   call. Rollover-leg shape and premium-leg zero-sentinel shape are validated
   before any rollover-side token movement, hook dispatch, or state writes.
2. **Admission.** If `statusOnEntry == None`, `_validateOrderForFill` runs the
   same shape checks as `openFor` (factory-attested rolloverContract, deadlines,
   `INV-USER-IS-ROLLOVER_CONTRACT-OWNER`, pool/expiry gates, non-zero `rolloverIntentHash`).
   The envelope `cptHolderSig` satisfies `INV-DIRECT-FILL-CPT-HOLDER-SIG` on the
   `None → Opened` transition. Premium-hook attestation is validated live inside
   `_handlePhasePremium` via ERC-7484 `check` — there is no separate
   `prevalidateExecutorHooks` admission call.
3. **Rollover leg.** The validated rollover payload supplies
   `fillAmount`, `destination`, intent, and filler-auth data.
   `safeTransferFrom(msg.sender, orderData.rolloverContract, fillAmount)` for srcCST
   (`INV-SRC-CST-PREDEPOSITED` — direct `filler → rolloverContract`, no Settler custody).
   Factory `executeIntentHooks(ROLLOVER)` runs the rolloverContract hook stack; dstCST is
   minted to `params.settler`. Settler verifies dst delivery and
   `minDstPerSrc`, then writes the partial or exact fill record.
4. **Premium leg.** `requiredPremium = ceil(dstProduced × minPremiumPerShare / 1e18)`
   is computed and pinned to `payload.premium` (bounded by `premiumCap`).
   Settler latches `premiumFired`, then
   `safeTransferFrom(msg.sender, orderData.rolloverContract, requiredPremium)` — direct
   `filler → rolloverContract`. Settler verifies
   `rolloverContract.balanceAfter - rolloverContract.balanceBefore == requiredPremium`
   (`Settler__PremiumDeliveryMismatch` on mismatch).
5. **RolloverContract premium dispatch.** `_handlePhasePremium` receives premium already
   at the rolloverContract. Standing balance is
   `balanceOf(rolloverContract) - ctx.premium`; premium hooks run under
   `INV-PREMIUM-HOOKS-CANNOT-SWEEP-STANDING-BALANCE`; `PremiumFired` emits
   resolved `ctx.subFiller`.
6. **Same-frame settle.** `_payPremiumAndReleaseDstCst` releases escrowed dstCST to
   `fillerDestination` and terminalizes the order when applicable.

### Pre-open fill from `OrderStatus.None`

`fill` remains callable when status is `None` (before a separate `openFor`).
The atomic frame may still transition `None → Opened` via cPT-holder sig on the
envelope, but callers SHOULD prefer an explicit `openFor` first to anchor FSM
state. `BaseFiller` calls `openFor` only when status is not yet `Opened`, then
dispatches one atomic `fill` per `execute` — no separate post-rollover premium
`fill` and no helper-side `settle` call. `src/EvcRolloverAdapter.sol` follows a
similar adapter path, but remains adapter/integration context only and is out
of audit scope unless explicitly re-added in `SCOPE.md`.

Related invariants: `INV-ATOMIC-FILL-CANONICAL`, `INV-PREMIUM-PAID-RELEASES-DST`,
`INV-PREMIUM-HOOK-REVERT-CASCADES`, `INV-PREMIUM-HOOKS-CANNOT-SWEEP-STANDING-BALANCE`,
`INV-FILLER-AUTH`, `INV-DST-CST-REACHABLE`, `INV-USER-IS-ROLLOVER_CONTRACT-OWNER`.

---

## Glossary — domain terms

The terms below are used throughout the spec set. Where a term names a specific
contract or function, the canonical Solidity source is the authoritative
definition; this glossary fixes the prose meaning.

- **cPT holder.** The cPT holder of a rollover intent; the
  EOA or contract whose signature authorizes a `Settler.open` /
  `Settler.openFor` call and whose collateral is debited.
- **Filler.** The party that picks up an open intent and supplies the
  destination-side liquidity. Bound to the order by FillerAuth (EIP-712 sig
  over `(orderDigest, destination, subFiller)`) and optionally pinned via the
  exclusive-filler binding (enforced via revert in `Settler` and
  `LibFillerAuth`).
- **Settler.** `src/BaseSettler.sol` holds shared lifecycle logic; `src/ExactSettler.sol`
  and `src/PartialSettler.sol` hold mode-specific storage/accounting hooks.
  Holds escrow, mediates the rolloverContract hook stack, and emits all status
  transitions.
- **RolloverContract.** `src/CorkRolloverContract.sol` — per-pool opinionated rollover host. Owns
  premium accounting, dstCST minting, and the four-hook RolloverIntent
  (pre/mid/post rollover + premium). Pinned to a `Settler` via the factory.
- **Factory (`CorkRolloverContractFactory`).** CWIA clone factory for rolloverContracts, plus
  allowlist registry, settler pin, and the live `IRolloverContractLens` view dispatcher
  that exposes trust config to fillers.
- **Module.** A pluggable in-scope hook contract (e.g. `ApproveModule` or
  `ScopedTransferModule`) attached via the Cork module registry and exposed to
  the rolloverContract through ERC-7484 attestation. `EvcRolloverAdapter` is not a rolloverContract
  module and is adapter/integration context only.
- **Intent.** The signed off-chain message that authorizes a rollover; carries
  `RolloverParams` (src/dst pool IDs, settler pin, expiry, deadline, etc.) and
  is recoverable via EIP-712 typehash.
- **CWIA (Clones-With-Immutable-Args).** Minimal-proxy pattern used by the
  factory; the rolloverContract's immutable per-pool config is appended to clone
  bytecode, not stored in slots.
- **CPT / cPT (Cork Principal Token).** The principal leg of a Cork market;
  redeemable 1:1 for the underlying at expiry.
- **CST / cST (Cork Swap Token).** The market's yield/coverage leg. Two
  flavors appear in the docs:
  - **srcCST.** The source-pool CST the cPT holder is rolling **out of**.
  - **dstCST.** The destination-pool CST the cPT holder is rolling **into**, minted by
    the rolloverContract during the rollover hook stack.
- **`PoolShare`.** Phoenix's ERC20Burnable + ERC20Permit token used as the
  on-chain representation of CST balances. Plain — no blacklist, pause, hooks,
  or upgradeable surface.
- **F-PUSH.** Filler-Push accounting invariant: the filler funds the
  destination leg up-front; the rolloverContract reconciles produced dstCST to the
  promised minimum (`minDstPerSrc`) and the filler pulls the premium overage
  via `BaseFiller`'s post-fill refund tail.
- **ROLLOVER phase.** The mid-fill window during which the rolloverContract burns
  srcCST, unwinds the source pool, mints dstCST into the destination pool, and
  reconciles balances under `MidPhaseDstCstDrain` guards.
- **PREMIUM phase.** The pre/post-rollover window during which the filler's
  premium is collected, capped (`premium → premiumCap`), and refunded
  (`PremiumRefunded`) based on the exact `requiredPremium` computed from
  `dstCstProduced`.
- **RolloverIntent hooks.** Four-callback stack the Settler invokes on the
  rolloverContract: `preRollover`, `midRollover`, `postRollover`, `premium`.
  The standard dstCPT post-rollover hook routes the minted-amount register:
  `dstCptAfterDeposit - dstCptBeforeDeposit`, written in rolloverContract transient
  storage after deposit, to the cPT roller, so it does
  not require zero standing dstCPT and does not sweep pre-existing dstCPT.
- **FillerAuth.** EIP-712 envelope binding `(orderDigest, destination, subFiller)`;
  enforced at `Settler.fill`. Defeats race attacks because adversary's P&L is
  net-negative regardless of who relays the fill. Does not bind phase, fillAmount,
  premium, intent, minDstPerSrc, deadlines, or nonce — bearer-style by design.
- **Attester / Attester threshold.** ERC-7484 attestation requiring a quorum
  of trusted attesters to vouch for a module type before the rolloverContract will
  invoke it.
- **Trust-config time-lock.** Governance-configurable queue-and-apply delay
  (external `TimelockController`, bounded by `MAX_TRUST_CONFIG_DELAY = 4 hours`)
  on the factory-relayed `rolloverContract.setTrustConfig`; `pendingTrustConfig()` exposes
  the in-flight change so fillers can simulate the next state.
- **Defaulter.** A filler that completes its destination leg but fails to settle
  the produced dstCST; resolved by permissionless `reclaim(orderId, filler, subFiller,
  originData)` which routes the residual to `orderData.rolloverContract`.
- **`originData` / `fillerData`.** Opaque ABI-encoded blobs passed across the
  ERC-7683 boundary. `originData` carries the order envelope (signed by the
  cPT holder); `fillerData` is a 10-tuple appended by the filler, carrying
  `premiumFor` for third-party premium payment, optional `FillerAuth`
  signature, `subFiller`, and direct-fill `cptHolderSig`.
- **`minDstPerSrc`.** Filler-supplied lower bound on dstCST produced per
  srcCST burned, packed into the 10-tuple; defends against hostile cPT holder
  configurations that would zero the filler's mint.
- **`minPremiumPerShare`.** cPT-holder-signed lower bound on premium per produced
  dstCST share (1e18-scaled). `requiredPremium = Ceil(produced ×
  minPremiumPerShare / 1e18)` is enforced inside the atomic `fill` premium leg.
- **Order status.** Six-value enum (`src/types/RolloverTypes.sol:20-27`):
  `None`, `Opened`, `Settled`, `Expired`, `Cancelled`, `Closing`. `None` is
  the default for a never-opened order; `Closing` is the intermediate state
  for partial-mode orders with live dstCST escrow after a cPT-holder cancel. Direct unopened
  atomic `fill` reclaim admits `OrderStatus.None` so rolloverContract dstCST
  residuals from never-opened orders can be swept after `fillDeadline`.

---

## Abbreviation table

| Abbreviation | Expansion |
| --- | --- |
| ABI | Application Binary Interface |
| CPT / cPT | Cork Principal Token |
| CST / cST | Cork Swap Token |
| CWIA | Clones-With-Immutable-Args |
| dstCST | destination-pool CST (target of the rollover) |
| EIP | Ethereum Improvement Proposal |
| ERC | Ethereum Request for Comments |
| EOA | Externally-Owned Account |
| EVC | Ethereum Vault Connector |
| F-PUSH | Filler-Push accounting invariant |
| INV-* | Invariant identifier (see `docs/INVARIANTS.md`) |
| LSP | Language Server Protocol |
| OZ | OpenZeppelin |
| PoC | Proof of Concept |
| PR | Pull Request |
| RFC | Request for Comments (internal design doc) |
| srcCST | source-pool CST (origin of the rollover) |
| spec | Protocol Spec (this doc set) |
| STRIDE | Spoofing, Tampering, Repudiation, Info-disclosure, DoS, Elevation-of-privilege |
| TOC | Table of Contents |
| cPT holder | cPT holder (intent signer) |
| WT | Worktree |

---

## See also

- [`docs/INVARIANTS.md`](../INVARIANTS.md) — canonical invariant ledger.
- [`docs/DEPLOY.md`](../DEPLOY.md) — operational deployment runbook (not in spec scope).
- [`AUDIT-GLOSSARY.md`](AUDIT-GLOSSARY.md) — audit-symbol decoder.
