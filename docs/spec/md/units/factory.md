# Unit: CorkRolloverContractFactory

> _Supplementary protocol reference. The canonical bundle for AI auditors is [`docs/agent-context/`](../../../agent-context/README.md). Code in `src/` is the source of truth when docs disagree._

## Source

`src/CorkRolloverContractFactory.sol` (1019 lines).

Per-rolloverContract CWIA deployer + per-tx dispatch latch + managed defaults registry +
`IRolloverContractLens` aggregator. Stores live default attesters, threshold, and registry used for new
rolloverContracts; every freshly-deployed rolloverContract starts seeded with these defaults via
`IERC7484.trustAttesters`. cPT holders may update per rolloverContract via the external
per-rolloverContract trust-config `TimelockController`: the safe path calls
`CorkRolloverContractFactory.queueFactoryDefaultTrustConfig()` to snapshot the
current factory defaults, while the advanced path calls
`CorkRolloverContractFactory.queueTrustConfig(threshold, attesters)` with a custom
replacement config. Both paths wait the controller's `minDelay`, then anyone
calls `applyTrustConfig(rolloverContract)` which relays through `relayTrustConfig` into
the rolloverContract's factory-gated `setTrustConfig`. Defaults managers may rotate
defaults for future rolloverContracts with `setDefaults`; if delay is desired the role
should be held by external governance/timelock. Existing rolloverContracts keep their live
trust config until the per-rolloverContract path changes it; default-path queues snapshot
defaults at queue time and do not auto-follow later `setDefaults` changes. CWIA
trailer is 60 bytes
(`owner ‖ factory ‖ erc7484Registry`). Per-call PoolManager derivation moved into the rolloverContract; the
factory's hook-dispatch surface is exactly two arms — `ROLLOVER` and `PREMIUM`.

Source: `src/CorkRolloverContractFactory.sol:48-51` (`@notice`).

## Inheritance

- `ICorkRolloverContractFactory` — `src/CorkRolloverContractFactory.sol:78`
- `IRolloverContractLens` — `src/CorkRolloverContractFactory.sol:82`
- `Ownable` (OZ) — Phoenix-style deployment owner identity only.
- `AccessControl` (OZ) — protocol admin authority, matching Settler.
- `ReentrancyGuardTransient` (OZ) — `src/CorkRolloverContractFactory.sol:85`

## Storage

### ERC-7201 namespaced storage

Namespace `erc7201:cork.factory.storage.v3`. Root slot constant `FACTORY_STORAGE_SLOT =
0x33e161bf0309d8211c87f71dbb3e2f85e82ce7cff87a5e8b28dd7396ad330700` declared in
`src/CorkRolloverContractFactory.sol`; accessed via `_s()`. `struct FactoryStorage` declared in
`src/CorkRolloverContractFactory.sol`.

| Slot / Symbol | Type | Purpose | Write sites |
|---------------|------|---------|-------------|
| `approvedSettlers` | `mapping(address => bool)` | Default-deny settler allowlist ([[INV-SETTLER-APPROVED]]) | `src/CorkRolloverContractFactory.sol:141`, written by `approveSettler` / `revokeSettler` |
| `isDeployedRolloverContract` | `mapping(address => bool)` | Pin set of factory-deployed rolloverContracts | `src/CorkRolloverContractFactory.sol:142`, written by `deployRolloverContract` |
| `rolloverContractOf` | `mapping(address => address)` | cPT holder → rolloverContract one-per-owner registry | `src/CorkRolloverContractFactory.sol:143`, written by `deployRolloverContract` |
| `lastSalt` | `mapping(address rolloverContract => bytes32 salt)` | Per-rolloverContract handle for the Factory pending trust-config mirror. `bytes32(0)` = no Factory mirror. A nonzero salt can remain after direct external timelock cancellation; `pendingTrustConfig` then reports the mirror with `effectiveAt == 0`. Backs `INV-PENDING-MIRRORS-TIMELOCK`. | `src/CorkRolloverContractFactory.sol:145`, written in `_scheduleTrustConfig` / `applyTrustConfig` / `cancelTrustConfig` |
| `pendingConfig` | `mapping(bytes32 salt => PendingConfig{uint8 threshold; address[] attesters})` | Factory-side mirror of the timelock's queued `(threshold, attesters)` for each salt. | `src/CorkRolloverContractFactory.sol:146`, written in `_scheduleTrustConfig`; cleared in `applyTrustConfig` / `cancelTrustConfig` |
| `queueNonce` | `mapping(address rolloverContract => uint64)` | Monotone counter feeding the timelock salt (`keccak256(abi.encode(rolloverContract, nonce))`); guarantees salt uniqueness across re-queues. | `src/CorkRolloverContractFactory.sol:147`, incremented in `_scheduleTrustConfig` |
| `defaultTrustThreshold` | `uint8` | Live default trust threshold seeded into newly deployed rolloverContracts. | Set in constructor and `setDefaults` |
| `erc7484Registry` | `address` | Live ERC-7484 registry baked into new rolloverContract CWIA trailers. | Set in constructor and `setDefaults` |
| `defaultAttesters` | `address[]` | Live default attester list seeded into newly deployed rolloverContracts; capped at `MAX_TRUST_ATTESTERS`. | Set in constructor and `setDefaults` |

