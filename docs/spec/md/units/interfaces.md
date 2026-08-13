# Unit — `src/interfaces/` (Interface Surfaces)

> _Supplementary protocol reference. The canonical bundle for AI auditors is [`docs/agent-context/`](../../../agent-context/README.md). Code in `src/` is the source of truth when docs disagree._

> Per-contract spec unit doc bundling every local `.sol` file under `src/interfaces/` plus the vendored ERC-7683 origin/destination surfaces. Phoenix integration interfaces (`src/interfaces/external/phoenix/*`) are documented in `units/phoenix-integration.md`. Code is canonical.

## 1. Source

- **RolloverContract/factory interfaces** (6 files, all `pragma 0.8.34`):
  - `src/interfaces/rollover/IRolloverContractLens.sol` — 68 lines.
  - `src/interfaces/rollover/ICorkRolloverContract.sol` — 284 lines.
  - `src/interfaces/rollover/ICorkRolloverContractFactory.sol` — 251 lines.
  - `src/interfaces/rollover/ICorkRolloverContractFactoryAdmin.sol` — 42 lines.
  - `src/interfaces/rollover/ICorkRolloverContractFactoryDefaults.sol` — 86 lines.
  - `src/interfaces/rollover/IRolloverHookDispatcher.sol` — 55 lines.
- **Settler interfaces** (4 files):
  - `src/interfaces/settlers/ISettler.sol` — 196 lines.
  - `src/interfaces/settlers/ISettlerAdmin.sol` — 56 lines.
  - `src/interfaces/settlers/IExactSettler.sol` — 23 lines.
  - `src/interfaces/settlers/IPartialSettler.sol` — 71 lines.
- **Vendored external interfaces**:
  - `src/interfaces/external/erc7484/IERC7484.sol` — 34 lines.
  - `src/interfaces/external/erc7683/IOriginSettler.sol` — 65 lines.
  - `src/interfaces/external/erc7683/IDestinationSettler.sol` — 12 lines.
  - `src/interfaces/external/erc7683/ERC7683Types.sol` — 68 lines.

**Interface count enumerated by Read**: **12 interfaces** (`IRolloverContractLens`, `ICorkRolloverContract`, `ICorkRolloverContractFactory`, `ICorkRolloverContractFactoryAdmin`, `ICorkRolloverContractFactoryDefaults`, `IRolloverHookDispatcher`, `ISettler`, `ISettlerAdmin`, `IExactSettler`, `IPartialSettler`, `IOriginSettler`, `IDestinationSettler`) plus the `IERC7484` interface and the `ERC7683Types` library / `ModuleType` UDVT. Phoenix interfaces excluded by scope.

Purpose: pin the typed wire-format consumed by cPT holders/cPT holders, fillers, the factory, SDKs/indexers, and the Rhinestone ERC-7484 registry; absorb canonical ERC-7683 verbatim; vendor a deliberately narrow `IERC7484` so the audit-local attestation surface stays minimal.

### NatSpec one-liners (grouped by domain)

#### RolloverContract

- **`ICorkRolloverContract`** — `src/interfaces/rollover/ICorkRolloverContract.sol:7`
  > "cPT-holder-owned rolloverContract (CWIA clone) that holds risk-coverage capacity, executes signed hook intents on behalf of the cPT holder, and brackets every rollover leg with attester-gated module checks."
- **`IRolloverContractLens`** — `src/interfaces/rollover/IRolloverContractLens.sol:7`
  > "Factory read-through lens for factory-deployed rolloverContract state and configuration."

#### Factory

- **`ICorkRolloverContractFactory`** — `src/interfaces/rollover/ICorkRolloverContractFactory.sol:13`
  > Factory deploying per-cPT holder rolloverContract clones, transient-state holder, settler allowlist. The constructor takes `erc7484Registry` plus a factory-baked default attester pair; rolloverContracts consult the registry directly.

#### Settler (ERC-7683 + Cork extensions)

- **`ISettler`** — `src/interfaces/settlers/ISettler.sol:10`
  > Shared Settler lifecycle, metadata, and ERC-7683 entrypoints. Extends the canonical ERC-7683 origin and destination settler interfaces.
- **`ISettlerAdmin`** — `src/interfaces/settlers/ISettlerAdmin.sol:8`
  > Cork-specific Settler admin surface for pause controls and token rescue.
