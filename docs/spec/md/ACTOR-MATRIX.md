# Cork Rollover — Actor Capability Matrix

> _Supplementary protocol reference. The canonical bundle for AI auditors is [`docs/agent-context/`](../../agent-context/README.md). Code in `src/` is the source of truth when docs disagree._

Cross-cutting privilege map: who can call what across the entire `src/` surface
of this repo. Resolved against current `src/`.

Scope alignment: `src/BaseFiller.sol` is in scope.
`src/EvcRolloverAdapter.sol` is adapter/integration context only and is out of
audit scope unless explicitly re-added in `SCOPE.md`.

The Settler exposes a role surface (`DEFAULT_ADMIN_ROLE` / `RECOVERY_ROLE` /
`PAUSER_ROLE` / `UNPAUSER_ROLE`) granted to explicit constructor authority arguments
(`admin_`, `pauser_`, `unpauser_`). `owner()` is an OZ `Ownable`
ENS/deployment identity surface: it can transfer or renounce, but protocol role
management, bounded ERC-20 rescue, pause, and unpause remain role-gated.

Every external/public state-mutating function is listed once with the actors
that can reach it, plus the gate that decides. Views are summarised in §2.3
to keep the matrix readable.

Symbol legend used in §2:

- **✓** — callable; gate (if any) is structural-only (e.g. `nonReentrant`,
  CWIA-uniqueness, single-shot `initializer`).
- **✗** — not callable (modifier / role / latch / allowlist rejects).
- **⊕(condition)** — conditionally callable; the gate is named inline. The
  condition is the exact code-level check, not a paraphrase.
- **n/a** — gate is meaningless for this actor.

All `file.sol:line` pointers resolve against current `src/`.

The per-contract Actor/Capability/Function/Limit/Source table is rendered
inline alongside the multi-actor matrix for each contract; the single-row form
is sufficient when one actor or actor-class dominates the gate (e.g.
`withdraw` = cPT holder only).

Relationship to THREAT-MODEL.md: every `⊕(gate)` cell here corresponds to a
trust boundary in THREAT-MODEL.md; the matrix enumerates *who can cross*, the
threat model enumerates *what they get if they do*.

---

## 1. Actor enumeration

### 1.1 User EOA / Safe (cPT holder)

- **Identity binding** — `orderData.user` field of the signed `OrderData`
  payload. For accepted orders this equals `ICorkRolloverContract(orderData.rolloverContract).owner()`.
- **Authority** — gasless admission verifies the EIP-712 / ERC-1271
  signature over the `OrderData` digest against `orderData.user`; on-chain
  `open(OnchainCrossChainOrder)` instead binds `msg.sender == orderData.user`.
- **Provenance** — the cPT holder is the implemented signing party; older notes
  may call this party cPT holder or cPT holder. The solver / cST roller is called Filler in code; a
  two-sided-cPT holder matching model is not implemented.

### 1.2 Relayer / gasless opener (arbitrary EOA in openFor position)

- **Identity binding** — `msg.sender` of `openFor`; no on-chain identity
  check. On-chain `open(OnchainCrossChainOrder)` is submitted by
  `orderData.user` directly.
- **Authority** — none beyond the user's signature in calldata; `originFillerData`
  on `openFor` is opaque and ignored.
- **Provenance** — anyone willing to submit gas for `openFor`.

### 1.3 Filler EOA / Safe (settler-side filler caller)

- **Identity binding** — `msg.sender` of `Settler.fill`.
- **Authority** — `LibFillerAuth.isAuthorised` at `src/ExactSettler.sol and src/PartialSettler.sol` (helper
  at `src/libraries/LibFillerAuth.sol:91`) admits one of three branches
  (`INV-FILLER-AUTH`):
  - `orderData.exclusiveFiller == address(0)` (any caller), OR
  - `msg.sender == orderData.exclusiveFiller` (direct call), OR
  - `fillerAuthSig` is a valid EIP-712 / ERC-1271 sig by `exclusiveFiller`
    over `FillerAuth(bytes32 orderDigest,address destination,bytes32 subFiller)`.
- **Note** — `BaseFiller` is not a contract signer. It appears in this row
  only as `msg.sender` when the exclusive-filler check is open or delegated
  via `fillerAuthSig`. `EvcRolloverAdapter` references are adapter context
  only.

### 1.4 Delegated executor (third-party executor on behalf of exclusive filler)

- **Identity binding** — `msg.sender` of `Settler.fill` with
  `msg.sender != exclusiveFiller` and a populated `fillerAuthSig`.
- **Authority** — EIP-712 signature by `exclusiveFiller` over
  `FillerAuth(orderDigest, destination, subFiller)` (`FILLER_AUTH_TYPEHASH` at
  `src/libraries/Typehashes.sol:35-36`). Destination + subFiller binding is the
  gate — executor identity is NOT signed.
- **Provenance** — `INV-FILLER-AUTH`.

### 1.5 Approved Settler

- **Identity binding** — `approvedSettlers[settlerAddress] == true` in
  `CorkRolloverContractFactory.FactoryStorage` (`src/CorkRolloverContractFactory.sol:141`).
- **Authority** — sole caller permitted into
  `CorkRolloverContractFactory.executeIntentHooks` (allowlist check
  `_requireApprovedSettler` at `src/CorkRolloverContractFactory.sol:330`, helper revert
  `CorkRolloverContractFactory__SettlerNotApproved` at `:982-984`). `INV-SETTLER-APPROVED`.
- **Provenance** — factory approver via `approveSettler(settler)`
  (`src/CorkRolloverContractFactory.sol:354`). Allowlist is default-deny; atomic
  v1→v2 migration via `approveSettler(v2); revokeSettler(v1)`.

### 1.6 Settler admin / recovery / pauser / unpauser (OZ `AccessControl`)

- **Identity binding** — OZ `AccessControl.hasRole(role, account)` on
  `Settler`. Four roles: `DEFAULT_ADMIN_ROLE`, `RECOVERY_ROLE`,
  `PAUSER_ROLE`, and `UNPAUSER_ROLE`.
