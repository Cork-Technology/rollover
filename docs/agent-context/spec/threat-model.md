# Threat Model

STRIDE per actor + defense site. Defenses for §2.1-2.4, §2.7-2.8, §2.10, §2.13, §2.16 warrant focused review at HEAD.

## Actor roles as implemented

See `docs/agent-context/GLOSSARY.md` for the canonical mapping. The cPT holder
is the signing party (`orderData.user ==
ICorkRolloverContract(orderData.rolloverContract).owner()`) and may be an EOA or ERC-1271
contract. Solver / cST roller is the user-facing role; code and ERC-7683
surfaces still use Filler. This party supplies srcCST, pays premium, and
receives dstCST. A symmetric two-sided-cPT holder model is not
implemented.

## §2.1 User EOA / Safe (cPT holder)
- Spoof: `SignatureChecker.isValidSignatureNow(user, …)` on gasless admission;
  on-chain `open(OnchainCrossChainOrder)` requires `msg.sender == orderData.user`.
  ERC-1271 fallback applies to signed paths.
- Tamper: envelope/payload eq + `WrongOriginChain`/`WrongDestinationChain` `LibSettlerAdmission.sol:86, 89`; `Settler__OrderIdMismatch` `BaseSettler.sol:729, 732`.
- Repudiation: cancel sig `BaseSettler.sol:367` (`Settler__UnauthorizedCancel`).
- DoS (relayer drops): gasless `openFor` may be relayed by anyone with a valid user signature.
- Elevation: FSM gates.

## §2.2 Relayer
Mirrors §2.1; sig over user. **Info disclosure — OPEN by design** (user→relayer handoff).

## §2.3 Filler
- Spoof: 3-branch auth `LibFillerAuth.sol:100-107`.
- Tamper: `OrderIdMismatch` `:810`; `_validateOrder` + rolloverContract `_validateRolloverPreflight`.
- Repudiation: Settler-side per-record `premiumFired` latch (M-11 protocol-wide gate); rolloverContract-local `premiumFiredFor` (`CorkRolloverContract._handlePhasePremium`) is parallel success-only protection keyed by resolved `ctx.subFiller`.
- DoS (self-grief): ACCEPTED. INV-DSTCST-FLOOR.
- Elevation: Settler-side `premiumFired` latch + `MidPhaseDstCstDrain` `:908` + `DstCptNotConsumed` `:904` (rolloverContract `premiumFiredFor` is parallel success-only).

## §2.4 Delegated executor
- Spoof: `fillerAuthSig` bound `(orderDigest, destination, subFiller)` `LibFillerAuth.sol:100-107`; mismatch → `Settler__UnauthorizedFiller` `BaseSettler.sol:1139`.
- Elevation: bookkeeping keys on recovered `exclusiveFiller`, not `msg.sender`.

## §2.5 Settle keeper
- Spoof: `fillerDestination[orderDigest][filler][subFiller]` `PartialSettler.sol:142, 276, 340`.
- DoS (front-run reclaim): `Settler__OrderNotReclaimable`/`Settler__ReclaimBeforeFillDeadline` `BaseSettler.sol:304, 314`.
- Elevation (drain via refund): `Settler__PremiumAlreadyFired` `PartialSettler.sol:323` / `Settler__PremiumAlreadyFiredRollover` `PartialSettler.sol:240`. **[WEAK]** partial-mode refund "intentionally asymmetric" — relies on per-filler settle/reclaim preservation.

## §2.6 cPT holder
- Spoof: `SignatureChecker.isValidSignatureNow(_owner(), …)` `CorkRolloverContract.sol:609`.
- Tamper: `_validateIntentHashBinding` binds `intent.orderDigest` and the zero-digest `RolloverIntent` hash.
- ERC-1271 mutability: contract owners can change signature policy between signing and fill. cPT-holder order signatures are re-checked live on every RolloverContract hook dispatch, including atomic PREMIUM.
- DoS (front-run attester rotation): delay via external per-rollover-contract trust-config `TimelockController`; `TimelockController.TimelockUnexpectedOperationState` from `CorkRolloverContractFactory.applyTrustConfig`.
- Elevation (mid-hook value-skim / drain dstCST / leave dstCPT): `UnwindDepositShortfall` (`INV-DST-FLOOR`, cPT-holder-signed `params.minSharesOut`), `CaInsufficientForDeposit`, `DstCptNotConsumed`, `MidPhaseDstCstDrain`. caSrc consumption during mid is unconstrained (cross-CA supported).
- **Elevation (premium routing) — OPEN BY DESIGN.** Non-invariant. WEAK SPOT for adversarial cPT-holder UX.

## §2.7 Permissionless `CorkRolloverContractFactory.applyTrustConfig` caller
DEFENDED. Factory mirror (`pendingConfig` / `lastSalt`) + timelock `getTimestamp(opId)` gate enforce that the queued args match and the trust-config timelock delay has elapsed.

## §2.8 Approved Settler
- INV-SETTLER-APPROVED (factory) + INV-PARAMS-SETTLER-PIN (rolloverContract `_validateRolloverPreflight` `:747`).
- `approveSettler` SETTLER_APPROVER_ROLE-gated `CorkRolloverContractFactory.sol:354`; rejects zero/no-code targets without interface introspection.
- RolloverContract `onlyFactory`; factory pins `ctx.originSettler == msg.sender`.

