# PRD: UAIRegistry — Universal Agent Identity Registry on Push Chain

## 1. Project Summary

An ERC-8004-compatible Identity Registry deployed on Push Chain that uses the agent's Universal Executor Account (UEA) address as the canonical, chain-agnostic agent identifier. Per-chain ERC-8004 registries become "shadow registries" that link their local `agentId` to the canonical UEA via cryptographic proof of key ownership. The contract is non-transferable (soulbound), uses `agentId = uint256(uint160(ueaAddress)) % 10_000_000` for deterministic 7-digit IDs (with collision guard and zero-reservation), and supports verified shadow linking via EIP-712 signatures from per-chain NFT owners. This PRD covers core registration, shadow linking, and test infrastructure (Milestones M1 + M2 + M5 from the project idea).

> **Note:** This PRD was written for the original full-uint160 agent ID design. The implementation now uses 7-digit truncated IDs (`% 10_000_000`). References to `agentId = uint256(uint160(msg.sender))` throughout this document should be read as `uint256(uint160(msg.sender)) % 10_000_000`. ID 0 is reserved as sentinel; addresses truncating to 0 receive ID 10_000_000. `AgentIdCollision` reverts if two addresses share the same truncated ID.

## 2. Problem Context

ERC-8004's Identity Registry is a per-chain singleton: each chain mints its own ERC-721 `agentId` via an incrementing counter, and no on-chain mechanism links `agentId=42` on Ethereum to `agentId=17` on Base (Limitation (a): Identity fragmentation — P0). Reputation earned on one chain is invisible to contracts on another (Limitation (b): Reputation siloing — P0). The only cross-chain hook is the off-chain `registrations[]` JSON array — self-asserted, unverified, and unreadable by smart contracts (Limitation (e): Agent Card centralization risk — P1).

Push Chain's UEA primitive solves this at the account layer: every external-chain user gets a deterministic address on Push Chain derived from `keccak256(abi.encode(chainNamespace, chainId, owner))`. This address exists implicitly before deployment and is computable by anyone with the origin identity. UAIRegistry wraps this primitive in an ERC-8004-compatible interface, making UEA addresses the canonical agent identity and per-chain registries the shadows that defer to it.

The key insight: `UEAFactory.computeUEA(UniversalAccountId)` is already an on-chain CAIP-10 resolver. UAIRegistry gives it an ERC-8004 shape.

## 3. Technical Specification

### 3a. Architecture Overview

```
┌──────────────────────────────────────────────────────────────────┐
│                    Push Chain (Chain ID: 42101)                   │
│                                                                  │
│  UEAFactory (0x00...eA)                                          │
│  ├─ computeUEA(UniversalAccountId) → address                    │
│  ├─ getOriginForUEA(address) → (UniversalAccountId, isUEA)      │
│  └─ deployUEA(UniversalAccountId) → address                     │
│                                                                  │
│  UAIRegistry (deployed via TransparentUpgradeableProxy)          │
│  ├─ register(agentURI, agentCardHash)                            │
│  │   └─ agentId = uint256(uint160(msg.sender))                  │
│  │   └─ verifies msg.sender is a UEA or Push-native account     │
│  ├─ linkShadow(ShadowLinkRequest)                                │
│  │   └─ verifies EIP-712 signature from shadow-NFT owner        │
│  │   └─ stores (chainNs, chainId, registry, shadowAgentId) link │
│  ├─ unlinkShadow(chainNs, chainId, registry)                    │
│  ├─ canonicalUEAFromShadow(chainNs, chainId, registry, id)      │
│  │   └─ O(1) reverse lookup: shadow → canonical UEA             │
│  ├─ ERC-721 read surface (ownerOf, tokenURI)                    │
│  │   └─ ownerOf(agentId) = address(uint160(agentId))            │
│  └─ ERC-721 transfer surface → REVERTS (soulbound)              │
│                                                                  │
│  ProxyAdmin (transparent proxy admin, multisig-controlled)       │
└──────────────────────────────────────────────────────────────────┘
                              │
                     shadow links point to
                              │
        ┌─────────────────────┼─────────────────────┐
        ▼                     ▼                     ▼
┌───────────────┐   ┌───────────────┐   ┌───────────────┐
│   Ethereum    │   │     Base      │   │   Arbitrum    │
│ IdentityReg  │   │ IdentityReg   │   │ IdentityReg   │
│ agentId=42    │   │ agentId=17    │   │ agentId=8     │
│ (0x8004A169)  │   │ (0x8004A169)  │   │ (0x8004A169)  │
└───────────────┘   └───────────────┘   └───────────────┘
    All three shadow IDs link to one canonical UEA on Push Chain
```

**On-chain components (Push Chain only for v1):**

- **`UAIRegistry.sol`** — The main contract. Upgradeable via transparent proxy. Implements the ERC-8004-compatible read surface, canonical registration, shadow linking with EIP-712 verification, and soulbound transfer reverts. Single contract, no external oracle or keeper.

**Off-chain components:**
- None for v1. Gateway integration (external chain → Push Chain round-trip) is deferred to a follow-up PRD.

**External dependencies:**
- `IUEAFactory` interface for UEA validation (read-only calls to `getOriginForUEA`).
- OpenZeppelin upgradeable contracts for proxy pattern and access control.

### 3b. Smart Contract Interfaces

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IUAIRegistry
/// @notice ERC-8004-compatible Universal Agent Identity Registry on Push Chain.
///         Uses UEA addresses as canonical agent identifiers.
///         agentId = uint256(uint160(ueaAddress)) — deterministic, collision-free.
///         Non-transferable (soulbound).
interface IUAIRegistry {

    // ──────────────────────────────────────────────
    //  Types
    // ──────────────────────────────────────────────

