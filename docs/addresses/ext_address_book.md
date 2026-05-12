# External Address Book

External contract addresses that TAP depends on. Updated as new dependencies are identified.

---

## Push Chain Donut Testnet (Chain ID: 42101)

| Contract          | Address                                      | Notes                                                    |
| ----------------- | -------------------------------------------- | -------------------------------------------------------- |
| UEA Factory       | `0x00000000000000000000000000000000000000eA` | Predeploy. `getOriginForUEA()` returns origin chain info |
| Universal Gateway | `0x00000000000000000000000000000000000000C1` | Cross-chain message relay                                |
| Universal Core    | `0x00000000000000000000000000000000000000C0` | Push Chain system contract                               |

---

## ERC-8004 Contracts (Testnets)

Deterministic CREATE2 deployment — same addresses on all testnet chains.

### IdentityRegistry (Testnet): `0x8004A818BFB912233c491871b3d84c89A494BD9e`

| Chain            | Chain ID | CAIP-2          | Status   |
| ---------------- | -------- | --------------- | -------- |
| Ethereum Sepolia | 11155111 | eip155:11155111 | Verified |
| Base Sepolia     | 84532    | eip155:84532    | Verified |
| BNB Testnet      | 97       | eip155:97       | Verified |

### TAPReputationRegistry (Testnet): `0x8004B663056A597Dffe9eCcC1965A193B7388713`

| Chain            | Chain ID | CAIP-2          | Status           |
| ---------------- | -------- | --------------- | ---------------- |
| Ethereum Sepolia | 11155111 | eip155:11155111 | Deployed (proxy) |
| Base Sepolia     | 84532    | eip155:84532    | Deployed (proxy) |
| BNB Testnet      | 97       | eip155:97       | Deployed (proxy) |

---

## ERC-8004 Contracts (Mainnets)

For future reference. Not used in testnet demo.

| Contract              | Address                                      |
| --------------------- | -------------------------------------------- |
| IdentityRegistry      | `0x8004A169FB4a3325136EB29fA0ceB6D2e539a432` |
| TAPReputationRegistry | `0x8004BAa17C55a88189AE136b182e5fdA19dE9b63` |

---

## Push Chain External Gateways (Source Chains)

| Chain            | Gateway Address                              |
| ---------------- | -------------------------------------------- |
| Ethereum Sepolia | `0x05bD7a3D18324c1F7e216f7fBF2b15985aE5281A` |
| Arbitrum Sepolia | `0x2cd870e0166Ba458dEC615168Fd659AacD795f34` |
| Base Sepolia     | `0xFD4fef1F43aFEc8b5bcdEEc47f35a1431479aC16` |
| BNB Testnet      | `0x44aFFC61983F4348DdddB886349eb992C061EaC0` |