- **Authority** — admin grants/revokes roles; `RECOVERY_ROLE` gates
  amount-bounded token rescue, `PAUSER_ROLE` triggers `Pausable._pause`, and
  `UNPAUSER_ROLE` triggers `_unpause`. `whenNotPaused` gates every
  state-mutating external entrypoint
  (`src/BaseSettler.sol`: open `:243-244`, openFor `:254`, fill `:279-280`,
  reclaim `:301`, markExpired `:334-335`, cancel `:354-355`).
- **Provenance** — constructor grants `DEFAULT_ADMIN_ROLE` and
  `RECOVERY_ROLE` to `admin_`, `PAUSER_ROLE` to `pauser_`, and
  `UNPAUSER_ROLE` to `unpauser_`
  (`src/BaseSettler.sol`). Split-key custody is operational; the contract
  does not prescribe distinct holders.

### 1.6a Settler owner (OZ `Ownable` ENS identity)

- **Identity binding** — OZ `Ownable.owner()` on the Settler, initialized from
  constructor `ensOwner_`.
- **Authority** — ownership transfer and renounce only. Bounded token rescue,
  pause, unpause, and role administration remain AccessControl-gated.
- **Provenance** — mirrors Phoenix `ensOwner` wiring as a deployment identity;
  `transferOwnership` / `renounceOwnership` follow OZ default semantics and do
  not grant or revoke Settler roles.

### 1.7 cPT holder (per CWIA clone)

- **Identity binding** — CWIA trailer byte 0..20 of the rolloverContract clone, read
  on every call by `_owner()` (`src/CorkRolloverContract.sol:1180-1182`).
- **Authority** — `onlyOwner` modifier (`src/CorkRolloverContract.sol:223-228`).
- **Provenance** — `msg.sender` of `CorkRolloverContractFactory.deployRolloverContract`
  (`src/CorkRolloverContractFactory.sol:283`); encoded into clone trailer via
  deterministic `Clones.cloneDeterministicWithImmutableArgs`. The address is
  predictable before deployment with `predictRolloverContractOf(owner)`, subject
  to identical factory, implementation, owner, and registry inputs. One rolloverContract
  per cPT holder (`CorkRolloverContractFactory__AlreadyDeployed`, check at
  `src/CorkRolloverContractFactory.sol`).
- **Note** — cPT holder is implemented as the clone `owner`. Older notes may say cPT holder. The rollover contract has NO separate admin role.

### 1.8 Factory admin and operational roles (OZ AccessControl)

- **Identity binding** — OZ `AccessControl.hasRole(role, account)`
  on `CorkRolloverContractFactory`.
- **Authority** — `DEFAULT_ADMIN_ROLE` administers roles.
  `SETTLER_APPROVER_ROLE` gates `approveSettler`,
  `SETTLER_REVOKER_ROLE` gates `revokeSettler`, and
  `DEFAULTS_MANAGER_ROLE` gates `setDefaults`.
- **Provenance** — constructor grants all four roles to `initialAdmin_`.
  Later delegation uses plain `grantRole` / `revokeRole`; self-renunciation
  follows inherited OZ `AccessControl` self-renounce semantics.

### 1.8a Factory owner (Phoenix-style ENS identity)

- **Identity binding** — OZ `Ownable.owner()` on `CorkRolloverContractFactory`,
  initialized from constructor `ensOwner_`.
- **Authority** — ownership transfer and renounce only. Settler allowlist,
  defaults scheduling, and admin-role transfer remain role-gated.
- **Provenance** — mirrors Phoenix `ensOwner` wiring; `renounceOwnership`
  follows OZ default and clears only the owner identity.

### 1.9 RolloverContract pending admin (transfer-acceptor) — none

RolloverContract does NOT inherit role admin machinery. There is no separate "pending owner" on the
rolloverContract; CWIA trailer is immutable per clone, so cPT holdership is
non-transferable by construction (`src/CorkRolloverContract.sol:1166-1177`).

### 1.10 Permissionless / arbitrary EOA

Anyone with gas. Distinguished from "cPT holder" / "filler" / "relayer" when
the gate is purely a time-lock crank or a view.

### 1.11 Cross-chain executor

The current deployment is single-chain. `Settler._validateOrderCommon`
hard-asserts both chain identifiers equal `block.chainid`
(`src/ExactSettler.sol and src/PartialSettler.sol`, reverting `Settler__WrongOriginChain` /
`Settler__WrongDestinationChain`). There is no on-chain cross-chain executor
role today; the ERC-7683 envelope is plumbed through for interface compliance
only. Listed in §2 with **✗** on every row.

---

## 2. Privilege matrix

The matrix is sliced by deployment unit. Function rows; actor columns. Each
cell is `✓` / `✗` / `⊕(gate)`.

Column shorthand:

| Col | Actor (from §1) |
|---|---|
| **U** | User EOA / Safe (cPT holder, §1.1) |
| **R** | Relayer / opener (§1.2) |
| **F** | Filler EOA / Safe (§1.3) |
| **DE** | Delegated executor (§1.4) |
| **AS** | Approved Settler (§1.5) |
| **SO** | Settler admin / pauser / unpauser (§1.6) |
| **CPT** | cPT holder (§1.7) |
| **FA** | Factory admin (§1.8) |
| **BA**, **BM**, **BG** | Reserved placeholder columns; read as `✗` on every row. |
| **AE** | Arbitrary EOA (§1.10) |
| **CC** | Cross-chain executor (§1.11) |

### 2.1 Settler (`src/ExactSettler.sol and src/PartialSettler.sol`)

**Source:** `src/ExactSettler.sol and src/PartialSettler.sol` (shared base declaration:
`BaseSettler is ISettler, ISettlerAdmin, EIP712, AccessControl, Ownable, Pausable, ReentrancyGuardTransient`).
**Role family:** OZ `AccessControl` (`DEFAULT_ADMIN_ROLE` / `RECOVERY_ROLE` /
`PAUSER_ROLE` / `UNPAUSER_ROLE`) + OZ `Ownable.owner()` identity + OZ
`Pausable` + OZ `ReentrancyGuardTransient`.

