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
import {ITAPRegistry} from "./interfaces/ITAPRegistry.sol";
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
    MaxBindingsExceeded,
    AgentIdCollision
} from "./libraries/RegistryErrors.sol";

/// @title TAPRegistry
/// @notice ERC-8004-compatible Universal Agent Identity Registry on Push Chain.
contract TAPRegistry is
    ITAPRegistry,
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    EIP712Upgradeable
{
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    uint256 public constant MAX_BINDINGS = 64;

    bytes32 public constant BIND_TYPEHASH = keccak256(
        "Bind(address canonicalOwner,string chainNamespace,string chainId,"
        "address registryAddress,uint256 boundAgentId,uint256 nonce,uint256 deadline)"
    );

    bytes4 private constant _ERC1271_MAGIC = 0x1626ba7e;

    IUEAFactory public immutable ueaFactory;

    // ──────────────────────────────────────────────
    //  ERC-7201 namespaced storage
    // ──────────────────────────────────────────────

    /// @custom:storage-location erc7201:tap.registry.storage
    struct TAPRegistryStorage {
        mapping(uint256 => AgentRecord) records;
        mapping(uint256 => BindEntry[]) bindings;
        mapping(bytes32 => uint256) bindToCanonical; // stores agentId + 1; 0 = not bound
        mapping(uint256 => mapping(bytes32 => uint256)) bindIndex;
        mapping(uint256 => mapping(bytes32 => bool)) bindExists;
        mapping(uint256 => mapping(uint256 => bool)) usedNonces;
        mapping(address => uint256) ownerToAgentId; // stores agentId + 1; 0 = not registered
        mapping(bytes32 => uint256) ownerKeyToAgentId; // keccak256(ownerKey) → agentId + 1; 0 = not registered
    }

    // keccak256(abi.encode(uint256(keccak256("tap.registry.storage")) - 1))
    //   & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT =
        0x058d5531a4d48d6b2756a26de7bf5dc8cee5997c802aa85f245da9412ca74a00;

    function _getStorage() private pure returns (TAPRegistryStorage storage s) {
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
        __EIP712_init("TAP", "1");
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, pauser);
    }

    // ──────────────────────────────────────────────
    //  Registration
    // ──────────────────────────────────────────────

    /// @inheritdoc ITAPRegistry
    function register(
        string calldata _agentURI,
        bytes32 agentCardHash
    ) external whenNotPaused returns (uint256 agentId) {
        if (agentCardHash == bytes32(0)) revert AgentCardHashRequired();

        TAPRegistryStorage storage s = _getStorage();
        uint256 raw = s.ownerToAgentId[msg.sender];

        if (raw != 0) {
            agentId = raw - 1;
            _updateRecord(s, agentId, _agentURI, agentCardHash);
        } else {
            agentId = _registerNewOrAlias(s, _agentURI, agentCardHash);
        }
    }

    function _updateRecord(
        TAPRegistryStorage storage s,
        uint256 agentId,
        string calldata _agentURI,
        bytes32 agentCardHash
    ) private {
        AgentRecord storage record = s.records[agentId];
        record.agentURI = _agentURI;
        record.agentCardHash = agentCardHash;
        emit AgentURIUpdated(agentId, _agentURI);
        emit AgentCardHashUpdated(agentId, agentCardHash);
    }

    function _registerNewOrAlias(
        TAPRegistryStorage storage s,
        string calldata _agentURI,
        bytes32 agentCardHash
    ) private returns (uint256 agentId) {
        (UniversalAccountId memory origin, bool isUEA) = ueaFactory.getOriginForUEA(msg.sender);
        bytes32 ownerHash = keccak256(origin.owner);

        uint256 ownerRaw = s.ownerKeyToAgentId[ownerHash];
        if (ownerRaw != 0) {
            agentId = ownerRaw - 1;
            s.ownerToAgentId[msg.sender] = agentId + 1;
            _updateRecord(s, agentId, _agentURI, agentCardHash);
            return agentId;
        }

        agentId = uint256(uint160(msg.sender)) % 10_000_000;
        if (agentId == 0) agentId = 10_000_000;
        if (s.records[agentId].registered) {
            revert AgentIdCollision(agentId, _ownerKeyToAddress(s.records[agentId].ownerKey));
        }

        AgentRecord storage record = s.records[agentId];
        record.registered = true;
        record.agentURI = _agentURI;
        record.agentCardHash = agentCardHash;
        record.registeredAt = uint64(block.timestamp);
        record.originChainNamespace = origin.chainNamespace;
        record.originChainId = origin.chainId;
        record.ownerKey = origin.owner;
        record.nativeToPush = !isUEA;

        s.ownerToAgentId[msg.sender] = agentId + 1;
        s.ownerKeyToAgentId[ownerHash] = agentId + 1;

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

    /// @inheritdoc ITAPRegistry
    function setAgentURI(
        string calldata newAgentURI
    ) external whenNotPaused {
        TAPRegistryStorage storage s = _getStorage();
        uint256 raw = s.ownerToAgentId[msg.sender];
        if (raw == 0) revert AgentNotRegistered(uint256(uint160(msg.sender)) % 10_000_000);
        uint256 agentId = raw - 1;
        s.records[agentId].agentURI = newAgentURI;
        emit AgentURIUpdated(agentId, newAgentURI);
    }

    /// @inheritdoc ITAPRegistry
    function setAgentCardHash(
        bytes32 newHash
    ) external whenNotPaused {
        if (newHash == bytes32(0)) revert AgentCardHashRequired();
        TAPRegistryStorage storage s = _getStorage();
        uint256 raw = s.ownerToAgentId[msg.sender];
        if (raw == 0) revert AgentNotRegistered(uint256(uint160(msg.sender)) % 10_000_000);
        uint256 agentId = raw - 1;
        s.records[agentId].agentCardHash = newHash;
        emit AgentCardHashUpdated(agentId, newHash);
    }

    // ──────────────────────────────────────────────
    //  Binding
    // ──────────────────────────────────────────────

    /// @inheritdoc ITAPRegistry
    function bind(
        BindRequest calldata req
    ) external whenNotPaused {
        TAPRegistryStorage storage s = _getStorage();
        uint256 raw = s.ownerToAgentId[msg.sender];
        if (raw == 0) revert AgentNotRegistered(uint256(uint160(msg.sender)) % 10_000_000);
        uint256 agentId = raw - 1;
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

        s.bindToCanonical[dedupKey] = agentId + 1;

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

    /// @inheritdoc ITAPRegistry
    function unbind(
        string calldata chainNamespace,
        string calldata chainId,
        address registryAddress
    ) external whenNotPaused {
        TAPRegistryStorage storage s = _getStorage();
        uint256 raw = s.ownerToAgentId[msg.sender];
        if (raw == 0) revert AgentNotRegistered(uint256(uint160(msg.sender)) % 10_000_000);
        uint256 agentId = raw - 1;

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

    /// @inheritdoc ITAPRegistry
    function ownerOf(
        uint256 agentId
    ) external view returns (address) {
        TAPRegistryStorage storage s = _getStorage();
        if (!s.records[agentId].registered) revert AgentNotRegistered(agentId);
        return _ownerKeyToAddress(s.records[agentId].ownerKey);
    }

    /// @inheritdoc ITAPRegistry
    function tokenURI(
        uint256 agentId
    ) external view returns (string memory) {
        TAPRegistryStorage storage s = _getStorage();
        if (!s.records[agentId].registered) {
            revert AgentNotRegistered(agentId);
        }
        return s.records[agentId].agentURI;
    }

    /// @inheritdoc ITAPRegistry
    function agentURI(
        uint256 agentId
    ) external view returns (string memory) {
        TAPRegistryStorage storage s = _getStorage();
        if (!s.records[agentId].registered) {
            revert AgentNotRegistered(agentId);
        }
        return s.records[agentId].agentURI;
    }

    // ──────────────────────────────────────────────
    //  Reads — TAPRegistry-specific
    // ──────────────────────────────────────────────

    /// @inheritdoc ITAPRegistry
    function canonicalOwner(
        uint256 agentId
    ) external view returns (address) {
        TAPRegistryStorage storage s = _getStorage();
        if (!s.records[agentId].registered) revert AgentNotRegistered(agentId);
        return _ownerKeyToAddress(s.records[agentId].ownerKey);
    }

    /// @inheritdoc ITAPRegistry
    function agentIdOfUEA(
        address uea
    ) external view returns (uint256) {
        uint256 raw = _getStorage().ownerToAgentId[uea];
        if (raw == 0) return 0;
        return raw - 1;
    }

    /// @inheritdoc ITAPRegistry
    function getBindings(
        uint256 agentId
    ) external view returns (BindEntry[] memory) {
        return _getStorage().bindings[agentId];
    }

    /// @inheritdoc ITAPRegistry
    function canonicalOwnerFromBinding(
        string calldata chainNamespace,
        string calldata chainId,
        address registryAddress,
        uint256 boundAgentId
    ) external view returns (address canonical, bool verified) {
        TAPRegistryStorage storage s = _getStorage();
        bytes32 dedupKey =
            keccak256(abi.encode(chainNamespace, chainId, registryAddress, boundAgentId));
        uint256 stored = s.bindToCanonical[dedupKey];
        if (stored == 0) return (address(0), false);

        uint256 agentId = stored - 1;
        bytes32 chainKey = keccak256(abi.encode(chainNamespace, chainId, registryAddress));
        uint256 idx = s.bindIndex[agentId][chainKey];
        return (_ownerKeyToAddress(s.records[agentId].ownerKey), s.bindings[agentId][idx].verified);
    }

    /// @inheritdoc ITAPRegistry
    function isRegistered(
        uint256 agentId
    ) external view returns (bool) {
        return _getStorage().records[agentId].registered;
    }

    /// @inheritdoc ITAPRegistry
    function getAgentRecord(
        uint256 agentId
    ) external view returns (AgentRecord memory) {
        return _getStorage().records[agentId];
    }

    // ──────────────────────────────────────────────
    //  ERC-721 transfer surface — all revert
    // ──────────────────────────────────────────────

    /// @inheritdoc ITAPRegistry
    function transferFrom(
        address,
        address,
        uint256
    ) external pure {
        revert IdentityNotTransferable();
    }

    /// @inheritdoc ITAPRegistry
    function safeTransferFrom(
        address,
        address,
        uint256
    ) external pure {
        revert IdentityNotTransferable();
    }

    /// @inheritdoc ITAPRegistry
    function safeTransferFrom(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure {
        revert IdentityNotTransferable();
    }

    /// @inheritdoc ITAPRegistry
    function approve(
        address,
        uint256
    ) external pure {
        revert IdentityNotTransferable();
    }

    /// @inheritdoc ITAPRegistry
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
        address callerAddr,
        BindRequest calldata req
    ) internal view returns (bool) {
        bytes32 structHash = keccak256(
            abi.encode(
                BIND_TYPEHASH,
                callerAddr,
                keccak256(bytes(req.chainNamespace)),
                keccak256(bytes(req.chainId)),
                req.registryAddress,
                req.boundAgentId,
                req.nonce,
                req.deadline
            )
        );
        bytes32 digest = _hashTypedDataV4(structHash);

        TAPRegistryStorage storage s = _getStorage();
        uint256 raw = s.ownerToAgentId[callerAddr];
        if (raw == 0) revert AgentNotRegistered(uint256(uint160(callerAddr)) % 10_000_000);
        uint256 agentId = raw - 1;
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
