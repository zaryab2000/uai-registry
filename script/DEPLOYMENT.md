# Deployment Plan — AgentRegistry & ReputationRegistry

First deployment on Push Chain Donut Testnet.

---

## Network Configuration

| Parameter | Value |
|-----------|-------|
| Network | Push Chain Donut Testnet |
| Chain ID | `42101` |
| RPC URL | `https://evm.donut.rpc.push.org/` |
| Block Explorer | `https://donut.push.network` |
| Currency Symbol | `PC` |
| Faucet | `https://faucet.push.org` |
| EVM Target | `shanghai` |

## Push Chain System Contracts (Predeploys)

| Contract | Address | Role |
|----------|---------|------|
| UEA Factory | `0x00000000000000000000000000000000000000eA` | Deploys/manages Universal Executor Accounts. AgentRegistry calls `getOriginForUEA()`. |
| Universal Gateway PC | `0x00000000000000000000000000000000000000C1` | Push-side gateway for cross-chain messages. |
| Universal Core | `0x00000000000000000000000000000000000000C0` | Mints PRC-20 tokens, manages cross-chain native token pricing. |

### External Chain Gateways (Source-Chain Deployments)

| Chain | Gateway Address |
|-------|-----------------|
| Ethereum Sepolia | `0x05bD7a3D18324c1F7e216f7fBF2b15985aE5281A` |
| Arbitrum Sepolia | `0x2cd870e0166Ba458dEC615168Fd659AacD795f34` |
| Base Sepolia | `0xFD4fef1F43aFEc8b5bcdEEc47f35a1431479aC16` |
| BNB Testnet | `0x44aFFC61983F4348DdddB886349eb992C061EaC0` |

---

## Environment Setup

### 1. Prerequisites

- **Foundry** — install or update:
  ```bash
  curl -L https://foundry.paradigm.xyz | bash
  foundryup
  ```
- **Solidity 0.8.26** — pinned in `foundry.toml`
- **OpenZeppelin v5.3.0** — already in `lib/`

### 2. Wallet Setup

Import the deployer key into Foundry's encrypted keystore:

```bash
cast wallet import deployer --interactive
```

### 3. Environment Variables

Create `.env` in project root (already gitignored):

```bash
PC_RPC=https://evm.donut.rpc.push.org/
PC_KEY=0x...

# Post-deployment: set after AgentRegistry deploys
AGENT_REGISTRY_PROXY=0x...

# Reputation roles
INITIAL_REPORTER=0x...
INITIAL_SLASHER=0x...
```

### 4. Foundry Configuration

`foundry.toml` already includes Push Chain endpoints:

```toml
[rpc_endpoints]
push_testnet = "${PC_RPC}"

[etherscan]
push_testnet = { key = "blockscout", url = "https://donut.push.network/api", chain = 42101 }
```

### 5. Fund the Deployer

Get testnet `$PC` from `https://faucet.push.org`. Verify:

```bash
cast balance <DEPLOYER_ADDRESS> --rpc-url $PC_RPC
```

---

## Deployment Order

```
Step 1: AgentRegistry (depends on UEA Factory predeploy)
   ↓
Step 2: ReputationRegistry (depends on AgentRegistry proxy address)
   ↓
Step 3: Grant roles + verify
   ↓
Step 4: Verify source on Blockscout
```

---

## Known Issue: `forge script` and Chain 42101

Foundry's `forge script --broadcast` does not support unknown chain IDs (42101 is not in Foundry's chain registry). Use `cast send --create` for deployment and `cast send` for transactions instead. The forge scripts serve as reference for what gets deployed and in what order.

---

## Step 1 — Deploy AgentRegistry

```bash
source .env

# Deploy implementation
BYTECODE=$(forge inspect src/AgentRegistry.sol:AgentRegistry bytecode)
ARGS=$(cast abi-encode "constructor(address)" \
    0x00000000000000000000000000000000000000eA | sed 's/^0x//')
cast send --rpc-url $PC_RPC --private-key $PC_KEY \
    --create "${BYTECODE}${ARGS}" --json

# Deploy proxy
DEPLOYER=$(cast wallet address --private-key $PC_KEY)
INIT=$(cast calldata "initialize(address,address)" $DEPLOYER $DEPLOYER)
PROXY_BC=$(forge inspect TransparentUpgradeableProxy bytecode)
PROXY_ARGS=$(cast abi-encode "constructor(address,address,bytes)" \
    <IMPL_ADDRESS> $DEPLOYER $INIT | sed 's/^0x//')
cast send --rpc-url $PC_RPC --private-key $PC_KEY \
    --create "${PROXY_BC}${PROXY_ARGS}" --json
```

