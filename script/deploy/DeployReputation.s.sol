// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {TAPReputationRegistry} from "src/TAPReputationRegistry.sol";
import {
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract DeployReputation is Script {
    function run() external {
        address deployer = msg.sender;
        address TAPRegistryProxy = vm.envAddress("TAP_REGISTRY_PROXY");
        address reporter = vm.envAddress("INITIAL_REPORTER");
        address slasher = vm.envAddress("INITIAL_SLASHER");

        vm.startBroadcast();

        TAPReputationRegistry impl = new TAPReputationRegistry();
        console.log("Implementation:", address(impl));

        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(impl),
            deployer,
            abi.encodeCall(TAPReputationRegistry.initialize, (deployer, deployer, TAPRegistryProxy))
        );
        console.log("Proxy:", address(proxy));

        TAPReputationRegistry registry = TAPReputationRegistry(address(proxy));

        registry.grantRole(registry.REPORTER_ROLE(), reporter);
        console.log("Reporter granted:", reporter);

        registry.grantRole(registry.SLASHER_ROLE(), slasher);
        console.log("Slasher granted:", slasher);

        vm.stopBroadcast();
    }
}
