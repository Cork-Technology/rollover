# Unit: CorkRolloverContract

> _Supplementary protocol reference. The canonical bundle for AI auditors is [`docs/agent-context/`](../../../agent-context/README.md). Code in `src/` is the source of truth when docs disagree._

## Source

`src/CorkRolloverContract.sol` — 1,213 lines.

Per-cPT holder CWIA clone deployed by `CorkRolloverContractFactory`. The rolloverContract is the single
source of truth for hook execution on every rollover leg: it pins the cPT holder's EIP-712 intent
verification through the cPT-holder signature on every hook dispatch, runs the
four-bucket hook pipeline (pre/mid/post rollover + premium) under ERC-7484 module-type
attestation, owns the phoenix `unwindMint` + `deposit` calls between hook batches, and
enforces the cPT-holder-signed `params.minSharesOut` deposit-side floor (`INV-DST-FLOOR`),
the dstCST no-drain bracket (`INV-5`), `INV-CPT-CONTAINED`, and `DSR-1/DSR-2`.
The mid-hook may freely consume caSrc (cross-CA rollover via an attested
SwapModule); end-to-end value is bounded by the dst-side floor. The CWIA trailer is 60 bytes
(owner ‖ factory ‖ erc7484Registry); the owner is the cPT holder by convention and is baked at
clone time (no ownership transfer). Trust-config changes flow through the external per-rolloverContract
trust-config `TimelockController`: cPT holder calls safe/default
`CorkRolloverContractFactory.queueFactoryDefaultTrustConfig()` or advanced/custom
`queueTrustConfig(threshold, attesters)` for their own deployed rolloverContract, waits the configured delay,
then `CorkRolloverContractFactory.applyTrustConfig(rolloverContract)` relays through
`relayTrustConfig` into the rolloverContract's factory-gated `setTrustConfig`
(`INV-TRUST-CONFIG-DELAY` / `INV-ROLLOVER_CONTRACT-TRUST-ONLY-VIA-FACTORY`).

## Inheritance

| Base | Source | Purpose |
|------|--------|---------|
| `ICorkRolloverContract` | `src/interfaces/rollover/ICorkRolloverContract.sol` | External ABI surface implemented by `CorkRolloverContract`. |
| `Initializable` (OZ) | `@openzeppelin/contracts/proxy/utils/Initializable.sol` | Single-shot `initialize`; implementation disables initializers in the constructor. |
| `ReentrancyGuardTransient` (OZ) | `@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol` | Transient-storage `nonReentrant` on every state-mutating entry. |

CWIA cloning is handled at deploy time by the factory using OZ `Clones`; the rolloverContract reads
its 60-byte trailer (owner ‖ factory ‖ erc7484Registry) via `Clones.fetchCloneArgs` in
`_cwiaImmutableArgs`.

## Storage

### ERC-7201 namespaced slot

```solidity
// src/CorkRolloverContract.sol
bytes32 private constant ROLLOVER_CONTRACT_STORAGE_SLOT =
    0xb4cefcf1cd721ac7aa7779687f98e0bf77365d8cc544d423bc3152971ed5cc00;
```

Computed per ERC-7201 as
`keccak256(abi.encode(uint256(keccak256("cork.rollover.rolloverContract")) - 1)) & ~bytes32(uint256(0xff))`.
Reached via the assembly accessor `_s()`. Pinned by
`test/unit/rolloverContract/RolloverContractLens.t.sol::test_storage_rolloverContractStorageNamespaceSlotUnchanged` and
`test/unit/rolloverContract/TrustConfigViaFactory.t.sol::test_namespaceStorageLayout_pinnedToLocked`.

### `RolloverContractStorage` fields

The rolloverContract holds only live trust state — pending/queued state lives on
`CorkRolloverContractFactory.pendingConfig[salt]` / `lastSalt[rolloverContract]` / `queueNonce[rolloverContract]`.
`RolloverContractStorage` has five fields.