| Function | U | R | F | DE | AS | SO | CPT | FA | BA | BM | BG | AE | CC | Gate / notes | Src |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `open(OnchainCrossChainOrder)` | ✓ | ✗ | ✗ | ✗ | ✗ | ✗ | ✓ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | `whenNotPaused nonReentrant`. Caller must equal `orderData.user`; no signature parameter. Shares `_validateOrderCommon` envelope/payload/chain/economics/rolloverContract/pool-expiry gates with gasless admission. | `src/ExactSettler.sol and src/PartialSettler.sol` |
| `openFor(GaslessCrossChainOrder, bytes, bytes)` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ | `whenNotPaused nonReentrant`. `_validateOrderCommon` runs the envelope/payload/chain/economics/rolloverContract/pool-expiry/exclusive-filler-self-DoS family; only user sig binds; `originFillerData` ignored. Permissionless to submit. | `src/ExactSettler.sol and src/PartialSettler.sol` |
| `fill(bytes32, bytes, bytes)` | ⊕ | ⊕ | ⊕(INV-FILLER-AUTH) | ⊕(`fillerAuthSig` over `(orderDigest, destination, subFiller)`) | ⊕ | ⊕ | ⊕ | ⊕ | ⊕ | ⊕ | ⊕ | ⊕ | ✗ | `whenNotPaused nonReentrant`. `LibFillerAuth.isAuthorised` invoked at `src/ExactSettler.sol and src/PartialSettler.sol` (helper at `src/libraries/LibFillerAuth.sol:91`): `(a) exclusiveFiller == 0` ⇒ any caller; `(b) msg.sender == exclusiveFiller` direct; `(c) EIP-712 sig by exclusiveFiller`. | `src/ExactSettler.sol and src/PartialSettler.sol`; helper `src/libraries/LibFillerAuth.sol:91` |
| `reclaim(bytes32, address, bytes32, bytes)` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ | `whenNotPaused nonReentrant`. Permissionless; async-only (`premiumPaymentMode == 1`), gated on order status AND `block.timestamp > fillDeadline`. Routes residual to `orderData.rolloverContract` only. | `src/ExactSettler.sol and src/PartialSettler.sol` |
| `markExpired(bytes32, bytes)` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ | `whenNotPaused nonReentrant`. Permissionless FSM flip for `Opened` / `Closing` orders after `fillDeadline`. | `src/BaseSettler.sol:332-349` |
| `cancel(bytes32, bytes, bytes)` | ⊕(cPT holder sig) | ⊕(cPT holder sig) | ⊕(cPT holder sig) | ⊕(cPT holder sig) | ⊕(cPT holder sig) | ⊕(cPT holder sig) | ⊕(cPT holder sig) | ⊕(cPT holder sig) | ⊕(cPT holder sig) | ⊕(cPT holder sig) | ⊕(cPT holder sig) | ⊕(cPT holder sig) | ✗ | `whenNotPaused nonReentrant`. Anyone may submit; `SignatureChecker.isValidSignatureNow(orderData.user, cancelDigest, cptHolderSig)` at `src/BaseSettler.sol:367`. The cPT-holder signature is the gate. | `src/ExactSettler.sol and src/PartialSettler.sol` |
| `pause()` | ✗ | ✗ | ✗ | ✗ | ✗ | ⊕(`onlyRole(PAUSER_ROLE)`) | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | OZ `Pausable._pause`. Halts every state-mutating Settler entrypoint. | `src/ExactSettler.sol and src/PartialSettler.sol` |
| `unpause()` | ✗ | ✗ | ✗ | ✗ | ✗ | ⊕(`onlyRole(UNPAUSER_ROLE)`) | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | OZ `Pausable._unpause`. Split role from pauser. | `src/ExactSettler.sol and src/PartialSettler.sol` |
| `grantRole / revokeRole` | ✗ | ✗ | ✗ | ✗ | ✗ | ⊕(`onlyRole(DEFAULT_ADMIN_ROLE)`) | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | Standard OZ `AccessControl`. Constructor grants `DEFAULT_ADMIN_ROLE` to `admin_`. | `src/ExactSettler.sol and src/PartialSettler.sol` |
| `dstCstLiabilityOf` / `recoverableTokenBalance` | ✓(view only) | ✓(view only) | ✓(view only) | ✓(view only) | ✓(view only) | ✓(view only) | ✓(view only) | ✓(view only) | ✓(view only) | ✓(view only) | ✓(view only) | ✓(view only) | ✗ | Liability / recoverable-balance views. `recoverableTokenBalance` reverts if token balance is below tracked dstCST liability. | `src/BaseSettler.sol` |
| `recoverToken` | ✗ | ✗ | ✗ | ✗ | ✗ | ⊕(`onlyRole(RECOVERY_ROLE)`) | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | Recovery-role ERC-20 rescue. Amount-bounded and cannot recover tracked dstCST liability. | `src/BaseSettler.sol` |
| `owner()` | ✓(view only) | ✓(view only) | ✓(view only) | ✓(view only) | ✓(view only) | ✓(view only) | ✓(view only) | ✓(view only) | ✓(view only) | ✓(view only) | ✓(view only) | ✓(view only) | ✓(view only) | ✗ | OZ `Ownable` deployment identity view; does not gate protocol actions. | `src/BaseSettler.sol` |
| `transferOwnership(address)` / `renounceOwnership()` | ✗ | ✗ | ✗ | ✗ | ✗ | ⊕(`onlyOwner`) | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | OZ `Ownable`; moves or clears only the owner identity and does not grant/revoke AccessControl roles. | `src/BaseSettler.sol` |

### 2.2 CorkRolloverContractFactory (`src/CorkRolloverContractFactory.sol`)

**Source:** `src/CorkRolloverContractFactory.sol:1` (declaration: `CorkRolloverContractFactory is
Ownable, AccessControl, ICorkRolloverContractFactory, IRolloverContractLens`).
**Role family:** OZ `AccessControl` (`DEFAULT_ADMIN_ROLE`,
`SETTLER_APPROVER_ROLE`, `SETTLER_REVOKER_ROLE`, `DEFAULTS_MANAGER_ROLE`) +
CWIA factory + transient origin-settler latch (`_originatingSettler`).

