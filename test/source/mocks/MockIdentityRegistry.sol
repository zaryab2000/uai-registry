// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Minimal mock of ERC-8004 IdentityRegistryUpgradeable for testing
///      IdentityRegistrySource. Simulates register(), ownerOf(), tokenURI().
contract MockIdentityRegistry {
    uint256 private _lastId;
    mapping(uint256 => address) private _owners;
    mapping(uint256 => string) private _uris;

    event Registered(uint256 indexed agentId, string agentURI, address indexed owner);

    function register(
        string memory agentURI
    ) external returns (uint256 agentId) {
        agentId = _lastId++;
        _owners[agentId] = msg.sender;
        _uris[agentId] = agentURI;
        emit Registered(agentId, agentURI, msg.sender);
    }

    function ownerOf(
        uint256 agentId
    ) external view returns (address) {
        address owner = _owners[agentId];
        require(owner != address(0), "ERC721NonexistentToken");
        return owner;
    }

    function tokenURI(
        uint256 agentId
    ) external view returns (string memory) {
        return _uris[agentId];
    }
}
