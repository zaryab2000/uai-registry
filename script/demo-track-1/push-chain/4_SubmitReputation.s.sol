// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {TAPReputationRegistry} from "src/TAPReputationRegistry.sol";
import {ITAPReputationRegistry} from "src/interfaces/ITAPReputationRegistry.sol";

/// @title 4_SubmitReputation
/// @notice Submits a per-chain reputation snapshot to Push Chain's
///         TAPReputationRegistry. Called by the Deployer (REPORTER_ROLE).
///
/// Usage:
///   AGENT_ID=<id> CHAIN_ID=11155111 BOUND_AGENT_ID=<id> \
///   FEEDBACK_COUNT=150 SUMMARY_VALUE=85 POSITIVE=120 NEGATIVE=30 \
///   SOURCE_BLOCK=1000000 \
///   forge script script/demo/push-chain/4_SubmitReputation.s.sol \
///     --private-key $DEPLOYER_KEY \
///     --rpc-url $PC_RPC --broadcast -vvvv
///
/// Env vars required:
///   REPUTATION_REGISTRY - TAPReputationRegistry proxy address
///   ERC8004_IDENTITY    - ERC-8004 registry address on source chain
///   AGENT_ID            - Canonical agent ID on Push Chain
///   CHAIN_ID            - Source chain CAIP-2 chain ID
///   BOUND_AGENT_ID      - Agent ID on the source chain
///   FEEDBACK_COUNT      - Number of feedbacks to report
///   SUMMARY_VALUE       - Average rating 0-100 (integer, scaled to 18 dec)
///   POSITIVE            - Positive feedback count
///   NEGATIVE            - Negative feedback count
///   SOURCE_BLOCK        - Source chain block number for staleness
contract SubmitReputation is Script {
    function run() external {
        address repRegistryAddr = vm.envAddress("REPUTATION_REGISTRY");
        address sourceRegistry = vm.envAddress("ERC8004_IDENTITY");
        uint256 agentId = vm.envUint("AGENT_ID");
        string memory chainId = vm.envString("CHAIN_ID");
        uint256 boundAgentId = vm.envUint("BOUND_AGENT_ID");
        uint64 feedbackCount = uint64(vm.envUint("FEEDBACK_COUNT"));
        uint256 summaryRaw = vm.envUint("SUMMARY_VALUE");
        uint64 positive = uint64(vm.envUint("POSITIVE"));
        uint64 negative = uint64(vm.envUint("NEGATIVE"));
        uint256 sourceBlock = vm.envUint("SOURCE_BLOCK");

        int128 summaryValue = int128(int256(summaryRaw * 1e18));

        TAPReputationRegistry repRegistry = TAPReputationRegistry(repRegistryAddr);

        string memory chainLabel = _chainLabel(chainId);

        _header(string.concat("STEP 4: Submit Reputation (", chainLabel, ")"));
        _log("Reporter", vm.toString(msg.sender));
        _log("Agent ID", vm.toString(agentId));
        _log("Chain", string.concat("eip155:", chainId));
        _log("Bound Agent ID", vm.toString(boundAgentId));
        _log("Feedback Count", vm.toString(uint256(feedbackCount)));
        _log("Summary Value", string.concat(vm.toString(summaryRaw), "/100"));
        _log("Positive", vm.toString(uint256(positive)));
        _log("Negative", vm.toString(uint256(negative)));
        _log("Source Block", vm.toString(sourceBlock));
        _separator();

        ITAPReputationRegistry.ReputationSubmission memory sub =
            ITAPReputationRegistry.ReputationSubmission({
                agentId: agentId,
                chainNamespace: "eip155",
                chainId: chainId,
                registryAddress: sourceRegistry,
                boundAgentId: boundAgentId,
                feedbackCount: feedbackCount,
                summaryValue: summaryValue,
                valueDecimals: 18,
                positiveCount: positive,
                negativeCount: negative,
                sourceBlockNumber: sourceBlock
            });

        vm.startBroadcast();
        repRegistry.submitReputation(sub);
        vm.stopBroadcast();

        uint256 score = repRegistry.getReputationScore(agentId);
        ITAPReputationRegistry.AggregatedReputation memory agg =
            repRegistry.getAggregatedReputation(agentId);

        _header("REPUTATION RESULT");
        _log("Status", "SUCCESS");
        _log(
            "Score",
            string.concat(
                vm.toString(score),
                " bps (",
                vm.toString(score / 100),
                ".",
                vm.toString(score % 100),
                "%)"
            )
        );
        _log("Chain Count", vm.toString(uint256(agg.chainCount)));
        _log("Total Feedback", vm.toString(uint256(agg.totalFeedbackCount)));
        _log("Total Positive", vm.toString(uint256(agg.totalPositive)));
        _log("Total Negative", vm.toString(uint256(agg.totalNegative)));
        _log("Weighted Avg", vm.toString(int256(agg.weightedAvgValue)));
        _separator();
    }

    function _chainLabel(
        string memory chainId
    ) internal pure returns (string memory) {
        if (keccak256(bytes(chainId)) == keccak256(bytes("11155111"))) return "Sepolia";
        if (keccak256(bytes(chainId)) == keccak256(bytes("84532"))) return "Base Sepolia";
        if (keccak256(bytes(chainId)) == keccak256(bytes("97"))) return "BSC Testnet";
        return chainId;
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
