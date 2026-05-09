# ReputationRegistry

Cross-Chain Agent Reputation Aggregator on Push Chain.

ReputationRegistry collects per-chain reputation data for AI agents and computes a single, normalized reputation score (0-10,000 basis points) that reflects an agent's performance across every chain it operates on. It works alongside AgentRegistry: where AgentRegistry answers "who is this agent?", ReputationRegistry answers "how trustworthy is this agent?"

---

## The Problem

ERC-8004 defines per-chain ReputationRegistryUpgradeable contracts. Each chain tracks feedback, ratings, and reputation independently. An agent with a perfect track record on Ethereum has zero reputation on Base until it earns it there from scratch. This creates several problems:

- **Reputation fragmentation**: An agent's reputation is scattered across chains with no way to see the full picture. A user on Arbitrum has no visibility into an agent's Ethereum track record.
- **Cold start on every chain**: When an agent expands to a new chain, it starts with zero reputation regardless of years of proven performance elsewhere. Users have no reason to trust it.
- **No accountability across chains**: A malicious agent slashed on one chain can operate freely on another. There's no mechanism to propagate negative reputation signals cross-chain.
- **Incomparable metrics**: Different chains may use different rating scales, feedback formats, and decimal precisions. Raw data from one chain is not directly comparable to another.

---

## How ReputationRegistry Solves It

ReputationRegistry acts as a cross-chain reputation aggregator that:

1. **Collects** per-chain reputation snapshots from authorized reporters
2. **Normalizes** data across different decimal precisions to a common scale
3. **Aggregates** feedback-count-weighted averages across all chains
4. **Computes** a single reputation score using a formula that rewards quality, volume, and chain diversity while penalizing slashing events
5. **Enforces** staleness protection so reputation data always moves forward

### Architecture Overview

```
                          Push Chain
                   +--------------------+
                   | ReputationRegistry |
                   |  (aggregated score)|
                   +--------+-----------+
                            |
          reads bindings from AgentRegistry
                            |
         +------------------+------------------+
         |                  |                  |
  +------+-------+  +------+-------+  +-------+------+
  | Ethereum     |  | Base         |  | Arbitrum     |
  | ERC-8004     |  | ERC-8004     |  | ERC-8004     |
  | ReputationReg|  | ReputationReg|  | ReputationReg|
  +--------------+  +--------------+  +--------------+
         |                  |                  |
    off-chain reporters read per-chain data,
    submit snapshots to ReputationRegistry
```

The flow:
1. Per-chain ERC-8004 ReputationRegistryUpgradeable contracts accumulate local feedback.
2. Authorized reporters (off-chain services or relayers) read per-chain reputation data.
3. Reporters submit snapshots to ReputationRegistry on Push Chain.
4. ReputationRegistry validates each submission against AgentRegistry bindings (ensuring the agent actually has a linked identity on that chain).
5. ReputationRegistry normalizes, aggregates, and scores.

---

## Novel Features (Beyond ERC-8004)

ERC-8004 defines per-chain reputation storage and explicitly states that "more complex reputation aggregation will happen off-chain." ReputationRegistry moves that aggregation on-chain and introduces several features that do not exist in the base specification.

### Reputation Score Formula (0-10,000 bps)

ERC-8004 stores raw weighted averages per chain with no composite score. ReputationRegistry computes a single, normalized score from 0 to 10,000 basis points using a multi-factor formula that combines quality, volume, diversity, and slashing into one number. This gives consumers a single value to gate access decisions without interpreting raw data.

### Diversity Bonus

Agents that operate across multiple chains receive a bonus of 500 bps per chain (capped at 2,000 bps for 4+ chains). This incentivizes genuine cross-chain participation and makes it harder for an agent to farm a high score on a single low-activity chain. No equivalent exists in ERC-8004.

### Volume Multiplier (log2-scaled)

The score scales the base quality rating by `log2(totalFeedbackCount)`, ranging from 0.5x (1 feedback) to 1.0x (1,024+ feedbacks). This penalizes agents with thin track records — a perfect rating from 2 feedbacks produces a lower score than a good rating from thousands. ERC-8004 treats all feedback counts equally.

### Cross-Chain Slashing with Persistent Penalties

