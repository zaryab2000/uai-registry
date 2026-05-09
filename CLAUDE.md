# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

AgentRegistry is an ERC-8004-compatible Universal Agent Identity Registry on Push Chain. It uses Universal Executor Account (UEA) addresses as canonical, chain-agnostic agent identifiers. Per-chain ERC-8004 registries become "bound registries" linked to the canonical UEA via EIP-712 signatures. Identity tokens are soulbound (non-transferable), with `agentId = uint256(uint160(ueaAddress))`.

The ReputationRegistry is a cross-chain agent reputation aggregator that collects per-chain reputation snapshots from authorized reporters and computes aggregated scores keyed to canonical UEA identities.

## Build and Test

```bash
forge build                    # compile
forge test                     # all tests (189 passing: unit, binding, fuzz, integration, source-chain)
forge test -vv                 # verbose output
forge test --gas-report        # with gas reporting
forge fmt                      # format

# Run specific test files
forge test --match-path test/AgentRegistry.t.sol -vv
forge test --match-path test/ReputationRegistry.t.sol -vv
forge test --match-path test/AgentRegistry.fuzz.t.sol -vv

# Run a single test
forge test --match-test test_Register_FirstTime_CreatesRecord -vv

# Integration tests (auto-skip without fork)
forge test --match-path test/AgentRegistry.integration.t.sol --fork-url $PUSH_CHAIN_RPC -vv

# Source-chain contracts
forge test --match-path test/source/IdentityRegistrySource.t.sol -vv
forge test --match-path test/source/ReputationRegistrySource.t.sol -vv
```

## Deployment

```bash
# AgentRegistry (Push Chain)
DEPLOYER_KEY=0x... forge script script/Deploy.s.sol --rpc-url $PUSH_CHAIN_RPC --broadcast

# ReputationRegistry (Push Chain, requires existing AgentRegistry proxy)
AGENT_REGISTRY_PROXY=0x... INITIAL_REPORTER=0x... INITIAL_SLASHER=0x... \
  forge script script/DeployReputation.s.sol --rpc-url $PUSH_CHAIN_RPC --broadcast
```

## Architecture

### Settlement layer (Push Chain)

Two upgradeable contracts deployed behind `TransparentUpgradeableProxy`:

- **AgentRegistry** — Canonical identity. Registers agents via UEA, stores `AgentRecord` with origin chain metadata from `IUEAFactory.getOriginForUEA()`. Binding uses EIP-712 signatures verified via `ECDSA.tryRecover` (EOAs) or `IERC1271.isValidSignature` (smart wallets). Bind entries capped at 64 per agent, stored with swap-and-pop for O(1) unbind. Reverse lookup via `bindToCanonical` mapping for O(1) `canonicalUEAFromBinding()`.

- **ReputationRegistry** — Cross-chain reputation aggregation. Authorized `REPORTER_ROLE` addresses submit per-chain `ChainReputation` snapshots. Validates that the target chain has an active binding in AgentRegistry. Aggregation computes weighted average normalized to 18 decimals, with a scoring formula: `baseScore` (capped 7000 bps from avg value) * `volumeMultiplier` (log2-scaled feedback count) + `diversityBonus` (500 bps per chain, capped 2000) - `slashPenalty`. Score output is 0-10000 bps. `SLASHER_ROLE` records slash events with cumulative severity deductions.

### Source layer (per-chain ERC-8004+ source-chain wrappers, in `src/source/`)

Composition-based wrappers over existing ERC-8004 contracts (register/giveFeedback are non-virtual in base):

- **IdentityRegistrySource** — Registers locally via existing IdentityRegistry, then propagates to Push Chain AgentRegistry via `IGatewayAdapter`. UUPS-upgradeable with `OwnableUpgradeable`.

- **ReputationRegistrySource** — Submits feedback locally, batches reputation snapshots (threshold count or time interval), and propagates to Push Chain ReputationRegistry via gateway. Manages local-to-canonical agent ID mappings.

- **PushGatewayAdapter** — `IGatewayAdapter` implementation wrapping Push Chain's Universal Gateway for cross-chain payload delivery.

### Key design patterns

- **ERC-7201 namespaced storage** on all contracts for upgrade safety
- **UEAFactory** at `0x00000000000000000000000000000000000000eA` (Push Chain predeploy) — only `getOriginForUEA()` is called (view, no reentrancy risk)
- **AccessControlUpgradeable** for settlement contracts (PAUSER_ROLE, REPORTER_ROLE, SLASHER_ROLE); **OwnableUpgradeable** for source-chain wrappers
- **Custom errors** in `src/libraries/Errors.sol` (identity) and `src/libraries/ReputationErrors.sol` (reputation) — no string reverts in production code

## Compiler and Toolchain

- Solidity `0.8.26`, pinned pragma
- Optimizer: enabled, 10000 runs, `via_ir = false`
- EVM target: `cancun`
- Fuzz: 1000 runs per test
- OpenZeppelin v5.3.0 (both `contracts` and `contracts-upgradeable`)
- Formatter: 100 char line length, 4-space tabs, `params_first` multiline headers

## Test Naming Convention

`test_FunctionName_Condition_ExpectedResult` (e.g. `test_Bind_ExpiredDeadline_Reverts`). Fuzz tests use `testFuzz_` prefix.

## External References

- ERC-8004 registry addresses: mainnet `0x8004A169FB4a3325136EB29fA0ceB6D2e539a432`, testnet `0x8004A818BFB912233c491871b3d84c89A494BD9e`
- Push Chain Donut testnet chain ID: `42101`
- Full spec in `PRD.md`, internal design docs in `docs/`