| Slot / Symbol | Type | Purpose | Write sites |
|---------------|------|---------|-------------|
| `hookNonces` | `mapping(bytes32 => uint256)` | Per-order bitmap; bit 0 = `PHASE_0_TERMINAL_BIT`. Set when order is fully rolled or partial-fills disabled. Blocks further ROLLOVER phases. | `_applyRolloverAccounting` |
| `rolled` | `mapping(bytes32 => uint256)` | Cumulative srcCST consumed per order. Backs `N-INV-ROLLED-MONOTONE-AND-BOUNDED`. | `_applyRolloverAccounting` |
| `premiumFiredFor` | `mapping(bytes32 => mapping(address => mapping(bytes32 => bool)))` | Per-(orderDigest, filler, subFiller) latch; rolloverContract-local replay protection for `_handlePhasePremium`. Under atomic-fill commits/reverts with the Settler frame. NOT the protocol-wide M-11 gate. | `src/CorkRolloverContract.sol` |
| `liveTrustThreshold` | `uint8` | Current attester threshold; seeded at `initialize`, replaced by `setTrustConfig` (factory-only). | `initialize`, `setTrustConfig` |
| `liveTrustAttesters` | `address[]` | Current attester list mirror (vendored `IERC7484` omits attester reads). | `initialize`, `setTrustConfig` |

Pending trust state (`pendingConfig`, `lastSalt`, `queueNonce`) lives on the factory; read it via `ICorkRolloverContractFactory.pendingTrustConfig(rolloverContract)`. `erc7484Registry` is no longer a storage slot — it is baked into the CWIA trailer (see below).

### Constants

| Constant | Value | Source |
|----------|-------|--------|
| `MAX_TRUST_ATTESTERS` | `16` | Public implementation constant exposed through `ICorkRolloverContract`. |
| `PHASE_0_TERMINAL_BIT` | `1 << 0` | Internal rollover-terminal bit. |
| `ROLLOVER_CONTRACT_STORAGE_SLOT` | `0xb4cefc...cc00` | ERC-7201 namespace slot. |

The trust-config delay lives on the constructor-supplied external per-rolloverContract
`TimelockController` (configured delay bounded by `MAX_TRUST_CONFIG_DELAY`).

### CWIA trailer (immutable, not storage)

Trailer layout: bytes 0x00..0x14 = `owner` (cPT holder), bytes 0x14..0x28 = `factory`, bytes
0x28..0x3c = `erc7484Registry`. Read on every call via `_cwiaImmutableArgs`
→ `_owner()` / `_factory()` / `_registry()`. Backs `INV-ROLLOVER_CONTRACT-OWNER-IMMUTABLE`.

## Entrypoints

