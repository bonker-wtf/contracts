// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {Bonker} from "../src/Bonker.sol";
import {BonkerFeeLocker} from "../src/BonkerFeeLocker.sol";
import {BonkerHookDynamicFeeV2} from "../src/hooks/BonkerHookDynamicFeeV2.sol";
import {BonkerHookStaticFeeV2} from "../src/hooks/BonkerHookStaticFeeV2.sol";
import {BonkerSniperAuctionV2} from "../src/mev-modules/BonkerSniperAuctionV2.sol";
import {BonkerMevDescendingFees} from "../src/mev-modules/BonkerMevDescendingFees.sol";
import {BonkerAirdropV2} from "../src/extensions/BonkerAirdropV2.sol";

/// @notice Step 2: Deploy hooks (CREATE2 via deterministic proxy), MevModule, Airdrop.
///         Then configure the default-profile modules on the factory.
///         LpLocker is deployed separately via DeployLpLocker.s.sol (needs 200 optimizer runs).
///
/// Requires Step 1 outputs + mined salts from MineHookAddress.s.sol.
/// Hook salts must be mined using CREATE2 deployer 0x4e59b44847b379578588920cA78FbF26c0B4956C.
///
/// MEV_MODULE_KIND selects the module, defaulting to "sniper-auction-v2" so Base's deployment
/// is byte-for-byte what it has always been. The choice is not cosmetic: BonkerSniperAuctionV2
/// schedules its auction with `block.number + blocksBetweenAuction` and BonkerSniperUtilV2
/// requires `block.number == nextAuctionBlock` exactly. On an Arbitrum-stack chain Solidity's
/// `block.number` is an L1 Ethereum block number, not that chain's height — measured on
/// Robinhood Chain 2026-09-02: the EVM saw 25_889_336 while the L2 head was 52_542_808, so a
/// "block" there is ~12s of L1 rather than the chain's own cadence, and every L2 block inside
/// one L1 block shares a number. "descending-fees" selects BonkerMevDescendingFees, which is
/// pure `block.timestamp`, takes no constructor arguments, and gives the same descending-fee
/// sniper protection without counting blocks at all.
contract DeployStep2 is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("BONKER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        // Step 1 outputs
        address feeLockerAddr = vm.envAddress("FEE_LOCKER");
        address allowlistAddr = vm.envAddress("POOL_EXTENSION_ALLOWLIST");
        address factoryAddr = vm.envAddress("FACTORY");

        // Infrastructure
        address poolManager = vm.envAddress("POOL_MANAGER");
        address weth = vm.envAddress("WETH");
        address teamFeeRecipient = vm.envAddress("TEAM_FEE_RECIPIENT");

        // Mined salts
        uint256 dynamicHookSalt = vm.envUint("DYNAMIC_HOOK_SALT");
        uint256 staticHookSalt = vm.envUint("STATIC_HOOK_SALT");

        string memory mevKind = vm.envOr("MEV_MODULE_KIND", string("sniper-auction-v2"));
        bool useDescendingFees =
            keccak256(bytes(mevKind)) == keccak256(bytes("descending-fees"));
        if (!useDescendingFees && keccak256(bytes(mevKind)) != keccak256(bytes("sniper-auction-v2"))) {
            revert("MEV_MODULE_KIND must be 'sniper-auction-v2' or 'descending-fees'");
        }

        // Cast existing contracts
        BonkerFeeLocker feeLocker = BonkerFeeLocker(feeLockerAddr);
        Bonker factory = Bonker(factoryAddr);

        console.log("Deployer:", deployer);
        console.log("Factory:", factoryAddr);

        vm.startBroadcast(deployerKey);

        // 4. Dynamic Hook (CREATE2 with mined salt)
        BonkerHookDynamicFeeV2 dynamicHook = new BonkerHookDynamicFeeV2{
            salt: bytes32(dynamicHookSalt)
        }(poolManager, factoryAddr, allowlistAddr, weth);
        console.log("DynamicHook:", address(dynamicHook));

        // 5. Static Hook (CREATE2 with mined salt)
        BonkerHookStaticFeeV2 staticHook = new BonkerHookStaticFeeV2{
            salt: bytes32(staticHookSalt)
        }(poolManager, factoryAddr, allowlistAddr, weth);
        console.log("StaticHook:", address(staticHook));

        // 6. MevModule
        address mevModule;
        if (useDescendingFees) {
            mevModule = address(new BonkerMevDescendingFees());
            console.log("MevModule (BonkerMevDescendingFees):", mevModule);
        } else {
            mevModule = address(new BonkerSniperAuctionV2(deployer, factoryAddr, feeLockerAddr, weth));
            console.log("MevModule (BonkerSniperAuctionV2):", mevModule);
        }

        // 7. Airdrop Extension
        BonkerAirdropV2 airdrop = new BonkerAirdropV2(factoryAddr);
        console.log("Airdrop:", address(airdrop));

        // --- Post-deploy config ---

        // FeeLocker: add mev module depositor
        // BonkerMevDescendingFees never deposits fees (it only adjusts the swap fee), so this is
        // a no-op for that module rather than a requirement — harmless, and keeps one code path.
        feeLocker.addDepositor(mevModule);

        // Factory: enable hooks
        factory.setHook(address(dynamicHook), true);
        factory.setHook(address(staticHook), true);

        // Factory: enable mev module
        factory.setMevModule(mevModule, true);

        // Factory: enable airdrop extension
        factory.setExtension(address(airdrop), true);

        // Factory: set team fee recipient
        factory.setTeamFeeRecipient(teamFeeRecipient);

        // Factory: undeprecate (allow deployments)
        factory.setDeprecated(false);

        vm.stopBroadcast();

        console.log("\n=== Step 2 Complete - Core Modules Deployed ===");
        console.log("FeeLocker:     ", feeLockerAddr);
        console.log("Allowlist:     ", allowlistAddr);
        console.log("Factory:       ", factoryAddr);
        console.log("DynamicHook:   ", address(dynamicHook));
        console.log("StaticHook:    ", address(staticHook));
        console.log("MevModule:     ", mevModule);
        console.log("Airdrop:       ", address(airdrop));
        console.log("\nNext: deploy LpLocker with FOUNDRY_PROFILE=lplocker");
    }
}