    /// @notice Proof type for shadow registry linking.
    enum ShadowProofType {
        /// EIP-712 signature from the shadow-chain NFT owner.
        OWNER_KEY_SIGNED
    }

    /// @notice Stored record of a canonical agent registration.
    struct AgentRecord {
        bool registered;
        string agentURI;
        bytes32 agentCardHash;
        uint64 registeredAt;
        string originChainNamespace;
        string originChainId;
        bytes ownerKey;
        bool nativeToPush;
    }

    /// @notice Stored record of a shadow registry link.
    struct ShadowEntry {
        string chainNamespace;
        string chainId;
        address registryAddress;
        uint256 shadowAgentId;
        ShadowProofType proofType;
        bool verified;
        uint64 linkedAt;
    }

    /// @notice Input parameters for creating a shadow link.
    struct ShadowLinkRequest {
        string chainNamespace;
        string chainId;
        address registryAddress;
        uint256 shadowAgentId;
        ShadowProofType proofType;
        bytes proofData;
        uint256 nonce;
        uint256 deadline;
    }

    // ──────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────

    /// @notice Emitted when a new agent registers or updates their record.
    event Registered(
        uint256 indexed agentId,
        address indexed uea,
        string originChainNamespace,
        string originChainId,
        bytes ownerKey,
        string agentURI,
        bytes32 agentCardHash
    );

    /// @notice Emitted when an agent's URI is updated.
    event AgentURIUpdated(uint256 indexed agentId, string newAgentURI);

    /// @notice Emitted when an agent's card hash is updated.
    event AgentCardHashUpdated(uint256 indexed agentId, bytes32 newHash);

    /// @notice Emitted when a shadow registry link is created.
    event ShadowLinked(
        uint256 indexed agentId,
        string chainNamespace,
        string chainId,
        address registryAddress,
        uint256 shadowAgentId,
        ShadowProofType proofType,
        bool verified
    );

    /// @notice Emitted when a shadow registry link is removed.
    event ShadowUnlinked(
        uint256 indexed agentId,
        string chainNamespace,
        string chainId,
        address registryAddress
    );

    // ──────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────

    /// @notice The agent record does not exist.
    error AgentNotRegistered(uint256 agentId);

    /// @notice Caller is not the UEA that owns this agentId.
    error NotAgentOwner(uint256 agentId, address caller);

    /// @notice The agent card hash is zero (required).
    error AgentCardHashRequired();

    /// @notice A shadow link already exists for this
    ///         (chainNamespace, chainId, registry, shadowAgentId) tuple.
    error ShadowAlreadyClaimed(
        string chainNamespace,
        string chainId,
        address registryAddress,
        uint256 shadowAgentId
    );

    /// @notice No shadow link exists for the given parameters.
    error ShadowNotFound(
        string chainNamespace,
        string chainId,
        address registryAddress
    );

    /// @notice The shadow link deadline has passed.
    error ShadowLinkExpired(uint256 deadline);

    /// @notice The shadow link nonce has already been used.
    error ShadowLinkNonceUsed(uint256 nonce);

    /// @notice The EIP-712 signature is invalid.
    error InvalidShadowSignature();

    /// @notice The chain namespace or chain ID is empty.
    error InvalidChainIdentifier();

    /// @notice The registry address is zero.
    error InvalidRegistryAddress();

    /// @notice Agent identity is soulbound and cannot be transferred.
    error IdentityNotTransferable();

    /// @notice Maximum shadow links per agent (64) exceeded.
    error MaxShadowsExceeded(uint256 agentId);

    // ──────────────────────────────────────────────
    //  Registration
    // ──────────────────────────────────────────────

    /// @notice Register or update the canonical identity for the calling UEA.
    ///         agentId = uint256(uint160(msg.sender)).
    ///         Idempotent: re-calling updates agentURI and agentCardHash.
    ///         agentCardHash is required (non-zero). agentURI is optional
    ///         (can be empty string, set later via setAgentURI).
    /// @param agentURI IPFS / HTTPS / data URI to the Agent Registration File.
    /// @param agentCardHash keccak256 of the canonical Agent Registration File.
    /// @return agentId The deterministic agent ID.
    function register(
        string calldata agentURI,
        bytes32 agentCardHash
    ) external returns (uint256 agentId);

    /// @notice Update the agent's URI pointer.
    /// @param newAgentURI The new URI.
    function setAgentURI(string calldata newAgentURI) external;

    /// @notice Update the agent's card content hash anchor.
    /// @param newHash The new keccak256 hash of the Agent Registration File.
    function setAgentCardHash(bytes32 newHash) external;

    // ──────────────────────────────────────────────
    //  Shadow Linking
    // ──────────────────────────────────────────────

    /// @notice Link a per-chain ERC-8004 shadow registration to this
    ///         canonical UEA. Requires an EIP-712 signature from the
    ///         shadow-chain NFT owner proving they authorize the link.
    ///         The signed message includes: canonical UEA address,
    ///         shadow tuple (chainNs, chainId, registry, shadowAgentId),
    ///         nonce, and deadline.
    /// @param req The shadow link request with proof data.
    function linkShadow(ShadowLinkRequest calldata req) external;

    /// @notice Remove a shadow link. Only callable by the canonical agent.
    /// @param chainNamespace CAIP-2 namespace (e.g., "eip155").
    /// @param chainId CAIP-2 chain ID (e.g., "1").
    /// @param registryAddress The per-chain Identity Registry address.
    function unlinkShadow(
        string calldata chainNamespace,
        string calldata chainId,
        address registryAddress
    ) external;

    // ──────────────────────────────────────────────
    //  Reads — ERC-8004-shaped
    // ──────────────────────────────────────────────

    /// @notice Returns the UEA address that owns the agentId.
    ///         Always returns address(uint160(agentId)) if registered.
    /// @param agentId The agent's deterministic ID.
    /// @return The UEA address.
    function ownerOf(uint256 agentId) external view returns (address);