### Transient storage (EIP-1153)

| Slot / Symbol | Type | Purpose | Write sites |
|---------------|------|---------|-------------|
| `_originatingSettler` | `address transient` | Active-dispatch provenance latch: set to `msg.sender` for the factory-to-rolloverContract call, read by the rolloverContract via `factory.originatingSettler()`, cleared after successful return (transient rollback on revert); `nonReentrant` is the practical nested factory-dispatch guard | `src/CorkRolloverContractFactory.sol:162` (declaration), `src/CorkRolloverContractFactory.sol:340-349` (set/clear in `executeIntentHooks`) |

Protocol-wide premium-replay protection lives in the **Settler**
(`rec.premiumFired` partial / `exactRec.premiumFired` exact), set inside the
atomic-fill frame and reverted with the frame on any failure. The rolloverContract's
`premiumFiredFor[orderDigest][filler][subFiller]` mapping is local rolloverContract replay
protection that commits atomically with a successful atomic fill. Exposed
read-only via `premiumFiredFor(rolloverContract, orderDigest, filler, subFiller)` on
`IRolloverContractLens` / `CorkRolloverContractFactory`; not the protocol-wide M-11 gate.

### Immutables (constructor-set, code-checked)

| Slot / Symbol | Type | Purpose | Write sites |
|---------------|------|---------|-------------|
| `ROLLOVER_CONTRACT_IMPLEMENTATION` | `address immutable` | CWIA clone template; reverts `__AddressHasNoCode` if EOA | `src/CorkRolloverContractFactory.sol:176`, set at `src/CorkRolloverContractFactory.sol:258`; code-check at `src/CorkRolloverContractFactory.sol:223-224` |
| `trustConfigTimelock` | `address immutable` | Constructor-supplied external per-rolloverContract trust-config `TimelockController`. Address is immutable; configured delay is mutable through the Factory-governed delay-update path and bounded by `MAX_TRUST_CONFIG_DELAY`. Must have factory proposer/canceller/executor roles. Sole authorized caller of `relayTrustConfig`. Backs `INV-TRUST-CONFIG-TIMELOCK-WIRED`. | `src/CorkRolloverContractFactory.sol` |

### Constants

| Slot / Symbol | Type | Purpose | Source |
|---------------|------|---------|--------|
| `MAX_TRUST_ATTESTERS` | `uint256 = 16` | Maximum attester count accepted by constructor defaults, defaults updates, queued per-rolloverContract configs, and rolloverContract-side trust configs. | `src/CorkRolloverContractFactory.sol` |

### CWIA trailer

