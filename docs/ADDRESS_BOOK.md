# Address Book

Deployed contract addresses for TAP (Trustless Agents Plus). Update this file after every deployment or upgrade.

---

## Push Chain Donut Testnet (Chain ID: 42101)

Deployed: 2026-05-09

### AgentRegistry

| Component | Address |
|-----------|---------|
| Proxy | `0x13499d36729467bd5C6B44725a10a0113cE47178` |
| Implementation (v1) | `0x593a68fc512608e8f5bf4ebf919117c8ab8ecd15` |
| ProxyAdmin | `0x062021b898e2693f41bb69d463c016cda568794e` |

### ReputationRegistry

| Component | Address |
|-----------|---------|
| Proxy | `0x90B484063622289742516c5dDFdDf1C1A3C2c50C` |
| Implementation (v1) | `0x59ab150c2ba3efd618668a469db29f5c92eedd64` |
| ProxyAdmin | `0x32e0b8a0fdd30c8a64bf013ea8d224ed79cbcab8` |

### Roles

| Role | Holder |
|------|--------|
| DEFAULT_ADMIN_ROLE | `0x53CE8AA36CD92A25AF7AA2cFfd08DC46b080c88a` |
| PAUSER_ROLE | `0x53CE8AA36CD92A25AF7AA2cFfd08DC46b080c88a` |
| REPORTER_ROLE | `0x53CE8AA36CD92A25AF7AA2cFfd08DC46b080c88a` |
| SLASHER_ROLE | `0x53CE8AA36CD92A25AF7AA2cFfd08DC46b080c88a` |
| ProxyAdmin Owner | `0x53CE8AA36CD92A25AF7AA2cFfd08DC46b080c88a` |

### Push Chain System Contracts

| Contract | Address |
|----------|---------|
| UEA Factory | `0x00000000000000000000000000000000000000eA` |
| Universal Gateway PC | `0x00000000000000000000000000000000000000C1` |
| Universal Core | `0x00000000000000000000000000000000000000C0` |

### Block Explorer Links

- [AgentRegistry Proxy](https://donut.push.network/address/0x13499d36729467bd5C6B44725a10a0113cE47178)
- [AgentRegistry Impl](https://donut.push.network/address/0x593a68fc512608e8f5bf4ebf919117c8ab8ecd15)
- [ReputationRegistry Proxy](https://donut.push.network/address/0x90B484063622289742516c5dDFdDf1C1A3C2c50C)
- [ReputationRegistry Impl](https://donut.push.network/address/0x59ab150c2ba3efd618668a469db29f5c92eedd64)

---

## Upgrade History

| Date | Contract | Old Impl | New Impl | Notes |
|------|----------|----------|----------|-------|
| 2026-05-09 | AgentRegistry | — | `0x593a...cd15` | Initial deployment (TAP namespace) |
| 2026-05-09 | ReputationRegistry | — | `0x59ab...dd64` | Initial deployment (TAP namespace) |

---

## Deprecated Deployments

Previous deployments using `agentgraph.*` namespace (superseded by TAP rename):

| Contract | Address | Status |
|----------|---------|--------|
| AgentRegistry Impl (old) | `0x3e7e8195391c5918ab8ba0133bc0dbdcdd62e54d` | Deprecated |
| AgentRegistry Proxy (old) | `0xc2E531735594A5275793234C86b51d0E486452Ea` | Deprecated |
| ReputationRegistry Impl (old) | `0x6ed969b1bbcdcc68790ed881ea11ddbb0a47dcb8` | Deprecated |
| ReputationRegistry Proxy (old) | `0x5ec27E61a3dC153115ddaEFfa4f9D5a9Ab9C3503` | Deprecated |

---

## Source-Chain Deployments

_Not yet deployed. Will be added after source-chain wrappers go live._

### External Chain Gateways (for reference)

| Chain | Gateway Address |
|-------|-----------------|
| Ethereum Sepolia | `0x05bD7a3D18324c1F7e216f7fBF2b15985aE5281A` |
| Arbitrum Sepolia | `0x2cd870e0166Ba458dEC615168Fd659AacD795f34` |
| Base Sepolia | `0xFD4fef1F43aFEc8b5bcdEEc47f35a1431479aC16` |
| BNB Testnet | `0x44aFFC61983F4348DdddB886349eb992C061EaC0` |
