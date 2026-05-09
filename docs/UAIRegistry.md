# UAIRegistry

Universal Agent Identity Registry on Push Chain.

UAIRegistry is the canonical identity contract for AI agents operating across multiple blockchains. It lives on Push Chain and serves as the single source of truth for "who is this agent?" regardless of which chain the agent originally registered on.

Every agent gets one identity. That identity can be linked to per-chain registrations on Ethereum, Base, Arbitrum, or any EVM-compatible chain running an ERC-8004 IdentityRegistry. The result is a unified, cross-chain identity graph for AI agents, anchored to a soulbound (non-transferable) record on Push Chain.

---

## The Problem

ERC-8004 gives each chain its own IdentityRegistry. An agent registered on Ethereum mainnet gets an `agentId` on Ethereum. The same agent registered on Base gets a different `agentId` on Base. These two identities are completely disconnected:

- A user on Base cannot verify that agent #42 on Base is the same entity as agent #17 on Ethereum.
- Reputation earned on one chain does not carry over to another.
- An agent operator must manage separate registrations, metadata URIs, and agent cards on every chain independently.
- There is no way to revoke or update an agent's identity atomically across all chains.

Without a canonical registry, "cross-chain agent identity" is a manual, trust-the-operator affair. Users must rely on off-chain social signals (website, Twitter, docs) to figure out if two per-chain agents are the same entity. This breaks the moment agents are autonomous and need machine-readable, cryptographically verifiable identity.

---

## How UAIRegistry Solves It

UAIRegistry introduces a two-layer identity model:

1. **Canonical identity on Push Chain** -- the agent registers once on Push Chain via its Universal Executor Account (UEA). This creates a soulbound, non-transferable identity record.

2. **Shadow links to per-chain identities** -- the agent links its per-chain ERC-8004 registrations (called "shadows") to the canonical identity. Each link is cryptographically verified via EIP-712 signatures.

### The UEA as Canonical Anchor

Push Chain's Universal Executor Accounts (UEAs) are factory-deployed accounts that bridge external chain identities to Push Chain. When a user from Ethereum creates a UEA on Push Chain, the UEA factory records their origin chain, chain ID, and owner key (the Ethereum address that controls the UEA).

The `agentId` is deterministic: `agentId = uint256(uint160(ueaAddress))`. This means:
- The agent ID is the UEA address itself, cast to uint256.
- No counter. No mapping lookup. No collision risk.
- Anyone who knows the UEA address can compute the agent ID, and vice versa.

### Registration

An agent registers by calling `register(agentURI, agentCardHash)` from its UEA on Push Chain:

- `agentURI` is a metadata URI (typically an IPFS CID) pointing to the agent's card -- a JSON document describing the agent's capabilities, model, version, and other metadata.
- `agentCardHash` is the keccak-256 hash of the agent card content, enabling on-chain integrity verification.

On first registration, the contract queries the UEA factory to determine:
- `originChainNamespace`: The CAIP-2 namespace (e.g., `"eip155"` for EVM chains).
- `originChainId`: The CAIP-2 chain ID (e.g., `"1"` for Ethereum mainnet).
- `ownerKey`: The raw bytes of the controlling address on the origin chain.
- `nativeToPush`: Whether the caller is native to Push Chain (not a UEA).

Subsequent calls to `register()` update the `agentURI` and `agentCardHash` without modifying origin metadata. This is the re-registration path -- same function, idempotent semantics.

### Shadow Linking

Once registered, the agent links its per-chain ERC-8004 registrations to the canonical identity. Each link is called a "shadow" and represents a binding between:

- The canonical agent on Push Chain (identified by `agentId`)
- A per-chain agent on another chain (identified by `chainNamespace`, `chainId`, `registryAddress`, `shadowAgentId`)

#### How Shadow Linking Works

