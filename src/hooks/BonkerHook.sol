// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BonkerToken} from "../BonkerToken.sol";

import {IBonker} from "../interfaces/IBonker.sol";

import {IBonkerLpLocker} from "../interfaces/IBonkerLpLocker.sol";
import {IBonkerMevModule} from "../interfaces/IBonkerMevModule.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks, IHooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IBonkerHook} from "../interfaces/IBonkerHook.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {
    BeforeSwapDelta, BeforeSwapDeltaLibrary
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";

/// @title BonkerHook
/// @notice Abstract base hook that handles pool initialization, MEV module gating, LP locker
///         fee auto-claiming, and protocol fee collection on every swap.
abstract contract BonkerHook is BaseHook, Ownable, IBonkerHook {
    using TickMath for int24;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    uint24 public constant MAX_LP_FEE = 300_000; // LP fee capped at 30%
    uint256 public constant PROTOCOL_FEE_NUMERATOR = 200_000; // 20% of the imposed LP fee
    int128 public constant FEE_DENOMINATOR = 1_000_000; // Uniswap 100% fee

    uint24 public protocolFee;

    address public immutable factory;
    address public immutable weth;

    mapping(PoolId => bool) internal bonkerIsToken0;
    mapping(PoolId => address) internal locker;

    // mev module pool variables
    uint256 public constant MAX_MEV_MODULE_DELAY = 2 minutes;
    mapping(PoolId => address) public mevModule;
    mapping(PoolId => bool) public mevModuleEnabled;
    mapping(PoolId => uint256) public poolCreationTimestamp;

    modifier onlyFactory() {
        if (msg.sender != factory) {
            revert OnlyFactory();
        }
        _;
    }

    constructor(address _poolManager, address _factory, address _weth)
        BaseHook(IPoolManager(_poolManager))
        Ownable(msg.sender)
    {
        factory = _factory;
        weth = _weth;
    }

    /// @notice Hook point for subclasses to update the LP fee before each swap.
    function _setFee(PoolKey calldata poolKey, IPoolManager.SwapParams calldata swapParams)
        internal
        virtual
    {
        return;
    }

    /// @notice Derives and stores the protocol fee as 20% of the given LP fee.
    /// @param lpFee The LP fee (in millionths) used to compute the protocol fee.
    function _setProtocolFee(uint24 lpFee) internal {
        protocolFee = uint24(uint256(lpFee) * PROTOCOL_FEE_NUMERATOR / uint128(FEE_DENOMINATOR));
    }

    /// @notice Hook point for subclasses to decode and store pool-specific configuration data.
    function _initializePoolData(PoolKey memory poolKey, bytes memory poolData) internal virtual {
        return;
    }

    /// @notice Initializes a new Bonker pool and wires its LP locker and MEV module.
    /// @dev Only callable by the factory. Emits {PoolCreatedFactory}.
    /// @param bonker Address of the Bonker token being paired.
    /// @param pairedToken Address of the paired token (e.g. WETH).
    /// @param tickIfToken0IsBonker Starting tick expressed as if the Bonker token were token0.
    /// @param tickSpacing Pool tick spacing.
    /// @param _locker Address of the LP locker contract for this token.
    /// @param _mevModule Address of the MEV module contract (or zero to disable).
    /// @param poolData ABI-encoded fee configuration passed to `_initializePoolData`.
    /// @return poolKey The Uniswap v4 pool key for the newly created pool.
    function initializePool(
        address bonker,
        address pairedToken,
        int24 tickIfToken0IsBonker,
        int24 tickSpacing,
        address _locker,
        address _mevModule,
        bytes calldata poolData
    ) public onlyFactory returns (PoolKey memory) {
        // initialize the pool
        PoolKey memory poolKey =
            _initializePool(bonker, pairedToken, tickIfToken0IsBonker, tickSpacing, poolData);

        // set the locker config
        locker[poolKey.toId()] = _locker;

        // set the mev module
        mevModule[poolKey.toId()] = _mevModule;

        emit PoolCreatedFactory({
            pairedToken: pairedToken,
            bonker: bonker,
            poolId: poolKey.toId(),
            tickIfToken0IsBonker: tickIfToken0IsBonker,
            tickSpacing: tickSpacing,
            locker: _locker,
            mevModule: _mevModule
        });

        return poolKey;
    }

    /// @notice Allows anyone to initialize a pool on this hook without a locker or MEV module.
    /// @dev Intended for tokens not deployed by the factory. WETH cannot be the Bonker token.
    ///      Emits {PoolCreatedOpen}.
    /// @param bonker Address of the token to treat as the "bonker" side for fee collection.
    /// @param pairedToken Address of the paired token.
    /// @param tickIfToken0IsBonker Starting tick expressed as if `bonker` were token0.
    /// @param tickSpacing Pool tick spacing.
    /// @param poolData ABI-encoded fee configuration passed to `_initializePoolData`.
    /// @return poolKey The Uniswap v4 pool key for the newly created pool.
    function initializePoolOpen(
        address bonker,
        address pairedToken,
        int24 tickIfToken0IsBonker,
        int24 tickSpacing,
        bytes calldata poolData
    ) public returns (PoolKey memory) {
        // if able, we prefer that weth is not the bonker as our hook fee will only
        // collect fees on the paired token
        if (bonker == weth) {
            revert WethCannotBeBonker();
        }

        PoolKey memory poolKey =
            _initializePool(bonker, pairedToken, tickIfToken0IsBonker, tickSpacing, poolData);

        emit PoolCreatedOpen(
            pairedToken, bonker, poolKey.toId(), tickIfToken0IsBonker, tickSpacing
        );

        return poolKey;
    }

    // common actions for initializing a pool
    function _initializePool(
        address bonker,
        address pairedToken,
        int24 tickIfToken0IsBonker,
        int24 tickSpacing,
        bytes calldata poolData
    ) internal virtual returns (PoolKey memory) {
        // ensure that the pool is not an ETH pool
        if (pairedToken == address(0) || bonker == address(0)) {
            revert ETHPoolNotAllowed();
        }

        // determine if bonker is token0
        bool token0IsBonker = bonker < pairedToken;

        // create the pool key
        PoolKey memory _poolKey = PoolKey({
            currency0: Currency.wrap(token0IsBonker ? bonker : pairedToken),
            currency1: Currency.wrap(token0IsBonker ? pairedToken : bonker),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(this))
        });

        // Set the storage helpers
        bonkerIsToken0[_poolKey.toId()] = token0IsBonker;

        // initialize the pool
        int24 startingTick = token0IsBonker ? tickIfToken0IsBonker : -tickIfToken0IsBonker;
        uint160 initialPrice = startingTick.getSqrtPriceAtTick();
        poolManager.initialize(_poolKey, initialPrice);

        // set the pool creation timestamp
        poolCreationTimestamp[_poolKey.toId()] = block.timestamp;

        // initialize other pool data
        _initializePoolData(_poolKey, poolData);

        return _poolKey;
    }

    /// @notice Activates the MEV module for a pool after all extensions have been initialised.
    /// @dev Called by the factory in a separate step so extensions can perform pool actions first.
    ///      Only callable by the factory.
    /// @param poolKey The pool whose MEV module should be enabled.
    /// @param mevModuleData ABI-encoded initialisation data forwarded to the MEV module.
    function initializeMevModule(PoolKey calldata poolKey, bytes calldata mevModuleData)
        external
        onlyFactory
    {
        // initialize the mev module
        IBonkerMevModule(mevModule[poolKey.toId()]).initialize(poolKey, mevModuleData);

        // enable the mev module
        mevModuleEnabled[poolKey.toId()] = true;
    }

    function _runMevModule(
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata swapParams,
        bytes calldata mevModuleSwapData
    ) internal {
        // if the mev module is enabled and the pool is younger than 2 minutes, call it
        //
        // note: we have the 2 minute guard in case the sequencer environment
        // changes and the mev module breaks
        if (
            mevModuleEnabled[poolKey.toId()]
                && block.timestamp < poolCreationTimestamp[poolKey.toId()] + MAX_MEV_MODULE_DELAY
        ) {
            bool disableMevModule = IBonkerMevModule(mevModule[poolKey.toId()]).beforeSwap(
                poolKey, swapParams, bonkerIsToken0[poolKey.toId()], mevModuleSwapData
            );

            // disable the mevModule if the module requests it
            if (disableMevModule) {
                mevModuleEnabled[poolKey.toId()] = false;
                emit MevModuleDisabled(poolKey.toId());
            }
        }
    }

    function _lpLockerFeeClaim(PoolKey calldata poolKey) internal {
        // if this wasn't initialized to claim fees, skip the claim
        if (locker[poolKey.toId()] == address(0)) {
            return;
        }

        // determine the token
        address token = bonkerIsToken0[poolKey.toId()]
            ? Currency.unwrap(poolKey.currency0)
            : Currency.unwrap(poolKey.currency1);

        // trigger the fee claim
        IBonkerLpLocker(locker[poolKey.toId()]).collectRewardsWithoutUnlock(token);
    }

    function _hookFeeClaim(PoolKey calldata poolKey) internal {
        // determine the fee token
        Currency feeCurrency =
            bonkerIsToken0[poolKey.toId()] ? poolKey.currency1 : poolKey.currency0;

        // get the fees stored from the previous swap in the pool manager
        uint256 fee = poolManager.balanceOf(address(this), feeCurrency.toId());

        if (fee == 0) {
            return;
        }

        // burn the fee
        poolManager.burn(address(this), feeCurrency.toId(), fee);

        // take the fee
        poolManager.take(feeCurrency, factory, fee);

        emit ClaimProtocolFees(Currency.unwrap(feeCurrency), fee);
    }

    function _beforeSwap(
        address,
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata swapParams,
        bytes calldata mevModuleSwapData
    ) internal virtual override returns (bytes4, BeforeSwapDelta delta, uint24) {
        // set the fee for this swap
        _setFee(poolKey, swapParams);

        // trigger hook fee claim
        _hookFeeClaim(poolKey);

        // trigger the LP locker fee claim
        _lpLockerFeeClaim(poolKey);

        // run the mev module
        _runMevModule(poolKey, swapParams, mevModuleSwapData);

        // variables to determine how to collect protocol fee
        bool token0IsBonker = bonkerIsToken0[poolKey.toId()];
        bool swappingForBonker = swapParams.zeroForOne != token0IsBonker;
        bool isExactInput = swapParams.amountSpecified < 0;

        // case: specified amount paired in, unspecified amount bonker out
        // want to: keep amountIn the same, take fee on amountIn
        // how: we modulate the specified amount being swapped DOWN, and
        // transfer the difference into the hook's account before making the swap
        if (isExactInput && swappingForBonker) {
            // since we're taking the protocol fee before the LP swap, we want to
            // take a slightly smaller amount to keep the taken LP/protocol fee at the 20% ratio,
            // this also helps us match the ExactOutput swappingForBonker scenario
            uint128 scaledProtocolFee = uint128(protocolFee) * 1e18 / (1_000_000 + protocolFee);
            int128 fee = int128(swapParams.amountSpecified * -int128(scaledProtocolFee) / 1e18);

            delta = toBeforeSwapDelta(fee, 0);
            poolManager.mint(
                address(this),
                token0IsBonker ? poolKey.currency1.toId() : poolKey.currency0.toId(),
                uint256(int256(fee))
            );
        }

        // case: specified amount paired out, unspecified amount bonker in
        // want to: increase amountOut by fee and take it
        // how: we modulate the specified amount out UP, and transfer it
        // into the hook's account
        if (!isExactInput && !swappingForBonker) {
            // we increase the protocol fee here because we want to better match
            // the ExactOutput !swappingForBonker scenario
            uint128 scaledProtocolFee = uint128(protocolFee) * 1e18 / (1_000_000 - protocolFee);
            int128 fee = int128(swapParams.amountSpecified * int128(scaledProtocolFee) / 1e18);
            delta = toBeforeSwapDelta(fee, 0);

            poolManager.mint(
                address(this),
                token0IsBonker ? poolKey.currency1.toId() : poolKey.currency0.toId(),
                uint256(int256(fee))
            );
        }

        return (BaseHook.beforeSwap.selector, delta, 0);
    }

    function _afterSwap(
        address,
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata swapParams,
        BalanceDelta delta,
        bytes calldata mevModuleSwapData
    ) internal override returns (bytes4, int128 unspecifiedDelta) {
        // variables to determine how to collect protocol fee
        bool token0IsBonker = bonkerIsToken0[poolKey.toId()];
        bool swappingForBonker = swapParams.zeroForOne != token0IsBonker;
        bool isExactInput = swapParams.amountSpecified < 0;

        // case: specified amount bonker in, unspecified amount paired out
        // want to: take fee on amount out
        // how: the change in unspecified delta is debited to the swaps account post swap,
        // in this case the amount out given to the swapper is decreased
        if (isExactInput && !swappingForBonker) {
            // grab non-bonker amount out
            int128 amountOut = token0IsBonker ? delta.amount1() : delta.amount0();
            // take fee from it
            unspecifiedDelta = amountOut * int24(protocolFee) / FEE_DENOMINATOR;
            poolManager.mint(
                address(this),
                token0IsBonker ? poolKey.currency1.toId() : poolKey.currency0.toId(),
                uint256(int256(unspecifiedDelta))
            );
        }

        // case: specified amount bonker out, unspecified amount paired in
        // want to: take fee on amount in
        // how: the change in unspecified delta is debited to the swapper's account post swap,
        // in this case the amount taken from the swapper's account is increased
        if (!isExactInput && swappingForBonker) {
            // grab non-bonker amount in
            int128 amountIn = token0IsBonker ? delta.amount1() : delta.amount0();
            // take fee from amount int
            unspecifiedDelta = amountIn * -int24(protocolFee) / FEE_DENOMINATOR;
            poolManager.mint(
                address(this),
                token0IsBonker ? poolKey.currency1.toId() : poolKey.currency0.toId(),
                uint256(int256(unspecifiedDelta))
            );
        }

        return (BaseHook.afterSwap.selector, unspecifiedDelta);
    }

    // prevent initializations that don't start via our initializePool functions
    function _beforeInitialize(address, PoolKey calldata, uint160)
        internal
        virtual
        override
        returns (bytes4)
    {
        revert UnsupportedInitializePath();
    }

    // prevent liquidity adds during mev module operation
    function _beforeAddLiquidity(
        address,
        PoolKey calldata poolKey,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) internal virtual override returns (bytes4) {
        if (
            mevModuleEnabled[poolKey.toId()]
                && block.timestamp < poolCreationTimestamp[poolKey.toId()] + MAX_MEV_MODULE_DELAY
        ) {
            revert MevModuleEnabled();
        }

        return BaseHook.beforeAddLiquidity.selector;
    }

    /// @notice Returns true if this contract implements the given interface.
    /// @param interfaceId The ERC-165 interface identifier.
    /// @return True when `interfaceId` matches {IBonkerHook}.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IBonkerHook).interfaceId;
    }

    /// @notice Returns the set of hook callbacks this hook requires from the pool manager.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}
