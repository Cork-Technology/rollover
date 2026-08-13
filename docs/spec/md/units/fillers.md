# Unit: BaseFiller + Adapter Context

> _Supplementary protocol reference. The canonical bundle for AI auditors is [`docs/agent-context/`](../../../agent-context/README.md). Code in `src/` is the source of truth when docs disagree._

Protocol-spec unit doc for the in-scope filler-side actor contract in the Cork
rollover settlement stack.

Scope alignment: `src/BaseFiller.sol` is in scope.
`src/EvcRolloverAdapter.sol` is adapter/integration context only and is out of
audit scope unless explicitly re-added in `SCOPE.md`. Adapter notes below are
retained only to explain shared wire formats and references from tests or
invariants.

## Source

- `src/BaseFiller.sol` — Non-EVC filler orchestrator. Pulls srcCST
  + premium-cap funds from a filler EOA / SCW, conditionally calls `openFor`,
  then dispatches exactly one atomic `fill(orderId, originData, fillerData)`
  envelope (`ATOMIC_TAG`). The Settler performs admit → rollover → premium →
  settlement inside that single frame. The filler never calls a public async
  lifecycle surface.
- `src/EvcRolloverAdapter.sol` — adapter/integration context only. It is
  out of audit scope unless explicitly re-added in `SCOPE.md`; adapter-specific
  EVC and Permit2 behavior is not in-scope protocol behavior unless shared code
  affects in-scope contracts.
- `src/libraries/LibFillerAuth.sol` — 219 lines. Pure helpers for the Path-2
  `fillerData` 10-tuple decode and the `FillerAuth(orderDigest, destination,
  subFiller)` EIP-712 binding check enforced at fill time
  (`src/libraries/LibFillerAuth.sol:91-108`).

`BaseFiller` pulls tokens from an upstream account, builds a single
atomic-envelope `fillerData` blob (`ATOMIC_TAG`) wrapping the ROLLOVER +
PREMIUM inner-leg payloads and the cPT-holder EIP-712 signature, dispatches one
`Settler.fill` call (the Settler performs admit -> rollover -> premium ->
settle inside one frame), and refunds balance deltas. The EVC adapter follows
a similar wire-format shape for integration context, but remains out of audit
scope unless explicitly re-added in `SCOPE.md`.

## Inheritance

| Contract | Base | Source |
|----------|------|--------|
| `BaseFiller` | `ReentrancyGuardTransient` (OZ, EIP-1153 transient slot) | `src/BaseFiller.sol:6-8`, `src/BaseFiller.sol:27` |
| `EvcRolloverAdapter` (adapter context only) | `ReentrancyGuardTransient` (OZ) | `src/EvcRolloverAdapter.sol:6-8`, `src/EvcRolloverAdapter.sol:82` |

Adapter context: `EvcRolloverAdapter` does NOT inherit from `BaseFiller`. They
share only the OZ `ReentrancyGuardTransient` parent and a similarly-shaped
calldata struct (`FillerJob` / `EvcRolloverJob`).

## Storage

### `BaseFiller`

Stateless beyond OZ `ReentrancyGuardTransient`. Two persistent settler
immutables are pinned at construction.

| Slot / Symbol | Type | Purpose | Write sites |
|---------------|------|---------|-------------|
| `EXACT_SETTLER` | `ISettler` (immutable) | Exact-mode settler this wrapper may dispatch through | constructor only |
| `PARTIAL_SETTLER` | `ISettler` (immutable) | Partial-mode settler this wrapper may dispatch through | constructor only |
| `ReentrancyGuardTransient` | `tstore` transient | Reentrancy flag (EIP-1153) | inherited |

No ERC-7201 namespace; no persistent slots.

### `EvcRolloverAdapter` (adapter context only)

Out of audit scope unless explicitly re-added in `SCOPE.md`. Five persistent
immutables are pinned at construction. Constructor reverts on
each zero-address argument (`src/EvcRolloverAdapter.sol:220-234`), covering the
EVC, controller, exact/partial settler, and Permit2 arguments.