## §2.9 Factory admin
- Spoof: OPEN (off-protocol). Mitigated by off-chain admin custody; Factory uses plain OZ `AccessControl`.
- Tamper (factory-wide defaults): direct via `setDefaults` gated by `DEFAULTS_MANAGER_ROLE` (INV-FACTORY-DEFAULTS-MANAGED); assign that role to external governance/timelock if delay is desired. Per-rolloverContract trust remains gated by the external trust-config `TimelockController` (INV-TRUST-CONFIG-DELAY).
- DoS (admin renounce): Factory and Settler role administration follows inherited OZ `AccessControl`, including self-renounce. Factory/Settler `renounceOwnership` clears only the Ownable deployment identity; Settler `owner()` is transferable/renounceable and is not a protocol role.
- Elevation (swap `ROLLOVER_CONTRACT_IMPLEMENTATION`): immutable; no setter (`CorkRolloverContractFactory.sol:176`, INV-NON-ROTATABLE-TRUST-ANCHORS).
- Elevation (swap trust-config `TimelockController`): immutable; no setter. Constructor validates the external trust-config timelock role wiring (INV-NON-ROTATABLE-TRUST-ANCHORS / INV-TRUST-CONFIG-TIMELOCK-WIRED).

## §2.10 Settler admin/pauser
- Tamper (pause mid-PREMIUM): `whenNotPaused` `BaseSettler.sol:244, 254, 280, 301, 335, 355`.
- DoS (indefinite pause): OPEN (governance).

## §2.13 Cross-chain
Runtime order execution is DEFENDED (inert). Hard chainid
`LibSettlerAdmission.sol:85-89`. Re-enable = OPEN.

Cross-chain address identity confusion remains a recognized threat for
factory-spawned user contracts. Same address on different chains can imply
different logical owners if per-user contracts are nonce-deployed. This is not
signature replay and not an on-chain access-control bypass; it is an
off-chain/operator/user-routing hazard. Agents should inspect factory-spawned
user contracts for deployment-order dependence, especially when SDKs,
operators, relayers, or monitoring expect same-address parity across chains.

## §2.14 Observer
Views `view`. No write capability.

## §2.15 Phoenix
- Spoof: rolloverContract derives pool-id from `IPoolShare(token).poolId()` + cross-checks.
- Tamper: balance-delta (DSR-1).
- **DoS (phoenix `Pausable`) — OPEN.** No Settler `whenNotPaused` covering phoenix. **WEAK:** filler firing ROLLOVER + phoenix-paused mid-PREMIUM → defaulter-pathed. Verify INV-DEFAULTER-RECOUP covers all permutations.

## §2.16 Hook target
- Spoof: `_prevalidateIntentCalls` `CorkRolloverContract.sol:1032-1066` (`ModuleTypeMismatch`); reference modules carry `OnlyDelegatecall` (`src/modules/OnlyDelegatecall.sol`) so standalone invocation reverts.
- DoS (revert mid-batch): `allowFailure=false` `:1051`.
- Elevation (re-enter): `nonReentrant` on factory + rolloverContract + every Settler mutating entry.

---

## Weak-spot verification targets

1. cPT-holder premium routing unbounded (§2.6) — `CorkRolloverContract._handlePhasePremium` no filler-protective destination bound (standing-balance trip-wire only).
2. Partial-mode refund asymmetry (§2.5) — per-filler settle/reclaim genuinely preserved post-refund?
3. Phoenix `Pausable` mid-flight (§2.15) — no Settler kill-switch; defaulter-recoup covers ROLLOVER-fired pre-pause + partial-fill?
4. `originFillerData` on `openFor` ignored — destination-binding holds when filler races itself?
5. Factory owner identity powers — claim "no protocol powers"; spot-check `transferOwnership`/`renounceOwnership` cannot reach role grants or admin transfer.
6. `originData` vs `RolloverParams` cross-checks still pin `params.{src,dst}CstToken == orderData.{src,dst}CstToken`? Drifted refs.
7. `ROLLOVER_CONTRACT_IMPLEMENTATION` immutable `[UNCERTAIN]` — confirm via grep.
8. In-flight latch leakage (§2.14) — EIP-1153 clears on revert?

## Accepted residuals (NOT findings)

1. cPT-holder premium-routing unbounded by design. `CorkRolloverContract._handlePhasePremium` has no destination constraint on hook routing. M-11 binds filler↔premium-receiver within tx not destination.
2. `originFillerData` on `openFor` ignored. Destination-binding at `fill` is gate.
3. Phoenix `Pausable` DoS on in-flight — user remedy = post-`fillDeadline` refund. ROLLOVER-fired-but-PREMIUM-unpaid filler = defaulter under INV-DEFAULTER-RECOUP.
4. Cross-chain envelope inert.
5. Lens ABI now CI-pinned — `IRolloverContractLens.RolloverContractConfig`, `ICorkRolloverContract.RolloverContractTrustSnapshot`, and `ICorkRolloverContract.RolloverContractOrderState` component order is gated by `test/integration/admission/LensStructAbiStability.t.sol` (silent reorder/extension fails CI).
