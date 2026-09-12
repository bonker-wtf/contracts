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

        // Owner of the new presale extension. Must match the broadcaster (BONKER_PRIVATE_KEY),
        // because this script's setAllowlist call is onlyOwner. BONKER_PRIVATE_KEY is now the
        // factory owner 0x6097… (ownership was consolidated off the original deployer 0x21b1…),
        // which is also why factory.setExtension below succeeds without a separate admin grant.
        // `vm.envOr` keeps Base's literals as the defaults, so the existing Base runbook is
        // unchanged and needs no new environment. Another chain overrides all three — without
        // that, this script would deploy a presale extension owned by a Base wallet and
        // registered against a factory address that holds no code on the target chain.
        address owner = vm.envOr("PRESALE_OWNER", address(0x6097DD26871b0c7811D52B674e7407a38F7E84e5));
        address factoryAddr = vm.envOr("FACTORY", address(0xD850DACe6c3E3B3cf09ABb92342Fab681013c8cB));
        address bonkerFeeRecipient =
            vm.envOr("TEAM_FEE_RECIPIENT", address(0x1750d61A438aE6317b2Ee7De0A16201F68530C8F));

        console.log("Chain:", block.chainid);

        Bonker factory = Bonker(factoryAddr);

        vm.startBroadcast(deployerKey);

        BonkerPresaleEthToCreator presale = new BonkerPresaleEthToCreator(owner, factoryAddr, bonkerFeeRecipient);
        console.log("Presale:", address(presale));

        BonkerPresaleAllowlist allowlist = new BonkerPresaleAllowlist(address(presale));
        console.log("PresaleAllowlist:", address(allowlist));

        // Enable allowlist on presale contract
        presale.setAllowlist(address(allowlist), true);

        // Make the owner a presale admin so it can call startPresale (which is onlyAdmin,
        // not onlyOwner) from /admin immediately after deploy without a separate tx.
        presale.setAdmin(owner, true);

        // Enable presale extension on factory
        factory.setExtension(address(presale), true);

        vm.stopBroadcast();

        console.log("\n=== Presale Deployed ===");
        console.log("Presale:          ", address(presale));
        console.log("PresaleAllowlist: ", address(allowlist));
    }
}
