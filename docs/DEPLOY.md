# Cork Rollover Deployment Runbook

## 1. The silence pattern — read this first

The Cork rollover boot sequence is a **three-domain coordination
problem with no single revert as a forcing function**. Cork's factory checks
its own state, Phoenix's pool manager checks its own state, and the
Rhinestone ERC-7484 registry checks its own state. Every individual contract
can return clean tx receipts for a sequence that the *protocol as a whole*
cannot make a single fill flow through.

Deploy-time success ≠ first-fill success. A misconfigured deployment can
have a green-looking Cork state (`approvedSettlers == true`,
`isDeployedRolloverContract == true`, a populated `rolloverContractSnapshot().liveTrustAttesters`,
non-empty `defaultAttesters()`) and still revert on the first user fill
because the selected Phoenix market/pool is absent or mismatched, an attester
has not published an attestation for the hook target, or only one of the two
concrete settlers has been approved.

**The release gate for this codebase is
`FOUNDRY_PROFILE=deploy forge script script/verify-deploy.s.sol`, not any
individual contract's view function.** The deployer and verifier must use this
same compiler profile because the exact bootstrap artifact bytecode is a
provenance input. No deploy is considered live until the deploy-profile script
exits 0 against the target chain.

## Canonical multi-component operator

Paired Base + Arbitrum release orchestration belongs in
`cork-agentic-releases-private`, not in a repository-local shell wrapper. This
repository exposes the component-specific Foundry primitives that the release
helper must pin and invoke:

- `DeployStaging.plan(string)` for deterministic address and initcode planning;
- `DeployStaging.compareConfigParity(...)` for typed cross-chain identity evidence;
- `DeployStaging.run(string)` for the bounded Rollover deployment transaction set;
- `DeployStaging.verify(string)` and `VerifyDeploy.run()` for terminal state checks.

The release orchestrator supports Rollover as a separately typed,
Base-and-Arbitrum-only campaign. It pins this repository and every recursive
submodule, consumes the source-owned plan/compare/apply/verify entrypoints, and
records Rollover evidence without appending to a Phoenix, ForSelf, or Market
Registry campaign. Do not duplicate its planning, approvals, signing,
broadcast, or release-manifest workflow in this repository. Do not invoke
`deploy-staging.s.sol` with `--broadcast` outside that reviewed workflow.

The command plan is dependency ordered: reconcile compatible Phoenix releases
on both chains; reconcile Market Registry when `BaseFiller` is enabled; verify
its recipes, expiry bound, ownership, and runtime; review Rollover plans;
deploy/reconcile the canonical singleton vector; deploy/reconcile the optional
operational `BaseFiller`; generate unsigned governance artifacts; reconcile
authority state; then run readiness checks. Ethereum, a one-chain cohort, an
extra chain, or a missing dependency fails before execution.

## 2. Boot-order rail (lane diagram)

```
Lane A (Phoenix)     │ Lane B (ERC-7484)   │ Lane C (Cork Factory) │ Lane D (cPT holder RolloverContract)
─────────────────────┼─────────────────────┼───────────────────────┼──────────────────────
A1 market published  │                     │                       │
A2 shares() verified │                     │                       │
                     │ B1 registry alive   │                       │
                     │ B2 attesters set    │                       │
                     │                     │ C1 factory deployed   │
                     │                     │ C2 impl bound         │
                     │                     │ C3 defaults validated │
                     │                     │ C4 Settlers approved  │
                     │                     │                       │ D1 deployRolloverContract()
                     │                     │                       │ D2 seed verified
                     │ B3 hooks attested   │                       │ (cross-lane wait on D1)
                     │                     │                       │ D3 simulate fill
                     │                     │                       │ D4 hold configured delay ─ no queue
                     │                     │                       │ D5 release genesis
```

Two cross-lane gates carry the silence pattern:

- **B3 starts only after D1** — module registration and M1 attestation publication
  occur after the immutable implementation, Factory, and holder clone are deployed
  and verified. Prediction is planning evidence, not permission to label an
  undeployed or legacy clone attestation-ready.
- **D3 waits on A2 + B3 + C4** — the end-to-end fill simulation can only
  succeed once the selected Phoenix market/pool matches its configured shares,
  attesters have published module-type attestations, and both concrete Settlers
  are on the factory allowlist. No PoolManager rollover-contract whitelist step
  exists in this campaign.

Each lane step maps to a literal command:

| Step | Literal command (or external dependency) |
|---|---|
| A1 | Phoenix admin publishes the pool. |
| A2 | `FOUNDRY_PROFILE=deploy forge script script/verify-deploy.s.sol --sig 'run()'` (gate 3). |
| B1 | Rhinestone deploys / operates the registry. |
| B2 | Default attesters live on the registry. |
| B3 | Each attester publishes `(rolloverContract, hookTarget, moduleType)` attestations. |
| C1 | Predict the factory address, deploy/configure the external trust-config timelock for that address, then `new CorkRolloverContractFactory(impl, registry, threshold, defaults, trustConfigTimelock, ensOwner, factoryAdmin, defaultsManager, settlerApprover, settlerRevoker)`. |
| C1a | Link/deploy `LibFillerPayloadExternal` for the concrete Settler artifacts. |
| C2 | Implementation address baked into factory at construction. |
| C3 | `defaultAttesters()` non-empty + threshold ≤ length. |
| C4 | `factory.approveSettler(exactSettler)` and `factory.approveSettler(partialSettler)` from `SETTLER_APPROVER_ROLE`. |
| D1 | cPT holder checks `factory.predictRolloverContractOf(cptHolder)`, then calls `factory.deployRolloverContract()`. |
| D2 | `factory.rolloverContractConfig(rolloverContract).owner == cptHolder`. |
| D3 | `FOUNDRY_PROFILE=deploy forge script script/verify-deploy.s.sol --sig 'run()'` (gates 1–4) + the anvil probe in §4 for gate 5. |
| D4 | Confirm Gate 1 reports the live timelock delay as exactly `0` and Gate 2 reports `factory.pendingTrustConfig(rolloverContract) == (0, [], 0)`. A scheduled M1 operation may be executed immediately, but it must still traverse `TimelockController.schedule` and `execute`; M1 never receives a direct Factory administration role. |
| D5 | Broadcast the first user fill. |

## 3. Boot-order traps

Two misconfigurations have green Cork-side state and revert only on the
first fill. Each entry: symptom, silent state, first revert selector,
recovery action.

### Trap 1 — Genesis Settler missing

- **Symptom:** `deployRolloverContract()` succeeds; the first fill reverts.
- **Silent state:** `isDeployedRolloverContract(rolloverContract) == true`, but
  `approvedSettlers(exactSettler) == false` or
  `approvedSettlers(partialSettler) == false`.
- **First revert:** `CorkRolloverContractFactory__SettlerNotApproved(settler)` inside
  `executeIntentHooks`.
- **Recovery:** approve both concrete settlers from `SETTLER_APPROVER_ROLE`.

### Trap 2 — Hook target not attested for its bucket

- **Symptom:** a signed intent succeeds in a unit test against a mocked
  registry; the same intent reverts on-chain on the first fill.
- **Silent state:** `rolloverContractSnapshot().liveTrustAttesters` mirrors the
  factory defaults; `defaultAttesters()` non-empty.
- **First revert:** `CorkRolloverContract__ModuleTypeMismatch(target, expectedModuleType)`
  on the rolloverContract's per-batch `IERC7484.check` call.
- **Recovery:** the attester publishes the missing `(rolloverContract, hookTarget, moduleType)`
  attestation through the registry's attestation surface.

### Trap 3 — Legacy module-type discriminators

- **Symptom:** every attempted module attestation using the release's inlined
  discriminator reverts before first-fill readiness can be established.