- **`IExactSettler`** — `src/interfaces/settlers/IExactSettler.sol:8`
  > Exact-mode Settler accounting views.
- **`IPartialSettler`** — `src/interfaces/settlers/IPartialSettler.sol:10`
  > Partial-mode Settler events and accounting views.
- **`IOriginSettler`** (vendored ERC-7683) — `src/interfaces/external/erc7683/IOriginSettler.sol:9`
  > Canonical ERC-7683 origin-settler surface implemented by Cork `ExactSettler.sol and PartialSettler.sol`. The five entry points pin the wire-format used by relayers and integrators.
- **`IDestinationSettler`** (vendored ERC-7683) — `src/interfaces/external/erc7683/IDestinationSettler.sol:5`
  > "ERC-7683 destination-side settler entrypoint that fillers call to satisfy an order."

#### Attester gate

- **`IERC7484`** (vendored narrow) — `src/interfaces/external/erc7484/IERC7484.sol:11`
  > Minimal ERC-7484 attester-registry surface consumed by Cork.
- **`ModuleType`** (user-defined value type) — `src/interfaces/external/erc7484/IERC7484.sol:5`

#### Phoenix (out of scope — see `units/phoenix-integration.md`)

`IPoolShare` / `IPoolManager` / `MarketId` / `Market` are documented separately.

---

## 2. Inheritance

```
IOriginSettler ◀──┐
                  ├── ISettler
IDestinationSettler ◀┘

IExactSettler and IPartialSettler extend ISettler; ISettlerAdmin is a Cork-specific sibling surface.
```

Per-interface inheritance (verified via `is` clause at the cited line):

| Interface | Inherits | Source |
|---|---|---|
| `ISettler` | `IOriginSettler, IDestinationSettler` | `src/interfaces/settlers/ISettler.sol:10` |
| `IOriginSettler` | (none) | `src/interfaces/external/erc7683/IOriginSettler.sol:9` |
| `IDestinationSettler` | (none) | `src/interfaces/external/erc7683/IDestinationSettler.sol:6` |
| `IExactSettler` | `ISettler` | `src/interfaces/settlers/IExactSettler.sol:9` |
| `IPartialSettler` | `ISettler` | `src/interfaces/settlers/IPartialSettler.sol:11` |
| `ISettlerAdmin` | (none) | `src/interfaces/settlers/ISettlerAdmin.sol:8` |
| `ICorkRolloverContract` | (none) | `src/interfaces/rollover/ICorkRolloverContract.sol:10` |
| `IRolloverContractLens` | (none) | `src/interfaces/rollover/IRolloverContractLens.sol:8` |
| `ICorkRolloverContractFactory` | (none) | `src/interfaces/rollover/ICorkRolloverContractFactory.sol:7` |
| `IERC7484` | (none) | `src/interfaces/external/erc7484/IERC7484.sol:11` |

`ICorkRolloverContractFactory` and `IRolloverContractLens` are sibling interfaces co-implemented by `CorkRolloverContractFactory` (no on-chain inheritance edge between them).

---

## 3. Storage

**N/A.** Interfaces declare no storage. Structs and user-defined value types declared inside interface bodies (`IRolloverContractLens.RolloverContractConfig`, `ICorkRolloverContract.RolloverContractTrustSnapshot`, `ICorkRolloverContract.RolloverContractOrderState`, `ModuleType`) are wire-format projections of implementer state, not storage themselves.

### Struct definitions (typed return projections)

| Struct / UDT | Field count | Source |
|---|---|---|
| `IRolloverContractLens.RolloverContractConfig` | 5 (`owner`, `factory`, `erc7484Registry`, `liveTrustThreshold`, `liveTrustAttesters`) — pending trust state lives on `ICorkRolloverContractFactory.pendingTrustConfig(rolloverContract)` | `src/interfaces/rollover/IRolloverContractLens.sol:19-25` |
| `ICorkRolloverContract.RolloverContractTrustSnapshot` | 3 (`erc7484Registry`, `liveTrustThreshold`, `liveTrustAttesters`) | `src/interfaces/rollover/ICorkRolloverContract.sol:18-22` |
| `ICorkRolloverContract.RolloverContractOrderState` | 2 (`rolled`, `rolloverTerminal`) | `src/interfaces/rollover/ICorkRolloverContract.sol:32-35` |
| `ModuleType` (UDT — `type ModuleType is uint256`) | n/a | `src/interfaces/external/erc7484/IERC7484.sol:5` |

