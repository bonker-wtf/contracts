// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {Bonker} from "../src/Bonker.sol";
import {BonkerFeeLocker} from "../src/BonkerFeeLocker.sol";
import {BonkerLpLockerFeeConversion} from "../src/lp-lockers/BonkerLpLockerFeeConversion.sol";

/// @notice Deploy LpLocker separately (needs 200 optimizer runs to fit under 24KB)
///         and run the remaining factory config calls.
///
/// @dev Two things this script deploys that are easy to miss.
///
///      **`V4RouterSwap`.** The locker DELEGATECALLs it for the fee-conversion swap, because
///      that swap does not fit in the locker's EIP-170 budget. forge deploys and links it
///      automatically as part of this broadcast — but its address must be RECORDED, because
///      `verify-chain.sh` cannot verify the locker without `--libraries`. `deploy-chain.sh`
///      does that; a manual run has to read it out of the broadcast log (the CREATE2 entry
///      whose `contractName` is `V4RouterSwap`).
///
///      **`V4_ROUTER_HAS_MIN_HOP_PRICE`.** Which `IV4Router` exact-input params layout this
///      chain's UniversalRouter decodes — `config/chains.js`'s `v4RouterHasMinHopPrice`, false
///      on Base and true on Robinhood Chain (4663). It is a constructor immutable, so it is
///      chosen here and never again. `vm.envBool` reverting when it is unset is deliberate: a
///      wrong value is caught by no test, no verification and no read of the chain, only by a
///      creator whose `collectRewards` reverts with empty revert data. Same argument as
///      `DeployDevBuy.s.sol`; see `docs/UNIVERSAL-ROUTER-V4-SWAP-ENCODING.md`.
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
        bool v4RouterHasMinHopPrice = vm.envBool("V4_ROUTER_HAS_MIN_HOP_PRICE");

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
            poolManager,
            v4RouterHasMinHopPrice
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