- **Silent state:** an implementation or clone still contains
  `0xc0c0_0001..0xc0c0_0004`; Factory defaults and holder trust configuration
  may otherwise look correct.
- **First revert:** Rhinestone `InvalidModuleType()` (`0x2125deae`) while packing
  the attestation's module types because the deployed registry accepts only
  bitmap indices 0…31.
- **Recovery:** none for that immutable deployment. Build from the corrected
  source (`5` pre, `6` mid, `7` post, `8` premium), select a fresh release
  configuration, and deploy a greenfield cohort. Do not relabel the old
  implementation, Factory, or clones as compatible.

### M-05 — Removed full-balance premium executors

New premium intents must not depend on removed full-balance premium modules.
`TransferAllModule` and `SplitModule` are removed and obsolete for new-order
hook templates; keep premium payout hooks amount-scoped through
`ScopedTransferModule` or `ScopedSplitModule`. There are no live signed intents
in this remediation branch, so deployment must not attest removed full-balance
premium modules for new orders.

### OwnerTokenPullModule operator note

Deploy `OwnerTokenPullModule` as an immutable stateless module and attest it
only under `MODULE_TYPE_PRE_ROLLOVER_HOOK` / Cork-local bucket `5`. The cPT holder's
ERC-20 allowance must be granted to the rollover contract, not to the module,
because the module runs through delegatecall and calls `transferFrom(owner,
address(this), amount)` from the rollover contract context. In module calldata,
`amount` is exact when `allowUnderfill=false`; when `allowUnderfill=true`,
`amount` is a maximum and the module pulls the smaller positive value across the
signed maximum, the owner's token balance, and the owner's allowance to the
rollover contract. The module does not infer fill size and does not perform
rollover accounting; actual underfill accounting remains in `_unwindLeg`.

## 4. Release gate — `script/verify-deploy.s.sol`

The release gate is a Forge script. **The script's exit code IS the release
signal** — `0` means release-ready, non-zero means blocked. Block-explorer
eyeballing or Discord pings are NOT sufficient.

### Greenfield-only release policy

This release is greenfield-only. The verifier must be run against:

- fresh `ExactSettler` and `PartialSettler` deployments;
- a fresh `CorkRolloverContractFactory`;
- fresh `CorkRolloverContract` clones deployed by that factory.

Do not use this release gate to approve proxy upgrades, in-place reuse of
populated legacy storage, legacy factory/rolloverContract reparenting, or live-state
migration. Any future live-state migration needs a separate written spec,
storage-compatibility tests, and its own release gate before production use.

The removed `0xc0c0_0001..0xc0c0_0004` module types are inlined into
`CorkRolloverContract` runtime bytecode and are incompatible with the deployed
registry. Existing implementations, Factories bound to them, and holder clones
cannot gain usable attestations through configuration or governance. A fixed
release requires a new immutable commit, clean deploy-profile rebuild, and
greenfield deployment; existing addresses remain legacy and incompatible.

### Repository deployment entrypoint

`script/deploy-staging.s.sol:DeployStaging` is the source-owned greenfield
entrypoint. Its checked JSON input follows
`script/config/ethereum-staging.example.json` (`profile = "ethereum"`, chain
`1`), `script/config/base-staging.example.json` (`profile = "base"`, chain
`8453`), or `script/config/arbitrum-staging.example.json` (`profile =
"arbitrum"`, chain `42161`). The source script retains all three profiles, but
the production Rollover release cohort is exactly Base and Arbitrum; the
external orchestrator rejects Ethereum and any incomplete or expanded cohort.
The document contains public deployment inputs only: never place a private
key, seed, mnemonic, PIN, passphrase, signature, signed transaction,
credential-bearing URL, or Ledger transport/session/derivation data in it.
Missing keys are rejected separately from present zero values. Every enabled
external dependency address and runtime codehash is mandatory; zero is
rejected and never disables comparison.

The input binds two typed signer identities before any apply:

- `signers.deployer` must use `foundry-encrypted-keystore` with the shared
  Phoenix/ForSelf Shadow Wallet sender `0xaCd3cda91582Ac9940Eaf94A5CCB8eD21671AFA8`;
- `signers.governance` may use either typed backend; this campaign selects
  `ledger`;
- each binding carries its public `sender`, a non-empty **non-secret** backend
  `reference`, the selected profile's `chainId`, and the expected pre-apply
  `nonce`.

The typed loader represents both `ledger` and `foundry-encrypted-keystore`
without accepting raw keys. The deployer reference identifies the shared
Phoenix/ForSelf Shadow Wallet but never contains its path, password, or signing material.
The canonical operator validates that file and prompts for its password only
when a transaction must be signed.

The deployer and governance signer are separate. The governance signer must be
one of the three ordered Safe owners; the deployer must not be a Safe owner,
default attester, or final authority. A backend reference is an operator-facing
alias, not signing material, and the script never interprets it as a key.

Planning validates the complete config, explicit profile/chain pairing, signer
bindings and live nonces, external runtime code and hashes, principal
separation, Safe owner shape, deterministic salts, and fill-probe completeness.
On Arbitrum One it first requires the shared Phoenix/ForSelf Shadow Wallet
deployment sender `0xaCd3cda91582Ac9940Eaf94A5CCB8eD21671AFA8`. The `deterministicRoot` block
selects the `eip-2470-singleton-factory` ABI and commits the common root
address/runtime, bootstrap-deployer salt, and common deployment authority.
Cohort comparison requires the root runtime commitment to match across
manifests. The operational sender and nonce authorize the transaction but do
not enter any singleton address formula.

The root CREATE2-deploys the exact `RolloverBootstrapDeployer` initcode. That
deployer uses one fixed salt to CREATE2-deploy the no-argument,
chain-neutral `RolloverDeploymentBootstrap`, then atomically initializes the
config hash, deployment-artifact commitment, and temporary owner. Planning and
execution reject wrong root runtime, wrong occupied deployer/bootstrap runtime
or authority state, uninitialized occupied bootstrap state, and commitment or
owner mismatches before broadcasting a missing child.

Planning separately hashes the complete address-bound initcode set. Factory
identity remains CREATE-derived from bootstrap nonce 6; the script asserts that
nonce immediately before Factory creation, and the terminal verifier derives
the same expected Factory address from the shared
`DeploymentIdentity.FACTORY_CREATION_NONCE`. Any occupied Factory must match the
locally reconstructed runtime and the bootstrap-recorded runtime hash.

### Operational BaseFiller

`baseFiller.enabled` controls a separate operational component; it does not
change the canonical 14-entry singleton/parity vector or Factory CREATE nonce
6. When disabled, legacy config and deployment-artifact commitments remain
unchanged and Market Registry is not a deployment prerequisite. When enabled,
the versioned commitments bind the BaseFiller salt and five constructor
dependencies: the planned exact and partial Settlers, Phoenix Pool Manager,
Phoenix controller, and Market Registry.

Planning reconstructs the constructor-bearing initcode, predicts the bootstrap
CREATE2 address, compares Base and Arbitrum salt, dependencies, creation-code
hash, runtime hash, and address, and rejects chain-local drift. Apply deploys
BaseFiller after the canonical modules and before bootstrap finalization.
Preflight accepts an occupied target only when its runtime matches both the
locally reconstructed runtime and the bootstrap's recorded codehash. Terminal
verification checks code plus all five immutable getters. Recognized partial
completion resumes without redeployment; an unrecognized occupied target
fails closed.

Production configuration must set the Phoenix Pool Manager address equal to
the canonical Settler dependency, and pin codehashes independently for Pool
Manager, controller, and Market Registry on each chain. The generated
governance artifact grants only Phoenix `POOL_CREATOR_ROLE` to BaseFiller.
It never grants `FEE_MANAGER_ROLE`, never signs or submits the transaction, and
must be reviewed before Safe scheduling/execution.