`Clones.cloneDeterministicWithImmutableArgs(ROLLOVER_CONTRACT_IMPLEMENTATION, abi.encodePacked(owner, address(this), registry), ownerSalt)`
appends a **60-byte trailer = `owner` (20 bytes) ‖ `factory` (20 bytes) ‖ `erc7484Registry` (20 bytes)** to the clone's runtime code
and deploys it with CREATE2. `predictRolloverContractOf(owner)` uses the same implementation,
CWIA trailer, deployer, and owner-derived domain-separated salt. The factory-side `_decodeCwiaArgs` reads only the first
40 bytes (owner + factory) — the registry tail is consumed by the rolloverContract's `_registry()`.
Factory nonce and unrelated prior rolloverContract deployments are not address inputs.
Decode is via assembly `shr(0x60, mload(add(args, 0x20)))` for owner and `shr(0x60, mload(add(args, 0x34)))` for factory (`src/CorkRolloverContractFactory.sol:1008-1017`).
Mirror of `CorkRolloverContract._cwiaImmutableArgs` per rolloverContract.md.

## Entrypoints

**AC legend**: `ANY` = unrestricted; `APPROVED-SETTLER` = `approvedSettlers[msg.sender] == true`;
`APPROVER` = `onlyRole(SETTLER_APPROVER_ROLE)`; `REVOKER` = `onlyRole(SETTLER_REVOKER_ROLE)`;
`DEFAULTS MANAGER` = `onlyRole(DEFAULTS_MANAGER_ROLE)`;
`DELAY MANAGER` = `onlyRole(TRUST_CONFIG_DELAY_MANAGER_ROLE)`; `CWIA-NEW` = caller has no existing rolloverContract.

### Mutating

