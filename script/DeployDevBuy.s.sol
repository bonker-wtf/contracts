// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Bonker} from "../src/Bonker.sol";
import {BonkerUniv4EthDevBuy} from "../src/extensions/BonkerUniv4EthDevBuy.sol";
import {Script, console} from "forge-std/Script.sol";

/// @notice Deploy the dev-buy extension and enable it on the factory.
///
/// Split out of `DeployExtensions` because the dev-buy extension is the piece of the stack most
/// likely to need a SECOND deployment on a chain that already has everything else. It is the
/// only contract whose correctness depends on a property of somebody else's contract — the
/// chain's UniversalRouter — rather than on our own addresses, and Robinhood Chain proved that
/// is not hypothetical: the first one there emitted stock `IV4Router` params to a forked router
/// and reverted every creator buy with empty revert data. Redeploying it should not mean
/// redeploying the vault.
///
/// `V4_ROUTER_HAS_MIN_HOP_PRICE` is the whole point of this script existing separately. Set it
/// from `config/chains.js`'s `v4RouterHasMinHopPrice` — `deploy-chain.sh` does that for you.
/// `vm.envBool` reverts when it is unset, which is the intended behaviour: a wrong value here is
/// not caught by any test, any verification, or any read of the chain, only by a creator's
/// launch reverting after their token already exists.
///
/// Set `OLD_DEVBUY` to the address this one supersedes and it is disabled in the same run.
/// That matters because `Bonker.enabledExtensions` is private: nothing off-chain can list which
/// extensions a factory will accept, so a superseded-but-still-enabled extension stays usable
/// by anyone who hand-builds the calldata, and stays invisible.
contract DeployDevBuy is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("BONKER_PRIVATE_KEY");

        address factoryAddr = vm.envAddress("FACTORY");
        address weth = vm.envAddress("WETH");
        address universalRouter = vm.envAddress("UNIVERSAL_ROUTER");
        address permit2 = vm.envAddress("PERMIT2");
        bool v4RouterHasMinHopPrice = vm.envBool("V4_ROUTER_HAS_MIN_HOP_PRICE");
        address oldDevBuy = vm.envOr("OLD_DEVBUY", address(0));

        Bonker factory = Bonker(factoryAddr);

        console.log("Chain:", block.chainid);
        console.log("Factory:", factoryAddr);
        console.log("UniversalRouter:", universalRouter);
        console.log("v4RouterHasMinHopPrice:", v4RouterHasMinHopPrice);

        vm.startBroadcast(deployerKey);

        BonkerUniv4EthDevBuy devBuy = new BonkerUniv4EthDevBuy(
            factoryAddr, weth, universalRouter, permit2, v4RouterHasMinHopPrice
        );
        console.log("DevBuy:", address(devBuy));

        factory.setExtension(address(devBuy), true);

        if (oldDevBuy != address(0)) {
            factory.setExtension(oldDevBuy, false);
            console.log("Disabled superseded DevBuy:", oldDevBuy);
        }

        vm.stopBroadcast();

        console.log("\n=== DevBuy Deployed ===");
        console.log("DevBuy: ", address(devBuy));
    }
}
