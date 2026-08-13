# Unit: `src/modules/*` — Stateless Delegatecall Modules

> _Supplementary protocol reference. The canonical bundle for AI auditors is [`docs/agent-context/`](../../../agent-context/README.md). Code in `src/` is the source of truth when docs disagree._

## Source

| File | Lines | Role |
|---|---|---|
| `src/modules/OnlyDelegatecall.sol` | abstract | Direct-call guard inherited by every module in this folder. |
| `src/modules/ApproveModule.sol` | atomic | `SafeERC20.forceApprove` + spender-call + revoke atomic bracket (USDT-style zero-first via OZ). |
| `src/modules/OwnerTokenPullModule.sol` | pre-rollover | Pulls an exact owner-held ERC-20 amount, or a positive pullable maximum when underfill is enabled, into the rolloverContract host. |
| `src/modules/ScopedSplitModule.sol` | scoped | Amount-scoped split module; takes explicit `amount` (or transient-read sentinel). |
| `src/modules/ScopedTransferModule.sol` | scoped | Amount-scoped replacement for the removed `TransferAllModule`; takes explicit `amount` (or transient-read sentinel). |
| `src/modules/PostRolloverDstCptTransferModule.sol` | post-rollover | Routes only the transient minted `dstCptAfterDeposit - dstCptBeforeDeposit` amount to a cPT roller; never sweeps standing dstCPT. |
| `src/modules/PreRolloverReferenceModule.sol` | reference | Reference observation — emits `PreRolloverSnapshot`. |
| `src/modules/MidRolloverReferenceModule.sol` | reference | Reference observation — emits `MidRolloverObservation` (BS-EVT-25). |
| `src/modules/PostRolloverReferenceModule.sol` | reference | Reference observation — emits `PostRolloverSnapshot`. |

**M-05 removal:** `TransferAllModule` and `SplitModule` are removed and obsolete
for new-order premium intents. New premium executor hooks must use
`ScopedTransferModule` or `ScopedSplitModule`, with an explicit amount or the
delivered-premium sentinel. Do not attest removed full-balance modules for new
orders.

**Module count: 8 + 1 abstract base.** Every concrete module under `src/modules/`
is a **stateless delegatecall payload** invoked by `CorkRolloverContract._executeIntentCalls`
via `delegatecall`. Each inherits `OnlyDelegatecall` so direct calls to the
deployed module address revert `OnlyDelegatecall__DirectCallForbidden`. Under
the delegatecall frame `address(this)` and storage are the rolloverContract's; the module
code is executed but its own storage and code identity are not the trust root —
the ERC-7484 registry attestation of the target address is.

> **Cross-references:** caller is the rolloverContract — see `rolloverContract.md`. The factory
> latches `originSettler` and gates dispatch — see `factory.md`. Shared
> typehashes and `ModuleType` constants live in `libraries.md`.

---

## Inheritance

| Module | Base contracts |
|---|---|
| `OnlyDelegatecall` | — (abstract base) |
| `ApproveModule` | `OnlyDelegatecall` |
| `OwnerTokenPullModule` | `OnlyDelegatecall` |
| `ScopedSplitModule` | `OnlyDelegatecall` |
| `ScopedTransferModule` | `OnlyDelegatecall` |
| `PostRolloverDstCptTransferModule` | `OnlyDelegatecall` |
| `PreRolloverReferenceModule` | `OnlyDelegatecall` |
| `MidRolloverReferenceModule` | `OnlyDelegatecall` |
| `PostRolloverReferenceModule` | `OnlyDelegatecall` |

No diamond inheritance. Every concrete module inherits `OnlyDelegatecall`.
Library uses: `using SafeERC20 for IERC20` in `ScopedSplitModule`,
`ScopedTransferModule`, `PostRolloverDstCptTransferModule`, `ApproveModule`,
and `OwnerTokenPullModule`.

---

## Storage

**NONE.** Every module under `src/modules/` declares zero state variables.
Non-function declarations only:

