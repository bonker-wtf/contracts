// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {Bonker} from "../src/Bonker.sol";
import {BonkerFeeLocker} from "../src/BonkerFeeLocker.sol";
import {BonkerLpLockerFeeConversion} from "../src/lp-lockers/BonkerLpLockerFeeConversion.sol";

/// @notice Deploy LpLocker separately (needs 200 optimizer runs to fit under 24KB)
///         and run the remaining factory config calls.
contract DeployLpLocker is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("BONKER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        address feeLockerAddr = vm.envAddress("FEE_LOCKER");
        address factoryAddr = vm.envAddress("FACTORY");
        address dynamicHookAddr = vm.envAddress("DYNAMIC_HOOK");
        address staticHookAddr = vm.envAddress("STATIC_HOOK");
        address poolManager = vm.envAddress("POOL_MANAGER");
        address positionManager = vm.envAddress("POSITION_MANAGER");
        address permit2 = vm.envAddress("PERMIT2");
        address universalRouter = vm.envAddress("UNIVERSAL_ROUTER");

        BonkerFeeLocker feeLocker = BonkerFeeLocker(feeLockerAddr);
        Bonker factory = Bonker(factoryAddr);

        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerKey);

        // Deploy LpLocker
        BonkerLpLockerFeeConversion lpLocker = new BonkerLpLockerFeeConversion(
            deployer,
            factoryAddr,
            feeLockerAddr,
            positionManager,
            permit2,
            universalRouter,
            poolManager
        );
        console.log("LpLocker:", address(lpLocker));

        // FeeLocker: add LpLocker as depositor
        feeLocker.addDepositor(address(lpLocker));

        // Factory: enable locker for each hook
        factory.setLocker(address(lpLocker), dynamicHookAddr, true);
        factory.setLocker(address(lpLocker), staticHookAddr, true);

        vm.stopBroadcast();

        console.log("\n=== LpLocker Deployed ===");
        console.log("LpLocker:", address(lpLocker));
    }
}
