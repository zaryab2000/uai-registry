// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @param agentId The agent ID that was not found.
error AgentNotRegistered(uint256 agentId);

/// @dev Thrown when a zero agentCardHash is passed to register or setAgentCardHash.
error AgentCardHashRequired();

/// @dev Thrown when a proof type other than OWNER_KEY_SIGNED is supplied.
error UnsupportedProofType();

/// @param chainNamespace CAIP-2 namespace of the already-claimed binding.
/// @param chainId CAIP-2 chain ID of the already-claimed binding.
/// @param registryAddress ERC-8004 registry on the bound chain.
/// @param boundAgentId Agent ID on the bound chain registry.
error BindingAlreadyClaimed(
    string chainNamespace, string chainId, address registryAddress, uint256 boundAgentId
);

/// @param chainNamespace CAIP-2 namespace of the missing binding.
/// @param chainId CAIP-2 chain ID of the missing binding.
/// @param registryAddress ERC-8004 registry on the bound chain.
error BindingNotFound(string chainNamespace, string chainId, address registryAddress);

/// @param deadline The expired deadline timestamp.
error BindExpired(uint256 deadline);

/// @param nonce The already-consumed nonce.
error BindNonceUsed(uint256 nonce);

/// @dev Thrown when the EIP-712 bind signature does not recover to the agent's ownerKey.
error InvalidBindSignature();

/// @dev Thrown when chainNamespace or chainId is empty.
error InvalidChainIdentifier();

/// @dev Thrown when registryAddress is address(0).
error InvalidRegistryAddress();

/// @dev Thrown on any ERC-721 transfer, approve, or setApprovalForAll call (soulbound).
error IdentityNotTransferable();

/// @param agentId The agent that hit the 64-binding cap.
error MaxBindingsExceeded(uint256 agentId);
