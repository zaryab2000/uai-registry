// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @param agentId The agent ID not found in UAIRegistry.
error AgentNotRegisteredForReputation(uint256 agentId);

/// @param agentId The agent ID.
/// @param chainNamespace CAIP-2 namespace.
/// @param chainId CAIP-2 chain ID.
/// @param storedBlock Currently stored source block number.
/// @param submittedBlock The rejected (stale) block number.
error StaleSubmission(
    uint256 agentId,
    string chainNamespace,
    string chainId,
    uint256 storedBlock,
    uint256 submittedBlock
);

/// @param severityBps The invalid severity value.
error InvalidSeverity(uint256 severityBps);

/// @dev Thrown when chainNamespace or chainId is empty.
error InvalidChainIdentifierReputation();

/// @dev Thrown when registryAddress is address(0).
error InvalidRegistryAddressReputation();

/// @param agentId The agent ID.
/// @param chainNamespace CAIP-2 namespace of the unlinked chain.
/// @param chainId CAIP-2 chain ID of the unlinked chain.
error ShadowNotLinked(
    uint256 agentId,
    string chainNamespace,
    string chainId
);

/// @param size The submitted batch size.
/// @param max The maximum allowed batch size.
error BatchTooLarge(uint256 size, uint256 max);

/// @dev Thrown when batch is empty.
error EmptyBatch();

/// @param valueDecimals The invalid decimal value.
error InvalidDecimals(uint8 valueDecimals);

/// @dev Thrown when uaiRegistry address is zero.
error InvalidUAIRegistryAddress();

/// @dev Thrown when admin or pauser address is zero in initialize().
error InvalidInitializationAddress();

/// @param agentId The agent that hit the 256-slash cap.
error MaxSlashRecordsExceeded(uint256 agentId);

/// @param summaryValue The out-of-range value.
/// @param maxAbsolute The maximum allowed absolute value.
error SummaryValueOutOfRange(int128 summaryValue, int128 maxAbsolute);

/// @param agentId The agent that hit the chain key cap.
/// @param max The maximum allowed chain keys.
error TooManyChainKeys(uint256 agentId, uint256 max);