| Function | Modifiers | Role gate | Revert paths | Source |
|----------|-----------|-----------|--------------|--------|
| `deployRolloverContract() returns (address rolloverContract)` | `nonReentrant` | ANY + CWIA-NEW | `CorkRolloverContractFactory__AlreadyDeployed(msg.sender)` | `src/CorkRolloverContractFactory.sol:283-303` |
| `executeIntentHooks(address rolloverContract, bytes32 orderDigest, uint8 phase, RolloverIntent calldata intent, bytes calldata signature, FillContext calldata fillContext, OrderData calldata orderData) returns (uint256 dstProduced, uint256 srcLeftover)` | `nonReentrant` | APPROVED-SETTLER | `CorkRolloverContractFactory__PhaseNotDispatchable(phase)`, `CorkRolloverContractFactory__SettlerNotApproved(msg.sender)`, `CorkRolloverContractFactory__InvalidOrderBinding`, `CorkRolloverContractFactory__SettlerLatchMismatch(origin, msg.sender)`, `CorkRolloverContractFactory__SettlerNotOriginSettler(fillContext.originSettler, msg.sender)`, `CorkRolloverContractFactory__UnknownRolloverContract(rolloverContract)` | `src/CorkRolloverContractFactory.sol:310-350` |
| `approveSettler(address settler)` | `nonReentrant onlyRole(SETTLER_APPROVER_ROLE)` | APPROVER | `CorkRolloverContractFactory__ZeroAddress`, `CorkRolloverContractFactory__AddressHasNoCode(settler)`; idempotent flag set; no interface check | `src/CorkRolloverContractFactory.sol:354-364` |
| `revokeSettler(address settler)` | `nonReentrant onlyRole(SETTLER_REVOKER_ROLE)` | REVOKER | — (idempotent kill-switch, including zero/no-code targets; emits even when already unapproved) | `src/CorkRolloverContractFactory.sol:368-372` |
| `owner()` / `transferOwnership(address)` / `renounceOwnership()` | inherited `Ownable` | owner identity only | OZ `OwnableUnauthorizedAccount`, `OwnableInvalidOwner` | inherited via `src/CorkRolloverContractFactory.sol` |
| `grantRole(bytes32 role, address account)` / `revokeRole(bytes32 role, address account)` | inherited `AccessControl` | role admin | OZ `AccessControlUnauthorizedAccount` | inherited |
| `renounceRole(bytes32 role, address account)` | inherited OZ `AccessControl` | self only | OZ `AccessControlBadConfirmation` for non-self renounce | inherited |
| `setDefaults(uint8 threshold, address[] attesters, address registry)` | `nonReentrant onlyRole(DEFAULTS_MANAGER_ROLE)` | DEFAULTS MANAGER | `CorkRolloverContractFactory__InvalidThreshold`, `CorkRolloverContractFactory__ZeroAddress`, `CorkRolloverContractFactory__DuplicateAttester`, `CorkRolloverContractFactory__TooManyAttesters`, `CorkRolloverContractFactory__AddressHasNoCode` | `src/CorkRolloverContractFactory.sol` |
| `queueFactoryDefaultTrustConfig()` | `nonReentrant` | rolloverContract owner only | `CorkRolloverContractFactory__CallerHasNoRolloverContract(caller)`, `CorkRolloverContractFactory__NotFactoryRolloverContract(rolloverContract)` | Resolves `rolloverContractOf[msg.sender]`, snapshots current factory defaults, and forwards to `_scheduleTrustConfig`; same delay/cancel/apply lifecycle as the custom path. |
| `queueTrustConfig(uint8 threshold, address[] attesters)` | `nonReentrant` | rolloverContract owner only | `CorkRolloverContractFactory__CallerHasNoRolloverContract(caller)`, `CorkRolloverContractFactory__NotFactoryRolloverContract(rolloverContract)`, `CorkRolloverContractFactory__NotRolloverContractOwner(caller, rolloverContract)`, `CorkRolloverContractFactory__InvalidThreshold`, `CorkRolloverContractFactory__ZeroAddress`, `CorkRolloverContractFactory__DuplicateAttester`, `CorkRolloverContractFactory__TooManyAttesters` | Advanced/custom path; resolves `rolloverContractOf[msg.sender]` and forwards caller-supplied config to `_scheduleTrustConfig`. |
| `queueTrustConfigDelayUpdate(uint256 newDelay)` | `nonReentrant onlyRole(TRUST_CONFIG_DELAY_MANAGER_ROLE)` | DELAY MANAGER | `CorkRolloverContractFactory__InvalidTrustConfigTimelockDelay` | Queues a replacement `TimelockController.updateDelay(newDelay)` operation on the external trust-config timelock; re-queueing cancels any prior pending delay-update op. |
| `applyTrustConfig(address rolloverContract)` | `nonReentrant` | ANY (post-delay) | `CorkRolloverContractFactory__NoQueuedTrustConfig(rolloverContract)`, OZ `TimelockController.TimelockUnexpectedOperationState` (delay not elapsed) | `src/CorkRolloverContractFactory.sol` |
| `cancelTrustConfig()` | `nonReentrant` | rolloverContract owner only | `CorkRolloverContractFactory__CallerHasNoRolloverContract(caller)`, `CorkRolloverContractFactory__NotFactoryRolloverContract(rolloverContract)`, `CorkRolloverContractFactory__NotRolloverContractOwner(caller, rolloverContract)`, `CorkRolloverContractFactory__NoQueuedTrustConfig(rolloverContract)` | Resolves `rolloverContractOf[msg.sender]` and cancels only that caller's pending trust config. |
| `cancelTrustConfigDelayUpdate()` | `nonReentrant onlyRole(TRUST_CONFIG_DELAY_MANAGER_ROLE)` | DELAY MANAGER | `CorkRolloverContractFactory__NoQueuedTrustConfigDelayUpdate` | Cancels the pending trust-config timelock delay update and clears the factory-side pending delay mirror. |
| `applyTrustConfigDelayUpdate()` | `nonReentrant` | ANY (post-delay) | `CorkRolloverContractFactory__NoQueuedTrustConfigDelayUpdate`, OZ `TimelockController.TimelockUnexpectedOperationState` (delay not elapsed) | Permissionless apply path that executes the queued `TimelockController.updateDelay(newDelay)` operation on the external trust-config timelock. |
| `relayTrustConfig(address rolloverContract, bytes32 salt, uint8 threshold, address[] attesters)` | external | `msg.sender == trustConfigTimelock` only + matching pending mirror + exact apply-frame op id | `CorkRolloverContractFactory__NotTimelock(caller)`, `CorkRolloverContractFactory__NotFactoryRolloverContract`, `CorkRolloverContractFactory__NoQueuedTrustConfig`, `CorkRolloverContractFactory__MismatchedApplyArgs`, `CorkRolloverContractFactory__UnexpectedTrustConfigRelay`; rolloverContract-side `CorkRolloverContract__NotFactory` is structurally unreachable here | `src/CorkRolloverContractFactory.sol` |

