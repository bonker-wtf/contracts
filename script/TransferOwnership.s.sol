// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/Script.sol";
import {ChainPinnedScript} from "./ChainPinnedScript.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface IBonkerFactory {
    function claimTeamFees(address token) external;
    function owner() external view returns (address);
    function teamFeeRecipient() external view returns (address);
    function transferOwnership(address newOwner) external;
}

interface IBonkerFeeLocker {
    function availableFees(address feeOwner, address token) external view returns (uint256);
    function claim(address feeOwner, address token) external;
    function owner() external view returns (address);
    function transferOwnership(address newOwner) external;
}

interface IBonkerLpLocker {
    function withdrawETH(address recipient) external;
    function withdrawERC20(address token, address recipient) external;
    function owner() external view returns (address);
    function transferOwnership(address newOwner) external;
}

interface IBonkerPresale {
    function setBonkerFeeRecipient(address recipient) external;
    function bonkerFeeRecipient() external view returns (address);
    function owner() external view returns (address);
    function transferOwnership(address newOwner) external;
}

contract TransferOwnership is ChainPinnedScript {
    // Deployed contract addresses
    address constant FACTORY = 0xD850DACe6c3E3B3cf09ABb92342Fab681013c8cB;
    address constant FEE_LOCKER = 0x473e52D89bE6ea78f94d1b5c62Bd1f01b1E32e21;
    address constant POOL_EXTENSION_ALLOWLIST = 0x00d9C6dda8D6DC9fc735B8a10a62AA6AE070510C;
    address constant DYNAMIC_HOOK = 0x963E91A45148b39737b9DF10c5b897B55cA9e8cC;
    address constant STATIC_HOOK = 0xC9156C1868E122eF5b3e6ed946e1E88ff7da68Cc;
    address constant LP_LOCKER = 0xBf05b1d5E356f3219D0086A4e09c969ADbe2e7d0;
    address constant MEV_MODULE = 0x6a04057180F8cc02E18DabEE3f3437E438BE657A;
    address constant AIRDROP = 0xa727da00eDd0F98Dc5Fb5D3b9eA09646CB809A87;
    address constant PRESALE = 0xC3E89329777183Ebf4fBE02769c98799B9Ff93b4;

    address constant WETH = 0x4200000000000000000000000000000000000006;

    address constant NEW_OWNER = 0x6097DD26871b0c7811D52B674e7407a38F7E84e5;

    function run() external onlyChain(BASE_CHAIN_ID) {
        uint256 deployerKey = vm.envUint("BONKER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        console.log("=== Transfer Ownership Script ===");
        console.log("Old owner:", deployer);
        console.log("New owner:", NEW_OWNER);
        console.log("");

        // ── Step 1: Claim fees ──────────────────────────────────────────

        // 1a. Claim team fees from Factory (WETH)
        uint256 factoryWeth = IERC20(WETH).balanceOf(FACTORY);
        console.log("Factory WETH balance:", factoryWeth);
        if (factoryWeth > 0) {
            console.log("  -> Claiming team fees from Factory...");
            vm.broadcast(deployerKey);
            IBonkerFactory(FACTORY).claimTeamFees(WETH);
        }

        // 1b. Claim fees from FeeLocker for our address
        uint256 lockerFees = IBonkerFeeLocker(FEE_LOCKER).availableFees(deployer, WETH);
        console.log("FeeLocker available WETH for deployer:", lockerFees);
        if (lockerFees > 0) {
            console.log("  -> Claiming from FeeLocker...");
            vm.broadcast(deployerKey);
            IBonkerFeeLocker(FEE_LOCKER).claim(deployer, WETH);
        }

        // 1c. Withdraw any ETH/WETH dust from LpLocker
        uint256 lpLockerEth = LP_LOCKER.balance;
        uint256 lpLockerWeth = IERC20(WETH).balanceOf(LP_LOCKER);
        console.log("LpLocker ETH balance:", lpLockerEth);
        console.log("LpLocker WETH balance:", lpLockerWeth);
        if (lpLockerEth > 0) {
            console.log("  -> Withdrawing ETH from LpLocker...");
            vm.broadcast(deployerKey);
            IBonkerLpLocker(LP_LOCKER).withdrawETH(deployer);
        }
        if (lpLockerWeth > 0) {
            console.log("  -> Withdrawing WETH from LpLocker...");
            vm.broadcast(deployerKey);
            IBonkerLpLocker(LP_LOCKER).withdrawERC20(WETH, deployer);
        }

        // ── Step 2: Send all WETH to new owner ─────────────────────────

        uint256 wethBalance = IERC20(WETH).balanceOf(deployer);
        console.log("");
        console.log("Deployer WETH balance after claims:", wethBalance);
        if (wethBalance > 0) {
            console.log("  -> Sending WETH to new owner...");
            vm.broadcast(deployerKey);
            IERC20(WETH).transfer(NEW_OWNER, wethBalance);
        }

        // ── Step 3: Transfer ownership of all contracts ─────────────────

        console.log("");
        console.log("=== Transferring Ownership ===");

        // Ownable contracts (hooks are NOT Ownable — V2 hooks have no owner)
        address[5] memory ownableContracts = [
            FACTORY,
            FEE_LOCKER,
            POOL_EXTENSION_ALLOWLIST,
            LP_LOCKER,
            MEV_MODULE
        ];
        string[5] memory names = [
            "Factory",
            "FeeLocker",
            "PoolExtensionAllowlist",
            "LpLocker",
            "MevModule"
        ];

        for (uint256 i = 0; i < ownableContracts.length; i++) {
            address current = Ownable(ownableContracts[i]).owner();
            console.log(names[i], "current owner:", current);
            if (current == deployer) {
                console.log("  -> Transferring to new owner...");
                vm.broadcast(deployerKey);
                Ownable(ownableContracts[i]).transferOwnership(NEW_OWNER);
            } else {
                console.log("  !! NOT owned by deployer, skipping");
            }
        }

        // Presale — also update bonkerFeeRecipient
        {
            address presaleOwner = IBonkerPresale(PRESALE).owner();
            console.log("Presale current owner:", presaleOwner);
            if (presaleOwner == deployer) {
                console.log("  -> Setting bonkerFeeRecipient to new owner...");
                vm.broadcast(deployerKey);
                IBonkerPresale(PRESALE).setBonkerFeeRecipient(NEW_OWNER);

                console.log("  -> Transferring Presale ownership...");
                vm.broadcast(deployerKey);
                Ownable(PRESALE).transferOwnership(NEW_OWNER);
            } else {
                console.log("  !! NOT owned by deployer, skipping");
            }
        }

        // ── Step 4: Send remaining ETH to new owner ────────────────────

        uint256 ethBalance = deployer.balance;
        console.log("");
        console.log("Deployer ETH balance:", ethBalance);
        // Keep a small amount for gas in case something goes wrong
        uint256 gasReserve = 0.001 ether;
        if (ethBalance > gasReserve) {
            uint256 sendAmount = ethBalance - gasReserve;
            console.log("  -> Sending ETH to new owner (keeping 0.001 for gas):", sendAmount);
            vm.broadcast(deployerKey);
            (bool ok,) = NEW_OWNER.call{value: sendAmount}("");
            require(ok, "ETH transfer failed");
        }

        // ── Summary ────────────────────────────────────────────────────

        console.log("");
        console.log("=== Done ===");
        console.log("Verify new ownership with:");
        console.log("  cast call <CONTRACT> 'owner()(address)' --rpc-url https://mainnet.base.org");
    }
}
