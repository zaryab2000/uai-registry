# UAIRegistry — Universal Agent Identity Registry on Push Chain

An ERC-8004-compatible Identity Registry deployed on Push Chain that uses the agent's Universal Executor Account (UEA) address as the canonical, chain-agnostic agent identifier. Per-chain ERC-8004 registries become "shadow registries" that link their local `agentId` to the canonical UEA via cryptographic proof of key ownership. The contract is non-transferable (soulbound), uses `agentId = uint256(uint160(ueaAddress))` for deterministic IDs, and supports verified shadow linking via EIP-712 signatures from per-chain NFT owners.

**Status:** Implemented — 70 tests passing (32 unit, 29 shadow linking, 6 fuzz x 1000 runs each, 3 fork-only integration scaffolds).

## Layout

- `src/UAIRegistry.sol` — main contract (registration, shadow linking, ERC-721 surface, soulbound)
- `src/IUAIRegistry.sol` — interface
- `src/interfaces/IUEAFactory.sol`, `src/interfaces/Types.sol` — Push Chain UEA interfaces
- `test/` — unit, shadow, fuzz, fork-based integration tests
- `script/Deploy.s.sol`, `script/VerifyDeployment.s.sol` — deployment + verification

## Build & test

```bash
forge build
forge test
forge test --gas-report
```

Integration tests auto-skip unless run against Push Chain Donut testnet:

```bash
forge test --match-path test/UAIRegistry.integration.t.sol \
    --fork-url $PUSH_CHAIN_RPC -vv
```

## Deploy

```bash
DEPLOYER_KEY=0x... forge script script/Deploy.s.sol \
    --rpc-url $PUSH_CHAIN_RPC --broadcast
```

See [PRD.md](PRD.md) for the full specification.
