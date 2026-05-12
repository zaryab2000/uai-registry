// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {TAPRegistry} from "src/TAPRegistry.sol";

contract VerifyDeployment is Script {
    function run(
        address proxyAddress
    ) external view {
        TAPRegistry registry = TAPRegistry(proxyAddress);

        bool registered = registry.isRegistered(0);
        console.log("isRegistered(0):", registered);

        address ueaFactory = address(registry.ueaFactory());
        console.log("ueaFactory:", ueaFactory);

        console.log("supportsERC721:", registry.supportsInterface(0x80ac58cd));
        console.log("supportsERC165:", registry.supportsInterface(0x01ffc9a7));
    }
}