| Symbol | Kind | Source |
|---|---|---|
| `PreRolloverSnapshot(address,bytes32,address,uint256,uint256)` | event | `src/modules/PreRolloverReferenceModule.sol:21` |
| `MidRolloverObservation(address,bytes32,address,uint256,uint256)` | event | `src/modules/MidRolloverReferenceModule.sol:21` |
| `PostRolloverSnapshot(address,bytes32,address,uint256,uint256)` | event | `src/modules/PostRolloverReferenceModule.sol:21` |
| `PostRolloverDstCptTransferred(address,address,address,uint256)` | event | `src/modules/PostRolloverDstCptTransferModule.sol` |
| `ApproveModuleExecuted(address,address,address,bytes4,uint256)` | event | `src/modules/ApproveModule.sol:34` |
| `OwnerTokenPulled(address,address,address,uint256)` | event | `src/modules/OwnerTokenPullModule.sol` |
| `ScopedTransferModuleTokenMoved(address,address,address,uint256)` | event | `src/modules/ScopedTransferModule.sol` |
| `ScopedSplitModuleTokenMoved(address,address,address,uint256)` | event | `src/modules/ScopedSplitModule.sol` |

Constants, errors, and events are not storage slots. No module declares an
ERC-7201 namespace — the statelessness is what makes delegatecall safe by
construction: no slot the module writes can collide with the rolloverContract's
`erc7201:cork.rollover.rolloverContract` namespace.

---

## Entrypoints

Every module exposes exactly one external `execute(...)` selector. All are
intended to be invoked via `delegatecall`, never directly.

| Function | Modifiers | Role gate | Revert paths | Source |
|---|---|---|---|---|
| `ApproveModule.execute(IERC20 token, address spender, bytes4 selector, uint256 amount)` | `external onlyDelegatecall` | guard rejects direct calls | `OnlyDelegatecall__DirectCallForbidden` on direct call; `ApproveModule__ZeroSpender`; `ApproveModule__SpenderCallFailed(bytes)` if spender call reverts (capped returndata); OZ `SafeERC20` errors on failed approve | `src/modules/ApproveModule.sol` |
| `OwnerTokenPullModule.execute(IERC20 token, uint256 amount, bool allowUnderfill)` | `external onlyDelegatecall` | guard rejects direct calls | `OnlyDelegatecall__DirectCallForbidden` on direct call; `OwnerTokenPullModule__ZeroToken`; `OwnerTokenPullModule__ZeroAmount`; `OwnerTokenPullModule__NothingPullable`; OZ `SafeERC20` errors on failed exact `transferFrom`; emits `OwnerTokenPulled` after the pull | `src/modules/OwnerTokenPullModule.sol` |
| `ScopedSplitModule.execute(IERC20 token, uint256 amount, address[] recipients, uint16[] bps)` | `external onlyDelegatecall` | guard rejects direct calls | `OnlyDelegatecall__DirectCallForbidden`; `ScopedSplitModule__*` validation errors; emits `ScopedSplitModuleTokenMoved` per recipient transfer | `src/modules/ScopedSplitModule.sol` |
| `ScopedTransferModule.execute(IERC20 token, uint256 amount, address to)` | `external onlyDelegatecall` | guard rejects direct calls | `OnlyDelegatecall__DirectCallForbidden`; `ScopedTransferModule__*` validation errors; emits `ScopedTransferModuleTokenMoved` after the transfer | `src/modules/ScopedTransferModule.sol` |
| `PostRolloverDstCptTransferModule.execute(IERC20 dstCpt, address recipient)` | `external onlyDelegatecall` | guard rejects direct calls | `OnlyDelegatecall__DirectCallForbidden`; `PostRolloverDstCptTransferModule__ZeroRecipient`; OZ `SafeERC20` errors on failed minted-amount transfer; emits `PostRolloverDstCptTransferred` after a nonzero transfer | `src/modules/PostRolloverDstCptTransferModule.sol` |
| `PreRolloverReferenceModule.execute(bytes32 orderDigest, IERC20 token)` | `external onlyDelegatecall` | guard rejects direct calls | `OnlyDelegatecall__DirectCallForbidden`; otherwise emits `PreRolloverSnapshot` | `src/modules/PreRolloverReferenceModule.sol` |
| `MidRolloverReferenceModule.execute(bytes32 orderDigest, IERC20 token)` | `external onlyDelegatecall` | guard rejects direct calls | `OnlyDelegatecall__DirectCallForbidden`; otherwise emits `MidRolloverObservation` | `src/modules/MidRolloverReferenceModule.sol` |
| `PostRolloverReferenceModule.execute(bytes32 orderDigest, IERC20 token)` | `external onlyDelegatecall` | guard rejects direct calls | `OnlyDelegatecall__DirectCallForbidden`; otherwise emits `PostRolloverSnapshot` | `src/modules/PostRolloverReferenceModule.sol` |