    /// @notice Returns the agent's registration file URI.
    /// @param agentId The agent's ID.
    /// @return The URI string.
    function tokenURI(uint256 agentId) external view returns (string memory);

    /// @notice Alias for tokenURI, per ERC-8004 convention.
    function agentURI(uint256 agentId) external view returns (string memory);

    // ──────────────────────────────────────────────
    //  Reads — UAIRegistry-specific
    // ──────────────────────────────────────────────

    /// @notice Direct UEA lookup from agentId.
    function canonicalUEA(uint256 agentId) external view returns (address);

    /// @notice Reverse lookup: UEA → agentId. Returns 0 if not registered.
    function agentIdOfUEA(address uea) external view returns (uint256);

    /// @notice Get all shadow entries for an agent.
    function getShadows(
        uint256 agentId
    ) external view returns (ShadowEntry[] memory);

    /// @notice Resolve a canonical UEA from a per-chain shadow registration.
    ///         The primary cross-chain resolution function.
    /// @return canonical The UEA address (address(0) if no link exists).
    /// @return verified Whether the link was cryptographically verified.
    function canonicalUEAFromShadow(
        string calldata chainNamespace,
        string calldata chainId,
        address registryAddress,
        uint256 shadowAgentId
    ) external view returns (address canonical, bool verified);

    /// @notice Check if an agentId is registered.
    function isRegistered(uint256 agentId) external view returns (bool);

    /// @notice Get the full agent record.
    function getAgentRecord(
        uint256 agentId
    ) external view returns (AgentRecord memory);

    // ──────────────────────────────────────────────
    //  ERC-721 transfer surface — all revert
    // ──────────────────────────────────────────────

    /// @notice Reverts with IdentityNotTransferable().
    function transferFrom(address from, address to, uint256 tokenId) external;

    /// @notice Reverts with IdentityNotTransferable().
    function safeTransferFrom(
        address from, address to, uint256 tokenId
    ) external;

    /// @notice Reverts with IdentityNotTransferable().
    function safeTransferFrom(
        address from, address to, uint256 tokenId, bytes calldata data
    ) external;

    /// @notice Reverts with IdentityNotTransferable().
    function approve(address spender, uint256 tokenId) external;

    /// @notice Reverts with IdentityNotTransferable().
    function setApprovalForAll(address operator, bool approved) external;
}
```

### 3c. Data Structures and Storage Layout

UAIRegistry uses ERC-7201 namespaced storage for upgrade safety, matching the ERC-8004 IdentityRegistry's pattern.

```solidity
/// @custom:storage-location erc7201:uairegistry.storage
struct UAIRegistryStorage {
    /// @dev agentId → AgentRecord.
    mapping(uint256 => AgentRecord) records;

    /// @dev agentId → ShadowEntry[]. Capped at 64 entries per agent.
    mapping(uint256 => ShadowEntry[]) shadows;

    /// @dev shadowKey → agentId. Reverse lookup for canonicalUEAFromShadow().
    ///      shadowKey = keccak256(abi.encode(chainNs, chainId, registry, shadowAgentId))
    mapping(bytes32 => uint256) shadowToCanonical;

    /// @dev agentId → shadowKey → index in shadows array.
    ///      Used for O(1) unlinkShadow without iterating.
    ///      shadowKey = keccak256(abi.encode(chainNs, chainId, registry))
    mapping(uint256 => mapping(bytes32 => uint256)) shadowIndex;

    /// @dev agentId → shadowKey → exists flag (dedup for shadowIndex which uses 0).
    mapping(uint256 => mapping(bytes32 => bool)) shadowExists;

