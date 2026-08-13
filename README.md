# Cork Rollover

Cork Rollover is a Solidity/Foundry protocol for private rollover orders between [Cork Phoenix](https://github.com/Cork-Technology/phoenix) pools.

A cPT holder can move a cST position from an expiring source pool into a destination pool through a signed rollover flow. The protocol combines ERC-7683-compatible exact and partial settlers, per-holder `CorkRolloverContract` clones, ERC-7484 module attestation, and filler-side orchestration.

## Release status

This branch is a curated release snapshot of the private development repository.

**The protocol has not completed a production security audit. This pre-1.0 release is experimental and is not presented as production-ready.**

Repository release versions are recorded in [`VERSION`](VERSION). The deployed contracts currently expose implementation and EIP-712 domain version `1.0.0`; those values identify the deployed bytecode/signing domain and are distinct from the repository's pre-1.0 release maturity.

## Source provenance

- Private source repository: `Cork-Technology/rollover-private`
- Private source commit: `76c360d9b78a28cb6ac6135734686f9858178c06`
- Private source tree: `49ef519acd9fb49588a7232c1b0f5e9ce3202799`
- Preserved `src/` tree: `d8b28e72492233594d0e140ccb995e30629f1601`

Development infrastructure, deployment scripts, operational authorization material, generated audit context, formal-verification artifacts, and private CI configuration are intentionally excluded.

## Architecture

The principal contracts are:

- `BaseSettler`, `ExactSettler`, and `PartialSettler`: order admission and settlement.
- `CorkRolloverContractFactory`: deterministic rollover-contract deployment and trust configuration.
- `CorkRolloverContract`: executes the Phoenix unwind/deposit rollover leg.
- `BaseFiller`: filler-side orchestration.
- `EvcRolloverAdapter`: EVC-mediated filler adapter.
- `src/modules/`: stateless delegatecall modules used by signed hook plans.

Supplementary protocol specifications and invariants are retained under [`docs/`](docs/).

## Build and test

Requires Foundry.

```bash
git submodule update --init --recursive
forge build
forge test
```

Fork and deployment-script tests are excluded from this curated snapshot because they depend on operational infrastructure that is not part of the release.

## Shadow deployments

Release `v0.1.0-rc.1` records the paired shadow deployment on Base and Arbitrum One from the exact source provenance above. These deployments remain provisional and are not presented as production-ready.

The consolidated deployment manifest is [`deployments/rollover-release-v1.json`](deployments/rollover-release-v1.json). It records all 13 canonical singleton components, paired addresses, runtime hashes, artifact digests, exclusions, and the deployment-readiness evidence digests.

All 13 canonical singleton components use identical addresses on Base and Arbitrum One. Runtime hashes are identical for 11 of 13 components. `ExactSettler` and `PartialSettler` differ only because their cached EIP-712 domain-separator immutable embeds the chain ID.

First-fill readiness is separate from singleton deployment. No holder clone or first-fill order is included in this release.

## License

Tracked Solidity sources carry per-file SPDX identifiers. Most protocol sources use `BUSL-1.1`; narrowly vendored external interfaces use `MIT`. Review each source file's SPDX identifier before use or redistribution.