### View

| Function | Modifiers | Role gate | Revert paths | Source |
|----------|-----------|-----------|--------------|--------|
| `originatingSettler() returns (address)` | external view | ANY | — (zero outside dispatch frame) | `src/CorkRolloverContractFactory.sol:586-588` |
| `isDeployedRolloverContract(address rolloverContract) returns (bool)` | external view | ANY | — | `src/CorkRolloverContractFactory.sol:591-593` |
| `rolloverContractOf(address user) returns (address)` | external view | ANY | — | `src/CorkRolloverContractFactory.sol:596-598` |
| `predictRolloverContractOf(address owner) returns (address)` | external view | ANY | — | Predicts the deterministic CREATE2 CWIA clone address for `owner`; same-address parity across chains requires identical factory address, implementation address, owner, and live registry. |
| `approvedSettlers(address settler) returns (bool)` | external view | ANY | — | `src/CorkRolloverContractFactory.sol:601-603` |
| `defaultAttesters() returns (address[])` | external view | ANY | — | `src/CorkRolloverContractFactory.sol:573-575` |
| `orderState(address rolloverContract, bytes32 orderDigest) returns (ICorkRolloverContract.RolloverContractOrderState memory)` | external view (`IRolloverContractLens`) | ANY | `CorkRolloverContractFactory__UnknownRolloverContract(rolloverContract)` | `src/CorkRolloverContractFactory.sol:606-615` |
| `premiumFiredFor(address rolloverContract, bytes32 orderDigest, address filler, bytes32 subFiller) returns (bool)` | external view (`IRolloverContractLens`) | ANY | `CorkRolloverContractFactory__UnknownRolloverContract(rolloverContract)` | `src/CorkRolloverContractFactory.sol:618-627` |
| `rolloverContractConfig(address rolloverContract) returns (IRolloverContractLens.RolloverContractConfig memory)` | external view (`IRolloverContractLens`) | ANY | `CorkRolloverContractFactory__UnknownRolloverContract(rolloverContract)` | `src/CorkRolloverContractFactory.sol:630-645` |
| `pendingTrustConfig(address rolloverContract) returns (uint8 threshold, address[] attesters, uint64 effectiveAt)` | external view | ANY | — (threshold/attesters from the Factory mirror, `effectiveAt` from the timelock op timestamp; returns `(0, [], 0)` when no Factory mirror exists) | `src/CorkRolloverContractFactory.sol:648-667` |
| `trustConfigTimelock() returns (address)` | public view (immutable accessor) | ANY | — | `src/CorkRolloverContractFactory.sol` |

### `executeIntentHooks` dispatch sequence (CEI-ordered)

1. Storage handle `$ = _s()` (`src/CorkRolloverContractFactory.sol:319`).
2. Phase allowlist — `phase ∈ {ROLLOVER, PREMIUM}` (`src/CorkRolloverContractFactory.sol:322-324`); reverts `__PhaseNotDispatchable`.
3. Allowlist gate — `approvedSettlers[msg.sender]` (`src/CorkRolloverContractFactory.sol:330`, helper at `src/CorkRolloverContractFactory.sol:982-986`); reverts `__SettlerNotApproved` ([[INV-SETTLER-APPROVED]]).
4. Zero-digest reject (`src/CorkRolloverContractFactory.sol:326-328`); reverts `__InvalidOrderBinding`. Runs **before** any transient writes.
5. `fillContext.originSettler == msg.sender` cross-check (`src/CorkRolloverContractFactory.sol:332-334`); reverts `__SettlerNotOriginSettler`.
6. `isDeployedRolloverContract[rolloverContract]` set-membership (`src/CorkRolloverContractFactory.sol:336-338`); reverts `__UnknownRolloverContract`.
7. Settler latch (`src/CorkRolloverContractFactory.sol:340-345`). Sets `_originatingSettler = msg.sender` when zero; if already set to another address, reverts `__SettlerLatchMismatch` (defensive — nested `executeIntentHooks` is practically blocked by `nonReentrant`).
8. **INTERACTION**: `ICorkRolloverContract(rolloverContract).executeIntentHooks(orderDigest, phase, intent, cptHolderSig, fillContext, orderData)`.
9. `_originatingSettler = address(0)` (`src/CorkRolloverContractFactory.sol:349`) after the rolloverContract call returns. `nonReentrant` wraps the whole call; reverts after the latch write roll back the transient write.