### Deployment versus first-fill readiness

Singleton and optional BaseFiller deployment do not establish first-fill
readiness. The release bundle records these states separately: singleton
deployment, BaseFiller deployment, Factory Settler approvals, holder clone
creation, trust configuration, hook attestations, Phoenix pool readiness,
Market Registry readiness, and first-fill rehearsal.

For JIT creation, Market Registry must expose the exact reconciled recipes and
a nonzero `maxExpiryDuration`. `BaseFiller.executeWithMarket` enforces the live
bound only while creating a missing pool; a bound that is zero, unavailable,
malformed, or shorter than the signed expiry fails closed before Phoenix
creation. A later governance reduction cannot strand fills into an existing
pool. FIXED readiness requires its registered fixed-rate recipe and a live
nonzero oracle rate. PRICE/NAV readiness additionally requires the applicable
assets, denominations, conversion feeds, and recipe configuration; a registry
with only recipes registered must not be reported as generally PRICE/NAV
ready.

Before any JIT rehearsal, reconcile that BaseFiller holds Phoenix
`POOL_CREATOR_ROLE` on each chain. New JIT pools are created with
`isWhitelistEnabled = false`. For an existing whitelisted destination market,
the required whitelist subject is the per-holder RolloverContract clone—not
the Factory, either Settler, or BaseFiller.

Each cPT holder creates its own predicted CWIA clone through the Factory. These
clones are operational inventory, never canonical singleton components.
Holder clone trust configuration is a separate registry trust-set operation;
it does not register a module or publish an M1 module attestation. Only after
the implementation, Factory, and clone are deployed and verified may operators
register each reviewed module and publish M1 attestations for the exact Cork
phase bucket.

First-fill readiness requires a successful fork/local simulation of the exact
`check(module, moduleType, attesters, threshold)` context used by the clone for
every module in the order. Readiness then verifies safe trust defaults, the
holder-specific trust configuration, and every `(clone, hook target, module
type)` attestation. The campaign generates unsigned governance/attestation
artifacts only; an operator reviews the authenticated command plan, source plan,
paired parity evidence, Safe addresses/nonces, calldata, and artifact digests
before any external signing or submission.

On interrupted execution, rerun planning against the frozen chain boundary and
resume only when every occupied deterministic target matches its planned
runtime, immutable bindings, bootstrap record, and deployment-artifact
commitment. The corrected module constants change the implementation initcode,
its CREATE2 address, the Factory's implementation-bound initcode/runtime, and
holder clone initcode/address. A stale incompatible release therefore fails
the source-owned occupied-address and artifact-commitment checks; cached
`out/`, manifests, or prior plan output is never compatibility evidence. Any
mismatch requires a fresh release configuration; never overwrite a frozen plan
or manifest.
Planning does not start a broadcast:

```bash
FOUNDRY_PROFILE=deploy forge script \
  script/deploy-staging.s.sol:DeployStaging \
  --sig 'plan(string)' script/config/arbitrum-staging.json \
  --rpc-url "$READ_ONLY_RPC_URL"
```

Compare every cohort member against the candidate canonical manifest before any
broadcast. Comparison rejects different deterministic-root runtime
commitments, even when the root address matches. The typed report then contains
opcode, deployer, salt/nonce, creation-code hash, named address inputs,
address-parity, and semantic-parity evidence for every singleton plus one fixed
owner's CWIA RolloverContract:

```bash
FOUNDRY_PROFILE=deploy forge script \
  script/deploy-staging.s.sol:DeployStaging \
  --sig 'compareParity(string,string)' \
  script/config/arbitrum-staging.json script/config/base-staging.json \
  --rpc-url "$READ_ONLY_RPC_URL"

FOUNDRY_PROFILE=deploy forge script \
  script/deploy-staging.s.sol:DeployStaging \
  --sig 'compareParity(string,string)' \
  script/config/arbitrum-staging.json script/config/ethereum-staging.json \
  --rpc-url "$READ_ONLY_RPC_URL"
```

Before bootstrap initialization, `run(string)` revalidates the governance
signer's exact live nonce. It requires the deployment authority's exact
configured nonce while the bootstrap deployer is absent. If the authenticated
bootstrap deployer already exists but the bootstrap does not, it accepts the
configured nonce or the next nonce: a permissionless root caller does not
consume the authority nonce, while an authority-originated deployment does.
Once an initialized bootstrap exists, same-config resume and verification rely
on its stored commitments; unrelated later signer nonce changes do not alter
its address or the checked config. Balance-only pre-funding is not treated as
occupied output state; any nonempty runtime or nonzero account nonce must still
match the exact expected deployment state before deployment resumes.

Production broadcast remains blocked until the team records a verified common
EIP-2470 root runtime on every target chain, one fixed deployer salt, one common
deployment authority, complete Ethereum/Base/Arbitrum dependency inventory,
and a signed release recipe. Example files intentionally contain zero root and
dependency placeholders. Never infer production values from them or add
`--private-key`; signer selection remains out of band.

The script deploys `LibFillerPayloadExternal` once, patches that one address
into both concrete Settler artifacts, deploys the implementation and Settlers,
deploys a zero-delay governance/trust timelock for the predicted Factory,
deploys the Factory and canonical settlement modules (`ApproveModule`,
`OwnerTokenPullModule`, `ScopedTransferModule`, `ScopedSplitModule`, and
`PostRolloverDstCptTransferModule`), approves both Settlers, hands roles to the
configured principals, and renounces all bootstrap authority. It then runs the
same Factory/Settler/timelock assertions used by `verify-deploy.s.sol`.
Re-running the same config against a finalized bootstrap performs verification
only.

Production singleton addresses are intentionally not recorded here. Publish one
shared inventory only after Ethereum, Base, and Arbitrum pass root/runtime,
parity, fork-rehearsal, and terminal-verification gates. Existing Base and
Arbitrum demo addresses remain legacy and are not relabeled.

### Verification invocation

```bash
FOUNDRY_PROFILE=deploy forge script script/verify-deploy.s.sol \
  --sig 'run()' \
  --rpc-url "$RPC_URL"
```

Gate 5 is a real, non-broadcast local simulation. Supply the public signed order
payload and expected balance deltas through the `FILL_*` inputs, then run:

```bash
FOUNDRY_PROFILE=deploy forge script script/verify-deploy.s.sol \
  --sig 'runWithFillSimulation()' \
  --rpc-url "$RPC_URL"
```

The gate first proves the identical payload fails from
`FILL_UNAUTHORIZED_FILLER`, then executes the atomic ExactSettler fill as
`FILL_FILLER`. It checks exact source debit, destination recipient credit,
premium debit and recipient credit, and preservation of the unused
`FILL_PREMIUM_CAP` remainder. It uses only public payload/signature bytes and
local caller impersonation; it never broadcasts the fill or reads private
material.

### Linked library requirement

`ExactSettler` and `PartialSettler` contain link references to
`src/libraries/LibFillerPayloadExternal.sol:LibFillerPayloadExternal`. The
repository entrypoint deploys it once and links both concrete Settler artifacts
to that address before any transaction is generated. The size gate proves only
that the linked runtime is EIP-170 compliant.

### Settler authority wiring

`ExactSettler` and `PartialSettler` use the same campaign authority mapping:

| Surface | Required principal |
|---|---|
| `owner()` / `ensOwner_` | dedicated display identity |
| `DEFAULT_ADMIN_ROLE` and `RECOVERY_ROLE` | zero-delay governance/trust timelock |
| `PAUSER_ROLE` | dedicated pause-only signer |
| `UNPAUSER_ROLE` | M1 |

The display identity is metadata only. It has no governance, attestation,
custody, deployer, pause, user, filler, or pilot-funding consequence. The
pause-only signer can pause but cannot unpause or acquire another authority by
virtue of that role. Both concrete Settlers must use the same checked mapping.

