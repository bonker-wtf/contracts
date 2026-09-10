// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/Script.sol";
import {ChainPinnedScript} from "./ChainPinnedScript.sol";
import {Bonker} from "../src/Bonker.sol";
import {IBonker} from "../src/interfaces/IBonker.sol";
import {IBonkerVault} from "../src/extensions/interfaces/IBonkerVault.sol";
import {IBonkerUniv4EthDevBuy} from "../src/extensions/interfaces/IBonkerUniv4EthDevBuy.sol";
import {IBonkerLpLockerFeeConversion} from
    "../src/lp-lockers/interfaces/IBonkerLpLockerFeeConversion.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

/// @notice Test deploy tokens with Vault and DevBuy extensions on mainnet.
///         Deploys two tokens:
///           1. "Vault Test" — 5% supply locked in vault (7-day lockup, no vesting)
///           2. "DevBuy Test" — creator buy of 0.001 ETH bundled into deploy
contract TestExtensions is ChainPinnedScript {
    address constant FACTORY = 0xD850DACe6c3E3B3cf09ABb92342Fab681013c8cB;
    address constant DYNAMIC_HOOK = 0x963E91A45148b39737b9DF10c5b897B55cA9e8cC;
    address constant LP_LOCKER = 0xBf05b1d5E356f3219D0086A4e09c969ADbe2e7d0;
    address constant MEV_MODULE = 0x6a04057180F8cc02E18DabEE3f3437E438BE657A;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant VAULT = 0x26a4654E85CD8cc3Ba08dBC05418c63300624c8e;
    address constant DEVBUY = 0xc00Ab3631E82902f55B62EB95A0101eE2eb91a69;

    function run() external onlyChain(BASE_CHAIN_ID) {
        uint256 deployerKey = vm.envUint("BONKER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        console.log("Deployer:", deployer);

        // Shared pool/mev/locker config
        bytes memory feeData = abi.encode(
            uint24(10000), uint24(100000), uint256(30), uint256(120),
            int24(200), uint256(500000000), uint24(7500)
        );
        bytes memory poolData = abi.encode(address(0), bytes(""), feeData);
        bytes memory mevModuleData = abi.encode(uint24(666777), uint24(41673), uint256(15));

        IBonkerLpLockerFeeConversion.FeeIn[] memory feePref =
            new IBonkerLpLockerFeeConversion.FeeIn[](1);
        feePref[0] = IBonkerLpLockerFeeConversion.FeeIn.Both;
        bytes memory lockerData =
            abi.encode(IBonkerLpLockerFeeConversion.LpFeeConversionInfo({feePreference: feePref}));

        // ──────────────────────────────────────────────
        // Test 1: Deploy token with Vault extension
        // ──────────────────────────────────────────────
        console.log("\n=== Test 1: Token with Vault (5%, 7-day lockup) ===");

        IBonker.ExtensionConfig[] memory vaultExts = new IBonker.ExtensionConfig[](1);
        vaultExts[0] = IBonker.ExtensionConfig({
            extension: VAULT,
            msgValue: 0,
            extensionBps: 500, // 5%
            extensionData: abi.encode(
                IBonkerVault.VaultExtensionData({
                    admin: deployer,
                    lockupDuration: 7 days,
                    vestingDuration: 0
                })
            )
        });

        IBonker.DeploymentConfig memory vaultConfig =
            _baseConfig(deployer, "Vault Test Bonker", "VAULTTEST", poolData, mevModuleData, lockerData, vaultExts);

        vm.startBroadcast(deployerKey);
        address vaultToken = Bonker(FACTORY).deployToken(vaultConfig);
        vm.stopBroadcast();
        console.log("Vault token deployed:", vaultToken);

        // ──────────────────────────────────────────────
        // Test 2: Deploy token with DevBuy extension
        // ──────────────────────────────────────────────
        console.log("\n=== Test 2: Token with DevBuy (0.001 ETH) ===");

        IBonker.ExtensionConfig[] memory devBuyExts = new IBonker.ExtensionConfig[](1);
        devBuyExts[0] = IBonker.ExtensionConfig({
            extension: DEVBUY,
            msgValue: 0.001 ether,
            extensionBps: 0,
            extensionData: abi.encode(
                IBonkerUniv4EthDevBuy.Univ4EthDevBuyExtensionData({
                    pairedTokenPoolKey: PoolKey({
                        currency0: Currency.wrap(address(0)),
                        currency1: Currency.wrap(address(0)),
                        fee: 0,
                        tickSpacing: 0,
                        hooks: IHooks(address(0))
                    }),
                    pairedTokenAmountOutMinimum: 0,
                    recipient: deployer
                })
            )
        });

        IBonker.DeploymentConfig memory devBuyConfig =
            _baseConfig(deployer, "DevBuy Test Bonker", "DEVBUYTEST", poolData, mevModuleData, lockerData, devBuyExts);

        vm.startBroadcast(deployerKey);
        address devBuyToken = Bonker(FACTORY).deployToken{value: 0.001 ether}(devBuyConfig);
        vm.stopBroadcast();
        console.log("DevBuy token deployed:", devBuyToken);

        console.log("\n=== Both tests passed! ===");
    }

    function _baseConfig(
        address deployer,
        string memory name,
        string memory symbol,
        bytes memory poolData,
        bytes memory mevModuleData,
        bytes memory lockerData,
        IBonker.ExtensionConfig[] memory exts
    ) internal view returns (IBonker.DeploymentConfig memory) {
        int24[] memory tickLower = new int24[](5);
        int24[] memory tickUpper = new int24[](5);
        uint16[] memory positionBps = new uint16[](5);
        tickLower[0] = -230400; tickUpper[0] = -214000; positionBps[0] = 1000;
        tickLower[1] = -214000; tickUpper[1] = -155000; positionBps[1] = 5000;
        tickLower[2] = -202000; tickUpper[2] = -155000; positionBps[2] = 1500;
        tickLower[3] = -155000; tickUpper[3] = -120000; positionBps[3] = 2000;
        tickLower[4] = -141000; tickUpper[4] = -120000; positionBps[4] = 500;

        address[] memory admins = new address[](1);
        admins[0] = deployer;
        address[] memory recipients = new address[](1);
        recipients[0] = deployer;
        uint16[] memory rewardBps = new uint16[](1);
        rewardBps[0] = 10000;

        return IBonker.DeploymentConfig({
            tokenConfig: IBonker.TokenConfig({
                tokenAdmin: deployer,
                name: name,
                symbol: symbol,
                salt: keccak256(abi.encodePacked(name, block.timestamp)),
                image: "",
                metadata: "",
                context: "",
                originatingChainId: block.chainid
            }),
            poolConfig: IBonker.PoolConfig({
                hook: DYNAMIC_HOOK,
                pairedToken: WETH,
                tickIfToken0IsBonker: -230400,
                tickSpacing: 200,
                poolData: poolData
            }),
            lockerConfig: IBonker.LockerConfig({
                locker: LP_LOCKER,
                rewardAdmins: admins,
                rewardRecipients: recipients,
                rewardBps: rewardBps,
                tickLower: tickLower,
                tickUpper: tickUpper,
                positionBps: positionBps,
                lockerData: lockerData
            }),
            mevModuleConfig: IBonker.MevModuleConfig({
                mevModule: MEV_MODULE,
                mevModuleData: mevModuleData
            }),
            extensionConfigs: exts
        });
    }
}