### `deployRolloverContract` initialization sequence

`src/CorkRolloverContractFactory.sol:283-303`:

1. Per-owner uniqueness — `rolloverContractOf[owner] == 0` (`:287-288`); reverts `__AlreadyDeployed`.
2. `args = abi.encodePacked(owner, address(this), registry)` — 60-byte CWIA trailer.
3. `salt = keccak256(abi.encodePacked(ROLLOVER_CONTRACT_SALT_DOMAIN, owner))`.
4. `rolloverContract = Clones.cloneDeterministicWithImmutableArgs(ROLLOVER_CONTRACT_IMPLEMENTATION, args, salt)`.
5. `rolloverContractOf[owner] = rolloverContract; isDeployedRolloverContract[rolloverContract] = true`.
6. `ICorkRolloverContract(rolloverContract).initialize(trustThreshold, trustAttesters)`.
   The rolloverContract mirrors the pair into `liveTrustThreshold` / `liveTrustAttesters` and forwards
   `(threshold, attesters)` to `IERC7484.trustAttesters` so the smart-account record is seeded.
   Modifier-order requirement (`onlyFactory` MUST precede `initializer`) per
   [[oz_migration_cwia_dependencies]].
6. `emit RolloverContractDeployed(owner, rolloverContract)` (`:303`).

## Internal helpers

| Function | Purpose | Source |
|----------|---------|--------|
| `_s() returns (FactoryStorage storage $)` | ERC-7201 storage handle | `src/CorkRolloverContractFactory.sol:833-838` |
| `_decodeCwiaArgs(address rolloverContract) returns (address ownerAddr, address factoryAddr)` | Assembly decode of the first 40 bytes of the 60-byte CWIA trailer at offsets `0x20` (owner) and `0x34` (factory); registry tail (offset `0x48`) read separately by the rolloverContract's `_registry()`. Used by `rolloverContractConfig`. | `src/CorkRolloverContractFactory.sol:1008-1017` |
| `_scheduleTrustConfig(address rolloverContract, uint8 threshold, address[] attesters)` | Sole factory `trustConfigTimelock.schedule` site. Shared by default-snapshot and custom queue paths. Validates owner identity + threshold/attester set; cancels any prior pending op for this rolloverContract; computes a per-`(rolloverContract, queueNonce)` salt; mirrors the exact scheduled `(salt, threshold, attesters)` into `pendingConfig[salt]` and `lastSalt[rolloverContract]`; emits `TrustConfigQueued`. | `src/CorkRolloverContractFactory.sol` |
| `relayTrustConfig(address rolloverContract, bytes32 salt, uint8 threshold, address[] attesters)` | External self-target for the trust-config timelock; gated `msg.sender == trustConfigTimelock`, the matching factory pending mirror, and the exact op id temporarily authorized by `applyTrustConfig`. Clears the mirror before forwarding into `ICorkRolloverContract(rolloverContract).setTrustConfig`. | `src/CorkRolloverContractFactory.sol` |
| `_relayCalldata` | Build the timelock payload that routes through `relayTrustConfig`. | `src/CorkRolloverContractFactory.sol:841-850` |
| `_validateTrustConfig(uint8, address[])` | Factory-side validator shared by defaults updates and per-rolloverContract trust queues (cap / zero / empty / threshold-too-big / zero-attester / duplicate-attester). Mirrors `CorkRolloverContract._validateTrustConfig`. | `src/CorkRolloverContractFactory.sol:929-946` |

## Invariants touched