### Factory authority wiring

`CorkRolloverContractFactory` uses AccessControl for factory-wide operations.
The one-shot bootstrap temporarily holds only the roles needed to deploy and
approve the canonical Settlers. Finalization wires the exact campaign graph:

| Factory surface | Required principal |
|---|---|
| `owner()` | dedicated display identity |
| `DEFAULT_ADMIN_ROLE` | zero-delay governance/trust timelock |
| `DEFAULTS_MANAGER_ROLE` | zero-delay governance/trust timelock |
| `TRUST_CONFIG_DELAY_MANAGER_ROLE` | zero-delay governance/trust timelock |
| `SETTLER_APPROVER_ROLE` | zero-delay governance/trust timelock |
| `SETTLER_REVOKER_ROLE` | M2 |

M1 directly holds none of the four Factory/Settler administration surfaces. M1
may reach Factory administration, defaults, Settler approval, and Settler
admin/recovery only by scheduling and executing through the timelock. The zero
delay removes elapsed-time waiting, not the schedule/execute boundary or the
ability to inspect and cancel a scheduled operation before execution. M1's only
direct Rollover authorities are Settler unpause and the sole ERC-7484 attester
position (threshold `1`). M2's only direct Rollover authority is Settler
revocation. The treasury has pilot custody only and no protocol authority.

The same `TimelockController` is the Factory administration authority and the
factory's immutable trust-config timelock. It is initialized with exactly a
zero-second minimum delay. M1 holds its proposer, canceller, executor, and
administrative roles; the predicted Factory additionally holds proposer,
canceller, and executor roles so canonical trust-config queue/apply flows work.
Execution is not open to `address(0)`, and no campaign principal other than M1
may be an alternate timelock caller.

The Factory-governed delay-update flow remains
`queueTrustConfigDelayUpdate(newDelay)`, `cancelTrustConfigDelayUpdate()`, and
`applyTrustConfigDelayUpdate()`. The source-level protocol permits bounded
delay updates, but the campaign verifier requires the live delay to remain
exactly `0`; a queued update or a changed delay blocks release. Normal trust
configuration uses `queueFactoryDefaultTrustConfig` / `queueTrustConfig` /
`applyTrustConfig` / `cancelTrustConfig`.

`DEFAULTS_MANAGER_ROLE` can call `setDefaults(threshold, attesters, registry)`,
but because the role holder is the timelock, M1 cannot call it directly.
Existing rolloverContracts keep their deployment-time registry and live trust
config; `setDefaults` affects only future `deployRolloverContract()` calls.

Every configured principal is independently represented. Preflight fails
closed on any forbidden alias among M1, M2, treasury, pause signer, display
identity, governance signer, deployer, or ordered Safe owners. It also rejects
the deployer as a Safe owner or default attester. Final verification proves the
deployer and bootstrap own no Factory or Settler role and no ownership.

Canonical `ExactSettler` and `PartialSettler` deployments are the supported
default. `approveSettler` is an address/code allowlist, not a behavioral
verifier, so custom Settlers require explicit conformance approval before they
are added to the factory allowlist. That review must verify the canonical
settlement discipline end to end: srcCST predeposit into the rolloverContract,
dstCST delivery to the Settler, srcLeftover return/refund to the Settler, the
signed-settler pin used by the rolloverContract, and premium/dst release
semantics matching the canonical Settlers.

Before deploying the Factory, the script predicts its address from the bound
deployer and nonce, then deploys and configures the timelock for that address.
The Factory constructor enforces code presence and canonical Factory
proposer/canceller/executor wiring. The campaign verifier additionally enforces:

- `getMinDelay() == 0`;
- M1 has proposer, canceller, executor, and administrative roles;
- the predicted Factory has proposer, canceller, and executor roles;
- `address(0)` is not an executor;
- M2, treasury, pause signer, display identity, governance signer, deployer, and
  bootstrap have no timelock caller or administrative role;
- no trust-config delay update is queued.

OZ `AccessControl` is not enumerable, so the verifier checks every known
campaign principal and the deterministic deployment actors. Immutable
deployment evidence must also account for role-grant history before release.
Any direct M1 assignment to Factory admin/defaults/approval or Settler
admin/recovery, any alternate caller, or any live delay other than `0` fails
closed.

### Local fill rehearsal

Run `runWithFillSimulation()` against a fresh local Anvil snapshot after setting
all gate 0–4 variables and the gate-5 variables listed below. The script uses
`vm.prank` only in the local simulation and does not broadcast the fill:

```bash
FOUNDRY_PROFILE=deploy forge script script/verify-deploy.s.sol \
  --sig 'runWithFillSimulation()' \
  --rpc-url http://localhost:8545
```

### Env-var schema

