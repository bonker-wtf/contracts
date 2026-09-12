// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {Bonker} from "../src/Bonker.sol";
import {BonkerVault} from "../src/extensions/BonkerVault.sol";

/// @notice Deploy the Vault extension and enable it on the factory.
///
/// The dev-buy extension used to be deployed here too and now has its own `DeployDevBuy`
/// script, because it is the one piece that gets replaced on its own — see that script's
/// header for why.
///
/// Every address is read from the environment. It used to hardcode Base's factory, WETH and
/// UniversalRouter, which meant pointing this script at another chain's `--rpc-url` deployed
/// extensions wired to contracts that do not exist there — a DevBuy holding Base's router
/// address deploys fine, enables fine, and reverts only when a creator's first dev-buy runs.
/// `vm.envAddress` reverts on an unset variable, so a missing value fails before broadcast.
contract DeployExtensions is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("BONKER_PRIVATE_KEY");

        address factoryAddr = vm.envAddress("FACTORY");

        Bonker factory = Bonker(factoryAddr);

        console.log("Chain:", block.chainid);
        console.log("Factory:", factoryAddr);

        vm.startBroadcast(deployerKey);

        BonkerVault vault = new BonkerVault(factoryAddr);
        console.log("Vault:", address(vault));

        factory.setExtension(address(vault), true);

        vm.stopBroadcast();

        console.log("\n=== Extensions Deployed ===");
        console.log("Vault:  ", address(vault));
    }
}
