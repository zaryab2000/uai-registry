# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

TAP (Trustless Agents Plus) is an ERC-8004-compatible Universal Agent Identity Registry on Push Chain. It uses Universal Executor Account (UEA) addresses as canonical, chain-agnostic agent identifiers. Per-chain ERC-8004 registries become "bound registries" linked to the canonical UEA via EIP-712 signatures. Identity tokens are soulbound (non-transferable), with `agentId = uint256(uint160(ueaAddress)) % 10_000_000` (7-digit, deterministic). ID 0 is reserved as sentinel; addresses that truncate to 0 receive ID 10_000_000. Collision guard reverts if two addresses share the same truncated ID.

The TAPReputationRegistry is a cross-chain agent reputation aggregator that collects per-chain reputation snapshots from authorized reporters and computes aggregated scores keyed to canonical UEA identities.

## Build and Test

```bash
forge build                    # compile
forge test                     # all tests (unit, binding, fuzz, integration)
forge test -vv                 # verbose output
forge test --gas-report        # with gas reporting
forge fmt                      # format

# Run specific test files
forge test --match-path test/TAPRegistry.t.sol -vv
forge test --match-path test/TAPReputationRegistry.t.sol -vv
forge test --match-path test/TAPRegistry.fuzz.t.sol -vv

# Run a single test
forge test --match-test test_Register_FirstTime_CreatesRecord -vv

# Integration tests (auto-skip without fork)
forge test --match-path test/TAPRegistry.integration.t.sol --fork-url $PUSH_CHAIN_RPC -vv
```

## Deployment

```bash
# TAPRegistry (Push Chain)
DEPLOYER_KEY=0x... forge script script/deploy/Deploy.s.sol --rpc-url $PUSH_CHAIN_RPC --broadcast

# TAPReputationRegistry (Push Chain, requires existing TAPRegistry proxy)
TAP_REGISTRY_PROXY=0x... INITIAL_REPORTER=0x... INITIAL_SLASHER=0x... \
  forge script script/deploy/DeployReputation.s.sol --rpc-url $PUSH_CHAIN_RPC --broadcast
```

## Architecture

### Settlement layer (Push Chain)

Two upgradeable contracts deployed behind `TransparentUpgradeableProxy`:

- **TAPRegistry** — Canonical identity. Registers agents via UEA, stores `AgentRecord` with origin chain metadata from `IUEAFactory.getOriginForUEA()`. Binding uses EIP-712 signatures verified via `ECDSA.tryRecover` (EOAs) or `IERC1271.isValidSignature` (smart wallets). Bind entries capped at 64 per agent, stored with swap-and-pop for O(1) unbind. Reverse lookup via `bindToCanonical` mapping for O(1) `canonicalOwnerFromBinding()`.

- **TAPReputationRegistry** — Cross-chain reputation aggregation. Authorized `REPORTER_ROLE` addresses submit per-chain `ChainReputation` snapshots. Validates that the target chain has an active binding in TAPRegistry. Aggregation computes weighted average normalized to 18 decimals, with a scoring formula: `baseScore` (capped 7000 bps from avg value) * `volumeMultiplier` (log2-scaled feedback count) + `diversityBonus` (500 bps per chain, capped 2000) - `slashPenalty`. Score output is 0-10000 bps. `SLASHER_ROLE` records slash events with cumulative severity deductions.

### Cross-chain invocation (no source-chain wrappers)

Source chains (Sepolia, Base, BSC) use the existing ERC-8004 IdentityRegistry directly. Agents call Push Chain's `TAPRegistry` / `TAPReputationRegistry` either directly on Push Chain (Track 1) or via Push Chain's Universal Gateway from the source chain (Track 1.a). See `docs/TRACK1-a_workflow.md`.

### Key design patterns

- **ERC-7201 namespaced storage** on all contracts for upgrade safety
- **UEAFactory** at `0x00000000000000000000000000000000000000eA` (Push Chain predeploy) — only `getOriginForUEA()` is called (view, no reentrancy risk)
- **AccessControlUpgradeable** for settlement contracts (PAUSER_ROLE, REPORTER_ROLE, SLASHER_ROLE)
- **Custom errors** in `src/libraries/RegistryErrors.sol` (identity) and `src/libraries/ReputationErrors.sol` (reputation) — no string reverts in production code

## Compiler and Toolchain

- Solidity `0.8.26`, pinned pragma
- Optimizer: enabled, 10000 runs, `via_ir = false`
- EVM target: `cancun`
- Fuzz: 1000 runs per test
- OpenZeppelin v5.3.0 (both `contracts` and `contracts-upgradeable`)
- Formatter: 100 char line length, 4-space tabs, `params_first` multiline headers

## Test Naming Convention

`test_FunctionName_Condition_ExpectedResult` (e.g. `test_Bind_ExpiredDeadline_Reverts`). Fuzz tests use `testFuzz_` prefix.

## Address Books

- `docs/tap_address_book.md` — TAP contract addresses (TAPRegistry, TAPReputationRegistry, roles, upgrade history)
- `docs/ext_address_book.md` — External dependencies (UEA Factory, ERC-8004 registries, Push Chain gateways)

## External References

- ERC-8004 IdentityRegistry: mainnet `0x8004A169FB4a3325136EB29fA0ceB6D2e539a432`, testnet `0x8004A818BFB912233c491871b3d84c89A494BD9e`
- ERC-8004 TAPReputationRegistry: mainnet `0x8004BAa17C55a88189AE136b182e5fdA19dE9b63`, testnet `0x8004B663056A597Dffe9eCcC1965A193B7388713`
- Push Chain Donut testnet chain ID: `42101`
- Full spec in `PRD.md`, internal design docs in `docs/`
