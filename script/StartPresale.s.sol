// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/Script.sol";
import {ChainPinnedScript} from "./ChainPinnedScript.sol";
import {IBonker} from "../src/interfaces/IBonker.sol";
import {IBonkerAirdropV2} from "../src/extensions/interfaces/IBonkerAirdropV2.sol";
import {BonkerPresaleEthToCreator} from "../src/extensions/BonkerPresaleEthToCreator.sol";
import {IBonkerLpLockerFeeConversion} from
    "../src/lp-lockers/interfaces/IBonkerLpLockerFeeConversion.sol";

/// @notice Start a TBONK test presale on mainnet.
///         Airdrop (10%) + Presale (20%), min 0.001 ETH, max 0.01 ETH, 1 week.
contract StartPresale is ChainPinnedScript {
    address constant FACTORY = 0xD850DACe6c3E3B3cf09ABb92342Fab681013c8cB;
    address constant DYNAMIC_HOOK = 0x963E91A45148b39737b9DF10c5b897B55cA9e8cC;
    address constant LP_LOCKER = 0xBf05b1d5E356f3219D0086A4e09c969ADbe2e7d0;
    address constant MEV_MODULE = 0x6a04057180F8cc02E18DabEE3f3437E438BE657A;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant AIRDROP = 0xa727da00eDd0F98Dc5Fb5D3b9eA09646CB809A87;
    address constant PRESALE = 0xC3E89329777183Ebf4fBE02769c98799B9Ff93b4;

    function run() external onlyChain(BASE_CHAIN_ID) {
        uint256 deployerKey = vm.envUint("BONKER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        console.log("Deployer:", deployer);

        // --- Shared pool/mev/locker config (same as TestExtensions) ---
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

        // --- Extensions: Airdrop (10%) + Presale (20%, must be last) ---
        IBonker.ExtensionConfig[] memory exts = new IBonker.ExtensionConfig[](2);

        // 1. Airdrop V2 — 10%, merkle root = 0 (admin sets later), 1 day lockup, no vesting
        exts[0] = IBonker.ExtensionConfig({
            extension: AIRDROP,
            msgValue: 0,
            extensionBps: 1000, // 10%
            extensionData: abi.encode(
                IBonkerAirdropV2.AirdropV2ExtensionData({
                    admin: deployer,
                    merkleRoot: bytes32(0),
                    lockupDuration: 1 days,
                    vestingDuration: 0
                })
            )
        });

        // 2. Presale — 20%, extensionData will be overwritten by startPresale()
        exts[1] = IBonker.ExtensionConfig({
            extension: PRESALE,
            msgValue: 0,
            extensionBps: 2000, // 20%
            extensionData: abi.encode(uint256(0))
        });

        // --- Build deployment config ---
        IBonker.DeploymentConfig memory config = _baseConfig(
            deployer, "Test Bonk", "TBONK", poolData, mevModuleData, lockerData, exts
        );

        // --- Start presale ---
        vm.startBroadcast(deployerKey);

        // Ensure deployer is admin on presale contract
        BonkerPresaleEthToCreator presale = BonkerPresaleEthToCreator(PRESALE);
        if (!presale.admins(deployer)) {
            console.log("Setting deployer as presale admin...");
            presale.setAdmin(deployer, true);
        }

        uint256 presaleId = presale.startPresale({
            deploymentConfig: config,
            minEthGoal: 0.001 ether,
            maxEthGoal: 0.01 ether,
            presaleDuration: 7 days,
            presaleOwner: deployer,
            lockupDuration: 7 days,
            vestingDuration: 7 days,
            allowlist: address(0),
            allowlistInitializationData: bytes("")
        });

        vm.stopBroadcast();

        console.log("Presale started! ID:", presaleId);
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
