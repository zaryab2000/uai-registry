// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
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
import {UniversalAccountId} from "./libraries/Types.sol";
import {IAgentRegistry} from "./interfaces/IAgentRegistry.sol";
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
} from "./libraries/Errors.sol";

/// @title AgentRegistry
/// @notice ERC-8004-compatible Universal Agent Identity Registry on Push Chain.
contract AgentRegistry is
    IAgentRegistry,
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    EIP712Upgradeable
{
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    uint256 public constant MAX_BINDINGS = 64;

    bytes32 public constant BIND_TYPEHASH = keccak256(
        "Bind(address canonicalUEA,string chainNamespace,string chainId,"
        "address registryAddress,uint256 boundAgentId,uint256 nonce,uint256 deadline)"
    );

    bytes4 private constant _ERC1271_MAGIC = 0x1626ba7e;

    IUEAFactory public immutable ueaFactory;

    // ──────────────────────────────────────────────
    //  ERC-7201 namespaced storage
    // ──────────────────────────────────────────────

    /// @custom:storage-location erc7201:agentgraph.registry.storage
    struct AgentRegistryStorage {
        mapping(uint256 => AgentRecord) records;
        mapping(uint256 => BindEntry[]) bindings;
        mapping(bytes32 => uint256) bindToCanonical;
        mapping(uint256 => mapping(bytes32 => uint256)) bindIndex;
        mapping(uint256 => mapping(bytes32 => bool)) bindExists;
        mapping(uint256 => mapping(uint256 => bool)) usedNonces;
    }

    // keccak256(abi.encode(uint256(keccak256("agentgraph.registry.storage")) - 1))
    //   & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT =
        0xf37f1d7c5752967bda44eaab6131ed8a290372309eed64688fb601f4ced83600;

    function _getStorage() private pure returns (AgentRegistryStorage storage s) {
        bytes32 slot = STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }

    // ──────────────────────────────────────────────
    //  Constructor + Initializer
    // ──────────────────────────────────────────────

    constructor(
        IUEAFactory _ueaFactory
    ) {
        ueaFactory = _ueaFactory;
        _disableInitializers();
    }

    function initialize(
        address admin,
        address pauser
    ) external initializer {
        __AccessControl_init();
        __Pausable_init();
        __EIP712_init("AgentGraph", "1");
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, pauser);
    }

    // ──────────────────────────────────────────────
    //  Registration
    // ──────────────────────────────────────────────

    /// @inheritdoc IAgentRegistry
    function register(
        string calldata _agentURI,
        bytes32 agentCardHash
    ) external whenNotPaused returns (uint256 agentId) {
        if (agentCardHash == bytes32(0)) revert AgentCardHashRequired();

        agentId = uint256(uint160(msg.sender));
        AgentRegistryStorage storage s = _getStorage();
        AgentRecord storage record = s.records[agentId];

        if (record.registered) {
            record.agentURI = _agentURI;
            record.agentCardHash = agentCardHash;
            emit AgentURIUpdated(agentId, _agentURI);
            emit AgentCardHashUpdated(agentId, agentCardHash);
        } else {
            (UniversalAccountId memory origin, bool isUEA) = ueaFactory.getOriginForUEA(msg.sender);

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

    /// @inheritdoc IAgentRegistry
    function setAgentURI(
        string calldata newAgentURI
    ) external whenNotPaused {
        uint256 agentId = uint256(uint160(msg.sender));
        AgentRegistryStorage storage s = _getStorage();
        if (!s.records[agentId].registered) {
            revert AgentNotRegistered(agentId);
        }
        s.records[agentId].agentURI = newAgentURI;
        emit AgentURIUpdated(agentId, newAgentURI);
    }

    /// @inheritdoc IAgentRegistry
    function setAgentCardHash(
        bytes32 newHash
    ) external whenNotPaused {
        if (newHash == bytes32(0)) revert AgentCardHashRequired();
        uint256 agentId = uint256(uint160(msg.sender));
        AgentRegistryStorage storage s = _getStorage();
        if (!s.records[agentId].registered) {
            revert AgentNotRegistered(agentId);
        }
        s.records[agentId].agentCardHash = newHash;
        emit AgentCardHashUpdated(agentId, newHash);
    }

    // ──────────────────────────────────────────────
    //  Binding
    // ──────────────────────────────────────────────

    /// @inheritdoc IAgentRegistry
    function bind(
        BindRequest calldata req
    ) external whenNotPaused {
        uint256 agentId = uint256(uint160(msg.sender));
        AgentRegistryStorage storage s = _getStorage();

        if (!s.records[agentId].registered) {
            revert AgentNotRegistered(agentId);
        }
        if (bytes(req.chainNamespace).length == 0 || bytes(req.chainId).length == 0) {
            revert InvalidChainIdentifier();
        }
        if (req.registryAddress == address(0)) {
            revert InvalidRegistryAddress();
        }
        if (req.proofType != BindProofType.OWNER_KEY_SIGNED) {
            revert UnsupportedProofType();
        }
        if (req.deadline < block.timestamp) {
            revert BindExpired(req.deadline);
        }
        if (s.usedNonces[agentId][req.nonce]) {
            revert BindNonceUsed(req.nonce);
        }

        s.usedNonces[agentId][req.nonce] = true;

        bytes32 dedupKey = keccak256(
            abi.encode(req.chainNamespace, req.chainId, req.registryAddress, req.boundAgentId)
        );
        if (s.bindToCanonical[dedupKey] != 0) {
            revert BindingAlreadyClaimed(
                req.chainNamespace, req.chainId, req.registryAddress, req.boundAgentId
            );
        }
        if (s.bindings[agentId].length >= MAX_BINDINGS) {
            revert MaxBindingsExceeded(agentId);
        }

        bool verified = _verifyBindSignature(msg.sender, req);
        if (!verified) revert InvalidBindSignature();

        s.bindings[agentId].push(
            BindEntry({
                chainNamespace: req.chainNamespace,
                chainId: req.chainId,
                registryAddress: req.registryAddress,
                boundAgentId: req.boundAgentId,
                proofType: req.proofType,
                verified: true,
                linkedAt: uint64(block.timestamp)
            })
        );

        s.bindToCanonical[dedupKey] = agentId;

        bytes32 chainKey =
            keccak256(abi.encode(req.chainNamespace, req.chainId, req.registryAddress));
        s.bindIndex[agentId][chainKey] = s.bindings[agentId].length - 1;
        s.bindExists[agentId][chainKey] = true;

        emit AgentBound(
            agentId,
            req.chainNamespace,
            req.chainId,
            req.registryAddress,
            req.boundAgentId,
            req.proofType,
            true
        );
    }

    /// @inheritdoc IAgentRegistry
    function unbind(
        string calldata chainNamespace,
        string calldata chainId,
        address registryAddress
    ) external whenNotPaused {
        uint256 agentId = uint256(uint160(msg.sender));
        AgentRegistryStorage storage s = _getStorage();

        if (!s.records[agentId].registered) {
            revert AgentNotRegistered(agentId);
        }

        bytes32 chainKey = keccak256(abi.encode(chainNamespace, chainId, registryAddress));
        if (!s.bindExists[agentId][chainKey]) {
            revert BindingNotFound(chainNamespace, chainId, registryAddress);
        }

        uint256 idx = s.bindIndex[agentId][chainKey];
        BindEntry storage entry = s.bindings[agentId][idx];

        bytes32 dedupKey = keccak256(
            abi.encode(
                entry.chainNamespace, entry.chainId, entry.registryAddress, entry.boundAgentId
            )
        );
        delete s.bindToCanonical[dedupKey];

        uint256 lastIdx = s.bindings[agentId].length - 1;
        if (idx != lastIdx) {
            BindEntry storage lastEntry = s.bindings[agentId][lastIdx];
            s.bindings[agentId][idx] = lastEntry;

            bytes32 lastChainKey = keccak256(
                abi.encode(lastEntry.chainNamespace, lastEntry.chainId, lastEntry.registryAddress)
            );
            s.bindIndex[agentId][lastChainKey] = idx;
        }
        s.bindings[agentId].pop();

        delete s.bindExists[agentId][chainKey];
        delete s.bindIndex[agentId][chainKey];

        emit AgentUnbound(agentId, chainNamespace, chainId, registryAddress);
    }

    // ──────────────────────────────────────────────
    //  Reads — ERC-8004-shaped
    // ──────────────────────────────────────────────

    /// @inheritdoc IAgentRegistry
    function ownerOf(
        uint256 agentId
    ) external view returns (address) {
        if (!_getStorage().records[agentId].registered) {
            revert AgentNotRegistered(agentId);
        }
        return address(uint160(agentId));
    }

    /// @inheritdoc IAgentRegistry
    function tokenURI(
        uint256 agentId
    ) external view returns (string memory) {
        AgentRegistryStorage storage s = _getStorage();
        if (!s.records[agentId].registered) {
            revert AgentNotRegistered(agentId);
        }
        return s.records[agentId].agentURI;
    }

    /// @inheritdoc IAgentRegistry
    function agentURI(
        uint256 agentId
    ) external view returns (string memory) {
        AgentRegistryStorage storage s = _getStorage();
        if (!s.records[agentId].registered) {
            revert AgentNotRegistered(agentId);
        }
        return s.records[agentId].agentURI;
    }

    // ──────────────────────────────────────────────
    //  Reads — AgentRegistry-specific
    // ──────────────────────────────────────────────

    /// @inheritdoc IAgentRegistry
    function canonicalUEA(
        uint256 agentId
    ) external view returns (address) {
        if (!_getStorage().records[agentId].registered) {
            revert AgentNotRegistered(agentId);
        }
        return address(uint160(agentId));
    }

    /// @inheritdoc IAgentRegistry
    function agentIdOfUEA(
        address uea
    ) external view returns (uint256) {
        uint256 agentId = uint256(uint160(uea));
        if (!_getStorage().records[agentId].registered) return 0;
        return agentId;
    }

    /// @inheritdoc IAgentRegistry
    function getBindings(
        uint256 agentId
    ) external view returns (BindEntry[] memory) {
        return _getStorage().bindings[agentId];
    }

    /// @inheritdoc IAgentRegistry
    function canonicalUEAFromBinding(
        string calldata chainNamespace,
        string calldata chainId,
        address registryAddress,
        uint256 boundAgentId
    ) external view returns (address canonical, bool verified) {
        AgentRegistryStorage storage s = _getStorage();
        bytes32 dedupKey =
            keccak256(abi.encode(chainNamespace, chainId, registryAddress, boundAgentId));
        uint256 agentId = s.bindToCanonical[dedupKey];
        if (agentId == 0) return (address(0), false);

        bytes32 chainKey = keccak256(abi.encode(chainNamespace, chainId, registryAddress));
        uint256 idx = s.bindIndex[agentId][chainKey];
        return (address(uint160(agentId)), s.bindings[agentId][idx].verified);
    }

    /// @inheritdoc IAgentRegistry
    function isRegistered(
        uint256 agentId
    ) external view returns (bool) {
        return _getStorage().records[agentId].registered;
    }

    /// @inheritdoc IAgentRegistry
    function getAgentRecord(
        uint256 agentId
    ) external view returns (AgentRecord memory) {
        return _getStorage().records[agentId];
    }

    // ──────────────────────────────────────────────
    //  ERC-721 transfer surface — all revert
    // ──────────────────────────────────────────────

    /// @inheritdoc IAgentRegistry
    function transferFrom(
        address,
        address,
        uint256
    ) external pure {
        revert IdentityNotTransferable();
    }

    /// @inheritdoc IAgentRegistry
    function safeTransferFrom(
        address,
        address,
        uint256
    ) external pure {
        revert IdentityNotTransferable();
    }

    /// @inheritdoc IAgentRegistry
    function safeTransferFrom(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure {
        revert IdentityNotTransferable();
    }

    /// @inheritdoc IAgentRegistry
    function approve(
        address,
        uint256
    ) external pure {
        revert IdentityNotTransferable();
    }

    /// @inheritdoc IAgentRegistry
    function setApprovalForAll(
        address,
        bool
    ) external pure {
        revert IdentityNotTransferable();
    }

    // ──────────────────────────────────────────────
    //  ERC-165
    // ──────────────────────────────────────────────

    function supportsInterface(
        bytes4 interfaceId
    ) public view override(AccessControlUpgradeable) returns (bool) {
        return interfaceId == type(IERC721).interfaceId || interfaceId == type(IERC165).interfaceId
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

    function _verifyBindSignature(
        address canonicalUEAAddr,
        BindRequest calldata req
    ) internal view returns (bool) {
        bytes32 structHash = keccak256(
            abi.encode(
                BIND_TYPEHASH,
                canonicalUEAAddr,
                keccak256(bytes(req.chainNamespace)),
                keccak256(bytes(req.chainId)),
                req.registryAddress,
                req.boundAgentId,
                req.nonce,
                req.deadline
            )
        );
        bytes32 digest = _hashTypedDataV4(structHash);

        AgentRegistryStorage storage s = _getStorage();
        uint256 agentId = uint256(uint160(canonicalUEAAddr));
        address expectedSigner = _ownerKeyToAddress(s.records[agentId].ownerKey);

        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, req.proofData);

        if (err == ECDSA.RecoverError.NoError && recovered == expectedSigner) {
            return true;
        }

        if (req.proofData.length >= 20) {
            address signer = _extractSignerAddress(req.proofData);
            if (signer == expectedSigner && signer.code.length > 0) {
                try IERC1271(signer).isValidSignature{gas: 50_000}(
                    digest, req.proofData[20:]
                ) returns (
                    bytes4 magic
                ) {
                    return magic == _ERC1271_MAGIC;
                } catch {
                    return false;
                }
            }
        }

        return false;
    }

    function _ownerKeyToAddress(
        bytes storage ownerKey
    ) private view returns (address) {
        if (ownerKey.length < 20) return address(0);
        return address(bytes20(ownerKey));
    }

    function _extractSignerAddress(
        bytes calldata data
    ) private pure returns (address signer) {
        signer = address(bytes20(data[:20]));
    }
}