ERC-8004 has no slashing mechanism. ReputationRegistry introduces `SLASHER_ROLE` with cumulative severity deductions that persist even if the associated binding is later removed. An agent cannot escape a slash by unbinding from the chain where the incident occurred. Up to 256 slash records are stored per agent with full provenance (chain, reason, evidence hash, timestamp, slasher address).

### Staleness Protection

Each per-chain submission includes a `sourceBlockNumber` that must be strictly greater than the previously stored value for that agent+chain combination. This prevents replay attacks and guarantees monotonic data freshness. ERC-8004 has no equivalent ordering constraint on reputation updates.

### Positive/Negative Sentiment Tracking

ReputationRegistry tracks `positiveCount` and `negativeCount` alongside the `summaryValue`. While these do not factor into the score formula, they provide consumers with sentiment breakdown that ERC-8004's single weighted average does not expose.

---

## Detailed Mechanics

### Roles

| Role | Purpose |
|------|---------|
| `DEFAULT_ADMIN_ROLE` | Grants/revokes roles. Updates AgentRegistry address. |
| `REPORTER_ROLE` | Submits per-chain reputation snapshots. |
| `SLASHER_ROLE` | Records slashing events against agents. |
| `PAUSER_ROLE` | Pauses/unpauses the contract. |

These are separate roles, not hierarchical. An address can hold multiple roles, but each privilege requires explicit grant.

### Per-Chain Reputation Snapshots

A reporter submits a `ReputationSubmission` containing:

| Field | Type | Description |
|-------|------|-------------|
| `agentId` | `uint256` | Canonical agent ID on AgentRegistry |
| `chainNamespace` | `string` | CAIP-2 namespace (e.g., `"eip155"`) |
| `chainId` | `string` | CAIP-2 chain ID (e.g., `"1"`) |
| `registryAddress` | `address` | ERC-8004 registry address on the source chain |
| `boundAgentId` | `uint256` | Agent's ID on the source chain registry |
| `feedbackCount` | `uint64` | Total number of feedback entries on that chain |
| `summaryValue` | `int128` | Weighted average rating (signed, supports negative) |
| `valueDecimals` | `uint8` | Decimal precision of `summaryValue` (max 18) |
| `positiveCount` | `uint64` | Number of positive feedback entries |
| `negativeCount` | `uint64` | Number of negative feedback entries |
| `sourceBlockNumber` | `uint256` | Block number on the source chain at snapshot time |

### Submission Validation

Every submission goes through these checks:

1. **Decimals**: `valueDecimals` must be <= 18.
2. **Chain identifiers**: Neither `chainNamespace` nor `chainId` can be empty.
3. **Registry address**: Cannot be `address(0)`.
4. **Agent registration**: The `agentId` must be registered in AgentRegistry.
5. **Binding validation**: The agent must have an active binding to the specified chain. The contract reads all bindings from AgentRegistry and checks that at least one matches the submitted `chainNamespace` and `chainId`.
6. **Staleness protection**: If reputation data already exists for this agent+chain combination, the new submission's `sourceBlockNumber` must be strictly greater than the stored value. This prevents replay attacks and ensures data always moves forward.

### Data Storage

Per-chain reputation is stored using a `chainKey = keccak256(abi.encode(chainNamespace, chainId))`. The storage tracks:

- `chainReputations[agentId][chainKey]` -- the full `ChainReputation` struct
- `chainKeys[agentId]` -- an array of all chain keys for the agent (enables iteration)
- `chainKeyIndex[agentId][chainKey]` -- index into the chain keys array (enables O(1) removal)
- `chainKeyExists[agentId][chainKey]` -- existence flag

This pattern supports efficient iteration for aggregation and O(1) insertion/removal via swap-and-pop.

### Aggregation

When reputation data is submitted (or `reaggregate()` is called), the contract recomputes the aggregate across all chains:

1. **Iterate** over all chain keys for the agent.
2. **Normalize** each chain's `summaryValue` to 18 decimals: `normalized = summaryValue * 10^(18 - valueDecimals)`.
3. **Compute weighted sum**: `weightedSum += normalized * feedbackCount` for each chain.
4. **Sum** all feedback counts, positive counts, and negative counts.
5. **Calculate weighted average**: `weightedAvgValue = weightedSum / totalFeedbackCount`.
6. **Store** the aggregated result and compute the final score.