| Function | U | R | F | DE | AS | SO | CPT | FA | BA | BM | BG | AE | CC | Gate / notes | Src |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `deployRolloverContract()` | ⊕(CWIA-NEW) | ⊕(CWIA-NEW) | ⊕(CWIA-NEW) | ⊕(CWIA-NEW) | ⊕(CWIA-NEW) | ⊕(CWIA-NEW) | ⊕(CWIA-NEW) | ⊕(CWIA-NEW) | ⊕(CWIA-NEW) | ⊕(CWIA-NEW) | ⊕(CWIA-NEW) | ⊕(CWIA-NEW) | ✗ | `nonReentrant`. Permissionless except one-rolloverContract-per-caller (`rolloverContractOf[owner] == 0`, revert `CorkRolloverContractFactory__AlreadyDeployed`). Deploys the address predicted by `predictRolloverContractOf(owner)`. | `src/CorkRolloverContractFactory.sol` |
| `executeIntentHooks(...)` | ✗ | ✗ | ✗ | ✗ | ⊕(phase + allowlist + non-zero digest + origin binding + rolloverContract set + origin latch) | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | `nonReentrant`. Composed gates: `approvedSettlers[msg.sender]` (`INV-SETTLER-APPROVED`), origin-settler cross-check (`ctx.originSettler == msg.sender`, revert `__SettlerNotOriginSettler`), known-rolloverContract set (`isDeployedRolloverContract[rolloverContract]`, revert `__UnknownRolloverContract`), and settler-latch provenance (`_originatingSettler` set before the rolloverContract call and cleared after return; `nonReentrant` blocks nested factory dispatch; `__SettlerLatchMismatch` defensive). Sole reachable caller is an approved Settler. | `src/CorkRolloverContractFactory.sol:311` |
| `approveSettler(address)` | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ⊕(`nonReentrant onlyRole(SETTLER_APPROVER_ROLE)`, non-zero code address) | ✗ | ✗ | ✗ | ✗ | ✗ | Default-deny allowlist toggle. Idempotent; emits even when already approved; does not verify a Settler interface. | `src/CorkRolloverContractFactory.sol:354` |
| `revokeSettler(address)` | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ⊕(`nonReentrant onlyRole(SETTLER_REVOKER_ROLE)`) | ✗ | ✗ | ✗ | ✗ | ✗ | Idempotent instant kill-switch for FUTURE factory and rolloverContract dispatches, including zero/no-code targets. PREMIUM specifically: factory policy-gate reverts (e.g. `__SettlerNotApproved`) propagate through the atomic-fill frame and roll back the entire transaction (no partial latch commit). Does NOT halt a filler with already-pulled srcCST mid-`fill` past the factory gate — use `Settler.pause()` for that. | `src/CorkRolloverContractFactory.sol:368` |
| `grantRole` / `revokeRole` | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ⊕(`DEFAULT_ADMIN_ROLE` admin) | ✗ | ✗ | ✗ | ✗ | ✗ | Plain OZ `AccessControl` admin rotation. | inherited |
| `owner()` / `transferOwnership(address)` / `renounceOwnership()` (Factory) | ✓(view only) | ✓(view only) | ✓(view only) | ✓(view only) | ✓(view only) | ✓(view only) | ✓(view only) | ✓(view only) | ✓(view only) | ✓(view only) | ✓(view only) | ✓(view only) | ✗ | OZ `Ownable`; owner identity can transfer or renounce but does not gate protocol actions. | inherited via `src/CorkRolloverContractFactory.sol` |
| `renounceRole(bytes32, address)` | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ⊕(self only) | ✗ | ✗ | ✗ | ✗ | ✗ | Inherited OZ `AccessControl`; self-renounce allowed for all roles including `DEFAULT_ADMIN_ROLE`. | inherited |
| `queueFactoryDefaultTrustConfig()` | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ⊕(`rolloverContractOf[msg.sender]` deployed factory-rolloverContract + current defaults snapshot) | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | Safe/default owner path for the caller's own deployed rolloverContract. Snapshots current factory defaults, then schedules the same `(salt, threshold, attesters)` op on the external per-rollover-contract trust-config `TimelockController` with its configured delay. Later `setDefaults` changes do not mutate the queued config. Re-queue cancels any prior pending op and resets the clock. Mirrors into `pendingConfig[salt]` / `lastSalt[rolloverContract]`. | `src/CorkRolloverContractFactory.sol` |
| `queueTrustConfig(uint8, address[])` | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ⊕(`rolloverContractOf[msg.sender]` deployed factory-rolloverContract + `_validateTrustConfig`) | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | Advanced/custom owner path for the caller's own deployed rolloverContract. Schedules caller-supplied `(salt, threshold, attesters)` on the external per-rollover-contract trust-config `TimelockController` with its configured delay. Re-queue cancels any prior pending op and resets the clock. Mirrors into `pendingConfig[salt]` / `lastSalt[rolloverContract]`. | `src/CorkRolloverContractFactory.sol` |
| `applyTrustConfig(address rolloverContract)` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ | Permissionless crank. Loads salt/threshold/attesters from the pending mirror. Reverts `__NoQueuedTrustConfig` and `TimelockController.TimelockUnexpectedOperationState` while the delay has not elapsed. Routes through `relayTrustConfig` → `ICorkRolloverContract.setTrustConfig` with the exact queued op id temporarily authorized. | `src/CorkRolloverContractFactory.sol` |
| `cancelTrustConfig()` | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ⊕(`rolloverContractOf[msg.sender]` deployed factory-rolloverContract + `__NoQueuedTrustConfig`) | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | cPT-holder abort path for the caller's own deployed rolloverContract. Cancels the pending timelock op and clears the factory mirror in a single tx. | `src/CorkRolloverContractFactory.sol` |
| `relayTrustConfig(address rolloverContract, bytes32 salt, uint8, address[])` | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | Trust-config timelock callback only. Requires `msg.sender == trustConfigTimelock`, a factory-deployed rolloverContract, an existing pending mirror, supplied salt/threshold/attesters matching that mirror, and the exact op id authorized by `applyTrustConfig` before calling `ICorkRolloverContract(rolloverContract).setTrustConfig`. Direct, stale, or mismatched calls revert. | `src/CorkRolloverContractFactory.sol` |
| `pendingTrustConfig(address rolloverContract)` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ | View. Returns `(threshold, attesters, effectiveAt)` where threshold/attesters come from the Factory pending mirror and `effectiveAt` comes from the timelock op timestamp; `(0, [], 0)` means no Factory mirror exists. | `src/CorkRolloverContractFactory.sol:648-667` |

