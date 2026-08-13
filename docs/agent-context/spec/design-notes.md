# Design Notes

## 1. F-PUSH

Settler NOT custodian. Fill push-only:
- Filler `safeTransferFrom` srcCST → rolloverContract directly `BaseSettler.sol:888` (`safeTransferFrom(msg.sender, orderData.rolloverContract, fillAmount)`).
- Filler `safeTransferFrom` premium → rolloverContract `BaseSettler.sol:1042`.
- Settler hands srcCST leftover back to filler `BaseSettler.sol:978`.
- RolloverContract mints dstCST during ROLLOVER → pushes back to Settler via factory.
- Settler holds dstCST in escrow fill→settle only.

No pull-from-3rd-party paths. Adding one = Critical (F-PUSH row).

## 2. cPT-holder-signed intent hash binding (INV-ROLLOVER_CONTRACT-CPT-HOLDER-SIG-EVERY-DISPATCH + INV-INTENT-DUAL-BINDING)

cPT-holder-signed `OrderData` commits `OrderData.rolloverIntentHash`, the canonical
zero-digest hash of the `RolloverIntent` hook plan. Because `orderData.user` is
the cPT holder, the same cPT-holder signature over `orderDigest` authorizes that
committed hook plan on first rolloverContract execution.

Off-chain builders hash the `RolloverIntent` w/ `orderDigest = bytes32(0)`.
On-chain (`CorkRolloverContract._validateIntentHashBinding`):
```
intent.orderDigest == live orderDigest
AND
intentStructHash(intent) == rolloverIntentHash
```

Every RolloverContract dispatch checks the cPT-holder signature over `orderDigest` and writes
no authorization state. Atomic ROLLOVER and atomic PREMIUM reuse the same
off-chain cPT-holder signature bytes, but both phases verify them on-chain. Async
phases likewise verify on each dispatch.

## 3. cPT holder signs order economics and committed hooks

cPT holder signs `OrderData`, including economics (`orderSize`, `minPremiumPerShare`,
premium mode, params) and `rolloverIntentHash`. The committed hook chain
(pre/mid/post/premium `Call[]`) is not separately signed. cPT holder does NOT sign
`filler`/`fillAmount`/`premium`/`minDstPerSrc`/`destination`; those live in
`FillContext` at fill.

Economics gated by user-signed `OrderData` (`orderSize`, `minPremiumPerShare`), filler `minDstPerSrc` (unsigned self-protect), rolloverContract `_validateFillEnvelope` (`CorkRolloverContract.sol:538+`).

Load-bearing: hostile cPT holder hooks fail closed, cannot redirect funds.

## 4. INV-CPT-CONTAINED (bidirectional)

`_handlePhaseRollover` snaps `srcCptBefore` and `dstCptBefore` for the rolloverContract. After hooks: assert both balances are equal to (not just `>=`) the snapshots (`CorkRolloverContract.sol:948-953`, `SrcCptNotRestored` / `DstCptNotRestored`). Either direction fires `!=`, catching both residual consumption and unsolicited inflow. Compositional bypass = drain inside bracket + refund equiv before snapshot — pure single-contract paths blocked.

## 5. ERC-7201 + delegatecall containment

Modules execute in rolloverContract storage frame. Defense:

1. ERC-7484 attestation — `_prevalidateIntentCalls` (`CorkRolloverContract.sol:1032+`) checks every hook attested under right bucket. `code.length != 0`, `value == 0`, `allowFailure == false`, `isDelegateCall == true`. `ModuleTypeMismatch` `:1063`.
2. ERC-7201 namespacing — `keccak256(keccak256(ns) - 1) & ~0xff`. Collision ~2^-248.
3. Reference modules carry `OnlyDelegatecall` (`src/modules/OnlyDelegatecall.sol`) so standalone-target calls revert.

**Gap**: no enforcement hooks MUST use ERC-7201. Naive module writing slot 0/1/2 overwrites the first storage slot in the rolloverContract namespace. `_liveTrustHash` (`CorkRolloverContract.sol:1071`) covers `liveTrustThreshold` + `liveTrustAttesters` (the only live trust slots in the post-PR2 layout); other rolloverContract slots unprotected.

## 6. INV-TRUST-CONFIG-DELAY

