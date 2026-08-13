# Fork Tests

The fork suite separates live deployment assumptions from fork-local mutation so
readers can tell what mainnet currently guarantees and what the test locally
changes after the fork is created.

## Environment

- Ethereum mainnet fork tests read `ETH_MAINNET_RPC_URL` first and then
  `MAINNET_RPC_URL`.
- GitHub Actions has one fork job for Ethereum/Phoenix/Rhinestone/Permit2 using
  `ETH_MAINNET_RPC_URL`. It runs after the normal integration, deploy-profile
  smoke, invariant, and static-analysis gates so the RPC-backed fork suite does
  not spend CI time when cheaper gates already failed.
- Tenderly Node RPC is sufficient for local and CI execution.

When the relevant RPC environment variable is missing, the fork tests call
`vm.skip(true)` instead of faking a live run. A skipped fork test only proves the
secret-free path works.

## Coverage Labels

- `readOnly`: checks pinned live mainnet state without mutating fork state.
- `forkLocal`: starts from live mainnet state, then uses Foundry fork mutation
  such as `vm.prank` or `deal` to validate a local operational path.
- `hybrid`: combines locally deployed Cork contracts with live third-party
  contracts. Hybrid tests are intentionally separate because local deployment can
  prove wiring feasibility, not production deployment state.

## Ethereum Phoenix

Phoenix tests pin Ethereum mainnet at block `24274824`, the production smoke
configuration block. They validate:

- PoolManager, DefaultCorkController, WhitelistManager, and SharesFactory code.
- Smoke pool `market(poolId)` against the canonical collateral, reference,
  expiry, rate bounds, rate-change limits, and oracle.
- Smoke-pool `shares(poolId)` resolution to CPT and CST.
- CPT/CST identity assumptions consumed by Cork: `poolManager`, `poolId`,
  `decimals`, and `expiry`.
- Preview conversion semantics for `previewDeposit` and `previewUnwindMint`.
- Fork-local low-decimal Phoenix pool behavior: deposit mints 18-decimal paired
  shares from 6-decimal collateral, and `unwindMint` truncates unaligned share
  input to the source-share quantum before burning.
- Smoke-pool expiry boundary for `previewDeposit`.
- Smoke-pool pause flags and fee settings.
- Whitelist role assumptions for the operational multisig and timelock.
- Fork-local controller whitelist mutation, WhitelistManager caller boundary,
  whitelist rejection, deposit/mint behavior, and unwindMint behavior.
- Whitelist subject boundaries: `deposit` gates the caller rather than the
  receiver, and `unwindMint` gates the caller while spending owner-approved
  paired shares and sending collateral to the receiver.
- Fork-local per-market pause mutation for deposit and unwind-mint previews and
  actions.
- CPT/CST EIP-2612 permit behavior.
- Smoke collateral/reference token code, decimals, symbols, and exact ERC-20
  `transferFrom` behavior.
- Smoke oracle code/rate, constraint-rate adapter code, and PoolManager
  `swapRate(poolId)` binding at the pinned block.
- Cork's live Phoenix share quantum derivation for the smoke pool.
- Uninitialized Phoenix pool ids resolving to zero market/share data.
- Raw `shares(poolId)` returndata shape: exactly 64 bytes for initialized and
  uninitialized pool ids, matching Cork's staticcall/decode assumption.
- Paired-share burn assumptions: `unwindMint` rejects when either CPT or CST is
  missing from the owner.
- Actual deposit non-minting at the smoke expiry boundary.
- Actual unwindMint non-burning/non-moving behavior at the smoke expiry
  boundary.
- `script/verify-deploy.s.sol` Phoenix selector gate acceptance for the live
  smoke CST and rejection when a CPT, wrong expected pool id, non-share token,
  zero address, or no-code target is supplied where a CST is expected. Wrong
  pool-id rejection is covered on both source and destination CST inputs.
- `script/verify-deploy.s.sol` local release-gate checks for all-or-none
  Phoenix env inputs and hook target/module-type array length equality.
