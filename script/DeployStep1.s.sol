// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {Bonker} from "../src/Bonker.sol";
import {BonkerFeeLocker} from "../src/BonkerFeeLocker.sol";
import {BonkerPoolExtensionAllowlist} from "../src/hooks/BonkerPoolExtensionAllowlist.sol";

/// @notice Step 1: Deploy FeeLocker, Allowlist, Factory.
///         After this, run MineHookAddress.s.sol with FACTORY and POOL_EXTENSION_ALLOWLIST
///         from the output, then run DeployStep2.s.sol.
contract DeployStep1 is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("BONKER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerKey);

        BonkerFeeLocker feeLocker = new BonkerFeeLocker(deployer);
        console.log("FeeLocker:", address(feeLocker));

        BonkerPoolExtensionAllowlist allowlist = new BonkerPoolExtensionAllowlist(deployer);
        console.log("PoolExtensionAllowlist:", address(allowlist));

        Bonker factory = new Bonker(deployer);
        console.log("Factory:", address(factory));

        vm.stopBroadcast();

        console.log("\n=== Step 1 Complete ===");
        console.log("FeeLocker:     ", address(feeLocker));
        console.log("Allowlist:     ", address(allowlist));
        console.log("Factory:       ", address(factory));
    }
}
