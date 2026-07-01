// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IBonker} from "../interfaces/IBonker.sol";
import {IBonkerFeeLocker} from "../interfaces/IBonkerFeeLocker.sol";
import {IBonkerLpLocker} from "../interfaces/IBonkerLpLocker.sol";
import {IBonkerLpLockerMultiple} from "./interfaces/IBonkerLpLockerMultiple.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

/// @title BonkerLpLockerMultiple
/// @notice Locks Uniswap v4 liquidity positions on behalf of the Bonker factory and routes
///         collected LP fees to up to seven configurable reward recipients according to their
///         basis-point splits.  Each token gets its own set of positions (up to seven ranges),
///         and reward recipients can rotate their own address via {updateRewardRecipient}.
contract BonkerLpLockerMultiple is IBonkerLpLockerMultiple, ReentrancyGuard, Ownable {
    using TickMath for int24;

    string public constant version = "1";

    uint256 public constant BASIS_POINTS = 10_000;
    uint256 public constant MAX_REWARD_PARTICIPANTS = 7;
    uint256 public constant MAX_LP_POSITIONS = 7;

    IPositionManager public immutable positionManager;
    IPermit2 public immutable permit2;
    IBonkerFeeLocker public immutable feeLocker;
    address public immutable factory;

    mapping(address token => TokenRewardInfo tokenRewardInfo) internal _tokenRewards;

    constructor(
        address owner_,
        address factory_, // Address of the bonker factory
        address feeLocker_,
        address positionManager_, // Address of the position manager
        address permit2_ // address of the permit2 contract
    ) Ownable(owner_) {
        factory = factory_;
        feeLocker = IBonkerFeeLocker(feeLocker_);
        positionManager = IPositionManager(positionManager_);
        permit2 = IPermit2(permit2_);
    }

    modifier onlyFactory() {
        if (msg.sender != factory) {
            revert Unauthorized();
        }
        _;
    }

    /// @notice Returns the full reward configuration for a token.
    /// @param token The ERC-20 token address to query.
    /// @return The {TokenRewardInfo} struct including recipients, BPS splits, and position IDs.
    function tokenRewards(address token) external view returns (TokenRewardInfo memory) {
        return _tokenRewards[token];
    }

    /// @notice Pulls tokens from the factory, mints one or more Uniswap v4 positions, and
    ///         records the reward distribution configuration for the token.
    /// @dev Only callable by the factory. Reverts if the token already has positions.
    ///      Emits {TokenRewardAdded}.
    /// @param lockerConfig Tick ranges, per-position BPS, and reward recipient arrays.
    /// @param poolConfig Pool parameters (paired token, tick spacing, starting tick).
    /// @param poolKey Uniswap v4 pool key for the token pair.
    /// @param poolSupply Total token amount to lock as liquidity.
    /// @param token Address of the Bonker token being locked.
    /// @return positionId First Uniswap v4 NFT position ID minted for this token.
    function placeLiquidity(
        IBonker.LockerConfig memory lockerConfig,
        IBonker.PoolConfig memory poolConfig,
        PoolKey memory poolKey,
        uint256 poolSupply,
        address token
    ) external onlyFactory nonReentrant returns (uint256 positionId) {
        // ensure that we don't already have a reward for this token
        if (_tokenRewards[token].positionId != 0) {
            revert TokenAlreadyHasRewards();
        }

        // create the reward info
        TokenRewardInfo memory tokenRewardInfo = TokenRewardInfo({
            token: token,
            poolKey: poolKey,
            positionId: 0, // set below
            numPositions: lockerConfig.tickLower.length,
            rewardBps: lockerConfig.rewardBps,
            rewardAdmins: lockerConfig.rewardAdmins,
            rewardRecipients: lockerConfig.rewardRecipients
        });

        // check that all arrays are the same length
        if (
            tokenRewardInfo.rewardBps.length != tokenRewardInfo.rewardAdmins.length
                || tokenRewardInfo.rewardBps.length != tokenRewardInfo.rewardRecipients.length
        ) {
            revert MismatchedRewardArrays();
        }

        // check that the number of reward participants is not greater than the max
        if (tokenRewardInfo.rewardBps.length > MAX_REWARD_PARTICIPANTS) {
            revert TooManyRewardParticipants();
        }

        // check that there is at least one reward
        if (tokenRewardInfo.rewardBps.length == 0) {
            revert NoRewardRecipients();
        }

        // check that the reward amounts add up to 10000
        uint16 totalRewards = 0;
        for (uint256 i = 0; i < tokenRewardInfo.rewardBps.length; i++) {
            totalRewards += tokenRewardInfo.rewardBps[i];
            if (tokenRewardInfo.rewardBps[i] == 0) {
                revert ZeroRewardAmount();
            }
        }
        if (totalRewards != BASIS_POINTS) {
            revert InvalidRewardBps();
        }

        // check that no address is the zero address
        for (uint256 i = 0; i < tokenRewardInfo.rewardBps.length; i++) {
            if (
                tokenRewardInfo.rewardAdmins[i] == address(0)
                    || tokenRewardInfo.rewardRecipients[i] == address(0)
            ) {
                revert ZeroRewardAddress();
            }
        }

        // pull in the token and mint liquidity
        SafeERC20.safeTransferFrom(IERC20(token), msg.sender, address(this), poolSupply);

        positionId = _mintLiquidity(poolConfig, lockerConfig, poolKey, poolSupply, token);

        // store the reward info
        tokenRewardInfo.positionId = positionId;
        _tokenRewards[token] = tokenRewardInfo;

        emit TokenRewardAdded({
            token: tokenRewardInfo.token,
            poolKey: tokenRewardInfo.poolKey,
            poolSupply: poolSupply,
            positionId: tokenRewardInfo.positionId,
            numPositions: tokenRewardInfo.numPositions,
            rewardBps: tokenRewardInfo.rewardBps,
            rewardAdmins: tokenRewardInfo.rewardAdmins,
            rewardRecipients: tokenRewardInfo.rewardRecipients,
            tickLower: lockerConfig.tickLower,
            tickUpper: lockerConfig.tickUpper,
            positionBps: lockerConfig.positionBps
        });
    }

    function _mintLiquidity(
        IBonker.PoolConfig memory poolConfig,
        IBonker.LockerConfig memory lockerConfig,
        PoolKey memory poolKey,
        uint256 poolSupply,
        address token
    ) internal returns (uint256 positionId) {
        // check that all position infos are the same length
        if (
            lockerConfig.tickLower.length != lockerConfig.tickUpper.length
                || lockerConfig.tickLower.length != lockerConfig.positionBps.length
        ) {
            revert MismatchedPositionInfos();
        }

        // ensure that there is at least one position
        if (lockerConfig.tickLower.length == 0) {
            revert NoPositions();
        }

        // ensure that the max number of positions is not exceeded
        if (lockerConfig.tickLower.length > MAX_LP_POSITIONS) {
            revert TooManyPositions();
        }

        // make sure the locker position config is valid
        uint256 positionBpsTotal = 0;
        for (uint256 i = 0; i < lockerConfig.tickLower.length; i++) {
            if (lockerConfig.tickLower[i] > lockerConfig.tickUpper[i]) {
                revert TicksBackwards();
            }
            if (
                lockerConfig.tickLower[i] < TickMath.MIN_TICK
                    || lockerConfig.tickUpper[i] > TickMath.MAX_TICK
            ) {
                revert TicksOutOfTickBounds();
            }
            if (
                lockerConfig.tickLower[i] % poolConfig.tickSpacing != 0
                    || lockerConfig.tickUpper[i] % poolConfig.tickSpacing != 0
            ) {
                revert TicksNotMultipleOfTickSpacing();
            }
            if (lockerConfig.tickLower[i] < poolConfig.tickIfToken0IsBonker) {
                revert TickRangeLowerThanStartingTick();
            }

            positionBpsTotal += lockerConfig.positionBps[i];
        }
        if (positionBpsTotal != BASIS_POINTS) {
            revert InvalidPositionBps();
        }

        bool token0IsBonker = token < poolConfig.pairedToken;

        // encode actions
        bytes[] memory params = new bytes[](lockerConfig.tickLower.length + 1);
        bytes memory actions;

        int24 startingTick =
            token0IsBonker ? poolConfig.tickIfToken0IsBonker : -poolConfig.tickIfToken0IsBonker;

        for (uint256 i = 0; i < lockerConfig.tickLower.length; i++) {
            // add mint action
            actions = abi.encodePacked(actions, uint8(Actions.MINT_POSITION));

            // determine token amount for this position
            uint256 tokenAmount = poolSupply * lockerConfig.positionBps[i] / BASIS_POINTS;
            uint256 amount0 = token0IsBonker ? tokenAmount : 0;
            uint256 amount1 = token0IsBonker ? 0 : tokenAmount;

            // determine tick bounds for this position
            int24 tickLower_ =
                token0IsBonker ? lockerConfig.tickLower[i] : -lockerConfig.tickLower[i];
            int24 tickUpper_ =
                token0IsBonker ? lockerConfig.tickUpper[i] : -lockerConfig.tickUpper[i];
            int24 tickLower = token0IsBonker ? tickLower_ : tickUpper_;
            int24 tickUpper = token0IsBonker ? tickUpper_ : tickLower_;
            uint160 lowerSqrtPrice = TickMath.getSqrtPriceAtTick(tickLower);
            uint160 upperSqrtPrice = TickMath.getSqrtPriceAtTick(tickUpper);

            // determine liquidity amount
            uint256 liquidity = LiquidityAmounts.getLiquidityForAmounts(
                startingTick.getSqrtPriceAtTick(), lowerSqrtPrice, upperSqrtPrice, amount0, amount1
            );

            params[i] = abi.encode(
                poolKey,
                tickLower, // tick lower
                tickUpper, // tick upper
                liquidity, // liquidity
                amount0, // amount0Max
                amount1, // amount1Max
                address(this), // recipient of position
                abi.encode(address(this))
            );
        }

        // add settle action
        actions = abi.encodePacked(actions, uint8(Actions.SETTLE_PAIR));
        params[lockerConfig.tickLower.length] = abi.encode(poolKey.currency0, poolKey.currency1);

        // approvals
        {
            SafeERC20.forceApprove(IERC20(token), address(permit2), poolSupply);
            permit2.approve(
                token, address(positionManager), uint160(poolSupply), uint48(block.timestamp)
            );
        }

        // grab position id we're about to mint
        positionId = positionManager.nextTokenId();
        // add liquidity
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);
    }

    /// @notice Collects LP fees and forwards them to reward recipients while the pool is already
    ///         unlocked (e.g. called from an `afterSwap` hook via {IBonkerLpLocker}).
    /// @param token The Bonker token whose positions to collect fees from.
    function collectRewardsWithoutUnlock(address token) external nonReentrant {
        _collectRewards(token, true);
    }

    /// @notice Collects LP fees and forwards them to reward recipients while the pool is locked.
    /// @param token The Bonker token whose positions to collect fees from.
    function collectRewards(address token) external nonReentrant {
        _collectRewards(token, false);
    }

    // Collect rewards for a token
    function _collectRewards(address token, bool withoutUnlock) internal {
        // get the reward info
        TokenRewardInfo memory tokenRewardInfo = _tokenRewards[token];

        // collect the rewards
        (uint256 amount0, uint256 amount1) = _bringFeesIntoContract(
            tokenRewardInfo.poolKey,
            tokenRewardInfo.positionId,
            tokenRewardInfo.numPositions,
            withoutUnlock
        );

        IERC20 rewardToken0 = IERC20(Currency.unwrap(tokenRewardInfo.poolKey.currency0));
        IERC20 rewardToken1 = IERC20(Currency.unwrap(tokenRewardInfo.poolKey.currency1));

        // determine reward distribution
        uint256[] memory rewards0 = new uint256[](tokenRewardInfo.rewardBps.length);
        uint256[] memory rewards1 = new uint256[](tokenRewardInfo.rewardBps.length);
        uint256 reward0Total = 0;
        uint256 reward1Total = 0;

        for (uint256 i = 0; i < tokenRewardInfo.rewardBps.length - 1; i++) {
            rewards0[i] = uint256(tokenRewardInfo.rewardBps[i]) * amount0 / BASIS_POINTS;
            rewards1[i] = uint256(tokenRewardInfo.rewardBps[i]) * amount1 / BASIS_POINTS;
            reward0Total += rewards0[i];
            reward1Total += rewards1[i];
        }
        rewards0[tokenRewardInfo.rewardBps.length - 1] = amount0 - reward0Total;
        rewards1[tokenRewardInfo.rewardBps.length - 1] = amount1 - reward1Total;

        // distribute the rewards
        for (uint256 i = 0; i < tokenRewardInfo.rewardBps.length; i++) {
            if (rewards0[i] > 0) {
                SafeERC20.forceApprove(rewardToken0, address(feeLocker), rewards0[i]);
                feeLocker.storeFees(
                    tokenRewardInfo.rewardRecipients[i], address(rewardToken0), rewards0[i]
                );
            }
            if (rewards1[i] > 0) {
                SafeERC20.forceApprove(rewardToken1, address(feeLocker), rewards1[i]);
                feeLocker.storeFees(
                    tokenRewardInfo.rewardRecipients[i], address(rewardToken1), rewards1[i]
                );
            }
        }

        // emit the claim event
        emit ClaimedRewards(tokenRewardInfo.token, amount0, amount1, rewards0, rewards1);
    }

    function _bringFeesIntoContract(
        PoolKey memory poolKey,
        uint256 positionId,
        uint256 numPositions,
        bool withoutUnlock
    ) internal returns (uint256 amount0, uint256 amount1) {
        bytes memory actions;
        bytes[] memory params = new bytes[](numPositions + 1);

        for (uint256 i = 0; i < numPositions; i++) {
            actions = abi.encodePacked(actions, uint8(Actions.DECREASE_LIQUIDITY));
            /// @dev collecting fees is achieved with liquidity=0, the second parameter
            params[i] = abi.encode(positionId + i, 0, 0, 0, abi.encode());
        }

        Currency currency0 = poolKey.currency0;
        Currency currency1 = poolKey.currency1;
        actions = abi.encodePacked(actions, uint8(Actions.TAKE_PAIR));
        params[numPositions] = abi.encode(currency0, currency1, address(this));

        uint256 balance0Before = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 balance1Before = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        // when claiming from the hook, we need to call modifyLiquiditiesWithoutUnlock since
        // the pool will be in an unlocked state
        if (withoutUnlock) {
            positionManager.modifyLiquiditiesWithoutUnlock(actions, params);
        } else {
            positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);
        }

        uint256 balance0After = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 balance1After = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        return (balance0After - balance0Before, balance1After - balance1Before);
    }

    /// @notice Allows the reward admin at `rewardIndex` to redirect future fees to a new address.
    /// @dev Emits {RewardRecipientUpdated}.
    /// @param token The Bonker token whose reward config is being updated.
    /// @param rewardIndex Index into the rewards array (must match caller's admin slot).
    /// @param newRecipient Address that will receive future fee distributions.
    function updateRewardRecipient(address token, uint256 rewardIndex, address newRecipient)
        external
    {
        TokenRewardInfo storage tokenRewardInfo = _tokenRewards[token];

        // Only admin can replace the reward recipient
        if (msg.sender != tokenRewardInfo.rewardAdmins[rewardIndex]) {
            revert Unauthorized();
        }

        // Add the new recipient
        address oldRecipient = tokenRewardInfo.rewardRecipients[rewardIndex];
        tokenRewardInfo.rewardRecipients[rewardIndex] = newRecipient;

        emit RewardRecipientUpdated(token, rewardIndex, oldRecipient, newRecipient);
    }

    /// @notice Allows the current reward admin at `rewardIndex` to transfer admin rights.
    /// @dev Emits {RewardAdminUpdated}.
    /// @param token The Bonker token whose reward config is being updated.
    /// @param rewardIndex Index into the rewards array (must match caller's admin slot).
    /// @param newAdmin Address that will become the new admin for this reward slot.
    function updateRewardAdmin(address token, uint256 rewardIndex, address newAdmin) external {
        TokenRewardInfo storage tokenRewardInfo = _tokenRewards[token];

        // Only admin can replace the reward admin
        if (msg.sender != tokenRewardInfo.rewardAdmins[rewardIndex]) {
            revert Unauthorized();
        }

        // Add the new admin
        address oldAdmin = tokenRewardInfo.rewardAdmins[rewardIndex];
        tokenRewardInfo.rewardAdmins[rewardIndex] = newAdmin;

        emit RewardAdminUpdated(token, rewardIndex, oldAdmin, newAdmin);
    }

    /// @notice ERC-721 receiver hook; only accepts NFTs sent by the factory.
    /// @dev Reverts with {Unauthorized} for any other sender. Emits {Received}.
    function onERC721Received(address, address from, uint256 id, bytes calldata)
        external
        returns (bytes4)
    {
        // Only Bonker Factory can send NFTs here
        if (from != factory) {
            revert Unauthorized();
        }

        emit Received(from, id);
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice Emergency ETH withdrawal; only callable by the contract owner.
    /// @param recipient Address to receive the full ETH balance.
    function withdrawETH(address recipient) public onlyOwner nonReentrant {
        payable(recipient).transfer(address(this).balance);
    }

    /// @notice Emergency ERC-20 withdrawal; only callable by the contract owner.
    /// @param token The ERC-20 token to sweep.
    /// @param recipient Address to receive the full token balance.
    function withdrawERC20(address token, address recipient) public onlyOwner nonReentrant {
        IERC20 token_ = IERC20(token);
        SafeERC20.safeTransfer(token_, recipient, token_.balanceOf(address(this)));
    }

    /// @notice Returns true if this contract implements the given ERC-165 interface.
    /// @param interfaceId The interface identifier to check.
    /// @return True when `interfaceId` matches {IERC721Receiver} or {IBonkerLpLocker}.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC721Receiver).interfaceId
            || interfaceId == type(IBonkerLpLocker).interfaceId;
    }
}