| Name | Type | When required | Source of truth |
|---|---|---|---|
| `EXPECTED_CHAIN_ID` | uint256 | always | Chain ID of the manifest being verified; must equal the live `block.chainid`. |
| `FACTORY` | address | always | Factory deployment receipt. |
| `REGISTRY` | address | always | ERC-7484 registry address baked into the factory. |
| `EXACT_SETTLER` | address | always | ExactSettler operator expects on the allowlist. |
| `PARTIAL_SETTLER` | address | always | PartialSettler operator expects on the allowlist. |
| `PHOENIX_POOL_MANAGER` | address | always | Phoenix PoolManager identity that both Settlers must expose through their immutable `CORK_POOL_MANAGER()` getter. |
| `TRUST_CONFIG_TIMELOCK` | address | always | Shared zero-delay governance/trust `TimelockController` baked into the Factory; M1 actions still require schedule then execute. |
| `M1` | address | always | Expected sole direct attester/unpauser and sole campaign timelock controller. |
| `M2` | address | always | Expected direct Settler revoker. |
| `TREASURY` | address | always | Pilot treasury; expected to hold no protocol role. |
| `PAUSE_SIGNER` | address | always | Dedicated direct Settler pauser. |
| `DISPLAY_IDENTITY` | address | always | Expected `owner()` on Factory and Settlers; display-only. |
| `GOVERNANCE_SIGNER` | address | always | Public Safe owner identity; expected to hold no direct protocol or timelock role. |
| `DEPLOYER` | address | always | Exact public encrypted-keystore sender (`0xaCd3cda91582Ac9940Eaf94A5CCB8eD21671AFA8` on the paired Base/Arbitrum Shadow deployment lane); expected to hold no terminal role or ownership. |
| `DETERMINISTIC_ROOT` | address | always | Verified common EIP-2470 singleton-factory address used to CREATE2-deploy the bootstrap deployer. |
| `DETERMINISTIC_ROOT_CODEHASH` | bytes32 | always | Exact live root runtime hash for the release cohort. |
| `BOOTSTRAP_DEPLOYER_SALT` | bytes32 | always | Fixed salt used by the common root. |
| `BOOTSTRAP_DEPLOYER` | address | always | CREATE2 result from root, salt, and constructor-bound common authority; runtime and `DEPLOYMENT_AUTHORITY()` must match. |
| `BOOTSTRAP` | address | always | Chain-neutral CREATE2 result from the canonical bootstrap deployer and fixed bootstrap salt; must be initialized with exact config/artifact commitments, finalized, ownerless, and provenance-linked to the verified Factory. |
| `BOOTSTRAP_CONFIG_HASH` | bytes32 | always | Exact chain-local `CONFIG_HASH()` initialized atomically on the canonical bootstrap. |
| `DEPLOYMENT_ARTIFACTS_HASH` | bytes32 | always | Exact chain-local initcode commitment initialized atomically on the canonical bootstrap. |
| `EXPECTED_IMPL` | address | always | RolloverContract implementation address baked into the factory. |
| `BASE_FILLER_ENABLED` | bool | always | Enables terminal operational BaseFiller verification; defaults to `false`. |
| `BASE_FILLER` | address | when `BASE_FILLER_ENABLED=true` | Planned operational BaseFiller address. |
| `PHOENIX_CONTROLLER` | address | when `BASE_FILLER_ENABLED=true` | Phoenix controller immutable bound into BaseFiller. |
| `MARKET_REGISTRY` | address | when `BASE_FILLER_ENABLED=true` | Reconciled Market Registry immutable bound into BaseFiller. |
| `ROLLOVER_CONTRACT` | address | when verifying a specific cPT holder rolloverContract | `rolloverContractOf[cptHolder]` view on the factory. |
| `EXPECTED_CPT_HOLDER` | address | when `ROLLOVER_CONTRACT` is set | cPT holder EOA that called `deployRolloverContract()`. |
| `SRC_POOL_ID` / `DST_POOL_ID` | bytes32 | when verifying Phoenix selector | Phoenix `MarketId`. |
| `SRC_CST_TOKEN` / `DST_CST_TOKEN` | address | when pool ids set | CST share-token addresses. |
| `HOOK_TARGETS` | address[] (comma) | when verifying hook attestations | cPT holder's intended hook chain. |
| `HOOK_MODULE_TYPES` | uint256[] (comma) | parallel to `HOOK_TARGETS` | `Typehashes.MODULE_TYPE_*`. |
| `M01_FRESH_SETTLERS` | bool | always | Must be `true`: both concrete Settlers are fresh deployments. |
| `M01_FRESH_FACTORY` | bool | always | Must be `true`: the Factory is a fresh deployment. |
| `M01_FRESH_ROLLOVER_CONTRACTS` | bool | always | Must be `true`: verified RolloverContracts are fresh clones from the fresh Factory. |
| `M01_PROXY_OR_IN_PLACE_REUSE` | bool | always | Must be `false`: no proxy or in-place reuse of populated legacy storage. |
| `M01_LIVE_STATE_MIGRATION_SPEC` | bool | always | Must be `false` for this release: live-state migration is out of scope. |
| `FILL_EXACT_SETTLER` | address | gate 5 | Must equal the same `EXACT_SETTLER` whose Factory approval and authority shape passed gates 0-4; a separate fill-only Settler is rejected. |
| `FILL_FILLER` / `FILL_UNAUTHORIZED_FILLER` | address | gate 5 | Canonical funded/approved filler and a distinct negative-control caller. |
| `FILL_RECIPIENT` / `FILL_PREMIUM_RECIPIENT` | address | gate 5 | Expected destination-asset and premium recipients. |
| `FILL_SOURCE_TOKEN` / `FILL_DESTINATION_TOKEN` / `FILL_PREMIUM_TOKEN` | address | gate 5 | Real local token contracts used by the signed order. |
| `FILL_ORDER_ID` | bytes32 | gate 5 | Canonical order digest. |
| `FILL_ORIGIN_DATA` / `FILL_FILLER_DATA` | bytes | gate 5 | Public signed ERC-7683 order payload and atomic filler envelope; never a private key. |
| `FILL_EXPECTED_SOURCE_DEBIT` / `FILL_EXPECTED_DESTINATION_CREDIT` | uint256 | gate 5 | Exact source-filler debit and destination-recipient credit. |
| `FILL_EXPECTED_PREMIUM_DEBIT` / `FILL_EXPECTED_PREMIUM_RECIPIENT_CREDIT` | uint256 | gate 5 | Exact premium accounting deltas. |
| `FILL_PREMIUM_CAP` | uint256 | gate 5 | Signed cap; the gate proves the unused remainder stays with the filler. |

### Gates

| # | Name | Finding discharged | What it staticcalls |
|---|---|---|---|
| 0 | Greenfield readiness | M-01 | No chain reads. Requires `M01_FRESH_SETTLERS=true`, `M01_FRESH_FACTORY=true`, `M01_FRESH_ROLLOVER_CONTRACTS=true`, `M01_PROXY_OR_IN_PLACE_REUSE=false`, and `M01_LIVE_STATE_MIGRATION_SPEC=false`. |
| 1 | Factory and authority shape | F-D2 | Pairwise-distinct nonzero campaign authorities; root runtime and CREATE2 root→deployer→bootstrap provenance; exact deployer authority; chain-neutral initialized/finalized bootstrap with exact commitments and zero owner; Factory address derived from shared bootstrap nonce 6; bootstrap-recorded Factory runtime; Factory implementation/registry/defaults; both approved Settlers; exact zero-second timelock delay; canonical Factory and M1 timelock roles; no open/alternate callers or pending delay update; delayed Factory/Settler roles held only by the timelock; M2 revoker; pause-only signer; M1 unpauser; display-only ownership; and terminal-zero deployer/bootstrap roles. |
| 2 | RolloverContract shape | F-D5 | `rolloverContractConfig(rolloverContract)` — owner, registry mirror, attester parity; pending-trust quiescence via `factory.pendingTrustConfig(rolloverContract) == (0, [], 0)`. |
| 3 | Phoenix selector | F-D3 | `IPoolShare.poolId`, `IPoolShare.poolManager`, `IPoolManager.shares`. |
| 4 | Attestation reachability | F-D4 (HIGH) | `IERC7484.check(target, moduleType)` per hook target with `msg.sender == rolloverContract`. |
| 5 | End-to-end fill (opt-in) | F-D8 (HIGH) | Requires `FILL_EXACT_SETTLER == EXACT_SETTLER`, proves the configured unauthorized caller cannot use the signed payload, executes the atomic `ExactSettler.fill(...)` locally, and checks exact source debit, destination credit, premium debit/credit, and premium-cap remainder preservation. |

### Exit codes

- `0` — every configured gate passed; `VerifyDeploy__AllGatesPassed` event
  emitted. Release-ready.
- Non-zero — at least one gate reverted. The revert selector names the
  failing gate; map to the failure-mode table in §10.

## 5. Domain-by-domain detail

### 5.1 Phoenix-side

#### Pool publication and `shares(MarketId)` selector

Each `(src, dst)` CST pair the rolloverContract will roll between MUST be live in the
Phoenix pool registry and resolvable from the CST token surface
(`IPoolShare(token).poolManager()`, `IPoolShare(token).poolId()`, and
`IPoolManager(pm).shares(poolId)`). The rolloverContract's `_siblingCptToken` uses
this getter on every rollover leg to derive the sibling CPT (principal
token) — there is no fallback selector. A phoenix build that lacks the
`shares` view, or returns a zero principal token, reverts the rolloverContract's
staticcall with `CorkRolloverContract__PoolManagerCallFailed(IPoolManager.shares.selector, ...)`.

Gate 3 of `verify-deploy.s.sol` enforces this against the live phoenix
bytecode before the genesis fill is broadcast.


#### Phoenix dependency policy (M-04)

M-04 is remediated as a deployment-policy dependency check, not as a Cork
runtime manager-pinning change. Cork relies on Phoenix `PoolShare.poolManager`
immutability (PoolShare.poolManager immutability): the CST/CPT share token's
manager is fixed when the share token is deployed, and Gate 3 verifies the
live `poolManager()` plus `IPoolManager.shares(poolId)` selector before release.

Cork also relies on Phoenix upgrade governance for the UUPS-upgradeable
`CorkPoolManager`. A Phoenix manager upgrade that changes `deposit` /
`previewDeposit` collateral accounting, share minting, pool lookup, or
share-token authority is a dependency change and MUST be reviewed before
Rollover uses the affected markets.

Phoenix collateral used by Rollover MUST be standard no-fee ERC-20
collateral. Unsupported collateral includes fee-on-transfer, rebasing,
deflationary, or otherwise balance-mutating behavior unless separately reviewed
and approved for the specific Phoenix market and Rollover flow. This policy is
the M-04 remediation boundary: no Cork runtime manager-pinning change is included.

