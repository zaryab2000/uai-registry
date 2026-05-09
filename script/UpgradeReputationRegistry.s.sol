// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {ReputationRegistry} from "src/ReputationRegistry.sol";

interface IProxyAdmin {
    function upgradeAndCall(
        address proxy,
        address implementation,
        bytes calldata data
    ) external;
}

contract UpgradeReputationRegistry is Script {
    function run() external {
        address proxy = vm.envAddress("REPUTATION_REGISTRY_PROXY");
        address proxyAdmin = vm.envAddress("REPUTATION_REGISTRY_PROXY_ADMIN");

        ReputationRegistry old = ReputationRegistry(proxy);
        console.log("Proxy:", proxy);
        console.log("ProxyAdmin:", proxyAdmin);
        console.log("Old AgentRegistry link:", address(old.getAgentRegistry()));

        vm.startBroadcast();

        ReputationRegistry newImpl = new ReputationRegistry();
        console.log("New Implementation:", address(newImpl));

        IProxyAdmin(proxyAdmin).upgradeAndCall(proxy, address(newImpl), "");
        console.log("Upgrade complete");

        ReputationRegistry upgraded = ReputationRegistry(proxy);
        console.log("Post-upgrade AgentRegistry link:", address(upgraded.getAgentRegistry()));

        vm.stopBroadcast();
    }
}