`OwnerTokenPullModule` is intentionally generalized by token, but it is not a
generic transfer gadget. The signed hook chooses only token, explicit nonzero
amount, and whether that amount is exact or a maximum. Source is always
`ICorkRolloverContract(address(this)).owner()` and destination is always the
delegatecall host. `CorkRolloverContract` does not parse owner-pull calldata or
compare arbitrary ERC-20 raw units against source-share accounting. `_unwindLeg`
later credits only the real sibling `srcCPT` delta before Phoenix `unwindMint`,
and existing rollover accounting handles underfill.

All functions are `external` and non-`payable`. No reentrancy guard is
declared at the module level — the rolloverContract's `_handlePhasePremium`
(`src/CorkRolloverContract.sol:636`) and `_handlePhaseRollover`
(`src/CorkRolloverContract.sol:703`) paths are guarded one frame up.

**Module-level auth is `none` because authority is enforced one frame up
in the rolloverContract.** `CorkRolloverContract._prevalidateIntentCalls` (`src/CorkRolloverContract.sol:1032-1066`)
runs four invariant checks per `RolloverTypes.Call`:

1. `c.isDelegateCall == true` (else `CorkRolloverContract__MustBeDelegateCall`).
2. `c.allowFailure == false` (else `CorkRolloverContract__MayNotAllowFailure`).
3. `c.value == 0` (else `CorkRolloverContract__MayNotHaveValue`).
4. `c.target.code.length > 0` (else `CorkRolloverContract__HookTargetNoCode`).

Then the 4-arg overload `registry.check(c.target, moduleType, attesters, threshold)`
is invoked (`src/CorkRolloverContract.sol:1061`), with `attesters`/`threshold` supplied from the
rolloverContract's live-trust mirror; failure surfaces as
`CorkRolloverContract__ModuleTypeMismatch(target, expected)` (`src/CorkRolloverContract.sol:1063`).
The four `ModuleType` constants are defined in `src/libraries/Typehashes.sol:45-55`:
`MODULE_TYPE_PRE_ROLLOVER_HOOK`, `MODULE_TYPE_MID_ROLLOVER_HOOK`,
`MODULE_TYPE_POST_ROLLOVER_HOOK`, `MODULE_TYPE_EXECUTOR`.

---

## 4-Hook RolloverIntent flow

`CorkRolloverContract.executeIntentHooks` (`src/CorkRolloverContract.sol:285`) dispatches one of
two phase handlers per call:

- **`HookPhase.Premium`** → `_handlePhasePremium`
  (`src/CorkRolloverContract.sol:636`) → `_executeIntentCalls(premiumHooks, MODULE_TYPE_EXECUTOR)`
  at `src/CorkRolloverContract.sol:662`. Executor modules route premium payouts under
  cPT holder discretion. For new premium intents after M-05, use only
  `ScopedTransferModule` or `ScopedSplitModule`.
- **`HookPhase.Rollover`** → `_handlePhaseRollover`
  (`src/CorkRolloverContract.sol:703`) → three sequential `_executeIntentCalls` legs:
  1. `preRolloverHooks` with `MODULE_TYPE_PRE_ROLLOVER_HOOK`
     (`src/CorkRolloverContract.sol:718`).
  2. Phoenix `unwindMint` + `deposit` between pre and mid.
  3. `midRolloverHooks` with `MODULE_TYPE_MID_ROLLOVER_HOOK`
     (`src/CorkRolloverContract.sol:725`).
  4. `postRolloverHooks` with `MODULE_TYPE_POST_ROLLOVER_HOOK`
     (`src/CorkRolloverContract.sol:945`), after `_finalizeRolloverLeg` has
     written the transient minted dstCPT amount for post-rollover routing.

