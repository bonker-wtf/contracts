// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IBonker} from "../interfaces/IBonker.sol";
import {IBonkerFeeLocker} from "../interfaces/IBonkerFeeLocker.sol";

import {IBonkerHookV2} from "../hooks/interfaces/IBonkerHookV2.sol";
import {IBonkerLpLocker} from "../interfaces/IBonkerLpLocker.sol";
import {IBonkerMevModule} from "../interfaces/IBonkerMevModule.sol";

import {IBonkerMevDescendingFees} from "./interfaces/IBonkerMevDescendingFees.sol";
import {IBonkerSniperAuctionV0} from "./interfaces/IBonkerSniperAuctionV0.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

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

/// @title BonkerSniperAuctionV2
/// @notice Runs sniper auction rounds, then transitions into a descending LP-fee decay phase.
/// @dev Winning swaps pay WETH based on the delta between `tx.gasprice` and a per-round gas peg.
contract BonkerSniperAuctionV2 is
    ReentrancyGuard,
    IBonkerSniperAuctionV0,
    IBonkerMevDescendingFees,
    Ownable
{
    uint8 public constant BONKER_VERSION = 2;
    bytes32 public constant BONKER_PROTOCOL_ID = keccak256("bonker.wtf");

    // gas peg and block number for a pool's auction
    mapping(PoolId => uint256 gasPeg) public gasPeg;
    mapping(PoolId => uint256 nextAuctionBlock) public nextAuctionBlock;
    // round of the auction
    mapping(PoolId => uint256 round) public round;

    // block between deployment and first auction
    uint256 public blocksBetweenDeploymentAndFirstAuction;

    // blocks between recurrent auction
    uint256 public blocksBetweenAuction;

    // max rounds of auction
    uint256 public maxRounds;

    // payment amount per gas unit difference
    uint256 public paymentPerGasUnit;

    // factory's portion of the payment
    uint256 public constant FACTORY_PORTION = 2000;
    uint256 public constant BPS = 10_000;

    // descending fee config
    mapping(PoolId poolId => FeeConfig feeConfig) public feeConfig;
    mapping(PoolId poolId => uint256 poolDecayStartTime) public poolDecayStartTime;

    // variable to have decay start at end of auction
    mapping(PoolId poolId => uint256 auctionTimestamp) internal auctionTimestamp;

    address public immutable weth;

    IBonker public immutable bonkerFactory;
    IBonkerFeeLocker public immutable feeLocker;

    /// @param owner_ Initial owner allowed to tune auction settings.
    /// @param _bonkerFactory Factory that receives the protocol share of auction proceeds.
    /// @param _feeLocker Fee locker used to stream LP rewards to configured recipients.
    /// @param _weth Token paid by auction winners.
    constructor(address owner_, address _bonkerFactory, address _feeLocker, address _weth)
        Ownable(owner_)
    {
        bonkerFactory = IBonker(_bonkerFactory);
        feeLocker = IBonkerFeeLocker(_feeLocker);
        weth = _weth;

        blocksBetweenDeploymentAndFirstAuction = 2;
        blocksBetweenAuction = 2;
        maxRounds = 5;
        paymentPerGasUnit = 0.0001 ether;
    }

    modifier onlyHook(PoolKey calldata poolKey) {
        if (msg.sender != address(poolKey.hooks)) {
            revert OnlyHook();
        }
        _;
    }

    /// @notice Sets the block delay between pool creation and the first sniper auction round.
    /// @param _blocksBetweenDeploymentAndFirstAuction New delay in blocks.
    function setBlocksBetweenDeploymentAndFirstAuction(uint256 _blocksBetweenDeploymentAndFirstAuction)
        external
        onlyOwner
    {
        uint256 oldBlocksBetweenDeploymentAndFirstAuction = blocksBetweenDeploymentAndFirstAuction;
        blocksBetweenDeploymentAndFirstAuction = _blocksBetweenDeploymentAndFirstAuction;

        emit SetBlocksBetweenDeploymentAndFirstAuction(
            oldBlocksBetweenDeploymentAndFirstAuction, blocksBetweenDeploymentAndFirstAuction
        );
    }

    /// @notice Sets the block delay between subsequent sniper auction rounds.
    /// @param _blocksBetweenAuction New delay in blocks.
    function setBlocksBetweenAuction(uint256 _blocksBetweenAuction) external onlyOwner {
        uint256 oldBlocksBetweenAuction = blocksBetweenAuction;
        blocksBetweenAuction = _blocksBetweenAuction;

        emit SetBlocksBetweenAuction(oldBlocksBetweenAuction, blocksBetweenAuction);
    }

    /// @notice Sets the WETH cost multiplier applied to the gas price signal.
    /// @param _paymentPerGasUnit New payment amount charged per unit above the gas peg.
    function setPaymentPerGasUnit(uint256 _paymentPerGasUnit) external onlyOwner {
        uint256 oldPaymentPerGasUnit = paymentPerGasUnit;
        paymentPerGasUnit = _paymentPerGasUnit;

        emit SetPaymentPerGasUnit(oldPaymentPerGasUnit, paymentPerGasUnit);
    }

    /// @notice Sets the maximum number of auction rounds before fee decay begins.
    /// @param _maxRounds New maximum round count.
    function setMaxRounds(uint256 _maxRounds) external onlyOwner {
        uint256 oldMaxRounds = maxRounds;
        maxRounds = _maxRounds;

        emit SetMaxRounds(oldMaxRounds, maxRounds);
    }

    /// @notice Returns the LP fee the hook should use for the next swap.
    /// @dev Returns 0 before initialization or after the decay period completes.
    /// @param poolId Pool identifier to query.
    /// @return Current LP fee in hundredths of a bip.
    function getFee(PoolId poolId) external view returns (uint24) {
        // if the pool is not initialized, return zero
        if (gasPeg[poolId] == 0) {
            return 0;
        }

        // if the decay period has not started, return the starting fee
        if (poolDecayStartTime[poolId] == 0) {
            return feeConfig[poolId].startingFee;
        }

        // check if the decay period is over
        if (block.timestamp > poolDecayStartTime[poolId] + feeConfig[poolId].secondsToDecay) {
            // decay period is over, return zero
            return 0;
        }

        return _calculateFee(poolId);
    }

    /// @notice Validates the descending-fee schedule supplied during initialization.
    /// @param poolKey Pool identity whose hook constraints must be satisfied.
    /// @param feeConfigData Decay schedule to validate.
    function _validateFeeConfig(PoolKey calldata poolKey, FeeConfig memory feeConfigData)
        internal
        view
    {
        // ensure the seconds to decay is greater than zero
        if (feeConfigData.secondsToDecay == 0) {
            revert TimeDecayMustBeGreaterThanZero();
        }

        // ensure the starting fee is not zero
        if (feeConfigData.startingFee == 0) {
            revert StartingFeeMustBeGreaterThanZero();
        }

        // ensure the starting fee is greater than the ending fee
        if (feeConfigData.startingFee < feeConfigData.endingFee) {
            revert StartingFeeMustBeGreaterThanEndingFee();
        }

        // ensure that the associated hook is a BonkerHookV2
        if (!IBonkerHookV2(address(poolKey.hooks))
                .supportsInterface(type(IBonkerHookV2).interfaceId)) {
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
    }

    /// @notice Initializes both the auction state and post-auction fee decay for a pool.
    /// @dev Can only be called once per pool by that pool's hook.
    /// @param poolKey Pool identity used to derive the pool ID and hook authorization.
    /// @param descendingFeeConfig ABI-encoded `FeeConfig` consumed once the auction rounds finish.
    function initialize(PoolKey calldata poolKey, bytes calldata descendingFeeConfig)
        external
        nonReentrant
        onlyHook(poolKey)
    {
        PoolId poolId = poolKey.toId();

        // check if the pool is already initialized
        if (gasPeg[poolId] != 0) {
            revert PoolAlreadyInitialized();
        }

        // get the first round's gas peg
        gasPeg[poolId] = _getBaseAuctionGasPeg(blocksBetweenDeploymentAndFirstAuction);

        // track the block number for the auction to be ran in
        nextAuctionBlock[poolId] = block.number + blocksBetweenDeploymentAndFirstAuction;

        // set the round to 1
        round[poolId] = 1;

        emit AuctionInitialized(poolId, gasPeg[poolId], nextAuctionBlock[poolId], round[poolId]);

        // initialize the descending fee config
        IBonkerMevDescendingFees.FeeConfig memory feeConfigData =
            abi.decode(descendingFeeConfig, (IBonkerMevDescendingFees.FeeConfig));

        // validate the descending fee config
        _validateFeeConfig(poolKey, feeConfigData);

        feeConfig[poolId] = feeConfigData;

        emit FeeConfigSet(
            poolId, feeConfigData.startingFee, feeConfigData.endingFee, feeConfigData.secondsToDecay
        );

        // set the auction timestamp to the current block timestamp
        auctionTimestamp[poolId] = block.timestamp;
    }

    /// @notice Computes the basefee peg that future winning bids must exceed.
    /// @param _blocksBetweenAuction Number of blocks the peg should account for.
    /// @return Gas peg derived from the current basefee and the configured block spacing.
    function _getBaseAuctionGasPeg(uint256 _blocksBetweenAuction) internal view returns (uint256) {
        // Assuming that the sequencer is running vanilla EIP-1559, gas prices can increase
        // by max 12.5% per block if the previous block was full. To enable a clean signal
        // for the auction, we peg the starting auction's gas price to block.basefee *
        // (1.125 ^ (_blocksBetweenAuction))
        //
        // This ensures that the lowest gas price signal can accommodate the highest shift
        // in the gas price
        return block.basefee * (1125 ** _blocksBetweenAuction) / (1000 ** _blocksBetweenAuction);
    }

    /// @notice Pulls the winning bid payment from the encoded payee.
    /// @dev The payment equals `(tx.gasprice - gasPeg) * paymentPerGasUnit`.
    /// @param poolId Pool whose current round is being settled.
    /// @param auctionData ABI-encoded winner address expected to fund the payment.
    /// @return paymentAmount Amount of WETH collected for this winning bid.
    function _pullPayment(PoolId poolId, bytes calldata auctionData)
        internal
        returns (uint256 paymentAmount)
    {
        (address payee) = abi.decode(auctionData, (address));

        // calculate the expected payment for the given gas price
        int256 gasSignal = int256(tx.gasprice) - int256(gasPeg[poolId]);

        // shouldn't be negative
        if (gasSignal < 0) {
            revert GasSignalNegative();
        }

        // calculate the expected payment for the given swap params
        paymentAmount = uint256(gasSignal) * paymentPerGasUnit;

        // pull payment from the payee
        SafeERC20.safeTransferFrom(IERC20(weth), payee, address(this), paymentAmount);

        emit AuctionWon(poolId, payee, paymentAmount, round[poolId]);
    }

    /// @notice Splits a winning bid between the factory and LP fee recipients.
    /// @param poolKey Pool identity used to resolve the deployed token and locker.
    /// @param bonkerIsToken0 True when the Bonker token is `currency0`.
    /// @param paymentAmount Total WETH payment collected from the auction winner.
    function _sendPayment(PoolKey calldata poolKey, bool bonkerIsToken0, uint256 paymentAmount)
        internal
    {
        if (paymentAmount == 0) {
            return;
        }

        // determine factory vs lp payment split
        uint256 factoryPayment = paymentAmount * FACTORY_PORTION / BPS;
        uint256 lpPayment = paymentAmount - factoryPayment;

        // send factory's portion
        SafeERC20.safeTransfer(IERC20(weth), address(bonkerFactory), factoryPayment);

        address bonker = bonkerIsToken0
            ? Currency.unwrap(poolKey.currency0)
            : Currency.unwrap(poolKey.currency1);

        // grab locker address from factory
        address lpLocker = bonkerFactory.tokenDeploymentInfo(bonker).locker;

        // get reward info from the locker
        IBonkerLpLocker.TokenRewardInfo memory tokenRewardInfo =
            IBonkerLpLocker(lpLocker).tokenRewards(bonker);

        // get the reward recipients and their splits
        uint256[] memory rewardsSplit = new uint256[](tokenRewardInfo.rewardBps.length);
        uint256 rewardTotal = 0;

        for (uint256 i = 0; i < tokenRewardInfo.rewardBps.length - 1; i++) {
            rewardsSplit[i] = tokenRewardInfo.rewardBps[i] * lpPayment / BPS;
            rewardTotal += rewardsSplit[i];
        }
        rewardsSplit[tokenRewardInfo.rewardBps.length - 1] = lpPayment - rewardTotal;

        // distribute the rewards
        SafeERC20.forceApprove(IERC20(weth), address(feeLocker), lpPayment);
        for (uint256 i = 0; i < tokenRewardInfo.rewardBps.length; i++) {
            feeLocker.storeFees(tokenRewardInfo.rewardRecipients[i], weth, rewardsSplit[i]);
        }

        emit AuctionRewardsTransferred(poolKey.toId(), lpPayment, factoryPayment);
    }

    /// @notice Advances the pool to the next auction round or starts fee decay after the final round.
    /// @param poolId Pool whose round state should be updated.
    function _prepareNextRound(PoolId poolId) internal {
        // bump round and record the auction timestamp
        round[poolId] = round[poolId] + 1;
        auctionTimestamp[poolId] = block.timestamp;

        // check if max rounds have been reached, if so,
        // trigger the start of the decay logic
        if (round[poolId] > maxRounds) {
            poolDecayStartTime[poolId] = block.timestamp;
            emit AuctionEnded(poolId);
            return;
        }

        // setup other variables for the next round
        gasPeg[poolId] = _getBaseAuctionGasPeg(blocksBetweenAuction);
        nextAuctionBlock[poolId] = block.number + blocksBetweenAuction;

        emit AuctionReset(poolId, gasPeg[poolId], nextAuctionBlock[poolId], round[poolId]);
    }

    /// @notice Calculates the active LP fee during the post-auction decay period.
    /// @param poolId Pool identifier to query.
    /// @return Decayed fee between the configured start and end fee values.
    function _calculateFee(PoolId poolId) internal view returns (uint24) {
        IBonkerMevDescendingFees.FeeConfig memory activeFeeConfig = feeConfig[poolId];

        // how much decay time remains
        uint256 timeDecay =
            activeFeeConfig.secondsToDecay - (block.timestamp - (poolDecayStartTime[poolId]));
        uint256 feeRange = activeFeeConfig.startingFee - activeFeeConfig.endingFee;

        // Parabolic decay: fee = endingFee + feeRange * (timeDecay / timeToDecay)²
        uint256 normalizedTime = (timeDecay * 1e18) / activeFeeConfig.secondsToDecay; // Scale for precision
        uint256 squaredTime = (normalizedTime * normalizedTime) / 1e18;
        uint256 decayAmount = (feeRange * squaredTime) / 1e18;

        return uint24(activeFeeConfig.endingFee + decayAmount);
    }

    /// @notice Instructs the hook to use `lpFee` for the current swap.
    /// @param poolKey Pool whose hook should be updated.
    /// @param lpFee Fee to apply for the current swap.
    function _setLpFee(PoolKey calldata poolKey, uint24 lpFee) internal {
        // call back into the hook to update the fee for the swap
        IBonkerHookV2(msg.sender).mevModuleSetFee(poolKey, lpFee);
    }

    /// @notice Applies decay-mode logic once the auction rounds are complete.
    /// @param poolKey Pool whose fee-decay state should be refreshed.
    /// @return disableMevModule True once the configured decay window has ended.
    function _handleFeeDecay(PoolKey calldata poolKey) internal returns (bool disableMevModule) {
        PoolId poolId = poolKey.toId();

        // check if the decay period is over
        if (block.timestamp > poolDecayStartTime[poolId] + feeConfig[poolId].secondsToDecay) {
            // decay period is over, disable the mev module
            emit DecayPeriodOver(poolId);
            return true;
        }

        // decay period is not over, set the LP fee
        _setLpFee(poolKey, _calculateFee(poolId));

        // mev module is still active
        return false;
    }

    /// @notice Runs either the auction phase or the fee-decay phase for the pool.
    /// @dev Before decay starts this enforces auction block timing; after decay starts it updates
    ///      the LP fee until the configured window expires.
    /// @param poolKey Pool identity for the auctioned token.
    /// @param bonkerIsToken0 True when the Bonker token is `currency0`.
    /// @param auctionData ABI-encoded winner address expected to pay for the round.
    /// @return disableMevModule True once the module has completed all auction and decay logic.
    function beforeSwap(
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata,
        bool bonkerIsToken0,
        bytes calldata auctionData // expected to be address paying
    ) external nonReentrant onlyHook(poolKey) returns (bool disableMevModule) {
        PoolId poolId = poolKey.toId();

        // check if the auction is ready to be ran or if we need to trigger the decay logic
        if (poolDecayStartTime[poolId] != 0) {
            // decay period is active, allow the decay logic to handle setting the LP fee
            return _handleFeeDecay(poolKey);
        } else if (block.number < nextAuctionBlock[poolId]) {
            // auction block not reached yet
            revert NotAuctionBlock();
        } else if (block.number > nextAuctionBlock[poolId]) {
            // auction block has passed, trigger the decay logic start
            emit AuctionExpired(poolId, round[poolId]);

            // note: the decay period starts at the last targeted auction block's timestamp
            poolDecayStartTime[poolId] = auctionTimestamp[poolId];
            return _handleFeeDecay(poolKey);
        }
        // block == nextAuctionBlock, run the auction logic

        // pull payment from the payee
        uint256 paymentAmount = _pullPayment(poolId, auctionData);

        // send payment to fee recipients
        _sendPayment(poolKey, bonkerIsToken0, paymentAmount);

        // set the LP fee to the starting fee
        _setLpFee(poolKey, feeConfig[poolId].startingFee);

        // setup auction for next round
        _prepareNextRound(poolId);

        // mev module is still active
        return false;
    }

    /// @notice Returns true for the `IBonkerMevModule` ERC-165 interface ID.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IBonkerMevModule).interfaceId;
    }
}
