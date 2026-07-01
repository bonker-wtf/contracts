// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IBonkerMevModule} from "../interfaces/IBonkerMevModule.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title BonkerMevTimeDelay
/// @notice Temporarily blocks swaps on a newly created pool until a configured time delay expires.
/// @dev The delay is stored per pool during `initialize`, then enforced in `beforeSwap`.
contract BonkerMevTimeDelay is IBonkerMevModule {
    error TimeDelayMustBeGreaterThanZero();

    mapping(PoolId => uint256) public poolUnlockTime;

    uint256 public timeDelay;

    /// @param _timeDelay Number of seconds a pool stays locked after initialization.
    constructor(uint256 _timeDelay) {
        if (_timeDelay == 0) {
            revert TimeDelayMustBeGreaterThanZero();
        }
        timeDelay = _timeDelay;
    }

    modifier onlyHook(PoolKey calldata poolKey) {
        if (msg.sender != address(poolKey.hooks)) {
            revert OnlyHook();
        }
        _;
    }

    /// @notice Records the timestamp when a pool becomes tradable.
    /// @dev Only the pool's hook may call this, and it is expected to run once per pool deployment.
    /// @param poolKey Pool identity used to derive the stored pool ID.
    function initialize(PoolKey calldata poolKey, bytes calldata) external onlyHook(poolKey) {
        // set the pool unlock time to the current timestamp + the time delay
        poolUnlockTime[poolKey.toId()] = block.timestamp + timeDelay;
    }

    /// @notice Reverts while the configured time delay is still active for `poolKey`.
    /// @dev Returns `true` once the delay has passed so the hook can stop calling this module.
    /// @param poolKey Pool identity used to look up the unlock timestamp.
    /// @return disableMevModule Always true once the pool is unlocked.
    function beforeSwap(
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata,
        bool,
        bytes calldata
    ) external onlyHook(poolKey) returns (bool disableMevModule) {
        // check if the pool is locked
        if (block.timestamp < poolUnlockTime[poolKey.toId()]) {
            revert PoolLocked();
        }

        // pool should be unlocked now
        return true;
    }

    /// @notice Returns true for the `IBonkerMevModule` ERC-165 interface ID.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IBonkerMevModule).interfaceId;
    }
}
