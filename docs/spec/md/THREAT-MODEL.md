# Cork Rollover — Threat Model

> _Supplementary protocol reference. The canonical bundle for AI auditors is [`docs/agent-context/`](../../agent-context/README.md). Code in `src/` is the source of truth when docs disagree._

This document maps the trust boundaries, adversaries, and concrete attack
scenarios for Cork Rollover. Resolved against current `src/`, generated against
the [`threat-model`](../../agent-context/spec/threat-model.md) format and cross-referenced
against [`docs/INVARIANTS.md`](../../INVARIANTS.md) (canonical ledger) and the
per-unit pages under [`docs/spec/md/units/`](./units/).

**Scope.** Single-chain ERC-7683 rollover settler + per-cPT holder CWIA rolloverContract +
Settler-gated factory. Phoenix `IPoolManager` / `IPoolShare` is treated as a
trusted external dependency. No oracle, no AMM math, no liquidation, no
upgradeable proxies. `src/BaseFiller.sol` is in scope.
`src/EvcRolloverAdapter.sol` is adapter/integration context only and is out of
audit scope unless explicitly re-added in `SCOPE.md`.

**What this doc covers.** Trust zones, adversaries, named attack scenarios
with source-cited defense sites, the defense matrix cross-referenced to the
invariant ledger, and known residual weak spots.

**What this doc does NOT cover.** Off-chain key custody, frontend phishing,
phoenix-internal correctness (covered by the phoenix audit set), or
SDK/indexer schema-stability — these are surfaced as OPEN items in §6 but
not modelled as in-protocol scenarios.

---

## Trust boundaries

Each row is a trust zone. The protocol's correctness rests on the named
authority being honoured at the source binding.