| Function | Modifiers | Role gate | Revert paths | Source |
|----------|-----------|-----------|--------------|--------|
| `initialize(uint8 initialTrustThreshold, address[] initialTrustAttesters)` | `nonReentrant onlyFactory initializer` | Factory only (CWIA byte 20..40); single-shot | `CorkRolloverContract__NotFactory`, `CorkRolloverContract__RegistryZero`, `CorkRolloverContract__EmptyDefaultAttesters`, `CorkRolloverContract__InvalidThreshold`, `CorkRolloverContract__TooManyAttesters`, OZ `InvalidInitialization` | `initialize` |
| `executeIntentHooks(bytes32 orderDigest, RolloverTypes.HookPhase phase, RolloverIntent intent, bytes cptHolderSig, FillContext fillContext, OrderData orderData)` | `nonReentrant onlyFactory` | Factory only | Envelope: `RolloverContractMismatch`, `SettlerMismatch`, `DeadlineExpired`, `IntentDeadlineExpired`, `ZeroFiller`. Binding: `OrderDigestMismatch`, `IntentHashMismatch`, `OrderDataDigestMismatch`, `RolloverIntentHashCtxMismatch`, `SignedSettlerOriginMismatch`, `IntentDeadlineBeforeFillDeadline`. Auth: `BadIntentSignature`. Phase rejection is owned by `CorkRolloverContractFactory.executeIntentHooks` before rolloverContract dispatch. Preflight (ROLLOVER): `PhaseAlreadyConsumed`, `ZeroRollover`, `OverfillCeiling`, `SrcPoolIdMismatch`, `DstPoolIdMismatch`, share-quantum errors. Leg: `SrcCptShortfall`, `RolloverZeroUnwindMint`, `UnwindMintShortfall`, `CaInsufficientForDeposit`, `RolloverZeroDeposit`, `DepositOverMint`, `UnwindDepositShortfall`, `UnderfillNotAllowed`, `DstCptNotRestored`, `SrcCptNotRestored`, `SrcCstNotReturned`, `MidPhaseDstCstDrain`. Hook execution: `MustBeDelegateCall`, `MayNotAllowFailure`, `MayNotHaveValue`, `HookTargetNoCode`, `ModuleTypeMismatch`, `DelegatecallFailed`, `TrustConfigMutatedDuringHook`. PREMIUM: `PremiumBeforeRollover`, `PremiumAlreadyFiredForFiller`, `PremiumHookSweptExcess`, `PremiumTokenMismatch`. Pool resolution: `PoolManagerCallFailed`. | `executeIntentHooks` |
| `withdraw(address token, uint256 amount)` | `nonReentrant onlyOwner` | Owner only (CWIA byte 0..20) | `CorkRolloverContract__NotOwner`, ERC-20 revert | `withdraw` |
| `setTrustConfig(uint8 threshold, address[] attesters)` | `nonReentrant onlyFactory` | Factory only (CWIA byte 20..40) — cPT holder must route through `CorkRolloverContractFactory.queueFactoryDefaultTrustConfig` or `queueTrustConfig` → configured trust-config timelock delay → `applyTrustConfig` | `CorkRolloverContract__NotFactory`, `CorkRolloverContract__InvalidThreshold`, `CorkRolloverContract__TooManyAttesters`, registry revert | `setTrustConfig` |
| `rolloverContractSnapshot()` view | — | Public view | none | `rolloverContractSnapshot` |
| `orderState(bytes32 orderDigest)` view | — | Public view | none | `orderState` |
| `premiumFiredFor(bytes32, address, bytes32)` view | — | Public view | none | `src/CorkRolloverContract.sol` |

Modifier bodies: `onlyOwner`; `onlyFactory`.

Selector hex values are omitted from this table; compute via `cast sig` if needed.

## Internal helpers

