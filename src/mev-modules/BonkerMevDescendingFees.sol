// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IBonkerHookV2} from "../hooks/interfaces/IBonkerHookV2.sol";
import {IBonkerMevModule} from "../interfaces/IBonkerMevModule.sol";
import {IBonkerMevDescendingFees} from "./interfaces/IBonkerMevDescendingFees.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/*
╔════════════════════════════════════════════════════════════════╗
║                                                                ║
║      ██████╗  ██████╗ ███╗   ██╗██╗  ██╗███████╗██████╗        ║
║      ██╔══██╗██╔═══██╗████╗  ██║██║ ██╔╝██╔════╝██╔══██╗       ║
║      ██████╔╝██║   ██║██╔██╗ ██║█████╔╝ █████╗  ██████╔╝       ║
║      ██╔══██╗██║   ██║██║╚██╗██║██╔═██╗ ██╔══╝  ██╔══██╗       ║
║      ██████╔╝╚██████╔╝██║ ╚████║██║  ██╗███████╗██║  ██║       ║
║      ╚═════╝  ╚═════╝ ╚═╝  ╚═══╝╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝       ║
║                                                                ║
║                   ░▒▓█ BONKER PROTOCOL █▓▒░                    ║
║                                                                ║
╚════════════════════════════════════════════════════════════════╝
*/

