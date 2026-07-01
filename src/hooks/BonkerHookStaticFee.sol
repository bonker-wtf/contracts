// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BonkerHook} from "./BonkerHook.sol";
import {IBonkerHookStaticFee} from "./interfaces/IBonkerHookStaticFee.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

contract BonkerHookStaticFee is BonkerHook, IBonkerHookStaticFee {
    mapping(PoolId => uint24) public bonkerFee;
    mapping(PoolId => uint24) public pairedFee;

    constructor(address _poolManager, address _factory, address _weth)
        BonkerHook(_poolManager, _factory, _weth)
    {}

    function _initializePoolData(PoolKey memory poolKey, bytes memory poolData) internal override {
        PoolStaticConfigVars memory _poolConfigVars = abi.decode(poolData, (PoolStaticConfigVars));

        if (_poolConfigVars.bonkerFee > MAX_LP_FEE) {
            revert BonkerFeeTooHigh();
        }

        if (_poolConfigVars.pairedFee > MAX_LP_FEE) {
            revert PairedFeeTooHigh();
        }

        bonkerFee[poolKey.toId()] = _poolConfigVars.bonkerFee;
        pairedFee[poolKey.toId()] = _poolConfigVars.pairedFee;

        emit PoolInitialized(poolKey.toId(), _poolConfigVars.bonkerFee, _poolConfigVars.pairedFee);
    }

    // set the LP fee according to the bonker/paired fee configuration
    function _setFee(PoolKey calldata poolKey, IPoolManager.SwapParams calldata swapParams)
        internal
        override
    {
        PoolId poolId = poolKey.toId();
        uint24 fee =
            swapParams.zeroForOne != bonkerIsToken0[poolId] ? pairedFee[poolId] : bonkerFee[poolId];

        _setProtocolFee(fee);
        IPoolManager(poolManager).updateDynamicLPFee(poolKey, fee);
    }
}
