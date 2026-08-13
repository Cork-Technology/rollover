# Cork Rollover — ERC and External Dependency Map

> _Supplementary protocol reference. The canonical bundle for AI auditors is [`docs/agent-context/`](../../agent-context/README.md). Code in `src/` is the source of truth when docs disagree._

Cross-cutting reference of the Ethereum standards and external libraries consumed by this repo, with verbatim canonical quotes, per-ERC conformance/deviation tables, and version pins for each external dependency. All citations grounded in current `src/`.

Source pointers are absolute paths within the worktree. Where the protocol diverges from a standard, the deviation is called out explicitly with a rationale (Why) drawn from in-source NatSpec.

Scope note: `src/EvcRolloverAdapter.sol` is excluded from the current audit
scope. EVC / Permit2 details below are adapter-specific context only unless a
shared-code issue affects in-scope contracts.

---

## Build / library version pins

| Source | Pin | Mechanism |
|---|---|---|
| `solc` | `0.8.34` | `foundry.toml:7` |
| `evm_version` | `cancun` | `foundry.toml:24` |
| `via_ir` | `false` | `foundry.toml:20` |
| `optimizer_runs` | `200` | `foundry.toml:22` |
| OpenZeppelin Contracts | submodule `5fd1781b1454fd1ef8e722282f86f9293cacf256` | `.gitmodules:4-6`, `git ls-tree HEAD lib/` |
| forge-std | submodule `620536fa5277db4e3fd46772d5cbc1ea0696fb43` | `.gitmodules:1-3`, `git ls-tree HEAD lib/` |
| permit2 | submodule `cc56ad0f3439c502c246fc5cfcc3db92bb8b7219` | `.gitmodules:7-9`, `git ls-tree HEAD lib/` |

Remappings (`remappings.txt`):

```
forge-std/=lib/forge-std/src/
@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/
openzeppelin-contracts/=lib/openzeppelin-contracts/contracts/
permit2/=lib/permit2/src/
permit2-test/=lib/permit2/test/
```

No `package.json`, no npm pin — OZ is consumed exclusively via git submodule. The two remapping aliases (`@openzeppelin/contracts/` and bare `openzeppelin-contracts/`) both resolve to the same `lib/openzeppelin-contracts/contracts/` tree; src/ uses the `@openzeppelin/contracts/` form exclusively (`rg -n '@openzeppelin' src/`).

The submodule SHA `5fd1781b` is the authoritative pin; the exact released OZ tag at that SHA is not separately recorded here.

---

## ERC-7683 — Cross-Chain Intents

**Version pin:** pre-resolver-redesign EIP draft (no semver), specifically
`ethereum/ERCs` `ERCS/erc-7683.md` at commit
`dfc90d9274c17977b8bad021ae1207f71c339266`. This is the parent of redesign
commit `96d110fbbe7042b061064833edaf8fa2cf5db195` from 2026-05-13, and it is
the draft implemented by the vendored local interfaces at
`src/interfaces/external/erc7683/IOriginSettler.sol` +
`IDestinationSettler.sol`. Cork does not implement the current live
resolver-centric ERC-7683 text.
**Used in:** `src/BaseSettler.sol, src/ExactSettler.sol, and src/PartialSettler.sol`, `src/types/RolloverTypes.sol`, `src/libraries/LibRolloverOrder.sol`, `src/libraries/Typehashes.sol`.
**Purpose:** Cross-chain intent envelope + filler-side destination settlement. Cork uses ERC-7683 as the canonical wire format for rollover orders.
**ABI risk:** HIGH — any change to `OrderData` field set/order is a wire-format break; in-flight `Open` events under the old typehash become unresolvable.
**Cork-specific extensions:** see Deviations below.

### Canonical text
Canonical source for this repo is the ERC-7683 text at:
<https://github.com/ethereum/ERCs/blob/dfc90d9274c17977b8bad021ae1207f71c339266/ERCS/erc-7683.md>.
The live page at <https://eips.ethereum.org/EIPS/eip-7683> has since moved to
resolver-centric wording and is not the version implemented here.

> A compliant origin settler contract implementation MUST implement the `IOriginSettler` interface.

> A compliant destination settlement contract implementation MUST implement the `IDestinationSettler` interface.

The two `IOriginSettler` order envelopes — `GaslessCrossChainOrder` (off-chain-signed) and `OnchainCrossChainOrder` (on-chain-initiated) — are consumed by `openFor` and `open` respectively; each settler entry-point is bound to one envelope shape by the standard's interface signatures (paraphrased — not a verbatim normative clause).