| Slot / Symbol | Type | Purpose | Write sites |
|---------------|------|---------|-------------|
| `EVC` | `IEVC` (immutable) | EVC instance queried for on-behalf-of authentication context | constructor only — `src/EvcRolloverAdapter.sol:137`, `src/EvcRolloverAdapter.sol:235` |
| `CONTROLLER` | `address` (immutable) | Controller address that must be enabled on the EVC subaccount before dispatch | constructor only — `src/EvcRolloverAdapter.sol:141`, `src/EvcRolloverAdapter.sol:236` |
| `EXACT_SETTLER` | `ISettler` (immutable) | Exact-mode settler this adapter may dispatch through | constructor only |
| `PARTIAL_SETTLER` | `ISettler` (immutable) | Partial-mode settler this adapter may dispatch through | constructor only |
| `PERMIT2` | `ISignatureTransfer` (immutable) | Canonical Permit2 used for witness-bound job funding | constructor only — `src/EvcRolloverAdapter.sol:154`, `src/EvcRolloverAdapter.sol:239` |
| `ReentrancyGuardTransient` | `tstore` transient | Reentrancy flag (EIP-1153) | inherited |

No ERC-7201 namespace; no persistent slots beyond the five immutables.

## Entrypoints

| Function | Modifiers | Role gate | Revert paths | Source |
|----------|-----------|-----------|--------------|--------|
| `BaseFiller.execute(FillerJob)` | `external nonReentrant` | none — open dispatch; settler-pin asserted inline | `BaseFiller__UnknownSettler`, `BaseFiller__ZeroSettler`, `BaseFiller__SettlerMismatch`; bubbles `Settler__*` reverts, including premium-cap failures | `src/BaseFiller.sol` |
| `BaseFiller.EXACT_SETTLER()` | `public view` (immutable getter) | none | — | `src/BaseFiller.sol` |
| `BaseFiller.PARTIAL_SETTLER()` | `public view` (immutable getter) | none | — | `src/BaseFiller.sol` |
| `EvcRolloverAdapter.execute(EvcRolloverJob)` | adapter context only | `_gateEvc(subaccount)` — EVC frame + `msg.sender == EVC`; Permit2 signer must equal `fundingAccount` and EVC owner | Out of audit scope unless explicitly re-added in `SCOPE.md` | `src/EvcRolloverAdapter.sol` |
| `EvcRolloverAdapter.executePartial(EvcRolloverJob)` | adapter context only | same `_gateEvc` chain as `execute` | Out of audit scope unless explicitly re-added in `SCOPE.md` | `src/EvcRolloverAdapter.sol:277` |
| `EvcRolloverAdapter.EVC()` | `public view` (immutable getter) | none | — | `src/EvcRolloverAdapter.sol:137` |
| `EvcRolloverAdapter.CONTROLLER()` | `public view` (immutable getter) | none | — | `src/EvcRolloverAdapter.sol:141` |
| `EvcRolloverAdapter.EXACT_SETTLER()` | `public view` (immutable getter) | none | — | `src/EvcRolloverAdapter.sol` |
| `EvcRolloverAdapter.PARTIAL_SETTLER()` | `public view` (immutable getter) | none | — | `src/EvcRolloverAdapter.sol` |

**Entrypoint count:** `BaseFiller` = 1 mutating + 2 immutable getters (3).
`EvcRolloverAdapter` entrypoints are adapter context only.

No `receive()` / `fallback()`. No admin surface, no `Ownable`, no upgrade
path. The `FillerJob` / `EvcRolloverJob` calldata struct shape is chosen
specifically to keep both `execute` selectors inside the EVM 16-slot
accessible stack without `via_ir` (`src/BaseFiller.sol:53-66`,
`src/EvcRolloverAdapter.sol:113-133`).

### 10-tuple inner-leg `FillerPayload` ABI

Both contracts encode a ROLLOVER 10-tuple `FillerPayload` blob, then wrap it
inside a single atomic envelope (`ATOMIC_TAG`) forwarded to `Settler.fill`.
The synthesized atomic PREMIUM payload reuses the decoded rollover intent and
the envelope cPT-holder signature. The ROLLOVER blob carries `intent` and is decoded
by `LibFillerAuth.decodePayload` inside the Settler:

