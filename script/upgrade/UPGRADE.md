# Upgrade Procedure

Standard procedure for upgrading TAPRegistry or TAPReputationRegistry on Push Chain.

Both contracts use OpenZeppelin `TransparentUpgradeableProxy`. Upgrades deploy a new implementation contract and point the proxy at it. Storage is preserved — only bytecode changes.

---

## Current Addresses

See `docs/ADDRESS_BOOK.md` for the full list. Key addresses for upgrades:

| Contract              | Proxy                                        | ProxyAdmin                                   |
| --------------------- | -------------------------------------------- | -------------------------------------------- |
| TAPRegistry           | `0x13499d36729467bd5C6B44725a10a0113cE47178` | `0x062021b898e2693f41bb69d463c016cda568794e` |
| TAPReputationRegistry | `0x90B484063622289742516c5dDFdDf1C1A3C2c50C` | `0x32e0b8a0fdd30c8a64bf013ea8d224ed79cbcab8` |

---

## Before You Start

### Storage compatibility

Every upgrade must preserve the existing storage layout. Breaking changes:

- Reordering, removing, or changing the type of existing state variables
- Changing the ERC-7201 namespace string (moves the storage slot)
- Adding new state variables before existing ones

Safe changes:

- Adding new state variables at the end of the storage struct
- Adding new functions
- Modifying function logic without changing storage layout
- Adding new events or errors

If unsure, diff storage layouts:

```bash
forge inspect TAPRegistry storage-layout --pretty > /tmp/old-layout.txt
# (make changes)
forge inspect TAPRegistry storage-layout --pretty > /tmp/new-layout.txt
diff /tmp/old-layout.txt /tmp/new-layout.txt
```

### Pre-upgrade checklist

```bash
# 1. All tests pass
forge test

# 2. Formatting clean
forge fmt --check

# 3. Verify the upgrade caller owns the ProxyAdmin
cast call <PROXY_ADMIN> "owner()(address)" --rpc-url $PC_RPC

# 4. Check current implementation
cast storage <PROXY> \
    0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc \
    --rpc-url $PC_RPC
```

---

## Upgrade TAPRegistry

```bash
source .env
AGENT_PROXY=0x13499d36729467bd5C6B44725a10a0113cE47178
AGENT_PROXY_ADMIN=0x062021b898e2693f41bb69d463c016cda568794e

# 1. Deploy new implementation
BYTECODE=$(forge inspect src/TAPRegistry.sol:TAPRegistry bytecode)
ARGS=$(cast abi-encode "constructor(address)" \
    0x00000000000000000000000000000000000000eA | sed 's/^0x//')
cast send --rpc-url $PC_RPC --private-key $PC_KEY \
    --create "${BYTECODE}${ARGS}" --json

# 2. Upgrade proxy
cast send $AGENT_PROXY_ADMIN \
    "upgradeAndCall(address,address,bytes)" \
    $AGENT_PROXY <NEW_IMPL> 0x \
    --rpc-url $PC_RPC --private-key $PC_KEY
```

### With migration logic

If the upgrade needs a reinitializer:

```bash
MIGRATION=$(cast calldata "reinitialize(uint64)" 2)
cast send $AGENT_PROXY_ADMIN \
    "upgradeAndCall(address,address,bytes)" \
    $AGENT_PROXY <NEW_IMPL> $MIGRATION \
    --rpc-url $PC_RPC --private-key $PC_KEY
```

---

## Upgrade TAPReputationRegistry

```bash
source .env
REP_PROXY=0x90B484063622289742516c5dDFdDf1C1A3C2c50C
REP_PROXY_ADMIN=0x32e0b8a0fdd30c8a64bf013ea8d224ed79cbcab8

# 1. Deploy new implementation
BYTECODE=$(forge inspect src/TAPReputationRegistry.sol:TAPReputationRegistry bytecode)
cast send --rpc-url $PC_RPC --private-key $PC_KEY \
    --create "$BYTECODE" --json

# 2. Upgrade proxy
cast send $REP_PROXY_ADMIN \
    "upgradeAndCall(address,address,bytes)" \
    $REP_PROXY <NEW_IMPL> 0x \
    --rpc-url $PC_RPC --private-key $PC_KEY
```

---

## Post-Upgrade Verification

```bash
# 1. Confirm new implementation address
cast storage <PROXY> \
    0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc \
    --rpc-url $PC_RPC

# 2. TAPRegistry health check
cast call $AGENT_PROXY "ueaFactory()(address)" --rpc-url $PC_RPC
cast call $AGENT_PROXY "supportsInterface(bytes4)(bool)" 0x80ac58cd --rpc-url $PC_RPC

# 3. TAPReputationRegistry health check
cast call $REP_PROXY "getTAPRegistry()(address)" --rpc-url $PC_RPC

# 4. Role integrity
DEPLOYER=0x53CE8AA36CD92A25AF7AA2cFfd08DC46b080c88a
cast call <PROXY> "hasRole(bytes32,address)(bool)" \
    0x0000000000000000000000000000000000000000000000000000000000000000 \
    $DEPLOYER --rpc-url $PC_RPC
```

---

## Post-Upgrade Bookkeeping

1. **Verify on Blockscout:**
   ```bash
   forge verify-contract --chain 42101 --verifier blockscout \
       --verifier-url https://donut.push.network/api \
       <NEW_IMPL> src/TAPRegistry.sol:TAPRegistry \
       --constructor-args $(cast abi-encode "constructor(address)" \
           0x00000000000000000000000000000000000000eA)
   ```

2. **Update `docs/ADDRESS_BOOK.md`** — new implementation address + upgrade history row.

3. **Commit the changes.**

---

## Rollback

Upgrade back to the previous implementation:

```bash
cast send <PROXY_ADMIN> \
    "upgradeAndCall(address,address,bytes)" \
    <PROXY> <OLD_IMPL> 0x \
    --rpc-url $PC_RPC --private-key $PC_KEY
```

Only works if the new implementation did not make irreversible storage changes.

---

## Emergency: Pause Before Upgrade

```bash
# Pause
cast send <PROXY> "pause()" --rpc-url $PC_RPC --private-key $PC_KEY

# (perform upgrade)

# Unpause
cast send <PROXY> "unpause()" --rpc-url $PC_RPC --private-key $PC_KEY
```
