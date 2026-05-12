# TAP Address Book

Deployed contract addresses for TAP (Trustless Agents Plus). Update this file after every deployment or upgrade.

---

## Push Chain Donut Testnet (Chain ID: 42101)

Deployed: 2026-05-09

### TAPRegistry

| Component           | Address                                      |
| ------------------- | -------------------------------------------- |
| Proxy               | `0x13499d36729467bd5C6B44725a10a0113cE47178` |
| Implementation (v2) | `0x998e9630b6437bb3c42f42cb48bb9f8124397cf5` |
| ProxyAdmin          | `0x062021b898e2693f41bb69d463c016cda568794e` |

### TAPReputationRegistry

| Component           | Address                                      |
| ------------------- | -------------------------------------------- |
| Proxy               | `0x90B484063622289742516c5dDFdDf1C1A3C2c50C` |
| Implementation (v1) | `0x59ab150c2ba3efd618668a469db29f5c92eedd64` |
| ProxyAdmin          | `0x32e0b8a0fdd30c8a64bf013ea8d224ed79cbcab8` |

### Roles

| Role               | Holder                                       |
| ------------------ | -------------------------------------------- |
| DEFAULT_ADMIN_ROLE | `0x53CE8AA36CD92A25AF7AA2cFfd08DC46b080c88a` |
| PAUSER_ROLE        | `0x53CE8AA36CD92A25AF7AA2cFfd08DC46b080c88a` |
| REPORTER_ROLE      | `0x53CE8AA36CD92A25AF7AA2cFfd08DC46b080c88a` |
| SLASHER_ROLE       | `0x53CE8AA36CD92A25AF7AA2cFfd08DC46b080c88a` |
| ProxyAdmin Owner   | `0x53CE8AA36CD92A25AF7AA2cFfd08DC46b080c88a` |

### Block Explorer Links

- [TAPRegistry Proxy](https://donut.push.network/address/0x13499d36729467bd5C6B44725a10a0113cE47178)
- [TAPRegistry Impl v2](https://donut.push.network/address/0x998e9630b6437bb3c42f42cb48bb9f8124397cf5)
- [TAPReputationRegistry Proxy](https://donut.push.network/address/0x90B484063622289742516c5dDFdDf1C1A3C2c50C)
- [TAPReputationRegistry Impl](https://donut.push.network/address/0x59ab150c2ba3efd618668a469db29f5c92eedd64)

---

## Upgrade History

| Date       | Contract              | Old Impl        | New Impl        | Notes                                                                |
| ---------- | --------------------- | --------------- | --------------- | -------------------------------------------------------------------- |
| 2026-05-09 | TAPRegistry           | —               | `0x593a...cd15` | Initial deployment (TAP namespace)                                   |
| 2026-05-09 | TAPReputationRegistry | —               | `0x59ab...dd64` | Initial deployment (TAP namespace)                                   |
| 2026-05-12 | TAPRegistry           | `0x593a...cd15` | `0x998e...7cf5` | 7-digit truncated agent IDs, ownerToAgentId mapping, collision guard |

---

## Deprecated Deployments

Previous deployments using `agentgraph.*` namespace (superseded by TAP rename):

| Contract                          | Address                                      | Status     |
| --------------------------------- | -------------------------------------------- | ---------- |
| TAPRegistry Impl (old)            | `0x3e7e8195391c5918ab8ba0133bc0dbdcdd62e54d` | Deprecated |
| TAPRegistry Proxy (old)           | `0xc2E531735594A5275793234C86b51d0E486452Ea` | Deprecated |
| TAPReputationRegistry Impl (old)  | `0x6ed969b1bbcdcc68790ed881ea11ddbb0a47dcb8` | Deprecated |
| TAPReputationRegistry Proxy (old) | `0x5ec27E61a3dC153115ddaEFfa4f9D5a9Ab9C3503` | Deprecated |