### 2.3 CorkRolloverContract (`src/CorkRolloverContract.sol`)

**Source:** `src/CorkRolloverContract.sol:1` (declaration: `CorkRolloverContract is Initializable,
ICorkRolloverContract`).
**Role family:** CWIA clone (owner = trailer byte 0..20; factory = trailer
byte 20..40) + OZ `Initializable` (single-shot) + OZ
`ReentrancyGuardTransient` + ERC-7484 attestation registry.

| Function | U | R | F | DE | AS | SO | CPT | FA | BA | BM | BG | AE | CC | Gate / notes | Src |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `initialize(uint8 initialTrustThreshold, address[] calldata initialTrustAttesters)` | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | `nonReentrant onlyFactory initializer` (modifier order pinned by OZ CWIA-migration: `onlyFactory` MUST precede `initializer`, `:255-259`). Only `CorkRolloverContractFactory.deployRolloverContract` reaches this. The registry is CWIA-immutable (trailer bytes 40-60, read via `_registry()`), not a parameter. Seeds factory-baked default attesters into the rolloverContract's smart-account record via `IERC7484.trustAttesters` at `:274`. | `src/CorkRolloverContract.sol:255-277` |
| `executeIntentHooks(bytes32, uint8, RolloverIntent, bytes, FillContext, OrderData)` | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | `nonReentrant onlyFactory`. Only the deploying factory reaches this; envelope, intent dual-bind (`_validateIntentHashBinding`), owner signature (`_ensureOwnerAuthorized`), and signed settler pin (`orderData.rolloverParams.settler == ctx.originSettler`) run before phase dispatch. | `src/CorkRolloverContract.sol` |
| `withdraw(address, uint256)` | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ⊕(`nonReentrant onlyOwner`) | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | CWIA owner only. | `src/CorkRolloverContract.sol:315-322` |
| `setTrustConfig(uint8, address[])` | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | `nonReentrant onlyFactory` (`src/CorkRolloverContract.sol:351-355`); reachable only via `CorkRolloverContractFactory.applyTrustConfig` → `TimelockController.execute` → `relayTrustConfig`. Forwards to `IERC7484.trustAttesters` at `:362`. | `src/CorkRolloverContract.sol:351-363` |

### 2.4 BaseFiller (`src/BaseFiller.sol`)

**Source:** `src/BaseFiller.sol:1` (standalone non-EVC filler orchestration).
**Role family:** OZ `ReentrancyGuardTransient`; no AccessControl, no owner.

| Function | U | R | F | DE | AS | SO | CPT | FA | BA | BM | BG | AE | CC | Gate / notes | Src |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `execute(FillerJob)` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ | `nonReentrant`. Permissionless except zero-settler check + `_assertExpectedSettler(settler, job.settler)` cross-check (`:106`) against `allowPartialFills ? PARTIAL_SETTLER : EXACT_SETTLER` (the two immutables at `:32` / `:36`). Caller (`msg.sender`) pays srcCST + premium upfront. Downstream `Settler.fill` re-enforces `INV-FILLER-AUTH` when the order names an exclusive filler. Emits `PremiumRefunded` when `requiredPremium < job.premiumCap`. | `src/BaseFiller.sol:102` |

### 2.5 EvcRolloverAdapter (`src/EvcRolloverAdapter.sol`) — adapter context only

Out of audit scope unless explicitly re-added in `SCOPE.md`. The rows below
are retained only so supplementary spec readers understand why EVC / Permit2 terms
appear elsewhere in the repository.

**Source:** `src/EvcRolloverAdapter.sol:1`.
**Role family:** OZ `ReentrancyGuardTransient` + EVC context gate
(`getCurrentOnBehalfOfAccount` + controller-enabled subaccount check). No
AccessControl, no owner.

| Function | U | R | F | DE | AS | SO | CPT | FA | BA | BM | BG | AE | CC | Gate / notes | Src |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `execute(EvcRolloverJob)` | ⊕(EVC ctx) | ⊕(EVC ctx) | ⊕(EVC ctx) | ⊕(EVC ctx) | ⊕(EVC ctx) | ⊕(EVC ctx) | ⊕(EVC ctx) | ⊕(EVC ctx) | ⊕(EVC ctx) | ⊕(EVC ctx) | ⊕(EVC ctx) | ⊕(EVC ctx) | ✗ | `nonReentrant`. `_gateEvc(subaccount)`: `EVC.getCurrentOnBehalfOfAccount(CONTROLLER)` must return non-zero and match `job.subaccount`. `job.fundingAccount` must equal `EVC.getAccountOwner(job.subaccount)` and signs the Permit2 witness. Caller per se is unbound. | `src/EvcRolloverAdapter.sol` |
| `executePartial(EvcRolloverJob)` | ⊕(EVC ctx) | ⊕(EVC ctx) | ⊕(EVC ctx) | ⊕(EVC ctx) | ⊕(EVC ctx) | ⊕(EVC ctx) | ⊕(EVC ctx) | ⊕(EVC ctx) | ⊕(EVC ctx) | ⊕(EVC ctx) | ⊕(EVC ctx) | ⊕(EVC ctx) | ✗ | `nonReentrant`. Same gate as `execute`; dispatches a single atomic envelope, then `_refundTails` returns residuals to the EVC subaccount. | `src/EvcRolloverAdapter.sol:277` |

### 2.6 Modules (`src/modules/*`)

The reference/current modules (`PreRolloverReferenceModule`,
`MidRolloverReferenceModule`, `PostRolloverReferenceModule`, `ApproveModule`,
`OwnerTokenPullModule`, `ScopedSplitModule`, `ScopedTransferModule`) are stateless and intended for
**delegatecall only** from the rolloverContract. Each inherits `OnlyDelegatecall`, so direct
calls to the deployed module address revert `OnlyDelegatecall__DirectCallForbidden`
before any token-touching logic runs. The operative authority is always "whoever
delegatecalls into them from within a rolloverContract hook bucket". The relevant gate
composition lives upstream in `CorkRolloverContract._prevalidateIntentCalls` (per-batch
ERC-7484 attestation gate `check(target, moduleType, attesters, threshold)` —
registry read via `_registry()` — call site `src/CorkRolloverContract.sol:1061`).

