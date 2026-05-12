// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {TAPRegistry} from "src/TAPRegistry.sol";
import {ITAPRegistry} from "src/interfaces/ITAPRegistry.sol";

/// @title 2_RegisterOnPushChain
/// @notice Registers the canonical agent identity on Push Chain's TAPRegistry.
///         Must be called by the Agent Builder wallet.
///
/// Usage:
///   forge script script/demo/push-chain/2_RegisterOnPushChain.s.sol \
///     --private-key $AGENT_BUILDER_KEY \
///     --rpc-url $PC_RPC --broadcast -vvvv
///
/// Env vars required:
///   AGENT_URI        - IPFS URI for agent card
///   AGENT_CARD_HASH  - keccak256 of agent card JSON content
///   AGENT_REGISTRY   - TAPRegistry proxy address on Push Chain
contract RegisterOnPushChain is Script {
    function run() external {
        string memory agentURI = vm.envString("AGENT_URI");
        bytes32 cardHash = vm.envBytes32("AGENT_CARD_HASH");
        address registryAddr = vm.envAddress("AGENT_REGISTRY");

        TAPRegistry registry = TAPRegistry(registryAddr);

        _header("STEP 2: Register Canonical Identity on Push Chain");
        _log("Chain ID", vm.toString(block.chainid));
        _log("TAPRegistry", vm.toString(registryAddr));
        _log("Caller (UEA)", vm.toString(msg.sender));
        _log("Agent URI", agentURI);
        _log("Card Hash", vm.toString(cardHash));
        _separator();

        vm.startBroadcast();
        uint256 agentId = registry.register(agentURI, cardHash);
        vm.stopBroadcast();

        ITAPRegistry.AgentRecord memory record = registry.getAgentRecord(agentId);

        _header("REGISTRATION RESULT");
        _log("Agent ID", vm.toString(agentId));
        _log("Agent ID (hex)", vm.toString(bytes32(agentId)));
        _log("Owner", vm.toString(registry.ownerOf(agentId)));
        _log("Registered", record.registered ? "true" : "false");
        _log("Native to Push", record.nativeToPush ? "true" : "false");
        _log("Origin NS", record.originChainNamespace);
        _log("Origin Chain", record.originChainId);
        _log("Registered At", vm.toString(record.registeredAt));
        _log("Agent URI", record.agentURI);
        _separator();

        console.log("");
        console.log("  >>> Save this for all subsequent steps:");
        console.log("      AGENT_ID=%s", vm.toString(agentId));
        console.log("");
    }

    function _header(
        string memory title
    ) internal pure {
        console.log("");
        console.log("==========================================");
        console.log("  %s", title);
        console.log("==========================================");
    }

    function _log(
        string memory key,
        string memory value
    ) internal pure {
        console.log("  %-16s %s", key, value);
    }

    function _separator() internal pure {
        console.log("------------------------------------------");
    }
}
