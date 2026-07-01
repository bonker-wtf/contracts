// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IBonkerMevModule} from "../interfaces/IBonkerMevModule.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title BonkerMevBlockDelay
/// @notice Temporarily blocks swaps on a newly created pool until a configured number of blocks pass.
/// @dev The Bonker hook initializes each pool once, then consults `beforeSwap` on every swap until
///      this module reports the lock period is over.
contract BonkerMevBlockDelay is IBonkerMevModule {
    mapping(PoolId => uint256) public poolUnlockTime;

    uint256 public blockDelay;

    /// @param _blockDelay Number of blocks a pool stays locked after initialization.
    constructor(uint256 _blockDelay) {
        blockDelay = _blockDelay;
    }

    modifier onlyHook(PoolKey calldata poolKey) {
        if (msg.sender != address(poolKey.hooks)) {
            revert OnlyHook();
        }
        _;
    }

    /// @notice Records the block height when a pool becomes tradable.
    /// @dev Only the pool's hook may call this, and it is expected to run once per pool deployment.
    /// @param poolKey Pool identity used to derive the stored pool ID.
    function initialize(PoolKey calldata poolKey, bytes calldata) external onlyHook(poolKey) {
        // set the pool unlock time to block.number plus the configured delay
        poolUnlockTime[poolKey.toId()] = block.number + blockDelay;
    }

    /// @notice Reverts while the configured block delay is still active for `poolKey`.
    /// @dev Returns `true` once the delay has passed so the hook can stop calling this module.
    /// @param poolKey Pool identity used to look up the unlock block.
    /// @return disableMevModule Always true once the pool is unlocked.
    function beforeSwap(
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata,
        bool,
        bytes calldata
    ) external onlyHook(poolKey) returns (bool disableMevModule) {
        // check if the pool is locked
        if (block.number < poolUnlockTime[poolKey.toId()]) {
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
