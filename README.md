# UAIRegistry — Universal Agent Identity Registry on Push Chain

An ERC-8004-compatible Identity Registry deployed on Push Chain that uses the agent's Universal Executor Account (UEA) address as the canonical, chain-agnostic agent identifier. Per-chain ERC-8004 registries become "shadow registries" that link their local `agentId` to the canonical UEA via cryptographic proof of key ownership. The contract is non-transferable (soulbound), uses `agentId = uint256(uint160(ueaAddress))` for deterministic IDs, and supports verified shadow linking via EIP-712 signatures from per-chain NFT owners. This PRD covers core registration, shadow linking, and test infrastructure (Milestones M1 + M2 + M5).

**Status:** Not Started

See [PRD.md](PRD.md) for the full specification.