The weighted average uses feedback count as the weight. A chain with 10,000 feedbacks has 100x the influence of a chain with 100 feedbacks. This prevents a low-activity chain from disproportionately affecting the aggregate.

### Score Computation

The reputation score is a number from 0 to 10,000 basis points, computed as:

```
finalScore = (baseScore * volumeMultiplier / 10000) + diversityBonus - slashPenalty
```

Clamped to [0, 10,000].

#### Base Score (0-7,000)

The base score reflects the quality of feedback:

```
baseScore = weightedAvgValue * 7000 / (100 * 1e18)
```

Where `100 * 1e18` represents a perfect rating (100.0 with 18 decimals). If the weighted average is negative (more negative feedback than positive), the base score is 0 -- it never goes negative.

The 7,000 cap means that quality alone can get you 70% of the maximum score. The remaining 30% comes from volume and diversity.

#### Volume Multiplier (0.5x - 1.0x)

The volume multiplier rewards agents with more total feedback:

```
volumeMultiplier = 5000 + (log2(totalFeedbackCount) * 500)
```

Capped at 10,000 (1.0x).

| Total Feedback | log2 | Multiplier |
|---------------|------|------------|
| 1 | 0 | 0.50x |
| 2 | 1 | 0.55x |
| 4 | 2 | 0.60x |
| 16 | 4 | 0.70x |
| 64 | 6 | 0.80x |
| 256 | 8 | 0.90x |
| 1,024 | 10 | 1.00x (capped) |

An agent with only 1 feedback entry gets its base score halved. An agent with 1,024+ entries gets the full base score. This prevents gaming through a small number of positive feedbacks.

#### Diversity Bonus (0-2,000)

The diversity bonus rewards presence across multiple chains:

```
diversityBonus = chainCount * 500
```

Capped at 2,000 (4 chains max bonus).

| Chains | Bonus |
|--------|-------|
| 1 | 500 |
| 2 | 1,000 |
| 3 | 1,500 |
| 4+ | 2,000 |

An agent active on 4+ chains gets up to 2,000 additional basis points, reflecting broader ecosystem participation.

#### Slash Penalty

Slashing deducts basis points from the score:

```
slashPenalty = sum of all severityBps from slash records
```

Slash penalties are cumulative and persistent. If an agent has been slashed for 3,000 bps total, that deduction applies permanently (though the score is clamped to 0, never going negative).

#### Score Examples

**High-reputation multi-chain agent:**
- Weighted average: 95/100 (95 * 1e18)
- Total feedback: 5,000 across 3 chains
- No slashes

```
baseScore     = 95e18 * 7000 / 100e18 = 6,650
volumeMult    = 5000 + (log2(5000) * 500) = 5000 + (12 * 500) = 11,000 → capped at 10,000
adjustedBase  = 6,650 * 10,000 / 10,000 = 6,650
diversityBon  = 3 * 500 = 1,500
finalScore    = 6,650 + 1,500 = 8,150 bps (81.5%)
```

**New agent, single chain, few feedbacks:**
- Weighted average: 80/100
- Total feedback: 5 on 1 chain
- No slashes

```
baseScore     = 80e18 * 7000 / 100e18 = 5,600
volumeMult    = 5000 + (log2(5) * 500) = 5000 + (2 * 500) = 6,000
adjustedBase  = 5,600 * 6,000 / 10,000 = 3,360
diversityBon  = 1 * 500 = 500
finalScore    = 3,360 + 500 = 3,860 bps (38.6%)
```

**Slashed agent:**
- Weighted average: 90/100
- Total feedback: 1,000 on 2 chains
- Slashed for 5,000 bps total

```
baseScore     = 90e18 * 7000 / 100e18 = 6,300
volumeMult    = 5000 + (log2(1000) * 500) = 5000 + (9 * 500) = 9,500
adjustedBase  = 6,300 * 9,500 / 10,000 = 5,985
diversityBon  = 2 * 500 = 1,000
preSlash      = 5,985 + 1,000 = 6,985
finalScore    = 6,985 - 5,000 = 1,985 bps (19.85%)
```

### Slashing