/// @title BonkerMevDescendingFees
/// @notice Applies a time-decaying MEV fee to a pool immediately after deployment.
/// @dev The hook initializes a per-pool fee curve, then calls `beforeSwap` to update the active
///      swap fee until the decay window expires.
contract BonkerMevDescendingFees is IBonkerMevDescendingFees {
    mapping(PoolId poolId => FeeConfig feeConfig) public feeConfig;
    mapping(PoolId poolId => uint256 poolStartTime) public poolStartTime;

    uint256 public delayGuard = 1;

    modifier onlyHook(PoolKey calldata poolKey) {
        if (msg.sender != address(poolKey.hooks)) {
            revert OnlyHook();
        }
        _;
    }

    /// @notice Initializes the decaying fee configuration for a pool.
    /// @dev Only callable by the pool's hook and only once per pool.
    /// @param poolKey Pool identity whose fee decay state is being configured.
    /// @param poolFeeConfig ABI-encoded `FeeConfig` containing the start fee, end fee, and decay time.
    function initialize(PoolKey calldata poolKey, bytes calldata poolFeeConfig)
        external
        onlyHook(poolKey)
    {
        // only initialize once
        if (poolStartTime[poolKey.toId()] != 0) {
            revert PoolAlreadyInitialized();
        }

        // set pool's start time
        poolStartTime[poolKey.toId()] = block.timestamp;

        // decode the fee config
        FeeConfig memory feeConfigData = abi.decode(poolFeeConfig, (FeeConfig));

        // validate the fee config
        if (feeConfigData.secondsToDecay == 0) {
            revert TimeDecayMustBeGreaterThanZero();
        }
        if (feeConfigData.startingFee == 0) {
            revert StartingFeeMustBeGreaterThanZero();
        }
        if (feeConfigData.startingFee < feeConfigData.endingFee) {
            revert StartingFeeMustBeGreaterThanEndingFee();
        }

        // ensure that the associated hook is a BonkerHookV2
        if (
            !IBonkerHookV2(address(poolKey.hooks)).supportsInterface(
                type(IBonkerHookV2).interfaceId
            )
        ) {
            revert OnlyBonkerHookV2();
        }

        // ensure the starting fee is not greater than the max mev LP fee
        if (feeConfigData.startingFee > IBonkerHookV2(address(poolKey.hooks)).MAX_MEV_LP_FEE()) {
            revert StartingFeeGreaterThanMaxLpFee();
        }

        // ensure the max time length is not longer than the max auction length
        if (
            feeConfigData.secondsToDecay
                > IBonkerHookV2(address(poolKey.hooks)).MAX_MEV_MODULE_DELAY()
        ) {
            revert TimeDecayLongerThanMaxMevDelay();
        }

        // set the fee config
        feeConfig[poolKey.toId()] = FeeConfig({
            startingFee: feeConfigData.startingFee,
            endingFee: feeConfigData.endingFee,
            secondsToDecay: feeConfigData.secondsToDecay
        });

        emit FeeConfigSet(
            poolKey.toId(),
            feeConfigData.startingFee,
            feeConfigData.endingFee,
            feeConfigData.secondsToDecay
        );
    }

    /// @notice Returns the current decayed fee for `poolId`.
    /// @dev Returns 0 before initialization, after the decay period ends, or if the pool is no longer
    ///      meant to use this module. Returns the starting fee during the exact deployment timestamp.
    /// @param poolId Pool identifier to query.
    /// @return Current fee in hundredths of a bip.
    function getFee(PoolId poolId) external view returns (uint24) {
        // if the pool is not initialized, return zero
        if (poolStartTime[poolId] == 0) {
            return 0;
        }

        // check if the decay period is over
        if (block.timestamp > poolStartTime[poolId] + feeConfig[poolId].secondsToDecay) {
            // decay period is over, return zero
            return 0;
        }

        // check if this is the same timestamp as deployment, if so, return the starting fee
        if (block.timestamp == poolStartTime[poolId]) {
            return feeConfig[poolId].startingFee;
        }

        // return the fee for the swap
        return _calculateFee(poolId);
    }

    /// @notice Calculates the active fee using a parabolic decay curve.
    /// @param poolId Pool identifier to query.
    /// @return Decayed fee between the configured start and end fee values.
    function _calculateFee(PoolId poolId) internal view returns (uint24) {
        FeeConfig memory config = feeConfig[poolId];
        uint256 startTime = poolStartTime[poolId];
        uint256 guard = delayGuard;

        // how much time has passed since pool creation
        uint256 timeDecay = config.secondsToDecay - (block.timestamp - (startTime + guard));
        uint256 feeRange = config.startingFee - config.endingFee;

        // Parabolic decay: fee = endingFee + feeRange * (timeDecay / timeToDecay)²
        uint256 normalizedTime = (timeDecay * 1e18) / config.secondsToDecay; // Scale for precision
        uint256 squaredTime = (normalizedTime * normalizedTime) / 1e18;
        uint256 decayAmount = (feeRange * squaredTime) / 1e18;

        return uint24(config.endingFee + decayAmount);
    }

    /// @notice Updates the hook's fee for the current swap or disables the module after decay ends.
    /// @dev Reverts during the exact deployment second to prevent same-second sniping.
    /// @param poolKey Pool identity whose current fee should be refreshed.
    /// @return disableMevModule True once the decay window has ended; otherwise false.
    function beforeSwap(
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata,
        bool,
        bytes calldata
    ) external onlyHook(poolKey) returns (bool disableMevModule) {
        // don't allow trading in the same second as deployment
        if (block.timestamp == poolStartTime[poolKey.toId()]) {
            revert SameSecondAsDeployment();
        }

        // check if tax period is over
        if (
            block.timestamp
                >= poolStartTime[poolKey.toId()] + feeConfig[poolKey.toId()].secondsToDecay + delayGuard
        ) {
            // disable the mev module without setting the fee
            emit DecayPeriodOver(poolKey.toId());
            return true;
        }

        // calculate the fee for the swap
        uint24 swapFee = _calculateFee(poolKey.toId());

        // call back into the hook to update the fee for the swap
        IBonkerHookV2(msg.sender).mevModuleSetFee(poolKey, swapFee);

        // mev module is still active
        return false;
    }

    /// @notice Returns true for the `IBonkerMevModule` ERC-165 interface ID.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IBonkerMevModule).interfaceId;
    }
}
