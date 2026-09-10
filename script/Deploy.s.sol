// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {Bonker} from "../src/Bonker.sol";
import {BonkerFeeLocker} from "../src/BonkerFeeLocker.sol";
import {BonkerHookDynamicFeeV2} from "../src/hooks/BonkerHookDynamicFeeV2.sol";
import {BonkerHookStaticFeeV2} from "../src/hooks/BonkerHookStaticFeeV2.sol";
import {BonkerPoolExtensionAllowlist} from "../src/hooks/BonkerPoolExtensionAllowlist.sol";
import {BonkerLpLockerFeeConversion} from "../src/lp-lockers/BonkerLpLockerFeeConversion.sol";
import {BonkerSniperAuctionV2} from "../src/mev-modules/BonkerSniperAuctionV2.sol";
import {BonkerAirdropV2} from "../src/extensions/BonkerAirdropV2.sol";

/// @notice Deploys the full custom factory stack.
///
/// Deploy order (dependency chain):
///   1. BonkerFeeLocker (no deps)
///   2. BonkerPoolExtensionAllowlist (no deps)
///   3. Bonker factory (no deps)
///   4. BonkerHookDynamicFeeV2 (needs poolManager, factory, allowlist, weth)
///   5. BonkerHookStaticFeeV2  (same deps)
///   6. BonkerLpLockerFeeConversion (needs factory, feeLocker, poolManager, permit2, universalRouter, weth)
///   7. BonkerSniperAuctionV2 (needs factory, feeLocker, weth)
///   8. BonkerAirdropV2 (needs factory)
///
/// Post-deploy config:
///   - Factory: enable hooks, lockers, mev modules, extensions
///   - FeeLocker: add LpLocker as depositor
///   - Factory: set team fee recipient
///   - Factory: undeprecate
///
/// Required env vars:
///   DEPLOYER_PRIVATE_KEY - private key for deployment
///   POOL_MANAGER         - Uniswap V4 PoolManager on Base
///   POSITION_MANAGER     - Uniswap V4 PositionManager on Base
///   WETH                 - WETH address on Base
///   PERMIT2              - Permit2 address on Base
///   UNIVERSAL_ROUTER     - Universal Router address on Base
///   TEAM_FEE_RECIPIENT   - address to receive team fees
///   DYNAMIC_HOOK_SALT    - CREATE2 salt from MineHookAddress (decimal)
///   STATIC_HOOK_SALT     - CREATE2 salt from MineHookAddress (decimal)
contract Deploy is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        address poolManager = vm.envAddress("POOL_MANAGER");
        address weth = vm.envAddress("WETH");
        address permit2 = vm.envAddress("PERMIT2");
        address universalRouter = vm.envAddress("UNIVERSAL_ROUTER");
        address teamFeeRecipient = vm.envAddress("TEAM_FEE_RECIPIENT");
        address positionManager = vm.envAddress("POSITION_MANAGER");
        bool v4RouterHasMinHopPrice = vm.envBool("V4_ROUTER_HAS_MIN_HOP_PRICE");
        uint256 dynamicHookSalt = vm.envUint("DYNAMIC_HOOK_SALT");
        uint256 staticHookSalt = vm.envUint("STATIC_HOOK_SALT");

        console.log("Deployer:", deployer);
        console.log("Pool Manager:", poolManager);

        vm.startBroadcast(deployerKey);

        // 1. FeeLocker
        BonkerFeeLocker feeLocker = new BonkerFeeLocker(deployer);
        console.log("FeeLocker:", address(feeLocker));

        // 2. PoolExtensionAllowlist
        BonkerPoolExtensionAllowlist allowlist = new BonkerPoolExtensionAllowlist(deployer);
        console.log("PoolExtensionAllowlist:", address(allowlist));

        // 3. Factory
        Bonker factory = new Bonker(deployer);
        console.log("Factory:", address(factory));

        // 4. Dynamic Hook (CREATE2 with mined salt)
        BonkerHookDynamicFeeV2 dynamicHook = new BonkerHookDynamicFeeV2{
            salt: bytes32(dynamicHookSalt)
        }(poolManager, address(factory), address(allowlist), weth);
        console.log("DynamicHook:", address(dynamicHook));

        // 5. Static Hook (CREATE2 with mined salt)
        BonkerHookStaticFeeV2 staticHook = new BonkerHookStaticFeeV2{
            salt: bytes32(staticHookSalt)
        }(poolManager, address(factory), address(allowlist), weth);
        console.log("StaticHook:", address(staticHook));

        // 6. LpLocker
        BonkerLpLockerFeeConversion lpLocker = new BonkerLpLockerFeeConversion(
            deployer,
            address(factory),
            address(feeLocker),
            positionManager,
            permit2,
            universalRouter,
            poolManager,
            v4RouterHasMinHopPrice
        );
        console.log("LpLocker:", address(lpLocker));

        // 7. MevModule
        BonkerSniperAuctionV2 mevModule =
            new BonkerSniperAuctionV2(deployer, address(factory), address(feeLocker), weth);
        console.log("MevModule:", address(mevModule));

        // 8. Airdrop Extension
        BonkerAirdropV2 airdrop = new BonkerAirdropV2(address(factory));
        console.log("Airdrop:", address(airdrop));

        // --- Post-deploy config ---

        // FeeLocker: add LpLocker as depositor
        feeLocker.addDepositor(address(lpLocker));
        // FeeLocker: add MevModule as depositor (it stores auction payments)
        feeLocker.addDepositor(address(mevModule));

        // Factory: enable hooks
        factory.setHook(address(dynamicHook), true);
        factory.setHook(address(staticHook), true);

        // Factory: enable locker for each hook
        factory.setLocker(address(lpLocker), address(dynamicHook), true);
        factory.setLocker(address(lpLocker), address(staticHook), true);

        // Factory: enable mev module
        factory.setMevModule(address(mevModule), true);

        // Factory: enable airdrop extension
        factory.setExtension(address(airdrop), true);

        // Factory: set team fee recipient
        factory.setTeamFeeRecipient(teamFeeRecipient);

        // Factory: undeprecate (allow deployments)
        factory.setDeprecated(false);

        vm.stopBroadcast();

        console.log("\n=== Deployment Complete ===");
        console.log("FeeLocker:     ", address(feeLocker));
        console.log("Allowlist:     ", address(allowlist));
        console.log("Factory:       ", address(factory));
        console.log("DynamicHook:   ", address(dynamicHook));
        console.log("StaticHook:    ", address(staticHook));
        console.log("LpLocker:      ", address(lpLocker));
        console.log("MevModule:     ", address(mevModule));
        console.log("Airdrop:       ", address(airdrop));
    }
}