- **[[INV-SETTLER-APPROVED]]** (`docs/INVARIANTS.md:955`) — `executeIntentHooks` gates on `approvedSettlers[msg.sender]` at `src/CorkRolloverContractFactory.sol:330`; `approveSettler` enforces non-zero + code-present targets at `src/CorkRolloverContractFactory.sol:354-360`; `revokeSettler` is an idempotent instant kill-switch at `src/CorkRolloverContractFactory.sol:368-372`.
- **[[INV-PARAMS-SETTLER-PIN]]** (`docs/INVARIANTS.md:1172`) — factory's `fillContext.originSettler == msg.sender` cross-check at `src/CorkRolloverContractFactory.sol:332-333` is one of three composed gates (allowlist + origin-settler match + rolloverContract's signed `orderData.rolloverParams.settler == fillContext.originSettler` binding) that jointly pin dstCST routing to an approved Settler.
- **[[INV-DEFAULT-ATTESTERS-FACTORY-SEEDED]]** (`docs/INVARIANTS.md:1192`) — every rolloverContract deployed by this factory starts life with the current `(defaultTrustThreshold, defaultAttesters)` pair forwarded into `initialize` at `src/CorkRolloverContractFactory.sol:301`; constructor and `setDefaults` enforce `MAX_TRUST_ATTESTERS`.
- **M-11 / premium-replay** — protocol-wide replay is enforced **Settler-side** by `rec.premiumFired` (partial) / `exactRec.premiumFired` (exact) inside the atomic-fill frame. RolloverContract `premiumFiredFor[orderDigest][filler][subFiller]` is local replay protection; lens `premiumFiredFor(rolloverContract, orderDigest, filler, subFiller)` at `src/CorkRolloverContractFactory.sol:618-627` is read-through only.
- Factory-local structural invariants (no INV-id):
  - **Settler latch provenance** — `_originatingSettler` active-dispatch mirror at `src/CorkRolloverContractFactory.sol:340-345` and clear at `:349`, bracketed tightly around the rolloverContract call; rolloverContract verifies `factory.originatingSettler() == fillContext.originSettler`. `__SettlerLatchMismatch` is defensive if the latch already holds another settler; nested factory dispatch is practically blocked by `nonReentrant`.
  - **One rolloverContract per cPT holder** — `__AlreadyDeployed` at `src/CorkRolloverContractFactory.sol:287-288`.
  - **CWIA trailer 60 bytes** — `abi.encodePacked(owner, address(this), registry)` shared by deploy and prediction; decode uses the first 40 bytes for owner/factory and the rolloverContract reads the registry tail.
  - **Phase allowlist** = `{ROLLOVER, PREMIUM}` — `src/CorkRolloverContractFactory.sol:322-324`.
  - **Code-present external anchors** — constructor and `setDefaults` `code.length` checks for registry / implementation anchors; mirrored on `approveSettler` at `src/CorkRolloverContractFactory.sol:358-359`.
  - **Phoenix-style owner/admin split** — `owner()` is deployment identity only; `DEFAULT_ADMIN_ROLE` administers roles, while dedicated operational roles gate allowlist/default actions.
  - **Role administration** — inherited OZ `AccessControl`; `DEFAULT_ADMIN_ROLE` self-renounce is allowed and should be controlled by runbooks.
  - **Factory defaults governance** — `setDefaults` is direct and role-gated by `DEFAULTS_MANAGER_ROLE`; assign that role to external governance/timelock if delay is desired.

## Integrations

- **`ICorkRolloverContract`** — clone targets. Called at:
  - `initialize(trustThreshold, trustAttesters)` — `src/CorkRolloverContractFactory.sol:301`.
  - `executeIntentHooks(orderDigest, phase, intent, cptHolderSig, fillContext, orderData)` — factory-to-rolloverContract dispatch.
  - `orderState(orderDigest)` — `src/CorkRolloverContractFactory.sol:614`.
  - `premiumFiredFor(orderDigest, filler, subFiller)` — `src/CorkRolloverContractFactory.sol:626`.
  - `rolloverContractSnapshot()` — `src/CorkRolloverContractFactory.sol:638`.