| Function | Purpose | Source |
|----------|---------|--------|
| `_cwiaImmutableArgs() → (address owner, address factory, address registry)` | Decode the 60-byte CWIA trailer; backs `_owner()` / `_factory()` / `_registry()`. | `CorkRolloverContract._cwiaImmutableArgs` |
| `_owner() → address` | CWIA-baked owner (cPT holder). | `CorkRolloverContract._owner` |
| `_factory() → address` | CWIA-baked factory. | `CorkRolloverContract._factory` |
| `_registry() → address` | CWIA-baked ERC-7484 registry. | `CorkRolloverContract._registry` |
| `_validateTrustConfig(uint8, address[])` | Trust-config validator for factory-seeded defaults and owner-queued updates (zero / empty / threshold-too-big / zero-attester / duplicate-attester rejection). | `src/CorkRolloverContract.sol` |
| `_validateFillEnvelope(intent, fillContext)` | RolloverContract/Settler/deadline/filler envelope checks. Phase-range rejection is factory-owned. | `src/CorkRolloverContract.sol` |
| `_validateIntentHashBinding(intent, orderDigest, rolloverIntentHash)` | `intent.orderDigest == orderDigest` + zero-digest canonical hash equality. | `src/CorkRolloverContract.sol` |
| `_ensureOwnerAuthorized(orderDigest, cptHolderSig)` | Checks `SignatureChecker.isValidSignatureNow(_owner(), orderDigest, cptHolderSig)` on every RolloverContract dispatch and writes no authorization state. | `src/CorkRolloverContract.sol` |
| `_handlePhasePremium($, orderDigest, fillContext, premiumHooks)` | Per-`(orderDigest, filler, subFiller)` latch on `fillContext.subFiller`, standing-balance trip-wire, EXECUTOR-typed `premiumHooks`, `PremiumFired` emit. | `CorkRolloverContract._handlePhasePremium` |
| `_handlePhaseRollover($, orderDigest, fillContext, params, intent)` | Straight-line ROLLOVER sequence (snapshots → preHooks → unwindMint → mid-bracket → DSR-2 seal → deposit → finalize). Returns `(actualRolled, dstProduced, srcLeftover)`. | `CorkRolloverContract._handlePhaseRollover` |
| `_validateRolloverPreflight($, orderDigest, fillContext, params)` | Terminal-bit clear, non-zero fillAmount, overfill ceiling, srcPoolId/dstPoolId cross-check. Signed settler pin is enforced earlier by `_validateOrderDataBinding`. | `src/CorkRolloverContract.sol` |
| `_populateScratch(s, params)` | Per-leg snapshots + PoolManager + CA + sibling-CPT derivation. | `CorkRolloverContract._populateScratch` |
| `_unwindLeg(s, params, fillContext)` | srcCPT-delta check (+ over-delivery refund to cPT holder), DSR-1 `unwindMint` with balance-delta accounting. | `CorkRolloverContract._unwindLeg` |
| `_depositLeg(s, params)` | DSR-2 sealed `caDstAfterMid - caDstBefore` derivation, unconditional `forceApprove` + `forceApprove(0)` tail, DSR-1 `deposit` with balance-delta. | `CorkRolloverContract._depositLeg` |
| `_finalizeRolloverLeg($, orderDigest, fillContext, params, intent, s, dstProduced)` | Underfill accounting, `rolled` + terminal-bit writes, dstCST/leftover srcCST `safeTransfer(params.settler)`, postHooks, CPT restoration guards, `INV-5` dstCST no-drain, and `INV-SRC-CST-RETURNED`. | `CorkRolloverContract._finalizeRolloverLeg` |
| `_siblingCptToken(pm, poolIdRaw, cstToken)` | Phoenix `shares(MarketId)` staticcall; 64-byte bounded returndata; `swapToken == cstToken` identity check. | `CorkRolloverContract._siblingCptToken` |
| `_prevalidateIntentCalls(hooks, moduleType)` | Per-hook: `isDelegateCall == true`, `allowFailure == false`, `value == 0`, `target.code.length > 0`, then `IERC7484.check(target, moduleType, liveTrustAttesters, liveTrustThreshold)`. | `CorkRolloverContract._prevalidateIntentCalls` |
| `_liveTrustHash($)` | `keccak256(abi.encode(liveTrustThreshold, liveTrustAttesters))` snapshot used to detect hook-induced trust-mirror mutation. | `CorkRolloverContract._liveTrustHash` |
| `_executeIntentCalls(hooks, moduleType)` | Pre-validate against the live trust snapshot, delegatecall each hook, compare live-trust hash post-hook to detect `TrustConfigMutatedDuringHook`, and reseed the ERC-7484 registry trust-attester view from the rolloverContract mirror after each hook. | `CorkRolloverContract._executeIntentCalls` |
| `_emitIntentPhaseFired($, orderDigest, phase, fillContext, actualRolled, dstProduced)` | Emit `IntentPhaseFired` with post-phase `rolled` and terminal-bit state. | `CorkRolloverContract._emitIntentPhaseFired` |

## Invariants touched

The rolloverContract enforces or relies on the following ledger entries
(`docs/INVARIANTS.md`):

- **`INV-TRUST-CONFIG-DELAY`** (`docs/INVARIANTS.md:340`) — mandatory delay between
  `CorkRolloverContractFactory.queueFactoryDefaultTrustConfig()` or
  `queueTrustConfig(...)` for the caller's own deployed rolloverContract and `applyTrustConfig(rolloverContract)`,
  enforced by the external per-rolloverContract trust-config `TimelockController`. Re-queue cancels the prior op and
  restarts the trust-config timelock clock. RolloverContract-side throw site: `setTrustConfig` gates on
  `msg.sender == _factory()`, so any non-factory writer reverts `CorkRolloverContract__NotFactory`.
- **`INV-ROLLOVER_CONTRACT-TRUST-ONLY-VIA-FACTORY`** (`docs/INVARIANTS.md:1374`) — the rolloverContract's
  sole live-trust writer is `setTrustConfig`, gated `onlyFactory`.
- **`INV-ROLLOVER_CONTRACT-CPT-HOLDER-SIG-EVERY-DISPATCH`** (`docs/INVARIANTS.md`) — every RolloverContract hook dispatch verifies the cPT-holder signature over the cPT-holder-signed order digest. Throw site:
  `_ensureOwnerAuthorized` (`BadIntentSignature` on invalid cPT-holder signature).