```
(uint8 phase, uint256 fillAmount, uint256 premium, address destination,
 address premiumFor, RolloverTypes.RolloverIntent intent, uint256 minDstPerSrc,
 bytes fillerAuthSig, bytes32 subFiller, bytes cptHolderSig)
```

- The 5th slot `address premiumFor` is zero in ROLLOVER. In PREMIUM it is
  mandatory and must identify the recorded rollover filler being paid for. The
  premium payer never controls settlement destination.
- The 7th slot `uint256 minDstPerSrc` is a filler-supplied (NOT EIP-712-signed)
  calldata floor used only on the ROLLOVER branch; PREMIUM passes `0`.
- The 8th slot `bytes fillerAuthSig` is the optional EIP-712 signature an
  `exclusiveFiller` issues over `FillerAuth(orderDigest, destination, subFiller)`
  to authorise a delegated executor.
- The 9th slot `bytes32 subFiller` keys partial-mode per-filler state.
  `BaseFiller` derives it from caller identity (`msg.sender`). Adapter context:
  `EvcRolloverAdapter` derives it from `job.subaccount`. Direct-EOA fillers may send `bytes32(0)`
  and `LibFillerAuth` substitutes `bytes32(uint256(uint160(msg.sender)))` at decode.
  Exact-mode settler storage ignores `subFiller`; `FillContext`, rolloverContract `premiumFiredFor`,
  and `PremiumFired` always use the resolved value (indexers must query lens/event with
  that resolved key, not wire-zero).
- The 10th slot `bytes cptHolderSig` carries the cPT-holder EIP-712 signature over
  `orderDigest` for direct-fill admission when status is `None`; PREMIUM and
  already-`Opened` ROLLOVER legs pass empty bytes.
- Encoded by `BaseFiller` via `_buildRolloverInnerBlob`
  (`src/BaseFiller.sol:193-207`) and wrapped by
  `_dispatchAtomicFill` into the atomic envelope
  (`src/BaseFiller.sol:172-192`). The EVC adapter has analogous adapter-context
  encoders but is out of audit scope unless explicitly re-added in `SCOPE.md`.

### Exact-premium computation site

Under atomic fill the filler does NOT compute `requiredPremium` itself.
Instead, `BaseFiller` approves `premiumToken` upfront at the job-supplied
`premiumCap` ceiling (`src/BaseFiller.sol:180`) and passes the same ceiling
into the atomic-envelope's `premiumCap` slot
(`src/BaseFiller.sol:188-190`). The
Settler records dstCST produced by the ROLLOVER leg, then computes the canonical
`requiredPremium = Math.mulDiv(produced, minPremiumPerShare, 1e18, Math.Rounding.Ceil)`
itself, and pulls only that amount from the filler — surplus stays with the
filler and is refunded by `execute` from the post-fill balance diff.
`BaseFiller` emits `PremiumRefunded` from the balance-delta tail
(`src/BaseFiller.sol:73-78`, `src/BaseFiller.sol:119-124`).
Adapter context: `EvcRolloverAdapter` refunds to `job.recipient` without an
event via `_refundTails` (`src/EvcRolloverAdapter.sol:595-621`).

### `FillerAuth` EIP-712 path

The 10-tuple's `fillerAuthSig` is the EIP-712 signature `exclusiveFiller`
issues over `FillerAuth(bytes32 orderDigest, address destination, bytes32 subFiller)`. Filler
contracts forward it verbatim; the actual verification is done at fill time
inside `Settler` via `LibFillerAuth.isAuthorised`, which has three branches:
(a) `exclusiveFiller == address(0)` → open, (b) `caller == exclusiveFiller`
→ direct, (c) otherwise → `SignatureChecker.isValidSignatureNow` against the
typed-data digest computed by `hashFillerAuth`
(`src/libraries/LibFillerAuth.sol:91-108`,
`src/libraries/LibFillerAuth.sol:67-77`). `BaseFiller` explicitly does NOT
implement ERC-1271 (no `isValidSignature` / ERC-1271 import in
`src/BaseFiller.sol`); orders naming `BaseFiller` as
`exclusiveFiller` fail with a clean signature error.