---

## Step 2 — Deploy ReputationRegistry

```bash
# Deploy implementation
BYTECODE=$(forge inspect src/ReputationRegistry.sol:ReputationRegistry bytecode)
cast send --rpc-url $PC_RPC --private-key $PC_KEY --create "$BYTECODE" --json

# Deploy proxy
INIT=$(cast calldata "initialize(address,address,address)" \
    $DEPLOYER $DEPLOYER <AGENT_PROXY>)
PROXY_ARGS=$(cast abi-encode "constructor(address,address,bytes)" \
    <REP_IMPL> $DEPLOYER $INIT | sed 's/^0x//')
cast send --rpc-url $PC_RPC --private-key $PC_KEY \
    --create "${PROXY_BC}${PROXY_ARGS}" --json

# Grant roles
REPORTER_ROLE=$(cast call <REP_PROXY> 'REPORTER_ROLE()(bytes32)' --rpc-url $PC_RPC)
SLASHER_ROLE=$(cast call <REP_PROXY> 'SLASHER_ROLE()(bytes32)' --rpc-url $PC_RPC)
cast send <REP_PROXY> "grantRole(bytes32,address)" $REPORTER_ROLE $DEPLOYER \
    --rpc-url $PC_RPC --private-key $PC_KEY
cast send <REP_PROXY> "grantRole(bytes32,address)" $SLASHER_ROLE $DEPLOYER \
    --rpc-url $PC_RPC --private-key $PC_KEY
```

---

## Step 3 — Verify Deployments

```bash
# AgentRegistry
cast call $AGENT_REGISTRY_PROXY "ueaFactory()(address)" --rpc-url $PC_RPC
cast call $AGENT_REGISTRY_PROXY "supportsInterface(bytes4)(bool)" 0x80ac58cd --rpc-url $PC_RPC

# ReputationRegistry
cast call $REPUTATION_REGISTRY_PROXY "getAgentRegistry()(address)" --rpc-url $PC_RPC
```

---

## Step 4 — Verify on Blockscout

```bash
# AgentRegistry implementation
forge verify-contract --chain 42101 --verifier blockscout \
    --verifier-url https://donut.push.network/api \
    <IMPL_ADDRESS> src/AgentRegistry.sol:AgentRegistry \
    --constructor-args $(cast abi-encode "constructor(address)" \
        0x00000000000000000000000000000000000000eA)

# ReputationRegistry implementation
forge verify-contract --chain 42101 --verifier blockscout \
    --verifier-url https://donut.push.network/api \
    <IMPL_ADDRESS> src/ReputationRegistry.sol:ReputationRegistry

# Proxies (usually auto-verified by Blockscout)
forge verify-contract --chain 42101 --verifier blockscout \
    --verifier-url https://donut.push.network/api \
    <PROXY_ADDRESS> TransparentUpgradeableProxy \
    --constructor-args <ENCODED_CONSTRUCTOR_ARGS>
```

---

## Pre-Deployment Checklist

```bash
forge build          # zero errors
forge test           # all 211 tests pass
forge fmt --check    # formatting clean
cast balance <DEPLOYER> --rpc-url $PC_RPC  # sufficient $PC
```

---

## Post-Deployment Roles

### AgentRegistry

| Role | Holder |
|------|--------|
| `DEFAULT_ADMIN_ROLE` | Deployer |
| `PAUSER_ROLE` | Deployer |
| Proxy Admin | ProxyAdmin contract (owned by deployer) |

### ReputationRegistry

| Role | Holder |
|------|--------|
| `DEFAULT_ADMIN_ROLE` | Deployer |
| `PAUSER_ROLE` | Deployer |
| `REPORTER_ROLE` | Deployer (reassign to reporter service) |
| `SLASHER_ROLE` | Deployer (reassign to slasher service) |
| Proxy Admin | ProxyAdmin contract (owned by deployer) |

---

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Push Chain does not support Cancun opcodes | `foundry.toml` pins `evm_version = "shanghai"`. Verified during initial deployment. |
| `forge script --broadcast` fails on chain 42101 | Use `cast send --create` directly. |
| UEA Factory not at `0x...eA` | Check with `cast code` before deploying. |
| Wrong AgentRegistry passed to ReputationRegistry | Correctable via `setAgentRegistry()` (admin-only). |
