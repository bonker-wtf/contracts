// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {Bonker} from "../src/Bonker.sol";
import {BonkerPresaleEthToCreator} from "../src/extensions/BonkerPresaleEthToCreator.sol";
import {BonkerPresaleAllowlist} from "../src/extensions/BonkerPresaleAllowlist.sol";

/// @notice Deploy Presale + Allowlist extensions, then enable them on Factory.
contract DeployPresale is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("BONKER_PRIVATE_KEY");

        address owner = 0x21b109ce8E663FB63CF0B2529324A2e75AeAf87D;
        address factoryAddr = 0xD850DACe6c3E3B3cf09ABb92342Fab681013c8cB;
        address bonkerFeeRecipient = 0x1750d61A438aE6317b2Ee7De0A16201F68530C8F;

        Bonker factory = Bonker(factoryAddr);

        vm.startBroadcast(deployerKey);

        BonkerPresaleEthToCreator presale = new BonkerPresaleEthToCreator(owner, factoryAddr, bonkerFeeRecipient);
        console.log("Presale:", address(presale));

        BonkerPresaleAllowlist allowlist = new BonkerPresaleAllowlist(address(presale));
        console.log("PresaleAllowlist:", address(allowlist));

        // Enable allowlist on presale contract
        presale.setAllowlist(address(allowlist), true);

        // Enable presale extension on factory
        factory.setExtension(address(presale), true);

        vm.stopBroadcast();

        console.log("\n=== Presale Deployed ===");
        console.log("Presale:          ", address(presale));
        console.log("PresaleAllowlist: ", address(allowlist));
    }
}
