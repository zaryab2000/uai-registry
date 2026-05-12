// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {TAPReputationRegistry} from "src/TAPReputationRegistry.sol";

interface IProxyAdmin {
    function upgradeAndCall(
        address proxy,
        address implementation,
        bytes calldata data
    ) external;
}

contract UpgradeTAPReputationRegistry is Script {
    function run() external {
        address proxy = vm.envAddress("TAP_REPUTATION_REGISTRY_PROXY");
        address proxyAdmin = vm.envAddress("TAP_REPUTATION_REGISTRY_PROXY_ADMIN");

        TAPReputationRegistry old = TAPReputationRegistry(proxy);
        console.log("Proxy:", proxy);
        console.log("ProxyAdmin:", proxyAdmin);
        console.log("Old TAPRegistry link:", address(old.getTAPRegistry()));

        vm.startBroadcast();

        TAPReputationRegistry newImpl = new TAPReputationRegistry();
        console.log("New Implementation:", address(newImpl));

        IProxyAdmin(proxyAdmin).upgradeAndCall(proxy, address(newImpl), "");
        console.log("Upgrade complete");

        TAPReputationRegistry upgraded = TAPReputationRegistry(proxy);
        console.log("Post-upgrade TAPRegistry link:", address(upgraded.getTAPRegistry()));

        vm.stopBroadcast();
    }
}