The canonical `IOriginSettler` surface defined by that pinned ERCs commit comprises `open(OnchainCrossChainOrder)`, `openFor(GaslessCrossChainOrder, bytes signature, bytes originFillerData)`, `resolve(OnchainCrossChainOrder)`, `resolveFor(GaslessCrossChainOrder, bytes originFillerData)`, plus the `Open(bytes32 orderId, ResolvedCrossChainOrder resolvedOrder)` event. The destination surface is a single method `fill(bytes32 orderId, bytes originData, bytes fillerData)`.

### Conformance in this repo
- Origin-settler surface declared at `src/interfaces/external/erc7683/IOriginSettler.sol` and implemented by the concrete Settlers through `BaseSettler`, `ExactSettler`, and `PartialSettler`. The origin entry points are the methods from that pinned ERCs commit: on-chain `open(OnchainCrossChainOrder)` / `resolve(OnchainCrossChainOrder)` and gasless `openFor(GaslessCrossChainOrder,bytes,bytes)` / `resolveFor(GaslessCrossChainOrder,bytes)`. The umbrella `ISettler` (`src/interfaces/settlers/ISettler.sol`) composes `IOriginSettler` + `IDestinationSettler`.
- Destination-settler surface declared at `src/interfaces/external/erc7683/IDestinationSettler.sol` (single-method `fill`).
- Order envelope types match ERC-7683 names from that pinned ERCs commit: `OnchainCrossChainOrder`, `GaslessCrossChainOrder`, `ResolvedCrossChainOrder`, `Output` (identifiers are 20-byte addresses left-padded into `bytes32` per the EIP), and `FillInstruction` (`destinationChainId` remains `uint256` under that pin).
- `OUTPUT_TYPEHASH` at `src/libraries/Typehashes.sol:58-59` matches the EIP canonical: `"Output(bytes32 token,uint256 amount,bytes32 recipient,uint256 chainId)"`.
- `orderDataType` is Cork's `OrderData` EIP-712 typehash (`Typehashes.ORDER_DATA_TYPEHASH`), so ERC-7683 envelopes identify the signed order-data schema directly.
- `orderData` bytes must be the canonical static ABI encoding of Cork `OrderData`; decoders reject ABI-decodable blobs with trailing data.
- `Open` event emitted via the ERC-7683 `IOriginSettler` surface inherited by `ISettler`.
- Resolved-order output recipients are filler-perspective projections: `maxSpent[0]`
  sends source cST to the rollover contract, while `minReceived[0]` uses
  `bytes32(0)` because the final dstCST filler recipient is not known until fill
  data is supplied.
- `resolve` / `resolveFor` are state-aware view projections. `None` orders still
  enforce the open-deadline admission ceiling; already-`Opened` orders skip only
  that gate and remain resolvable until `fillDeadline`, subject to non-time
  envelope validation and terminal/Closing status exclusions.

### Deviations
1. **`originFillerData` is ignored.** Filler authorisation is moved entirely to fill-time via `FillerAuth` EIP-712 commitments inside `fillerData` (see ERC-1271 deviation below).
2. **`orderDataType` is Cork's schema typehash.** `LibRolloverOrder` constrains accepted payloads to the rollover `OrderData` schema only — no generic multi-schema routing.
3. **`orderId` ≡ EIP-712 `orderDigest` of `OrderData`.** `src/libraries/LibSettlerHashing.sol` makes the canonical ERC-7683 order identifier the same value used for signature authentication.

### Migration / upgrade notes
- `ORDER_DATA_TYPEHASH` at `src/libraries/Typehashes.sol:18-20` is a 20-field shape embedding the 7-field `RolloverParams`. Any change to `OrderData` field set/order is a wire-format break.
- `originFillerData` is currently dead-bytes — adding semantics later is a non-break for relayers passing `0x`.
- Migrating to the live resolver-centric ERC-7683 text is a standards upgrade,
  not a documentation-only change. It would require explicit interface,
  resolver, event, and integration review.

---

## ERC-7484 — Module Registry (Rhinestone)

**Version pin:** Vendored interface — no submodule. Canonical reference: <https://github.com/rhinestonewtf/registry>.
**Used in:** `src/CorkRolloverContract.sol`, `src/libraries/Typehashes.sol`, `src/interfaces/external/erc7484/IERC7484.sol`.
**Purpose:** Per-batch hook-target attestation. Cork attests every module called inside `executeIntentHooks` under a per-bucket `ModuleType` discriminator.
**ABI risk:** LOW — Cork vendors only two members it dereferences; widening the surface requires an explicit code change.
**Cork-specific extensions:** time-locked `trustAttesters`, per-bucket `ModuleType` IDs, in-rolloverContract attester-set mirror.
**Known compatibility notes:** `NewTrustedAttesters` event is fired by the upstream registry, not the rolloverContract — Cork relies on the registry emission and keeps an in-rolloverContract mirror for downstream consumers.

