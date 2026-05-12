// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {TAPRegistry} from "src/TAPRegistry.sol";
import {IUEAFactory} from "src/interfaces/IUEAFactory.sol";

interface IProxyAdmin {
    function upgradeAndCall(
        address proxy,
        address implementation,
        bytes calldata data
    ) external;
}

contract UpgradeTAPRegistry is Script {
    address constant UEA_FACTORY = 0x00000000000000000000000000000000000000eA;

    function run() external {
        address proxy = vm.envAddress("TAP_REGISTRY_PROXY");
        address proxyAdmin = vm.envAddress("TAP_REGISTRY_PROXY_ADMIN");

        TAPRegistry oldImpl = TAPRegistry(proxy);
        console.log("Proxy:", proxy);
        console.log("ProxyAdmin:", proxyAdmin);
        console.log("Old ueaFactory:", address(oldImpl.ueaFactory()));

        vm.startBroadcast();

        TAPRegistry newImpl = new TAPRegistry(IUEAFactory(UEA_FACTORY));
        console.log("New Implementation:", address(newImpl));

        IProxyAdmin(proxyAdmin).upgradeAndCall(proxy, address(newImpl), "");
        console.log("Upgrade complete");

        TAPRegistry upgraded = TAPRegistry(proxy);
        console.log("Post-upgrade ueaFactory:", address(upgraded.ueaFactory()));

        vm.stopBroadcast();
    }
}
