// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Gateway adapter address is zero.
error InvalidGatewayAdapter();

/// @dev Settlement registry address is zero.
error InvalidSettlementRegistry();

/// @dev Cross-chain propagation is disabled.
error PropagationDisabled();

/// @dev Agent was already synced to the settlement chain.
/// @param agentId The agent that was already synced.
error AlreadySynced(uint256 agentId);

/// @dev Caller is not the agent owner.
/// @param agentId The agent ID.
error NotAgentOwner(uint256 agentId);

/// @dev Batch threshold cannot be zero.
error InvalidBatchThreshold();

/// @dev UEA recipient address is zero.
error InvalidUEARecipient();
