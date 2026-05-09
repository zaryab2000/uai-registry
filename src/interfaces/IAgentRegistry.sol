// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    AgentNotRegistered,
    AgentCardHashRequired,
    UnsupportedProofType,
    BindingAlreadyClaimed,
    BindingNotFound,
    BindExpired,
    BindNonceUsed,
    InvalidBindSignature,
    InvalidChainIdentifier,
    InvalidRegistryAddress,
    IdentityNotTransferable,
    MaxBindingsExceeded
} from "../libraries/Errors.sol";

/// @title IAgentRegistry
/// @notice ERC-8004-compatible Universal Agent Identity Registry on Push Chain.
///         Uses UEA addresses as canonical agent identifiers.
///         agentId = uint256(uint160(ueaAddress)) — deterministic, collision-free.
///         Non-transferable (soulbound).
interface IAgentRegistry {
    // ──────────────────────────────────────────────
    //  Types
    // ──────────────────────────────────────────────

    /// @notice Proof mechanism used to verify binding ownership.
    enum BindProofType {
        OWNER_KEY_SIGNED
    }

    /// @notice On-chain record for a registered agent identity.
    struct AgentRecord {
        bool registered;
        string agentURI;
        bytes32 agentCardHash;
        uint64 registeredAt;
        string originChainNamespace;
        string originChainId;
        bytes ownerKey;
        bool nativeToPush;
    }

    /// @notice Stored link between a canonical agent and a per-chain bound identity.
    struct BindEntry {
        string chainNamespace;
        string chainId;
        address registryAddress;
        uint256 boundAgentId;
        BindProofType proofType;
        bool verified;
        uint64 linkedAt;
    }

    /// @notice Input payload for creating a binding.
    /// @dev `proofData` encoding depends on the proof type:
    ///      - OWNER_KEY_SIGNED (ECDSA): raw 65-byte signature (r ‖ s ‖ v).
    ///      - OWNER_KEY_SIGNED (ERC-1271): `abi.encodePacked(signerAddress, signatureBytes)`
    ///        where `signerAddress` is the 20-byte contract address that implements ERC-1271,
    ///        and `signatureBytes` is the contract-specific signature passed to `isValidSignature`.
    struct BindRequest {
        string chainNamespace;
        string chainId;
        address registryAddress;
        uint256 boundAgentId;
        BindProofType proofType;
        bytes proofData;
        uint256 nonce;
        uint256 deadline;
    }

    // ──────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────

    /// @notice Emitted when a new agent identity is registered.
    event Registered(
        uint256 indexed agentId,
        address indexed uea,
        string originChainNamespace,
        string originChainId,
        bytes ownerKey,
        string agentURI,
        bytes32 agentCardHash
    );

    /// @notice Emitted when an agent's URI is updated (via setAgentURI or re-registration).
    event AgentURIUpdated(uint256 indexed agentId, string newAgentURI);

    /// @notice Emitted when an agent's card hash is updated (via setAgentCardHash or re-registration).
    event AgentCardHashUpdated(uint256 indexed agentId, bytes32 newHash);

    /// @notice Emitted when a per-chain identity is bound to a canonical agent.
    event AgentBound(
        uint256 indexed agentId,
        string chainNamespace,
        string chainId,
        address registryAddress,
        uint256 boundAgentId,
        BindProofType proofType,
        bool verified
    );

    /// @notice Emitted when a per-chain identity is unbound from a canonical agent.
    event AgentUnbound(
        uint256 indexed agentId, string chainNamespace, string chainId, address registryAddress
    );

    // ──────────────────────────────────────────────
    //  Registration
    // ──────────────────────────────────────────────

    /// @notice Register a new agent identity or update an existing one.
    /// @dev On first call, creates a record with origin metadata from the UEA factory.
    ///      Subsequent calls update `agentURI` and `agentCardHash` only.
    /// @param agentURI Metadata URI (e.g. IPFS CID) for the agent card.
    /// @param agentCardHash Keccak-256 hash of the agent card content.
    /// @return agentId Deterministic ID derived as `uint256(uint160(msg.sender))`.
    function register(
        string calldata agentURI,
        bytes32 agentCardHash
    ) external returns (uint256 agentId);

    /// @notice Update the metadata URI for the caller's agent.
    /// @param newAgentURI New metadata URI.
    function setAgentURI(
        string calldata newAgentURI
    ) external;

    /// @notice Update the agent card hash for the caller's agent.
    /// @param newHash New keccak-256 hash of the agent card content.
    function setAgentCardHash(
        bytes32 newHash
    ) external;