- Hybrid local Cork deployment against the live Phoenix PoolManager, using a
  local MockERC7484 registry while keeping Rhinestone read-only.

At the pinned block, the operational multisig has `WHITELIST_ADDER_ROLE` but
does not have `WHITELIST_REMOVER_ROLE`; the TimelockOperational address has the
pool-creator and whitelist roles. The Phoenix pauser role holder is
`0x22813eAD27855382D2B0AD98De433baD30C08d1F`. The tests encode this
pinned-chain state so a future permissions change is visible.

The adjacent Phoenix repository confirms this is not a Base deployment:
`../phoenix-private/config/prod.toml` has production sections for `[mainnet]`
and `[sepolia]`, and
`../phoenix-private/config/smoke/smoke-00-vbUSDC-sUSDe.toml` pins the smoke
configuration under chain id `[1]`. There is no `[base]` or `[8453]` Phoenix
deployment section in those configs.

## Rhinestone And Permit2

Rhinestone and Permit2 checks are a mix of read-only and fork-local:

- The Rhinestone Module Registry has code and
  `findTrustedAttesters(address)` is callable.
- A fork-local `trustAttesters` update round-trips through
  `findTrustedAttesters`.
- Fork-local Rhinestone trust configuration is caller-scoped: one caller's
  trusted attesters do not appear for another caller.
- The live registry exposes the four-argument ERC-7484
  `check(module,moduleType,attesters,threshold)` selector Cork's explicit
  attester-set path depends on; the test uses negative unattested-module
  coverage because no known live Cork-attested module is configured.
- The tests intentionally do not require `supportsInterface`; manual probing
  showed that call can revert and it is not part of Cork's consumed surface.
- Permit2 has code and `DOMAIN_SEPARATOR()` is callable.
- Permit2's domain separator matches the expected Ethereum-mainnet EIP-712
  domain for the canonical Permit2 address.
- Permit2 allowance transfer works with the Phoenix smoke collateral token.
- Permit2 SignatureTransfer accepts the `EvcRolloverAdapter` batch witness type
  with smoke collateral/reference tokens, and expired or witness-mutated
  signatures leave balances unchanged.

Live Rhinestone attestation is not used for local Cork hybrid tests unless an
attester/module setup is available. Prefer `MockERC7484` for local hybrid Cork
coverage.

## Known Blockers

Full Cork/Phoenix live rollover is more fragile than read-only assumption
coverage because it depends on live source and destination pool availability,
pool expiry, Phoenix whitelist state, funding for live collateral, live
Rhinestone attestation, and CI secret access. If no live destination pool is
known, a fork-local destination pool must be created from the timelock role.
If live collateral `deal` does not work, the next fallback is transfer from a
known whale at the pinned block; whale discovery is intentionally not part of the
secret-free path.

The current hybrid test stops at locally deployed Cork plus live Phoenix
whitelist/funding/deposit preconditions. It does not claim full `Settler.fill`
coverage because no canonical live destination pool and live Rhinestone
attestation path are configured in this repo.

## Commands

Secret-free skip-path verification:

```bash
env -u ETH_MAINNET_RPC_URL -u MAINNET_RPC_URL \
  forge test --match-path "test/fork/**/*.t.sol" -vvv
```

Live Ethereum fork verification, when an Ethereum RPC is available:

```bash
export ETH_MAINNET_RPC_URL=<tenderly-ethereum-mainnet-url>
forge test --match-path "test/fork/PhoenixEthMainnetFork.t.sol" -vvv
forge test --match-path "test/fork/EthMainnetExternalAssumptionsFork.t.sol" -vvv
forge test --match-path "test/fork/EthMainnetDependencyAssumptionsFork.t.sol" -vvv
forge test --match-path "test/fork/CorkPhoenixHybridEthMainnetFork.t.sol" -vvv
forge test --match-path "test/fork/EthMainnetPermit2WitnessFork.t.sol" -vvv
```

Focused Phoenix integration regression:

```bash
forge test --match-path "test/integration/rollover/AtomicFillPhoenixQuantization.t.sol" -vvv
```
