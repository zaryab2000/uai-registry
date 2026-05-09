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
    SafeCast
} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IUAIRegistry} from "./interfaces/IUAIRegistry.sol";
import {IReputationRegistry} from "./IReputationRegistry.sol";
import {
    AgentNotRegisteredForReputation,
    StaleSubmission,
    InvalidSeverity,
    InvalidChainIdentifierReputation,
    InvalidRegistryAddressReputation,
    ShadowNotLinked,
    BatchTooLarge,
    EmptyBatch,
    InvalidDecimals,
    InvalidUAIRegistryAddress,
    InvalidInitializationAddress,
    MaxSlashRecordsExceeded,
    SummaryValueOutOfRange,
    TooManyChainKeys
} from "./libraries/ReputationErrors.sol";

/// @title ReputationRegistry
/// @notice Cross-chain agent reputation aggregator on Push Chain.
///         Collects per-chain reputation snapshots from authorized reporters
///         and computes aggregated scores keyed to canonical UEA via UAIRegistry.
contract ReputationRegistry is
    IReputationRegistry,
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable
{
    // ──────────────────────────────────────────────
    //  Roles
    // ──────────────────────────────────────────────

    bytes32 public constant REPORTER_ROLE = keccak256("REPORTER_ROLE");
    bytes32 public constant SLASHER_ROLE = keccak256("SLASHER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // ──────────────────────────────────────────────
    //  Constants
    // ──────────────────────────────────────────────

    uint256 public constant MAX_BATCH_SIZE = 50;
    uint256 public constant MAX_SLASH_RECORDS = 256;
    uint256 public constant MAX_CHAIN_KEYS = 64;
    uint8 public constant MAX_DECIMALS = 18;
    uint256 public constant MAX_BPS = 10_000;

    uint256 private constant BASE_SCORE_CAP = 7000;
    uint256 private constant VOLUME_MULTIPLIER_FLOOR = 5000;
    uint256 private constant VOLUME_MULTIPLIER_STEP = 500;
    uint256 private constant DIVERSITY_BONUS_PER_CHAIN = 500;
    uint256 private constant DIVERSITY_BONUS_CAP = 2000;
    uint256 private constant PERFECT_VALUE_WAD = 100 * 1e18;

    // ──────────────────────────────────────────────
    //  ERC-7201 namespaced storage
    // ──────────────────────────────────────────────

    /// @custom:storage-location erc7201:reputationregistry.storage
    struct ReputationRegistryStorage {
        mapping(uint256 => AggregatedReputation) aggregated;
        mapping(uint256 => mapping(bytes32 => ChainReputation)) chainReputations;
        mapping(uint256 => bytes32[]) chainKeys;
        mapping(uint256 => mapping(bytes32 => uint256)) chainKeyIndex;
        mapping(uint256 => mapping(bytes32 => bool)) chainKeyExists;
        mapping(uint256 => SlashRecord[]) slashRecords;
        mapping(uint256 => uint256) totalSlashSeverity;
        address uaiRegistry;
    }

    // keccak256(abi.encode(uint256(keccak256("reputationregistry.storage")) - 1))
    //   & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT =
        0xe070097f04227be86f6bce14fa1fa3a34d6ed0171b77fb88539672b7cff99400;

    function _getStorage()
        private
        pure
        returns (ReputationRegistryStorage storage s)
    {
        bytes32 slot = STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }

    // ──────────────────────────────────────────────
    //  Constructor + Initializer
    // ──────────────────────────────────────────────

    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the ReputationRegistry proxy.
    /// @param admin Address receiving DEFAULT_ADMIN_ROLE.
    /// @param pauser Address receiving PAUSER_ROLE.
    /// @param uaiRegistryAddr Address of the deployed UAIRegistry proxy.
    function initialize(
        address admin,
        address pauser,
        address uaiRegistryAddr
    ) external initializer {
        if (admin == address(0) || pauser == address(0)) {
            revert InvalidInitializationAddress();
        }
        if (uaiRegistryAddr == address(0)) {
            revert InvalidUAIRegistryAddress();
        }

        __AccessControl_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, pauser);

        _getStorage().uaiRegistry = uaiRegistryAddr;
    }

    // ──────────────────────────────────────────────
    //  Write — Submission
    // ──────────────────────────────────────────────

    /// @inheritdoc IReputationRegistry
    function submitReputation(
        ReputationSubmission calldata submission
    ) external onlyRole(REPORTER_ROLE) whenNotPaused {
        _submitSingle(submission);
        _reaggregate(submission.agentId);
    }

    /// @inheritdoc IReputationRegistry
    function batchSubmitReputation(
        ReputationSubmission[] calldata submissions
    ) external onlyRole(REPORTER_ROLE) whenNotPaused {
        uint256 len = submissions.length;
        if (len == 0) revert EmptyBatch();
        if (len > MAX_BATCH_SIZE) revert BatchTooLarge(len, MAX_BATCH_SIZE);

        uint256[] memory seenAgents = new uint256[](len);
        uint256 seenCount;

        for (uint256 i; i < len; i++) {
            _submitSingle(submissions[i]);

            uint256 aid = submissions[i].agentId;
            bool found;
            for (uint256 j; j < seenCount; j++) {
                if (seenAgents[j] == aid) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                seenAgents[seenCount] = aid;
                seenCount++;
            }
        }

        for (uint256 i; i < seenCount; i++) {
            _reaggregate(seenAgents[i]);
        }
    }

    // ──────────────────────────────────────────────
    //  Write — Slashing
    // ──────────────────────────────────────────────

    /// @inheritdoc IReputationRegistry
    function slash(
        uint256 agentId,
        string calldata chainNamespace,
        string calldata chainId,
        string calldata reason,
        bytes32 evidenceHash,
        uint256 severityBps
    ) external onlyRole(SLASHER_ROLE) whenNotPaused {
        if (severityBps == 0 || severityBps > MAX_BPS) {
            revert InvalidSeverity(severityBps);
        }
        if (
            bytes(chainNamespace).length == 0 || bytes(chainId).length == 0
        ) {
            revert InvalidChainIdentifierReputation();
        }

        ReputationRegistryStorage storage s = _getStorage();
        IUAIRegistry uaiReg = IUAIRegistry(s.uaiRegistry);
        if (!uaiReg.isRegistered(agentId)) {
            revert AgentNotRegisteredForReputation(agentId);
        }
        if (s.slashRecords[agentId].length >= MAX_SLASH_RECORDS) {
            revert MaxSlashRecordsExceeded(agentId);
        }

        s.slashRecords[agentId].push(
            SlashRecord({
                chainNamespace: chainNamespace,
                chainId: chainId,
                reason: reason,
                evidenceHash: evidenceHash,
                slashedAt: uint64(block.timestamp),
                reporter: msg.sender,
                severityBps: severityBps
            })
        );

        s.totalSlashSeverity[agentId] += severityBps;
        _computeScore(agentId);

        emit AgentSlashed(
            agentId,
            chainNamespace,
            chainId,
            reason,
            severityBps,
            msg.sender
        );
    }

    // ──────────────────────────────────────────────
    //  Write — Reaggregation
    // ──────────────────────────────────────────────

    /// @inheritdoc IReputationRegistry
    function reaggregate(uint256 agentId) external whenNotPaused {
        ReputationRegistryStorage storage s = _getStorage();
        IUAIRegistry uaiReg = IUAIRegistry(s.uaiRegistry);
        if (!uaiReg.isRegistered(agentId)) {
            revert AgentNotRegisteredForReputation(agentId);
        }

        IUAIRegistry.ShadowEntry[] memory shadows =
            uaiReg.getShadows(agentId);

        uint256 keyLen = s.chainKeys[agentId].length;
        uint256 i;
        while (i < keyLen) {
            bytes32 ck = s.chainKeys[agentId][i];
            ChainReputation storage cr =
                s.chainReputations[agentId][ck];

            bool stillLinked;
            bytes32 crNsHash = keccak256(bytes(cr.chainNamespace));
            bytes32 crIdHash = keccak256(bytes(cr.chainId));
            for (uint256 j; j < shadows.length; j++) {
                if (
                    keccak256(bytes(shadows[j].chainNamespace)) == crNsHash
                    && keccak256(bytes(shadows[j].chainId)) == crIdHash
                ) {
                    stillLinked = true;
                    break;
                }
            }

            if (!stillLinked) {
                _removeChainKey(agentId, ck);
                keyLen = s.chainKeys[agentId].length;
            } else {
                i++;
            }
        }

        _reaggregate(agentId);
    }

    // ──────────────────────────────────────────────
    //  Write — Admin
    // ──────────────────────────────────────────────

    /// @inheritdoc IReputationRegistry
    function setUAIRegistry(
        address newUAIRegistry
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newUAIRegistry == address(0)) {
            revert InvalidUAIRegistryAddress();
        }
        ReputationRegistryStorage storage s = _getStorage();
        address oldAddr = s.uaiRegistry;
        s.uaiRegistry = newUAIRegistry;
        emit UAIRegistryUpdated(oldAddr, newUAIRegistry);
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
    //  Reads
    // ──────────────────────────────────────────────

    /// @inheritdoc IReputationRegistry
    function getAggregatedReputation(
        uint256 agentId
    ) external view returns (AggregatedReputation memory) {
        return _getStorage().aggregated[agentId];
    }

    /// @inheritdoc IReputationRegistry
    function getChainReputation(
        uint256 agentId,
        string calldata chainNamespace,
        string calldata chainId
    ) external view returns (ChainReputation memory) {
        bytes32 chainKey = keccak256(
            abi.encode(chainNamespace, chainId)
        );
        return _getStorage().chainReputations[agentId][chainKey];
    }

    /// @inheritdoc IReputationRegistry
    function getAllChainReputations(
        uint256 agentId
    ) external view returns (ChainReputation[] memory) {
        ReputationRegistryStorage storage s = _getStorage();
        bytes32[] storage keys = s.chainKeys[agentId];
        uint256 len = keys.length;
        ChainReputation[] memory result = new ChainReputation[](len);
        for (uint256 i; i < len; i++) {
            result[i] = s.chainReputations[agentId][keys[i]];
        }
        return result;
    }

    /// @inheritdoc IReputationRegistry
    function getReputationScore(
        uint256 agentId
    ) external view returns (uint256) {
        return _getStorage().aggregated[agentId].reputationScore;
    }

    /// @inheritdoc IReputationRegistry
    function getSlashRecords(
        uint256 agentId
    ) external view returns (SlashRecord[] memory) {
        return _getStorage().slashRecords[agentId];
    }

    /// @inheritdoc IReputationRegistry
    function isFresh(
        uint256 agentId,
        uint256 maxAge
    ) external view returns (bool) {
        uint64 lastAgg =
            _getStorage().aggregated[agentId].lastAggregated;
        if (lastAgg == 0) return false;
        return block.timestamp - lastAgg <= maxAge;
    }

    /// @inheritdoc IReputationRegistry
    function lastUpdated(
        uint256 agentId
    ) external view returns (uint64) {
        return _getStorage().aggregated[agentId].lastAggregated;
    }

    /// @inheritdoc IReputationRegistry
    function getUAIRegistry() external view returns (address) {
        return _getStorage().uaiRegistry;
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
        return
            interfaceId == type(IReputationRegistry).interfaceId
            || super.supportsInterface(interfaceId);
    }

    // ──────────────────────────────────────────────
    //  Internal — Submission
    // ──────────────────────────────────────────────

    function _submitSingle(
        ReputationSubmission calldata sub
    ) internal {
        if (sub.valueDecimals > MAX_DECIMALS) {
            revert InvalidDecimals(sub.valueDecimals);
        }
        int128 maxAbsolute =
            int128(int256(100 * int256(10 ** uint256(sub.valueDecimals))));
        if (
            sub.summaryValue > maxAbsolute
                || sub.summaryValue < -maxAbsolute
        ) {
            revert SummaryValueOutOfRange(sub.summaryValue, maxAbsolute);
        }
        if (
            bytes(sub.chainNamespace).length == 0
            || bytes(sub.chainId).length == 0
        ) {
            revert InvalidChainIdentifierReputation();
        }
        if (sub.registryAddress == address(0)) {
            revert InvalidRegistryAddressReputation();
        }

        ReputationRegistryStorage storage s = _getStorage();
        IUAIRegistry uaiReg = IUAIRegistry(s.uaiRegistry);

        if (!uaiReg.isRegistered(sub.agentId)) {
            revert AgentNotRegisteredForReputation(sub.agentId);
        }

        _validateShadowLink(
            sub.agentId,
            sub.chainNamespace,
            sub.chainId
        );

        bytes32 chainKey = keccak256(
            abi.encode(sub.chainNamespace, sub.chainId)
        );

        if (s.chainKeyExists[sub.agentId][chainKey]) {
            uint256 storedBlock =
                s.chainReputations[sub.agentId][chainKey].sourceBlockNumber;
            if (sub.sourceBlockNumber <= storedBlock) {
                revert StaleSubmission(
                    sub.agentId,
                    sub.chainNamespace,
                    sub.chainId,
                    storedBlock,
                    sub.sourceBlockNumber
                );
            }
        } else {
            if (s.chainKeys[sub.agentId].length >= MAX_CHAIN_KEYS) {
                revert TooManyChainKeys(sub.agentId, MAX_CHAIN_KEYS);
            }
            s.chainKeys[sub.agentId].push(chainKey);
            s.chainKeyIndex[sub.agentId][chainKey] =
                s.chainKeys[sub.agentId].length - 1;
            s.chainKeyExists[sub.agentId][chainKey] = true;
        }

        s.chainReputations[sub.agentId][chainKey] = ChainReputation({
            chainNamespace: sub.chainNamespace,
            chainId: sub.chainId,
            registryAddress: sub.registryAddress,
            shadowAgentId: sub.shadowAgentId,
            feedbackCount: sub.feedbackCount,
            summaryValue: sub.summaryValue,
            valueDecimals: sub.valueDecimals,
            positiveCount: sub.positiveCount,
            negativeCount: sub.negativeCount,
            sourceBlockNumber: sub.sourceBlockNumber,
            lastUpdated: uint64(block.timestamp),
            reporter: msg.sender
        });

        emit ReputationSubmitted(
            sub.agentId,
            sub.chainNamespace,
            sub.chainId,
            sub.feedbackCount,
            sub.summaryValue,
            msg.sender
        );
    }

    // ──────────────────────────────────────────────
    //  Internal — Shadow Validation
    // ──────────────────────────────────────────────

    function _validateShadowLink(
        uint256 agentId,
        string calldata chainNamespace,
        string calldata chainId
    ) internal view {
        IUAIRegistry uaiReg =
            IUAIRegistry(_getStorage().uaiRegistry);
        IUAIRegistry.ShadowEntry[] memory shadows =
            uaiReg.getShadows(agentId);

        bytes32 targetNsHash = keccak256(bytes(chainNamespace));
        bytes32 targetIdHash = keccak256(bytes(chainId));

        for (uint256 i; i < shadows.length; i++) {
            if (
                keccak256(bytes(shadows[i].chainNamespace))
                    == targetNsHash
                && keccak256(bytes(shadows[i].chainId)) == targetIdHash
            ) {
                return;
            }
        }

        revert ShadowNotLinked(agentId, chainNamespace, chainId);
    }

    // ──────────────────────────────────────────────
    //  Internal — Aggregation
    // ──────────────────────────────────────────────

    function _reaggregate(uint256 agentId) internal {
        ReputationRegistryStorage storage s = _getStorage();

        int256 weightedSum;
        uint256 totalCount;
        uint256 totalPositive;
        uint256 totalNegative;
        uint256 chainCount;

        bytes32[] storage keys = s.chainKeys[agentId];
        for (uint256 i; i < keys.length; i++) {
            ChainReputation storage cr =
                s.chainReputations[agentId][keys[i]];
            if (cr.feedbackCount == 0) continue;

            int256 factor =
                int256(10 ** uint256(MAX_DECIMALS - cr.valueDecimals));
            int256 normalized = int256(cr.summaryValue) * factor;
            weightedSum +=
                normalized * int256(uint256(cr.feedbackCount));
            totalCount += cr.feedbackCount;
            totalPositive += cr.positiveCount;
            totalNegative += cr.negativeCount;
            chainCount++;
        }

        AggregatedReputation storage agg = s.aggregated[agentId];
        agg.totalFeedbackCount = SafeCast.toUint64(totalCount);
        agg.totalPositive = SafeCast.toUint64(totalPositive);
        agg.totalNegative = SafeCast.toUint64(totalNegative);
        agg.chainCount = SafeCast.toUint16(chainCount);
        agg.valueDecimals = MAX_DECIMALS;

        if (totalCount > 0) {
            agg.weightedAvgValue = SafeCast.toInt128(
                weightedSum / int256(totalCount)
            );
        } else {
            agg.weightedAvgValue = 0;
        }

        _computeScore(agentId);

        emit ReputationAggregated(
            agentId,
            agg.totalFeedbackCount,
            agg.reputationScore,
            agg.chainCount
        );
    }

    // ──────────────────────────────────────────────
    //  Internal — Score Computation
    // ──────────────────────────────────────────────

    function _computeScore(uint256 agentId) internal {
        ReputationRegistryStorage storage s = _getStorage();
        AggregatedReputation storage agg = s.aggregated[agentId];

        int256 normalizedAvg = int256(agg.weightedAvgValue);
        uint256 baseScore;
        if (normalizedAvg > 0) {
            baseScore =
                uint256(normalizedAvg) * BASE_SCORE_CAP / PERFECT_VALUE_WAD;
            if (baseScore > BASE_SCORE_CAP) baseScore = BASE_SCORE_CAP;
        }

        uint256 volumeMultiplier = VOLUME_MULTIPLIER_FLOOR;
        if (agg.totalFeedbackCount > 0) {
            volumeMultiplier = VOLUME_MULTIPLIER_FLOOR
                + (_log2(uint256(agg.totalFeedbackCount)) * VOLUME_MULTIPLIER_STEP);
            if (volumeMultiplier > MAX_BPS) {
                volumeMultiplier = MAX_BPS;
            }
        }

        uint256 diversityBonus =
            uint256(agg.chainCount) * DIVERSITY_BONUS_PER_CHAIN;
        if (diversityBonus > DIVERSITY_BONUS_CAP) {
            diversityBonus = DIVERSITY_BONUS_CAP;
        }

        uint256 adjustedBase =
            (baseScore * volumeMultiplier) / MAX_BPS;
        uint256 preSlash = adjustedBase + diversityBonus;

        uint256 slashPenalty = s.totalSlashSeverity[agentId];
        uint256 finalScore;
        if (preSlash > slashPenalty) {
            finalScore = preSlash - slashPenalty;
        }
        if (finalScore > MAX_BPS) finalScore = MAX_BPS;

        agg.reputationScore = finalScore;
        agg.lastAggregated = uint64(block.timestamp);
    }

    // ──────────────────────────────────────────────
    //  Internal — Chain Key Removal (swap-and-pop)
    // ──────────────────────────────────────────────

    function _removeChainKey(
        uint256 agentId,
        bytes32 chainKey
    ) internal {
        ReputationRegistryStorage storage s = _getStorage();

        uint256 idx = s.chainKeyIndex[agentId][chainKey];
        uint256 lastIdx = s.chainKeys[agentId].length - 1;

        if (idx != lastIdx) {
            bytes32 lastKey = s.chainKeys[agentId][lastIdx];
            s.chainKeys[agentId][idx] = lastKey;
            s.chainKeyIndex[agentId][lastKey] = idx;
        }

        s.chainKeys[agentId].pop();
        delete s.chainKeyExists[agentId][chainKey];
        delete s.chainKeyIndex[agentId][chainKey];
        delete s.chainReputations[agentId][chainKey];
    }

    // ──────────────────────────────────────────────
    //  Internal — Math
    // ──────────────────────────────────────────────

    function _log2(uint256 x) internal pure returns (uint256 r) {
        if (x <= 1) return 0;
        if (x >= 1 << 128) { x >>= 128; r += 128; }
        if (x >= 1 << 64) { x >>= 64; r += 64; }
        if (x >= 1 << 32) { x >>= 32; r += 32; }
        if (x >= 1 << 16) { x >>= 16; r += 16; }
        if (x >= 1 << 8) { x >>= 8; r += 8; }
        if (x >= 1 << 4) { x >>= 4; r += 4; }
        if (x >= 1 << 2) { x >>= 2; r += 2; }
        if (x >= 1 << 1) { r += 1; }
    }
}