cPT holder calls safe/default `CorkRolloverContractFactory.queueFactoryDefaultTrustConfig()` or advanced/custom `queueTrustConfig(threshold, attesters)` → configured external per-rolloverContract trust-config `TimelockController` delay → permissionless `applyTrustConfig(rolloverContract)` → `relayTrustConfig` → `ICorkRolloverContract.setTrustConfig`. The timelock address is immutable; its delay is mutable through the Factory-governed `queueTrustConfigDelayUpdate` / `applyTrustConfigDelayUpdate` path and capped by `MAX_TRUST_CONFIG_DELAY`. The default path snapshots the current factory defaults at queue time and does not auto-follow later `setDefaults` changes. Apply permissionless (prevents cPT holder griefing).

Separately, factory-wide defaults rotation is direct via `setDefaults` gated by `DEFAULTS_MANAGER_ROLE`; see INV-FACTORY-DEFAULTS-MANAGED. Assign that role to external governance/timelock if delayed defaults governance is desired. Existing rolloverContracts retain their deployment snapshot until the owner queues a per-rolloverContract trust-config update.

Live-trust mirror (`liveTrustAttesters[]`) asserted faithful inside hooks via `_liveTrustHash` (`CorkRolloverContract.sol:1071`). Hook delegatecalling `IERC7484(registry).trustAttesters(...)` with `msg.sender == rolloverContract` would mutate registry state without touching the rolloverContract mirror — caught at the post-hook hash check.

## 7. Three modes

- **Exact** (`allowPartialFills=false`) — single filler full order. Single FillRecord + residual slot, terminal `Settled`.
- **Partial** (`allowPartialFills=true`) — multi-filler slices. Per-filler `FillerRollover` + residual + premium latch. Can sit `Closing`.
- **Underfill** (`allowUnderfill=true`) — exact mode can complete below `orderSize`
  through a single underfilled leg. In partial mode, underfill is per-leg only:
  partial orders remain `Opened` while aggregate consumed srcCST is below
  `orderSize`, even if current escrow is zero; refund/reclaim/cancel are the
  post-deadline cleanup paths.

Separate storage (`rolloverAccounting`/`dstCstResidual` in `ExactSettler.sol` vs `fillerRollovers` / `participantCount` in `PartialSettler.sol`), separate writers, separate settle/reclaim branches. Polarity decided at deploy time — `ExactSettler.sol:111` rejects `allowPartialFills=true`; `PartialSettler.sol:161` rejects `allowPartialFills=false`. The single `BaseSettler` core is shared.

## 7A. PR90 / PR91 reclaim decision

PR90's reclaim-removal thesis is correct only for a purely atomic protocol
shape: a successful `ATOMIC_TAG` fill cannot leave unpaid dstCST residual.
PR91 changes that shape by adding cPT-holder-signed async premium opt-in. In the
current PR94 API, `reclaim` is live by design for `fill(ROLLOVER)` residuals
whose premium never fires before `fillDeadline`; it must stay hard-routed to
`orderData.rolloverContract`.

Long-term rule: async premium remains behind
`RolloverTypes.PREMIUM_PAYMENT_MODE_ATOMIC_OR_SEPARATE`, reached through
ROLLOVER/PREMIUM `fill(...)` tags. Any PR that removes
`reclaim` is incompatible unless it also removes async premium or supplies
another post-deadline residual cleanup path.

## 8. CWIA

RolloverContract = CWIA clones. `_owner()` / `_factory()` / `_registry()` from CWIA trailer. No setters. INV-ROLLOVER_CONTRACT-OWNER-IMMUTABLE structural. Risk = `initialize` re-entry, blocked by OZ `initializer`.

## 9. Hard chainid binding

`LibSettlerAdmission.sol:80-84` hard-asserts single-chain. Cross-chain envelope inert. Re-enable = open question + reopens attester chain binding.

## 10. Lens ABI CI-pinned

Lens views part of integrator surface. Output struct component order (`RolloverContractConfig`, `RolloverContractTrustSnapshot`, `RolloverContractOrderState`) is gated by `test/integration/admission/LensStructAbiStability.t.sol` (`vm.readFile` source-shape pin): silent struct reorder/extension breaks CI before it can break SDK/indexers. Integration/ops hygiene gate, not a fund-loss path.