### 5.2 ERC-7484 attester registry

#### Default-attester seed at `initialize`

`CorkRolloverContractFactory.deployRolloverContract()` calls `ICorkRolloverContract(rolloverContract).initialize(...)`,
which mirrors `(threshold, attesters)` into the rolloverContract's `liveTrust*` slots
AND calls `IERC7484(registry).trustAttesters(threshold, attesters)` against
the rolloverContract's own address. This seeds the rolloverContract's smart-account record
inside the Rhinestone registry. If the registry call reverts (wrong address,
ABI drift, paused), `initialize` reverts and `deployRolloverContract()` reverts
atomically — the failure is loud at construction time. There is no Cork-side
registry bypass or cached-success fallback: hook execution is fail-closed when
the registry cannot validate a required module attestation.

#### Attestation publication MUST follow deployment and precede first fill

The `trustAttesters` seed call is necessary but NOT sufficient. Holder clone
trust configuration is separate from module registration and attestation.
After deployment, each reviewed module must be registered and M1 must publish
an attestation for the exact Cork-local bucket: pre `5`, mid `6`, post `7`, or
premium `8`. The legacy `0xc0c0_0001..0xc0c0_0004` values cannot be packed by
the deployed Registry.

Gate 4 of `verify-deploy.s.sol` proves the configured
attester→hook→bucket composition for each supplied hook. Before first fill,
operators must exercise that exact-context `check(...)` for every module used
by the order; a trust seed, registration receipt, or attestation transaction
alone is not readiness evidence.

#### Delegatecall hook deployment policy (M-03)

The rolloverContract executes hook targets with `delegatecall`, so delegatecall hooks
are privileged trusted modules by design. Attestation is an authorization
boundary, not a bytecode sandbox: module code runs in the rolloverContract storage frame.

Production attestations MUST be limited to immutable, reviewed, storage-safe hook modules.
Their bytecode and storage behavior must be reviewed against the rolloverContract storage
layout. By default, upgradeable/proxy hook targets are disallowed unless the risk
owner records explicit risk acceptance before attestation and release.

### 5.3 Cork factory allowlist

#### `approveSettler` is the first-order-flow gate

`CorkRolloverContractFactory.executeIntentHooks` checks
`approvedSettlers[msg.sender]` on every dispatch. The check fires on every
fill. `deployRolloverContract()` does NOT auto-approve any Settler — the admin MUST
call `factory.approveSettler(canonicalSettler)` for every Settler that will
dispatch `executeIntentHooks` BEFORE the first order can flow. The approved
address must already have deployed bytecode; EOAs and self-destructed
addresses are rejected. The factory does not verify a Settler interface, so the
operator must approve the canonical deployed Settler contracts. Repeating an
approval is idempotent and still emits `SettlerApproved`.

#### Atomic Settler migration is a MUST

A v1 → v2 Settler migration MUST land in a single admin transaction:
`approveSettler(v2); revokeSettler(v1)` in one Safe / multisig batch. A
two-tx migration leaves a gap window in which in-flight orders may route
through either Settler depending on tx interleaving; fillers in the mempool
during that window hit `SettlerNotApproved` on v1.

Safe (Gnosis Safe) tx-builder JSON example for an atomic migration:

```json
{
  "version": "1.0",
  "chainId": "1",
  "createdAt": 1779000000000,
  "meta": { "name": "Cork Settler v1->v2 atomic migration" },
  "transactions": [
    {
      "to": "<factory>",
      "value": "0",
      "data": "0x<encoded approveSettler(v2)>",
      "contractMethod": {
        "name": "approveSettler",
        "inputs": [{ "name": "settler", "type": "address" }],
        "payable": false
      },
      "contractInputsValues": { "settler": "<v2-settler>" }
    },
    {
      "to": "<factory>",
      "value": "0",
      "data": "0x<encoded revokeSettler(v1)>",
      "contractMethod": {
        "name": "revokeSettler",
        "inputs": [{ "name": "settler", "type": "address" }],
        "payable": false
      },
      "contractInputsValues": { "settler": "<v1-settler>" }
    }
  ]
}
```

Discharges F-D7.

## 6. cPT holder onboarding

The deployment model is **cPT holder**: the cPT holder holds the
CWIA `owner` slot and is the sole intent-signing key.

### `deployRolloverContract()`

The cPT holder (an EOA or multisig) calls `factory.deployRolloverContract()`. The factory:

1. Reverts if `rolloverContractOf[owner] != address(0)` (one rolloverContract per cPT holder per
   factory deployment).
2. Clones `ROLLOVER_CONTRACT_IMPLEMENTATION` via OZ
   `Clones.cloneDeterministicWithImmutableArgs` with a domain-separated
   owner salt and a 60-byte trailer encoding `owner ‖ factory ‖ erc7484Registry`.
3. Invokes the clone's `initialize(DEFAULT_TRUST_THRESHOLD, _defaultAttesters)`
   atomically inside the same transaction. The clone reads its ERC-7484
   registry from the CWIA trailer rather than as an `initialize` argument.

`factory.predictRolloverContractOf(owner)` returns the same address before
deployment. Cross-chain same-address parity is not based on `chainid`; it
requires the same CREATE2 deployer/factory address, rolloverContract
implementation address, owner, and live ERC-7484 registry address.

### Atomic `initialize` seed

`CorkRolloverContract.initialize` mirrors the factory defaults into the rolloverContract's
`liveTrust*` slots AND forwards them to `IERC7484.trustAttesters`. The
rolloverContract's smart-account record inside the registry starts seeded out-of-the-box;
the cPT holder does NOT need to call `factory.queueTrustConfig(...)` for the
first dispatch to succeed.

### First-order readiness checklist

Before the cPT holder signs the genesis intent, every gate in `script/verify-deploy.s.sol`
MUST exit 0 against the target chain. Specifically:

- Gate 1 — factory allowlist includes both ExactSettler and PartialSettler.
- Gate 2 — `factory.pendingTrustConfig(rolloverContract) == (0, [], 0)`.
- Gate 3 — Phoenix `shares(MarketId)` resolves for every pool the cPT holder intends
  to roll between.
- Gate 4 — every hook target is attested for its bucket against the rolloverContract's
  seeded smart-account record. RolloverContracts that intend to support **cross-CA
  rollover** (src and dst pools backed by different collateral assets — e.g.
  USDC and DAI) MUST additionally have a reference SwapModule deployed and
  attested under `MODULE_TYPE_MID_ROLLOVER_HOOK`. The SwapModule is a
  delegatecall hook the cPT holder signs into `midRolloverHooks` to swap caSrc → caDst
  between `unwindMint` and `deposit`; end-to-end value is bounded by the
  cPT-holder-signed `params.minSharesOut` floor (`INV-DST-FLOOR`). Same-CA rolloverContracts
  do not require a mid-hook attestation. Reference SwapModule implementations
  are out of scope for this contract release; Cork ops attests cPT-holder-supplied
  modules under standard ERC-7484 attestation flow.

## 7. Optional cPT holder trust-config update

A cPT holder that wants to update their own deployed rolloverContract's trust config uses the
external per-rolloverContract trust-config `TimelockController` path. Owner-side queue and
cancel entrypoints derive the rolloverContract from `rolloverContractOf[msg.sender]`; permissionless
apply and filler/keeper views still take an explicit `rolloverContract`. There are two
queue entrypoints and both share the same delay / cancel / apply lifecycle:

- Safe/default path:
  `factory.queueFactoryDefaultTrustConfig()` — cPT holder (rolloverContract `owner`) only.
  Snapshots the factory's current live `DEFAULT_TRUST_THRESHOLD()` and
  `defaultAttesters()` at queue time, then schedules those values. This is not
  automatic following of future defaults; if `setDefaults` changes later, the
  queued config remains the earlier snapshot and the cPT holder must queue again to use
  newer defaults.
- Advanced/custom path:
  `factory.queueTrustConfig(threshold, attesters)` — cPT holder (rolloverContract
  `owner`) only. Schedules caller-supplied values after validating the complete
  replacement config.
- Both queue paths schedule a timelock op with the trust-config timelock's
  current configured delay and mirror `(salt, threshold,
  attesters)` into the factory's `pendingConfig[salt]` / `lastSalt[rolloverContract]`
  state. Re-queueing by either path cancels any prior pending op for this rolloverContract
  and resets the trust-config timelock clock. If an extra proposer pre-scheduled
  the exact factory operation, the factory cancels it before scheduling the
  owner queue so the delay starts from the owner queue transaction.
- `factory.applyTrustConfig(rolloverContract)` —
  **permissionless** once the timelock delay elapses. Loads `(threshold,
  attesters)` and the queued salt from the factory mirror, sets the exact
  expected operation id for this execution frame, then routes through
  `relayTrustConfig(rolloverContract, salt, threshold, attesters)` →
  `ICorkRolloverContract.setTrustConfig`. Direct timelock execution and stale or
  malicious raw timelock operations fail closed because the relay requires the
  pending salt and the apply-frame op id.
- **Owner-side abort:** `factory.cancelTrustConfig()` — cPT holder only.
  Cancels the pending timelock op for the caller's own rolloverContract and clears the
  factory mirror in a single tx.

### First fill follows first apply

The trust-config timelock address is immutable. The protocol source supports a
bounded Factory-governed delay-update path, but this campaign fixes the live
delay at exactly zero seconds. A queued delay update or any nonzero live delay
blocks Gate 1. Each trust-config operation still completes the full
schedule/execute path before apply and before the next release check. There is
no elapsed-time observation window; operational review and cancellation must
occur between the explicit scheduling and execution transactions.

`factory.pendingTrustConfig(rolloverContract)` is intentionally a Factory mirror plus
timelock timestamp view:

- `threshold` / `attesters` are the Factory-mirrored pending trust config.
- `effectiveAt` is `trustConfigTimelock.getTimestamp(opId)` for the mirrored
  operation.
- `(0, [], 0)` means no Factory pending mirror exists.
- `(nonzero config, effectiveAt > 0)` means a Factory pending mirror exists and
  the corresponding timelock op exists.
- `(nonzero config, effectiveAt == 0)` means the Factory pending mirror exists
  but the timelock op is absent, done, or unset. This is mirror/timelock
  divergence, usually from direct external timelock cancellation. The owner
  should call `factory.cancelTrustConfig()` or requeue to recover.

**Gate 2 acceptance criterion:** `factory.pendingTrustConfig(rolloverContract) == (0, [], 0)`.
`effectiveAt == 0` alone is not sufficient, and `block.timestamp >= effectiveAt + 60s`
is not sufficient while the queued config remains unapplied.

Gate 2 proves no pending Factory mirror exists. It does not prove historical
observation time after a recently applied trust-config change. If a trust-config
change was recently applied, operators should inspect live `getMinDelay()`: wait
that window when nonzero, then rerun verification; when it is zero, no nonzero
observation window exists. F-D5 discharged.

## 8. Kill-switch matrix

| Lever | Mechanism | Latency | Role required |
|---|---|---|---|
| `factory.revokeSettler(settler)` | Removes a Settler from the allowlist; the next factory dispatch from that Settler fails before rolloverContract execution. | Instant. | `SETTLER_REVOKER_ROLE` on factory. |
| `settler.pause()` / `unpause()` | OZ Pausable; all state-changing entrypoints reject when paused. | Instant. | `PAUSER_ROLE` / `UNPAUSER_ROLE` on Settler (split). |
| `factory.queueFactoryDefaultTrustConfig()` / `factory.queueTrustConfig(...)` | Stages an attester-set change for the caller's own deployed rolloverContract on the external per-rolloverContract trust-config `TimelockController` behind its configured delay. The default path snapshots current factory defaults at queue time; the custom path uses caller-supplied values. | Trust-config timelock `minDelay`. | RolloverContract `owner` (the cPT holder). |

**DO NOT** confuse these:

- `revokeSettler` is the only Cork-side lever that immediately severs the
  dispatch surface for ALL rolloverContracts deployed by this factory.
- `pause()` / `unpause()` is Settler-scoped, not factory-scoped — pausing
  Settler v1 does NOT pause Settler v2 even when both are approved.
- Factory trust-config queueing is per-rolloverContract; one rolloverContract's queue does not
  affect another rolloverContract's live attesters.

## 9. Version migration

### Settler v1 → v2 (atomic)

`approveSettler(v2); revokeSettler(v1)` in a single admin tx — see the Safe
tx-builder JSON example in §5.3. Mandatory; two-tx migration leaks the
in-flight order window.

### PR #66 ABI break checklist

Split-settler deployments are a hard ABI break for downstream fillers and
operators:

- `fillerData` has one accepted shape: the canonical 10-field payload
  `(phase, fillAmount, premium, destination, premiumFor, intent, minDstPerSrc,
  fillerAuthSig, subFiller, cptHolderSig)`. The legacy payload shape
  without `premiumFor` is rejected by `LibFillerAuth.decodePayload`.
- PREMIUM payloads must set `premiumFor` to the recorded rollover filler.
  ROLLOVER payloads must set `premiumFor` to zero.
- `BaseFiller` / `EvcRolloverAdapter` deployments now wire both
  `EXACT_SETTLER` and `PARTIAL_SETTLER`; downstream constructor arguments and
  deployment scripts must be updated accordingly.
- Release gates must verify both settlers are approved on the factory. A
  deployment that only configures the former single `SETTLER` /
  `CANONICAL_SETTLER` address is incomplete.

### Factory v1 → v2 (new deployment)

Each `CorkRolloverContractFactory` deployment binds one immutable
`ROLLOVER_CONTRACT_IMPLEMENTATION`. A new rolloverContract version ships as a new factory
deployment. The cPT holder redeploys their rolloverContract through factory v2 under the same
EOA and receives a fresh `rolloverContractOf[cptHolder]` slot in v2; the v1 binding remains
in place as legacy state. Off-chain infrastructure resolves the active
rolloverContract by querying the version-of-record factory address.

The module-type correction changes `CorkRolloverContract` creation/runtime
bytecode and therefore its CREATE2 implementation address. The Factory's
constructor-bearing initcode and runtime immutable binding change, while its
CREATE-derived address formula remains sender-and-nonce based; an occupied old
Factory runtime is rejected rather than reused. CWIA clone initcode embeds the
implementation address, so every predicted holder clone address changes.
Deployment artifact commitments change accordingly. Exact/Partial Settler and
standalone module source bytecode do not change from this correction.

### cPT holder key compromise

cPT holder key compromise inside a single factory is **irrecoverable on-chain**:
`rolloverContractOf[cptHolder]` has no admin reset path, and the compromised EOA can sign
valid intents against its own legacy rolloverContract indefinitely. Mitigations:

- Factory revoker calls `revokeSettler(compromisedSettler)` against every
  Settler the compromised key has authorised; the factory is default-deny,
  so revocation is instant and any future re-approval is a separate approver
  action.
- cPT holder redeploys under a fresh EOA against the next rolloverContract-version factory
  (only possible when a new factory is released).
- Accept the burn — the compromised rolloverContract's funds-routing decisions remain
  under attacker control; the rest of the protocol is unaffected.

Operators planning long-lived deployments should treat the rolloverContract binding
as scoped to factory-version cadence, NOT to the cPT holder EOA's operational
lifetime.