The three "Reference" modules
(`PreRolloverReferenceModule`/`MidRolloverReferenceModule`/`PostRolloverReferenceModule`)
slot into the matching pre/mid/post buckets and emit balance snapshots.
`PostRolloverDstCptTransferModule` is the standard production post hook for dstCPT:
it reads the rolloverContract-scoped minted `dstCptAfterDeposit - dstCptBeforeDeposit` register and
routes only that amount to the cPT roller, so nonzero standing dstCPT is not swept.
M-05 removed the obsolete `TransferAllModule` and `SplitModule`; new premium
templates must route through `ScopedTransferModule` or `ScopedSplitModule`.

The per-batch ERC-7484 check overload (`check(address, ModuleType, address[], uint256)`) is
re-invoked every leg — see `INV-MODULE-TYPE-MATCH` below.

---

## Internal helpers

None of the modules declare internal helpers. The three reference modules each contain a single
`emit X(address(this), orderDigest, address(token), token.balanceOf(address(this)), block.timestamp)`
pattern.

---

## Invariants touched

### M-INV-1 (Module statelessness — empirical, not enforced)

- **Statement:** Every module under `src/modules/` declares zero non-constant
  state variables.
- **Throw site:** structural — no runtime check; verified by inspection of
  `src/modules/*.sol` (Storage section above).
- **Risk:** drift for *future* attested modules. The codebase has no
  automated check enforcing this.

### INV-MODULE-TYPE-MATCH (per-batch ERC-7484 attestation)

- **Statement:** Every hook target in a `RolloverTypes.Call[]` chain MUST be
  attested for the matching `ModuleType` bucket via the 4-arg
  `IERC7484.check(module, moduleType, attesters, threshold)` overload (the rolloverContract
  supplies `attesters`/`threshold` from its live-trust mirror). A module attested as
  `MODULE_TYPE_PRE_ROLLOVER_HOOK` cannot be invoked from a `postRolloverHooks`
  chain.
- **Throw site:** `CorkRolloverContract__ModuleTypeMismatch(target, moduleType)` at
  `src/CorkRolloverContract.sol:1063` when the registry's per-bucket check reverts.
- **Source pointers:** dispatch sites in `src/CorkRolloverContract.sol:662, 718, 725, 945`;
  `ModuleType` constants in `src/libraries/Typehashes.sol:45-55`.

### INV-MODULE-TARGET-HAS-CODE

- **Statement:** `_prevalidateIntentCalls` rejects any hook target whose
  bytecode length is zero, so the ERC-7484 attestation gate cannot admit
  not-yet-deployed clone addresses or EOAs.
- **Throw site:** `CorkRolloverContract__HookTargetNoCode(target)` at
  `src/CorkRolloverContract.sol:1058`.

### INV-MODULE-DELEGATECALL-ONLY

- **Statement:** `RolloverTypes.Call.isDelegateCall` MUST be `true`,
  `allowFailure` MUST be `false`, `value` MUST be `0` for every hook in a
  chain.
- **Throw sites:** `CorkRolloverContract__MustBeDelegateCall`
  (`src/CorkRolloverContract.sol:1049`), `CorkRolloverContract__MayNotAllowFailure`
  (`src/CorkRolloverContract.sol:1052`), `CorkRolloverContract__MayNotHaveValue`
  (`src/CorkRolloverContract.sol:1055`).

### INV-MODULE-LIVE-TRUST-IMMUTABLE-PER-HOOK

- **Statement:** `_executeIntentCalls` snapshots
  `keccak256(liveTrustThreshold ‖ liveTrustAttesters)` before each
  delegatecall and reverts if the post-call hash differs. A hook that
  reaches the canonical live-trust mirror via `delegatecall` is rejected.
