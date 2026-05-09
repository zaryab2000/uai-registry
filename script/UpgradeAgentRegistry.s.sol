// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {AgentRegistry} from "src/AgentRegistry.sol";
import {IUEAFactory} from "src/interfaces/IUEAFactory.sol";

interface IProxyAdmin {
    function upgradeAndCall(
        address proxy,
        address implementation,
        bytes calldata data
    ) external;
}

contract UpgradeAgentRegistry is Script {
    address constant UEA_FACTORY = 0x00000000000000000000000000000000000000eA;

    function run() external {
        address proxy = vm.envAddress("AGENT_REGISTRY_PROXY");
        address proxyAdmin = vm.envAddress("AGENT_REGISTRY_PROXY_ADMIN");

        AgentRegistry oldImpl = AgentRegistry(proxy);
        console.log("Proxy:", proxy);
        console.log("ProxyAdmin:", proxyAdmin);
        console.log("Old ueaFactory:", address(oldImpl.ueaFactory()));

        vm.startBroadcast();

        AgentRegistry newImpl = new AgentRegistry(IUEAFactory(UEA_FACTORY));
        console.log("New Implementation:", address(newImpl));

        IProxyAdmin(proxyAdmin).upgradeAndCall(proxy, address(newImpl), "");
        console.log("Upgrade complete");

        AgentRegistry upgraded = AgentRegistry(proxy);
        console.log("Post-upgrade ueaFactory:", address(upgraded.ueaFactory()));

        vm.stopBroadcast();
    }
}