- **OZ `Clones`** (CWIA / ERC-1167) — `cloneDeterministicWithImmutableArgs(ROLLOVER_CONTRACT_IMPLEMENTATION, args, salt)` for deployment, `predictDeterministicAddressWithImmutableArgs(...)` for `predictRolloverContractOf`, and `fetchCloneArgs(rolloverContract)` for decode.
- **OZ `Ownable`** — Phoenix-style owner identity. It does not gate protocol actions.
- **OZ `AccessControl`** — Factory mirrors Settler's role model. `DEFAULT_ADMIN_ROLE` rotation is plain `grantRole` / `revokeRole`; dedicated operational roles gate allowlist/default actions.
- **OZ `ReentrancyGuardTransient`** (EIP-1153) — transient reentrancy guard on `deployRolloverContract`, `executeIntentHooks`, `approveSettler`, `revokeSettler`. Import at `src/CorkRolloverContractFactory.sol:8-10`.
- **EIP-1153** — used for `_originatingSettler` (declaration `src/CorkRolloverContractFactory.sol:162`) and by `ReentrancyGuardTransient`.
- **ERC-7484** — Rhinestone attester registry. **Factory does NOT call into it.** RolloverContracts consult `IERC7484.check(target, ModuleType)` directly per [[feature_hook_restructure_and_rolloverContract_opinionation]]; rolloverContracts are seeded with `(defaultTrustThreshold, defaultAttesters)` and forward to `IERC7484.trustAttesters` at initialize time. Constructor and scheduled-defaults code-length gates prevent EOA wiring (`src/CorkRolloverContractFactory.sol:226-227`, `:400-401`).
- **ERC-7683** — cross-chain intents. `orderDigest` and `(intent, cptHolderSig,
  fillContext, orderData)` shape routed verbatim from the Settler. Factory does
  NOT verify the cPT-holder signature — the Settler verifies before dispatch where
  required, and the rolloverContract re-verifies on every hook dispatch.
- **`IRolloverContractLens`** (vendored at `src/interfaces/rollover/IRolloverContractLens.sol`) — factory is sole implementor; exposes three typed primitives:
  1. `orderState(rolloverContract, orderDigest) → ICorkRolloverContract.RolloverContractOrderState{rolled, rolloverTerminal}` — `src/CorkRolloverContractFactory.sol:606-615`.
  2. `premiumFiredFor(rolloverContract, orderDigest, filler, subFiller) → bool` — `src/CorkRolloverContractFactory.sol:618-627`.
  3. `rolloverContractConfig(rolloverContract) → RolloverContractConfig{owner, factory, erc7484Registry, liveTrustThreshold, liveTrustAttesters}` — `src/CorkRolloverContractFactory.sol:630-645`. Composes CWIA decode + `ICorkRolloverContract.rolloverContractSnapshot()`. Pending trust state lives on the factory: read it via `pendingTrustConfig(rolloverContract)`.
- **EIP-712** — factory itself does NOT mix EIP-712 domains; rolloverContract (intents) and Settler (FillerAuth / Cancel) own theirs. CWIA-clone EIP-712 hazard documented in [[oz_migration_cwia_dependencies]] but does not surface in the factory.
- **ERC-20** — never custodied directly. Token transfers happen inside the rolloverContract leg.

## Tests

- `test/unit/factory/` — factory unit tests (deploy, approve/revoke, allowlist, timelock, AccessControl admin, CWIA trailer, lens primitives).
- `test/unit/rollover-contract/RolloverContractLens.t.sol` — scenarios across `orderState` / `premiumFiredFor` / `rolloverContractConfig` (per `feature_rolloverContract_lens_via_factory`).
- `test/integration/` — multi-rolloverContract dispatch and settler latch identity across nested phases.
- `test/invariant/` — handler-based invariant suites read `docs/INVARIANTS.md` for INV-SETTLER-APPROVED, INV-PARAMS-SETTLER-PIN, INV-DEFAULT-ATTESTERS-FACTORY-SEEDED, M-11.

Test directories mirror the `src/` layout; see each path for the live `*.t.sol` files.
