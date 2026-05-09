// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {
    PausableUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IGatewayAdapter} from "./IGatewayAdapter.sol";
import {
    InvalidGatewayAdapter,
    InvalidSettlementRegistry,
    PropagationDisabled,
    InvalidBatchThreshold
} from "./SourceErrors.sol";

/// @notice Minimal view into the per-chain ERC-8004 ReputationRegistry.
interface IReputationRegistryLocal {
    function giveFeedback(
        uint256 agentId,
        int128 value,
        uint8 valueDecimals,
        string calldata tag1,
        string calldata tag2,
        string calldata endpoint,
        string calldata feedbackURI,
        bytes32 feedbackHash
    ) external;

    function getSummary(
        uint256 agentId,
        address[] calldata clientAddresses,
        string calldata tag1,
        string calldata tag2
    ) external view returns (uint64 count, int128 summaryValue, uint8 summaryValueDecimals);

    function getClients(
        uint256 agentId
    ) external view returns (address[] memory);
}

/// @title ReputationRegistrySource
/// @notice ERC-8004+ source-chain wrapper that submits feedback locally
///         via the existing ERC-8004 ReputationRegistry and propagates
///         reputation snapshots to Push Chain's ReputationRegistry via
///         the Universal Gateway.
/// @dev Uses composition (not inheritance) because giveFeedback() is
///      non-virtual in the base contract.
///      Reputation propagation is batched: snapshots are sent after
///      batchThreshold feedbacks or maxPropagationInterval elapsed.
contract ReputationRegistrySource is
    Initializable,
    OwnableUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    // ──────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────

    event ReputationPropagated(
        uint256 indexed agentId,
        uint64 feedbackCount,
        int128 summaryValue,
        uint256 sourceBlockNumber
    );

    event GatewayAdapterUpdated(address indexed adapter);
    event SettlementRegistryUpdated(address indexed registry);
    event LocalRegistryUpdated(address indexed registry);
    event PropagationToggled(bool enabled);
    event BatchThresholdUpdated(uint64 threshold);
    event MaxPropagationIntervalUpdated(uint64 interval);

    // ──────────────────────────────────────────────
    //  Storage
    // ──────────────────────────────────────────────

    /// @custom:storage-location erc7201:agentgraph.reputation.source
    struct ReputationSourceStorage {
        address gatewayAdapter;
        address settlementRegistry;
        address localRegistry;
        bool propagationEnabled;
        uint64 batchThreshold;
        uint64 maxPropagationInterval;
        mapping(uint256 => uint64) pendingFeedbackCount;
        mapping(uint256 => uint64) lastPropagated;
        /// @dev agentId → canonical agent ID on Push Chain.
        ///      Set by the owner after cross-chain identity is established.
        mapping(uint256 => uint256) canonicalIds;
    }

    // keccak256(abi.encode(uint256(keccak256(
    //   "agentgraph.reputation.source")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT =
        0x48b3ed8006293b84cc75560b8f9b061cac45710afcdefb3feba9b575f7e80a00;

    function _getStorage() private pure returns (ReputationSourceStorage storage s) {
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

    /// @notice Initialize the ReputationRegistrySource proxy.
    /// @param owner_ Admin address.
    /// @param localRegistry_ Existing ERC-8004 ReputationRegistry.
    /// @param gatewayAdapter_ PushGatewayAdapter address.
    /// @param settlementRegistry_ ReputationRegistry on Push Chain.
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

        ReputationSourceStorage storage s = _getStorage();
        s.gatewayAdapter = gatewayAdapter_;
        s.settlementRegistry = settlementRegistry_;
        s.localRegistry = localRegistry_;
        s.propagationEnabled = false;
        s.batchThreshold = 10;
        s.maxPropagationInterval = 1 hours;
    }

    // ──────────────────────────────────────────────
    //  Feedback + Propagation
    // ──────────────────────────────────────────────

    /// @notice Submit feedback locally and conditionally propagate.
    /// @dev Delegates to the existing ReputationRegistry for local storage.
    ///      If propagation is enabled and the batch threshold or time
    ///      interval is met, sends a reputation snapshot to Push Chain.
    ///      Caller must send msg.value if propagation will trigger.
    function giveFeedback(
        uint256 agentId,
        int128 value,
        uint8 valueDecimals,
        string calldata tag1,
        string calldata tag2,
        string calldata endpoint,
        string calldata feedbackURI,
        bytes32 feedbackHash
    ) external payable whenNotPaused {
        _localFeedback(
            agentId, value, valueDecimals, tag1, tag2, endpoint, feedbackURI, feedbackHash
        );
        _maybePropagate(agentId);
    }

    function _localFeedback(
        uint256 agentId,
        int128 value,
        uint8 valueDecimals,
        string calldata tag1,
        string calldata tag2,
        string calldata endpoint,
        string calldata feedbackURI,
        bytes32 feedbackHash
    ) internal {
        IReputationRegistryLocal(_getStorage().localRegistry)
            .giveFeedback(
                agentId, value, valueDecimals, tag1, tag2, endpoint, feedbackURI, feedbackHash
            );
    }

    function _maybePropagate(
        uint256 agentId
    ) internal {
        ReputationSourceStorage storage s = _getStorage();
        if (!s.propagationEnabled) return;

        s.pendingFeedbackCount[agentId]++;

        bool shouldSend = s.pendingFeedbackCount[agentId] >= s.batchThreshold
            || s.lastPropagated[agentId] == 0
            || (block.timestamp - s.lastPropagated[agentId]) >= s.maxPropagationInterval;

        if (shouldSend && msg.value > 0) {
            _propagateReputation(agentId);
        }
    }

    /// @notice Manually trigger reputation propagation for an agent.
    /// @dev Permissionless — anyone can call this and pay the gateway fee.
    function propagateReputation(
        uint256 agentId
    ) external payable {
        if (!_getStorage().propagationEnabled) {
            revert PropagationDisabled();
        }
        _propagateReputation(agentId);
    }

    // ──────────────────────────────────────────────
    //  Canonical ID Management
    // ──────────────────────────────────────────────

    /// @notice Set the canonical agent ID mapping for a local agent.
    /// @dev Called by the owner after the agent registers on Push Chain.
    function setCanonicalId(
        uint256 localAgentId,
        uint256 cId
    ) external onlyOwner {
        _getStorage().canonicalIds[localAgentId] = cId;
    }

    /// @notice Batch-set canonical agent IDs.
    function batchSetCanonicalIds(
        uint256[] calldata localAgentIds,
        uint256[] calldata canonicalIds
    ) external onlyOwner {
        require(localAgentIds.length == canonicalIds.length, "length mismatch");
        ReputationSourceStorage storage s = _getStorage();
        for (uint256 i; i < localAgentIds.length; i++) {
            s.canonicalIds[localAgentIds[i]] = canonicalIds[i];
        }
    }

    // ──────────────────────────────────────────────
    //  Internal
    // ──────────────────────────────────────────────

    function _propagateReputation(
        uint256 agentId
    ) internal {
        ReputationSourceStorage storage s = _getStorage();

        // Read current local summary (all clients, no tag filter)
        address[] memory clients = IReputationRegistryLocal(s.localRegistry).getClients(agentId);

        (uint64 feedbackCount, int128 summaryValue, uint8 decimals) =
            IReputationRegistryLocal(s.localRegistry).getSummary(agentId, clients, "", "");

        uint256 cId = s.canonicalIds[agentId];

        // Encode ReputationRegistry.submitReputation() payload
        // Using the ReputationSubmission struct ABI encoding
        bytes memory submitCalldata = abi.encodeWithSignature(
            "submitReputation((uint256,string,string,address,uint256,"
            "uint64,int128,uint8,uint64,uint64,uint256))",
            cId,
            "eip155",
            _chainIdString(),
            s.localRegistry,
            agentId,
            feedbackCount,
            summaryValue,
            decimals,
            uint64(0), // positiveCount (computed on settlement)
            uint64(0), // negativeCount (computed on settlement)
            block.number
        );

        bytes memory payload = abi.encode(s.settlementRegistry, submitCalldata);

        IGatewayAdapter(s.gatewayAdapter).sendPayload{value: msg.value}(
            address(0), // recipient: credit to caller's UEA
            payload,
            "", // no signature needed for reporter submissions
            msg.sender
        );

        s.pendingFeedbackCount[agentId] = 0;
        s.lastPropagated[agentId] = uint64(block.timestamp);

        emit ReputationPropagated(agentId, feedbackCount, summaryValue, block.number);
    }

    /// @dev Returns the chain ID as a string for CAIP-2 encoding.
    function _chainIdString() internal view returns (string memory) {
        return _uint256ToString(block.chainid);
    }

    /// @dev Uint256 to decimal string.
    function _uint256ToString(
        uint256 value
    ) internal pure returns (string memory) {
        if (value == 0) return "0";

        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }

        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits--;
            buffer[digits] = bytes1(uint8(48 + (value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    // ──────────────────────────────────────────────
    //  Read Functions
    // ──────────────────────────────────────────────

    function pendingFeedbackCount(
        uint256 agentId
    ) external view returns (uint64) {
        return _getStorage().pendingFeedbackCount[agentId];
    }

    function lastPropagated(
        uint256 agentId
    ) external view returns (uint64) {
        return _getStorage().lastPropagated[agentId];
    }

    function canonicalId(
        uint256 localAgentId
    ) external view returns (uint256) {
        return _getStorage().canonicalIds[localAgentId];
    }

    function gatewayAdapter() external view returns (address) {
        return _getStorage().gatewayAdapter;
    }

    function settlementRegistry() external view returns (address) {
        return _getStorage().settlementRegistry;
    }

    function localRegistry() external view returns (address) {
        return _getStorage().localRegistry;
    }

    function propagationEnabled() external view returns (bool) {
        return _getStorage().propagationEnabled;
    }

    function batchThreshold() external view returns (uint64) {
        return _getStorage().batchThreshold;
    }

    function maxPropagationInterval() external view returns (uint64) {
        return _getStorage().maxPropagationInterval;
    }

    function estimatePropagationFee() external view returns (uint256) {
        return IGatewayAdapter(_getStorage().gatewayAdapter).estimateFee();
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

    function setPropagationEnabled(
        bool enabled
    ) external onlyOwner {
        _getStorage().propagationEnabled = enabled;
        emit PropagationToggled(enabled);
    }

    function setBatchThreshold(
        uint64 threshold
    ) external onlyOwner {
        if (threshold == 0) revert InvalidBatchThreshold();
        _getStorage().batchThreshold = threshold;
        emit BatchThresholdUpdated(threshold);
    }

    function setMaxPropagationInterval(
        uint64 interval
    ) external onlyOwner {
        _getStorage().maxPropagationInterval = interval;
        emit MaxPropagationIntervalUpdated(interval);
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