### Canonical text
From <https://github.com/rhinestonewtf/registry/blob/main/src/interfaces/IERC7484.sol>:

```
interface IERC7484 {
    event NewTrustedAttesters(address indexed smartAccount);

    function check(address module) external view;
    function checkForAccount(address smartAccount, address module) external view;
    function check(address module, ModuleType moduleType) external view;
    function checkForAccount(address smartAccount, address module, ModuleType moduleType) external view;

    function trustAttesters(uint8 threshold, address[] calldata attesters) external;

    function check(address module, address[] calldata attesters, uint256 threshold) external view;
    function check(address module, ModuleType moduleType, address[] calldata attesters, uint256 threshold) external view;
}
```

### Conformance in this repo
- Vendored interface at `src/interfaces/external/erc7484/IERC7484.sol` mirrors the members Cork dereferences: `check(address, ModuleType)` at `:16`, explicit-threshold `check(address, ModuleType, address[], uint256)` at `:23`, and `trustAttesters(uint8, address[])` at `:33`.
- `ModuleType` is a `type ... is uint256` UDVT at `src/interfaces/external/erc7484/IERC7484.sol:5` per the upstream convention.
- Per-batch attestation enforced by `CorkRolloverContract._executeIntentCalls` via the explicit-threshold overload `IERC7484(registry).check(c.target, moduleType, attesters, threshold)` (`src/CorkRolloverContract.sol:1061`). Trust-config registration routes through `IERC7484(...).trustAttesters(threshold, attesters)` during rolloverContract initialization and factory-only trust-config application.
- Per-bucket `ModuleType` constants defined at `src/libraries/Typehashes.sol:50-64`:
  - `MODULE_TYPE_PRE_ROLLOVER_HOOK = 5`
  - `MODULE_TYPE_MID_ROLLOVER_HOOK = 6`
  - `MODULE_TYPE_POST_ROLLOVER_HOOK = 7`
  - `MODULE_TYPE_EXECUTOR = 8`

  Each hook list is attested under a distinct bucket so a module legitimate for one phase cannot be reused as another.

### Deviations
1. **Vendored-narrow surface.** Cork vendors only the two members it dereferences. The 1-arg `check(address)`, `checkForAccount`, and richer attester-set views in the upstream interface are deliberately omitted so the vendored surface stays audit-local.
2. **`NewTrustedAttesters` event not declared.** The upstream event fires on the registry, not on the rolloverContract; Cork relies on the registry's emission and additionally keeps an in-rolloverContract mirror.
3. **RolloverContract mirrors the attester set.** Because the vendored interface omits attester reads, `CorkRolloverContract` stores `liveTrustThreshold` + `liveTrustAttesters` as the authoritative lens for downstream consumers.
4. **Trust-config changes are time-locked.** Cork wraps `trustAttesters` with a queue/apply window enforced by the constructor-supplied external per-rolloverContract trust-config `TimelockController` (configured delay bounded by `MAX_TRUST_CONFIG_DELAY`, factory proposer/canceller/executor capability checked in the factory constructor). `CorkRolloverContractFactory.queueFactoryDefaultTrustConfig` snapshots current factory defaults, while `queueTrustConfig` accepts a custom config; both schedule and mirror the pending config. `applyTrustConfig` routes through `relayTrustConfig(rolloverContract, salt, threshold, attesters)` into the rolloverContract's factory-gated `setTrustConfig`, which writes through to `IERC7484.trustAttesters`. The relay succeeds only during canonical apply for the exact queued op id. The standard itself imposes no delay; Cork adds one to defend filler simulations from mid-tx attester swaps, and the timelock delay itself is mutable only through the Factory-governed delay-update path.
5. **Module-type IDs are Cork-local bitmap allocations.** Numeric IDs `5..8` are pairwise-distinct Rollover authorization buckets within the deployed registry's `uint32` bitmap. They are neither standardized ERC-7579 IDs nor a collision-resistant namespace; attestations must use the exact phase bucket.

### Migration / upgrade notes
- Widening the vendored surface (e.g., adding `checkForAccount`) requires no upstream registry change but breaks the "audit-local" invariant — flag in review.
- Bucket-ID changes are storage-free wire breaks for attesters but transparent to the rolloverContract.

---

## ERC-7201 — Namespaced Storage Layout