    // ──────────────────────────────────────────────
    //  Binding
    // ──────────────────────────────────────────────

    /// @notice Bind a per-chain ERC-8004 agent identity to the caller's canonical agent.
    /// @dev Only one binding per (chainNamespace, chainId, registryAddress) tuple is
    ///      allowed per agent. Binding a second entry from the same registry requires
    ///      unbinding the first. This constraint exists because the reverse-lookup index
    ///      keys on the chain+registry tuple without the boundAgentId.
    /// @param req Bind request containing chain identifiers, proof, nonce, and deadline.
    function bind(
        BindRequest calldata req
    ) external;

    /// @notice Remove a binding from the caller's canonical agent.
    /// @param chainNamespace CAIP-2 namespace of the bound chain (e.g. "eip155").
    /// @param chainId CAIP-2 chain ID of the bound chain (e.g. "1").
    /// @param registryAddress ERC-8004 registry address on the bound chain.
    function unbind(
        string calldata chainNamespace,
        string calldata chainId,
        address registryAddress
    ) external;

    // ──────────────────────────────────────────────
    //  Reads — ERC-8004-shaped
    // ──────────────────────────────────────────────

    /// @notice Return the owner (UEA address) of a registered agent.
    /// @param agentId The agent identifier.
    /// @return The UEA address that owns this agent identity.
    function ownerOf(
        uint256 agentId
    ) external view returns (address);

    /// @notice Return the metadata URI for a registered agent (ERC-721 compatible).
    /// @param agentId The agent identifier.
    /// @return The agent's metadata URI string.
    function tokenURI(
        uint256 agentId
    ) external view returns (string memory);

    /// @notice Return the agent card URI (ERC-8004 alias for tokenURI).
    /// @param agentId The agent identifier.
    /// @return The agent's metadata URI string.
    function agentURI(
        uint256 agentId
    ) external view returns (string memory);

    // ──────────────────────────────────────────────
    //  Reads — AgentRegistry-specific
    // ──────────────────────────────────────────────

    /// @notice Return the canonical UEA address for an agent ID.
    /// @param agentId The agent identifier.
    /// @return The UEA address (identical to `address(uint160(agentId))`).
    function canonicalUEA(
        uint256 agentId
    ) external view returns (address);

    /// @notice Return the agent ID for a UEA address, or 0 if unregistered.
    /// @param uea The UEA address to look up.
    /// @return The agent ID, or 0 if no agent is registered at this address.
    function agentIdOfUEA(
        address uea
    ) external view returns (uint256);

    /// @notice Return all bind entries linked to an agent.
    /// @param agentId The agent identifier.
    /// @return Array of bind entries (empty if none linked).
    function getBindings(
        uint256 agentId
    ) external view returns (BindEntry[] memory);

    /// @notice Resolve a bound identity to its canonical UEA.
    /// @param chainNamespace CAIP-2 namespace of the bound chain.
    /// @param chainId CAIP-2 chain ID of the bound chain.
    /// @param registryAddress ERC-8004 registry on the bound chain.
    /// @param boundAgentId Agent ID on the bound chain registry.
    /// @return canonical The canonical UEA address (address(0) if not linked).
    /// @return verified Whether the binding has been cryptographically verified.
    function canonicalUEAFromBinding(
        string calldata chainNamespace,
        string calldata chainId,
        address registryAddress,
        uint256 boundAgentId
    ) external view returns (address canonical, bool verified);

    /// @notice Check whether an agent ID is registered.
    /// @param agentId The agent identifier.
    /// @return True if the agent is registered.
    function isRegistered(
        uint256 agentId
    ) external view returns (bool);

    /// @notice Return the full on-chain record for an agent.
    /// @param agentId The agent identifier.
    /// @return The agent's record (zeroed if unregistered).
    function getAgentRecord(
        uint256 agentId
    ) external view returns (AgentRecord memory);

    // ──────────────────────────────────────────────
    //  ERC-721 transfer surface — all revert
    // ──────────────────────────────────────────────

    /// @notice Always reverts — agent identities are soulbound.
    function transferFrom(
        address from,
        address to,
        uint256 tokenId
    ) external;

    /// @notice Always reverts — agent identities are soulbound.
    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId
    ) external;

    /// @notice Always reverts — agent identities are soulbound.
    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId,
        bytes calldata data
    ) external;

    /// @notice Always reverts — agent identities are soulbound.
    function approve(
        address spender,
        uint256 tokenId
    ) external;

    /// @notice Always reverts — agent identities are soulbound.
    function setApprovalForAll(
        address operator,
        bool approved
    ) external;
}
