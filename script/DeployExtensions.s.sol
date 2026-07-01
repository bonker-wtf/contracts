// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {Bonker} from "../src/Bonker.sol";
import {BonkerVault} from "../src/extensions/BonkerVault.sol";
import {BonkerUniv4EthDevBuy} from "../src/extensions/BonkerUniv4EthDevBuy.sol";

/// @notice Deploy Vault and DevBuy extensions, then enable them on Factory.
contract DeployExtensions is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("BONKER_PRIVATE_KEY");

        address factoryAddr = 0xD850DACe6c3E3B3cf09ABb92342Fab681013c8cB;
        address weth = 0x4200000000000000000000000000000000000006;
        address universalRouter = 0x6fF5693b99212Da76ad316178A184AB56D299b43;
        address permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

        Bonker factory = Bonker(factoryAddr);

        vm.startBroadcast(deployerKey);

        BonkerVault vault = new BonkerVault(factoryAddr);
        console.log("Vault:", address(vault));

        BonkerUniv4EthDevBuy devBuy = new BonkerUniv4EthDevBuy(factoryAddr, weth, universalRouter, permit2);
        console.log("DevBuy:", address(devBuy));

        factory.setExtension(address(vault), true);
        factory.setExtension(address(devBuy), true);

        vm.stopBroadcast();

        console.log("\n=== Extensions Deployed ===");
        console.log("Vault:  ", address(vault));
        console.log("DevBuy: ", address(devBuy));
    }
}
