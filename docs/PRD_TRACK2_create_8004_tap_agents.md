# PRD: Track 2 — Integrate TAP Universal Agent ID into `create-8004-agent` CLI

**Status:** Draft
**Owner:** Zaryab
**Created:** 2026-05-12
**Depends on:** Track 1.a infrastructure (AgentRegistry on Push Chain, Universal Gateways on source chains)
**Target repo:** `create-8004-TAP-agent` (fork of `create-8004-agent`)

---

## Table of Contents

1. [Objective](#1-objective)
2. [Background & Context](#2-background--context)
3. [User Journey (Before vs. After)](#3-user-journey-before-vs-after)
4. [Supported Chains for TAP Registration](#4-supported-chains-for-tap-registration)
5. [Architecture: How Universal Gateway Registration Works](#5-architecture-how-universal-gateway-registration-works)
6. [Implementation Plan](#6-implementation-plan)
   - [Phase 1: Configuration & Types](#phase-1-configuration--types)
   - [Phase 2: Wizard Changes](#phase-2-wizard-changes)
   - [Phase 3: TAP Registration Template](#phase-3-tap-registration-template)
   - [Phase 4: Generator Integration](#phase-4-generator-integration)
   - [Phase 5: Post-Registration Output](#phase-5-post-registration-output)
   - [Phase 6: Tests](#phase-6-tests)
7. [Contract Addresses & Constants](#7-contract-addresses--constants)
8. [Detailed File Changes](#8-detailed-file-changes)
9. [Generated File Specifications](#9-generated-file-specifications)
10. [Edge Cases & Error Handling](#10-edge-cases--error-handling)
11. [Success Criteria](#11-success-criteria)
12. [Out of Scope](#12-out-of-scope)

---

## 1. Objective

Integrate TAP (Trustless Agents Plus) Universal Agent ID creation into the `create-8004-agent` CLI tool. After a user registers their ERC-8004 agent on a supported chain (e.g., Ethereum Sepolia), they are prompted to also create a canonical TAP identity on Push Chain — without leaving their source chain, needing Push Chain tokens, or interacting with Push Chain's RPC directly.

The user calls `AgentRegistry.register()` on Push Chain by sending a transaction to Push Chain's **Universal Gateway** contract deployed on their source chain. Push Chain's TSS infrastructure picks up the event, derives a UEA (Universal Executor Account) for the caller, and executes the registration on Push Chain automatically.

The result: the user gets both a local ERC-8004 agent ID on their chosen chain AND a Universal Agent ID on Push Chain — in the same CLI session, from the same chain, with only source-chain gas.

---

## 2. Background & Context

### 2.1 What is ERC-8004?

ERC-8004 is a standard for on-chain AI agent identity. Each chain has its own IdentityRegistry that mints agents as NFTs with auto-incrementing IDs. The problem: agent ID 42 on Ethereum has no on-chain link to agent ID 17 on Base, even if they're the same agent.

### 2.2 What is TAP / Push Chain AgentRegistry?

TAP solves identity fragmentation. Push Chain's `AgentRegistry` assigns a **canonical** agent identity using the agent owner's UEA address. This Universal Agent ID can then be bound to the agent's local identities on any chain, proving single ownership across all chains.

### 2.3 What is the Universal Gateway?

Push Chain deploys gateway contracts on supported EVM chains. Users call `sendUniversalTx()` on the gateway contract on their local chain. Push Chain's TSS validators observe the event, derive a UEA for the caller, and execute the payload on Push Chain through that UEA.

This means users **never need Push Chain tokens or RPC**. They stay on their source chain and pay only source-chain gas.

### 2.4 What is `create-8004-agent`?

An npm CLI tool (`npx create-8004-agent`) that scaffolds complete ERC-8004 agent projects. It runs an interactive wizard, generates all source files (registration script, A2A server, MCP server, agent logic), and auto-installs dependencies. The generated project includes an `npm run register` command that registers the agent on-chain.

### 2.5 What We're Building

We are adding a **single additional step** to the generated project's registration flow. After the standard ERC-8004 `register()` call succeeds, the script prompts: "Also create a TAP Universal Agent on Push Chain?" If the user says yes, it constructs a Universal Gateway transaction and sends it from the same chain they're already on. After ~25-35 seconds of TSS relay, the agent has a canonical identity on Push Chain.

---

## 3. User Journey (Before vs. After)

### Before (Current `create-8004-agent`)

1. Run `npx create-8004-agent`
2. Answer wizard prompts (name, chain, features, etc.)
3. Configure `.env` with keys
4. Run `npm run register` → agent registered on chosen chain
5. Agent has a **local** identity only (e.g., agentId=42 on Sepolia)

### After (With TAP Integration)

1. Run `npx create-8004-agent` (same as before)
2. Answer wizard prompts — **no new wizard questions** (TAP prompt happens at registration time, not scaffold time)
3. Configure `.env` with keys (same as before)
4. Run `npm run register`:
   - a. Agent registered on chosen chain via ERC-8004 (same as before)
   - b. **NEW:** Script detects the chain supports TAP and prompts: "Also create a TAP Universal Agent on Push Chain? (Y/n)"
   - c. If yes: sends a `sendUniversalTx()` call to the Universal Gateway on the same chain
   - d. Waits ~25-35 seconds for TSS relay
   - e. Prints the Universal Agent ID and Push Chain explorer link
5. Agent now has **both** a local ERC-8004 identity AND a canonical Push Chain identity

---

## 4. Supported Chains for TAP Registration

TAP registration via Universal Gateway is only available on chains where Push Chain has deployed a gateway contract. The TAP prompt in `npm run register` must only appear for these chains:

| Chain | Chain ID | Gateway Address | Status |
|-------|----------|-----------------|--------|
| Ethereum Sepolia | 11155111 | `0x05bD7a3D18324c1F7e216f7fBF2b15985aE5281A` | Supported |
| Base Sepolia | 84532 | `0xFD4fef1F43aFEc8b5bcdEEc47f35a1431479aC16` | Supported |
| BSC Testnet | 97 | `0x44aFFC61983F4348DdddB886349eb992C061EaC0` | Supported |
| Arbitrum Sepolia | 421614 | `0x2cd870e0166Ba458dEC615168Fd659AacD795f34` | Supported |

**All other chains** (Polygon, Monad, Avalanche, SKALE, Solana, all mainnets) do **NOT** support TAP registration. The TAP prompt must not appear for these chains.

**Important:** BSC Testnet (chainId 97) and Arbitrum Sepolia (chainId 421614) are not currently in the `create-8004-agent` chain list. They need to be added to `config.ts` as new chain entries (ERC-8004 IdentityRegistry address `0x8004A818BFB912233c491871b3d84c89A494BD9e` is the same on all testnets via CREATE2). However, adding new chains to the wizard is **out of scope** for this task — we only add TAP support for chains already in the wizard. If BSC/Arbitrum are not in the wizard, TAP simply won't be offered for them.

**In practice, for this implementation:** TAP will be available for `eth-sepolia` and `base-sepolia` (the two chains that are both in the existing wizard AND have Push Chain gateways).

---

## 5. Architecture: How Universal Gateway Registration Works

### 5.1 Overview

```
User's EOA (on Sepolia)
    │
    │  Step 1: npm run register → ERC-8004 IdentityRegistry.register()
    │  Step 2: User confirms TAP registration
    │
    ▼
UniversalGateway.sendUniversalTx(req)     ← Sepolia (0x05bD...5281A)
    │
    │  emits UniversalTx event
    ▼
Push Chain TSS (off-chain validators, ~25-35 sec)
    │
    │  derives UEA for the caller's Sepolia EOA
    ▼
UEA Contract on Push Chain                ← Push Chain (chainId 42101)
    │
    │  UEA.executeUniversalTx(payload, signature)
    ▼
AgentRegistry.register(agentURI, agentCardHash)  ← msg.sender = UEA
    │
    │  Returns agentId = uint256(uint160(UEA)) % 10_000_000
    ▼
User receives Universal Agent ID
```

### 5.2 The `sendUniversalTx` Function Signature

```solidity
struct UniversalTxRequest {
    address recipient;       // address(0) = derive UEA from msg.sender
    address token;           // address(0) = no ERC20 transfer
    uint256 amount;          // 0 = no funds bridged (payload-only)
    bytes   payload;         // ABI-encoded UniversalPayload struct
    address revertRecipient; // receives refund if execution fails
    bytes   signatureData;   // empty for gateway path
}

function sendUniversalTx(
    UniversalTxRequest calldata req
) external payable;
```

### 5.3 The UniversalPayload Struct (Encoded Inside `payload`)

```solidity
struct UniversalPayload {
    address to;                    // AgentRegistry proxy on Push Chain
    uint256 value;                 // 0 (no native token transfer)
    bytes   data;                  // ABI-encoded AgentRegistry.register(agentURI, agentCardHash)
    uint256 gasLimit;              // 100000000 (10^8, generous limit)
    uint256 maxFeePerGas;          // 10000000000 (10^10)
    uint256 maxPriorityFeePerGas;  // 0
    uint256 nonce;                 // 0 (TSS manages UEA nonce)
    uint256 deadline;              // 9999999999 (far future, ~year 2286)
    uint8   vType;                 // 1 (universalTxVerification — gateway path)
}
```

### 5.4 Three-Layer Encoding

The transaction is constructed as three nested layers:

```
Layer 1 (innermost): Raw calldata for AgentRegistry.register()
  → encodeFunctionData("register", [agentURI, agentCardHash])

Layer 2: UniversalPayload struct wrapping the calldata
  → abiEncode the 9-field tuple: (to, value, data, gasLimit, ...)

Layer 3 (outermost): UniversalTxRequest struct sent to the gateway
  → sendUniversalTx((address(0), address(0), 0, payload, senderAddress, 0x))
```

### 5.5 Field Values Summary

**UniversalPayload fields:**

| Field | Value | Reason |
|-------|-------|--------|
| `to` | `0x13499d36729467bd5C6B44725a10a0113cE47178` | AgentRegistry proxy on Push Chain |
| `value` | `0` | No native token transfer |
| `data` | Encoded `register(string,bytes32)` calldata | The actual registration call |
| `gasLimit` | `100000000` | Generous limit for registration |
| `maxFeePerGas` | `10000000000` | Push Chain gas pricing |
| `maxPriorityFeePerGas` | `0` | No priority fee needed |
| `nonce` | `0` | TSS manages UEA nonce |
| `deadline` | `9999999999` | Effectively no deadline |
| `vType` | `1` | Gateway verification path |

**UniversalTxRequest fields:**

| Field | Value | Reason |
|-------|-------|--------|
| `recipient` | `address(0)` | Auto-derive UEA from msg.sender |
| `token` | `address(0)` | No ERC20 transfer |
| `amount` | `0` | No funds bridged |
| `payload` | Encoded UniversalPayload | See above |
| `revertRecipient` | User's wallet address | Refund destination on failure |
| `signatureData` | `0x` (empty) | Not needed for gateway path |

### 5.6 Gateway Fee

Currently `INBOUND_FEE = 0` on all gateways (no `msg.value` required). The generated code should query this fee dynamically via `gateway.INBOUND_FEE()` and include it as `msg.value` if non-zero, to be future-proof.

### 5.7 AgentRegistry.register() on Push Chain

```solidity
function register(
    string calldata agentURI,
    bytes32 agentCardHash
) external returns (uint256 agentId);
```

- `agentURI`: The IPFS URI of the agent's metadata (same URI used in ERC-8004 registration)
- `agentCardHash`: keccak256 hash of the agent card JSON content
- Returns: `agentId = uint256(uint160(msg.sender)) % 10_000_000` (where msg.sender is the UEA on Push Chain)

### 5.8 Verifying Registration on Push Chain

After the TSS relay (~25-35 seconds), the registration can be verified by querying Push Chain's AgentRegistry:

```typescript
// The canonical agentId is derived from the UEA address
// UEA is deterministic based on (chainNamespace, chainId, userAddress)
const isRegistered = await pushChainPublicClient.readContract({
    address: AGENT_REGISTRY,
    abi: agentRegistryABI,
    functionName: 'isRegistered',
    args: [canonicalAgentId],
});
```

### 5.9 UEA Address Discovery

The UEA address can be computed before or after registration by calling `UEAFactory.getUEAForOrigin()` on Push Chain:

```solidity
// UEAFactory at 0x00000000000000000000000000000000000000eA on Push Chain
function getUEAForOrigin(
    UniversalAccountId calldata id  // (string chainNamespace, string chainId, bytes owner)
) external view returns (address uea, bool isDeployed);
```

For a Sepolia user at address `0xABC...`, the call would be:
```
getUEAForOrigin(("eip155", "11155111", 0xABC...))
```

This returns the deterministic UEA address and whether it's been deployed yet. The canonical `agentId` is then `uint256(uint160(ueaAddress)) % 10_000_000`.

---

## 6. Implementation Plan

### Phase 1: Configuration & Types

#### 1.1 Add TAP chain config to `src/config.ts`

Add a new export mapping chains that support TAP to their Universal Gateway addresses:

```typescript
export const TAP_GATEWAYS: Partial<Record<ChainKey, string>> = {
    "eth-sepolia": "0x05bD7a3D18324c1F7e216f7fBF2b15985aE5281A",
    "base-sepolia": "0xFD4fef1F43aFEc8b5bcdEEc47f35a1431479aC16",
};
```

Add TAP constants:

```typescript
export const TAP_CONSTANTS = {
    AGENT_REGISTRY: "0x13499d36729467bd5C6B44725a10a0113cE47178",
    PUSH_CHAIN_RPC: "https://evm.donut.rpc.push.org/",
    PUSH_CHAIN_ID: 42101,
    UEA_FACTORY: "0x00000000000000000000000000000000000000eA",
    // UniversalPayload defaults
    GAS_LIMIT: 100000000n,
    MAX_FEE_PER_GAS: 10000000000n,
    MAX_PRIORITY_FEE: 0n,
    NONCE: 0n,
    DEADLINE: 9999999999n,
    V_TYPE: 1,
} as const;
```

Add a helper function:

```typescript
export function getTapGateway(chain: ChainKey): string | null {
    return TAP_GATEWAYS[chain] ?? null;
}

export function isTapSupported(chain: string): boolean {
    return chain in TAP_GATEWAYS;
}
```

#### 1.2 Add TAP field to `WizardAnswers` type in `src/wizard.ts`

No new fields needed on `WizardAnswers`. The TAP prompt happens at **registration time** (in the generated `register.ts`), not at scaffold time. The wizard only needs to be aware of TAP for generating the correct registration script.

However, the generated `register.ts` needs to know whether the chain supports TAP so it can include the TAP registration code. This is determined by checking `getTapGateway(chain)` at generation time.

---

### Phase 2: Wizard Changes

**No changes to the wizard prompts.** The TAP registration prompt is in the generated `register.ts` script, not in the CLI wizard. The user sees it when they run `npm run register`, not when they scaffold the project.

The wizard already collects all information needed (chain, wallet address, agent name/description/image).

---

### Phase 3: TAP Registration Template

This is the core of the implementation. We need to generate TAP registration code inside the `register.ts` script for chains that support TAP.

#### 3.1 New file: `src/templates/tap.ts`

Create a new template file that exports a function to generate the TAP registration code block. This code block is injected into the generated `register.ts` after the standard ERC-8004 registration succeeds.

The generated code must:

1. **Import viem** (already a dependency for EVM chains that use agent0-sdk, but may need explicit import for encoding)
2. **Prompt the user** with inquirer: "Also create a TAP Universal Agent on Push Chain? (Y/n)"
3. **If yes:**
   a. Read the `agentURI` that was just registered on the local chain
   b. Compute `agentCardHash` as `keccak256` of the agent card JSON content
   c. Encode the inner calldata: `register(string,bytes32)` with `agentURI` and `agentCardHash`
   d. Encode the `UniversalPayload` struct (9-field tuple)
   e. Encode the `UniversalTxRequest` struct
   f. Query the gateway's `INBOUND_FEE()` to determine `msg.value`
   g. Send the transaction to the Universal Gateway on the source chain
   h. Print: "Waiting for Push Chain confirmation (~30 seconds)..."
   i. Poll Push Chain's `AgentRegistry.isRegistered()` every 5 seconds for up to 120 seconds
   j. On success: print the Universal Agent ID and a note about what it means
   k. On timeout: print that the registration was submitted but couldn't be confirmed yet, with manual verification instructions

#### 3.2 Template function signature

```typescript
export function generateTapRegistrationBlock(
    gatewayAddress: string,
    chainId: number,
    chainName: string,
): string;
```

This returns a string of TypeScript code that gets appended to the `main()` function body in `register.ts`.

#### 3.3 Generated TAP code (detailed specification)

The generated code block in `register.ts` should look like this (pseudocode with actual viem calls):

```typescript
// ============================================================================
// TAP Universal Agent Registration (Push Chain)
// ============================================================================

import inquirer from 'inquirer';
// viem is already imported for agent0-sdk usage

const TAP_GATEWAY = '0x05bD...'; // Gateway on this chain
const TAP_AGENT_REGISTRY = '0x13499d36729467bd5C6B44725a10a0113cE47178';
const TAP_PUSH_CHAIN_RPC = 'https://evm.donut.rpc.push.org/';
const TAP_PUSH_CHAIN_ID = 42101;
const TAP_UEA_FACTORY = '0x00000000000000000000000000000000000000eA';

// After ERC-8004 registration succeeds...

const { createTap } = await inquirer.prompt([{
    type: 'confirm',
    name: 'createTap',
    message: 'Also create a TAP Universal Agent on Push Chain? (gives you a Universal Agent ID)',
    default: true,
}]);

if (createTap) {
    console.log('');
    console.log('🌐 Creating TAP Universal Agent...');
    console.log('   This registers your agent on Push Chain via the Universal Gateway.');
    console.log('   You stay on <ChainName> — no Push Chain tokens needed.');
    console.log('');

    // 1. Prepare the registration calldata
    //    The agentURI is the same IPFS URI used for ERC-8004 registration
    //    The agentCardHash is keccak256 of the metadata JSON
    const agentCardJson = JSON.stringify(AGENT_CONFIG_METADATA); // the metadata object
    const agentCardHash = keccak256(toBytes(agentCardJson));

    // 2. Encode Layer 1: AgentRegistry.register(string, bytes32)
    const innerCalldata = encodeFunctionData({
        abi: [{
            name: 'register',
            type: 'function',
            inputs: [
                { name: 'agentURI', type: 'string' },
                { name: 'agentCardHash', type: 'bytes32' },
            ],
            outputs: [{ name: 'agentId', type: 'uint256' }],
        }],
        functionName: 'register',
        args: [AGENT_URI, agentCardHash],
    });

    // 3. Encode Layer 2: UniversalPayload tuple
    const universalPayload = encodeAbiParameters(
        [{
            type: 'tuple',
            components: [
                { name: 'to', type: 'address' },
                { name: 'value', type: 'uint256' },
                { name: 'data', type: 'bytes' },
                { name: 'gasLimit', type: 'uint256' },
                { name: 'maxFeePerGas', type: 'uint256' },
                { name: 'maxPriorityFeePerGas', type: 'uint256' },
                { name: 'nonce', type: 'uint256' },
                { name: 'deadline', type: 'uint256' },
                { name: 'vType', type: 'uint8' },
            ],
        }],
        [{
            to: TAP_AGENT_REGISTRY,
            value: 0n,
            data: innerCalldata,
            gasLimit: 100000000n,
            maxFeePerGas: 10000000000n,
            maxPriorityFeePerGas: 0n,
            nonce: 0n,
            deadline: 9999999999n,
            vType: 1,
        }],
    );

    // 4. Query gateway fee (currently 0, but future-proof)
    const gatewayFee = await publicClient.readContract({
        address: TAP_GATEWAY,
        abi: [{ name: 'INBOUND_FEE', type: 'function', inputs: [], outputs: [{ type: 'uint256' }] }],
        functionName: 'INBOUND_FEE',
    });

    // 5. Encode Layer 3: sendUniversalTx((address,address,uint256,bytes,address,bytes))
    const txHash = await walletClient.writeContract({
        address: TAP_GATEWAY,
        abi: [{
            name: 'sendUniversalTx',
            type: 'function',
            inputs: [{
                name: 'req',
                type: 'tuple',
                components: [
                    { name: 'recipient', type: 'address' },
                    { name: 'token', type: 'address' },
                    { name: 'amount', type: 'uint256' },
                    { name: 'payload', type: 'bytes' },
                    { name: 'revertRecipient', type: 'address' },
                    { name: 'signatureData', type: 'bytes' },
                ],
            }],
            outputs: [],
        }],
        functionName: 'sendUniversalTx',
        args: [{
            recipient: '0x0000000000000000000000000000000000000000',
            token: '0x0000000000000000000000000000000000000000',
            amount: 0n,
            payload: universalPayload,
            revertRecipient: account.address,
            signatureData: '0x',
        }],
        value: gatewayFee,
    });

    console.log(`   Gateway tx submitted: ${txHash}`);
    console.log('   Waiting for Push Chain confirmation (~30 seconds)...');
    console.log('');

    // 6. Discover UEA address (to compute canonical agentId)
    const pushPublicClient = createPublicClient({
        chain: { id: TAP_PUSH_CHAIN_ID, name: 'Push Chain', ... },
        transport: http(TAP_PUSH_CHAIN_RPC),
    });

    const [ueaAddress] = await pushPublicClient.readContract({
        address: TAP_UEA_FACTORY,
        abi: [{
            name: 'getUEAForOrigin',
            type: 'function',
            inputs: [{
                name: 'id',
                type: 'tuple',
                components: [
                    { name: 'chainNamespace', type: 'string' },
                    { name: 'chainId', type: 'string' },
                    { name: 'owner', type: 'bytes' },
                ],
            }],
            outputs: [
                { name: 'uea', type: 'address' },
                { name: 'isDeployed', type: 'bool' },
            ],
        }],
        functionName: 'getUEAForOrigin',
        args: [{
            chainNamespace: 'eip155',
            chainId: '<SOURCE_CHAIN_ID>',
            owner: account.address,
        }],
    });

    const canonicalAgentId = BigInt(ueaAddress) % 10_000_000n;

    // 7. Poll for confirmation
    let confirmed = false;
    for (let i = 0; i < 24; i++) { // 24 * 5s = 120 seconds max
        await new Promise(r => setTimeout(r, 5000));
        try {
            const isReg = await pushPublicClient.readContract({
                address: TAP_AGENT_REGISTRY,
                abi: [{ name: 'isRegistered', type: 'function', inputs: [{ type: 'uint256' }], outputs: [{ type: 'bool' }] }],
                functionName: 'isRegistered',
                args: [canonicalAgentId],
            });
            if (isReg) {
                confirmed = true;
                break;
            }
        } catch { /* Push Chain RPC may be slow */ }
        process.stdout.write('.');
    }

    console.log('');
    if (confirmed) {
        console.log('');
        console.log('✅ TAP Universal Agent created!');
        console.log('');
        console.log('🆔 Universal Agent ID:', canonicalAgentId.toString());
        console.log('🔗 UEA Address:', ueaAddress);
        console.log('');
        console.log('💡 What this means:');
        console.log('   Your agent now has a canonical identity on Push Chain.');
        console.log('   You can bind agents from OTHER chains to this same identity,');
        console.log('   proving you own them all. No fragmented IDs across chains.');
    } else {
        console.log('');
        console.log('⏳ TAP registration submitted but not yet confirmed.');
        console.log('   The Push Chain TSS relay can take up to 2 minutes.');
        console.log('   Your expected Universal Agent ID:', canonicalAgentId.toString());
        console.log('');
        console.log('   Verify manually later:');
        console.log('   https://evm.donut.rpc.push.org/ → call isRegistered(' + canonicalAgentId.toString() + ')');
    }
}
```

#### 3.4 What metadata to hash for `agentCardHash`

The `agentCardHash` parameter on `AgentRegistry.register()` is `keccak256` of the agent's metadata JSON. This should be the same metadata object that was uploaded to IPFS during ERC-8004 registration. The exact JSON object depends on the registration path:

- **EVM (agent0-sdk):** The SDK handles metadata internally. The generated code should construct a metadata object from `AGENT_CONFIG` (name, description, image, endpoints, trust models) and hash it.
- **Monad (direct viem):** The `AGENT_METADATA` object in the Monad template is already available in the register script.

The simplest approach: construct a JSON object from the agent config fields available in the register script and hash it with `keccak256(toBytes(JSON.stringify(metadata)))`.

---

### Phase 4: Generator Integration

#### 4.1 Modify `src/generator.ts`

In `generateEVMProject()`:
- After generating `src/register.ts`, check if the chain supports TAP via `getTapGateway()`
- If supported, the register script template already includes the TAP code block (it's baked into the template, controlled by a boolean flag)

#### 4.2 Modify `src/templates/base.ts` — `generateRegisterScript()`

The `generateRegisterScript()` function receives the `WizardAnswers` and `chain` config. It needs to:

1. Check if `getTapGateway(answers.chain)` returns a gateway address
2. If yes, append the TAP registration block after the standard registration code
3. Add `inquirer` to the import list of the generated script
4. Add `inquirer` to the generated `package.json` dependencies

The TAP code block is generated by calling `generateTapRegistrationBlock()` from `src/templates/tap.ts`.

#### 4.3 Modify `src/templates/base.ts` — `generatePackageJson()`

When the chain supports TAP, add `inquirer` as a dependency (for the confirmation prompt in `register.ts`). Note: `inquirer` might already be a reasonable dependency to add since the user experience benefits from interactive prompts during registration.

Actually, simpler approach: use Node.js built-in `readline` instead of `inquirer` for the single Y/n prompt. This avoids adding a dependency. The generated register script can use:

```typescript
import readline from 'readline';
const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
const answer = await new Promise<string>(resolve => rl.question('Also create a TAP Universal Agent? (Y/n): ', resolve));
rl.close();
const createTap = answer.toLowerCase() !== 'n';
```

This is preferred — no new dependency needed.

#### 4.4 Modify Monad template (`src/templates/monad.ts`)

Monad chains are NOT in the TAP gateway list, so no changes needed. The `isMonadChain()` check in the generator already routes Monad to its own template.

#### 4.5 Modify Solana template (`src/templates/solana.ts`)

Solana is NOT in the TAP gateway list, so no changes needed.

---

### Phase 5: Post-Registration Output

#### 5.1 Modify `src/index.ts` — Next Steps output

After the "Register your agent on-chain" step, add a note about TAP if the chain supports it:

```typescript
if (getTapGateway(answers.chain)) {
    console.log(chalk.gray('   → You\'ll be prompted to also create a TAP Universal Agent'));
}
```

#### 5.2 Update generated `README.md`

In the `generateReadme()` function in `src/templates/base.ts`, add a section about TAP for supported chains:

```markdown
## TAP Universal Agent (Push Chain)

This agent was generated for a TAP-supported chain. When you run `npm run register`,
you'll be prompted to also create a canonical identity on Push Chain.

This gives you a **Universal Agent ID** that works across all chains. You can later
bind agents from other chains to this same identity, proving single ownership.

No Push Chain tokens needed — the registration goes through the Universal Gateway
on <ChainName>.
```

---

### Phase 6: Tests

#### 6.1 Unit tests for TAP config

- Test `isTapSupported('eth-sepolia')` returns `true`
- Test `isTapSupported('polygon-amoy')` returns `false`
- Test `getTapGateway('eth-sepolia')` returns the correct address
- Test `getTapGateway('base-mainnet')` returns `null`

#### 6.2 Template generation tests

- Generate a project for `eth-sepolia` with A2A → verify `register.ts` contains TAP registration code
- Generate a project for `polygon-amoy` with A2A → verify `register.ts` does NOT contain TAP code
- Generate a project for `eth-sepolia` → verify `register.ts` contains the correct gateway address
- Generate a project for `base-sepolia` → verify `register.ts` contains the Base Sepolia gateway address

#### 6.3 Code structure tests

- Verify generated `register.ts` for TAP chains imports `readline`
- Verify generated `register.ts` contains `sendUniversalTx` encoding
- Verify generated `register.ts` contains Push Chain RPC URL
- Verify generated `register.ts` contains `getUEAForOrigin` call
- Verify generated `register.ts` contains the polling loop for confirmation
- Verify generated `register.ts` contains `INBOUND_FEE` query

#### 6.4 Add to chain test factory

In `tests/utils/chain-test-factory.ts`, add a new test section for TAP-supported chains:

```typescript
if (isTapSupported(config.chainKey)) {
    describe('TAP Registration', () => {
        it('should include TAP registration code in register.ts', ...);
        it('should have correct gateway address', ...);
        it('should have correct Push Chain config', ...);
    });
}
```

---

## 7. Contract Addresses & Constants

### Push Chain (Chain ID: 42101)

| Contract | Address |
|----------|---------|
| AgentRegistry (Proxy) | `0x13499d36729467bd5C6B44725a10a0113cE47178` |
| ReputationRegistry (Proxy) | `0x90B484063622289742516c5dDFdDf1C1A3C2c50C` |
| UEA Factory | `0x00000000000000000000000000000000000000eA` |

### Universal Gateway (Source Chains)

| Chain | Chain ID | Gateway Address |
|-------|----------|-----------------|
| Ethereum Sepolia | 11155111 | `0x05bD7a3D18324c1F7e216f7fBF2b15985aE5281A` |
| Base Sepolia | 84532 | `0xFD4fef1F43aFEc8b5bcdEEc47f35a1431479aC16` |
| BSC Testnet | 97 | `0x44aFFC61983F4348DdddB886349eb992C061EaC0` |
| Arbitrum Sepolia | 421614 | `0x2cd870e0166Ba458dEC615168Fd659AacD795f34` |

### ERC-8004 (Same on All Testnets)

| Contract | Address |
|----------|---------|
| IdentityRegistry | `0x8004A818BFB912233c491871b3d84c89A494BD9e` |

### Push Chain RPC

| Network | RPC URL |
|---------|---------|
| Push Chain Donut Testnet | `https://evm.donut.rpc.push.org/` |

### Constants for UniversalPayload

| Constant | Value | Notes |
|----------|-------|-------|
| gasLimit | `100000000` (10^8) | Generous for registration |
| maxFeePerGas | `10000000000` (10^10) | Push Chain gas pricing |
| maxPriorityFeePerGas | `0` | No priority fee |
| nonce | `0` | TSS manages UEA nonce |
| deadline | `9999999999` | Far future (~2286) |
| vType | `1` | universalTxVerification (gateway path) |
| INBOUND_FEE | `0` (currently) | Query dynamically, may change |

---

## 8. Detailed File Changes

### Files to CREATE

| File | Purpose |
|------|---------|
| `src/templates/tap.ts` | TAP registration code block generator |

### Files to MODIFY

| File | Changes |
|------|---------|
| `src/config.ts` | Add `TAP_GATEWAYS`, `TAP_CONSTANTS`, `getTapGateway()`, `isTapSupported()` |
| `src/templates/base.ts` | Modify `generateRegisterScript()` to append TAP block; modify `generateReadme()` to include TAP section; modify `generatePackageJson()` (no new deps needed if using readline) |
| `src/generator.ts` | Import and use `isTapSupported` to pass flag to template |
| `src/index.ts` | Add TAP note in "Next Steps" output |

### Files NOT modified

| File | Reason |
|------|--------|
| `src/wizard.ts` | TAP prompt is at registration time, not scaffold time |
| `src/fourmica.ts` | Unrelated to TAP |
| `src/config-solana.ts` | Solana doesn't support TAP |
| `src/templates/solana.ts` | Solana doesn't support TAP |
| `src/templates/monad.ts` | Monad doesn't support TAP |
| `src/templates/a2a.ts` | A2A server is unrelated to registration |
| `src/templates/mcp.ts` | MCP server is unrelated to registration |

---

## 9. Generated File Specifications

### 9.1 Generated `register.ts` for TAP-supported chains

The generated file has two sections:

**Section 1 (unchanged):** Standard ERC-8004 registration via agent0-sdk

```typescript
// ... existing registration code ...
const txHandle = await agent.registerIPFS();
const { result } = await txHandle.waitMined();
// ... wallet setting, output ...
console.log('✅ Agent registered on <ChainName>!');
console.log('🆔 Agent ID:', result.agentId);
```

**Section 2 (new):** TAP Universal Agent registration

```typescript
// ============================================================================
// TAP Universal Agent Registration (Push Chain)
// ============================================================================
//
// Creates a canonical identity on Push Chain via the Universal Gateway.
// Your agent gets a Universal Agent ID that works across all chains.
// No Push Chain tokens needed — uses the gateway on <ChainName>.

import readline from 'readline';

// ... TAP registration code as specified in Phase 3 ...
```

### 9.2 Generated `register.ts` for NON-TAP chains

Unchanged from current behavior. No TAP code included.

### 9.3 Dependency changes in generated `package.json`

**No new dependencies** for TAP. The generated project already depends on:
- `viem` (via agent0-sdk, or directly for Monad) — needed for encoding
- `dotenv` — for env vars

The TAP code uses:
- `readline` — Node.js built-in (no dependency)
- `viem` functions (`encodeFunctionData`, `encodeAbiParameters`, `keccak256`, `toBytes`, `createPublicClient`, `http`) — already available
- `createWalletClient` — already used in the register script for the ERC-8004 registration

### 9.4 Generated `.env` additions for TAP chains

No additional env vars needed. The TAP registration uses:
- `PRIVATE_KEY` (already exists)
- `RPC_URL` (already exists, used for gateway tx on the same chain)

The Push Chain RPC URL is hardcoded in the generated script (it's a public endpoint, not a secret).

---

## 10. Edge Cases & Error Handling

### 10.1 User declines TAP registration

If the user answers "n" to the TAP prompt, the script continues normally with no TAP code executed. The ERC-8004 registration is already complete.

### 10.2 Gateway transaction reverts

If `sendUniversalTx()` reverts on the source chain (e.g., gateway is paused, invalid payload), catch the error and print a clear message:

```
❌ TAP registration failed: <error message>
   Your ERC-8004 agent is still registered on <ChainName>.
   You can try TAP registration later by running: npm run register
```

### 10.3 TSS relay timeout

If the 120-second polling window expires without confirmation:

```
⏳ TAP registration submitted but not yet confirmed.
   The Push Chain relay can take up to 5 minutes in rare cases.
   Your expected Universal Agent ID: <id>
   
   Check status later:
   Run: npx tsx src/check-tap.ts
```

### 10.4 Push Chain RPC unreachable

If the Push Chain RPC is down during the UEA discovery or polling step, catch the error and skip gracefully:

```
⚠️  Could not connect to Push Chain to verify registration.
   Gateway tx was submitted successfully: <txHash>
   Your agent should appear on Push Chain shortly.
```

### 10.5 Agent already registered on Push Chain

If the user runs `npm run register` again and the agent is already registered on Push Chain, the `AgentRegistry.register()` call on Push Chain would update the existing record (it's an upsert). The generated code should handle this gracefully — if `isRegistered()` already returns true before the gateway call, inform the user:

```
ℹ️  Your agent is already registered on Push Chain with Universal Agent ID: <id>
   Running register again will update the metadata.
```

### 10.6 Insufficient gas on source chain

If the user doesn't have enough gas for the gateway transaction, viem will throw before sending. The error is caught and displayed:

```
❌ TAP registration failed: insufficient funds for gas
   Your ERC-8004 agent is still registered on <ChainName>.
   Fund your wallet and try again.
```

### 10.7 Non-zero INBOUND_FEE

The generated code queries `INBOUND_FEE()` dynamically. If it returns a non-zero value, the code includes it as `msg.value` in the gateway call. No user action needed.

---

## 11. Success Criteria

### Must Have

- [ ] `src/config.ts` exports `TAP_GATEWAYS`, `TAP_CONSTANTS`, `getTapGateway()`, `isTapSupported()`
- [ ] `src/templates/tap.ts` exists and exports `generateTapRegistrationBlock()`
- [ ] Generated `register.ts` for `eth-sepolia` contains TAP registration code with correct gateway address
- [ ] Generated `register.ts` for `base-sepolia` contains TAP registration code with correct gateway address
- [ ] Generated `register.ts` for `polygon-amoy` does NOT contain TAP registration code
- [ ] TAP code uses 3-layer encoding (inner calldata → UniversalPayload → UniversalTxRequest)
- [ ] TAP code queries `INBOUND_FEE()` dynamically
- [ ] TAP code discovers UEA address via `getUEAForOrigin()` on Push Chain
- [ ] TAP code computes canonical agentId as `uint256(uint160(ueaAddress)) % 10_000_000`
- [ ] TAP code polls `isRegistered()` with timeout and clear status messages
- [ ] TAP registration prompt only appears after successful ERC-8004 registration
- [ ] Generated README includes TAP section for supported chains
- [ ] "Next Steps" output in CLI mentions TAP for supported chains
- [ ] All existing tests pass (no regressions)
- [ ] New tests verify TAP template generation for supported and unsupported chains
- [ ] User can decline TAP registration and the script completes normally
- [ ] Errors during TAP registration are caught and don't affect the ERC-8004 registration

### Nice to Have

- [ ] Generated `check-tap.ts` script for manual verification after timeout
- [ ] Integration test that actually calls the Sepolia gateway (requires funded wallet)
- [ ] TAP section in generated README includes the Universal Agent ID placeholder (filled after registration)
- [ ] `registration.json` updated with Push Chain canonical agent ID after TAP registration

---

## 12. Out of Scope

The following are explicitly **not** part of this task:

1. **Binding** — After TAP registration, the user can bind their local ERC-8004 agent to the canonical Push Chain identity. This requires EIP-712 signatures and a second gateway call. This is a separate feature for a future PR.

2. **Reputation propagation** — Cross-chain reputation via `ReputationRegistrySource` wrappers. Separate track.

3. **New chains in the wizard** — Adding BSC Testnet or Arbitrum Sepolia as wizard options. This task only adds TAP support for chains already in the wizard.

4. **Mainnet support** — TAP is testnet-only for now. No mainnet gateway addresses exist yet.

5. **Solana TAP** — Push Chain's Universal Gateway is EVM-only. Solana agents cannot register on Push Chain.

6. **Source-chain wrapper contracts** — The original Track 2 PRD proposed deploying `IdentityRegistrySource` wrapper contracts. We are NOT doing that. Instead, the generated `register.ts` script makes the gateway call directly using viem. This is simpler, requires no contract deployment, and achieves the same result.

7. **4mica / x402 interaction with TAP** — TAP registration is independent of payment configuration.

8. **Push Chain explorer links** — There's no public block explorer for Push Chain Donut testnet yet. We print the canonical agent ID and UEA address but cannot link to an explorer.

9. **Agent card updates on Push Chain** — If the user updates their agent metadata and re-runs `npm run register`, the TAP code will re-register (upsert) on Push Chain. This works but is not explicitly tested.