## Internal helpers

### `BaseFiller`

| Helper | Purpose | Source |
|--------|---------|--------|
| `_runSettlement(FillerJob, ISettler, OrderData, bytes32)` | Local `orderDigest` via `LibSettlerHashing.computeOrderDigestMemory`; conditional `openFor` when status ≠ `Opened`; dispatch atomic fill (admit → rollover → premium → settle in one Settler frame); zero approvals on return | `src/BaseFiller.sol:141-160` |
| `_dispatchAtomicFill(...)` | Approve srcCst at `fillerSrcCst` and premiumToken at `premiumCap`, build the rollover inner-leg blob, wrap it in the `ATOMIC_TAG` envelope (with cPT-holder EIP-712 sig in the envelope), and call `settler.fill` once | `src/BaseFiller.sol:172-192` |
| `_buildRolloverInnerBlob(FillerJob, bytes32)` | Encode ROLLOVER 10-tuple inner-leg `FillerPayload` blob (envelope-level `cptHolderSig` carries the cPT-holder attestation; the inner slot is empty) | `src/BaseFiller.sol` |
| `_settlerFor(OrderData)` / `_assertExpectedSettler(ISettler,ISettler)` | Mode-select exact vs partial and pin-match against the corresponding immutable settler | `src/BaseFiller.sol:210-222` |

### `EvcRolloverAdapter` (adapter context only)

| Helper | Purpose | Source |
|--------|---------|--------|
| `_runSettlementCommon(job, settler, orderData, orderId, subFiller)` | Receives the caller-computed `orderId` (computed in `execute` / `executePartial` via `LibSettlerHashing.computeOrderDigestMemory`, not internally); conditional `openFor` when status ≠ `Opened`; dispatch atomic fill (admit → rollover → premium → settle in one Settler frame); zero approvals on return | `src/EvcRolloverAdapter.sol:493-510` |
| `_dispatchAtomicFill(...)` | Approve srcCst at `fillerSrcCst` and premiumToken at `job.premium`, build the rollover inner-leg blob, wrap it in the `ATOMIC_TAG` envelope (with cPT-holder EIP-712 sig in the envelope), and call `settler.fill` once | `src/EvcRolloverAdapter.sol:524-544` |
| `_buildRolloverInnerBlob(EvcRolloverJob, bytes32)` | Encode ROLLOVER 10-tuple inner-leg `FillerPayload` blob with `destination = job.recipient`; the envelope-level `cptHolderSig` carries the cPT-holder attestation | `src/EvcRolloverAdapter.sol` |
| `_settlerFor(OrderData)` / `_assertExpectedSettler(ISettler,ISettler)` | Mode-select exact vs partial and pin-match against the corresponding immutable settler | `src/EvcRolloverAdapter.sol:581-592` |
| `_refundTails(...)` | Refund post-call balance deltas of `srcCst` + `premiumToken` back to `recipient` | `src/EvcRolloverAdapter.sol:595-621` |
| `_gateEvc(address subaccount)` | EVC authentication gate: nonzero enabled on-behalf frame for `CONTROLLER`, `onBehalf == subaccount`, and `msg.sender == EVC` | `src/EvcRolloverAdapter.sol:632-649` |

### `LibFillerAuth`

| Helper | Purpose | Source |
|--------|---------|--------|
| `decodePayload(bytes calldata)` | Decode 10-tuple `fillerData` into a `FillerPayload` memory struct, split into two halves to dodge the stack-slot ceiling | `src/libraries/LibFillerAuth.sol` |
| `hashFillerAuth(domainSeparator, orderDigest, destination, subFiller)` | Compute EIP-712 typed-data digest of `FillerAuth(bytes32 orderDigest,address destination,bytes32 subFiller)` | `src/libraries/LibFillerAuth.sol:67-77` |
| `isAuthorised(exclusiveFiller, caller, domainSeparator, orderDigest, destination, subFiller, fillerAuthSig)` | Three-branch predicate enforcing INV-FILLER-AUTH at the Settler fill site | `src/libraries/LibFillerAuth.sol:91-108` |
| `_decodePayloadTail(...)` | Private second-half decoder for the 10-tuple tail | `src/libraries/LibFillerAuth.sol` |

