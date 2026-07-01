// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {Bonker} from "../src/Bonker.sol";
import {BonkerFeeLocker} from "../src/BonkerFeeLocker.sol";
import {BonkerHookDynamicFeeV2} from "../src/hooks/BonkerHookDynamicFeeV2.sol";
import {BonkerHookStaticFeeV2} from "../src/hooks/BonkerHookStaticFeeV2.sol";
import {BonkerSniperAuctionV2} from "../src/mev-modules/BonkerSniperAuctionV2.sol";
import {BonkerAirdropV2} from "../src/extensions/BonkerAirdropV2.sol";

/// @notice Redeploy hooks + MevModule + Airdrop and configure factory.
///         LpLocker deployed separately via DeployLpLocker.s.sol (needs 200 optimizer runs).
///         Reuses existing FeeLocker and Allowlist.
contract RedeployStep2 is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("BONKER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        // Existing (unchanged)
        address feeLockerAddr = vm.envAddress("FEE_LOCKER");
        address allowlistAddr = vm.envAddress("POOL_EXTENSION_ALLOWLIST");

        // New factory from RedeployStep1
        address factoryAddr = vm.envAddress("FACTORY");

        // Infrastructure
        address poolManager = vm.envAddress("POOL_MANAGER");
        address weth = vm.envAddress("WETH");
        address teamFeeRecipient = vm.envAddress("TEAM_FEE_RECIPIENT");

        // Mined salts
        uint256 dynamicHookSalt = vm.envUint("DYNAMIC_HOOK_SALT");
        uint256 staticHookSalt = vm.envUint("STATIC_HOOK_SALT");

        BonkerFeeLocker feeLocker = BonkerFeeLocker(feeLockerAddr);
        Bonker factory = Bonker(factoryAddr);

        console.log("Deployer:", deployer);
        console.log("Factory:", factoryAddr);

        vm.startBroadcast(deployerKey);

        // Dynamic Hook (CREATE2)
        BonkerHookDynamicFeeV2 dynamicHook = new BonkerHookDynamicFeeV2{
            salt: bytes32(dynamicHookSalt)
        }(poolManager, factoryAddr, allowlistAddr, weth);
        console.log("DynamicHook:", address(dynamicHook));

        // Static Hook (CREATE2)
        BonkerHookStaticFeeV2 staticHook = new BonkerHookStaticFeeV2{
            salt: bytes32(staticHookSalt)
        }(poolManager, factoryAddr, allowlistAddr, weth);
        console.log("StaticHook:", address(staticHook));

        // MevModule
        BonkerSniperAuctionV2 mevModule =
            new BonkerSniperAuctionV2(deployer, factoryAddr, feeLockerAddr, weth);
        console.log("MevModule:", address(mevModule));

        // Airdrop Extension
        BonkerAirdropV2 airdrop = new BonkerAirdropV2(factoryAddr);
        console.log("Airdrop:", address(airdrop));

        // --- Config ---

        // FeeLocker: add mev module depositor
        feeLocker.addDepositor(address(mevModule));

        // Factory: enable hooks
        factory.setHook(address(dynamicHook), true);
        factory.setHook(address(staticHook), true);

        // Factory: enable mev module
        factory.setMevModule(address(mevModule), true);

        // Factory: enable airdrop extension
        factory.setExtension(address(airdrop), true);

        // Factory: set team fee recipient
        factory.setTeamFeeRecipient(teamFeeRecipient);

        // Factory: allow deployments
        factory.setDeprecated(false);

        vm.stopBroadcast();

        console.log("\n=== Redeploy Step 2 Complete ===");
        console.log("DynamicHook:", address(dynamicHook));
        console.log("StaticHook: ", address(staticHook));
        console.log("MevModule:  ", address(mevModule));
        console.log("Airdrop:    ", address(airdrop));
        console.log("\nNext: deploy LpLocker with FOUNDRY_PROFILE=lplocker");
    }
}