**Version pin:** EIP final.
**Used in:** `src/BaseSettler.sol, src/ExactSettler.sol, and src/PartialSettler.sol`, `src/CorkRolloverContract.sol`, `src/CorkRolloverContractFactory.sol`.
**Purpose:** Storage namespacing for CWIA-cloned rolloverContracts and singleton settler/factory contracts. Prevents collisions with the CWIA immutable-args trailer.
**ABI risk:** LOW — slots are literal-pinned; renaming a namespace id silently shifts storage, but no consumer reads the slot literal from outside the contract.
**Cork-specific extensions:** namespaced storage slots derived via the canonical ERC-7201 formula for the `RolloverContractStorage`, `ExactSettlerStorage`, `PartialSettlerStorage`, and `FactoryStorage` structs, documented via plain NatSpec comments rather than the formal `@custom:storage-location` annotation (no `@custom:storage-location` annotation exists in `src/`).

### Canonical text
From <https://eips.ethereum.org/EIPS/eip-7201>:

> The formula identified by `erc7201` is defined as `erc7201(id: string) = keccak256(keccak256(id) - 1) & ~0xff`. In Solidity, this corresponds to the expression `keccak256(abi.encode(uint256(keccak256(bytes(id))) - 1)) & ~bytes32(uint256(0xff))`.

> We define the NatSpec annotation `@custom:storage-location` to document storage namespaces and their location in storage in Solidity or Vyper source code.

### Conformance in this repo
Three namespaces, each pinned to a literal slot:

| Contract | Namespace ID | Pinned slot | Slot constant | Slot documentation |
|---|---|---|---|---|
| `ExactSettler` | `cork.rollover.exact-settler` | `0x545e6593eaef4a0977611e4e3c66cf08833dc54fedd0a55f3f6572464c0e3900` | `src/ExactSettler.sol` | plain NatSpec comment |
| `PartialSettler` | `cork.rollover.partial-settler` | `0xde4df9e562f99ce501d2218ebb94dfddd6f4be4f9c4423c45effffd6fd3f6f00` | `src/PartialSettler.sol` | plain NatSpec comment |
| `CorkRolloverContractFactory` | `cork.factory.storage.v3` | `0x33e161bf0309d8211c87f71dbb3e2f85e82ce7cff87a5e8b28dd7396ad330700` | `src/CorkRolloverContractFactory.sol` | plain NatSpec comment |
| `CorkRolloverContract` | `cork.rollover.rolloverContract` | `0xb4cefcf1cd721ac7aa7779687f98e0bf77365d8cc544d423bc3152971ed5cc00` | `src/CorkRolloverContract.sol:165-166` | plain NatSpec comment (`src/CorkRolloverContract.sol:164`) |

ExactSettler and PartialSettler document their derivation preimages inline:
`cork.rollover.exact-settler` and `cork.rollover.partial-settler`.

All three contracts use the canonical formula. The rolloverContract additionally validates non-collision against the CWIA trailer (see Cross-ERC section).

### Deviations
`CorkRolloverContract` derives its slot via the canonical ERC-7201 formula but documents it with a plain NatSpec comment (`/// @notice ERC-7201 namespaced storage slot for RolloverContractStorage` at `src/CorkRolloverContract.sol:164`) above the slot constant (`:165-166`), rather than the formal `@custom:storage-location` annotation. No `@custom:storage-location` annotation exists anywhere in `src/`; the settlers and `CorkRolloverContractFactory` likewise document their slots via plain NatSpec comments.

### Migration / upgrade notes
- Slots are literal-pinned. Renaming a namespace id silently shifts storage.
- The three-namespace map is verified non-collision against each other and against the Solidity standard layout — see memory `[OZ migration — Cork CWIA dependencies]`.

---

## ERC-1271 — Smart-Account Signature Validation

**Version pin:** EIP final.
**Used in:** `src/BaseSettler.sol, src/ExactSettler.sol, and src/PartialSettler.sol`, `src/CorkRolloverContract.sol`, `src/libraries/LibFillerAuth.sol`.
**Purpose:** Smart-account-friendly signature validation for user, cPT-holder-cancel,
FillerAuth, and rolloverContract cPT-holder-signature checks.
**ABI risk:** LOW — consumed via OZ `SignatureChecker.isValidSignatureNow`; Cork is not itself a contract-signer.
**Cork-specific extensions:** `BaseFiller` implements no `isValidSignature` function, so it cannot act as a contract-signer; rolloverContract async phases re-check the cPT-holder signature.

### Canonical text
From <https://eips.ethereum.org/EIPS/eip-1271>:

```
// bytes4(keccak256("isValidSignature(bytes32,bytes)")
bytes4 constant internal MAGICVALUE = 0x1626ba7e;

function isValidSignature(
    bytes32 _hash,
    bytes memory _signature
) public view returns (bytes4 magicValue);
```