## Invariants touched

| Invariant | Scope on fillers | Ledger entry | Filler-side source |
|-----------|-----------------|--------------|--------------------|
| **INV-FILLER-AUTH** | Filler dispatch through `Settler.fill` is gated on (a) `exclusiveFiller == 0` or (b) direct call or (c) EIP-712 `FillerAuth` sig. Filler contracts forward `fillerAuthSig` verbatim; verification is library-mediated at the Settler fill site. | `docs/INVARIANTS.md:1014-1032` | `src/libraries/LibFillerAuth.sol:91-108`; forwarded via `src/BaseFiller.sol:208`. Adapter-context analogue at `src/EvcRolloverAdapter.sol:560` is out of audit scope unless explicitly re-added in `SCOPE.md`. |
| **INV-DSTCST-FLOOR** | Filler-supplied `minDstPerSrc` (1e18-scaled, calldata-only) enforces `dstProduced >= mulDiv(srcConsumed, minDstPerSrc, 1e18)` after rollover hooks settle. `0` opts out. | `docs/INVARIANTS.md:58-74` | `src/BaseFiller.sol:207`; adapter-context analogue at `src/EvcRolloverAdapter.sol:559` is out of audit scope unless explicitly re-added in `SCOPE.md` |
| **F-PUSH** | Token-flow shape: srcCST and premium `filler -> rolloverContract` (Settler orchestrates); dstCST `rolloverContract -> Settler -> recorded settlement destination`. Filler contracts are the protocol-external entry edge. | `docs/INVARIANTS.md` `F-PUSH` | `BaseFiller`; EVC adapter references are adapter context only |
| **INV-ATOMIC-FILL-CANONICAL** | Filler contracts emit one atomic envelope per job. Admission, rollover, premium, and settlement occur inside the Settler `fill` frame; no filler-side phase-only or `reclaim` call exists. | `docs/INVARIANTS.md` | `src/BaseFiller.sol`; EVC adapter references are adapter context only |
| **INV-SUBFILLER-PROVENANCE** | `BaseFiller` derives `subFiller` locally from `msg.sender` and never accepts it from untrusted calldata. | `docs/INVARIANTS.md` | `src/BaseFiller.sol`; EVC adapter `job.subaccount` provenance is adapter context only |
| **INV-ADAPTER-JOB-AUTHORIZED** | Adapter-context invariant only. EVC adapter funding is authorised by the EVC account owner: `fundingAccount` must equal `EVC.getAccountOwner(subaccount)` and the Permit2 witness binds funding account, recipient, amounts, intent, order digest, nonce, and deadline. | `docs/INVARIANTS.md` | `src/EvcRolloverAdapter.sol` (out of audit scope unless explicitly re-added in `SCOPE.md`) |

`INV-DST-CST-RECONCILES` is a Settler-side invariant
(`fillerDstCstResidual` totals reconciling with mints/transfers) and is not
asserted from filler-side code; filler contracts only participate as the
`safeTransfer` destination.

## Integrations

