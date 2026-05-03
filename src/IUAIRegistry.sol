// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IUAIRegistry
/// @notice ERC-8004-compatible Universal Agent Identity Registry on Push Chain.
///         Uses UEA addresses as canonical agent identifiers.
///         agentId = uint256(uint160(ueaAddress)) — deterministic, collision-free.
///         Non-transferable (soulbound).
interface IUAIRegistry {
    // ──────────────────────────────────────────────
    //  Types
    // ──────────────────────────────────────────────

    enum ShadowProofType {
        OWNER_KEY_SIGNED
    }

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

    struct ShadowEntry {
        string chainNamespace;
        string chainId;
        address registryAddress;
        uint256 shadowAgentId;
        ShadowProofType proofType;
        bool verified;
        uint64 linkedAt;
    }

    struct ShadowLinkRequest {
        string chainNamespace;
        string chainId;
        address registryAddress;
        uint256 shadowAgentId;
        ShadowProofType proofType;
        bytes proofData;
        uint256 nonce;
        uint256 deadline;
    }

    // ──────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────

    event Registered(
        uint256 indexed agentId,
        address indexed uea,
        string originChainNamespace,
        string originChainId,
        bytes ownerKey,
        string agentURI,
        bytes32 agentCardHash
    );

    event AgentURIUpdated(uint256 indexed agentId, string newAgentURI);

    event AgentCardHashUpdated(uint256 indexed agentId, bytes32 newHash);

    event ShadowLinked(
        uint256 indexed agentId,
        string chainNamespace,
        string chainId,
        address registryAddress,
        uint256 shadowAgentId,
        ShadowProofType proofType,
        bool verified
    );

    event ShadowUnlinked(
        uint256 indexed agentId,
        string chainNamespace,
        string chainId,
        address registryAddress
    );

    // ──────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────

    error AgentNotRegistered(uint256 agentId);
    error NotAgentOwner(uint256 agentId, address caller);
    error AgentCardHashRequired();
    error ShadowAlreadyClaimed(
        string chainNamespace,
        string chainId,
        address registryAddress,
        uint256 shadowAgentId
    );
    error ShadowNotFound(
        string chainNamespace,
        string chainId,
        address registryAddress
    );
    error ShadowLinkExpired(uint256 deadline);
    error ShadowLinkNonceUsed(uint256 nonce);
    error InvalidShadowSignature();
    error InvalidChainIdentifier();
    error InvalidRegistryAddress();
    error IdentityNotTransferable();
    error MaxShadowsExceeded(uint256 agentId);

    // ──────────────────────────────────────────────
    //  Registration
    // ──────────────────────────────────────────────

    function register(
        string calldata agentURI,
        bytes32 agentCardHash
    ) external returns (uint256 agentId);

    function setAgentURI(string calldata newAgentURI) external;

    function setAgentCardHash(bytes32 newHash) external;

    // ──────────────────────────────────────────────
    //  Shadow Linking
    // ──────────────────────────────────────────────

    function linkShadow(ShadowLinkRequest calldata req) external;

    function unlinkShadow(
        string calldata chainNamespace,
        string calldata chainId,
        address registryAddress
    ) external;

    // ──────────────────────────────────────────────
    //  Reads — ERC-8004-shaped
    // ──────────────────────────────────────────────

    function ownerOf(uint256 agentId) external view returns (address);
    function tokenURI(uint256 agentId) external view returns (string memory);
    function agentURI(uint256 agentId) external view returns (string memory);

    // ──────────────────────────────────────────────
    //  Reads — UAIRegistry-specific
    // ──────────────────────────────────────────────

    function canonicalUEA(uint256 agentId) external view returns (address);
    function agentIdOfUEA(address uea) external view returns (uint256);
    function getShadows(
        uint256 agentId
    ) external view returns (ShadowEntry[] memory);
    function canonicalUEAFromShadow(
        string calldata chainNamespace,
        string calldata chainId,
        address registryAddress,
        uint256 shadowAgentId
    ) external view returns (address canonical, bool verified);
    function isRegistered(uint256 agentId) external view returns (bool);
    function getAgentRecord(
        uint256 agentId
    ) external view returns (AgentRecord memory);

    // ──────────────────────────────────────────────
    //  ERC-721 transfer surface — all revert
    // ──────────────────────────────────────────────

    function transferFrom(address from, address to, uint256 tokenId) external;
    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId
    ) external;
    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId,
        bytes calldata data
    ) external;
    function approve(address spender, uint256 tokenId) external;
    function setApprovalForAll(address operator, bool approved) external;
}
