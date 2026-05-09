// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {OwnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Initializable} from
    "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from
    "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IGatewayAdapter} from "./IGatewayAdapter.sol";
import {
    InvalidGatewayAdapter,
    InvalidSettlementRegistry,
    PropagationDisabled,
    AlreadySynced,
    NotAgentOwner,
    InvalidUEARecipient
} from "./SourceErrors.sol";

/// @notice Minimal view into the per-chain ERC-8004 IdentityRegistry.
interface IIdentityRegistryLocal {
    function register(
        string memory agentURI
    ) external returns (uint256 agentId);

    function ownerOf(
        uint256 agentId
    ) external view returns (address);

    function tokenURI(
        uint256 agentId
    ) external view returns (string memory);
}

/// @title IdentityRegistryPlus
/// @notice ERC-8004+ source-chain wrapper that registers agents locally
///         via the existing ERC-8004 IdentityRegistry and propagates
///         the registration to Push Chain's UAIRegistry via the
///         Universal Gateway.
/// @dev Deployed as a UUPS-upgradeable proxy alongside the existing
///      IdentityRegistry. Does NOT inherit from IdentityRegistryUpgradeable
///      because register() is non-virtual in the base contract.
///      Instead, this contract calls the existing registry via composition.
contract IdentityRegistryPlus is
    Initializable,
    OwnableUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    // ──────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────

    event CrossChainRegistrationSent(
        uint256 indexed agentId,
        address indexed owner,
        address indexed ueaRecipient
    );

    event GatewayAdapterUpdated(address indexed adapter);
    event SettlementRegistryUpdated(address indexed registry);
    event LocalRegistryUpdated(address indexed registry);
    event PropagationToggled(bool enabled);

    // ──────────────────────────────────────────────
    //  Storage
    // ──────────────────────────────────────────────

    /// @custom:storage-location erc7201:erc8004plus.identity.source
    struct IdentityPlusStorage {
        address gatewayAdapter;
        address settlementRegistry;
        address localRegistry;
        bool propagationEnabled;
        mapping(uint256 => bool) crossChainSynced;
        mapping(uint256 => address) agentOwners;
    }

    // keccak256(abi.encode(uint256(keccak256(
    //   "erc8004plus.identity.source")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT =
        0xf1c674ba209da31c146f52c6580f1c703ebb76997a6a13510c04efc0533a1200;

    function _getStorage()
        private
        pure
        returns (IdentityPlusStorage storage s)
    {
        bytes32 slot = STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }

    // ──────────────────────────────────────────────
    //  Constructor + Initializer
    // ──────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the IdentityRegistryPlus proxy.
    /// @param owner_ Admin address.
    /// @param localRegistry_ Existing ERC-8004 IdentityRegistry on this chain.
    /// @param gatewayAdapter_ PushGatewayAdapter address.
    /// @param settlementRegistry_ UAIRegistry address on Push Chain.
    function initialize(
        address owner_,
        address localRegistry_,
        address gatewayAdapter_,
        address settlementRegistry_
    ) external initializer {
        if (gatewayAdapter_ == address(0)) {
            revert InvalidGatewayAdapter();
        }
        if (settlementRegistry_ == address(0)) {
            revert InvalidSettlementRegistry();
        }
        require(localRegistry_ != address(0), "zero local registry");

        __Ownable_init(owner_);
        __Pausable_init();
        __UUPSUpgradeable_init();

        IdentityPlusStorage storage s = _getStorage();
        s.gatewayAdapter = gatewayAdapter_;
        s.settlementRegistry = settlementRegistry_;
        s.localRegistry = localRegistry_;
        s.propagationEnabled = false;
    }

    // ──────────────────────────────────────────────
    //  Registration
    // ──────────────────────────────────────────────

    /// @notice Register an agent locally and propagate to Push Chain.
    /// @dev Calls the existing ERC-8004 IdentityRegistry.register() for
    ///      local registration, then sends a cross-chain payload via the
    ///      gateway adapter. User must send msg.value to cover gateway fees.
    /// @param agentURI Agent Registration File URI.
    /// @param ueaRecipient Caller's UEA address on Push Chain.
    /// @param signatureData UEA signature for Push Chain execution.
    /// @return agentId The local agent ID from ERC-8004.
    function register(
        string calldata agentURI,
        address ueaRecipient,
        bytes calldata signatureData
    ) external payable whenNotPaused returns (uint256 agentId) {
        IdentityPlusStorage storage s = _getStorage();

        agentId = IIdentityRegistryLocal(s.localRegistry)
            .register(agentURI);
        s.agentOwners[agentId] = msg.sender;

        if (s.propagationEnabled) {
            if (ueaRecipient == address(0)) {
                revert InvalidUEARecipient();
            }
            _propagateRegistration(
                agentId,
                agentURI,
                ueaRecipient,
                signatureData
            );
        }
    }

    /// @notice Register locally without cross-chain propagation.
    /// @dev Convenience function that delegates to the existing registry.
    /// @param agentURI Agent Registration File URI.
    /// @return agentId The local agent ID.
    function registerLocalOnly(
        string calldata agentURI
    ) external whenNotPaused returns (uint256 agentId) {
        IdentityPlusStorage storage s = _getStorage();
        agentId = IIdentityRegistryLocal(s.localRegistry)
            .register(agentURI);
        s.agentOwners[agentId] = msg.sender;
    }

    /// @notice Retry cross-chain propagation for a previously registered agent.
    /// @param agentId The local agent ID to retry.
    /// @param ueaRecipient Caller's UEA address on Push Chain.
    /// @param signatureData UEA signature for Push Chain execution.
    function retryPropagation(
        uint256 agentId,
        address ueaRecipient,
        bytes calldata signatureData
    ) external payable {
        IdentityPlusStorage storage s = _getStorage();
        if (!s.propagationEnabled) revert PropagationDisabled();

        if (s.agentOwners[agentId] != msg.sender) {
            revert NotAgentOwner(agentId);
        }
        if (s.crossChainSynced[agentId]) {
            revert AlreadySynced(agentId);
        }
        if (ueaRecipient == address(0)) {
            revert InvalidUEARecipient();
        }

        string memory agentURI = IIdentityRegistryLocal(s.localRegistry)
            .tokenURI(agentId);
        _propagateRegistration(
            agentId, agentURI, ueaRecipient, signatureData
        );
    }

    // ──────────────────────────────────────────────
    //  Internal
    // ──────────────────────────────────────────────

    function _propagateRegistration(
        uint256 agentId,
        string memory agentURI,
        address ueaRecipient,
        bytes calldata signatureData
    ) internal {
        IdentityPlusStorage storage s = _getStorage();

        bytes32 agentCardHash = keccak256(bytes(agentURI));

        // Encode UAIRegistry.register(agentURI, agentCardHash)
        bytes memory registerCalldata = abi.encodeWithSignature(
            "register(string,bytes32)",
            agentURI,
            agentCardHash
        );

        // Wrap in UniversalPayload targeting settlement registry
        bytes memory payload = abi.encode(
            s.settlementRegistry,
            registerCalldata
        );

        IGatewayAdapter(s.gatewayAdapter).sendPayload{value: msg.value}(
            ueaRecipient,
            payload,
            signatureData,
            msg.sender
        );

        s.crossChainSynced[agentId] = true;

        emit CrossChainRegistrationSent(
            agentId, msg.sender, ueaRecipient
        );
    }

    // ──────────────────────────────────────────────
    //  Read Functions
    // ──────────────────────────────────────────────

    /// @notice Check if an agent has been synced to settlement chain.
    function isCrossChainSynced(
        uint256 agentId
    ) external view returns (bool) {
        return _getStorage().crossChainSynced[agentId];
    }

    /// @notice Get the gateway adapter address.
    function gatewayAdapter() external view returns (address) {
        return _getStorage().gatewayAdapter;
    }

    /// @notice Get the settlement registry address.
    function settlementRegistry() external view returns (address) {
        return _getStorage().settlementRegistry;
    }

    /// @notice Get the local ERC-8004 registry address.
    function localRegistry() external view returns (address) {
        return _getStorage().localRegistry;
    }

    /// @notice Check if propagation is enabled.
    function propagationEnabled() external view returns (bool) {
        return _getStorage().propagationEnabled;
    }

    /// @notice Estimate the gateway fee for a cross-chain registration.
    function estimateRegistrationFee()
        external
        view
        returns (uint256)
    {
        return IGatewayAdapter(_getStorage().gatewayAdapter)
            .estimateFee();
    }

    // ──────────────────────────────────────────────
    //  Admin
    // ──────────────────────────────────────────────

    function setGatewayAdapter(
        address adapter
    ) external onlyOwner {
        if (adapter == address(0)) revert InvalidGatewayAdapter();
        _getStorage().gatewayAdapter = adapter;
        emit GatewayAdapterUpdated(adapter);
    }

    function setSettlementRegistry(
        address registry
    ) external onlyOwner {
        if (registry == address(0)) {
            revert InvalidSettlementRegistry();
        }
        _getStorage().settlementRegistry = registry;
        emit SettlementRegistryUpdated(registry);
    }

    function setLocalRegistry(
        address registry
    ) external onlyOwner {
        require(registry != address(0), "zero local registry");
        _getStorage().localRegistry = registry;
        emit LocalRegistryUpdated(registry);
    }

    function setPropagationEnabled(bool enabled) external onlyOwner {
        _getStorage().propagationEnabled = enabled;
        emit PropagationToggled(enabled);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function _authorizeUpgrade(
        address
    ) internal override onlyOwner {}
}