| Outbound surface | Filler call sites | External signature |
|------------------|-------------------|--------------------|
| `ISettler.openFor(GaslessCrossChainOrder, bytes, bytes)` | `src/BaseFiller.sol` (conditional — skipped when cached status is `Opened`) | Opens the ERC-7683 order when status != `Opened`; `originFillerData = ""`. EVC adapter analogue is adapter context only. |
| `ISettler.fill(bytes32 orderId, bytes originData, bytes fillerData)` | `src/BaseFiller.sol` | Single `ATOMIC_TAG` envelope per `execute` (`LibFillerPayload`). EVC adapter analogue is adapter context only. |
| `ISettler.orderStatus(bytes32 orderId)` | `src/BaseFiller.sol` | Gates conditional `openFor` skip on `Opened`. EVC adapter analogue is adapter context only. |
| `ISettler.DOMAIN_SEPARATOR()` | `src/BaseFiller.sol` | Forwarded into `LibSettlerHashing.computeOrderDigestMemory` for local digest. EVC adapter analogue is adapter context only. |
| `IEVC.getCurrentOnBehalfOfAccount(address controllerToCheck)` | `src/EvcRolloverAdapter.sol:633` | Adapter context only; out of audit scope unless explicitly re-added in `SCOPE.md`. |
| `IEVC.getAccountOwner(address account)` | `src/EvcRolloverAdapter.sol` | Adapter context only; resolves the required Permit2 signer for `job.fundingAccount`. |
| `Permit2.permitWitnessTransferFrom(...)` | `src/EvcRolloverAdapter.sol` | Adapter context only; pulls `fillerSrcCst` and premium ceiling from `fundingAccount` with a witness binding `recipient` and the economic job fields. |
| `IERC20` (`srcCst`, `premiumToken`) via OZ `SafeERC20` | `safeTransferFrom` / `safeTransfer` / `forceApprove` at `src/BaseFiller.sol`; EVC adapter analogue is adapter context only | ERC-20 standard |
| `LibRolloverOrder.decodeOrderData(GaslessCrossChainOrder)` | `src/BaseFiller.sol:104`; EVC adapter analogue is adapter context only | Local decode for digest computation |
| `LibSettlerHashing.computeOrderDigestMemory(OrderData, bytes32)` | `src/BaseFiller.sol:147-149`; EVC adapter analogue is adapter context only | Local digest computation; must match Settler's hashing path |
| `LibFillerAuth.*` | NOT called directly by filler contracts — invoked by Settler at fill time. Filler contracts only forward the signature bytes. | `src/libraries/LibFillerAuth.sol` |

### Inbound surface

| Caller | Entry |
|--------|-------|
| Filler operator (EOA / SCW) | `BaseFiller.execute(FillerJob)` — `msg.sender` supplies srcCST and the premium cap |
| EVC subaccount (via EVC `call`/`batch`) | Adapter context only: `EvcRolloverAdapter.execute` / `executePartial(EvcRolloverJob)`; out of audit scope unless explicitly re-added in `SCOPE.md`. |

## Tests

Filler-side unit + integration coverage:

- `test/unit/filler/` — `BaseFiller` unit suites plus adapter-context
  `EvcRolloverAdapter` tests.
- `test/unit/filler/Fillers.t.sol` — listed in F-PUSH ledger entry
  (`docs/INVARIANTS.md:226`).
- `test/integration/rollover/FillerMintFloor.t.sol` — INV-DSTCST-FLOOR
  end-to-end coverage of ROLLOVER `minDstPerSrc` enforcement
  (`docs/INVARIANTS.md:71`).
- `test/integration/rollover/HookRestructure.t.sol` — Path-2 rewire +
  preRolloverHooks / midRolloverHooks dispatch via Settler.fill.
- `test/integration/atomic-fill/ThreatModel.t.sol` — atomic-fill lifecycle
  coverage for the canonical admit → rollover → premium → settle frame and
  helper-side refusal to emit async phase-only or defaulter calls.
- Adapter-context only: `test/integration/evcadapter/EvcRecipientBinding.t.sol` — C-01 coverage for
  explicit EVC recipient binding: rollover destination and adapter tail
  refunds route to `recipient`, while Permit2 pulls from `fundingAccount`.
- Adapter-context only: `test/integration/evcadapter/Permit2WitnessAuthorization.t.sol` — EVC
  funding witness coverage for `fundingAccount`, subaccount owner binding,
  and job-field authorization.
- `test/unit/settler/FillerAuth.t.sol` +
  `test/invariant/{failOnRevert,continueOnRevert}/FillerAuth.t.sol` +
  `test/integration/auth/SettlerTrustConsolidation.t.sol` — INV-FILLER-AUTH
  coverage at the Settler fill site (`docs/INVARIANTS.md:1029-1032`).

## Griefing vectors

### Scoundrel (intent: harm)

