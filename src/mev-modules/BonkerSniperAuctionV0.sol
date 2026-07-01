// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IBonker} from "../interfaces/IBonker.sol";
import {IBonkerFeeLocker} from "../interfaces/IBonkerFeeLocker.sol";
import {IBonkerLpLocker} from "../interfaces/IBonkerLpLocker.sol";
import {IBonkerMevModule} from "../interfaces/IBonkerMevModule.sol";
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

/// @title BonkerSniperAuctionV0
/// @notice Runs a fixed number of block-timed sniper auction rounds before disabling itself.
/// @dev Winning swaps pay WETH based on the delta between `tx.gasprice` and a per-round gas peg.
contract BonkerSniperAuctionV0 is ReentrancyGuard, IBonkerSniperAuctionV0, Ownable {
    // errors
    error PoolAlreadyInitialized();

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

    /// @notice Sets the maximum number of auction rounds before the module disables itself.
    /// @param _maxRounds New maximum round count.
    function setMaxRounds(uint256 _maxRounds) external onlyOwner {
        uint256 oldMaxRounds = maxRounds;
        maxRounds = _maxRounds;

        emit SetMaxRounds(oldMaxRounds, maxRounds);
    }

    /// @notice Initializes per-pool auction state when the hook creates a pool.
    /// @dev Can only be called once per pool by that pool's hook.
    /// @param poolKey Pool identity used to derive the pool ID and hook authorization.
    function initialize(PoolKey calldata poolKey, bytes calldata)
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

    /// @notice Advances the auction to the next round or ends the module after the last round.
    /// @param poolId Pool whose round state should be updated.
    /// @return nextRound True when the auction has ended and the hook should disable the module.
    function _prepareNextRound(PoolId poolId) internal returns (bool nextRound) {
        // bump round
        round[poolId] = round[poolId] + 1;

        // check if max rounds have been reached
        if (round[poolId] > maxRounds) {
            emit AuctionEnded(poolId);
            return true;
        }

        // setup other variables for the next round
        gasPeg[poolId] = _getBaseAuctionGasPeg(blocksBetweenAuction);
        nextAuctionBlock[poolId] = block.number + blocksBetweenAuction;

        emit AuctionReset(poolId, gasPeg[poolId], nextAuctionBlock[poolId], round[poolId]);

        return false;
    }

    /// @notice Runs the current round when a swap lands on the scheduled auction block.
    /// @dev Reverts before the target block, expires after the target block, and otherwise settles
    ///      the round payment before scheduling the next round.
    /// @param poolKey Pool identity for the auctioned token.
    /// @param bonkerIsToken0 True when the Bonker token is `currency0`.
    /// @param auctionData ABI-encoded winner address expected to pay for the round.
    /// @return disableMevModule True once the module has expired or completed all rounds.
    function beforeSwap(
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata,
        bool bonkerIsToken0,
        bytes calldata auctionData // expected to be address paying
    ) external nonReentrant onlyHook(poolKey) returns (bool disableMevModule) {
        // check if the auction is ready to be ran
        if (block.number < nextAuctionBlock[poolKey.toId()]) {
            // auction block not reached yet
            revert NotAuctionBlock();
        } else if (block.number > nextAuctionBlock[poolKey.toId()]) {
            // auction block passed with no winner, disable the module even if not all
            // rounds have been run and let the swap happen
            emit AuctionExpired(poolKey.toId(), round[poolKey.toId()]);
            return true;
        }

        // pull payment from the payee
        uint256 paymentAmount = _pullPayment(poolKey.toId(), auctionData);

        // send payment to fee recipients
        _sendPayment(poolKey, bonkerIsToken0, paymentAmount);

        // setup auction for next round or disable if max rounds reached
        return _prepareNextRound(poolKey.toId());
    }

    /// @notice Returns true for the `IBonkerMevModule` ERC-165 interface ID.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IBonkerMevModule).interfaceId;
    }
}
