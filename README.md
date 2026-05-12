# TAP — Trustless Agents Plus

An ERC-8004-compatible Identity Registry deployed on Push Chain that uses the agent's Universal Executor Account (UEA) address as the canonical, chain-agnostic agent identifier. Per-chain ERC-8004 registries become "bound registries" that link their local `agentId` to the canonical UEA via cryptographic proof of key ownership. The contract is non-transferable (soulbound), uses `agentId = uint256(uint160(ueaAddress)) % 10_000_000` for deterministic 7-digit IDs (with collision guard), and supports verified binding via EIP-712 signatures from per-chain NFT owners.

**Status:** Implemented — 70 tests passing (32 unit, 29 binding, 6 fuzz x 1000 runs each, 3 fork-only integration scaffolds).

## Layout

- `src/AgentRegistry.sol` — main contract (registration, binding, ERC-721 surface, soulbound)
- `src/interfaces/IAgentRegistry.sol` — interface
- `src/interfaces/IUEAFactory.sol`, `src/libraries/Types.sol` — Push Chain UEA interfaces
- `test/` — unit, binding, fuzz, fork-based integration tests
- `script/deploy/` — deployment scripts (`Deploy.s.sol`, `DeployReputation.s.sol`, `VerifyDeployment.s.sol`)
- `script/upgrade/` — upgrade scripts (`UpgradeAgentRegistry.s.sol`, `UpgradeReputationRegistry.s.sol`)

## Build & test

```bash
forge build
forge test
forge test --gas-report
```

Integration tests auto-skip unless run against Push Chain Donut testnet:

```bash
forge test --match-path test/AgentRegistry.integration.t.sol \
    --fork-url $PUSH_CHAIN_RPC -vv
```

## Deploy

```bash
DEPLOYER_KEY=0x... forge script script/deploy/Deploy.s.sol \
    --rpc-url $PUSH_CHAIN_RPC --broadcast
```

See [PRD.md](PRD.md) for the full specification.