    /// @dev agentId → nonce → used flag. Replay protection for linkShadow signatures.
    mapping(uint256 => mapping(uint256 => bool)) usedNonces;
}
```

Storage slot: `keccak256(abi.encode(uint256(keccak256("uairegistry.storage")) - 1)) & ~bytes32(uint256(0xff))`

**Immutables (set in constructor, not in storage):**

```solidity
/// @dev UEAFactory address on Push Chain.
IUEAFactory public immutable ueaFactory;
```

**Access control (inherited from AccessControlUpgradeable):**

```solidity
bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
```

Single pause controls `register`, `linkShadow`, `unlinkShadow`, `setAgentURI`, `setAgentCardHash`. Read functions are never paused.

**EIP-712 domain for shadow link signatures:**

```solidity
EIP712Domain(
    string name,      // "UAIRegistry"
    string version,   // "1"
    uint256 chainId,  // Push Chain chain ID (42101 on testnet)
    address verifyingContract // UAIRegistry proxy address
)
```

**EIP-712 typed data for shadow linking:**

```solidity
bytes32 constant SHADOW_LINK_TYPEHASH = keccak256(
    "ShadowLink(address canonicalUEA,string chainNamespace,string chainId,"
    "address registryAddress,uint256 shadowAgentId,uint256 nonce,uint256 deadline)"
);
```

The shadow-chain NFT owner signs this typed data with the UAIRegistry's Push Chain domain. The `canonicalUEA` field binds the signature to a specific UEA, preventing an attacker from reusing the signature to link to a different canonical identity.

**Struct hash construction:**

```solidity
keccak256(abi.encode(
    SHADOW_LINK_TYPEHASH,
    canonicalUEA,
    keccak256(bytes(chainNamespace)),
    keccak256(bytes(chainId)),
    registryAddress,
    shadowAgentId,
    nonce,
    deadline
))
```

Note: `string` fields are hashed per EIP-712 encoding rules (`keccak256(bytes(str))`).

### 3d. External Dependencies

| Dependency | Address / Version | Interface Used | Trust Assumption |
|---|---|---|---|
| UEAFactory (Push Chain testnet) | `0x00000000000000000000000000000000000000eA` | `getOriginForUEA(address) → (UniversalAccountId, bool)` — read-only, called in `register()` to snapshot origin metadata | Push Chain core contract. Audited by Hacken. Immutable address (vanity predeploy). |
| `IUEAFactory` interface | From `push-chain-core-contracts/src/Interfaces/IUEAFactory.sol` | See above | Interface only, no trust assumption. |
| `Types.sol` (UniversalAccountId) | From `push-chain-core-contracts/src/libraries/Types.sol` | Struct definition for `UniversalAccountId{chainNamespace, chainId, owner}` | Type definition only. |
| OpenZeppelin Contracts Upgradeable | v5.3.0 | `Initializable`, `AccessControlUpgradeable`, `PausableUpgradeable`, `EIP712Upgradeable`, `ECDSA` | Audited, widely used. |
| OpenZeppelin Contracts (non-upgradeable) | v5.3.0 | `IERC1271`, `IERC721` (for interface ID support in `supportsInterface`) | Same. |
| ERC-8004 Identity Registry (all mainnets) | `0x8004A169FB4a3325136EB29fA0ceB6D2e539a432` | **Not called by UAIRegistry.** Referenced as the `registryAddress` value inside shadow link entries. | None — UAIRegistry does not read from per-chain registries. |
| ERC-8004 Identity Registry (all testnets) | `0x8004A818BFB912233c491871b3d84c89A494BD9e` | Same as above. Used in tests. | None. |

### 3e. Security Considerations

**S1. Shadow link spoofing — attacker links a shadow agentId they don't own.**
The `OWNER_KEY_SIGNED` proof requires an EIP-712 signature over `(canonicalUEA, chainNs, chainId, registry, shadowAgentId, nonce, deadline)` from the shadow-chain NFT owner. The signature is verified via `ECDSA.recover` (EOAs) or `IERC1271.isValidSignature` (smart wallets). The `canonicalUEA` field in the signed message binds the signature to a specific UEA — an attacker cannot reuse someone else's signature to link to their own UEA. The nonce prevents replay. The deadline prevents indefinite validity.

**S2. Identity hijack via key compromise.**
If an attacker compromises the external-chain owner key, they can register the canonical UAIRegistry record first (since `register()` is idempotent and first-write-wins for origin metadata). Mitigation: the UEA's deterministic address means the legitimate owner can detect the hijack by checking `isRegistered(computedAgentId)` before transacting. Recovery requires UEA-level migration (existing Push Chain primitive), which is out of scope for v1 but architecturally supported.

**S3. Shadow array DoS.**
A malicious agent links many fake shadows, bloating `getShadows()` gas cost. Mitigation: hard cap of 64 shadows per agent (`MaxShadowsExceeded` error). 64 is generous — more chains than any agent would realistically operate on — while bounding worst-case `getShadows()` gas to ~64 × 5K = 320K.

**S4. Shadow deduplication key collision.**
The `_shadowToCanonical` mapping uses `keccak256(abi.encode(chainNs, chainId, registry, shadowAgentId))` as the key. Two different agents claiming the same shadow tuple collide by design — the second attempt reverts with `ShadowAlreadyClaimed`. This is correct: one physical per-chain NFT should map to at most one canonical UEA.

**S5. EIP-712 domain binding.**
The signature domain uses Push Chain's chain ID and the UAIRegistry proxy address. Signatures created for one UAIRegistry deployment cannot be replayed against another (e.g., testnet vs mainnet, or a redeployed proxy). The domain is constructed via OpenZeppelin's `EIP712Upgradeable`, which handles the domain separator caching correctly for proxied contracts.

**S6. Soulbound transfer enforcement.**
All ERC-721 transfer and approval functions revert with `IdentityNotTransferable()`. This prevents: (a) transferring an identity token to a new address, which would decouple agentId from the UEA key, and (b) approval-based attacks where an approved operator transfers the identity. The `ownerOf(agentId)` function always returns `address(uint160(agentId))` — it does not read from a mapping, so it cannot be manipulated.

**S7. Reentrancy on register() and linkShadow().**
`register()` makes one external view call: `ueaFactory.getOriginForUEA(msg.sender)`. This is a `view` function on an immutable infrastructure contract — no reentrancy vector. `linkShadow()` performs only ECDSA signature recovery (pure computation) or an ERC-1271 `staticcall`. `staticcall` prevents state modifications. Neither function has external calls before state updates beyond these read-only calls.

**S8. Nonce management for shadow link signatures.**
Nonces are per-agentId (not global), stored in `usedNonces[agentId][nonce]`. The signer chooses the nonce; the contract checks it hasn't been used. This is simpler than a sequential nonce (no off-chain nonce tracking needed) but means the signer must avoid nonce reuse. For the shadow linking use case (infrequent, manual operation), this is acceptable.

**S9. Pause scope.**
Single `pause()` freezes all write operations. Read functions (`ownerOf`, `tokenURI`, `canonicalUEAFromShadow`, `getShadows`, etc.) are never paused. This ensures existing agents remain queryable during an emergency pause.

### 3f. Gas Analysis

Gas estimates for Push Chain (EVM-compatible, similar gas pricing to L2s).

| Operation | Estimated Gas | Breakdown |
|---|---|---|
| `register()` (first time) | ~95,000–120,000 | `getOriginForUEA` view call (~5K) + storage writes for AgentRecord (5 fields, ~60K) + string storage for agentURI (~15K–30K depending on length) + event emission (~10K) |
| `register()` (update) | ~45,000–70,000 | Storage reads (~5K) + storage updates for agentURI + agentCardHash (~25K) + event (~10K) |
| `setAgentURI()` | ~30,000–50,000 | Ownership check (~3K) + string storage update (~20K–40K) + event (~5K) |
| `setAgentCardHash()` | ~30,000 | Ownership check (~3K) + bytes32 storage update (~5K) + event (~5K) |
| `linkShadow()` | ~120,000–150,000 | Nonce check (~5K) + ECDSA recover (~26K) + dedup key check (~5K) + ShadowEntry storage (~50K) + shadowToCanonical write (~20K) + shadowIndex write (~20K) + event (~10K) |
| `unlinkShadow()` | ~40,000–50,000 | Ownership check + shadow lookup (~10K) + array swap-and-pop (~15K) + clear mappings (~10K) + event (~5K) |
| `canonicalUEAFromShadow()` | ~5,000–8,000 | Compute key hash (~1K) + single SLOAD (~2K) + agentId → address conversion (~100) |
| `ownerOf()` | ~3,000 | Registration check (~2K) + uint256 → address cast (~100) |
| `getShadows()` | ~8,000–40,000 | Array copy (~5K base + ~5K per entry, max 64 entries) |

**Economic viability:** On Push Chain with sub-cent gas costs, all operations are economically negligible. Registration and shadow linking are one-time setup costs. `canonicalUEAFromShadow()` is a view function — free when called off-chain, ~5K gas when called by another contract.

## 4. Implementation Guide

### Step 1: Initialize Foundry project

Create the Foundry project and install dependencies.

**Commands:**
```bash
cd ai-on-chain-projects/uai-registry
forge init --no-git --no-commit .
forge install OpenZeppelin/openzeppelin-contracts@v5.3.0 --no-git --no-commit
forge install OpenZeppelin/openzeppelin-contracts-upgradeable@v5.3.0 --no-git --no-commit
```

**Configure `foundry.toml`:**
```toml
[profile.default]
src = "src"
out = "out"
libs = ["lib"]
solc = "0.8.26"
optimizer = true
optimizer_runs = 10000
via_ir = false
evm_version = "cancun"