- **Compromised exclusive filler authorising hostile executor.** Mitigated by
  the Settler allowlist + `FillerAuth(orderDigest, destination, subFiller)`
  destination + subFiller binding (INV-FILLER-AUTH at
  `docs/INVARIANTS.md:1014-1032`).
  Replay across executors is strictly net-negative for the attacker — the
  loser's call lands funds at the WINNER's destination.
- **FillerAuth signature replay across orders.** Defeated by `orderDigest`
  appearing in the EIP-712 struct hash
  (`src/libraries/LibFillerAuth.sol:73-75`); replay requires a fresh
  signature per order.
- **Hostile rolloverContract / cPT holder returning corrupt `dstCstProduced`.** RolloverContract dispatch
  through factory pins `params.settler` against `ctx.originSettler`, and the
  Settler reconciles reported values against token balance deltas before
  premium and settlement accounting use them.
- **Premium cap as DoS vector.** A hostile order with a tuned
  `minPremiumPerShare` that exceeds the filler-supplied cap reverts the
  entire atomic `fill` via Settler-side premium-cap enforcement. Filler
  protects itself by sizing the cap against the order's signed
  `minPremiumPerShare` × expected production.

### Lazy (intent: cut corners)

- **Filler passes `minDstPerSrc = 0` on a partial-fill order.** A hostile cPT holder
  could then mint zero dstCST against arbitrary srcCST consumption.
  INV-DSTCST-FLOOR closes this in the ROLLOVER branch — the floor is
  filler-supplied calldata (not signed). `BaseFiller` forwards
  `job.minDstPerSrc` on ROLLOVER (`src/BaseFiller.sol:207`) while the atomic
  PREMIUM leg carries no `minDstPerSrc`. Lazy fillers default-zeroing the field
  expose themselves. EVC adapter forwarding is adapter context only.
- **Filler skips cPT-holder signature validation off-chain.** Settler admission and
  every rolloverContract hook dispatch validate the cPT-holder signature at `fill` time —
  gas burned, funds safe.

### Confused (intent: well-meaning, wrong inputs)

- **Filler names `BaseFiller` itself as `exclusiveFiller`.** Falls through
  to ECDSA recovery against an EOA — unsupported because there is no
  `isValidSignature` / ERC-1271 implementation in `src/BaseFiller.sol`. Order
  fails with a clean signature revert.
- **Adapter context only: EVC adapter called outside an EVC context.** `_gateEvc` reverts
  `EvcRolloverAdapter__NotEvcContext` on zero `onBehalfOfAccount`
  (`src/EvcRolloverAdapter.sol:635`).
- **Adapter context only: direct EOA call with a populated frame.** `_gateEvc` reverts
  `EvcRolloverAdapter__CallerNotEvc` when `msg.sender != address(EVC)`
  (`src/EvcRolloverAdapter.sol:647`).
- **Adapter context only: subaccount mismatch.** `EvcRolloverAdapter__OnBehalfMismatch(onBehalf,
  subaccount)` reverts when caller-supplied subaccount diverges from the
  EVC-authenticated one (`src/EvcRolloverAdapter.sol:640-641`).
- **Stuck approvals on revert mid-flow.** Both contracts zero
  `forceApprove(settler, 0)` after atomic `fill` returns (`src/BaseFiller.sol:158-159`,
  `src/EvcRolloverAdapter.sol:508-509`); a revert BETWEEN `forceApprove` and
  `fill` leaves a non-zero approval to Settler. For `EvcRolloverAdapter`, this
  is adapter context only. Settler is an allowlisted,
  trusted callee — non-zero stale approval is not a fund-loss vector
  (Settler only pulls what the atomic frame declares).

## Token-flow diagram (atomic envelope)