> MUST return the bytes4 magic value `0x1626ba7e` when function passes.
> MUST NOT modify state … MUST allow external calls.

### Conformance in this repo
Cork does not implement ERC-1271 itself — no Cork contract is a contract-signer. It consumes ERC-1271 via OZ `SignatureChecker.isValidSignatureNow`, which transparently dispatches to ECDSA (for EOAs) or to the contract's `isValidSignature` (for smart accounts). Four consumption sites:

1. **User order signature** at `src/BaseSettler.sol, src/ExactSettler.sol, and src/PartialSettler.sol`:
   ```
   if (!SignatureChecker.isValidSignatureNow(user, orderDigest, signature)) { ... }
   ```
2. **FillerAuth executor delegation** at `src/libraries/LibFillerAuth.sol:107`:
   ```
   return SignatureChecker.isValidSignatureNow(exclusiveFiller, authDigest, fillerAuthSig);
   ```
3. **cPT-holder cancel signature** at `src/BaseSettler.sol, src/ExactSettler.sol, and src/PartialSettler.sol`:
   ```
   if (!SignatureChecker.isValidSignatureNow(orderData.user, cancelDigest, cptHolderSig)) { ... }
   ```
4. **RolloverContract cPT-holder signature** at `src/CorkRolloverContract.sol`:
   ```
   if (!SignatureChecker.isValidSignatureNow(_owner(), orderDigest, cptHolderSig)) { ... }
   ```

NatSpec at `src/interfaces/external/erc7683/IOriginSettler.sol:13-14` confirms the binding: "Implementations MUST verify `signature` against `order.user` using EIP-712 + ERC-1271 (`SignatureChecker.isValidSignatureNow` over `_hashTypedDataV4(structHash)`)."

### Deviations
1. **`BaseFiller` is NOT a contract-signer.** `BaseFiller` implements no `isValidSignature` function (true by absence across `src/` — `grep -rln 'function isValidSignature' src/` returns no matches), so orders naming `BaseFiller` as `exclusiveFiller` are unsupported — `SignatureChecker.isValidSignatureNow`'s ERC-1271 path will return false. This rules out the contract-as-exclusive-filler topology entirely.
2. **ERC-1271 path REMOVED from `openFor` exclusive-filler check.** filler authorisation is enforced only at `Settler.fill` via the `FillerAuth(orderDigest, destination, subFiller)` EIP-712 commitment (`src/libraries/Typehashes.sol:35-36`). The ERC-1271 path remains active for **user** and **cPT holder** signatures, NOT for filler authorisation.
3. **ERC-1271 mutability is live for every RolloverContract dispatch.** ERC-1271 signers can
   rotate keys mid-order; Cork re-checks cPT-holder authorization on ROLLOVER and
   PREMIUM, including atomic PREMIUM.

### Migration / upgrade notes
- `FillerAuth` typehash change (any field add/remove/rename) invalidates in-flight executor delegation sigs — fillers MUST re-sign before resubmit.
- Re-introducing ERC-1271 on the openFor path would require both interface widening on `BaseFiller`-style fillers and reversion of the filler-auth binding change.

---

## EIP-712 — Typed Structured Data Hashing

**Version pin:** EIP final.
**Used in:** `src/BaseSettler.sol, src/ExactSettler.sol, and src/PartialSettler.sol`, `src/libraries/{LibSettlerHashing, LibAuthenticatedHooks, LibFillerAuth, Typehashes}.sol`.
**Purpose:** Canonical struct-hash signing for user orders, filler authorisation,
and cPT holder cancels; `RolloverIntent` hashing is used for the
`OrderData.rolloverIntentHash` commitment rather than a separate signature.
**ABI risk:** HIGH — any typehash field add/remove/rename is a wire-format break; in-flight signatures under the old typehash become unverifiable.
**Cork-specific extensions:** two independent verifying-contract domains (`Settler` singleton via OZ `EIP712`; `CorkRolloverContract` via manual domain composition because OZ `EIP712` is unsafe under CWIA — see Cross-ERC section).

### Canonical text
From <https://eips.ethereum.org/EIPS/eip-712>:

> `encode(domainSeparator : 𝔹²⁵⁶, message : 𝕊) = "\x19\x01" ‖ domainSeparator ‖ hashStruct(message)` …
> `hashStruct(s : 𝕊) = keccak256(typeHash ‖ encodeData(s))` where `typeHash = keccak256(encodeType(typeOf(s)))`

Domain struct fields: `string name`, `string version`, `uint256 chainId`, `address verifyingContract`, optional `bytes32 salt`.

