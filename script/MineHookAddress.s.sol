// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BonkerHookDynamicFeeV2} from "../src/hooks/BonkerHookDynamicFeeV2.sol";
import {BonkerHookStaticFeeV2} from "../src/hooks/BonkerHookStaticFeeV2.sol";

/// @notice Mines CREATE2 salts for hook contracts so the deployed address
///         has the correct permission flags in the last 14 bits.
///         Foundry routes `new X{salt: ...}` through the deterministic CREATE2 proxy.
contract MineHookAddress is Script {
    // Foundry's deterministic CREATE2 deployer proxy (Arachnid's factory)
    address constant CREATE2_PROXY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // Required hook flags:
    // beforeInitialize | beforeAddLiquidity | beforeSwap | afterSwap |
    // beforeSwapReturnDelta | afterSwapReturnDelta
    uint160 constant REQUIRED_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
            | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    uint160 constant FLAG_MASK = 0x3FFF; // last 14 bits

    function run() external view {
        address poolManager = vm.envAddress("POOL_MANAGER");
        address factory = vm.envAddress("FACTORY");
        address poolExtensionAllowlist = vm.envAddress("POOL_EXTENSION_ALLOWLIST");
        address weth = vm.envAddress("WETH");

        console.log("Mining hook addresses (CREATE2 proxy: %s)", CREATE2_PROXY);
        console.log("Required flags: 0x%x", uint256(REQUIRED_FLAGS));

        // Mine for BonkerHookDynamicFeeV2
        bytes memory dynamicInitCode = abi.encodePacked(
            type(BonkerHookDynamicFeeV2).creationCode,
            abi.encode(poolManager, factory, poolExtensionAllowlist, weth)
        );
        bytes32 dynamicInitCodeHash = keccak256(dynamicInitCode);

        console.log("\n--- BonkerHookDynamicFeeV2 ---");
        _mineSalt(dynamicInitCodeHash, "DynamicFee");

        // Mine for BonkerHookStaticFeeV2
        bytes memory staticInitCode = abi.encodePacked(
            type(BonkerHookStaticFeeV2).creationCode,
            abi.encode(poolManager, factory, poolExtensionAllowlist, weth)
        );
        bytes32 staticInitCodeHash = keccak256(staticInitCode);

        console.log("\n--- BonkerHookStaticFeeV2 ---");
        _mineSalt(staticInitCodeHash, "StaticFee");
    }

    function _mineSalt(bytes32 initCodeHash, string memory label) internal view {
        for (uint256 salt = 0; salt < 10_000_000; salt++) {
            address predicted = _computeCreate2Address(CREATE2_PROXY, bytes32(salt), initCodeHash);

            if (uint160(predicted) & FLAG_MASK == REQUIRED_FLAGS) {
                console.log("\nFound %s salt:", label);
                console.log("  Salt:", salt);
                console.log("  Address:", predicted);
                console.log("  Flags: 0x%x", uint256(uint160(predicted) & FLAG_MASK));
                return;
            }
        }

        console.log("No salt found for %s in 10M iterations", label);
    }

    function _computeCreate2Address(address deployer, bytes32 salt, bytes32 initCodeHash)
        internal
        pure
        returns (address)
    {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash))))
        );
    }
}