- **Throw site:** `CorkRolloverContract__TrustConfigMutatedDuringHook(beforeHash, afterHash)`
  at `src/CorkRolloverContract.sol:1147`. Hash helper: `_liveTrustHash`
  (`src/CorkRolloverContract.sol:1071`).

### Module-flow indirect couplings

- **INV-DST-FLOOR (cPT-holder-signed dst-side floor)** and **INV-5 (dstCST
  no-drain across leg)** — see `docs/INVARIANTS.md`. A hostile pre-hook
  or mid-hook under-producing value is caught by the rolloverContract's
  `params.minSharesOut` floor (post-deposit), and dstCST drain is caught
  by the post-leg accounting guard, not by any module-level check.

---

## Integrations

Outbound from each module (executed under the rolloverContract's storage frame):

| Module | Outbound interface | Edge type | Source |
|---|---|---|---|
| `ApproveModule.execute` | `SafeERC20.forceApprove` (USDT-style zero-first via OZ; no bespoke bounded approval returndata handling) → `call` to spender (success returndata discarded; failure capped at 256 bytes in `ApproveModule__SpenderCallFailed`) → `forceApprove(0)` | `call` to token (via OZ) and spender | `src/modules/ApproveModule.sol` |
| `PreRolloverReferenceModule.execute` | `IERC20.balanceOf`, `emit PreRolloverSnapshot` | `staticcall`; no external state mutation | `src/modules/PreRolloverReferenceModule.sol:33-41` |
| `MidRolloverReferenceModule.execute` | `IERC20.balanceOf`, `emit MidRolloverObservation` | `staticcall` | `src/modules/MidRolloverReferenceModule.sol:33-41` |
| `PostRolloverReferenceModule.execute` | `IERC20.balanceOf`, `emit PostRolloverSnapshot` | `staticcall` | `src/modules/PostRolloverReferenceModule.sol:33-41` |
| `PostRolloverDstCptTransferModule.execute` | `LibPostRolloverDstCptMinted.read` + `SafeERC20.safeTransfer` of the transient minted amount when nonzero; emit `PostRolloverDstCptTransferred` | `tload` + token call | `src/modules/PostRolloverDstCptTransferModule.sol` |

Inbound: the only intended caller is `CorkRolloverContract._executeIntentCalls`
(`src/CorkRolloverContract.sol:1130`) via `delegatecall` executed by
`_delegatecallHookDiscardReturndata` at `src/CorkRolloverContract.sol:1100`.
That dispatch is invoked from four sites in the rolloverContract:
premium executor (`:662`), preRollover (`:718`), midRollover (`:725`),
postRollover (`:945`). The rolloverContract's entrypoint `executeIntentHooks`
(`src/CorkRolloverContract.sol:285`) is in turn invoked only from
`CorkRolloverContractFactory.executeIntentHooks` (factory-side allowlist + transient
`originSettler` latch — see `factory.md`).

**ERC dependencies cited:**

- **ERC-7484 (Module Attestation):** trust root for module dispatch.
  `IERC7484` interface at `src/interfaces/external/erc7484/IERC7484.sol`. The
  interface declares both `check` overloads, but the rolloverContract dispatch path uses only
  the 4-arg `check(address, ModuleType, address[], uint256)` overload plus
  `trustAttesters`. `ModuleType` is
  `type ModuleType is uint256`. Cork-specific module-type constants in
  `src/libraries/Typehashes.sol:45-55`.
- **ERC-20 (token interface):** every module imports
  `@openzeppelin/contracts/token/ERC20/IERC20.sol`. Scoped variants and
  `ApproveModule` use
  `@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol`. `ApproveModule`
  uses `forceApprove` only for the approval legs; spender-call failure
  returndata is capped locally and is separate from the OZ approval path.
- **EIP-191 / EIP-712:** not directly touched by these modules. The
  `orderDigest` arg to reference modules is an opaque `bytes32` produced
  upstream by the rollover-contract/Settler EIP-712 typed-hash machinery (see
  `rolloverContract.md`).

---

## Sharp edges

### Delegatecall confused-deputy

The rolloverContract willingly hands its storage frame to whatever code lives at
`c.target`. If the registry is misconfigured (a non-stateless contract
attested under any `MODULE_TYPE_*` bucket), that contract's writes land in
the rolloverContract's slot map. **Mitigation:** the per-batch ERC-7484 check
(`src/CorkRolloverContract.sol:1061`) is the only line of defence — the rolloverContract does
not introspect bytecode. Operationally, attesters MUST verify that any
attested module is stateless before issuing the attestation.

### `c.target` substitution

`_executeIntentCalls` does not pin module addresses in the intent — they
are supplied calldata-side per `RolloverTypes.Call`. The mitigation is
purely the ERC-7484 attestation: a hostile cPT holder cannot
route to a non-attested target without an attester signing for it.
`_prevalidateIntentCalls` additionally rejects code-less targets so a
not-yet-deployed clone address cannot be slipped through.

### Reference modules: no integrity binding

`Pre/Mid/PostRolloverReferenceModule` accept `orderDigest` as a free
calldata arg — they do not cross-check it against the rolloverContract's in-flight
order context. The emitted log is therefore as trustworthy as the caller
wants it to be; observers should treat the events as informational only
unless emitter provenance is authenticated as a rolloverContract delegatecall
context. The rolloverContract's premium / rollover legs do not consume these events
for any state transition. By design per the BS-EVT-25 docstring
annotations; treated as a known weak-promise property rather than a defect.

### `ApproveModule` approval path uses OpenZeppelin `SafeERC20`

`ApproveModule` delegates approve/revoke to `SafeERC20.forceApprove` (USDT-style
zero-first retry included). The module does **not** implement bespoke bounded
approval returndata handling; approval failures surface via OZ helpers and may
copy unbounded token revert data. Spender-call failures alone are capped at
256 bytes in `ApproveModule__SpenderCallFailed`.

### Returndata is ignored

`_executeIntentCalls` captures returndata only on the failure path
(in `_delegatecallHookDiscardReturndata`, `src/CorkRolloverContract.sol:1102-1120`). Any module under `src/modules/` already
returns nothing; a future attested module that returned a value would
have it silently dropped.

---

## Tests

- `test/unit/modules/ApproveModuleAtomicBracket.t.sol` — unit coverage of
  the atomic approve+call+revoke bracket; pins
  `INV-APPROVE-MODULE-NO-RESIDUAL` end-to-end via a delegating host.
- `test/unit/modules/OnlyDelegatecall.t.sol` — unit coverage of
  `INV-REFERENCE-MODULES-DELEGATECALL-ONLY`: every decorated module
  rejects direct calls and succeeds via delegatecall.
- `test/unit/modules/Modules.t.sol` — bundled module unit suite (via
  delegating host so module-internal validation can be observed past the
  `OnlyDelegatecall` guard).
- `test/unit/modules/EvcRolloverAdapterCoverage.t.sol` — adapter-context
  adjacent coverage only; `src/EvcRolloverAdapter.sol` is out of audit scope
  unless explicitly re-added in `SCOPE.md`.
- `test/integration/rollover/HookRestructure.t.sol` — end-to-end
  4-hook flow (pre/mid/post + premium), exercising the full
  `executeIntentHooks` → `_executeIntentCalls` → module `delegatecall`
  pipeline.

---

## Cross-references

- **`rolloverContract.md`** — the caller. `_executeIntentCalls`
  (`src/CorkRolloverContract.sol:1130-1151`) is the sole production invoker; the
  per-hook ERC-7484 attestation gate, code-length check, and live-trust
  no-mutation guard live there.
- **`factory.md`** — `CorkRolloverContractFactory.executeIntentHooks` is the only
  legitimate dispatcher into the rolloverContract's hook-running entrypoints;
  Settler allowlist + transient `originSettler` latch.
- **`libraries.md`** — `Typehashes.sol:45-55` defines the four
  `MODULE_TYPE_*` constants; the EIP-712 typehashes used upstream are at
  `Typehashes.sol:18-68`.
- **`interfaces.md`** — `IERC7484`, `ICorkRolloverContract`, `IRolloverContractLens` are the
  surfaces the rolloverContract consults around module dispatch.
