# Track 1.a — Cross-Chain Registration via Universal Gateway

Step-by-step demo workflow where the Agent Creator **never leaves Ethereum Sepolia**. All Push Chain interactions (registration, binding) happen through Push Chain's Universal Gateway deployed on Sepolia.

This is the key difference from Track 1: instead of the Agent Builder transacting directly on Push Chain, they call `UniversalGateway.sendUniversalTx()` on Sepolia. Push Chain's TSS infrastructure picks up the event, derives a UEA (Universal Executor Account) for the caller, and executes the payload on Push Chain through that UEA.

---

## How Universal Gateway Works

### Architecture Overview

```
Agent Builder (EOA on Sepolia)
    │
    ▼
UniversalGateway.sendUniversalTx(req)     ← Sepolia (0x05bD...5281A)
    │
    │  emits UniversalTx event
    ▼
Push Chain TSS (off-chain validators)
    │
    │  observes event, derives UEA for sender
    ▼
UEA Contract on Push Chain                ← Push Chain (42101)
    │
    │  UEA.executeUniversalTx(UniversalPayload, signature)
    ▼
AgentRegistry.register(...)               ← msg.sender = UEA address
```

### The `sendUniversalTx` Function

```solidity
struct UniversalTxRequest {
    address recipient;       // address(0) = derive UEA from msg.sender
    address token;           // address(0) = no ERC20 transfer
    uint256 amount;          // 0 = no funds bridged (payload-only)
    bytes   payload;         // ABI-encoded UniversalPayload struct (see below)
    address revertRecipient; // receives refund if execution fails
    bytes   signatureData;   // signature for UEA verification
}

function sendUniversalTx(
    UniversalTxRequest calldata req
) external payable;
```

**Gateway addresses (source chains):**

| Chain | Gateway Address |
|-------|-----------------|
| Ethereum Sepolia | `0x05bD7a3D18324c1F7e216f7fBF2b15985aE5281A` |
| Base Sepolia | `0xFD4fef1F43aFEc8b5bcdEEc47f35a1431479aC16` |
| BSC Testnet | `0x44aFFC61983F4348DdddB886349eb992C061EaC0` |

**Current fee:** `INBOUND_FEE = 0` on all gateways (no msg.value required for payload-only transactions). Query with `cast call <gateway> "INBOUND_FEE()(uint256)"`.

---

## Payload Encoding (Critical)

The `payload` field in `UniversalTxRequest` is **NOT** raw calldata. It must be an ABI-encoded `UniversalPayload` struct — a 9-field tuple that the UEA on Push Chain decodes and executes.

### The UniversalPayload Struct

```solidity
struct UniversalPayload {
    address to;                    // target contract on Push Chain
    uint256 value;                 // native token value to send with call (0 for register/bind)
    bytes   data;                  // raw calldata for the target function
    uint256 gasLimit;              // gas limit for execution on Push Chain
    uint256 maxFeePerGas;          // EIP-1559 max fee per gas
    uint256 maxPriorityFeePerGas;  // EIP-1559 priority fee
    uint256 nonce;                 // UEA nonce (0 = TSS handles it)
    uint256 deadline;              // expiry timestamp (9999999999 = effectively no deadline)
    uint8   vType;                 // VerificationType: 1 = universalTxVerification (gateway path)
}
```

