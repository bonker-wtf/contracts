// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BonkerHookDynamicFeeV2} from "../src/hooks/BonkerHookDynamicFeeV2.sol";
import {BonkerHookStaticFeeV2} from "../src/hooks/BonkerHookStaticFeeV2.sol";

/// @notice Deploys hooks via CREATE2 from a known address so salt mining is deterministic.
contract HookDeployer {
    function deployDynamic(
        bytes32 salt,
        address poolManager,
        address factory,
        address allowlist,
        address weth
    ) external returns (address) {
        return address(new BonkerHookDynamicFeeV2{salt: salt}(poolManager, factory, allowlist, weth));
    }

    function deployStatic(
        bytes32 salt,
        address poolManager,
        address factory,
        address allowlist,
        address weth
    ) external returns (address) {
        return address(new BonkerHookStaticFeeV2{salt: salt}(poolManager, factory, allowlist, weth));
    }
}