The `SLASHER_ROLE` can record slashing events against any registered agent:

```solidity
slash(agentId, chainNamespace, chainId, reason, evidenceHash, severityBps)
```

- `severityBps` must be between 1 and 10,000.
- `evidenceHash` is the keccak-256 hash of off-chain evidence data.
- Up to 256 slash records can be stored per agent (`MAX_SLASH_RECORDS`).
- The `totalSlashSeverity` is incremented by `severityBps`.
- The score is recomputed immediately.

Slash records persist even if the associated binding is later removed. This prevents an agent from escaping negative history by unbinding and rebinding.

### Batch Submission

Reporters can submit up to 50 reputation snapshots in a single transaction via `batchSubmitReputation()`. The contract tracks unique agent IDs in the batch and reaggregates once per unique agent (not once per submission), saving gas when multiple chains are submitted for the same agent.

### Reaggregation

The `reaggregate(agentId)` function is permissionless -- anyone can call it. It:

1. Reads the agent's current bindings from AgentRegistry.
2. Iterates over stored chain keys and removes any that no longer have a corresponding binding. This handles the case where a binding was removed via AgentRegistry but the reputation data hasn't been cleaned up yet.
3. Recomputes the aggregate and score.

This ensures reputation data stays consistent with the current identity graph. If an agent unbinds from Ethereum, reaggregation removes Ethereum reputation data from the aggregate.

### Freshness Checks

The `isFresh(agentId, maxAge)` function lets consumers check if reputation data is recent enough for their use case:

```solidity
bool fresh = repRegistry.isFresh(agentId, 1 hours);
```

This returns `true` if the last aggregation was within `maxAge` seconds. Consumers can set their own staleness threshold.

---

## How ReputationRegistry Works with ERC-8004

The relationship between ReputationRegistry and ERC-8004 mirrors how AgentRegistry relates to per-chain IdentityRegistries:

- **ERC-8004 per-chain**: Each chain's ReputationRegistryUpgradeable accumulates local feedback from users interacting with agents on that chain. This is the raw data source.
- **Off-chain reporters**: Authorized services read per-chain reputation data (via events, view functions, or indexers) and format it into `ReputationSubmission` structs.
- **ReputationRegistry on Push Chain**: Receives submissions, validates against AgentRegistry bindings, normalizes, and aggregates.

The dependency chain is:

```
ERC-8004 (per-chain)
    → reporters read local reputation data
        → submit to ReputationRegistry (Push Chain)
            → validates against AgentRegistry bindings
                → computes aggregated score
```

ReputationRegistry never reads directly from per-chain contracts. It trusts authorized reporters to submit accurate snapshots. The trust model is:

- **Reporters are trusted**: The `REPORTER_ROLE` is granted to vetted off-chain services. They are responsible for reading per-chain data accurately.
- **Bindings are verified**: ReputationRegistry validates that the agent actually has a linked identity on the submitted chain by querying AgentRegistry. This prevents reporters from submitting phantom reputation data for chains where the agent doesn't exist.
- **Staleness is enforced on-chain**: The `sourceBlockNumber` check ensures that old data cannot overwrite new data, regardless of reporter behavior.
- **Slashing is independent**: `SLASHER_ROLE` is separate from `REPORTER_ROLE`. Slashing doesn't require a binding and persists through unbinds.

---

## Real-World Example: Multi-Chain DeFi Agent

Consider "YieldBot", an AI agent that optimizes yield farming across Ethereum, Base, and Arbitrum. It has been registered on AgentRegistry and bound to all three chains.

### Step 1: Earning Reputation Per-Chain

Users interact with YieldBot on each chain. After each interaction, they leave feedback via the per-chain ERC-8004 ReputationRegistryUpgradeable:

- **Ethereum**: 500 feedbacks, average rating 92/100 (92 * 1e18, 18 decimals)
- **Base**: 300 feedbacks, average rating 88/100
- **Arbitrum**: 200 feedbacks, average rating 95/100

### Step 2: Reporter Submits Snapshots

An authorized reporter reads these per-chain ratings and submits three snapshots to ReputationRegistry on Push Chain:

```solidity
// Ethereum snapshot
repRegistry.submitReputation(ReputationSubmission({
    agentId: yieldBotAgentId,
    chainNamespace: "eip155",
    chainId: "1",
    registryAddress: 0xEthReputationRegistry...,
    boundAgentId: 17,
    feedbackCount: 500,
    summaryValue: 92 * 1e18,
    valueDecimals: 18,
    positiveCount: 460,
    negativeCount: 40,
    sourceBlockNumber: 19_500_000
}));
```

For efficiency, the reporter uses batch submission for all three at once:

```solidity
ReputationSubmission[] memory subs = new ReputationSubmission[](3);
subs[0] = ethSubmission;
subs[1] = baseSubmission;
subs[2] = arbSubmission;
repRegistry.batchSubmitReputation(subs);
```

The contract validates each submission:
- Checks YieldBot is registered in AgentRegistry
- Checks YieldBot has a binding to each chain (queries `AgentRegistry.getBindings()`)
- Checks no stale block numbers
- Stores per-chain reputation data
- Reaggregates once (all three submissions are for the same agent)

### Step 3: Aggregation Happens Automatically

After submission, the contract aggregates:

```
Weighted sum = (92e18 * 500) + (88e18 * 300) + (95e18 * 200)
             = 46000e18 + 26400e18 + 19000e18
             = 91400e18

Total feedback = 500 + 300 + 200 = 1000

Weighted average = 91400e18 / 1000 = 91.4e18 (91.4/100)
```

Score computation:
```
baseScore     = 91.4e18 * 7000 / 100e18 = 6,398
volumeMult    = 5000 + (log2(1000) * 500) = 5000 + (9 * 500) = 9,500
adjustedBase  = 6,398 * 9,500 / 10,000 = 6,078
diversityBon  = 3 * 500 = 1,500
finalScore    = 6,078 + 1,500 = 7,578 bps (75.78%)
```

### Step 4: A User Checks Reputation

A DeFi protocol on Base wants to gate access to high-value vaults. Before letting YieldBot manage funds, it checks reputation on Push Chain:

```solidity
uint256 score = repRegistry.getReputationScore(yieldBotAgentId);
require(score >= 7000, "Insufficient reputation");

bool fresh = repRegistry.isFresh(yieldBotAgentId, 24 hours);
require(fresh, "Reputation data too old");
```

For more detail:

```solidity
IReputationRegistry.AggregatedReputation memory agg =
    repRegistry.getAggregatedReputation(yieldBotAgentId);

// agg.totalFeedbackCount = 1000
// agg.weightedAvgValue = 91.4e18
// agg.totalPositive = 940
// agg.totalNegative = 60
// agg.chainCount = 3
// agg.reputationScore = 7578
```

Or per-chain breakdown:

```solidity
IReputationRegistry.ChainReputation memory ethRep =
    repRegistry.getChainReputation(yieldBotAgentId, "eip155", "1");

// ethRep.feedbackCount = 500
// ethRep.summaryValue = 92e18
// ethRep.positiveCount = 460
// ethRep.negativeCount = 40
// ethRep.sourceBlockNumber = 19500000
// ethRep.reporter = 0xReporter...
```

### Step 5: Slashing Event

YieldBot makes a bad trade on Arbitrum that loses user funds. The slashing authority records the incident:

```solidity
repRegistry.slash(
    yieldBotAgentId,
    "eip155",
    "42161",                    // Arbitrum chain ID
    "Unauthorized fund loss in vault strategy",
    keccak256(evidenceData),    // evidence stored on IPFS
    3000                        // 30% severity
);
```

The score is immediately recomputed:

```
preSlash  = 7,578
penalty   = 3,000
newScore  = 7,578 - 3,000 = 4,578 bps (45.78%)
```

Now the Base vault that requires 7,000 bps will reject YieldBot. The slash is visible on all chains because it affects the aggregated score.

### Step 6: Reputation Updates Over Time

As YieldBot continues operating and receiving new feedback, reporters submit updated snapshots with higher `sourceBlockNumber` values. The staleness check ensures only newer data is accepted:

```solidity
// Previous Ethereum submission had sourceBlockNumber = 19_500_000
// New submission must have sourceBlockNumber > 19_500_000
repRegistry.submitReputation(ReputationSubmission({
    agentId: yieldBotAgentId,
    chainNamespace: "eip155",
    chainId: "1",
    registryAddress: 0xEthReputationRegistry...,
    boundAgentId: 17,
    feedbackCount: 750,          // more feedback now
    summaryValue: 93 * 1e18,    // slightly improved
    valueDecimals: 18,
    positiveCount: 700,
    negativeCount: 50,
    sourceBlockNumber: 20_000_000  // must be > 19_500_000
}));
```

### Step 7: Unbind and Reaggregation

If YieldBot stops operating on Arbitrum and the operator unbinds Arbitrum from AgentRegistry, anyone can call:

```solidity
repRegistry.reaggregate(yieldBotAgentId);
```

This detects that the Arbitrum binding no longer exists, removes Arbitrum reputation data from the aggregate, and recomputes the score using only Ethereum and Base data. The slash record from Arbitrum remains -- it is not removed when the binding is removed.

---

## Storage Architecture

ReputationRegistry uses ERC-7201 namespaced storage at:

```
STORAGE_SLOT = keccak256(abi.encode(uint256(keccak256("tap.reputation.storage")) - 1))
                & ~bytes32(uint256(0xff))
```

| Field | Type | Purpose |
|-------|------|---------|
| `aggregated` | `mapping(uint256 => AggregatedReputation)` | Per-agent aggregated reputation |
| `chainReputations` | `mapping(uint256 => mapping(bytes32 => ChainReputation))` | Per-agent, per-chain reputation snapshots |
| `chainKeys` | `mapping(uint256 => bytes32[])` | Per-agent array of chain keys (for iteration) |
| `chainKeyIndex` | `mapping(uint256 => mapping(bytes32 => uint256))` | Index into chainKeys array (for O(1) removal) |
| `chainKeyExists` | `mapping(uint256 => mapping(bytes32 => bool))` | Existence flag |
| `slashRecords` | `mapping(uint256 => SlashRecord[])` | Per-agent slash history |
| `totalSlashSeverity` | `mapping(uint256 => uint256)` | Cumulative slash severity in bps |
| `agentRegistry` | `address` | Address of the AgentRegistry proxy |

---

## Function Reference

### Submission

| Function | Access | Description |
|----------|--------|-------------|
| `submitReputation(submission)` | REPORTER_ROLE | Submit a single per-chain reputation snapshot. |
| `batchSubmitReputation(submissions[])` | REPORTER_ROLE | Submit up to 50 snapshots. Reaggregates once per unique agent. |

### Slashing

| Function | Access | Description |
|----------|--------|-------------|
| `slash(agentId, ns, id, reason, evidenceHash, severityBps)` | SLASHER_ROLE | Record a slashing event (1-10,000 bps). |

### Aggregation

| Function | Access | Description |
|----------|--------|-------------|
| `reaggregate(agentId)` | Anyone | Force recompute. Removes data for unlinked bindings. |

### Reads

| Function | Description |
|----------|-------------|
| `getAggregatedReputation(agentId)` | Full aggregated struct (score, counts, averages). |
| `getChainReputation(agentId, ns, id)` | Per-chain snapshot for a specific chain. |
| `getAllChainReputations(agentId)` | All per-chain snapshots for an agent. |
| `getReputationScore(agentId)` | Normalized score (0-10,000 bps). |
| `getSlashRecords(agentId)` | All slash records for an agent. |
| `isFresh(agentId, maxAge)` | Whether last aggregation is within `maxAge` seconds. |
| `lastUpdated(agentId)` | Timestamp of last aggregation. |
| `getAgentRegistry()` | Current AgentRegistry address. |

### Admin

| Function | Access | Description |
|----------|--------|-------------|
| `setAgentRegistry(newAddr)` | DEFAULT_ADMIN_ROLE | Update the AgentRegistry reference. |
| `pause()` | PAUSER_ROLE | Pause submissions and slashing. |
| `unpause()` | PAUSER_ROLE | Resume operations. |

### Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `MAX_BATCH_SIZE` | 50 | Maximum submissions per batch call |
| `MAX_SLASH_RECORDS` | 256 | Maximum slash records per agent |
| `MAX_DECIMALS` | 18 | Maximum allowed `valueDecimals` |
| `MAX_BPS` | 10,000 | Maximum score / severity |