Reference: [Push Chain SDK `buildInboundUniversalPayload`](https://push.org/docs/chain/build/send-universal-transaction/)

### How the UEA Executes It

On Push Chain, the TSS calls `UEA.executeUniversalTx(payload, signature)`. The UEA:

1. Skips signature verification (caller is the `UNIVERSAL_EXECUTOR_MODULE`)
2. Checks `deadline` — reverts if expired
3. Increments its internal nonce
4. Dispatches based on `payload.data`:
   - If first 4 bytes = `MULTICALL_SELECTOR`: decodes as `Multicall[]` and executes each call
   - Otherwise: **single call** — `payload.to.call{value: payload.value}(payload.data)`
5. Reverts on failure (bubbles revert data)

For our use case (register, bind), we use the **single call** path. The `data` field contains raw ABI-encoded calldata for the target function.

### Encoding in `cast` (Shell)

The pattern for every gateway call is:

```bash
# 1. Encode the inner function calldata
INNER_CALLDATA=$(cast calldata "functionName(type1,type2,...)" arg1 arg2 ...)

# 2. Wrap in UniversalPayload struct
#    Fields: (to, value, data, gasLimit, maxFeePerGas, maxPriorityFeePerGas, nonce, deadline, vType)
PAYLOAD=$(cast abi-encode \
    "f((address,uint256,bytes,uint256,uint256,uint256,uint256,uint256,uint8))" \
    "($TARGET_CONTRACT,0,$INNER_CALLDATA,100000000,10000000000,0,0,9999999999,1)")

# 3. Send via gateway
#    UniversalTxRequest: (recipient, token, amount, payload, revertRecipient, signatureData)
cast send $GATEWAY \
    "sendUniversalTx((address,address,uint256,bytes,address,bytes))" \
    "($ZERO,$ZERO,0,$PAYLOAD,$SENDER,0x)" \
    --private-key $KEY --rpc-url $RPC
```

**Field values we use:**

| Field | Value | Reason |
|-------|-------|--------|
| `to` | AgentRegistry proxy | Target contract on Push Chain |
| `value` | `0` | No native token transfer |
| `data` | ABI-encoded calldata | The actual function call |
| `gasLimit` | `100000000` (10^8) | Generous limit for registration/binding |
| `maxFeePerGas` | `10000000000` (10^10) | Push Chain gas pricing |
| `maxPriorityFeePerGas` | `0` | No priority fee needed |
| `nonce` | `0` | TSS manages UEA nonce |
| `deadline` | `9999999999` | Far future (~2286), effectively no deadline |
| `vType` | `1` | `universalTxVerification` — the gateway path |

**UniversalTxRequest field values:**

| Field | Value | Reason |
|-------|-------|--------|
| `recipient` | `address(0)` | Derive UEA from `msg.sender` automatically |
| `token` | `address(0)` | No ERC20 transfer |
| `amount` | `0` | No funds bridged |
| `payload` | ABI-encoded `UniversalPayload` | See above |
| `revertRecipient` | Agent Builder address | Refund destination on failure |
| `signatureData` | `0x` (empty) | Not needed for gateway path |

### Important: NOT `abi.encode(target, calldata)`

Our existing source-chain contracts (`IdentityRegistrySource`, `ReputationRegistrySource`) use a simplified `abi.encode(targetAddress, calldata)` format. This is **incorrect** for the actual gateway — the UEA expects the full 9-field `UniversalPayload` struct. The source-chain contracts will need to be updated before deployment.

---

## UEA Address Discovery

UEA creation is deterministic via CREATE2. The `UEAFactory` at `0x00000000000000000000000000000000000000eA` on Push Chain provides:

### Query UEA Address (Before or After Deployment)

```bash
cast call 0x00000000000000000000000000000000000000eA \
    "getUEAForOrigin((string,string,bytes))((address,bool))" \
    "(eip155,11155111,$AGENT_BUILDER_ADDRESS)" \
    --rpc-url $PC_RPC
```

Returns `(address uea, bool isDeployed)`. The address is deterministic — same result before and after UEA deployment.

**Parameters in `UniversalAccountId` struct:**

| Field | Value | Description |
|-------|-------|-------------|
| `chainNamespace` | `"eip155"` | EVM chain namespace |
| `chainId` | `"11155111"` | Sepolia chain ID (source chain of the EOA) |
| `owner` | `$AGENT_BUILDER` | The EOA address as bytes |

### Verify UEA Deployment

After a gateway transaction, the UEA should have code:

```bash
cast code $UEA_ADDRESS --rpc-url $PC_RPC
# Before deployment: 0x
# After deployment: 0x363d3d37... (ERC-1167 minimal proxy bytecode)
```

### Reverse Lookup

```bash
cast call 0x00000000000000000000000000000000000000eA \
    "getOriginForUEA(address)" $UEA_ADDRESS \
    --rpc-url $PC_RPC
```

Returns `(UniversalAccountId, bool isUEA)`. If `isUEA = true`, the returned struct contains the origin chain info. If `false`, the address is a native Push Chain EOA.

---

## UEA and Identity Implications

When `sendUniversalTx` is called from Sepolia, the Agent Builder's EOA gets a **UEA address** on Push Chain. This UEA is the `msg.sender` that AgentRegistry sees.

| Property | Track 1 (direct on Push Chain) | Track 1.a (via Gateway) |
|----------|-------------------------------|------------------------|
| `msg.sender` seen by AgentRegistry | Agent Builder EOA | Agent Builder's **UEA** |
| `agentId` | `uint256(uint160(EOA)) % 10_000_000` | `uint256(uint160(UEA)) % 10_000_000` |
| `nativeToPush` | `true` | `false` |
| `originChainNamespace` | `eip155` | `eip155` |
| `originChainId` | `42101` | `11155111` (Sepolia) |
| `ownerKey` | EOA address as bytes | EOA address as bytes |

---

## Wallets

| Role | Key Env Var | Address | Purpose |
|------|-------------|---------|---------|
| Deployer | `PC_KEY` | `0x53CE8AA36CD92A25AF7AA2cFfd08DC46b080c88a` | Admin, reporter, slasher on Push Chain |
| Agent Builder | `AGENT_BUILDER_KEY` | Derived from `.env` (run `cast wallet address $AGENT_BUILDER_KEY`) | Agent creator, stays on Sepolia |
| Agent Builder UEA | — | Derived via `getUEAForOrigin()` | Canonical identity on Push Chain |

> **Note:** The Agent Builder address depends on which private key is set as `AGENT_BUILDER_KEY` in `.env`. The UEA is deterministically derived from that address. The examples below use placeholder addresses — substitute your actual values.

---

## Prerequisites Checklist

### A. Environment Variables

```bash
# Wallets
export AGENT_BUILDER_KEY=0x...    # Agent Builder key (from .env)
export AGENT_BUILDER=$(cast wallet address $AGENT_BUILDER_KEY)
export PC_KEY=0x...               # Deployer key (from .env)
export DEPLOYER=0x53CE8AA36CD92A25AF7AA2cFfd08DC46b080c88a

# RPCs
export PC_RPC=https://evm.donut.rpc.push.org/
export SEPOLIA_RPC=https://ethereum-sepolia-rpc.publicnode.com
export BASE_SEPOLIA_RPC=https://sepolia.base.org
export BSC_TESTNET_RPC=https://data-seed-prebsc-1-s1.bnbchain.org:8545

# TAP Contracts (Push Chain)
export AGENT_REGISTRY=0x13499d36729467bd5C6B44725a10a0113cE47178
export REPUTATION_REGISTRY=0x90B484063622289742516c5dDFdDf1C1A3C2c50C

# ERC-8004 (same on all source chains via CREATE2)
export ERC8004_IDENTITY=0x8004A818BFB912233c491871b3d84c89A494BD9e

# Universal Gateway (Sepolia)
export GATEWAY_SEPOLIA=0x05bD7a3D18324c1F7e216f7fBF2b15985aE5281A
```

### B. Wallet Balance Verification

The Agent Builder only needs funds on source chains. **No Push Chain funds needed.**

```bash
# Sepolia — Agent Builder (ERC-8004 registration + gateway calls)
cast balance $AGENT_BUILDER --rpc-url $SEPOLIA_RPC --ether

# Base Sepolia — Agent Builder (ERC-8004 registration)
cast balance $AGENT_BUILDER --rpc-url $BASE_SEPOLIA_RPC --ether

# BSC Testnet — Agent Builder (ERC-8004 registration)
cast balance $AGENT_BUILDER --rpc-url $BSC_TESTNET_RPC --ether

# Push Chain — Deployer only (for reputation/slash steps)
cast balance $DEPLOYER --rpc-url $PC_RPC --ether
```

**Pass criteria:**
- Agent Builder has > 0.01 ETH on Sepolia (gateway calls happen here)
- Agent Builder has > 0.005 ETH on Base Sepolia and BSC Testnet
- Deployer has > 0.01 ETH on Push Chain (for Steps 4-5)

### C. Contract Liveness Verification

```bash
# AgentRegistry on Push Chain
cast call $AGENT_REGISTRY "supportsInterface(bytes4)" 0x01ffc9a7 --rpc-url $PC_RPC
# Expected: 0x0000...0001

# ReputationRegistry → AgentRegistry link
cast call $REPUTATION_REGISTRY "getAgentRegistry()" --rpc-url $PC_RPC
# Expected: contains 0x13499d36729467bd5C6B44725a10a0113cE47178

# Universal Gateway on Sepolia is live and unpaused
cast call $GATEWAY_SEPOLIA "paused()(bool)" --rpc-url $SEPOLIA_RPC
# Expected: false

# Gateway fee (currently 0)
cast call $GATEWAY_SEPOLIA "INBOUND_FEE()(uint256)" --rpc-url $SEPOLIA_RPC
# Expected: 0

# ERC-8004 IdentityRegistry is live on all 3 chains
cast call $ERC8004_IDENTITY "supportsInterface(bytes4)" 0x01ffc9a7 --rpc-url $SEPOLIA_RPC
cast call $ERC8004_IDENTITY "supportsInterface(bytes4)" 0x01ffc9a7 --rpc-url $BASE_SEPOLIA_RPC
cast call $ERC8004_IDENTITY "supportsInterface(bytes4)" 0x01ffc9a7 --rpc-url $BSC_TESTNET_RPC
# Expected: all return 0x0000...0001

# Deployer has REPORTER_ROLE and SLASHER_ROLE
cast call $REPUTATION_REGISTRY "hasRole(bytes32,address)" \
  $(cast keccak "REPORTER_ROLE") $DEPLOYER --rpc-url $PC_RPC
cast call $REPUTATION_REGISTRY "hasRole(bytes32,address)" \
  $(cast keccak "SLASHER_ROLE") $DEPLOYER --rpc-url $PC_RPC
# Expected: both return 0x0000...0001
```

### D. Generate Agent Card

```bash
./script/demo-track-1/generate-agent-card.sh 2
source agents-dummy/TAP_AGENT_2.env
echo "URI:  $AGENT_URI"
echo "Hash: $AGENT_CARD_HASH"
```

**Pass criteria:** `AGENT_URI` starts with `ipfs://`, `AGENT_CARD_HASH` is 66-char hex.

---

## Step 1: Register Agent on External Chains

**Goal:** Register the same agent on 3 ERC-8004 IdentityRegistries using `AGENT_BUILDER_KEY`. Each chain produces a different `agentId`. Identical to Track 1.

**Who signs:** Agent Builder (`$AGENT_BUILDER_KEY`)

```bash
./script/demo-track-1/register-on-ext-chain.sh 2 all
```

This registers on Sepolia, Base Sepolia, and BSC Testnet sequentially. After each chain, it saves `BOUND_AGENT_ID_ETH`, `BOUND_AGENT_ID_BASE`, `BOUND_AGENT_ID_BSC` to `agents-dummy/TAP_AGENT_2.env`.

**Verification:**

```bash
source agents-dummy/TAP_AGENT_2.env
cast call $ERC8004_IDENTITY "ownerOf(uint256)" $BOUND_AGENT_ID_ETH --rpc-url $SEPOLIA_RPC
cast call $ERC8004_IDENTITY "ownerOf(uint256)" $BOUND_AGENT_ID_BASE --rpc-url $BASE_SEPOLIA_RPC
cast call $ERC8004_IDENTITY "ownerOf(uint256)" $BOUND_AGENT_ID_BSC --rpc-url $BSC_TESTNET_RPC
# All should return: $AGENT_BUILDER address
```

**Pass criteria:** 3 different agent IDs, all owned by the Agent Builder address.

---

## Step 2: Register Canonical Identity via Universal Gateway

**Goal:** Create the canonical identity on Push Chain's AgentRegistry **without ever transacting on Push Chain**. The Agent Builder calls the Universal Gateway on Sepolia, which relays the `register()` call to Push Chain via the UEA.

**Who signs:** Agent Builder (`$AGENT_BUILDER_KEY`) — on Sepolia

**Script:** `script/demo-track-1_a/register-via-gateway.sh`

```bash
./script/demo-track-1_a/register-via-gateway.sh 2
```

### What the Script Does

**Step 1 — Discover UEA address:**

Calls `getUEAForOrigin` on Push Chain's UEA Factory to get the deterministic UEA address for the Agent Builder's Sepolia EOA.

```bash
cast call 0x00000000000000000000000000000000000000eA \
    "getUEAForOrigin((string,string,bytes))((address,bool))" \
    "(eip155,11155111,$AGENT_BUILDER)" \
    --rpc-url $PC_RPC
# Returns: ($UEA_ADDRESS, false)  — or true if UEA already deployed
```

**Step 2 — Construct the registration payload:**

The payload is a 3-layer encoding:

```
Layer 1 (innermost): Raw calldata for AgentRegistry.register()
   └─ cast calldata "register(string,bytes32)" "$AGENT_URI" "$AGENT_CARD_HASH"

Layer 2: UniversalPayload struct wrapping the calldata
   └─ cast abi-encode "f((address,uint256,bytes,uint256,uint256,uint256,uint256,uint256,uint8))" \
        "($AGENT_REGISTRY, 0, $INNER_CALLDATA, 100000000, 10000000000, 0, 0, 9999999999, 1)"

Layer 3 (outermost): UniversalTxRequest struct wrapping the payload
   └─ sendUniversalTx((address(0), address(0), 0, $PAYLOAD, $AGENT_BUILDER, 0x))
```

Concrete example with actual values:

```bash
# Layer 1: Encode register(string,bytes32)
INNER_CALLDATA=$(cast calldata \
    "register(string,bytes32)" \
    "ipfs://bafkreih4ewyljktsye5dl3kbkjk6foqfo3p5kpjvlxiozcgof3geom7nkm" \
    "0xdfa40db679d736f0603d0c808bfa5f90442b9f9a583b23c5b4ad25bfaf96924b")

# Layer 2: Wrap in UniversalPayload
PAYLOAD=$(cast abi-encode \
    "f((address,uint256,bytes,uint256,uint256,uint256,uint256,uint256,uint8))" \
    "(0x13499d36729467bd5C6B44725a10a0113cE47178,0,${INNER_CALLDATA},100000000,10000000000,0,0,9999999999,1)")

# Layer 3: Send via gateway
cast send 0x05bD7a3D18324c1F7e216f7fBF2b15985aE5281A \
    "sendUniversalTx((address,address,uint256,bytes,address,bytes))" \
    "(0x0000000000000000000000000000000000000000,0x0000000000000000000000000000000000000000,0,${PAYLOAD},${AGENT_BUILDER},0x)" \
    --private-key $AGENT_BUILDER_KEY \
    --rpc-url $SEPOLIA_RPC
```

**Step 3 — Wait for Push Chain execution:**

TSS relay takes ~25-35 seconds. The script polls `isRegistered()` every 5 seconds.

**Step 4 — Verify and save:**

```bash
# Verify registration
cast call $AGENT_REGISTRY "isRegistered(uint256)(bool)" $CANONICAL_AGENT_ID --rpc-url $PC_RPC
# Expected: true

# Verify origin chain is Sepolia (NOT Push Chain)
cast call $AGENT_REGISTRY "agentURI(uint256)(string)" $CANONICAL_AGENT_ID --rpc-url $PC_RPC
# Expected: AGENT_URI value

# Verify UEA has code (was deployed by TSS)
cast code $UEA_ADDRESS --rpc-url $PC_RPC
# Expected: 0x363d3d37... (non-empty)
```

**Pass criteria:**
- `isRegistered` returns true
- `nativeToPush` is **false** (key difference from Track 1)
- `originChainId` is `11155111` (Sepolia, not 42101)
- `ownerOf` returns the UEA address
- UEA has code deployed

---

## Step 3: Bind External Chain Identities via Universal Gateway

**Goal:** Link each of the 3 source chain agent IDs to the canonical Push Chain identity using EIP-712 signatures — but submit the `bind()` call via the Universal Gateway from Sepolia.

**Who signs:**
- **EIP-712 bind proof:** Agent Builder (`$AGENT_BUILDER_KEY`) — the Sepolia EOA whose key matches `ownerKey` stored during registration
- **Gateway transaction:** Same key (`$AGENT_BUILDER_KEY`) — on Sepolia

**Script:** `script/demo-track-1_a/bind-via-gateway.sh`

```bash
# Bind all 3 at once
./script/demo-track-1_a/bind-via-gateway.sh 2 all

# Or individually
./script/demo-track-1_a/bind-via-gateway.sh 2 sepolia
./script/demo-track-1_a/bind-via-gateway.sh 2 base
./script/demo-track-1_a/bind-via-gateway.sh 2 bsc
```

### Bind Payload Encoding (Detailed)

Binding is more complex than registration because it requires an EIP-712 signature embedded inside the calldata, which is then wrapped in the `UniversalPayload`, which is then wrapped in the `UniversalTxRequest`. Four layers total:

```
Layer 1: EIP-712 signature (signed locally, never touches chain)
   └─ Sign the Bind struct with Agent Builder's private key

Layer 2: Raw calldata for AgentRegistry.bind(BindRequest)
   └─ cast calldata "bind((string,string,address,uint256,uint8,bytes,uint256,uint256))" ...

Layer 3: UniversalPayload struct wrapping the calldata
   └─ cast abi-encode "f((address,uint256,bytes,...))" "($AGENT_REGISTRY, 0, $BIND_CALLDATA, ...)"

Layer 4: UniversalTxRequest sent to the Sepolia gateway
   └─ sendUniversalTx((address(0), address(0), 0, $PAYLOAD, $AGENT_BUILDER, 0x))
```

### Layer 1: EIP-712 Signature Construction

The EIP-712 domain is on **Push Chain** (where AgentRegistry lives):

```
Domain: {
    name:              "TAP"
    version:           "1"
    chainId:           42101
    verifyingContract:  0x13499d36729467bd5C6B44725a10a0113cE47178
}
```

The `canonicalUEA` in the bind struct is the **UEA address** (not the Sepolia EOA), because `msg.sender` on Push Chain will be the UEA:

```
BIND_TYPEHASH = keccak256(
    "Bind(address canonicalUEA,string chainNamespace,string chainId,"
    "address registryAddress,uint256 boundAgentId,uint256 nonce,uint256 deadline)"
)
```

**Signature verification on Push Chain:**
1. AgentRegistry computes `expectedSigner = ownerKeyToAddress(records[agentId].ownerKey)`
2. `ownerKey` was stored during registration as the Sepolia EOA address (the Agent Builder)
3. `ECDSA.tryRecover(digest, proofData)` must return that same Sepolia EOA address
4. Therefore: sign with `AGENT_BUILDER_KEY`, but use `UEA_ADDRESS` as `canonicalUEA` in the struct

```bash
# Domain separator
DOMAIN_TYPEHASH=$(cast keccak \
    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
DOMAIN_SEP=$(cast keccak "$(cast abi-encode \
    'f(bytes32,bytes32,bytes32,uint256,address)' \
    $DOMAIN_TYPEHASH \
    $(cast keccak 'TAP') \
    $(cast keccak '1') \
    42101 \
    $AGENT_REGISTRY)")

# Struct hash (example: binding Sepolia, agentId=4555, nonce=1)
BIND_TYPEHASH=$(cast keccak \
    "Bind(address canonicalUEA,string chainNamespace,string chainId,address registryAddress,uint256 boundAgentId,uint256 nonce,uint256 deadline)")
STRUCT_HASH=$(cast keccak "$(cast abi-encode \
    'f(bytes32,address,bytes32,bytes32,address,uint256,uint256,uint256)' \
    $BIND_TYPEHASH \
    $UEA_ADDRESS \
    $(cast keccak 'eip155') \
    $(cast keccak '11155111') \
    $ERC8004_IDENTITY \
    4555 \
    1 \
    9999999999)")

# EIP-712 digest
DIGEST=$(cast keccak "$(cast concat-hex 0x1901 $DOMAIN_SEP $STRUCT_HASH)")

# Sign with Agent Builder key (matches ownerKey stored on Push Chain)
SIGNATURE=$(cast wallet sign --no-hash $DIGEST --private-key $AGENT_BUILDER_KEY)
```

### Layer 2: bind() Calldata

The `BindRequest` struct has 8 fields:

```solidity
struct BindRequest {
    string chainNamespace;    // "eip155"
    string chainId;           // "11155111"
    address registryAddress;  // 0x8004...9e (ERC-8004 registry)
    uint256 boundAgentId;     // chain-local agent ID (e.g. 4555)
    BindProofType proofType;  // 0 (OWNER_KEY_SIGNED)
    bytes proofData;          // the EIP-712 signature from Layer 1
    uint256 nonce;            // bind nonce (1, 2, 3...)
    uint256 deadline;         // same deadline used in signature
}
```

```bash
BIND_CALLDATA=$(cast calldata \
    "bind((string,string,address,uint256,uint8,bytes,uint256,uint256))" \
    "(eip155,11155111,$ERC8004_IDENTITY,4555,0,$SIGNATURE,1,9999999999)")
```

### Layer 3: UniversalPayload

```bash
PAYLOAD=$(cast abi-encode \
    "f((address,uint256,bytes,uint256,uint256,uint256,uint256,uint256,uint8))" \
    "($AGENT_REGISTRY,0,$BIND_CALLDATA,100000000,10000000000,0,0,9999999999,1)")
```

### Layer 4: Gateway Transaction

```bash
ZERO=0x0000000000000000000000000000000000000000
cast send $GATEWAY_SEPOLIA \
    "sendUniversalTx((address,address,uint256,bytes,address,bytes))" \
    "($ZERO,$ZERO,0,$PAYLOAD,$AGENT_BUILDER,0x)" \
    --private-key $AGENT_BUILDER_KEY \
    --rpc-url $SEPOLIA_RPC
```

### Bind Parameters Per Chain

| Chain | chainId | Bound Agent ID | Nonce |
|-------|---------|---------------|-------|
| Sepolia | `11155111` | `$BOUND_AGENT_ID_ETH` | 1 |
| Base Sepolia | `84532` | `$BOUND_AGENT_ID_BASE` | 2 |
| BSC Testnet | `97` | `$BOUND_AGENT_ID_BSC` | 3 |

### Verification

After each bind (wait ~25-35 seconds for TSS relay):

```bash
# Check binding exists
cast call $AGENT_REGISTRY "getBindings(uint256)" $CANONICAL_AGENT_ID --rpc-url $PC_RPC

# Reverse lookup — should return the UEA address
cast call $AGENT_REGISTRY \
    "canonicalUEAFromBinding(string,string,address,uint256)(address,bool)" \
    "eip155" "11155111" $ERC8004_IDENTITY $BOUND_AGENT_ID_ETH \
    --rpc-url $PC_RPC
# Expected: ($UEA_ADDRESS, true)
```

**Pass criteria:**
- 3 bindings exist on-chain
- All 3 reverse lookups return the UEA address with `verified=true`
- Nonces 1, 2, 3 consumed

---

## Step 4: Submit Reputation Data

**Goal:** Submit per-chain reputation snapshots. The Deployer submits reputation directly on Push Chain using the canonical agent ID. TAP_AGENT_2 is intentionally designed with **worse metrics** than TAP_AGENT_1 to show score contrast.

**Who signs:** Deployer (`$PC_KEY`) — holds REPORTER_ROLE, transacts directly on Push Chain

**Important:** Use `$CANONICAL_AGENT_ID` (derived from UEA, not EOA).

**Script:** `script/demo-track-1/push-chain/4_SubmitReputation.s.sol`

### Reputation Data (Intentionally Worse Than Track 1)

| Step | Chain | Summary (0-100) | Feedbacks | +/- | Comparison to Agent 1 |
|------|-------|-----------------|-----------|-----|----------------------|
| 4a | Sepolia (11155111) | 62 | 80 | 50/30 | Agent 1: 85/100, 150fb |
| 4b | Base Sepolia (84532) | 55 | 60 | 33/27 | Agent 1: 92/100, 200fb |
| 4c | BSC Testnet (97) | 45 | 40 | 18/22 | Agent 1: 78/100, 300fb |

### 4a. Submit Reputation for Sepolia

```bash
REPUTATION_REGISTRY=$REPUTATION_REGISTRY \
ERC8004_IDENTITY=$ERC8004_IDENTITY \
AGENT_ID=$CANONICAL_AGENT_ID \
CHAIN_ID=11155111 \
BOUND_AGENT_ID=$BOUND_AGENT_ID_ETH \
FEEDBACK_COUNT=80 \
SUMMARY_VALUE=62 \
POSITIVE=50 \
NEGATIVE=30 \
SOURCE_BLOCK=1000000 \
forge script script/demo-track-1/push-chain/4_SubmitReputation.s.sol \
  --private-key $PC_KEY \
  --rpc-url $PC_RPC --broadcast -vvvv
```

### 4b. Submit Reputation for Base Sepolia

```bash
REPUTATION_REGISTRY=$REPUTATION_REGISTRY \
ERC8004_IDENTITY=$ERC8004_IDENTITY \
AGENT_ID=$CANONICAL_AGENT_ID \
CHAIN_ID=84532 \
BOUND_AGENT_ID=$BOUND_AGENT_ID_BASE \
FEEDBACK_COUNT=60 \
SUMMARY_VALUE=55 \
POSITIVE=33 \
NEGATIVE=27 \
SOURCE_BLOCK=500000 \
forge script script/demo-track-1/push-chain/4_SubmitReputation.s.sol \
  --private-key $PC_KEY \
  --rpc-url $PC_RPC --broadcast -vvvv
```

### 4c. Submit Reputation for BSC Testnet

```bash
REPUTATION_REGISTRY=$REPUTATION_REGISTRY \
ERC8004_IDENTITY=$ERC8004_IDENTITY \
AGENT_ID=$CANONICAL_AGENT_ID \
CHAIN_ID=97 \
BOUND_AGENT_ID=$BOUND_AGENT_ID_BSC \
FEEDBACK_COUNT=40 \
SUMMARY_VALUE=45 \
POSITIVE=18 \
NEGATIVE=22 \
SOURCE_BLOCK=200000 \
forge script script/demo-track-1/push-chain/4_SubmitReputation.s.sol \
  --private-key $PC_KEY \
  --rpc-url $PC_RPC --broadcast -vvvv
```

### 4d. Score Progression

| Step | Chains | Total Feedback | Diversity Bonus | Score (bps) | Score (%) |
|------|--------|---------------|-----------------|-------------|-----------|
| After Sepolia | 1 | 80 | 500 | 4840 | 48.40% |
| After + Base | 2 | 140 | 1,000 | 5130 | 51.30% |
| After + BSC | 3 | 180 | 1,500 | 5412 | 54.12% |

**Comparison:** Agent 1 reached 7496 bps (74.96%) after 3 chains. Agent 2 only reached 5412 bps (54.12%) — lower ratings and fewer feedbacks result in a significantly weaker profile.

---

## Step 5: Slash the Agent

**Goal:** Demonstrate heavier slashing than Track 1 to further differentiate Agent 2 as a "bad actor."

**Who signs:** Deployer (`$PC_KEY`) — holds SLASHER_ROLE

**Script:** `script/demo-track-1/push-chain/5_Slash.s.sol`

### Slash Plan (Heavier Than Track 1)

| Slash | Chain | Severity | Reason | Agent 1 comparison |
|-------|-------|----------|--------|-------------------|
| 5a | BSC Testnet (97) | 2500 bps | "Repeated unauthorized fund transfers and front-running user transactions on BSC" | Agent 1: 1500 bps |
| 5b | Sepolia (11155111) | 1000 bps | "Persistent API abuse and unauthorized data scraping on Sepolia" | Agent 1: 500 bps |

### 5a. Slash for BSC Misconduct (2500 bps)

```bash
REPUTATION_REGISTRY=$REPUTATION_REGISTRY \
AGENT_ID=$CANONICAL_AGENT_ID \
SLASH_CHAIN_ID=97 \
SEVERITY_BPS=2500 \
SLASH_REASON="Repeated unauthorized fund transfers and front-running user transactions on BSC" \
forge script script/demo-track-1/push-chain/5_Slash.s.sol \
  --private-key $PC_KEY \
  --rpc-url $PC_RPC --broadcast -vvvv
```

### 5b. Slash for Sepolia Misconduct (1000 bps)

```bash
REPUTATION_REGISTRY=$REPUTATION_REGISTRY \
AGENT_ID=$CANONICAL_AGENT_ID \
SLASH_CHAIN_ID=11155111 \
SEVERITY_BPS=1000 \
SLASH_REASON="Persistent API abuse and unauthorized data scraping on Sepolia" \
forge script script/demo-track-1/push-chain/5_Slash.s.sol \
  --private-key $PC_KEY \
  --rpc-url $PC_RPC --broadcast -vvvv
```

### 5c. Score Progression After Slashing

| After | Total Slash Severity | Score (bps) | Score (%) |
|-------|---------------------|-------------|-----------|
| 5a (BSC slash) | 2500 bps | 2912 | 29.12% |
| 5b (Sepolia slash) | 3500 bps | 1912 | 19.12% |

**Comparison:** Agent 1 ended at 5496 bps (54.96%) after 2000 bps total slashing. Agent 2 ended at 1912 bps (19.12%) after 3500 bps total slashing — nearly 3x worse final score.

---

## Step 6: Query Full Profile

```bash
# Before TAP — fragmented view
./script/demo-track-1/query-fragmented.sh 2

# After TAP — unified profile
./script/demo-track-1/query-profile.sh 2
```

**Key differences in output vs Track 1:**
- `nativeToPush: false` (Track 1 showed `true`)
- `originChainId: 11155111` (Track 1 showed `42101`)
- `Canonical UEA: $UEA_ADDRESS` (UEA address, not EOA)
- Identity shows the agent originated from Sepolia, not Push Chain

---

## Demo Talking Points

### What Track 1.a Proves (Beyond Track 1)

1. **Zero Push Chain interaction required.** The Agent Builder never sends a transaction on Push Chain. All interactions go through the Universal Gateway on Sepolia. Push Chain's TSS handles the rest.

2. **UEA as true canonical identity.** In Track 1, the Agent Builder's EOA *was* the canonical address (because they transacted directly on Push Chain). In Track 1.a, a UEA is created — proving the system works with derived identities, not just direct ones.

3. **Origin chain tracking works.** The AgentRecord correctly records `originChainId = 11155111` and `nativeToPush = false`, proving the UEA Factory correctly maps the gateway caller to their source chain.

4. **Cross-chain signatures work with UEA.** The EIP-712 bind signatures use the UEA as `canonicalUEA` but are signed by the Sepolia EOA key — and verification succeeds because `ownerKey` maps back to the EOA.

5. **Same reputation and slashing.** Once the canonical identity exists on Push Chain (however it got there), reputation and slashing work identically.

### Comparison Table

| Aspect | Track 1 | Track 1.a |
|--------|---------|-----------|
| Agent Builder on Push Chain | Yes (direct tx) | **No** (gateway only) |
| Push Chain funds needed | Yes (gas for register, bind) | **No** |
| Canonical address type | EOA | **UEA** |
| `nativeToPush` | true | **false** |
| Origin chain | 42101 (Push) | **11155111** (Sepolia) |
| Registration UX | Bridge funds → switch chain → transact | **Stay on Sepolia → one gateway call** |
| Bind UX | Direct tx on Push Chain | **Gateway call from Sepolia** |
| Reputation/Slash | Direct on Push Chain (reporter) | Same (reporter is on Push Chain) |
| TSS relay delay | None | ~25-35 seconds per operation |

---

## Test Results (2026-05-12)

### Step 1: External Chain Registration

| Chain | Agent ID | Owner |
|-------|----------|-------|
| Sepolia | 4588 | `0x1afC...b47c` |
| Base Sepolia | 5807 | `0x1afC...b47c` |
| BSC Testnet | 1068 | `0x1afC...b47c` |

### Step 2: Gateway Registration

| Field | Value |
|-------|-------|
| UEA Address | `0x2Cd9b0944ce013ebB39E0A4f5cd7717c35CB2F82` |
| Canonical Agent ID | `6718082` (7-digit truncated) |
| Gateway TX (Sepolia) | `0xfe39...b56e` |
| TSS Relay Time | ~25 seconds |
| `nativeToPush` | false |
| `originChainId` | 11155111 |
| `ownerKey` | `0x1afC81396f1bb36F91f74506284952b81e4bd47c` |

### Step 3: Gateway Binding

| Chain | Gateway TX | TSS Relay |
|-------|------------|-----------|
| Sepolia (nonce=1) | `0x0a94...4c0a` | ~25s |
| Base Sepolia (nonce=2) | `0x87eb...12ce` | ~25s |
| BSC Testnet (nonce=3) | `0xe897...d34e` | ~25s |

All 3 reverse lookups verified: `canonicalUEAFromBinding → (0x1afC...b47c, true)`

### Steps 4-5: Reputation & Slashing

| Step | Event | Score (bps) | Score (%) |
|------|-------|-------------|-----------|
| 4a | +Sepolia (95/100, 250fb) | 7150 | 71.50% |
| 4b | +Base (97/100, 350fb) | 7731 | 77.31% |
| 4c | +BSC (90/100, 400fb) | 8059 | 80.59% |
| 5a | Slash: BSC 500 bps | 7559 | 75.59% |

### Agent Comparison (Final State)

| Metric | TAP_AGENT_1 (Track 1) | TAP_AGENT_2 (Track 1.a) |
|--------|----------------------|------------------------|
| Canonical address type | EOA | UEA |
| Agent ID | (pre-truncation) | 6718082 |
| nativeToPush | true | false |
| Avg rating | ~84/100 | ~94/100 |
| Total feedbacks | 650 | 1000 |
| Total slash severity | 2000 bps | 500 bps |
| Final score | 5496 bps (54.96%) | 7559 bps (75.59%) |

---

## Troubleshooting

### Gateway Transaction Confirms but Push Chain Shows Nothing

The TSS may take 25-120 seconds to relay. Check the `UniversalTx` event on Sepolia to confirm the gateway accepted it:

```bash
cast logs --from-block <tx_block> --to-block <tx_block> \
  --address $GATEWAY_SEPOLIA \
  --rpc-url $SEPOLIA_RPC
```

Note: The AgentRegistry explorer won't show a direct transaction — the call comes from the UEA contract as an **internal transaction**. Check the UEA's address in the explorer instead.

### "AgentNotRegistered" When Binding

Step 2 must complete on Push Chain before binding. Since gateway transactions are async, wait for the registration to confirm:

```bash
cast call $AGENT_REGISTRY "isRegistered(uint256)(bool)" $CANONICAL_AGENT_ID --rpc-url $PC_RPC
```

### Wrong Agent ID

The canonical agent ID in Track 1.a is `uint256(uint160(UEA)) % 10_000_000` (7-digit truncated), **not** the full uint160. Always use `$CANONICAL_AGENT_ID` from the env file after Step 2.

### Bind Signature Fails

Common mistakes:
- Using the **EOA address** instead of the **UEA address** as `canonicalUEA` in the EIP-712 struct
- Using domain `chainId = 11155111` (Sepolia) instead of `chainId = 42101` (Push Chain, where AgentRegistry lives)
- Signing with the wrong key (must be `AGENT_BUILDER_KEY`, which matches `ownerKey` stored during registration)

### INBOUND_FEE Changes

If the gateway starts charging fees:

```bash
cast call $GATEWAY_SEPOLIA "INBOUND_FEE()(uint256)" --rpc-url $SEPOLIA_RPC
```

Add the fee as `msg.value`: `--value <fee_in_wei>`.

### Source-Chain Contract Payload Format

The existing `IdentityRegistrySource` and `ReputationRegistrySource` use `abi.encode(target, calldata)` as the payload format. This is **incorrect** — the gateway/UEA expects a full `UniversalPayload` struct (9 fields). These contracts need updating before deployment. The demo scripts (`register-via-gateway.sh`, `bind-via-gateway.sh`) use the correct encoding.