1. **The agent constructs an EIP-712 typed data message** containing:
   - `canonicalUEA`: The UEA address on Push Chain
   - `chainNamespace`: CAIP-2 namespace of the target chain (e.g., `"eip155"`)
   - `chainId`: CAIP-2 chain ID (e.g., `"1"`)
   - `registryAddress`: The ERC-8004 IdentityRegistry contract address on that chain
   - `shadowAgentId`: The agent's ID on that chain's registry
   - `nonce`: A unique nonce to prevent replay
   - `deadline`: Timestamp after which the signature expires

2. **The agent signs this message** with the private key that controls the UEA (the `ownerKey` recorded at registration). The signature proves that the same entity controlling the canonical identity also controls the per-chain identity.

3. **The agent calls `linkShadow()`** on Push Chain with the signed request. The contract:
   - Verifies the agent is registered
   - Checks chain identifiers and registry address are valid
   - Validates the deadline hasn't expired and the nonce hasn't been used
   - Checks the shadow isn't already claimed by another agent (global uniqueness)
   - Checks the agent hasn't exceeded the 64-shadow limit
   - Verifies the signature against the `ownerKey` (supports both ECDSA and ERC-1271 contract signatures)
   - Stores the shadow entry and updates all indexes

#### Signature Verification

The contract supports two signature schemes:

- **ECDSA (EOA)**: The standard 65-byte `(r, s, v)` signature. The contract recovers the signer address and checks it matches the first 20 bytes of `ownerKey`.
- **ERC-1271 (Contract)**: For smart contract wallets. The `proofData` is encoded as `abi.encodePacked(signerAddress, signatureBytes)`. The contract calls `isValidSignature()` on the signer address with a 50,000 gas limit.

#### Deduplication and Uniqueness

- **Global uniqueness**: A shadow tuple `(chainNamespace, chainId, registryAddress, shadowAgentId)` can only be claimed by one canonical agent. This prevents two agents from claiming the same per-chain identity.
- **Per-agent uniqueness**: An agent can have at most one shadow per `(chainNamespace, chainId, registryAddress)` tuple. To change the `shadowAgentId` for a given chain+registry, the agent must unlink first, then relink.

#### Unlinking

The agent calls `unlinkShadow(chainNamespace, chainId, registryAddress)` to remove a shadow link. This uses a swap-and-pop pattern on the shadows array for gas efficiency -- the entry to remove is swapped with the last entry, then the array is popped. All indexes are updated accordingly.

### Soulbound Semantics

Agent identities are non-transferable. The contract implements the ERC-721 transfer surface (`transferFrom`, `safeTransferFrom`, `approve`, `setApprovalForAll`) but every function unconditionally reverts with `IdentityNotTransferable()`. This ensures:

- An agent's identity cannot be sold or transferred to another entity.
- The `ownerOf()` relationship is permanent.
- The `agentId <-> UEA` mapping is immutable after registration.

### Storage Architecture

UAIRegistry uses ERC-7201 namespaced storage for upgrade safety. All state lives in a single storage struct at a deterministic slot:

```
STORAGE_SLOT = keccak256(abi.encode(uint256(keccak256("uairegistry.storage")) - 1))
                & ~bytes32(uint256(0xff))
```

The storage struct contains:

| Field | Type | Purpose |
|-------|------|---------|
| `records` | `mapping(uint256 => AgentRecord)` | Agent ID to registration record |
| `shadows` | `mapping(uint256 => ShadowEntry[])` | Agent ID to array of shadow links |
| `shadowToCanonical` | `mapping(bytes32 => uint256)` | Dedup key to canonical agent ID (global uniqueness) |
| `shadowIndex` | `mapping(uint256 => mapping(bytes32 => uint256))` | Agent ID + chain key to array index (for O(1) lookup) |
| `shadowExists` | `mapping(uint256 => mapping(bytes32 => bool))` | Agent ID + chain key to existence flag |
| `usedNonces` | `mapping(uint256 => mapping(uint256 => bool))` | Agent ID + nonce to used flag (replay protection) |

### Access Control and Pausability

- **DEFAULT_ADMIN_ROLE**: Can grant/revoke roles. Set at initialization.
- **PAUSER_ROLE**: Can pause/unpause the contract. Registration, metadata updates, shadow linking, and shadow unlinking are all pausable.
- The contract is deployed behind a `TransparentUpgradeableProxy`.

