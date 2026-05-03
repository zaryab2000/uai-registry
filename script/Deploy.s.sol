// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {UAIRegistry} from "src/UAIRegistry.sol";
import {IUEAFactory} from "src/interfaces/IUEAFactory.sol";
import {
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract Deploy is Script {
    address constant UEA_FACTORY = 0x00000000000000000000000000000000000000eA;

    function run() external {
        address deployer = msg.sender;

        vm.startBroadcast();

        UAIRegistry impl = new UAIRegistry(IUEAFactory(UEA_FACTORY));
        console.log("Implementation:", address(impl));

        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(impl),
            deployer,
            abi.encodeCall(UAIRegistry.initialize, (deployer, deployer))
        );
        console.log("Proxy:", address(proxy));

        UAIRegistry registry = UAIRegistry(address(proxy));
        console.log("ueaFactory:", address(registry.ueaFactory()));

        vm.stopBroadcast();
    }
}
