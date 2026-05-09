// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {ReputationRegistry} from "src/ReputationRegistry.sol";
import {
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract DeployReputation is Script {
    function run() external {
        address deployer = msg.sender;
        address agentRegistryProxy = vm.envAddress("AGENT_REGISTRY_PROXY");
        address reporter = vm.envAddress("INITIAL_REPORTER");
        address slasher = vm.envAddress("INITIAL_SLASHER");

        vm.startBroadcast();

        ReputationRegistry impl = new ReputationRegistry();
        console.log("Implementation:", address(impl));

        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(impl),
            deployer,
            abi.encodeCall(ReputationRegistry.initialize, (deployer, deployer, agentRegistryProxy))
        );
        console.log("Proxy:", address(proxy));

        ReputationRegistry registry = ReputationRegistry(address(proxy));

        registry.grantRole(registry.REPORTER_ROLE(), reporter);
        console.log("Reporter granted:", reporter);

        registry.grantRole(registry.SLASHER_ROLE(), slasher);
        console.log("Slasher granted:", slasher);

        vm.stopBroadcast();
    }
}