remappings = [
    "@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/",
    "@openzeppelin/contracts-upgradeable/=lib/openzeppelin-contracts-upgradeable/contracts/",
]

[profile.default.fuzz]
runs = 1000
max_test_rejects = 100000

[fmt]
line_length = 100
tab_width = 4
bracket_spacing = false
int_types = "long"
multiline_func_header = "params_first"
quote_style = "double"
number_underscore = "thousands"
```

Create the Push Chain interface files locally (copied from the Push Chain core contracts repo — these are interface-only, no implementation dependency):

**File:** `src/interfaces/IUEAFactory.sol` — copy from `/Users/zar/Code/blockchain/evm/audit_check/core/push-chain-core-contracts/src/Interfaces/IUEAFactory.sol`

**File:** `src/interfaces/Types.sol` — copy the `UniversalAccountId` struct and related types from `/Users/zar/Code/blockchain/evm/audit_check/core/push-chain-core-contracts/src/libraries/Types.sol`. Only include the struct definition and constants needed by UAIRegistry (not the full Types.sol).

**Verification:** `forge build` succeeds with no warnings.

### Step 2: Implement UAIRegistry core (registration + ERC-721 surface)

**File:** `src/UAIRegistry.sol`

Implement:
- Inherit `Initializable`, `AccessControlUpgradeable`, `PausableUpgradeable`, `EIP712Upgradeable`
- Constructor: set `ueaFactory` as immutable, `_disableInitializers()`
- `initialize(address admin, address pauser)`:
  - `__AccessControl_init()`, `__Pausable_init()`, `__EIP712_init("UAIRegistry", "1")`
  - Grant `DEFAULT_ADMIN_ROLE` to admin, `PAUSER_ROLE` to pauser
- `register(string calldata agentURI, bytes32 agentCardHash)`:
  - Require `agentCardHash != bytes32(0)` → `AgentCardHashRequired`
  - `agentId = uint256(uint160(msg.sender))`
  - Call `ueaFactory.getOriginForUEA(msg.sender)` to get origin metadata
  - If `!record.registered`: first registration, store full AgentRecord
  - If `record.registered`: update only `agentURI` and `agentCardHash`
  - Emit `Registered`
- `setAgentURI(string calldata newAgentURI)`:
  - `agentId = uint256(uint160(msg.sender))`, require registered
  - Update, emit `AgentURIUpdated`
- `setAgentCardHash(bytes32 newHash)`:
  - Same pattern, require `newHash != bytes32(0)`
  - Emit `AgentCardHashUpdated`
- ERC-721 read surface:
  - `ownerOf(agentId)`: require registered, return `address(uint160(agentId))`
  - `tokenURI(agentId)`: require registered, return `records[agentId].agentURI`
  - `agentURI(agentId)`: alias for `tokenURI`
- `canonicalUEA(agentId)`: same as `ownerOf`
- `agentIdOfUEA(address uea)`: return `uint256(uint160(uea))` if registered, else 0
- `isRegistered(uint256 agentId)`: return `records[agentId].registered`
- `getAgentRecord(uint256 agentId)`: return full record
- ERC-721 transfer surface: all 5 functions revert with `IdentityNotTransferable()`
- `supportsInterface(bytes4)`: return true for `IERC721` and `IERC165` interface IDs
- `pause()` / `unpause()`: gated by `PAUSER_ROLE`

**Verification:** `forge build` succeeds.

### Step 3: Implement shadow linking

**File:** `src/UAIRegistry.sol` (extend the same contract)

Add to the existing contract:
- `SHADOW_LINK_TYPEHASH` constant
- `MAX_SHADOWS = 64` constant
- `linkShadow(ShadowLinkRequest calldata req)`:
  1. `whenNotPaused`
  2. `agentId = uint256(uint160(msg.sender))`, require registered → `AgentNotRegistered`
  3. Validate inputs: chainNamespace non-empty, chainId non-empty → `InvalidChainIdentifier`; registryAddress non-zero → `InvalidRegistryAddress`
  4. Check `req.deadline >= block.timestamp` → `ShadowLinkExpired`
  5. Check `!usedNonces[agentId][req.nonce]` → `ShadowLinkNonceUsed`
  6. Mark nonce used
  7. Compute shadow dedup key `keccak256(abi.encode(chainNs, chainId, registry, shadowAgentId))`
  8. Check `shadowToCanonical[dedupKey] == 0` (no existing claim) → `ShadowAlreadyClaimed`
  9. Check `shadows[agentId].length < MAX_SHADOWS` → `MaxShadowsExceeded`
  10. Verify EIP-712 signature: reconstruct struct hash, compute typed data hash via `_hashTypedDataV4()`, recover signer via `ECDSA.tryRecover`. For `OWNER_KEY_SIGNED`: the recovered signer is the shadow-chain NFT owner who authorized the link. Store `verified = true` if recovery succeeds and signer is non-zero.
  11. Store `ShadowEntry` in `shadows[agentId]`
  12. Store reverse lookup: `shadowToCanonical[dedupKey] = agentId`
  13. Store index: `shadowIndex[agentId][shadowChainKey] = index`, `shadowExists[agentId][shadowChainKey] = true` (where shadowChainKey = `keccak256(abi.encode(chainNs, chainId, registry))`)
  14. Emit `ShadowLinked`

- `unlinkShadow(chainNamespace, chainId, registryAddress)`:
  1. `whenNotPaused`
  2. `agentId = uint256(uint160(msg.sender))`, require registered
  3. Compute `shadowChainKey`, check `shadowExists[agentId][shadowChainKey]` → `ShadowNotFound`
  4. Get index from `shadowIndex`, load the `ShadowEntry`
  5. Compute full dedup key, clear `shadowToCanonical[dedupKey]`
  6. Swap-and-pop the shadows array (move last element to the removed position, update its index)
  7. Clear `shadowExists` and `shadowIndex`
  8. Emit `ShadowUnlinked`

- `canonicalUEAFromShadow(chainNs, chainId, registry, shadowAgentId)`:
  1. Compute dedup key
  2. `agentId = shadowToCanonical[dedupKey]`
  3. If 0, return `(address(0), false)`
  4. Return `(address(uint160(agentId)), shadows[agentId][index].verified)`

- `getShadows(uint256 agentId)`: return `shadows[agentId]`

**Verification:** `forge build` succeeds.

### Step 4: Implement test mocks

**File:** `test/mocks/MockUEAFactory.sol`

A minimal mock implementing `IUEAFactory.getOriginForUEA(address)`:
- Constructor takes a list of `(address, UniversalAccountId)` pairs to pre-register
- `addUEA(address, UniversalAccountId)` — add a UEA mapping
- `getOriginForUEA(address)` — returns the registered mapping, or synthetic fallback (matching real UEAFactory behavior)
- `computeUEA(UniversalAccountId)` — returns a deterministic address via `keccak256`

Other `IUEAFactory` functions can revert with "not implemented" — UAIRegistry only calls `getOriginForUEA`.

**Verification:** `forge build` succeeds.

### Step 5: Implement unit tests — registration and ERC-721 surface

**File:** `test/UAIRegistry.t.sol`

Deploy `MockUEAFactory`, `UAIRegistry` (behind a transparent proxy), and initialize in `setUp()`.

**Registration tests:**

| Test Function | Scenario |
|---|---|
| `test_Register_FirstTime_CreatesRecord` | UEA calls register, record created with correct fields |
| `test_Register_FirstTime_EmitsRegistered` | Event fields match inputs |
| `test_Register_Update_UpdatesURIAndHash` | Re-call register with new URI/hash, only those fields change |
| `test_Register_ZeroCardHash_Reverts` | `agentCardHash = bytes32(0)` reverts with `AgentCardHashRequired` |
| `test_Register_EmptyURI_Succeeds` | Empty string URI is allowed |
| `test_Register_AgentIdDeterministic` | `agentId == uint256(uint160(caller))` |
| `test_Register_OriginMetadataFromFactory` | Origin chain namespace/id/ownerKey match MockUEAFactory response |
| `test_Register_NativePushAccount` | Non-UEA caller gets `nativeToPush = true` |
| `test_Register_WhenPaused_Reverts` | Paused state blocks registration |

**setAgentURI / setAgentCardHash tests:**

| Test Function | Scenario |
|---|---|
| `test_SetAgentURI_Owner_Updates` | Owner updates URI successfully |
| `test_SetAgentURI_NotRegistered_Reverts` | Unregistered agent reverts |
| `test_SetAgentURI_NotOwner_Reverts` | Different caller reverts |
| `test_SetAgentCardHash_Owner_Updates` | Owner updates hash |
| `test_SetAgentCardHash_ZeroHash_Reverts` | Zero hash reverts |
| `test_SetAgentCardHash_WhenPaused_Reverts` | Paused state blocks |

**ERC-721 read surface tests:**

| Test Function | Scenario |
|---|---|
| `test_OwnerOf_RegisteredAgent_ReturnsUEA` | Returns `address(uint160(agentId))` |
| `test_OwnerOf_UnregisteredAgent_Reverts` | Reverts with `AgentNotRegistered` |
| `test_TokenURI_ReturnsStoredURI` | Returns the URI set during registration |
| `test_AgentURI_AliasesTokenURI` | Same output as `tokenURI` |
| `test_CanonicalUEA_SameAsOwnerOf` | `canonicalUEA == ownerOf` for registered agents |
| `test_AgentIdOfUEA_Registered_ReturnsId` | Correct reverse lookup |
| `test_AgentIdOfUEA_NotRegistered_ReturnsZero` | Returns 0 |
| `test_IsRegistered_True` | Registered agent |
| `test_IsRegistered_False` | Unregistered agent |
| `test_GetAgentRecord_ReturnsFullRecord` | All fields correct |

**ERC-721 transfer revert tests:**

| Test Function | Scenario |
|---|---|
| `test_TransferFrom_Reverts` | Always reverts with `IdentityNotTransferable` |
| `test_SafeTransferFrom_Reverts` | Same |
| `test_SafeTransferFromWithData_Reverts` | Same |
| `test_Approve_Reverts` | Same |
| `test_SetApprovalForAll_Reverts` | Same |

**SupportsInterface tests:**

| Test Function | Scenario |
|---|---|
| `test_SupportsInterface_IERC721` | Returns true for ERC-721 interface ID |
| `test_SupportsInterface_IERC165` | Returns true for ERC-165 interface ID |

**Verification:** `forge test --match-path test/UAIRegistry.t.sol -vv` — all tests pass.

### Step 6: Implement unit tests — shadow linking

**File:** `test/UAIRegistryShadow.t.sol`

**linkShadow tests:**

| Test Function | Scenario |
|---|---|
| `test_LinkShadow_ValidSignature_CreatesLink` | Happy path: EIP-712 signed by shadow NFT owner, link created |
| `test_LinkShadow_EmitsEvent` | `ShadowLinked` event with correct fields |
| `test_LinkShadow_NotRegistered_Reverts` | Unregistered caller |
| `test_LinkShadow_ExpiredDeadline_Reverts` | `deadline < block.timestamp` |
| `test_LinkShadow_ReusedNonce_Reverts` | Same nonce used twice |
| `test_LinkShadow_InvalidSignature_Reverts` | Wrong signer key |
| `test_LinkShadow_EmptyChainNamespace_Reverts` | Empty string chainNamespace |
| `test_LinkShadow_EmptyChainId_Reverts` | Empty string chainId |
| `test_LinkShadow_ZeroRegistry_Reverts` | `registryAddress = address(0)` |
| `test_LinkShadow_DuplicateShadow_Reverts` | Same shadow tuple linked twice |
| `test_LinkShadow_DifferentAgentSameShadow_Reverts` | Agent B tries to claim shadow already linked by Agent A |
| `test_LinkShadow_MaxShadowsExceeded_Reverts` | 65th shadow link fails |
| `test_LinkShadow_64Shadows_Succeeds` | 64th shadow link succeeds (boundary) |
| `test_LinkShadow_WhenPaused_Reverts` | Paused state blocks |
| `test_LinkShadow_MultipleShadows_AllStored` | Link 3 shadows, verify all in getShadows |

**unlinkShadow tests:**

| Test Function | Scenario |
|---|---|
| `test_UnlinkShadow_Owner_RemovesLink` | Happy path: link removed, canonicalUEAFromShadow returns zero |
| `test_UnlinkShadow_EmitsEvent` | `ShadowUnlinked` event |
| `test_UnlinkShadow_NotRegistered_Reverts` | Unregistered caller |
| `test_UnlinkShadow_NotOwner_Reverts` | Different caller |
| `test_UnlinkShadow_NoLink_Reverts` | Shadow doesn't exist |
| `test_UnlinkShadow_RelinkAfterUnlink_Succeeds` | Unlink then re-link same shadow |
| `test_UnlinkShadow_SwapAndPop_Preserves` | Unlink middle element, verify remaining elements are intact |
| `test_UnlinkShadow_WhenPaused_Reverts` | Paused state blocks |

**canonicalUEAFromShadow tests:**

| Test Function | Scenario |
|---|---|
| `test_CanonicalUEAFromShadow_LinkedAgent_ReturnsUEA` | Returns correct UEA address |
| `test_CanonicalUEAFromShadow_VerifiedFlag` | `verified = true` for valid sig |
| `test_CanonicalUEAFromShadow_NoLink_ReturnsZero` | Returns `(address(0), false)` |
| `test_CanonicalUEAFromShadow_AfterUnlink_ReturnsZero` | Unlinked shadow returns zero |

**getShadows tests:**

| Test Function | Scenario |
|---|---|
| `test_GetShadows_ReturnsAll` | Multiple shadows returned in order |
| `test_GetShadows_EmptyAgent_ReturnsEmpty` | No shadows returns empty array |

**Verification:** `forge test --match-path test/UAIRegistryShadow.t.sol -vv` — all tests pass.

### Step 7: Implement fuzz and invariant tests

**File:** `test/UAIRegistry.fuzz.t.sol`

| Test Function | Invariant |
|---|---|
| `testFuzz_Register_AgentIdAlwaysMatchesCaller(address caller)` | `agentId == uint256(uint160(caller))` for any caller. Bound: exclude address(0). |
| `testFuzz_OwnerOf_AlwaysMatchesAgentId(uint256 agentId)` | If registered, `ownerOf(agentId) == address(uint160(agentId))`. |
| `testFuzz_LinkShadow_OnlyAcceptsCorrectSigner(uint256 signerKey, uint256 wrongKey, uint256 shadowAgentId)` | Signature from `signerKey` verifies; signature from `wrongKey` fails. Bound: both keys valid, distinct. |
| `testFuzz_ShadowDedup_NoDuplicates(uint256 shadowAgentId, uint256 chainId)` | After a successful link, a second link with the same shadow tuple always reverts. |
| `testFuzz_UnlinkRelink_AlwaysSucceeds(uint256 shadowAgentId)` | Link → unlink → re-link always succeeds. |
| `testFuzz_CanonicalUEAFromShadow_Consistent(uint256 shadowAgentId)` | After linking, `canonicalUEAFromShadow` returns the correct UEA. After unlinking, returns zero. |

**Verification:** `forge test --match-path test/UAIRegistry.fuzz.t.sol -vv` — 1,000 fuzz runs pass.

### Step 8: Implement deployment script

**File:** `script/deploy/Deploy.s.sol`

A Forge script that:
1. Deploys `UAIRegistry` implementation contract
2. Deploys `TransparentUpgradeableProxy` pointing to the implementation, with `ProxyAdmin` auto-created
3. Calls `initialize(admin, pauser)` on the proxy
4. Logs: proxy address, implementation address, ProxyAdmin address, domain separator

Constructor arg for `ueaFactory`: `0x00000000000000000000000000000000000000eA` (Push Chain UEAFactory).

**File:** `script/deploy/VerifyDeployment.s.sol`

Read-only script that:
1. Calls `isRegistered(0)` — should return false
2. Calls `ueaFactory()` — should return the UEAFactory address
3. Logs domain separator for manual verification

**Verification:** `forge script script/deploy/Deploy.s.sol --rpc-url $PUSH_CHAIN_RPC --private-key $DEPLOYER_KEY --broadcast` deploys successfully on Push Chain testnet. Do **not** deploy to mainnet without explicit operator confirmation.

### Step 9: Integration test against forked Push Chain

**File:** `test/UAIRegistry.integration.t.sol`

Fork Push Chain Donut testnet (`forge test --fork-url $PUSH_CHAIN_RPC`).

| Test Function | Scenario |
|---|---|
| `test_Integration_RegisterWithRealUEAFactory` | Deploy UAIRegistry on fork, register from an address, verify `getOriginForUEA` returns the real factory's response |
| `test_Integration_LinkShadow_EthereumRegistry` | Register, then link a shadow with `registryAddress = 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432` (Ethereum mainnet Identity Registry), verify `canonicalUEAFromShadow` returns correct UEA |
| `test_Integration_FullFlow` | Register → link 3 shadows (Ethereum, Base, Arbitrum) → verify `getShadows` returns all 3 → unlink one → verify removed → `canonicalUEAFromShadow` for removed returns zero |

**Verification:** `forge test --match-path test/UAIRegistry.integration.t.sol --fork-url $PUSH_CHAIN_RPC -vv` — all tests pass.

## 5. Testing Plan

### Unit Tests

**Files:** `test/UAIRegistry.t.sol`, `test/UAIRegistryShadow.t.sol`
**Mock dependencies:** `MockUEAFactory.sol`.
**Convention:** `test_FunctionName_Condition_ExpectedResult`
**Coverage:** Every `external` function. Every custom error triggered (11 errors). Every event emitted. Registration idempotency. Shadow array swap-and-pop correctness. Nonce replay prevention. Pause enforcement on all write functions.

53 test cases specified across Steps 5–6.

### Fuzz Tests

**File:** `test/UAIRegistry.fuzz.t.sol`
**Runs:** 1,000 per function.
**Invariants:**
1. `agentId == uint256(uint160(caller))` for all callers.
2. `ownerOf(agentId) == address(uint160(agentId))` always.
3. Shadow dedup key prevents duplicates under all inputs.
4. Unlink-then-relink always succeeds.
5. `canonicalUEAFromShadow` is consistent with link/unlink state.
6. Only correct signer's signature passes verification.

6 fuzz test functions specified in Step 7.

### Integration Tests

**File:** `test/UAIRegistry.integration.t.sol`
**Fork:** Push Chain Donut testnet via `--fork-url`.
**Scenarios:** 3 test cases against real UEAFactory.

## 6. Reference Materials

- **ERC-8004 spec** — `8004-contracts/erc-8004-contracts/ERC8004SPEC.md` in this repo. Defines Identity Registry interface, Agent Registration File schema, `registrations[]` array.
- **ERC-8004 Identity Registry implementation** — `8004-contracts/erc-8004-contracts/contracts/IdentityRegistryUpgradeable.sol`. Reference for ERC-7201 storage pattern, EIP-712 domain construction, and `ownerOf` / `setMetadata` patterns.
- **ERC-8004 deployed addresses** — `8004-contracts/erc-8004-contracts/scripts/addresses.ts`. Mainnet: `0x8004A169FB4a3325136EB29fA0ceB6D2e539a432`. Testnet: `0x8004A818BFB912233c491871b3d84c89A494BD9e`.
- **Push Chain UEAFactory** — `/Users/zar/Code/blockchain/evm/audit_check/core/push-chain-core-contracts/src/uea/UEAFactory.sol`. Deterministic UEA deployment, `computeUEA`, `getOriginForUEA`, `getUEAForOrigin`.
- **Push Chain IUEAFactory interface** — `/Users/zar/Code/blockchain/evm/audit_check/core/push-chain-core-contracts/src/Interfaces/IUEAFactory.sol`. Interface to copy into this project.
- **Push Chain Types.sol** — `/Users/zar/Code/blockchain/evm/audit_check/core/push-chain-core-contracts/src/libraries/Types.sol`. `UniversalAccountId` struct definition.
- **Push Chain deployed addresses** — UEAFactory: `0x00000000000000000000000000000000000000eA` (Push Chain vanity predeploy). Push Chain Donut testnet chain ID: `42101`.
- **EIP-712 spec** — https://eips.ethereum.org/EIPS/eip-712. Typed structured data hashing and signing.
- **ERC-1271 spec** — https://eips.ethereum.org/EIPS/eip-1271. Smart contract signature validation.
- **OpenZeppelin TransparentUpgradeableProxy** — https://docs.openzeppelin.com/contracts/5.x/api/proxy#TransparentUpgradeableProxy.
- **Project idea doc** — `research/project-idea-UAIR-push.md` in this repo. Full context on goals, non-goals, security threat model, and v1.1 follow-ups.
