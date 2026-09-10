// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/Script.sol";
import {ChainPinnedScript} from "./ChainPinnedScript.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IUniversalRouter} from "@uniswap/universal-router/contracts/interfaces/IUniversalRouter.sol";
import {Commands} from "@uniswap/universal-router/contracts/libraries/Commands.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

contract SellToken is ChainPinnedScript {
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant DYNAMIC_HOOK = 0x963E91A45148b39737b9DF10c5b897B55cA9e8cC;
    address constant UNIVERSAL_ROUTER = 0x6fF5693b99212Da76ad316178A184AB56D299b43;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    function run() external onlyChain(BASE_CHAIN_ID) {
        address token = vm.envAddress("TOKEN");
        uint256 deployerKey = vm.envUint("BONKER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        uint256 balance = IERC20(token).balanceOf(deployer);
        console.log("Token:", token);
        console.log("Balance:", balance);
        require(balance > 0, "No tokens to sell");

        // token < WETH, so token is currency0, WETH is currency1
        // selling token -> WETH means zeroForOne = true
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(token),
            currency1: Currency.wrap(WETH),
            fee: 0x800000,
            tickSpacing: 200,
            hooks: IHooks(DYNAMIC_HOOK)
        });

        vm.startBroadcast(deployerKey);

        // 1. Approve token to Permit2
        IERC20(token).approve(PERMIT2, type(uint256).max);

        // 2. Permit2 approve to Universal Router
        IPermit2(PERMIT2).approve(token, UNIVERSAL_ROUTER, uint160(balance), uint48(block.timestamp + 3600));

        // 3. Execute swap via Universal Router
        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));

        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE),
            uint8(Actions.SETTLE_ALL),
            uint8(Actions.TAKE_ALL)
        );

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: poolKey,
                zeroForOne: true,
                amountIn: uint128(balance),
                amountOutMinimum: 1,
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(token, balance);
        params[2] = abi.encode(WETH, uint256(1));

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        IUniversalRouter(UNIVERSAL_ROUTER).execute(commands, inputs, block.timestamp + 300);

        vm.stopBroadcast();

        uint256 wethAfter = IERC20(WETH).balanceOf(deployer);
        console.log("WETH received:", wethAfter);
    }
}