### Conformance in this repo
- `EIP712_DOMAIN_TYPEHASH` at `src/libraries/Typehashes.sol:66-68`:
  ```
  bytes32 internal constant EIP712_DOMAIN_TYPEHASH = keccak256(
      "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
  );
  ```
  Matches the EIP-712 canonical four-field domain exactly.
- **Settler domain.** `("CorkSettler", "1.0.0")`, set via OZ `EIP712` mix-in at `src/BaseSettler.sol, src/ExactSettler.sol, and src/PartialSettler.sol`:
  ```
  constructor(address factory_, address corkPoolManager_, address ensOwner_, address admin_, address pauser_, address unpauser_)
      EIP712("CorkSettler", "1.0.0") { owner = ensOwner_; ... }
  ```
  `ensOwner_` is Phoenix-style ENS/deployment identity. `admin_` receives `DEFAULT_ADMIN_ROLE` and the bounded ERC-20 rescue authority; `pauser_` receives `PAUSER_ROLE`; `unpauser_` receives `UNPAUSER_ROLE`.
- **Rollover intent hash type.** `ROLLOVER_INTENT_TYPEHASH` is still pinned for the
  zero-digest `RolloverIntent` hash committed in `OrderData.rolloverIntentHash`.
  The rolloverContract verifies the cPT-holder signature over `orderDigest` on every hook dispatch.
- **Pinned typehashes** in `src/libraries/Typehashes.sol`:
  - `ORDER_DATA_TYPEHASH` (`:21-23`) — 19 primitives embedding the 7-field `RolloverParams`
  - `ROLLOVER_PARAMS_TYPEHASH` (`:30-32`) — 7 fields
  - `FILLER_AUTH_TYPEHASH = keccak256("FillerAuth(bytes32 orderDigest,address destination,bytes32 subFiller)")` (`:39-40`)
  - `ROLLOVER_INTENT_TYPEHASH` (`:43-45`) — 8 fields, embeds `Call[]` × 4
  - `OUTPUT_TYPEHASH` (`:60-61`)
  - `CANCEL_ORDER_TYPEHASH` (`:64-65`)
- Hashing helpers: `LibSettlerHashing` (`src/libraries/LibSettlerHashing.sol`) for `OrderData` / `RolloverParams` / `CancelOrder`; `LibAuthenticatedHooks` (`src/libraries/LibAuthenticatedHooks.sol`) for `RolloverIntent`.

### Deviations
1. **No `salt` in the domain.** Cork uses only the four canonical fields — consistent with the EIP, which marks `salt` optional.
2. **Two domains, by design.** `Settler` and `CorkRolloverContract` are independent verifying contracts with independent `(name, version)` pairs. The rolloverContract does NOT inherit OZ `EIP712` (see Cross-ERC section for the CWIA reason).

### Migration / upgrade notes
- Bumping or changing `ROLLOVER_INTENT_TYPEHASH` changes every
  `OrderData.rolloverIntentHash` commitment for in-flight orders.
- Adding fields to `OrderData` / `RolloverParams` / `FillerAuth` /
  `RolloverIntent` / `CancelOrder` is a typehash break — the constants in
  `Typehashes.sol` MUST move in lock-step with the struct definitions in
  `RolloverTypes.sol`.

---

## ERC-20 — Token Standard

**Version pin:** Baseline standard; consumed via OZ `SafeERC20` + `IERC20`.
**Used in:** `src/CorkRolloverContract.sol`, `src/BaseSettler.sol, src/ExactSettler.sol, and src/PartialSettler.sol`, `src/BaseFiller.sol`, `src/EvcRolloverAdapter.sol`, `src/modules/{ApproveModule, ScopedSplitModule, ScopedTransferModule, *RolloverReferenceModule}.sol`.
**Purpose:** Token transfers, approvals, and balance reads for srcCST / dstCST / premium tokens.
**ABI risk:** LOW — no custom ERC-20 implementation in this repo.
**Cork-specific extensions:** none. `dstCST` (phoenix `PoolShare`) is plain OZ `ERC20Burnable + ERC20Permit` — no blacklist, pause, hooks, or upgradeable surface.

### Conformance in this repo
- All token interactions go through OZ `SafeERC20`:
  - `src/CorkRolloverContract.sol:7` `import { SafeERC20 }`
  - `src/CorkRolloverContract.sol:6` `import { IERC20 }`
  - `src/CorkRolloverContract.sol:162` `using SafeERC20 for IERC20;`
- Token reads use `IERC20.balanceOf` directly — no allowance dance on reads.


