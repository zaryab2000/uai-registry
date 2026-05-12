// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {TAPReputationRegistry} from "src/TAPReputationRegistry.sol";
import {ITAPReputationRegistry} from "src/interfaces/ITAPReputationRegistry.sol";

/// @title 5_Slash
/// @notice Slashes an agent for misconduct. Called by the Deployer
///         (SLASHER_ROLE). Shows score impact before and after.
///
/// Usage:
///   AGENT_ID=<id> SLASH_CHAIN_ID=97 SEVERITY_BPS=2000 \
///   SLASH_REASON="Unauthorized token swap" \
///   forge script script/demo/push-chain/5_Slash.s.sol \
///     --private-key $DEPLOYER_KEY \
///     --rpc-url $PC_RPC --broadcast -vvvv
///
/// Env vars required:
///   REPUTATION_REGISTRY - TAPReputationRegistry proxy address
///   AGENT_ID            - Canonical agent ID
///   SLASH_CHAIN_ID      - Chain ID where offense occurred
///   SEVERITY_BPS        - Severity in basis points (1-10000)
///   SLASH_REASON        - Human-readable reason
contract Slash is Script {
    function run() external {
        address repRegistryAddr = vm.envAddress("REPUTATION_REGISTRY");
        uint256 agentId = vm.envUint("AGENT_ID");
        string memory chainId = vm.envString("SLASH_CHAIN_ID");
        uint256 severityBps = vm.envUint("SEVERITY_BPS");
        string memory reason = vm.envString("SLASH_REASON");

        TAPReputationRegistry repRegistry = TAPReputationRegistry(repRegistryAddr);

        uint256 scoreBefore = repRegistry.getReputationScore(agentId);

        bytes32 evidenceHash =
            keccak256(abi.encodePacked("evidence: ", reason, " on chain ", chainId));

        _header("STEP 5: Slash Agent");
        _log("Slasher", vm.toString(msg.sender));
        _log("Agent ID", vm.toString(agentId));
        _log("Chain", string.concat("eip155:", chainId));
        _log("Severity", string.concat(vm.toString(severityBps), " bps"));
        _log("Reason", reason);
        _log("Evidence Hash", vm.toString(evidenceHash));
        _log("Score BEFORE", string.concat(vm.toString(scoreBefore), " bps"));
        _separator();

        vm.startBroadcast();
        repRegistry.slash(agentId, "eip155", chainId, reason, evidenceHash, severityBps);
        vm.stopBroadcast();

        uint256 scoreAfter = repRegistry.getReputationScore(agentId);

        ITAPReputationRegistry.SlashRecord[] memory records = repRegistry.getSlashRecords(agentId);

        _header("SLASH RESULT");
        _log("Status", "SUCCESS");
        _log("Score BEFORE", string.concat(vm.toString(scoreBefore), " bps"));
        _log("Score AFTER", string.concat(vm.toString(scoreAfter), " bps"));

        uint256 diff = scoreBefore > scoreAfter ? scoreBefore - scoreAfter : 0;

        _log("Score DROP", string.concat("-", vm.toString(diff), " bps"));
        _log("Total Slashes", vm.toString(records.length));
        _separator();

        console.log("");
        console.log("  SLASH HISTORY:");
        for (uint256 i; i < records.length; i++) {
            string memory entry = string.concat(
                "  [",
                vm.toString(i),
                "] ",
                records[i].chainNamespace,
                ":",
                records[i].chainId,
                "  severity=",
                vm.toString(records[i].severityBps),
                " bps  reason=\"",
                records[i].reason,
                "\""
            );
            console.log(entry);
        }
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