---

## How UAIRegistry Works with ERC-8004

ERC-8004 defines the per-chain standard for agent identity and reputation. Each chain deploys its own `IdentityRegistry` (and optionally `ReputationRegistryUpgradeable`). Agents register on each chain independently through these per-chain contracts.

UAIRegistry sits on top of ERC-8004 as the **cross-chain unification layer**:

```
                         Push Chain
                    +-----------------+
                    |   UAIRegistry   |
                    |  (canonical ID) |
                    +--------+--------+
                             |
              shadow links   |   shadow links
           +-----------------+-----------------+
           |                 |                 |
    +------+------+   +------+------+   +------+------+
    | Ethereum    |   | Base        |   | Arbitrum    |
    | ERC-8004    |   | ERC-8004    |   | ERC-8004    |
    | IdentityReg |   | IdentityReg |   | IdentityReg |
    +-------------+   +-------------+   +-------------+
```

The relationship is:
- ERC-8004 handles per-chain registration, metadata, and local operations.
- UAIRegistry maps per-chain registrations to a single canonical identity.
- Shadow links are the bridge -- each link says "agent #42 on Ethereum's IdentityRegistry at `0xABC...` is the same entity as canonical agent `0x123...` on Push Chain."

### Reverse Lookups

The `canonicalUEAFromShadow()` function enables reverse resolution: given a per-chain agent identity (chain namespace, chain ID, registry address, shadow agent ID), find the canonical UEA on Push Chain. This is the key primitive that allows any chain to resolve a cross-chain agent identity question.

---

## Real-World Example: Registering an AI Trading Agent

Consider an AI trading agent called "AlphaBot" that operates on Ethereum mainnet and Base. The agent's operator wants a unified identity so users on either chain can verify they're interacting with the same agent.

### Step 1: Create a UEA on Push Chain

The operator's Ethereum address is `0xAlice...`. They use the Push Chain UEA factory to create a Universal Executor Account on Push Chain. The factory records:
- Origin namespace: `"eip155"`
- Origin chain ID: `"1"` (Ethereum mainnet)
- Owner key: `0xAlice...` (the Ethereum address)

The UEA is deployed at address `0xUEA_Alice...` on Push Chain.

### Step 2: Register on UAIRegistry

From the UEA (`0xUEA_Alice...`), the operator calls:

```solidity
uaiRegistry.register(
    "ipfs://QmAlphaBotCard",        // agent card metadata URI
    keccak256(agentCardJSON)         // hash of the agent card content
);
```

This creates a canonical identity with `agentId = uint256(uint160(0xUEA_Alice...))`. The registration record stores the origin chain info and owner key.

### Step 3: Register on Per-Chain ERC-8004 Registries

The operator registers AlphaBot on Ethereum's ERC-8004 IdentityRegistry (getting `shadowAgentId = 17`) and on Base's ERC-8004 IdentityRegistry (getting `shadowAgentId = 42`).

### Step 4: Link Ethereum Shadow

The operator constructs an EIP-712 message:

```
ShadowLink(
    canonicalUEA: 0xUEA_Alice...,
    chainNamespace: "eip155",
    chainId: "1",
    registryAddress: 0xEthIdentityRegistry...,
    shadowAgentId: 17,
    nonce: 1,
    deadline: <current timestamp + 1 hour>
)
```

They sign this with the private key of `0xAlice...` (the owner key), then call:

```solidity
uaiRegistry.linkShadow(ShadowLinkRequest({
    chainNamespace: "eip155",
    chainId: "1",
    registryAddress: 0xEthIdentityRegistry...,
    shadowAgentId: 17,
    proofType: ShadowProofType.OWNER_KEY_SIGNED,
    proofData: signature,
    nonce: 1,
    deadline: block.timestamp + 1 hours
}));
```

The contract verifies the signature, confirms the shadow isn't already claimed, and stores the link.

### Step 5: Link Base Shadow

Same process for Base:

```solidity
uaiRegistry.linkShadow(ShadowLinkRequest({
    chainNamespace: "eip155",
    chainId: "8453",
    registryAddress: 0xBaseIdentityRegistry...,
    shadowAgentId: 42,
    proofType: ShadowProofType.OWNER_KEY_SIGNED,
    proofData: baseSignature,
    nonce: 2,
    deadline: block.timestamp + 1 hours
}));
```

### Step 6: Cross-Chain Identity Resolution

Now, a user on Base interacting with agent #42 wants to know if this agent has a canonical identity. They (or a dApp, or another contract) query Push Chain:

```solidity
(address canonical, bool verified) = uaiRegistry.canonicalUEAFromShadow(
    "eip155",
    "8453",
    0xBaseIdentityRegistry...,
    42
);
// canonical = 0xUEA_Alice...
// verified = true
```

The user can then query the full agent record:

```solidity
IUAIRegistry.AgentRecord memory record = uaiRegistry.getAgentRecord(
    uint256(uint160(canonical))
);
// record.agentURI = "ipfs://QmAlphaBotCard"
// record.originChainNamespace = "eip155"
// record.originChainId = "1"
// record.registeredAt = <timestamp>
```

And see all linked shadows:

```solidity
IUAIRegistry.ShadowEntry[] memory shadows = uaiRegistry.getShadows(agentId);
// shadows[0]: Ethereum mainnet, agentId 17
// shadows[1]: Base, agentId 42
```

The user now has cryptographic proof that agent #42 on Base and agent #17 on Ethereum are the same entity, with a verifiable metadata URI and the ability to check the agent's cross-chain reputation (via ReputationRegistry).

### Step 7: Updating Metadata

If AlphaBot upgrades its model or capabilities, the operator updates the agent card:

```solidity
uaiRegistry.setAgentURI("ipfs://QmAlphaBotCardV2");
uaiRegistry.setAgentCardHash(keccak256(newAgentCardJSON));
```

This update is immediately visible to all chains that resolve through UAIRegistry. No need to update per-chain registrations for identity metadata.

### Step 8: Unlinking a Shadow

If AlphaBot stops operating on Base, the operator removes the shadow link:

```solidity
uaiRegistry.unlinkShadow(
    "eip155",
    "8453",
    0xBaseIdentityRegistry...
);
```

The shadow is removed, the dedup key is freed (another agent could now claim that per-chain identity), and future reverse lookups for that shadow return `(address(0), false)`.

---

## Function Reference

### Registration

| Function | Access | Description |
|----------|--------|-------------|
| `register(agentURI, agentCardHash)` | UEA owner | Register or re-register. Returns `agentId`. |
| `setAgentURI(newAgentURI)` | UEA owner | Update metadata URI only. |
| `setAgentCardHash(newHash)` | UEA owner | Update agent card hash only. |

### Shadow Linking

| Function | Access | Description |
|----------|--------|-------------|
| `linkShadow(req)` | UEA owner | Link a per-chain ERC-8004 identity with EIP-712 proof. |
| `unlinkShadow(ns, id, addr)` | UEA owner | Remove a shadow link. |

### Reads

| Function | Description |
|----------|-------------|
| `ownerOf(agentId)` | UEA address that owns the agent (ERC-721 compatible). |
| `tokenURI(agentId)` | Metadata URI (ERC-721 compatible). |
| `agentURI(agentId)` | Metadata URI (ERC-8004 alias). |
| `canonicalUEA(agentId)` | UEA address for an agent ID. |
| `agentIdOfUEA(uea)` | Agent ID for a UEA address (0 if unregistered). |
| `getShadows(agentId)` | All shadow entries for an agent. |
| `canonicalUEAFromShadow(ns, id, addr, shadowId)` | Resolve shadow to canonical UEA. |
| `isRegistered(agentId)` | Check registration status. |
| `getAgentRecord(agentId)` | Full on-chain record. |

### Admin

| Function | Access | Description |
|----------|--------|-------------|
| `pause()` | PAUSER_ROLE | Pause all state-changing operations. |
| `unpause()` | PAUSER_ROLE | Resume operations. |