| Module surface (any external fn, delegatecalled from rolloverContract only) | All §1 actors | Gate / notes | Src |
|---|---|---|---|
| any of `PreRolloverReferenceModule.*`, `MidRolloverReferenceModule.*`, `PostRolloverReferenceModule.*`, `ApproveModule.*`, `OwnerTokenPullModule.*`, `ScopedSplitModule.*`, `ScopedTransferModule.*` | direct calls revert via `OnlyDelegatecall__DirectCallForbidden`; operate only under rolloverContract `delegatecall` context. Removed full-balance modules are not new-order premium templates. | `OnlyDelegatecall` modifier on every module + per-batch ERC-7484 attestation gate. | `src/modules/*.sol` |

### 2.7 Phoenix integration (`src/interfaces/external/phoenix/*`)

This repo does NOT define `IPoolShare` / `IPoolManager` implementations.
Those live in Cork Phoenix (https://github.com/cork-technology/phoenix);
this repo only owns the read-side **caller** surface. Settler reads `poolId()` and `expiry()` on
`IPoolShare` at order open; rolloverContract consumes `unwindMint`, `deposit`, `shares`,
`market`, `poolManager` between rollover hook batches. No row in this matrix
for IPoolShare / IPoolManager — they are off-this-repo callees.

### 2.8 Interfaces & libraries

Interfaces declare the ABI surface implemented by other units in this matrix
(Settler / Factory / RolloverContract / Modules). Libraries (`LibSettlerHashing`,
`LibRolloverOrder`, `LibHookPhase`, `LibAuthenticatedHooks`, `LibFillerAuth`,
`Typehashes`) are `internal`-only pure / view helpers and have no external
entry points. Both are out-of-scope for this matrix.

---

## 3. Cross-cutting roles

Role identifiers and where they're granted/checked.

| Role | Where declared | Where granted | Where checked | Notes |
|---|---|---|---|---|
| `owner()` (Settler) | OZ `Ownable` | `Ownable(ensOwner_)` at `src/BaseSettler.sol` | `transferOwnership` / `renounceOwnership` only | Phoenix-style ENS/deployment identity; not a protocol permission and distinct from AccessControl roles. |
| `DEFAULT_ADMIN_ROLE` (Settler) | OZ `AccessControl` constant | `_grantRole(DEFAULT_ADMIN_ROLE, admin_)` at `src/BaseSettler.sol` | `Settler.grantRole` / `revokeRole` (inherited) | Granted to constructor `admin_`; administers roles only. |
| `RECOVERY_ROLE` (Settler) | `src/BaseSettler.sol` (`keccak256("RECOVERY_ROLE")`) | `_grantRole(RECOVERY_ROLE, admin_)` at `src/BaseSettler.sol` | `Settler.recoverToken` | Granted to constructor `admin_`; bounded token rescue authority. |
| `PAUSER_ROLE` (Settler) | `src/ExactSettler.sol and src/PartialSettler.sol` (`keccak256("PAUSER_ROLE")`) | `_grantRole(PAUSER_ROLE, pauser_)` at `src/BaseSettler.sol` | `Settler.pause` at `:380` | Split-key custody intended; not contract-enforced. |
| `UNPAUSER_ROLE` (Settler) | `src/ExactSettler.sol and src/PartialSettler.sol` (`keccak256("UNPAUSER_ROLE")`) | `_grantRole(UNPAUSER_ROLE, unpauser_)` at `src/BaseSettler.sol` | `Settler.unpause` at `:389` | Held by a separate key from `PAUSER_ROLE` so recovery is not coercible from a single compromised key. |
| `owner()` (Factory) | OZ `Ownable` | `Ownable(ensOwner_)` at `src/CorkRolloverContractFactory.sol` | `transferOwnership` / `renounceOwnership` only | Phoenix-style ENS/deployment identity; not a protocol permission. |
| `DEFAULT_ADMIN_ROLE` (Factory) | OZ `AccessControl` | constructor `factoryAdmin_` (`_grantRole(DEFAULT_ADMIN_ROLE, factoryAdmin_)`) | role admin, `renounceRole` | Inherited OZ role semantics; rotation uses `grantRole` / `revokeRole`, self-renounce is allowed. |
| `SETTLER_APPROVER_ROLE` (Factory) | `src/CorkRolloverContractFactory.sol` (`keccak256("SETTLER_APPROVER_ROLE")`) | constructor `settlerApprover_` | `approveSettler` | Dedicated expansionary allowlist role; production deployments typically assign this to delayed/admin governance. |
| `SETTLER_REVOKER_ROLE` (Factory) | `src/CorkRolloverContractFactory.sol` (`keccak256("SETTLER_REVOKER_ROLE")`) | constructor `settlerRevoker_` | `revokeSettler` | Dedicated instant kill-switch role; production deployments may assign this to a fast guardian/emergency authority. |
| `DEFAULTS_MANAGER_ROLE` (Factory) | `src/CorkRolloverContractFactory.sol` (`keccak256("DEFAULTS_MANAGER_ROLE")`) | constructor `defaultsManager_` | `setDefaults` | Dedicated factory-defaults rotation role; assign to external governance/timelock if delay is desired. |

---

## 4. Gating taxonomy

Every gate primitive used in §2, with the source pointer to its definition site.

### 4.1 Inheritance modifiers (OpenZeppelin)

| Primitive | Source | Used by |
|---|---|---|
| `nonReentrant` (transient, EIP-1153) | OZ `ReentrancyGuardTransient` | `Settler` state-mutating entrypoints in `src/BaseSettler.sol`: open `:243-244`, openFor `:254`, fill `:279-280`, reclaim `:301`, markExpired `:334-335`, cancel `:354-355`, plus `recoverToken` `:194` (nonReentrant-only, no `whenNotPaused`); `CorkRolloverContractFactory.{deployRolloverContract, executeIntentHooks, approveSettler, revokeSettler}` (`:283, 310, 354, 368`); `CorkRolloverContract.{initialize, executeIntentHooks, withdraw, setTrustConfig}` (`:255, 285, 315, 351`); `BaseFiller.execute` (`:102`). Adapter context only: `EvcRolloverAdapter.{execute, executePartial}` (`:246, 277`) is out of audit scope unless explicitly re-added in `SCOPE.md`. |
| `onlyRole(role)` (OZ `AccessControl`) | OZ `AccessControl._checkRole` | `CorkRolloverContractFactory` role-admin and operational paths (`DEFAULT_ADMIN_ROLE`, `SETTLER_APPROVER_ROLE`, `SETTLER_REVOKER_ROLE`, `DEFAULTS_MANAGER_ROLE`); `Settler` role administration, rescue, pause, and unpause (`RECOVERY_ROLE`, `PAUSER_ROLE`, `UNPAUSER_ROLE`) |
| `whenNotPaused` (OZ `Pausable`) | OZ `Pausable._requireNotPaused` | `Settler.{open, openFor, fill, reclaim, markExpired, cancel}` (`src/BaseSettler.sol`) |
| `initializer` (OZ `Initializable`, single-shot) | OZ `Initializable._initializableState` | `CorkRolloverContract.initialize` (with modifier order `onlyFactory` BEFORE `initializer` per OZ-migration constraint, `src/CorkRolloverContract.sol:454`) |

### 4.2 RolloverContract-local modifiers

| Primitive | Source | Semantics |
|---|---|---|
| `onlyFactory` | `src/CorkRolloverContract.sol:231-236` | Reads CWIA trailer byte 20..40 via `_factory()` (`:1185-1187`); reverts `CorkRolloverContract__NotFactory` if `msg.sender != _factory()`. Used on `initialize`, `executeIntentHooks`, `setTrustConfig`. |
| `onlyOwner` (rolloverContract) | `src/CorkRolloverContract.sol:223-228` | Reads CWIA trailer byte 0..20 via `_owner()` (`:1180-1182`); reverts `CorkRolloverContract__NotOwner`. Used on `withdraw`. (Trust-config changes flow through the factory's `setTrustConfig` gate, not `onlyOwner`.) |

### 4.3 Allowlist / set-membership gates

| Primitive | Storage / source | Semantics |
|---|---|---|
| Settler allowlist (`INV-SETTLER-APPROVED`) | `CorkRolloverContractFactory.FactoryStorage.approvedSettlers` (`src/CorkRolloverContractFactory.sol:141`); check at `:330` (helper `:982-984`) | Default-deny mapping. `__SettlerNotApproved` revert if `msg.sender` not present. Managed by `SETTLER_APPROVER_ROLE` / `SETTLER_REVOKER_ROLE`; instant `revokeSettler` kill-switch for future factory + rolloverContract dispatches. Under PR87 atomic-fill the revert propagates through `fill` and rolls back the whole transaction (admit / rollover / premium state). |
| Known-rolloverContract set | `CorkRolloverContractFactory.FactoryStorage.isDeployedRolloverContract` (`src/CorkRolloverContractFactory.sol:142`); check at `:336` | Pin set written by `deployRolloverContract`. `__UnknownRolloverContract(rolloverContract)` revert. |
| Per-cPT-holder uniqueness | `CorkRolloverContractFactory.FactoryStorage.rolloverContractOf` (`src/CorkRolloverContractFactory.sol:143`); check at `:287-288` | Reverts `__AlreadyDeployed(user)` if non-zero. |

### 4.4 Transient latches (EIP-1153)

| Primitive | Storage | Semantics |
|---|---|---|
| Settler latch provenance (`_originatingSettler`) | `transient` at `src/CorkRolloverContractFactory.sol:162`; set at `:342`, cleared at `:349` | Active only during each factory-to-rolloverContract dispatch call; mirrors `msg.sender` for rolloverContract `originatingSettler()` reads. Cleared after return; reverts after the latch write roll back the transient write. Sequential mixed-settler batches allowed once cleared. `nonReentrant` is the practical nested-dispatch guard; `__SettlerLatchMismatch` is defensive. |
| Origin-settler cross-check | inline equality `src/CorkRolloverContractFactory.sol:332-334` | `ctx.originSettler == msg.sender` else `__SettlerNotOriginSettler`. |
| `Settler nonReentrant` | OZ `ReentrancyGuardTransient` | Prevents rolloverContract-callback re-entry into `Settler.fill`. |

### 4.5 Signature-recovery gates

| Primitive | Source | Authority |
|---|---|---|
| User OrderData sig | `SignatureChecker.isValidSignatureNow(user, orderDigest, signature)` at `src/ExactSettler.sol and src/PartialSettler.sol` | EIP-712 / ERC-1271 over `OrderData` typehash. |
| Cancel sig | `SignatureChecker.isValidSignatureNow(orderData.user, cancelDigest, cptHolderSig)` at `src/ExactSettler.sol and src/PartialSettler.sol`; typehash `LibSettlerHashing.hashCancelOrder` | EIP-712 / ERC-1271 over `CancelOrder`. |
| FillerAuth sig (`INV-FILLER-AUTH`) | `LibFillerAuth.isAuthorised` invoked at `src/ExactSettler.sol and src/PartialSettler.sol` (helper at `src/libraries/LibFillerAuth.sol:91`); typehash `FILLER_AUTH_TYPEHASH` at `src/libraries/Typehashes.sol:39` | EIP-712 / ERC-1271 by `exclusiveFiller` over `FillerAuth(orderDigest, destination, subFiller)`. Three-branch: open / direct-call / sig. |
| Rollover intent authorization (`INV-ROLLOVER_CONTRACT-CPT-HOLDER-SIG-EVERY-DISPATCH`) | `_ensureOwnerAuthorized` at `src/CorkRolloverContract.sol`; every dispatch uses `SignatureChecker.isValidSignatureNow(_owner(), orderDigest, cptHolderSig)` and writes no authorization state | EIP-712 / ERC-1271 cPT-holder signature over `OrderData` / `orderDigest`; signed `OrderData.rolloverIntentHash` commits the zero-digest `RolloverIntent` hash. Atomic ROLLOVER and PREMIUM may reuse the same signature bytes, but both are verified on-chain. |

### 4.6 EIP-712 / ERC-1271 plumbing

| Primitive | Domain | Source |
|---|---|---|
| Settler EIP-712 domain | `(CorkSettler, 1.0.0)` | constructor `src/ExactSettler.sol and src/PartialSettler.sol`, rebuilt on chainid drift via OZ `EIP712._domainSeparatorV4` |
| Rollover intent hash (`RolloverIntent`) | `ROLLOVER_INTENT_TYPEHASH` typehash only | typehashes in `src/libraries/Typehashes.sol`; hashed by `LibAuthenticatedHooks.intentStructHash` for `OrderData.rolloverIntentHash` binding |
| ERC-1271 fallthrough | OZ `SignatureChecker` | Used at user-sig, cancel-sig, FillerAuth-sig, and rolloverContract per-dispatch cPT-holder-sig sites |

### 4.7 Attestation (rolloverContract-side hot path)

| Primitive | Source | Semantics |
|---|---|---|
| ERC-7484 attestation gate | `IERC7484(_registry()).check(c.target, moduleType, attesters, threshold)` in `_prevalidateIntentCalls` at `src/CorkRolloverContract.sol:1061` | Wrapped revert: `CorkRolloverContract__ModuleTypeMismatch`. Per-batch (per-bucket) attestation by the rolloverContract's currently live attester set. Module types defined at `src/libraries/Typehashes.sol:16-26`. |
| Trust-config delay | Constructor-supplied external per-rollover-contract trust-config `TimelockController`; factory mirror in `pendingConfig` / `lastSalt` / `queueNonce`. | `INV-TRUST-CONFIG-DELAY`. cPT holder queues via safe/default `CorkRolloverContractFactory.queueFactoryDefaultTrustConfig()` or advanced/custom `queueTrustConfig(...)`; permissionless `applyTrustConfig` after the trust-config timelock delay routes through `relayTrustConfig` → `ICorkRolloverContract.setTrustConfig`. Re-queue cancels prior op. |

### 4.8 FSM / time gates

| Primitive | Source | Semantics |
|---|---|---|
| `orderStatus` FSM (`BS-ST-20`) | predicates `isHardTerminal` / `blocksRollover` in `src/types/SettlerTypes.sol` | Six-state FSM `{None, Opened, Settled, Expired, Cancelled, Closing}`; revert `Settler__OrderInTerminalState` at every state-mutating call. |
| Fill deadline | `block.timestamp <= fillDeadline` at `Settler.fill`; opposite gate `> fillDeadline` at `Settler.reclaim` / `Settler.markExpired`. | `Settler__FillAfterDeadline` / `Settler__ReclaimBeforeFillDeadline` / `Settler__MarkExpiredBeforeFillDeadline`. |
| Open deadline | rejects `openDeadline > fillDeadline` at `src/libraries/LibSettlerAdmission.sol:82-83`; chain-level open check elsewhere | `Settler__OpenDeadlineAfterFillDeadline`. |
| Factory defaults governance | `DEFAULTS_MANAGER_ROLE`; `setDefaults` is direct | External governance/timelock role holder supplies delay if desired. |

### 4.9 Chain / envelope gates

| Primitive | Source | Semantics |
|---|---|---|
| `originChainId == block.chainid` | `src/ExactSettler.sol and src/PartialSettler.sol` | `Settler__WrongOriginChain`. |
| `destinationChainId == block.chainid` | `src/ExactSettler.sol and src/PartialSettler.sol` | `Settler__WrongDestinationChain`. Currently single-chain only. |
| Envelope/payload equality (6 fields) | `src/ExactSettler.sol and src/PartialSettler.sol` | `originSettler / user / orderSalt / originChainId / openDeadline / fillDeadline` must equal between ERC-7683 envelope and signed payload (errors `__OriginSettlerMismatch`, `__UserMismatch`, `__OrderSaltMismatch`, `__OriginChainIdMismatch`, `__OpenDeadlineMismatch`, `__FillDeadlineMismatch`). The envelope's `GaslessCrossChainOrder.nonce` (ERC-7683 field) binds to the payload's `OrderData.orderSalt` (user-chosen salt, not consumed). |
| Payload self-binding | `orderData.settler == address(this)` at `:453` | Rejects payloads signed for another Settler (`Settler__SettlerMismatch`). |
| Exclusive-filler self-DoS | `orderData.exclusiveFiller != address(this)` at `:508` | Prevents routing the FillerAuth sig back into the Settler itself (`Settler__SelfExclusiveFiller`). |

### 4.10 EVC gate — adapter context only

Out of audit scope unless explicitly re-added in `SCOPE.md`.

| Primitive | Source | Semantics |
|---|---|---|
| `_gateEvc(subaccount)` | `src/EvcRolloverAdapter.sol:632-642` | `EVC.getCurrentOnBehalfOfAccount(CONTROLLER)` must be non-zero (`__NotEvcContext` at `:635`) AND match `job.subaccount` (`__OnBehalfMismatch` at `:641`). |

### 4.11 CWIA structural gates

| Primitive | Source | Semantics |
|---|---|---|
| cPT holder (`_owner`) | CWIA trailer byte 0..20 at `src/CorkRolloverContract.sol:1154-1156` | Immutable per clone. cPT holdership is non-transferable. |
| RolloverContract factory (`_factory`) | CWIA trailer byte 20..40 at `src/CorkRolloverContract.sol:1159-1161` | Immutable per clone. Only the deploying factory can call `initialize` / `executeIntentHooks` / `setTrustConfig`. |
| RolloverContract registry (`_registry`) | CWIA trailer byte 40..60 at `src/CorkRolloverContract.sol:1164-1166` | Immutable per clone — the ERC-7484 registry the rolloverContract consults at every hook batch and forwards `trustAttesters` to. No `sstore` vector for the registry pointer. |
| 60-byte trailer integrity | `CorkRolloverContractFactory._decodeCwiaArgs` reads first 40 bytes; rolloverContract-side full decode `CorkRolloverContract._cwiaImmutableArgs`; construction uses deterministic `Clones.cloneDeterministicWithImmutableArgs` | `abi.encodePacked(owner, address(this), registry)`. Prediction/deployment parity requires the same factory/deployer, implementation, owner, and registry. |

---

**Source tip:** all citations resolved against current `src/`.