### Migration / upgrade notes
- Adding support for non-standard tokens (rebasing, fee-on-transfer, blacklist) would break the no-rescue assumption and require re-introducing rescue scaffolding. Out of scope at HEAD.

---

## OpenZeppelin Contracts (library)

**Version pin:** submodule `5fd1781b1454fd1ef8e722282f86f9293cacf256` (`.gitmodules:4-6`).
**Used in:** every contract in `src/` and several libraries; full import list below.
**Purpose:** Vetted implementations of access control, reentrancy guards, EIP-712 hashing, ERC-20 utilities, CWIA cloning, and initialization safety.
**ABI risk:** MEDIUM — OZ ships ABI-breaking changes between majors; the submodule pin avoids drift but a manual bump requires re-auditing all importing contracts.
**Cork-specific extensions:** OZ `EIP712` deliberately NOT inherited by `CorkRolloverContract` (CWIA `_cachedThis` impl-collision); OZ `Initializable` modifier ordering pinned (`onlyFactory` MUST precede `initializer`).
**Known compatibility notes:** see Cross-ERC section + memory `[OZ migration — Cork CWIA dependencies]`.

### OZ modules consumed (enumerated via `rg -n '@openzeppelin' src/`)

| Module | Path | Used in |
|---|---|---|
| `IERC20` | `@openzeppelin/contracts/token/ERC20/IERC20.sol` | `BaseSettler.sol:6`, `CorkRolloverContract.sol:6`, `BaseFiller.sol:8`, `EvcRolloverAdapter.sol:6`, `modules/{ApproveModule, ScopedSplitModule, ScopedTransferModule, MidRolloverReferenceModule, PreRolloverReferenceModule, PostRolloverReferenceModule}.sol` |
| `SafeERC20` | `@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol` | `BaseSettler.sol:7`, `CorkRolloverContract.sol:7`, `BaseFiller.sol:9`, `EvcRolloverAdapter.sol:7`, `modules/{ApproveModule, ScopedSplitModule, ScopedTransferModule}.sol` |
| `Math` | `@openzeppelin/contracts/utils/math/Math.sol` | `BaseSettler.sol:14`, `BaseFiller.sol:10`, `EvcRolloverAdapter.sol:8` |
| `EIP712` | `@openzeppelin/contracts/utils/cryptography/EIP712.sol` | `BaseSettler.sol:12` (singleton — safe; rolloverContract deliberately does NOT inherit) |
| `SignatureChecker` | `@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol` | `src/BaseSettler.sol:13`, `src/CorkRolloverContract.sol:11`, `src/libraries/LibFillerAuth.sol:5` |
| `MessageHashUtils` | `@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol` | `src/libraries/LibFillerAuth.sol:4` |
| `AccessControl` | `@openzeppelin/contracts/access/AccessControl.sol` | `BaseSettler.sol:4` |
| `AccessControl` | `@openzeppelin/contracts/access/AccessControl.sol` | `BaseSettler.sol:4`, `CorkRolloverContractFactory.sol` |
| `Pausable` | `@openzeppelin/contracts/utils/Pausable.sol` | `BaseSettler.sol:8` |
| `ReentrancyGuardTransient` | `@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol` | `BaseSettler.sol:9-11`, `CorkRolloverContract.sol:8-10`, `CorkRolloverContractFactory.sol:8-10` |
| `Clones` | `@openzeppelin/contracts/proxy/Clones.sol` | `CorkRolloverContract.sol:4`, `CorkRolloverContractFactory.sol:7` |
| `Initializable` | `@openzeppelin/contracts/proxy/utils/Initializable.sol` | `CorkRolloverContract.sol:5` |

### Cork-specific OZ integration notes
- **`ApproveModule`** uses `SafeERC20.forceApprove` for the approve/revoke legs (USDT-style zero-first via OZ); it does not implement bespoke bounded approval returndata handling. Spender-call failures only are capped at 256 bytes in `ApproveModule__SpenderCallFailed`.
- **`ReentrancyGuardTransient`** (transient-storage variant of `ReentrancyGuard`) is used uniformly — the `cancun` EVM target makes transient storage available.
- **`AccessControl`** on Factory and Settler gates protocol admin actions through `DEFAULT_ADMIN_ROLE`. Factory defaults rotation is direct through `DEFAULTS_MANAGER_ROLE`; assign that role to external governance/timelock if delay is desired.
- **`EIP712` singleton-only.** `Settler` inherits it (`src/BaseSettler.sol, src/ExactSettler.sol, and src/PartialSettler.sol`); `CorkRolloverContract` deliberately does not — see Cross-ERC.
- **`Clones.cloneDeterministicWithImmutableArgs`** is the CWIA deploy site. Trailer is 60 bytes (`owner ‖ factory ‖ erc7484Registry`). `predictRolloverContractOf(owner)` uses OZ `predictDeterministicAddressWithImmutableArgs` with the same args and owner-derived salt; same-address parity across chains requires identical factory address, implementation address, owner, and registry.
- **`Initializable` + `_disableInitializers()`** at `src/CorkRolloverContract.sol:245` prevents impl re-initialization.

