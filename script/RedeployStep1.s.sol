// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Bonker} from "../src/Bonker.sol";

/// @notice Redeploy only the Factory (BonkerToken bytecode changed).
///         FeeLocker and Allowlist are reused from previous deployment.
contract RedeployStep1 is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("BONKER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerKey);

        Bonker factory = new Bonker(deployer);
        console.log("Factory:", address(factory));

        vm.stopBroadcast();

        console.log("\n=== New Factory Deployed ===");
        console.log("Factory:", address(factory));
        console.log("\nNext: mine hook salts with this factory address");
    }
}
