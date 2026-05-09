// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Minimal mock of ERC-8004 ReputationRegistryUpgradeable for testing
///      ReputationRegistryPlus. Simulates giveFeedback(), getSummary(),
///      getClients().
contract MockReputationRegistry {
    struct StoredFeedback {
        int128 value;
        uint8 valueDecimals;
    }

    mapping(uint256 => uint64) private _feedbackCount;
    mapping(uint256 => int128) private _summaryValue;
    mapping(uint256 => uint8) private _summaryDecimals;
    mapping(uint256 => address[]) private _clients;
    mapping(uint256 => mapping(address => bool)) private _clientExists;

    bool public shouldRevert;

    event FeedbackGiven(
        uint256 indexed agentId,
        address indexed client,
        int128 value,
        uint8 valueDecimals
    );

    function giveFeedback(
        uint256 agentId,
        int128 value,
        uint8 valueDecimals,
        string calldata,
        string calldata,
        string calldata,
        string calldata,
        bytes32
    ) external {
        if (shouldRevert) revert("feedback reverted");

        _feedbackCount[agentId]++;

        if (!_clientExists[agentId][msg.sender]) {
            _clients[agentId].push(msg.sender);
            _clientExists[agentId][msg.sender] = true;
        }

        // Simple running average update
        _summaryValue[agentId] = value;
        _summaryDecimals[agentId] = valueDecimals;

        emit FeedbackGiven(agentId, msg.sender, value, valueDecimals);
    }

    function getSummary(
        uint256 agentId,
        address[] calldata,
        string calldata,
        string calldata
    )
        external
        view
        returns (
            uint64 count,
            int128 summaryValue,
            uint8 summaryValueDecimals
        )
    {
        return (
            _feedbackCount[agentId],
            _summaryValue[agentId],
            _summaryDecimals[agentId]
        );
    }

    function getClients(
        uint256 agentId
    ) external view returns (address[] memory) {
        return _clients[agentId];
    }

    function setShouldRevert(bool val) external {
        shouldRevert = val;
    }

    function setMockSummary(
        uint256 agentId,
        uint64 count,
        int128 value,
        uint8 decimals
    ) external {
        _feedbackCount[agentId] = count;
        _summaryValue[agentId] = value;
        _summaryDecimals[agentId] = decimals;
    }
}