### Migration / upgrade notes
- Any submodule bump must re-verify (a) `Initializable` modifier-order pin, (b) `EIP712._cachedThis` semantics on the singleton settler, and (c) ABI stability of OZ `AccessControl`.

---

## Cross-ERC Interactions

The standards do not stand alone in this repo. Three load-bearing interactions:

### ERC-1167 (CWIA) × OZ `Initializable` modifier order
- `CorkRolloverContract` is deployed as an ERC-1167 minimal proxy with a 60-byte CWIA trailer encoding `owner ‖ factory ‖ erc7484Registry` via deterministic `Clones.cloneDeterministicWithImmutableArgs`.
- The implementation contract calls `_disableInitializers()` in its constructor (`src/CorkRolloverContract.sol:245`) so the impl itself cannot be re-initialised.
- **Modifier ordering is load-bearing.** `initialize` orders the modifiers as `nonReentrant onlyFactory initializer`. Per memory `[OZ migration — Cork CWIA dependencies]`: `onlyFactory` MUST precede `initializer`. Why: OZ's `initializer` modifier sets the initialised flag before body execution; if `onlyFactory` ran second, a non-factory caller could still mark the clone "initialised" on a revert path with downstream consequences. The `onlyFactory` gate reads the factory address from the CWIA trailer, so the gate works pre-state-set (CWIA immutables are calldata-derived).
- **OZ `EIP712` is UNSAFE for CWIA clones.** OZ `EIP712` caches `_cachedThis = address(this)` at construction — for an impl-deployed-then-cloned topology, every clone would inherit the impl's `_cachedThis` and silently use the impl's domain separator. This is why `CorkRolloverContract` does NOT inherit OZ `EIP712` and instead computes its domain separator manually inside `LibAuthenticatedHooks` (`src/libraries/LibAuthenticatedHooks.sol`) with `rolloverContract` and `chainid` passed in explicitly. `Settler`, by contrast, is a singleton (no CWIA), so OZ `EIP712` is safe there (inheritance at `src/BaseSettler.sol:87`; domain init `EIP712("CorkSettler", "1.0.0")` at `src/BaseSettler.sol:169`).

### ERC-7201 × CWIA trailer
- The CWIA trailer occupies the last 60 bytes of the rolloverContract's runtime bytecode, not storage — so it cannot collide with the ERC-7201 namespaced storage at `cork.rollover.rolloverContract`. The trailer is read via `Clones.fetchCloneArgs(address(this))` from code, not SLOAD.
- The three ERC-7201 namespaces (settler / factory / rolloverContract) are verified non-colliding.

### EIP-712 × ERC-1271 paths in current code
Four live EIP-712 ↔ ERC-1271 verification points:

| Path | Signer | Typehash | Verifier site |
|---|---|---|---|
| User order open | `order.user` (EOA or contract) | `ORDER_DATA_TYPEHASH` | `src/BaseSettler.sol, src/ExactSettler.sol, and src/PartialSettler.sol` |
| FillerAuth executor delegation | `exclusiveFiller` (EOA or contract) | `FILLER_AUTH_TYPEHASH` | `src/libraries/LibFillerAuth.sol:107` |
| cPT-holder cancel | `orderData.user` (EOA or contract) | `CANCEL_ORDER_TYPEHASH` | `src/BaseSettler.sol, src/ExactSettler.sol, and src/PartialSettler.sol` |
| RolloverContract per-dispatch authorization | `_owner()` (EOA or contract) | cPT-holder-signed `OrderData` / `orderDigest` commits `rolloverIntentHash` | `src/CorkRolloverContract.sol` |

All four use `SignatureChecker.isValidSignatureNow(signer, digest, sig)`, which transparently routes to EIP-712-recovered ECDSA or to ERC-1271 `isValidSignature` based on whether `signer` has bytecode. The `BaseFiller` is excluded as a contract-signer because it implements no `isValidSignature` function (true by absence across `src/`), so SignatureChecker's ERC-1271 path returns false for it. The `openFor` exclusive-filler ERC-1271 check was REMOVED; the only filler-side ERC-1271 path that remains is FillerAuth at `Settler.fill` time (`LibFillerAuth.sol:107`).
