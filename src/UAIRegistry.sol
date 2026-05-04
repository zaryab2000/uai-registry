// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    Initializable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    AccessControlUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {
    PausableUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {
    EIP712Upgradeable
} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {IUEAFactory} from "./interfaces/IUEAFactory.sol";
import {UniversalAccountId} from "./interfaces/Types.sol";
import {IUAIRegistry} from "./IUAIRegistry.sol";

/// @title UAIRegistry
/// @notice ERC-8004-compatible Universal Agent Identity Registry on Push Chain.
contract UAIRegistry is
    IUAIRegistry,
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    EIP712Upgradeable
{
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    uint256 public constant MAX_SHADOWS = 64;

    bytes32 public constant SHADOW_LINK_TYPEHASH = keccak256(
        "ShadowLink(address canonicalUEA,string chainNamespace,string chainId,"
        "address registryAddress,uint256 shadowAgentId,uint256 nonce,uint256 deadline)"
    );

    bytes4 private constant _ERC1271_MAGIC = 0x1626ba7e;

    IUEAFactory public immutable ueaFactory;

    // ──────────────────────────────────────────────
    //  ERC-7201 namespaced storage
    // ──────────────────────────────────────────────

    /// @custom:storage-location erc7201:uairegistry.storage
    struct UAIRegistryStorage {
        mapping(uint256 => AgentRecord) records;
        mapping(uint256 => ShadowEntry[]) shadows;
        mapping(bytes32 => uint256) shadowToCanonical;
        mapping(uint256 => mapping(bytes32 => uint256)) shadowIndex;
        mapping(uint256 => mapping(bytes32 => bool)) shadowExists;
        mapping(uint256 => mapping(uint256 => bool)) usedNonces;
    }

    // keccak256(abi.encode(uint256(keccak256("uairegistry.storage")) - 1))
    //   & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT =
        0x905dcd4200907b00346920cc0e535fe5a14b683886cfe304b73c74466969d200;

    function _getStorage() private pure returns (UAIRegistryStorage storage s) {
        bytes32 slot = STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }

    // ──────────────────────────────────────────────
    //  Constructor + Initializer
    // ──────────────────────────────────────────────

    constructor(IUEAFactory _ueaFactory) {
        ueaFactory = _ueaFactory;
        _disableInitializers();
    }

    function initialize(address admin, address pauser) external initializer {
        __AccessControl_init();
        __Pausable_init();
        __EIP712_init("UAIRegistry", "1");
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, pauser);
    }

    // ──────────────────────────────────────────────
    //  Registration
    // ──────────────────────────────────────────────

    function register(
        string calldata _agentURI,
        bytes32 agentCardHash
    ) external whenNotPaused returns (uint256 agentId) {
        if (agentCardHash == bytes32(0)) revert AgentCardHashRequired();

        agentId = uint256(uint160(msg.sender));
        UAIRegistryStorage storage s = _getStorage();
        AgentRecord storage record = s.records[agentId];

        if (record.registered) {
            record.agentURI = _agentURI;
            record.agentCardHash = agentCardHash;
        } else {
            (UniversalAccountId memory origin, bool isUEA) =
                ueaFactory.getOriginForUEA(msg.sender);

            record.registered = true;
            record.agentURI = _agentURI;
            record.agentCardHash = agentCardHash;
            record.registeredAt = uint64(block.timestamp);
            record.originChainNamespace = origin.chainNamespace;
            record.originChainId = origin.chainId;
            record.ownerKey = origin.owner;
            record.nativeToPush = !isUEA;

            emit Registered(
                agentId,
                msg.sender,
                origin.chainNamespace,
                origin.chainId,
                origin.owner,
                _agentURI,
                agentCardHash
            );
        }
    }

    function setAgentURI(
        string calldata newAgentURI
    ) external whenNotPaused {
        uint256 agentId = uint256(uint160(msg.sender));
        UAIRegistryStorage storage s = _getStorage();
        if (!s.records[agentId].registered) {
            revert AgentNotRegistered(agentId);
        }
        s.records[agentId].agentURI = newAgentURI;
        emit AgentURIUpdated(agentId, newAgentURI);
    }

    function setAgentCardHash(bytes32 newHash) external whenNotPaused {
        if (newHash == bytes32(0)) revert AgentCardHashRequired();
        uint256 agentId = uint256(uint160(msg.sender));
        UAIRegistryStorage storage s = _getStorage();
        if (!s.records[agentId].registered) {
            revert AgentNotRegistered(agentId);
        }
        s.records[agentId].agentCardHash = newHash;
        emit AgentCardHashUpdated(agentId, newHash);
    }

    // ──────────────────────────────────────────────
    //  Shadow Linking
    // ──────────────────────────────────────────────

    function linkShadow(
        ShadowLinkRequest calldata req
    ) external whenNotPaused {
        uint256 agentId = uint256(uint160(msg.sender));
        UAIRegistryStorage storage s = _getStorage();

        if (!s.records[agentId].registered) {
            revert AgentNotRegistered(agentId);
        }
        if (bytes(req.chainNamespace).length == 0 || bytes(req.chainId).length == 0) {
            revert InvalidChainIdentifier();
        }
        if (req.registryAddress == address(0)) {
            revert InvalidRegistryAddress();
        }
        if (req.deadline < block.timestamp) {
            revert ShadowLinkExpired(req.deadline);
        }
        if (s.usedNonces[agentId][req.nonce]) {
            revert ShadowLinkNonceUsed(req.nonce);
        }

        s.usedNonces[agentId][req.nonce] = true;

        bytes32 dedupKey = keccak256(
            abi.encode(
                req.chainNamespace,
                req.chainId,
                req.registryAddress,
                req.shadowAgentId
            )
        );
        if (s.shadowToCanonical[dedupKey] != 0) {
            revert ShadowAlreadyClaimed(
                req.chainNamespace,
                req.chainId,
                req.registryAddress,
                req.shadowAgentId
            );
        }
        if (s.shadows[agentId].length >= MAX_SHADOWS) {
            revert MaxShadowsExceeded(agentId);
        }

        bool verified = _verifyShadowSignature(msg.sender, req);
        if (!verified) revert InvalidShadowSignature();

        s.shadows[agentId].push(
            ShadowEntry({
                chainNamespace: req.chainNamespace,
                chainId: req.chainId,
                registryAddress: req.registryAddress,
                shadowAgentId: req.shadowAgentId,
                proofType: req.proofType,
                verified: true,
                linkedAt: uint64(block.timestamp)
            })
        );

        s.shadowToCanonical[dedupKey] = agentId;

        bytes32 chainKey = keccak256(
            abi.encode(req.chainNamespace, req.chainId, req.registryAddress)
        );
        s.shadowIndex[agentId][chainKey] = s.shadows[agentId].length - 1;
        s.shadowExists[agentId][chainKey] = true;

        emit ShadowLinked(
            agentId,
            req.chainNamespace,
            req.chainId,
            req.registryAddress,
            req.shadowAgentId,
            req.proofType,
            true
        );
    }

    function unlinkShadow(
        string calldata chainNamespace,
        string calldata chainId,
        address registryAddress
    ) external whenNotPaused {
        uint256 agentId = uint256(uint160(msg.sender));
        UAIRegistryStorage storage s = _getStorage();

        if (!s.records[agentId].registered) {
            revert AgentNotRegistered(agentId);
        }

        bytes32 chainKey = keccak256(
            abi.encode(chainNamespace, chainId, registryAddress)
        );
        if (!s.shadowExists[agentId][chainKey]) {
            revert ShadowNotFound(chainNamespace, chainId, registryAddress);
        }

        uint256 idx = s.shadowIndex[agentId][chainKey];
        ShadowEntry storage entry = s.shadows[agentId][idx];

        bytes32 dedupKey = keccak256(
            abi.encode(
                entry.chainNamespace,
                entry.chainId,
                entry.registryAddress,
                entry.shadowAgentId
            )
        );
        delete s.shadowToCanonical[dedupKey];

        uint256 lastIdx = s.shadows[agentId].length - 1;
        if (idx != lastIdx) {
            ShadowEntry storage lastEntry = s.shadows[agentId][lastIdx];
            s.shadows[agentId][idx] = lastEntry;

            bytes32 lastChainKey = keccak256(
                abi.encode(
                    lastEntry.chainNamespace,
                    lastEntry.chainId,
                    lastEntry.registryAddress
                )
            );
            s.shadowIndex[agentId][lastChainKey] = idx;
        }
        s.shadows[agentId].pop();

        delete s.shadowExists[agentId][chainKey];
        delete s.shadowIndex[agentId][chainKey];

        emit ShadowUnlinked(agentId, chainNamespace, chainId, registryAddress);
    }

    // ──────────────────────────────────────────────
    //  Reads — ERC-8004-shaped
    // ──────────────────────────────────────────────

    function ownerOf(uint256 agentId) external view returns (address) {
        if (!_getStorage().records[agentId].registered) {
            revert AgentNotRegistered(agentId);
        }
        return address(uint160(agentId));
    }

    function tokenURI(
        uint256 agentId
    ) external view returns (string memory) {
        UAIRegistryStorage storage s = _getStorage();
        if (!s.records[agentId].registered) {
            revert AgentNotRegistered(agentId);
        }
        return s.records[agentId].agentURI;
    }

    function agentURI(
        uint256 agentId
    ) external view returns (string memory) {
        UAIRegistryStorage storage s = _getStorage();
        if (!s.records[agentId].registered) {
            revert AgentNotRegistered(agentId);
        }
        return s.records[agentId].agentURI;
    }

    // ──────────────────────────────────────────────
    //  Reads — UAIRegistry-specific
    // ──────────────────────────────────────────────

    function canonicalUEA(uint256 agentId) external view returns (address) {
        if (!_getStorage().records[agentId].registered) {
            revert AgentNotRegistered(agentId);
        }
        return address(uint160(agentId));
    }

    function agentIdOfUEA(address uea) external view returns (uint256) {
        uint256 agentId = uint256(uint160(uea));
        if (!_getStorage().records[agentId].registered) return 0;
        return agentId;
    }

    function getShadows(
        uint256 agentId
    ) external view returns (ShadowEntry[] memory) {
        return _getStorage().shadows[agentId];
    }

    function canonicalUEAFromShadow(
        string calldata chainNamespace,
        string calldata chainId,
        address registryAddress,
        uint256 shadowAgentId
    ) external view returns (address canonical, bool verified) {
        UAIRegistryStorage storage s = _getStorage();
        bytes32 dedupKey = keccak256(
            abi.encode(chainNamespace, chainId, registryAddress, shadowAgentId)
        );
        uint256 agentId = s.shadowToCanonical[dedupKey];
        if (agentId == 0) return (address(0), false);

        bytes32 chainKey = keccak256(
            abi.encode(chainNamespace, chainId, registryAddress)
        );
        uint256 idx = s.shadowIndex[agentId][chainKey];
        return (address(uint160(agentId)), s.shadows[agentId][idx].verified);
    }

    function isRegistered(uint256 agentId) external view returns (bool) {
        return _getStorage().records[agentId].registered;
    }

    function getAgentRecord(
        uint256 agentId
    ) external view returns (AgentRecord memory) {
        return _getStorage().records[agentId];
    }

    // ──────────────────────────────────────────────
    //  ERC-721 transfer surface — all revert
    // ──────────────────────────────────────────────

    function transferFrom(address, address, uint256) external pure {
        revert IdentityNotTransferable();
    }

    function safeTransferFrom(address, address, uint256) external pure {
        revert IdentityNotTransferable();
    }

    function safeTransferFrom(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure {
        revert IdentityNotTransferable();
    }

    function approve(address, uint256) external pure {
        revert IdentityNotTransferable();
    }

    function setApprovalForAll(address, bool) external pure {
        revert IdentityNotTransferable();
    }

    // ──────────────────────────────────────────────
    //  ERC-165
    // ──────────────────────────────────────────────

    function supportsInterface(
        bytes4 interfaceId
    )
        public
        view
        override(AccessControlUpgradeable)
        returns (bool)
    {
        return interfaceId == type(IERC721).interfaceId
            || interfaceId == type(IERC165).interfaceId
            || super.supportsInterface(interfaceId);
    }

    // ──────────────────────────────────────────────
    //  Pause
    // ──────────────────────────────────────────────

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // ──────────────────────────────────────────────
    //  Internal
    // ──────────────────────────────────────────────

    function _verifyShadowSignature(
        address canonicalUEAAddr,
        ShadowLinkRequest calldata req
    ) internal view returns (bool) {
        bytes32 structHash = keccak256(
            abi.encode(
                SHADOW_LINK_TYPEHASH,
                canonicalUEAAddr,
                keccak256(bytes(req.chainNamespace)),
                keccak256(bytes(req.chainId)),
                req.registryAddress,
                req.shadowAgentId,
                req.nonce,
                req.deadline
            )
        );
        bytes32 digest = _hashTypedDataV4(structHash);

        (address recovered, ECDSA.RecoverError err,) =
            ECDSA.tryRecover(digest, req.proofData);

        if (err == ECDSA.RecoverError.NoError && recovered != address(0)) {
            return true;
        }

        if (req.proofData.length >= 20) {
            address signer = _extractSignerAddress(req.proofData);
            if (signer.code.length > 0) {
                try IERC1271(signer).isValidSignature{gas: 50_000}(
                    digest,
                    req.proofData[20:]
                ) returns (bytes4 magic) {
                    return magic == _ERC1271_MAGIC;
                } catch {
                    return false;
                }
            }
        }

        return false;
    }

    function _extractSignerAddress(
        bytes calldata data
    ) private pure returns (address signer) {
        signer = address(bytes20(data[:20]));
    }
}