- **`INV-CPT-CONTAINED`** (`docs/INVARIANTS.md:730`) — srcCPT/dstCPT are cPT holder property; rolloverContract
  holds them only inside the transient leg window. Throw site:
  `_finalizeRolloverLeg` (`CorkRolloverContract__DstCptNotRestored` / `CorkRolloverContract__SrcCptNotRestored`).
- **`DSR-1`** (`docs/INVARIANTS.md:752`) — pool-reported outputs cross-checked by
  rolloverContract-balance delta; zero-output → revert. Throw sites: `_unwindLeg`
  (`RolloverZeroUnwindMint`); `_depositLeg` (`RolloverZeroDeposit`).
- **`DSR-2`** (`docs/INVARIANTS.md:765`) — `_depositLeg` consumes the sealed
  `caDstAfterMid` snapshot, no re-read. Sealed in `_handlePhaseRollover`; consumed by
  `_depositLeg` (`CaInsufficientForDeposit` when bracket delta zero).
- **`INV-DST-FLOOR`** (replaces removed `INV-3`) — end-to-end value bounded by
  cPT-holder-signed `params.minSharesOut`. Throw site: `_handlePhaseRollover`
  (`UnwindDepositShortfall`).
- **`INV-5`** (`docs/INVARIANTS.md:852`) — dstCST balance non-decreasing across the leg.
  Throw site: `_finalizeRolloverLeg` (`MidPhaseDstCstDrain`).
- **`INV-PARAMS-SETTLER-PIN`** (`docs/INVARIANTS.md:1172`) —
  `orderData.rolloverParams.settler == fillContext.originSettler`. Throw site:
  `_validateOrderDataBinding` (`CorkRolloverContract__SignedSettlerOriginMismatch`).
- **`INV-SETTLER-APPROVED`** (`docs/INVARIANTS.md:955`) — observed at
  `_validateFillEnvelope` via `factory.originatingSettler()` (`SettlerMismatch`). Primary
  enforcement in factory.
- **`INV-DEFAULT-ATTESTERS-FACTORY-SEEDED`** (`docs/INVARIANTS.md:1192`) — observed: the
  rolloverContract receives the factory-baked default attester pair at `initialize` and seeds the
  registry / live-trust mirror in lock-step during `initialize`.
- **`INV-ROLLOVER_CONTRACT-OWNER-IMMUTABLE`** (`docs/INVARIANTS.md:1245`) — CWIA-baked owner + write-once
  registry. No setter. Backed by `_cwiaImmutableArgs` / `initializer` modifier on
  `initialize`.
- **`N-INV-ROLLED-MONOTONE-AND-BOUNDED`** (`docs/INVARIANTS.md:1279`) — `rolled` is
  addition-only and bounded by `fillContext.orderSize`. Backed at `_validateRolloverPreflight`
  ceiling check in `_validateRolloverPreflight` and `_finalizeRolloverLeg` write through
  `_applyRolloverAccounting`; terminal-bit is set-only.
- **`M-11`** (`docs/INVARIANTS.md:150`) — per-(orderDigest, filler[, subFiller]) PREMIUM single-fire.
  Protocol-wide gate is **Settler-side**; the rolloverContract enforces only its local
  replay protection for a successful `_handlePhasePremium` execution.
  RolloverContract-side throw site: `CorkRolloverContract._handlePhasePremium` →
  `CorkRolloverContract__PremiumAlreadyFiredForFiller`; latch keyed by resolved `fillContext.subFiller`
  (wire-zero decodes to self-key per `LibFillerAuth`). Under atomic-fill commits/reverts
  with the Settler frame (`INV-PREMIUM-HOOK-REVERT-CASCADES`).
- **RolloverContract premium-routing discretion** (`docs/INVARIANTS.md`, **non-invariant**) —
  standing-balance tripwire across `premiumHooks` (`CorkRolloverContract._handlePhasePremium`);
  hooks may route delivered premium but must not sweep pre-leg standing balance.

## Integrations

Outbound calls from the rolloverContract surface:

| Target | Interface | Site |
|--------|-----------|------|
| Factory | `IRolloverHookDispatcher.originatingSettler()` | `_validateFillEnvelope` originating-settler latch read |
| ERC-7484 registry | `IERC7484.trustAttesters(uint8, address[])` | `initialize`, `setTrustConfig`, trust restoration after hooks |
| ERC-7484 registry | `IERC7484.check(address target, ModuleType moduleType, address[] attesters, uint256 threshold)` | `_prevalidateIntentCalls` |
| cPT holder EOA / contract | `SignatureChecker.isValidSignatureNow(_owner(), digest, sig)` (ERC-1271 fallback) | `_ensureOwnerAuthorized` |
| Phoenix `IPoolShare` | `poolId()`, `poolManager()` | `_validateRolloverPreflight`, `_populateScratch` |
| Phoenix `IPoolManager` | `market(MarketId) → Market`, `shares(MarketId)` (staticcall), `previewDeposit(MarketId, caIn)`, `unwindMint(MarketId, shares, recipient, ctp)`, `deposit(MarketId, caIn, recipient)` | `_populateScratch`, `_siblingCptToken`, `_unwindLeg`, `_depositLeg` |
| ERC-20 (CST, CPT, CA, premium) | `IERC20.balanceOf`, `safeTransfer`, `forceApprove` | Throughout `_populateScratch`, `_unwindLeg`, `_depositLeg`, `_finalizeRolloverLeg`, `_handlePhasePremium`, `withdraw`. |
| cPT holder (refund target) | `IERC20.safeTransfer(_owner(), …)` | `_unwindLeg` srcCPT over-delivery refund |
| Approved Settler (`params.settler`) | `IERC20.safeTransfer` (dstCST + leftover srcCST) | `_finalizeRolloverLeg` |
| RolloverContract self (delegatecall) | Module bytecode at `c.target` with `c.callData` | `_delegatecallHookDiscardReturndata` via `_executeIntentCalls` |
| `LibAuthenticatedHooks` | `intentStructHash(RolloverIntent memory)` | `_validateIntentHashBinding` |
| `Typehashes` | `MODULE_TYPE_PRE_/MID_/POST_ROLLOVER_HOOK`, `MODULE_TYPE_EXECUTOR`, `ROLLOVER_INTENT_TYPEHASH` | Rollover/premium hook module checks and committed intent hashing |

RolloverContract consumes (inbound) the Settler-forwarded `FillContext` and cPT-holder-signed
`RolloverIntent` + `RolloverParams` through `executeIntentHooks`; transit is
`Filler → Settler → CorkRolloverContractFactory → CorkRolloverContract`.

## Tests

| Suite | Path |
|-------|------|
| RolloverContract unit tests | `test/unit/rolloverContract/` |
| Factory unit tests (cover dispatch + premium latch) | `test/unit/factory/` |
| Module unit tests | `test/unit/modules/` |
| Rollover integration | `test/integration/rollover/` |
| Premium integration | `test/integration/premium/` |
| Trust-config end-to-end (queue → configured delay → apply via timelock) | `test/integration/timelock/EndToEnd.t.sol` |
| Trust-config unit (factory queue surface) | `test/unit/factory/TrustConfigQueue.t.sol` |
| Trust-config unit (rolloverContract factory-only gate) | `test/unit/rolloverContract/TrustConfigViaFactory.t.sol` |
| Auth integration (envelope/binding/per-dispatch cPT holder auth) | `test/integration/auth/` |
| Lifecycle integration (terminal bit, partial/exact) | `test/integration/lifecycle/` |
| Defaulter / reclaim integration | `test/integration/defaulter/` |
| Invariant suite — factory + rolloverContract | `test/invariant/FactoryInvariants.t.sol` + handlers under `test/invariant/handlers/` |
| Invariant ledger gate | `scripts/ci/check-invariant-ledger.py` reading `docs/INVARIANTS.md` |
| RolloverContract harnesses (storage / internal-fn probes) | `test/harnesses/` |
| Mocks (PoolManager / PoolShare / ERC-7484) | `test/mocks/` |

Test files mirror the `src/` layout under `test/`; see each suite directory for the exhaustive `*.t.sol` list.