---

## 4. Entrypoints

External actor / implementer surface, then per-interface function table.

### 4.1 Actor → implementer matrix

| Interface | Implementer | Counterparty callers |
|---|---|---|
| `ICorkRolloverContract` | `CorkRolloverContract` | `CorkRolloverContractFactory.executeIntentHooks` (only authorised dispatcher); owner (`withdraw`); factory-only (`setTrustConfig` via `relayTrustConfig` from the factory's `TimelockController`); SDK/lens (`rolloverContractSnapshot`, `orderState`, `premiumFiredFor`) |
| `IRolloverContractLens` | `CorkRolloverContractFactory` | SDK / indexers (off-chain), recovery actors, integrating frontends |
| `ICorkRolloverContractFactory` / `ICorkRolloverContractFactoryAdmin` / `ICorkRolloverContractFactoryDefaults` / `IRolloverHookDispatcher` | `CorkRolloverContractFactory` | Settlers (`executeIntentHooks`, `originatingSettler`); users (`deployRolloverContract`); factory operational roles (`approveSettler`, `revokeSettler`, `setDefaults`); SDK/operators (`predictRolloverContractOf`, `isDeployedRolloverContract`, `rolloverContractOf`, `pendingTrustConfig`, defaults views) |
| `ISettler` / `ISettlerAdmin` / `IExactSettler` / `IPartialSettler` | `ExactSettler` / `PartialSettler` | cPT holders/cPT holder (`open`); fillers (`openFor`, `fill`); keepers/recovery (`reclaim`, `markExpired`, `cancel`); settler operational roles (`pause`, `unpause`, bounded token rescue); SDK (`resolve`, `resolveFor`, accounting views) |
| `IOriginSettler` | Settlers via `ISettler` | ERC-7683 wire-format integrators (relayers, generic 7683 frontends) |
| `IDestinationSettler` | `Settler` | Same — origin == destination on the same chain for this product |
| `IERC7484` | External Rhinestone registry (NOT implemented in this repo) | `CorkRolloverContract._executeIntentCalls` (`check(module, moduleType)` per hook target); `CorkRolloverContract.initialize` and `CorkRolloverContract.setTrustConfig` (`trustAttesters` bootstrap/update — the latter only callable by `CorkRolloverContractFactory` via the timelock relay) |

### 4.2 Function table

| Interface | Function | Inputs / Outputs | Implementer | Callers | Src pointer |
|---|---|---|---|---|---|
| `ICorkRolloverContract` | `initialize(initialTrustThreshold, initialTrustAttesters)` | `(uint8, address[]) → ()` | `CorkRolloverContract` | Factory (CWIA-trailer auth) | `ICorkRolloverContract.sol:228` |
| `ICorkRolloverContract` | `executeIntentHooks(orderDigest, phase, intent, cptHolderSig, ctx, orderData)` | `(bytes32, HookPhase, RolloverIntent, bytes, FillContext, OrderData) → (uint256 dstProduced, uint256 srcLeftover)` | `CorkRolloverContract` | Factory only | `ICorkRolloverContract.sol` |
| `ICorkRolloverContract` | `withdraw(token, amount)` | `(address, uint256) → ()` | `CorkRolloverContract` | Owner | `ICorkRolloverContract.sol:283` |
| `ICorkRolloverContract` | `setTrustConfig(threshold, attesters)` | `(uint8, address[]) → ()` | `CorkRolloverContract` | Factory only (via `CorkRolloverContractFactory.relayTrustConfig` from the external trust-config `TimelockController`) | `ICorkRolloverContract.sol:274` |
| `ICorkRolloverContract` | `rolloverContractSnapshot()` | `() view → RolloverContractTrustSnapshot` | `CorkRolloverContract` | Lens / internal | `ICorkRolloverContract.sol:188` |
| `ICorkRolloverContract` | `orderState(orderDigest)` | `(bytes32) view → RolloverContractOrderState` | `CorkRolloverContract` | Lens | `ICorkRolloverContract.sol:200` |
| `ICorkRolloverContract` | `premiumFiredFor(orderDigest, filler, subFiller)` | `(bytes32, address, bytes32) view → bool` | `CorkRolloverContract` | Lens | `ICorkRolloverContract.sol:213` |
| `ICorkRolloverContractFactory` | `deployRolloverContract()` | `() → address` | `CorkRolloverContractFactory` | Any user (one rolloverContract per address) | `ICorkRolloverContractFactory.sol:77` |
| `ICorkRolloverContractFactory` | `predictRolloverContractOf(owner)` | `(address) view → address rolloverContract` | `CorkRolloverContractFactory` | Anyone / SDK / operators | Public CREATE2 CWIA predictor for the pre-deployment rolloverContract address. The prediction uses the factory/deployer address, implementation address, owner-derived salt, and live registry baked into the CWIA args; identical predictions across chains require identical factory, implementation, owner, and registry inputs. |
| `ICorkRolloverContractFactory` | `queueFactoryDefaultTrustConfig()` | `() → ()` | `CorkRolloverContractFactory` | rolloverContract owner only | Safe/default path for the caller's own deployed rolloverContract; snapshots current factory defaults at queue time. |
| `ICorkRolloverContractFactory` | `queueTrustConfig(threshold, attesters)` | `(uint8, address[]) → ()` | `CorkRolloverContractFactory` | rolloverContract owner only | Advanced/custom path for the caller's own deployed rolloverContract. |
| `ICorkRolloverContractFactory` | `applyTrustConfig(rolloverContract)` | `(address) → ()` | `CorkRolloverContractFactory` | Permissionless (post-delay) | `ICorkRolloverContractFactory.sol` |
| `ICorkRolloverContractFactory` | `cancelTrustConfig()` | `() → ()` | `CorkRolloverContractFactory` | rolloverContract owner only | Cancels only the caller's own pending trust config. |
| `ICorkRolloverContractFactory` | `pendingTrustConfig(rolloverContract)` | `(address) view → (uint8 threshold, address[] attesters, uint64 effectiveAt)` | `CorkRolloverContractFactory` | SDK / fillers | `ICorkRolloverContractFactory.sol:177` |
| `IRolloverContractLens` | `orderState(rolloverContract, orderDigest)` | `(address, bytes32) view → RolloverContractOrderState` | `CorkRolloverContractFactory` | SDK | `IRolloverContractLens.sol:38` |
| `IRolloverContractLens` | `premiumFiredFor(rolloverContract, orderDigest, filler, subFiller)` | `(address, bytes32, address, bytes32) view → bool` | `CorkRolloverContractFactory` | SDK | `IRolloverContractLens.sol:55` |
| `IRolloverContractLens` | `rolloverContractConfig(rolloverContract)` | `(address) view → RolloverContractConfig` | `CorkRolloverContractFactory` | SDK | `IRolloverContractLens.sol:67` |
| `IRolloverHookDispatcher` | `executeIntentHooks(rolloverContract, orderDigest, phase, intent, cptHolderSig, ctx, orderData)` | `(address, bytes32, HookPhase, RolloverIntent, bytes, FillContext, OrderData) → (uint256, uint256)` | `CorkRolloverContractFactory` | Settler | `IRolloverHookDispatcher.sol` |
| `IRolloverHookDispatcher` | `originatingSettler()` | `() view → address` | `CorkRolloverContractFactory` | RolloverContract | `IRolloverHookDispatcher.sol:54` |
| `ICorkRolloverContractFactoryAdmin` | `approveSettler` / `revokeSettler` / `approvedSettlers` | allowlist controls and view | `CorkRolloverContractFactory` | Admin / anyone view | `ICorkRolloverContractFactoryAdmin.sol:24`, `:33`, `:41` |
| `ICorkRolloverContractFactoryDefaults` | defaults views and `setDefaults` | deployment-default controls | `CorkRolloverContractFactory` | Defaults manager / anyone view | `ICorkRolloverContractFactoryDefaults.sol` |
| `IOriginSettler` | `open(OnchainCrossChainOrder)` | ERC-7683 on-chain open | Settlers | cPT holder directly | `IOriginSettler.sol:19` |
| `IOriginSettler` | `openFor(order, signature, originFillerData)` | ERC-7683 third-party gasless open | Settlers | Filler / relayer | `IOriginSettler.sol` |
| `IOriginSettler` | `resolve(OnchainCrossChainOrder)` | on-chain order view → `ResolvedCrossChainOrder` | Settlers | SDK | `IOriginSettler.sol` |
| `IOriginSettler` | `resolveFor(order, originFillerData)` | gasless order view → `ResolvedCrossChainOrder` | Settlers | SDK | `IOriginSettler.sol` |
| `IDestinationSettler` / `ISettler` | `fill(orderId, originData, fillerData)` | ERC-7683 phase dispatch | Settlers | Filler | `IDestinationSettler.sol`, `ISettler.sol` |
| `ISettler` | `DOMAIN_SEPARATOR()` | `() view → bytes32` | Settlers | `BaseFiller._runSettlement`, SDK | `ISettler.sol:114` |
| `ISettler` | `version()` | `() pure → string` | Settlers | SDK / deployment checks | `ISettler.sol:119` |
| `ISettler` | `reclaim(orderId, defaultedFiller, subFiller, originData)` | async unpaid escrow → cPT holder rolloverContract | Settlers | Permissionless post-fillDeadline; requires async-premium mode | `ISettler.sol:156` |
| `ISettler` | `markExpired(orderId, originData)` | `(bytes32, bytes) → ()` | Settlers | Permissionless post-fillDeadline | `ISettler.sol:174` |
| `ISettler` | `cancel(orderId, originData, cptHolderSig)` | unified cPT-holder cancel | Settlers | Anyone (with cPT-holder sig) | `ISettler.sol:188` |
| `ISettler` | `orderStatus(orderId)` | `(bytes32) view → OrderStatus` | Settlers | SDK | `ISettler.sol:195` |
| `IExactSettler` | `rolloverAccountingOf(orderDigest)` | `(bytes32) view → ExactRolloverAccounting` | `ExactSettler` | SDK | `IExactSettler.sol:18` |
| `IPartialSettler` | `rolloverAccountingOf(orderDigest)` | `(bytes32) view → PartialOrderAccounting` | `PartialSettler` | SDK | `IPartialSettler.sol:49` |
| `IPartialSettler` | `fillerSlotAccountingOf(orderDigest, filler, subFiller)` | `(bytes32, address, bytes32) view → FillerSlotAccounting` | `PartialSettler` | SDK | `IPartialSettler.sol:66` |
| `IERC7484` | `check(module, moduleType)` | `(address, ModuleType) view` (REVERTS on failure) | External Rhinestone registry | `CorkRolloverContract._executeIntentCalls` per hook target | `IERC7484.sol:16` |
| `IERC7484` | `check(module, moduleType, attesters, threshold)` | explicit-threshold view check | External Rhinestone registry | compatibility surface | `IERC7484.sol:23` |
| `IERC7484` | `trustAttesters(threshold, attesters)` | `(uint8, address[]) → ()` | External Rhinestone registry | RolloverContract initialization and factory-applied trust config | `IERC7484.sol:33` |

---

## 5. Internal helpers

**N/A.** Interfaces have no function bodies; there is no internal-to-internal call edge to plot. Inter-interface inheritance is the only graph; see §2.

---

## 6. ERC conformance map (audit-critical)

### ERC-7683 — origin and destination entry points

| ERC-7683 method | Vendored interface | Cork implementer | Implementer line |
|---|---|---|---|
| `open(OnchainCrossChainOrder)` | `IOriginSettler.sol:19` | `Settler.open` | `src/BaseSettler.sol:243` |
| `openFor(GaslessCrossChainOrder, bytes signature, bytes originFillerData)` | `IOriginSettler.sol` | `Settler.openFor` | `src/BaseSettler.sol`, with storage hooks in `src/ExactSettler.sol` / `src/PartialSettler.sol` |
| `resolve(OnchainCrossChainOrder) view returns (ResolvedCrossChainOrder)` | `IOriginSettler.sol` | `Settler.resolve` | `src/BaseSettler.sol` (via `_resolveDecodedOrder`) |
| `resolveFor(GaslessCrossChainOrder, bytes originFillerData) view` | `IOriginSettler.sol` | `Settler.resolveFor` | `src/BaseSettler.sol` |
| `fill(bytes32 orderId, bytes originData, bytes fillerData)` | `IDestinationSettler.sol` | `Settler.fill` | `src/BaseSettler.sol`, with storage hooks in `src/ExactSettler.sol` / `src/PartialSettler.sol` |

`ISettler` advertises both `IOriginSettler` and `IDestinationSettler` because origin == destination on the same chain for this product (`src/interfaces/external/erc7683/IDestinationSettler.sol`). Its `fill` redeclaration overrides the destination-side interface only.

ERC-7683 signature verification is implemented by the Settler using EIP-712 plus ERC-1271-compatible `SignatureChecker` against the cPT-holder-signed order digest.

### ERC-7484 — attestation surface (vendored narrow)

`src/interfaces/external/erc7484/IERC7484.sol` deliberately vendors only the members Cork dereferences from the upstream Rhinestone registry:

| Vendored method | Source line | Cork consumer | Consumer line |
|---|---|---|---|
| `check(address module, ModuleType moduleType) external view` | `IERC7484.sol:16` | `CorkRolloverContract._executeIntentCalls` (per hook target, per-bucket) | per-call hook dispatch |
| `check(address module, ModuleType moduleType, address[] attesters, uint256 threshold) external view` | `IERC7484.sol:23` | explicit-threshold compatibility surface | not the hot-path rolloverContract call |
| `trustAttesters(uint8 threshold, address[] attesters) external` | `IERC7484.sol:33` | `CorkRolloverContract.initialize` and `CorkRolloverContract.setTrustConfig` | seed and factory-only update |

`ModuleType` (`IERC7484.sol:5`) is a `uint256` UDT mirroring the upstream Rhinestone enum. Distinct module-type IDs let a single module be attested for one bucket (e.g. PRE_ROLLOVER_HOOK) and rejected from another (e.g. POST_ROLLOVER_HOOK) even when the same attester set covers both buckets.

**Omitted upstream members** (intentional, audit-locality):
- `check(address)` 1-arg overload.
- `checkForAccount(address, address, ModuleType)`.
- Attester-set views (`findTrustedAttesters`, etc.).

Rationale documented in `src/interfaces/external/erc7484/IERC7484.sol:7-10`.

### EIP-712 / ERC-1271 / ERC-20 / ERC-7201

- **EIP-712** — `ISettler.DOMAIN_SEPARATOR()` (`ISettler.sol:134`) — domain `(CorkSettler, 1.0.0)` + chainid. Consumed by fillers and SDK clients that compute order digests off-chain.
- **ERC-1271** — contract-wallet signatures over user orders, cancel signatures,
  FillerAuth, and rolloverContract per-dispatch cPT-holder authorization. Implementers route
  through OpenZeppelin `SignatureChecker`.
- **ERC-20** — not directly inherited by any interface here; `ICorkRolloverContract.withdraw(token, amount)` (`ICorkRolloverContract.sol:282`) operates on `IERC20` semantics via the implementer.
- **ERC-7201** — namespaced storage discipline; not directly an interface member, but `rolloverContractSnapshot()` / `rolloverContractConfig` mirror patterns depend on the implementer pinning a non-colliding namespace. Implementer slots: `EXACT_SETTLER_STORAGE_SLOT`, `PARTIAL_SETTLER_STORAGE_SLOT`, `ROLLOVER_CONTRACT_STORAGE_SLOT`, `FACTORY_STORAGE_SLOT` (W0 §3.3-§3.5).
- **ERC-165** — not invoked by any interface in this folder; `Settler` advertises its union surface by direct inheritance (`ISettler.sol:145`) rather than runtime selector probes.

---

## 7. Drift risk surfaces (audit-sensitive)

### G-1. IRolloverContractLens ↔ CorkRolloverContractFactory struct ABI

Indexers cache against `ICorkRolloverContract.RolloverContractOrderState` and `IRolloverContractLens.RolloverContractConfig` (`IRolloverContractLens.sol:19-67`). Adding a field is a **wire-format break** for pinned ABIs. Mitigation: the explicit ERC-7201 namespace pin in the factory plus the `liveTrustThreshold` / `liveTrustAttesters` mirror inside the rolloverContract (`ICorkRolloverContract.sol:18-22`) keep the lens from widening `IERC7484`.

### G-2. ISettler destination `fill` override

`ISettler.sol` redeclares `fill` with `override(IDestinationSettler)`. The merged Settler still advertises `is ISettler` (W0 §2.2), while the vendored origin interface no longer carries a destination-side `fill`.

### G-3. Shared structs cross interface boundaries

Structs that cross interface boundaries (`RolloverTypes.RolloverIntent`, `FillContext`, `RolloverParams`, `GaslessCrossChainOrder`, `OrderData`, `FillRecord`, `FillerRollover`) appear on both `IRolloverHookDispatcher.executeIntentHooks` (`IRolloverHookDispatcher.sol:39-47`) and `ICorkRolloverContract.executeIntentHooks` (`ICorkRolloverContract.sol:255-262`). Reordering or retyping any field silently breaks the factory→rolloverContract dispatch even when both contracts compile, because the calldata layout diverges (`abi.decode` of a struct with any dynamic field is not equivalent to `abi.decode` of the matching tuple). The `RolloverParams` typehash carries `srcPoolId`, `dstPoolId`, and `settler` fields.

### G-4. Signature collision (vendored ERC-7683 + Cork extensions)

`ISettler` extends `IOriginSettler` and `IDestinationSettler` (`ISettler.sol:10`). A future ERC-7683 revision that introduces a function with the same 4-byte selector as one of the Cork-added members (`DOMAIN_SEPARATOR`, `version`, `reclaim`, `markExpired`, `cancel`, `orderStatus`) would need an explicit interface review. Mitigation: the vendored `IOriginSettler.sol` / `IDestinationSettler.sol` files are pinned by hand; drift detection is by re-fetching upstream ERC-7683 reference and diffing.

### G-5. IERC7484 vendored-narrow rationale

Vendoring only `check(address,ModuleType)` and `trustAttesters(uint8,address[])` keeps the audit-local surface to two members. Widening would (a) tempt downstream changes that bypass the rolloverContract's gate logic, (b) add a toolchain dependency on `rhinestonewtf/registry`, (c) duplicate state already mirrored locally via `rolloverContractSnapshot.liveTrustThreshold/liveTrustAttesters`. The rolloverContract's `IERC7484.check` reverts on attestation failure; the vendored `IERC7484.sol` declares no error types of its own, so the upstream Rhinestone registry (not this interface) defines and raises selectors such as `NoTrustedAttestersFound()`, `InsufficientAttestations()`, `RevokedAttestation(address)`, and `AttestationNotFound()`, which propagate verbatim through the rolloverContract.

### G-6. Selector-only callers bypassing interface

A caller that uses `IFoo(addr).fn(...)` and a caller that builds calldata via `abi.encodeWithSelector` may diverge if the interface is updated but a hand-rolled callsite is not. Known site: `CorkRolloverContract` uses `IPoolManager.shares.selector` for a staticcall (W0 §3.4) — retyping `shares` in `IPoolManager` requires verifying that site. (Phoenix surface — out of unit scope.)

---

## 8. Invariants touched

Interfaces carry no runtime invariants themselves; they pin wire-format. Ledger entries that thread through interface members:

- **INV-TRUST-CONFIG-DELAY** — `docs/INVARIANTS.md:340`. Surface on `ICorkRolloverContractFactory.queueFactoryDefaultTrustConfig` / `queueTrustConfig` / `applyTrustConfig` / `cancelTrustConfig` / `pendingTrustConfig` and the rolloverContract's factory-gated `ICorkRolloverContract.setTrustConfig` (`ICorkRolloverContract.sol:274`). Pending state lives on the factory; SDKs read it via `pendingTrustConfig(rolloverContract)`.
- **INV-FILLER-AUTH** — `docs/INVARIANTS.md:1014`. Surface on `IDestinationSettler.fill` via the `FillerAuth` EIP-712 commitment in `fillerData`; enforcement inside `LibFillerAuth.isAuthorised` at fill time.
- **INV-SETTLER-APPROVED** — `docs/INVARIANTS.md:955`. Surface on `ICorkRolloverContractFactory.approveSettler` / `revokeSettler` / `approvedSettlers` (`ICorkRolloverContractFactoryAdmin.sol:24,33,41`); enforcement inside `CorkRolloverContractFactory.executeIntentHooks` allowlist gate (W0 §4.4).
- **INV-PARAMS-SETTLER-PIN** — `docs/INVARIANTS.md` (rolloverContract section). Surface on the `OrderData.rolloverParams` carried through `ICorkRolloverContract.executeIntentHooks` and `IRolloverHookDispatcher.executeIntentHooks` (`IRolloverHookDispatcher.sol:39-47`); enforcement at `src/CorkRolloverContract.sol:520`.
- **INV-DEFAULTER-RECOUP** — `docs/INVARIANTS.md:273`. Surface on `ISettler.reclaim(orderId, defaultedFiller, subFiller, originData)` (`ISettler.sol:152`).

Interface-stability items:

- **IRolloverContractLens struct ABI stability** — `IRolloverContractLens.RolloverContractConfig`, `ICorkRolloverContract.RolloverContractTrustSnapshot`, and `ICorkRolloverContract.RolloverContractOrderState` form the SDK / indexer decoding contract. Their ABI component order (field order, names, and types) is CI-pinned by `test/integration/admission/LensStructAbiStability.t.sol`, which reads the interface sources via `vm.readFile` and fails on any silent reorder, rename, retype, or extension. (No `docs/INVARIANTS.md` ledger entry; the test is the gate.)
- **`IPoolShare.expiry()` existence** — reader-discipline-only (no ledger entry). Read by `Settler._validateOrder` at `src/BaseSettler.sol, src/ExactSettler.sol, and src/PartialSettler.sol` to gate openFor against pool deadline. Removing `expiry()` from `IPoolShare` would silently drop the gate. (Phoenix surface; documented in `units/phoenix-integration.md`.)

---

## 9. Integrations

Interfaces in this unit are consumed by:

| Interface | Consumed by (src/) | Site |
|---|---|---|
| `ICorkRolloverContract` | `CorkRolloverContractFactory` | `src/CorkRolloverContractFactory.sol:347-348` (`executeIntentHooks` forward) |
| `ICorkRolloverContractFactory` | `Settler` | `src/BaseSettler.sol, src/ExactSettler.sol, and src/PartialSettler.sol` (`_dispatchToFactory` → factory dispatch) |
| `IRolloverContractLens` | (off-chain only) | SDK / indexers |
| `ISettler` (`DOMAIN_SEPARATOR`) | `BaseFiller` | `src/BaseFiller.sol` (`_runSettlement`) |
| `IDestinationSettler.fill` | `BaseFiller`; adapter-context `EvcRolloverAdapter` only | `src/BaseFiller.sol:191`; adapter analogue at `src/EvcRolloverAdapter.sol:543` is out of audit scope unless explicitly re-added in `SCOPE.md` |
| `IERC7484` | `CorkRolloverContract` | `src/CorkRolloverContract.sol:274` (init seed), per-bucket `check(target, moduleType)` invocations inside `_executeIntentCalls`, `src/CorkRolloverContract.sol:362` (`setTrustConfig` forward — factory-only) |
| `IOriginSettler` / `IDestinationSettler` | `Settler` | `src/BaseSettler.sol, src/ExactSettler.sol, and src/PartialSettler.sol` (inherits via `ISettler`) |

Outbound from interfaces themselves: **none** (no function bodies).

---

## 10. Tests

- **Per-interface integration coverage** (test dir): `test/integration/`. Use current CI / local `forge test` as the branch pass floor (per AGENTS.md), not a fixed count.
- **Lens / SDK surface**: `test/unit/rollover-contract/RolloverContractLens.t.sol` and sibling files (23 lens scenarios).
- **ERC-7683 conformance**: exercised through `Settler` open/openFor/fill suites under `test/integration/settler/`.
- **ERC-7484 gate**: exercised via `CorkRolloverContract.initialize` + `CorkRolloverContract.setTrustConfig` paths under `test/integration/rollover-contract/` and the external trust-config timelock suite (`test/integration/timelock/EndToEnd.t.sol`, `test/unit/factory/TrustConfigQueue.t.sol`, `test/unit/rollover-contract/TrustConfigViaFactory.t.sol`).
- **Invariant ledger gate**: `test/integration/admission/OrderDataWireStability.t.sol` (and sibling docs-gate tests) read `docs/INVARIANTS.md` via `vm.readFile`.

---

## 11. Cross-references

- **Sibling unit docs**:
  - `docs/spec/md/units/rolloverContract.md` — implementer of `ICorkRolloverContract`; consumer of `IERC7484`, Phoenix surface.
  - `docs/spec/md/units/factory.md` — implementer of `ICorkRolloverContractFactory` + `IRolloverContractLens`.
  - `docs/spec/md/units/settler.md` — implementer of `ISettler` plus exact / partial accounting interfaces.
  - `docs/spec/md/units/base-filler.md` — non-implementer consumer of `ISettler.DOMAIN_SEPARATOR` and `IDestinationSettler.fill`.
  - `docs/spec/md/units/phoenix-integration.md` — Phoenix interfaces (`IPoolShare`, `IPoolManager`).
- **`docs/INVARIANTS.md`** — INV-TRUST-CONFIG-DELAY (340), INV-FILLER-AUTH (1014), INV-SETTLER-APPROVED (955), INV-DEFAULTER-RECOUP (273).
