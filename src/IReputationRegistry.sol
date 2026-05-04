// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IReputationRegistry
/// @notice Cross-chain agent reputation aggregator on Push Chain.
///         Stores per-chain reputation snapshots submitted by authorized reporters
///         and computes aggregated scores keyed to canonical UEA via UAIRegistry.
interface IReputationRegistry {
    // ──────────────────────────────────────────────
    //  Types
    // ──────────────────────────────────────────────

    /// @notice Per-chain reputation snapshot submitted by an authorized reporter.
    struct ChainReputation {
        string chainNamespace;
        string chainId;
        address registryAddress;
        uint256 shadowAgentId;
        uint64 feedbackCount;
        int128 summaryValue;
        uint8 valueDecimals;
        uint64 positiveCount;
        uint64 negativeCount;
        uint256 sourceBlockNumber;
        uint64 lastUpdated;
        address reporter;
    }

    /// @notice Aggregated reputation across all chains for an agent.
    struct AggregatedReputation {
        uint64 totalFeedbackCount;
        int128 weightedAvgValue;
        uint8 valueDecimals;
        uint64 totalPositive;
        uint64 totalNegative;
        uint16 chainCount;
        uint64 lastAggregated;
        uint256 reputationScore;
    }

    /// @notice Record of a slashing event.
    struct SlashRecord {
        string chainNamespace;
        string chainId;
        string reason;
        bytes32 evidenceHash;
        uint64 slashedAt;
        address reporter;
        uint256 severityBps;
    }

    /// @notice Input payload for submitting per-chain reputation data.
    struct ReputationSubmission {
        uint256 agentId;
        string chainNamespace;
        string chainId;
        address registryAddress;
        uint256 shadowAgentId;
        uint64 feedbackCount;
        int128 summaryValue;
        uint8 valueDecimals;
        uint64 positiveCount;
        uint64 negativeCount;
        uint256 sourceBlockNumber;
    }

    // ──────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────

    /// @notice Emitted when per-chain reputation data is submitted or updated.
    event ReputationSubmitted(
        uint256 indexed agentId,
        string chainNamespace,
        string chainId,
        uint64 feedbackCount,
        int128 summaryValue,
        address indexed reporter
    );

    /// @notice Emitted when aggregated reputation is recomputed.
    event ReputationAggregated(
        uint256 indexed agentId,
        uint64 totalFeedbackCount,
        uint256 reputationScore,
        uint16 chainCount
    );

    /// @notice Emitted when a slashing event is recorded.
    event AgentSlashed(
        uint256 indexed agentId,
        string chainNamespace,
        string chainId,
        string reason,
        uint256 severityBps,
        address indexed reporter
    );

    /// @notice Emitted when the UAIRegistry address is updated.
    event UAIRegistryUpdated(
        address indexed oldAddr,
        address indexed newAddr
    );

    // ──────────────────────────────────────────────
    //  Write Functions
    // ──────────────────────────────────────────────

    /// @notice Submit or update per-chain reputation for an agent.
    /// @dev Only callable by REPORTER_ROLE. Validates agent registration
    ///      and shadow link existence in UAIRegistry. Recomputes aggregate.
    /// @param submission The reputation data to submit.
    function submitReputation(
        ReputationSubmission calldata submission
    ) external;

    /// @notice Batch submit reputation for multiple agents/chains.
    /// @dev Reaggregates once per unique agentId for gas efficiency.
    /// @param submissions Array of reputation submissions (max MAX_BATCH_SIZE).
    function batchSubmitReputation(
        ReputationSubmission[] calldata submissions
    ) external;

    /// @notice Record a slashing event for an agent.
    /// @dev Only callable by SLASHER_ROLE. Slash records persist even
    ///      after shadow unlinks.
    /// @param agentId The canonical agent ID.
    /// @param chainNamespace Source chain namespace where slash originated.
    /// @param chainId Source chain ID.
    /// @param reason Human-readable reason for the slash.
    /// @param evidenceHash keccak256 of the evidence data (stored off-chain).
    /// @param severityBps Severity in basis points (1-10000).
    function slash(
        uint256 agentId,
        string calldata chainNamespace,
        string calldata chainId,
        string calldata reason,
        bytes32 evidenceHash,
        uint256 severityBps
    ) external;

    /// @notice Force recomputation of aggregated reputation for an agent.
    /// @dev Callable by anyone. Removes data for unlinked shadows.
    /// @param agentId The canonical agent ID.
    function reaggregate(uint256 agentId) external;

    /// @notice Update the UAIRegistry address.
    /// @dev Only callable by DEFAULT_ADMIN_ROLE.
    /// @param newUAIRegistry The new UAIRegistry proxy address.
    function setUAIRegistry(address newUAIRegistry) external;

    // ──────────────────────────────────────────────
    //  Read Functions
    // ──────────────────────────────────────────────

    /// @notice Get the aggregated cross-chain reputation for an agent.
    /// @param agentId The canonical agent ID.
    /// @return The aggregated reputation struct (zeroed if no data).
    function getAggregatedReputation(
        uint256 agentId
    ) external view returns (AggregatedReputation memory);

    /// @notice Get per-chain reputation snapshot for a specific chain.
    /// @param agentId The canonical agent ID.
    /// @param chainNamespace CAIP-2 namespace.
    /// @param chainId CAIP-2 chain ID.
    /// @return The chain-specific reputation struct (zeroed if no data).
    function getChainReputation(
        uint256 agentId,
        string calldata chainNamespace,
        string calldata chainId
    ) external view returns (ChainReputation memory);

    /// @notice Get all per-chain reputation snapshots for an agent.
    /// @param agentId The canonical agent ID.
    /// @return Array of all chain reputation entries.
    function getAllChainReputations(
        uint256 agentId
    ) external view returns (ChainReputation[] memory);

    /// @notice Get the normalized reputation score (0-10000 basis points).
    /// @param agentId The canonical agent ID.
    /// @return score The reputation score in basis points.
    function getReputationScore(
        uint256 agentId
    ) external view returns (uint256 score);

    /// @notice Get all slashing records for an agent.
    /// @param agentId The canonical agent ID.
    /// @return Array of slash records.
    function getSlashRecords(
        uint256 agentId
    ) external view returns (SlashRecord[] memory);

    /// @notice Check if reputation data is fresh enough.
    /// @param agentId The canonical agent ID.
    /// @param maxAge Maximum acceptable age in seconds.
    /// @return fresh True if lastAggregated is within maxAge.
    function isFresh(
        uint256 agentId,
        uint256 maxAge
    ) external view returns (bool fresh);

    /// @notice Get the timestamp of the last aggregation for an agent.
    /// @param agentId The canonical agent ID.
    /// @return The lastAggregated timestamp.
    function lastUpdated(uint256 agentId) external view returns (uint64);

    /// @notice Get the current UAIRegistry address.
    /// @return The UAIRegistry contract address.
    function getUAIRegistry() external view returns (address);
}