```mermaid
sequenceDiagram
  autonumber
  participant FOp as Filler operator (msg.sender / fundingAccount)
  participant BF as BaseFiller
  participant S as Settler
  participant FA as CorkRolloverContractFactory
  participant C as RolloverContract (cPT holder)

  Note over FOp,C: execute() — operator pre-funds helper
  FOp->>BF: safeTransferFrom srcCst (fillerSrcCst)
  FOp->>BF: safeTransferFrom premiumToken (premiumCap)

  alt orderStatus(orderId) != Opened
    BF->>S: openFor(order, userSig, "")
  end

  BF->>BF: LibFillerPayload.encodeAtomicEnvelope(rollover, premiumCap, cptHolderSig)
  BF->>S: forceApprove srcCst → fillerSrcCst; forceApprove premiumToken → premiumCap
  BF->>S: fill(orderId, originData, ATOMIC_TAG envelope)

  Note over S,C: single frame — rollover
  S->>C: safeTransferFrom(BF → rolloverContract, srcCST)
  S->>FA: executeIntentHooks(ROLLOVER)
  FA->>C: rollover hooks; dstCST minted to Settler escrow

  Note over S,C: same frame — premium + settle
  S->>S: requiredPremium = Ceil(dstProduced × minPremiumPerShare / 1e18); pin ≤ premiumCap
  S->>C: safeTransferFrom(BF → rolloverContract, requiredPremium)
  S->>S: verify rolloverContract balance delta == requiredPremium
  S->>FA: executeIntentHooks(PREMIUM)
  FA->>C: premiumHooks (standing-balance tripwire)
  S->>BF: settle dstCST to fillerDestination (in-frame)

  BF->>S: forceApprove(settler, 0) both tokens
  BF->>FOp: refund leftover srcCst + premiumCap − requiredPremium
```

## ERC dependencies cited

- **EIP-712 (typed data hashing).** `FillerAuth(bytes32 orderDigest,
  address destination, bytes32 subFiller)` struct — Settler's `DOMAIN_SEPARATOR()` is forwarded
  into BaseFiller's local digest computation
  (`src/BaseFiller.sol:148`). Filler contracts hold no EIP-712 state
  themselves; they are pure forwarders for `fillerAuthSig`.
- **ERC-20 (token transfers).** OZ `SafeERC20` on `srcCst` and
  `premiumToken` (`src/BaseFiller.sol:4-5,28`). Adapter-context import sites
  exist in `src/EvcRolloverAdapter.sol`.
- **ERC-7683 (cross-chain intent settlement).** Filler role from the
  ERC-7683 taxonomy; helper contracts use `Settler.openFor` and one
  atomic `fill` envelope as their integration surface. The
  `GaslessCrossChainOrder` and
  `ResolvedCrossChainOrder` types are ERC-7683 standard.
- **ERC-1271 (contract signature verification).** NOT implemented by
  `BaseFiller` (no `isValidSignature` / ERC-1271 import in
  `src/BaseFiller.sol`). `LibFillerAuth.isAuthorised`
  uses `SignatureChecker.isValidSignatureNow` which accepts ERC-1271
  exclusively at the Settler side
  (`src/libraries/LibFillerAuth.sol:107`).
- **EIP-1153 (transient storage).** `ReentrancyGuardTransient` parent of
  `BaseFiller` (`src/BaseFiller.sol:6-8,27`). Adapter-context inheritance
  exists in `src/EvcRolloverAdapter.sol`.

## Cross-references

- [[settler.md]] — `Settler.openFor` / `fill` / `resolve` /
  `fillerDstProducedOf(bytes32,address,bytes32)` views; `LibFillerAuth.isAuthorised` and the
  `FillerAuth` EIP-712 typehash.
- [[rolloverContract.md]] — `CorkRolloverContract.executeIntentHooks` and the per-phase
  `preRolloverHooks` / `midRolloverHooks` / `postRolloverHooks` dispatch.
- [[libraries.md]] — `LibRolloverOrder.decodeOrderData`,
  `LibSettlerHashing.computeOrderDigestMemory`, and `LibFillerAuth`.
- [[interfaces.md]] — `ISettler` filler-side surface. Adapter context only:
  `IEVC` minimal interface declared inline at `src/EvcRolloverAdapter.sol:41-58`.
- [[modules.md]] — `fillerData` 10-tuple wire format (phase, fillAmount,
  premium, destination, premiumFor, intent, minDstPerSrc, fillerAuthSig,
  subFiller, cptHolderSig).
- [[phoenix-integration.md]] — rolloverContract's `unwindMint` / `deposit` calls on
  Phoenix's `CorkPoolManager` that consume srcCST pushed through the filler
  chain.