## 10. Failure-mode table

Indexed by the first revert selector an operator will see during a botched
deployment. Every Cork-specific selector here (the `CorkRolloverContract*` and
`CorkRolloverContractFactory*` ones) is greppable in `src/`; the `VerifyDeploy__*`
selectors live in `script/verify-deploy.s.sol`, and `TimelockController.*` /
`EnforcedPause` are OpenZeppelin selectors.

| Selector | Root cause | Recovery |
|---|---|---|
| `CorkRolloverContractFactory__SettlerNotApproved(addr)` | Genesis Settler approval missing. | Approve both ExactSettler and PartialSettler from factory admin. |
| `CorkRolloverContractFactory__AddressHasNoCode(addr)` | Attempted to use an EOA or undeployed contract where Factory expects code. | Deploy the target contract first, then retry. |
| `CorkRolloverContractFactory__UnknownRolloverContract(addr)` | RolloverContract address typed wrong, or wrong factory. | Read `rolloverContractOf[cptHolder]` from the correct factory. |
| `CorkRolloverContractFactory__PhaseNotDispatchable(uint8)` | Settler sent a phase other than ROLLOVER / PREMIUM. | Settler bug — not a deploy issue; escalate. |
| `CorkRolloverContract__SettlerMismatch` | Factory's `originatingSettler()` doesn't match `ctx.originSettler`. | Latch poisoning from an unexpected settler; escalate. |
| `CorkRolloverContract__SignedSettlerOriginMismatch(s, o)` | Signed `orderData.rolloverParams.settler != ctx.originSettler` (INV-PARAMS-SETTLER-PIN). | Settler-side payload-build bug or stale signed order. |
| `CorkRolloverContract__ModuleTypeMismatch(target, mt)` | Hook target not attested for the bucket the rolloverContract is calling. | Attester publishes attestation; or cPT holder signs a different hook chain. |
| `CorkRolloverContract__PoolManagerCallFailed(selector, data)` | `selector == shares.selector` → Phoenix `shares(MarketId)` not available or returns zero principal. | Verify phoenix build; verify pool published; verify CST→pool binding. |
| `CorkRolloverContract__SrcPoolIdMismatch` / `DstPoolIdMismatch` | cPT-holder-signed `srcPoolId`/`dstPoolId` doesn't match `IPoolShare(token).poolId()`. | cPT holder re-signs with correct pool IDs. |
| `CorkRolloverContract__BadIntentSignature` | Intent signed by non-owner, or owner rotated mid-flight without ERC-1271 cover. | cPT holder re-signs. |
| `TimelockController.TimelockUnexpectedOperationState` | `factory.applyTrustConfig` called before the external trust-config timelock delay elapsed. | Wait. |
| `CorkRolloverContractFactory__NoQueuedTrustConfig(rolloverContract)` | `factory.applyTrustConfig` / `cancelTrustConfig` called for a rolloverContract with no pending queue. | No-op or re-queue. |
| `CorkRolloverContractFactory__MismatchedApplyArgs(expectedSalt)` | Relay calldata/salt does not match the factory pending mirror, a stale/malicious/direct timelock callback was attempted, or the factory/timelock operation identity diverged. | Re-read `factory.pendingTrustConfig(rolloverContract)` and use canonical `factory.applyTrustConfig(rolloverContract)`. If mirror/timelock state diverged because an external canceller unset the op, the owner should call `factory.cancelTrustConfig()` or requeue. |
| `EnforcedPause` (OZ Pausable) | Settler paused. | Unpauser action; not a deploy issue. |
| `VerifyDeploy__FactoryShapeMismatch(field, ...)` | Gate 1 found a factory-state divergence. | Re-check factory deployment receipts vs operator inputs. |
| `VerifyDeploy__SettlerAuthorityCollapsed(ensOwner, admin, pauser, unpauser)` | Gate 1 received a collapsed authority shape. | Restore the exact display identity / timelock admin / pause signer / M1 unpause split. |
| `VerifyDeploy__SettlerAuthorityMismatch(settler, field, ...)` | Gate 1 found a missing expected Settler role or a forbidden extra role. | Reconcile the Settler with the exact campaign authority graph; do not add an alias or bypass. |
| `VerifyDeploy__RolloverContractShapeMismatch("pendingTrustConfig", ...)` | Gate 2 found a pending or divergent trust-config Factory mirror. The verifier requires `factory.pendingTrustConfig(rolloverContract) == (0, [], 0)`; nonzero threshold/attesters with `effectiveAt == 0` means mirror/timelock divergence. | Apply an intentional ready queue through the canonical zero-delay schedule/execute path, then rerun verification. If divergent/stale, the owner cancels or requeues through the canonical Factory path. |
| `VerifyDeploy__RolloverContractShapeMismatch(field, ...)` | Gate 2 found another rolloverContract-state divergence. | Re-check cPT holder, registry mirror, and live attester parity against deployment inputs. |
| `VerifyDeploy__PhoenixSelectorUnavailable(selector, data)` | Gate 3 — `shares(MarketId)` reverted or returned zero principal. | Phoenix admin publishes / re-binds the pool. |
| `VerifyDeploy__AttestationMissing(target, moduleType)` | Gate 4 — registry rejected `(rolloverContract, target, moduleType)`. | Attester publishes the missing attestation. |
| `VerifyDeploy__FillSimulationFailed(reason)` | Gate 5 rejected incomplete inputs, accepted the negative-control caller, observed a wrong balance delta, or failed the real atomic fill. | Fix the public `FILL_*` payload/expectations or the deployed address/role wiring, then rerun the local simulation. |

## 11. Glossary disambiguation

- **"Attester."** ERC-7484 attesters (the addresses in `liveTrustAttesters`)
  — NOT the EIP-712 signers on intents (the cPT holder owner). The factory's
  `defaultAttesters()` seeds the rolloverContract's smart-account record at
  `initialize`. The rolloverContract checks the cPT-holder signature over `orderDigest`
  against `owner()` on every hook dispatch.
- **"Settler."** The Cork `Settler` contract (the ERC-7683-shaped origin /
  destination settler) — NOT an OZ Pauseable role-holder. The factory's
  `approvedSettlers` allowlist refers to contract addresses, not EOAs.
- **"Pool."** Phoenix `MarketId` (the bytes32) — NOT the CST share token
  (the ERC-20). `IPoolShare(token).poolId()` is the bridge from CST→MarketId.

## 12. Appendix — ABI and events

### `RolloverIntent` (8 fields)

```
struct RolloverIntent {
    address rolloverContract;
    bytes32 orderDigest;
    uint64  deadline;
    uint64  nonce;
    Call[]  preRolloverHooks;
    Call[]  midRolloverHooks;
    Call[]  postRolloverHooks;
    Call[]  premiumHooks;
}
```

### `RolloverParams` (7 fields)

```
struct RolloverParams {
    address srcCstToken;
    address dstCstToken;
    uint256 minCaReceived;
    uint256 minSharesOut;
    bytes32 srcPoolId;
    bytes32 dstPoolId;
    address settler;
}
```

`HookPhase` enum is `{ROLLOVER, PREMIUM}` — no migration shim is shipped.

### Critical events

- `CorkRolloverContractFactory.SettlerApproved(settler)` / `SettlerRevoked(settler)`
  — allowlist transitions; gate 1 cares.
- `CorkRolloverContractFactory.TrustConfigQueued(rolloverContract, opId, threshold, attesters, effectiveAt)` /
  `TrustConfigApplied(rolloverContract, opId, threshold, attesters)` — trust-config window
  transitions; gate 2 cares.
- `VerifyDeploy.VerifyDeploy__AllGatesPassed(factory, rolloverContract, fillSimulationRan)`
  — emitted by the release script when every configured gate has passed.