| # | Zone | Role (one line) | Source of authority |
| --- | --- | --- | --- |
| TZ-1 | **User EOA / Safe (cPT holder)** | Same party as the rolloverContract owner; signs `OrderData` (EIP-712 / ERC-1271) and may `cancel` from non-terminal status. | `src/BaseSettler.sol` `openFor` / `_validateOrderForFill` user-sig branch + `cancel`; `INV-USER-IS-ROLLOVER_CONTRACT-OWNER` |
| TZ-2 | **Relayer / opener** | Submits `openFor`; trust-neutral — bound only by cPT-holder sig. | `src/ExactSettler.sol and src/PartialSettler.sol` `openFor` |
| TZ-3 | **Filler operator** | Pushes srcCST + premium to Settler; receives dstCST; bound by `INV-FILLER-AUTH` at fill-time. | `src/ExactSettler.sol and src/PartialSettler.sol` `fill`; `src/libraries/LibFillerAuth.sol` |
| TZ-4 | **Delegated executor** | Submits `fill` on behalf of an exclusive filler carrying `fillerAuthSig`. Payout still keys on `exclusiveFiller`. | `src/libraries/LibFillerAuth.sol` |
| TZ-5 | **Recovery keeper (permissionless)** | Anyone may crank `reclaim`/`markExpired`/`CorkRolloverContractFactory.applyTrustConfig`. Cannot redirect funds. | `BaseSettler.reclaim` / `BaseSettler.markExpired`; `src/CorkRolloverContractFactory.sol` `applyTrustConfig` |
| TZ-6 | **cPT holder = RolloverContract Owner** | Semi-trusted per-rolloverContract root. Signs `OrderData` committing the `RolloverIntent` hook hash, queues default-snapshot or custom trust config on the factory (`CorkRolloverContractFactory.queueFactoryDefaultTrustConfig` / `queueTrustConfig`), may `withdraw` rolloverContract's idle balance. CWIA-immutable. | `src/CorkRolloverContract.sol` owner-checks via CWIA trailer; `src/CorkRolloverContractFactory.sol` queue/cancel cPT holder gate; `INV-ROLLOVER_CONTRACT-OWNER-IMMUTABLE` |
| TZ-7 | **Approved Settler (contract)** | Single allowlisted Settler may dispatch into the factory; pinned via `INV-SETTLER-APPROVED`. | `src/CorkRolloverContractFactory.sol` `executeIntentHooks` allowlist gate |
| TZ-8 | **Factory admin / operational roles (AccessControl)** | `DEFAULT_ADMIN_ROLE` administers roles; dedicated roles approve/revoke Settlers and schedule factory defaults. Admin-role rotation and self-renounce use inherited OZ `AccessControl`. Factory `owner()` is a Phoenix-style deployment identity only. | `src/CorkRolloverContractFactory.sol` `approveSettler`/`revokeSettler`; OZ `AccessControl` |
| TZ-9 | **Settler admin / recovery / pauser / unpauser (split roles)** | `DEFAULT_ADMIN_ROLE` + `RECOVERY_ROLE` + `PAUSER_ROLE` + `UNPAUSER_ROLE`; `whenNotPaused` halts every state-mutating entrypoint. | `src/ExactSettler.sol and src/PartialSettler.sol` `pause`/`unpause` + role-grant in constructor |
| TZ-10 | **ERC-7484 attester set** | Live-checked module attestation at every rolloverContract phase; cPT holder-rotatable behind the configured `INV-TRUST-CONFIG-DELAY`. | `src/CorkRolloverContract.sol` `_executeIntentCalls` (`IERC7484.check`) |
| TZ-11 | **Phoenix `IPoolManager` / `IPoolShare`** | External trust set. RolloverContract derives `PoolManager` per-call via `IPoolShare(token).poolId()`; output is delta-measured, not return-value-trusted (`DSR-1`). | `src/CorkRolloverContract.sol` `unwindMint`/`deposit` call sites; `src/ExactSettler.sol and src/PartialSettler.sol` `expiry` gate |
| TZ-12 | **Hook target module (delegatecall'd)** | Stateless adapter under `src/modules/`. Executes inside rolloverContract storage frame; attested by ERC-7484; pre-`delegatecall` code-presence check. | `src/CorkRolloverContract.sol` `_executeIntentCalls` |
| TZ-13 | **Cross-chain executor (ERC-7683)** | Inert at HEAD — `originChainId == destinationChainId == block.chainid` hard-asserted. | `src/ExactSettler.sol and src/PartialSettler.sol` `Settler__WrongOriginChain` / `__WrongDestinationChain` |
| TZ-14 | **Arbitrary observer** | Lens views only. No write capability. | `src/CorkRolloverContractFactory.sol` `rolloverContractSnapshot`/`orderState`/`rolloverContractConfig` |

---

## Adversaries

Each adversary corresponds to a trust zone an attacker may compromise or
impersonate. Capability/Limit/Authority bindings cite the source gate; the
final `In-scope attacks` references the §Scenarios IDs.

### A-1: Sig-forging cPT holder impostor

**Capability:** Construct and submit arbitrary `OrderData` bytes with a forged cPT-holder signature; submit via any relayer or self.
**Limit:** Cannot satisfy OZ `SignatureChecker.isValidSignatureNow(orderData.user, …)`; cannot forge ERC-1271 result from a SCW the attacker does not control.
**Source of authority:** `src/BaseSettler.sol` `openFor` / `_validateOrderForFill` user-sig recovery; ERC-1271 fallback in `import "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol"`.
**In-scope attacks:** S-01, S-02.

### A-2: Hostile relayer / opener

**Capability:** Holds the cPT holder's signed envelope; chooses when (or whether) to call `open`/`openFor`; may mutate envelope bytes before submission.
**Limit:** Envelope/payload equality check on all six envelope fields (`originSettler / user / nonce / originChainId / openDeadline / fillDeadline`) and self-binding `orderData.settler == address(this)` reject any mutation. cPT holder can self-call `open` if relayer withholds.
**Source of authority:** `src/ExactSettler.sol and src/PartialSettler.sol` `_validateOrderCommon`.
**In-scope attacks:** S-03, S-04.

### A-3: Hostile filler operator

**Capability:** Calls `Settler.fill`; supplies `originData`, `minDstPerSrc` floor, premium token; controls own `fillerData` 10-tuple (including `fillerDestination` and `subFiller`).
**Limit:** `originData` digest must equal `orderId` (`Settler__OrderIdMismatch`); pool-id cross-check (`SL-14`); `RolloverParams.{src,dst}CstToken == orderData.{src,dst}CstToken`; Settler-side per-record `premiumFired` latch (`M-11`) is the authoritative replay block, with the rolloverContract-local `premiumFiredFor[digest][filler][subFiller]` mapping as parallel local replay protection; mid-hook value-skim bounded by cPT-holder-signed `params.minSharesOut` (`INV-DST-FLOOR`); dstCST drain rejected by `INV-5`; dstCPT residue rejected by `INV-CPT-CONTAINED`; `Settler__DstProducedNotDelivered` post-condition.
**Source of authority:** `src/ExactSettler.sol and src/PartialSettler.sol` `fill`; `src/CorkRolloverContract.sol` `_handlePhaseRollover`.
**In-scope attacks:** S-05, S-06, S-07, S-08.

### A-4: Race-attacking executor

**Capability:** Observes an exclusive-filler order in the mempool; submits `fill` with their own crafted `fillerData`; attempts to redirect dstCST or replay a stolen `fillerAuthSig`.
**Limit:** `INV-FILLER-AUTH` requires `msg.sender == exclusiveFiller` OR EIP-712 sig over `FillerAuth(orderDigest, destination, subFiller)`. Replayed sig binds destination + subFiller → attacker only sends dstCST to the original filler's pre-chosen destination for that sub-filler slot; their srcCST + premium are sunk. P&L strictly net-negative.
**Source of authority:** `src/libraries/LibFillerAuth.sol`.
**In-scope attacks:** S-09.

### A-5: Hostile recovery keeper

**Capability:** Permissionlessly calls `reclaim` / `markExpired` / `CorkRolloverContractFactory.applyTrustConfig` to grief honest fillers or cPT holders.
**Limit:** Payout target is fixed at fill-time (`fillerDestination[orderDigest][filler][subFiller]` in partial mode; `rolloverAccounting[orderDigest].settlementDestination` in exact mode); keeper only supplies `filler` / `subFiller` as indices. `reclaim` blocked until `block.timestamp > fillDeadline` (`Settler__ReclaimBeforeFillDeadline`) and the order status is reclaimable (`Settler__OrderNotReclaimable`). `markExpired` reverts `Settler__OrderNotExpirable` (via `isMarkExpiredStatus`) once the order status leaves the expirable set after PREMIUM.
**Source of authority:** `BaseSettler.reclaim` / `BaseSettler.markExpired`.
**In-scope attacks:** S-10, S-11.

### A-6: Compromised cPT holder

**Capability:** Signs `OrderData` committing an arbitrary `RolloverIntent` hash; chooses `premiumHooks` freely (non-invariant); queues malicious attester rotation; may `withdraw` rolloverContract's idle ERC-20 balance.
**Limit:** Cannot drain protocol-side dstCST mid-leg (`INV-5`), cannot leave dstCPT residue (`INV-CPT-CONTAINED`); mid-hook value-skim bounded by cPT-holder-signed `params.minSharesOut` (`INV-DST-FLOOR`) — the rolloverContract enforces no constraint on caSrc balance during mid (cross-CA rollover support). Attester rotation gated by the configured `INV-TRUST-CONFIG-DELAY`. CWIA-immutable owner address — no transfer.
**Source of authority:** `src/CorkRolloverContract.sol` `_handlePhaseRollover` guard band; `_executeIntentCalls` ERC-7484 gate; `src/CorkRolloverContractFactory.sol` `queueFactoryDefaultTrustConfig` / `queueTrustConfig` / `applyTrustConfig` / `cancelTrustConfig` (cPT-holder-only queueing on the external per-rolloverContract trust-config `TimelockController`).
**In-scope attacks:** S-12, S-13, S-14.

### A-7: Compromised approved Settler contract

**Capability:** Crafts arbitrary `(rolloverContract, orderDigest, intent, cptHolderSig, fillContext, orderData)` and forwards to `CorkRolloverContractFactory.executeIntentHooks`.
**Limit:** Three composed gates — factory allowlist (`INV-SETTLER-APPROVED`), `fillContext.originSettler == msg.sender` factory latch, `orderData.rolloverParams.settler == fillContext.originSettler` rolloverContract pin (`INV-PARAMS-SETTLER-PIN`). Admin instant `revokeSettler` kill-switch; atomic v1→v2 swap one tx.
**Source of authority:** `src/CorkRolloverContractFactory.sol` `executeIntentHooks` allowlist + fill-context latch; `src/CorkRolloverContract.sol` `_validateRolloverPreflight`.
**In-scope attacks:** S-15.

### A-8: Compromised factory admin

**Capability:** Administers roles; if also holding the dedicated operational role, calls `approveSettler` / `revokeSettler` or sets factory-default rotations; attempts to renounce or transfer admin.
**Limit:** Factory defaults rotations are bounded by attester-list and registry-code validation; delayed defaults governance must be supplied by assigning `DEFAULTS_MANAGER_ROLE` to external governance/timelock. `renounceOwnership` only clears the Phoenix-style owner identity; role self-renounce follows inherited OZ `AccessControl`. Approved-but-malicious Settler still pinned by `INV-PARAMS-SETTLER-PIN` rolloverContract-side. `ROLLOVER_CONTRACT_IMPLEMENTATION` is `immutable`.
**Source of authority:** `src/CorkRolloverContractFactory.sol` admin surface.
**In-scope attacks:** S-16.

### A-9: Compromised Settler pauser

**Capability:** Calls `Settler.pause()`; indefinitely halts new state transitions.
**Limit:** Cannot redirect funds; only blocks new transitions. Defaulter path remains reachable post-`fillDeadline` via `INV-DEFAULTER-RECOUP` once unpaused. Split `PAUSER_ROLE` / `UNPAUSER_ROLE` allows multi-key custody.
**Source of authority:** `src/ExactSettler.sol and src/PartialSettler.sol` `pause`/`unpause` (split roles).
**In-scope attacks:** S-17.

### A-10: Non-attested hook target

**Capability:** cPT holder includes an unattested target address in one of the `RolloverIntent` hook arrays (`preRolloverHooks`/`midRolloverHooks`/`postRolloverHooks`/`premiumHooks`).
**Limit:** Pre-`delegatecall` code-presence check + `IERC7484.check(target, moduleType)` revert the dispatch frame before any state effect.
**Source of authority:** `src/CorkRolloverContract.sol` `_executeIntentCalls`.
**In-scope attacks:** S-18.

### A-11: Phoenix-impersonating token

**Capability:** Filler/cPT holder supplies a caller-controlled `srcCstToken`/`dstCstToken` that does not back a real phoenix `PoolShare`.
**Limit:** RolloverContract derives pool-id from `IPoolShare(token).poolId()` and cross-checks against `RolloverParams.{src,dst}PoolId`. Settler pre-validates `IPoolShare(token).expiry() > orderData.fillDeadline` at `open`/`openFor`. Sibling CPT derived via `IPoolManager.shares(MarketId)`.
**Source of authority:** `src/ExactSettler.sol and src/PartialSettler.sol` `_validateOrderCommon` pool-expiry gate; `src/CorkRolloverContract.sol` pool-id cross-check.
**In-scope attacks:** S-19.

### A-12: Cross-chain envelope spoofer

**Capability:** Submits a `GaslessCrossChainOrder` with `originChainId` / `destinationChainId` not matching `block.chainid`.
**Limit:** Hard revert via `Settler__WrongOriginChain` / `Settler__WrongDestinationChain`. Inert until cross-chain wiring re-enabled.
**Source of authority:** `src/ExactSettler.sol and src/PartialSettler.sol` `_validateOrderCommon` chain-id gates.
**In-scope attacks:** S-20.

### A-13: Arbitrary observer

**Capability:** Reads any lens view.
**Limit:** Views are `staticcall`-safe; no privilege token is ever returned.
**Source of authority:** `src/CorkRolloverContractFactory.sol` lens views.
**In-scope attacks:** (none — bounded leak is design-accepted, see §Known weak spots).

---

## Scenarios

Each scenario is a concrete attack pathway. `Defense site` cites the
exact revert or check that blocks (or mitigates) the attack. `Related
invariant` references a `### CODE` heading in `docs/INVARIANTS.md`.

### S-01: Forged cPT-holder signature opens a non-existent user's order

**Adversary:** A-1
**Precondition:** Attacker controls a relayer slot or self-submits with arbitrary calldata.
**Mechanism:** Attacker constructs `GaslessCrossChainOrder` with `orderData.user` set to a victim address; signs with attacker's own key; submits to `openFor`.
**Defense site:** `src/BaseSettler.sol` `openFor` invokes `SignatureChecker.isValidSignatureNow(orderData.user, digest, signature)` which rejects unless the recovered signer matches the embedded user or the embedded user is an ERC-1271 SCW that returns the magic value.
**Related invariant:** `BS-ST-20`
**Status:** BLOCKED

### S-02: Repudiated cPT holder order

**Adversary:** A-1 (the cPT holder themselves attempting to repudiate)
**Precondition:** cPT-holder signed and submitted an order; later denies signing.
**Mechanism:** cPT holder claims the on-chain order is unauthorized.
**Defense site:** cPT-holder EIP-712 signature, digest-bound ERC-7683 `Open` event, and lifecycle re-decode of `originData`. Cancel requires fresh EIP-712 sig over `CancelOrder(orderId, orderSalt)`.
**Related invariant:** `BS-ST-20`
**Status:** BLOCKED (non-repudiation by EIP-712 + on-chain event)

### S-03: Tampered envelope submitted by relayer

**Adversary:** A-2
**Precondition:** cPT holder handed signed envelope to relayer.
**Mechanism:** Relayer mutates one of `originSettler` / `user` / `nonce` / `originChainId` / `openDeadline` / `fillDeadline` between the signed bytes and the envelope on the wire.
**Defense site:** `src/ExactSettler.sol and src/PartialSettler.sol` `_validateOrderCommon` envelope/payload equality check on all six fields plus self-binding `orderData.settler == address(this)`.
**Related invariant:** `BS-ST-20`
**Status:** BLOCKED

### S-04: Relayer withholding (DoS)

**Adversary:** A-2
**Precondition:** cPT holder dependent on a single relayer.
**Mechanism:** Relayer drops or delays past `openDeadline`.
**Defense site:** cPT holder can self-call `open` (unbound `msg.sender`); `Settler__OpenAfterOpenDeadline` enforces the window.
**Related invariant:** (none — operational mitigation)
**Status:** MITIGATED (self-open available)

### S-05: Filler tampers with `originData` to redirect to a different rolloverContract

**Adversary:** A-3
**Precondition:** Order opened with one rolloverContract.
**Mechanism:** Filler crafts `originData` pointing to a different rolloverContract / pool / settler.
**Defense site:** `src/ExactSettler.sol and src/PartialSettler.sol` `fill` recomputes `_orderDigestMemory(orderData)` and reverts `Settler__OrderIdMismatch` on mismatch; pool-id cross-check at `src/BaseSettler.sol` `_validateOrderCommon`; `RolloverParams.{src,dst}CstToken` must equal `orderData.{src,dst}CstToken`.
**Related invariant:** `SL-14`
**Status:** BLOCKED

### S-06: Filler double-fires premium

**Adversary:** A-3
**Precondition:** Filler completed ROLLOVER; attempts to fire PREMIUM twice.
**Mechanism:** Filler submits a second `fill` with the same `(digest, filler)`.
**Defense site:** Settler-side authoritative replay gate — atomic `fill` sets `rec.premiumFired` / `exactRec.premiumFired` inside one frame; a second `fill` with the same slot reverts at Settler entry. RolloverContract-side `_handlePhasePremium` keeps `premiumFiredFor[digest][filler][subFiller]` as parallel local replay protection that commits only on successful atomic completion.
**Related invariant:** `M-11`
**Status:** BLOCKED

### S-07: Filler self-griefs via pathological `minDstPerSrc`

**Adversary:** A-3 (self-targeted)
**Precondition:** Filler controls `fillerData.minDstPerSrc`.
**Mechanism:** Filler sets `minDstPerSrc` such that the mint-rate floor reverts.
**Defense site:** `src/ExactSettler.sol and src/PartialSettler.sol` `fill` enforces `INV-DSTCST-FLOOR`; revert is filler-scoped and produces no third-party exposure.
**Related invariant:** `INV-DSTCST-FLOOR`
**Status:** RESIDUAL (self-grief explicitly accepted — see [units/fillers.md](./units/fillers.md))

### S-08: Hostile mid-hook value-skim or dstCST drain

**Adversary:** A-3 or A-6 (cPT holder-authored mid hook)
**Precondition:** cPT holder-authored intent includes a mid-rollover hook target attested under `MODULE_TYPE_MID_ROLLOVER_HOOK`.
**Mechanism:** Mid-hook produces less caDst than the cPT holder signed for, or pulls dstCST out of the rolloverContract before the leg finalizes. Mid-hook caSrc consumption is permitted by design (cross-CA rollover support).
**Defense site:** `_handlePhaseRollover` reverts `CorkRolloverContract__UnwindDepositShortfall(produced, floor)` when `dstProduced < params.minSharesOut` (cPT-holder-signed floor), `CorkRolloverContract__CaInsufficientForDeposit` when the mid-hook produces zero caDst, `CorkRolloverContract__MidPhaseDstCstDrain` on dstCST drain, and the finalizer reverts `CorkRolloverContract__DstCptNotRestored` / `CorkRolloverContract__SrcCptNotRestored` when either CPT balance differs from its entry snapshot.
**Related invariant:** `INV-DST-FLOOR`, `INV-5`, `INV-CPT-CONTAINED`
**Status:** BLOCKED (compromised-but-attested module is the residual threat, mitigated by `INV-TRUST-CONFIG-DELAY` attester-rotation timelock and Settler `OZ Pausable` kill-switch).

### S-09: Race-executor replays a stolen `fillerAuthSig`

**Adversary:** A-4
**Precondition:** Exclusive-filler order with a leaked `fillerAuthSig`.
**Mechanism:** Executor submits `fill` with the leaked sig and their own `fillerData.fillerDestination`.
**Defense site:** `src/libraries/LibFillerAuth.sol` recovers `(orderDigest, destination, subFiller)`; if the executor changes destination or subFiller → `Settler__UnauthorizedFiller`. If destination and subFiller are preserved, dstCST routes to the original filler's pre-chosen destination → executor's P&L strictly net-negative.
**Related invariant:** `INV-FILLER-AUTH`
**Status:** BLOCKED (replay produces net-negative outcome for attacker)

### S-10: Keeper front-runs honest premium settlement

**Adversary:** A-5
**Precondition:** cPT-holder-opt-in async order has a recorded ROLLOVER slot awaiting PREMIUM.
**Mechanism:** Keeper submits a PREMIUM phase `fill` for the recorded `(filler, subFiller)` before the original filler.
**Defense site:** `src/ExactSettler.sol and src/PartialSettler.sol` payout target is the recorded `fillerDestination`, set at ROLLOVER time. The premium payer can name only the recorded slot and cannot become the dstCST recipient.
**Related invariant:** `F-PUSH`, `M-29`
**Status:** MITIGATED (no redirection possible — accepted per design)

### S-11: Keeper triggers `markExpired` before honest filler fires PREMIUM

**Adversary:** A-5
**Precondition:** Past `fillDeadline`; ROLLOVER fired but PREMIUM not yet.
**Mechanism:** Keeper attempts `markExpired` on an exact-mode order.
**Defense site:** `BaseSettler.markExpired` reverts `Settler__OrderNotExpirable` (via `isMarkExpiredStatus`, `src/types/SettlerTypes.sol:28`) once the order status leaves the expirable set after PREMIUM has fired; pre-PREMIUM, residual defaulter-recoup is the design (`INV-DEFAULTER-RECOUP`).
**Related invariant:** `INV-DEFAULTER-RECOUP`, `INV-DST-CST-REACHABLE`
**Status:** BLOCKED (exact-mode) / MITIGATED (partial-mode asymmetric by design)

### S-12: cPT holder front-runs filler tx by rotating attesters mid-simulation

**Adversary:** A-6
**Precondition:** Filler simulating a `fill` based on the current attester set.
**Mechanism:** cPT holder queues a new attester set, hoping it lands between simulation and the filler's tx.
**Defense site:** `src/CorkRolloverContractFactory.sol` `queueFactoryDefaultTrustConfig` / `queueTrustConfig` / `applyTrustConfig` route through the external per-rolloverContract trust-config `TimelockController` using its configured bounded delay; re-queue cancels any prior pending op and resets the clock; `pendingTrustConfig(rolloverContract)` view exposes the queued state for filler simulation. The relay callback includes the queued salt and only succeeds inside the canonical `applyTrustConfig` frame for the exact queued op id, so raw timelock execution cannot bypass the delay.
**Related invariant:** `INV-TRUST-CONFIG-DELAY`
**Status:** BLOCKED (configured simulation-stability window)

### S-13: cPT holder configures malicious post-hook to leave dstCPT residue

**Adversary:** A-6
**Precondition:** cPT holder-authored intent.
**Mechanism:** Post-hook fails to consume all minted dstCPT.
**Defense site:** `src/CorkRolloverContract.sol` final guard reverts `CorkRolloverContract__DstCptNotRestored(expected, actual)` when the dstCPT balance differs from its entry snapshot.
**Related invariant:** `INV-CPT-CONTAINED`
**Status:** BLOCKED

### S-14: cPT holder routes premium to attacker

**Adversary:** A-6
**Precondition:** cPT holder accepts an order whose `OrderData.rolloverContract` is a hostile cPT holder's rolloverContract.
**Mechanism:** cPT holder's `premiumHooks` forward the premium to any address of the cPT holder's choosing.
**Defense site:** None at the contract layer — premium routing is an explicit non-invariant ("RolloverContract premium routing discretion"). `M-11` ensures filler ↔ premium-receiver identity within the tx but does not bound the downstream cPT holder routing.
**Related invariant:** `M-11`, `RolloverContract premium routing discretion`
**Status:** RESIDUAL (off-protocol mitigation: cPT holders don't accept terms from untrusted cPT holders)

### S-15: Compromised approved Settler forges `params.settler` to misroute dstCST

**Adversary:** A-7
**Precondition:** Factory admin previously approved this Settler; Settler is now compromised.
**Mechanism:** Compromised Settler forwards `OrderData` whose signed `rolloverParams.settler` does not match `fillContext.originSettler`, or tries to mutate signed rollover params.
**Defense site:** Three composed gates — `src/CorkRolloverContractFactory.sol` `executeIntentHooks` rejects unapproved Settlers (`INV-SETTLER-APPROVED`) and pins `fillContext.originSettler == msg.sender`; `src/CorkRolloverContract.sol` `_validateOrderDataBinding` pins `orderData.rolloverParams.settler == fillContext.originSettler` (`INV-PARAMS-SETTLER-PIN`). Operational kill-switch: factory revoker's instant `revokeSettler`.
**Related invariant:** `INV-SETTLER-APPROVED`, `INV-PARAMS-SETTLER-PIN`
**Status:** BLOCKED

### S-16: Factory admin approves a hostile Settler

**Adversary:** A-8
**Precondition:** Factory admin compromised.
**Mechanism:** Admin calls `approveSettler(hostile)`.
**Defense site:** Even with approval, `INV-PARAMS-SETTLER-PIN` rolloverContract-side still prevents dstCST misrouting (see S-15). Admin cannot swap `ROLLOVER_CONTRACT_IMPLEMENTATION` (`immutable`). Factory defaults rotations are bounded by validation and should be delayed through external governance/timelock role wiring when required.
**Related invariant:** `INV-PARAMS-SETTLER-PIN`, `INV-DEFAULT-ATTESTERS-FACTORY-SEEDED`
**Status:** MITIGATED (defence-in-depth — admin compromise reduces to cPT holder-level capability)

### S-17: Settler pauser pauses indefinitely

**Adversary:** A-9
**Precondition:** Pauser key compromised.
**Mechanism:** Indefinite `Pausable._pause()` halts every state-mutating entrypoint.
**Defense site:** `BaseSettler` `whenNotPaused` on `open`/`openFor`/`fill`/`markExpired`/`reclaim`/`cancel`. Split `UNPAUSER_ROLE` permits multi-key custody. Defaulter path re-opens via `INV-DEFAULTER-RECOUP` once unpaused (or after `fillDeadline`).
**Related invariant:** `INV-PAUSE-GATES-ALL-ENTRYPOINTS`
**Status:** MITIGATED (cannot redirect funds; only delays)

### S-18: Non-attested module sneaks into hook bucket

**Adversary:** A-10
**Precondition:** cPT holder signs an intent whose hook arrays (`preRolloverHooks`/`midRolloverHooks`/`postRolloverHooks`/`premiumHooks`) include a target the current attester set rejects.
**Mechanism:** RolloverContract dispatches `delegatecall` into the unattested target.
**Defense site:** `src/CorkRolloverContract.sol` `_executeIntentCalls` checks `target.code.length > 0` then `IERC7484.check(target, moduleType)` before any `delegatecall`. Failed attestation reverts the whole frame.
**Related invariant:** `INV-DEFAULT-ATTESTERS-FACTORY-SEEDED`
**Status:** BLOCKED

### S-19: Caller-supplied token impersonates phoenix `PoolShare`

**Adversary:** A-11
**Precondition:** Attacker supplies `orderData.srcCstToken` / `dstCstToken` pointing to an attacker-controlled ERC-20 whose `poolManager()` / `poolId()` / `expiry()` views are spoofed to mimic a canonical phoenix `PoolShare`.
**Mechanism:** Settler/rolloverContract trusts the supplied token as a phoenix share, enabling the F-10 hostile-cPT holder spoofed-rolloverContract drain primitive.
**Defense site:** `src/ExactSettler.sol and src/PartialSettler.sol` `_validateOrderCommon` asks the trusted `CORK_POOL_MANAGER` singleton (immutable, set at construction from Phoenix's per-chain singleton) for the canonical swap-token of `rolloverParams.{src,dst}PoolId` and reverts `Settler__{Src,Dst}CstNotCanonical` when the supplied cST address does not match (`INV-CST-CANONICAL`). The pool ids are pulled from the EIP-712-signed `RolloverParams`, so the attacker cannot substitute a different pool id without breaking the user signature. Subsequent `IPoolShare(token).expiry()` / `poolId()` calls become safe because the token is now known to be canonical.
**Related invariant:** `INV-CST-CANONICAL`, `SL-14`
**Status:** MITIGATED-VIA-CANONICAL-CST-LOOKUP (closes baptiste F-10)

### S-20: Cross-chain envelope spoof

**Adversary:** A-12
**Precondition:** Attacker submits an order with non-matching `originChainId` / `destinationChainId`.
**Mechanism:** Submission attempts to bypass single-chain assumption.
**Defense site:** `src/ExactSettler.sol and src/PartialSettler.sol` `_validateOrderCommon` reverts `Settler__WrongOriginChain` / `Settler__WrongDestinationChain` on `!= block.chainid`.
**Related invariant:** `BS-ST-20`
**Status:** BLOCKED (cross-chain wiring inert at HEAD)

### S-21: Defaulter filler strands dstCST in rolloverContract

**Adversary:** A-3
**Precondition:** Filler fires ROLLOVER but never fires PREMIUM by `fillDeadline`.
**Mechanism:** Filler's failure leaves dstCST receivable by no party.
**Defense site:** `src/ExactSettler.sol and src/PartialSettler.sol` permissionless `reclaim(orderId, defaulterFiller, subFiller, originData)` routes cPT-holder-opt-in async residual to `orderData.rolloverContract` once `premiumPaymentMode == 1` and `block.timestamp > fillDeadline`. The status-guard admits `OrderStatus.None` to cover direct-`Settler.fill` integrations that bypass `openFor`.
**Related invariant:** `INV-DEFAULTER-RECOUP`, `INV-DST-CST-REACHABLE`
**Status:** BLOCKED

### S-22: Re-entrant module attempts to re-enter factory/Settler

**Adversary:** A-10 (a module that passes attestation but is malicious)
**Precondition:** Adversarial module attested by current ERC-7484 set.
**Mechanism:** Module re-enters `CorkRolloverContractFactory.executeIntentHooks` or any Settler entrypoint mid-dispatch.
**Defense site:** `nonReentrant` on `CorkRolloverContractFactory.executeIntentHooks` and on every Settler state-mutating entry. `Hook.Call` enforces `isDelegateCall=true, value=0, allowFailure=false`.
**Related invariant:** `INV-PAUSE-GATES-ALL-ENTRYPOINTS` (companion to the reentrancy guards)
**Status:** BLOCKED

---

## Defense matrix

Rows are scenarios; columns are the load-bearing defense site and the invariant
code. Citations link to the per-unit detail in [`docs/spec/md/units/`](./units/).

| Scenario | Defense site (primary) | Related invariant | Status |
| --- | --- | --- | --- |
| S-01 forged cPT-holder sig | `src/BaseSettler.sol` `openFor` (`SignatureChecker.isValidSignatureNow`) | `BS-ST-20` | BLOCKED |
| S-02 repudiation | cPT-holder EIP-712 sig + digest-bound ERC-7683 `Open` event; `cancel` re-sigs | `BS-ST-20` | BLOCKED |
| S-03 envelope tamper | `_validateOrderCommon` 6-field equality + self-binding | `BS-ST-20` | BLOCKED |
| S-04 relayer DoS | cPT holder self-`open`; `Settler__OpenAfterOpenDeadline` | (operational) | MITIGATED |
| S-05 originData tamper | `_orderDigestMemory` recompute → `Settler__OrderIdMismatch`; pool-id cross-check | `SL-14` | BLOCKED |
| S-06 premium replay | Settler-side authoritative latch (`rec.premiumFired` / `exactRec.premiumFired`); rolloverContract `premiumFiredFor[digest][filler][subFiller]` mirrors on successful atomic fill | `M-11`, `INV-ATOMIC-FILL-CANONICAL` | BLOCKED |
| S-07 filler self-grief | `INV-DSTCST-FLOOR` filler-supplied | `INV-DSTCST-FLOOR` | RESIDUAL (accepted) |
| S-08 mid-hook value-skim / drain | `UnwindDepositShortfall` / `CaInsufficientForDeposit` / `MidPhaseDstCstDrain` / `DstCptNotRestored` / `SrcCptNotRestored` | `INV-DST-FLOOR`, `INV-5`, `INV-CPT-CONTAINED` | BLOCKED |
| S-09 sig replay | `LibFillerAuth` `(orderDigest, destination, subFiller)` binding | `INV-FILLER-AUTH` | BLOCKED |
| S-10 settle front-run | `fillerDestination[orderDigest][filler][subFiller]` (partial) / `rolloverAccounting[orderDigest].settlementDestination` (exact) fixed at fill-time | `F-PUSH`, `M-29` | MITIGATED |
| S-11 refund race | `Settler__OrderNotExpirable` (via `isMarkExpiredStatus`) | `INV-DEFAULTER-RECOUP`, `INV-DST-CST-REACHABLE` | BLOCKED |
| S-12 attester race | `INV-TRUST-CONFIG-DELAY` configured-delay queue+apply | `INV-TRUST-CONFIG-DELAY` | BLOCKED |
| S-13 dstCPT residue | `DstCptNotRestored` | `INV-CPT-CONTAINED` | BLOCKED |
| S-14 premium routing | (none) — explicit non-invariant | `M-11`, `RolloverContract premium routing discretion` | RESIDUAL |
| S-15 compromised Settler | Allowlist + fill-context latch + `INV-PARAMS-SETTLER-PIN` | `INV-SETTLER-APPROVED`, `INV-PARAMS-SETTLER-PIN` | BLOCKED |
| S-16 compromised factory admin | RolloverContract-side pin; `ROLLOVER_CONTRACT_IMPLEMENTATION` immutable; delayed defaults rotation | `INV-PARAMS-SETTLER-PIN`, `INV-DEFAULT-ATTESTERS-FACTORY-SEEDED` | MITIGATED |
| S-17 indefinite pause | Split `UNPAUSER_ROLE`; defaulter path re-opens post-`fillDeadline` | `INV-PAUSE-GATES-ALL-ENTRYPOINTS` | MITIGATED |
| S-18 unattested module | `IERC7484.check(target, moduleType)` | `INV-DEFAULT-ATTESTERS-FACTORY-SEEDED` | BLOCKED |
| S-19 token impersonation | `CORK_POOL_MANAGER.shares(signedPoolId).swapToken == orderData.cstToken` (canonical-cST lookup against trusted Phoenix singleton) | `INV-CST-CANONICAL`, `SL-14` | MITIGATED-VIA-CANONICAL-CST-LOOKUP |
| S-20 cross-chain spoof | `Settler__WrongOriginChain` / `__WrongDestinationChain` | `BS-ST-20` | BLOCKED |
| S-21 defaulter strand | Permissionless `reclaim` with `None`-admitting status guard | `INV-DEFAULTER-RECOUP`, `INV-DST-CST-REACHABLE` | BLOCKED |
| S-22 module reentrancy | `nonReentrant` on factory + every Settler entry; `Hook.Call` constraints | `INV-PAUSE-GATES-ALL-ENTRYPOINTS` | BLOCKED |

---

## Known weak spots

These items are residual trust assumptions or defense-in-depth gaps worth
surfacing to auditors. They are NOT necessarily exploitable findings.

- **W-1: Phoenix `Pausable` DoS on in-flight orders.** Phoenix
  `IPoolManager.unwindMint` / `deposit` revert when paused; an order opened
  against a pool that later pauses cannot be filled until unpaused. User remedy
  is `markExpired` after `fillDeadline`. Filler that has fired ROLLOVER but not
  PREMIUM is defaulter-pathed to rolloverContract (`INV-DEFAULTER-RECOUP`). Pre-ROLLOVER
  filler loses an opportunity. RolloverContract has no kill-switch parallel to the
  phoenix pause.

- **W-2: cPT holder premium routing unbounded by design.** `_handlePhasePremium` has no
  balance bracket on the destination of cPT holder-authored premium hooks. A user whose
  cPT-holder sig nominates a hostile cPT holder intent can lose premium delivery. cPT-holder-side
  mitigation only. Explicit non-invariant (`RolloverContract premium routing
  discretion`). `M-11` enforces filler ↔ premium-receiver identity within the
  same tx but does not bound where premium flows after entering the rolloverContract.

- **W-3: `originFillerData` on `openFor` is ignored.** `INV-FILLER-AUTH`
  documents that `openFor` performs no filler attestation; binding occurs
  at `fill` time. Destination + subFiller binding makes any race attacker's P&L
  strictly net-negative. Intentional design choice; surfaced for auditor
  sign-off.

- **W-4: Lens struct ABI stability has no CI signature pin.**
  `ICorkRolloverContract.RolloverContractOrderState` / `IRolloverContractLens.RolloverContractConfig` ABIs are
  consumed by SDK/indexers; a silent struct addition would break consumers
  without a test break. Not a contract bug. Surfaced from interfaces drift
  report.

- **W-5: Cross-chain envelope re-enablement.** Once `Settler__WrongOriginChain`
  / `Settler__WrongDestinationChain` are relaxed, the cross-chain executor
  (A-12 / S-20) becomes load-bearing — attester-chain binding and outbox
  proofs become first-class threat-model entries. Not in scope at HEAD.

- **W-6: Single-author bus-factor.** The x-ray detects 2 author spellings
  collapsed to 1 effective contributor. Review signal from co-authorship is
  absent. Mitigating signals: dense invariant ledger (92 named invariants),
  83 stateful invariant test functions, and a dense commit history.

- **W-7: No multi-engine fuzzing.** No echidna, no medusa, no halmos at HEAD;
  Certora specs exist under `certora/specs/` and `.certora-pipeline/`. Foundry
  `invariant_*` is the primary property-test engine.


- **W-8: Admin off-protocol key custody.** Factory `DEFAULT_ADMIN_ROLE`,
  Settler `DEFAULT_ADMIN_ROLE` / `PAUSER_ROLE` / `UNPAUSER_ROLE` are all
  off-protocol custody concerns. Factory defaults delay and split
  pauser/unpauser keys on Settler are the in-protocol mitigations.

---

## Cross-references

- [units/settler.md](./units/settler.md) — `INV-FILLER-AUTH`, `INV-DEFAULTER-RECOUP`, `INV-DST-CST-REACHABLE`, `BS-ST-20`, `F-PUSH`, `M-08`, polarity isolation.
- [units/rolloverContract.md](./units/rolloverContract.md) — `INV-TRUST-CONFIG-DELAY`, `INV-ROLLOVER_CONTRACT-CPT-HOLDER-SIG-EVERY-DISPATCH`, `INV-CPT-CONTAINED`, `DSR-1`/`DSR-2`, `INV-DST-FLOOR`/`INV-5`, `INV-PARAMS-SETTLER-PIN`.
- [units/factory.md](./units/factory.md) — `INV-SETTLER-APPROVED`, settler latch, delayed defaults, `INV-DEFAULT-ATTESTERS-FACTORY-SEEDED`.
- [units/fillers.md](./units/fillers.md) — `F-PUSH`, fillerData 10-tuple, exact-premium flow; EVC subaccount gate is adapter context only.
- [units/modules.md](./units/modules.md) — stateless delegatecall modules; ERC-7484 + code-presence gate.
- [units/phoenix-integration.md](./units/phoenix-integration.md) — phoenix surface trust assumptions.
- [units/interfaces.md](./units/interfaces.md) — interface ↔ implementer verification matrix.
- [units/libraries.md](./units/libraries.md) — `LibFillerAuth`, `LibSettlerHashing`, typehashes.
- [`docs/INVARIANTS.md`](../../INVARIANTS.md) — canonical invariant ledger.

> **Citation discipline.** Line-numbered citations elsewhere in
> [`docs/spec/md/units/`](./units/) are the authoritative source for exact
> `file:line` ranges; this top-level doc references the symbol/entrypoint and
> defers to the per-unit pages for byte-precise gates. The per-unit pages are
> derived from the same source tree.
