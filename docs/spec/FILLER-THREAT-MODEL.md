---
title: Atomic-Fill Filler Threat Model
status: draft
---

# Atomic-Fill Filler Threat Model

This page narrates the threat-model coverage encoded by
`test/integration/atomic-fill/ThreatModel.t.sol`. Each row pins one
filler-facing risk under the atomic-fill dispatch (`ATOMIC_TAG = 255`
envelope, `INV-ATOMIC-FILL-CANONICAL`).

Atomic-fill collapses the legacy two-leg (`ROLLOVER` then `PREMIUM`) Settler
flow into a single `Settler.fill()` frame that admits, rolls over, pays
premium, and settles in one transaction. The threat model is correspondingly
simpler: there are no longer any inter-leg windows where the filler can be
left with rolled-but-unpaid dstCST, no Settler-boundary `try/catch` that
parks premium on the rolloverContract, and no rolloverContract-latch / Settler-latch divergence
post-conditions. Every fill either succeeds end-to-end or reverts
end-to-end.

## Filler-positive coverage (T-FILLER-N)

### T-FILLER-1 — Trust-config rotation during atomic-fill

An adversarial rolloverContract admin queues a trust-config rotation timed to land
inside the atomic frame. The rolloverContract's `TrustConfigMutatedDuringHook` guard
fires inside the atomic frame, reverting the entire transaction. The filler
loses nothing — no premium pull, no srcCST consumption, no dstCST mint.

### T-FILLER-2 — Pause race during atomic-fill

A privileged actor calls `Settler.pause()` between the filler's transaction
broadcast and inclusion. The atomic fill reverts at the `whenNotPaused`
modifier on `Settler.fill`. The filler retains all srcCST, premium, and
approvals.

### T-FILLER-3 — cPT-holder cancel race

The cPT holder submits `cancel(orderDigest, ...)` racing with the filler's
atomic fill. Whichever transaction lands first wins; the loser reverts
cleanly with no partial state.

### T-FILLER-4 — Premium hook revert cascades

A reverting premium hook propagates its revert through the rolloverContract's
bounded revert-reason copy (`REVERT_REASON_CAP = 256`) and reverts the
atomic frame. This pins `INV-PREMIUM-HOOK-REVERT-CASCADES`: there is no
longer a Settler-boundary `try/catch` that parks premium on the rolloverContract.

### T-FILLER-5 — Hostile mid-hook caught by floors

A hostile mid-hook attempts to drain caSrc or mis-mint dstCST. The
rolloverContract's cPT-holder-signed dst-side floor (`INV-DST-FLOOR`) and the rolloverContract's
src-side mid-bracket guards catch the misbehaviour and revert the atomic
frame.

### T-FILLER-6 — Gas-burn hook (documentation test)

A hook intentionally burns gas to grief the filler. This is detectable
off-chain via gas estimation; on-chain the worst case is a single failed
inclusion that reverts the atomic frame.

### T-FILLER-7a — Exact-mode race loser reverts

Two fillers race the same exact-mode order. The loser's atomic fill
reverts with `Settler__OrderInTerminalState` after the winner settles.

### T-FILLER-7b — Partial slot collision loser reverts

A second atomic fill against an already fully-consumed partial order
reverts before any slot logic — the codifying test asserts
`Settler__OrderIdMismatch` (the rebuilt `600e18` envelope binds a different
rolloverContract-intent hash, so the order-id binding check in
`_decodeBoundOriginData` fails). A true same-slot replay on
`(orderDigest, msg.sender, subFiller)` after premium has fired is guarded by
`Settler__PremiumAlreadyFiredRollover` (`PartialSettler.sol`).

### T-FILLER-8 — Gas griefing fails to create partial state

A would-be griefer tries to advance the order partway by reverting near
the end of the atomic frame. The atomic frame's all-or-nothing semantics
ensure that NO partial state survives the revert.

## Negative coverage (T-NEG-*)

### T-NEG-RESIDUAL — No atomic-fill produces reclaimable residual

Under atomic-fill the "defaulted" partial slot (rolled but unpaid premium)
is architecturally unreachable. `reclaim` remains in the ABI as a
terminal-state guard but cannot be exercised via a rollover-without-premium
sequence. Pins `INV-NO-DST-STRAND-IN-ATOMIC-FLOW`.

### T-NEG-AS10 — Premium-hook revert no longer parks at rolloverContract

The legacy `Settler__PremiumHooksReverted` event and the
`_forwardPremiumWithCatch` boundary have been removed. A reverting premium
hook now reverts the whole frame; no premium parks on the rolloverContract.

### T-NEG-DIVERGENCE — Settler latch and rolloverContract latch always consistent

Under atomic-fill the Settler's `premiumFired` latch and the rolloverContract's
`premiumFiredFor[orderDigest][filler][subFiller]` latch are always set or unset
together: both flip inside the same frame, and any failure in the frame
rolls both back atomically. The legacy `INV-PREMIUM-LATCH-DIVERGENCE-OK`
post-condition no longer applies.

### T-NEG-PHASE-ONLY — Phase fill tags require cPT holder opt-in

`HookPhase.ROLLOVER` and `HookPhase.PREMIUM` payloads route to the async
premium lifecycle only when the cPT-holder signed `premiumPaymentMode =
ATOMIC_OR_SEPARATE`. Unsupported tags still revert with
`Settler__AtomicFillRequired` before rolloverContract dispatch. Pins
`INV-FILL-TAG-DISPATCH`.

## Design-doc reconciliation: errors kept despite "delete"

The atomic-fill design doc marks three Settler-side errors as
"unreachable, delete". Per session-7 reachability analysis, the
following errors are KEPT (operator-approved):

| Error | Reason kept |
|---|---|
| `Settler__PremiumNotSettled` | Internal settlement guard retained for exact-mode defence-in-depth; the public `settle()` selector was removed, and successful PREMIUM now settles in-frame. |
| `Settler__PremiumNotPaid` | Internal partial-mode settlement guard retained for defence-in-depth; no public keeper settle path remains. |
| `Settler__PremiumAlreadyFiredRollover` | Partial-mode same-slot multi-fill guard. Fires when a second atomic fill on `(orderDigest, msg.sender, subFiller)` arrives after the first has already paid premium in-frame. |

These errors do not regress any atomic-fill invariant; they protect internal
premium-settlement and the external `reclaim` ABI surface from being exercised
against inconsistent slot state.
