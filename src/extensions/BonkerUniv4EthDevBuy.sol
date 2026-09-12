// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IBonker} from "../interfaces/IBonker.sol";
import {IBonkerExtension} from "../interfaces/IBonkerExtension.sol";

import {IBonkerUniv4EthDevBuy} from "./interfaces/IBonkerUniv4EthDevBuy.sol";

import {V4RouterExactInput} from "../utils/V4RouterExactInput.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {
    IUniversalRouter
} from "@uniswap/universal-router/contracts/interfaces/IUniversalRouter.sol";
import {Commands} from "@uniswap/universal-router/contracts/libraries/Commands.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

/// @title BonkerUniv4EthDevBuy
/// @notice Uses launch ETH to buy newly deployed tokens through one or two Uniswap V4 swaps.
/// @dev The factory is the only allowed caller. This extension expects zero reserved token supply
///      because all value comes from the attached ETH payment.
contract BonkerUniv4EthDevBuy is ReentrancyGuard, IBonkerUniv4EthDevBuy {
    IBonker public immutable factory;
    IWETH9 public immutable weth;
    IUniversalRouter public immutable universalRouter;
    IPermit2 public immutable permit2;
    /// @notice True when this chain's UniversalRouter is a fork whose `IV4Router` exact-input
    ///         structs carry an extra `minHopPriceX36` member (Robinhood Chain, 4663).
    /// @dev Set at deploy time from `config/chains.js`'s `v4RouterHasMinHopPrice`. Sending the
    ///      stock layout to such a router reverts with EMPTY revert data before it makes a
    ///      single inner call, so this cannot be discovered from a failing swap's trace — see
    ///      `V4RouterExactInput` for the layouts side by side and the measurements.
    bool public immutable v4RouterHasMinHopPrice;

    modifier onlyFactory() {
        if (msg.sender != address(factory)) revert Unauthorized();
        _;
    }

    /// @param factory_ Bonker factory authorized to invoke the extension.
    /// @param weth_ Wrapped native token used as the intermediate buy asset.
    /// @param universalRouter_ Uniswap universal router used for V4 swaps.
    /// @param permit2_ Permit2 contract approved for transient token spends.
    /// @param v4RouterHasMinHopPrice_ True on a chain whose UniversalRouter is the fork that
    ///        expects `minHopPriceX36` in its exact-input params.
    constructor(
        address factory_,
        address weth_,
        address universalRouter_,
        address permit2_,
        bool v4RouterHasMinHopPrice_
    ) {
        factory = IBonker(factory_);
        weth = IWETH9(weth_);
        universalRouter = IUniversalRouter(universalRouter_);
        permit2 = IPermit2(permit2_);
        v4RouterHasMinHopPrice = v4RouterHasMinHopPrice_;
    }

    /// @notice Consumes launch ETH to buy the freshly deployed token for the configured recipient.
    /// @dev Requires the extension's configured `msgValue` to exactly match the ETH sent and
    ///      enforces zero `extensionBps`/`extensionSupply` because no token allocation is reserved.
    /// @param deploymentConfig Deployment config supplied by the factory.
    /// @param tokenPoolKey Uniswap V4 pool used for the final paired-token to token swap.
    /// @param token Newly deployed token address being purchased.
    /// @param extensionSupply Reserved extension token amount, expected to be zero.
    /// @param extensionIndex Index of this extension inside `deploymentConfig.extensionConfigs`.
    function receiveTokens(
        IBonker.DeploymentConfig calldata deploymentConfig,
        PoolKey memory tokenPoolKey,
        address token,
        uint256 extensionSupply,
        uint256 extensionIndex
    ) external payable nonReentrant onlyFactory {
        // ensure that the msgValue matches what was requested and is not zero
        if (
            deploymentConfig.extensionConfigs[extensionIndex].msgValue != msg.value
                || deploymentConfig.extensionConfigs[extensionIndex].msgValue == 0
        ) {
            revert IBonkerExtension.InvalidMsgValue();
        }

        // check the dev-buy percentage is zero
        if (
            deploymentConfig.extensionConfigs[extensionIndex].extensionBps != 0
                || extensionSupply != 0
        ) {
            revert InvalidEthDevBuyPercentage();
        }

        // decode the dev buy data
        Univ4EthDevBuyExtensionData memory devBuyData = abi.decode(
            deploymentConfig.extensionConfigs[extensionIndex].extensionData,
            (Univ4EthDevBuyExtensionData)
        );

        // perform the dev buy
        uint256 tokenAmount = _performDevBuy(
            token, deploymentConfig.poolConfig.pairedToken, tokenPoolKey, devBuyData
        );

        // transfer the token to the recipient
        SafeERC20.safeTransfer(IERC20(token), devBuyData.recipient, tokenAmount);

        emit EthDevBuy(token, devBuyData.recipient, msg.value, tokenAmount);
    }

    /// @notice Executes the ETH -> paired token -> launched token purchase flow.
    /// @param token Newly deployed token address being purchased.
    /// @param pairedToken Token paired against the launched token in the V4 pool.
    /// @param tokenPoolKey Uniswap V4 pool used for the final paired-token to token swap.
    /// @param devBuyData Encoded intermediate pool information and slippage guardrails.
    /// @return Amount of launched tokens acquired for the recipient.
    function _performDevBuy(
        address token,
        address pairedToken,
        PoolKey memory tokenPoolKey,
        Univ4EthDevBuyExtensionData memory devBuyData
    ) internal returns (uint256) {
        uint128 amountPairedToken = uint128(msg.value);

        // if the paired token is not weth, we need to swap from weth to paired token
        if (pairedToken != address(weth)) {
            PoolKey memory pairedTokenPoolKey = devBuyData.pairedTokenPoolKey;
            uint128 pairedTokenAmountOutMinimum = devBuyData.pairedTokenAmountOutMinimum;
            address currency0 = Currency.unwrap(pairedTokenPoolKey.currency0);
            address currency1 = Currency.unwrap(pairedTokenPoolKey.currency1);

            // check that the first pool to swap on is paired with W/ETH
            bool pairedTokenIsToken0 = currency0 == pairedToken;
            if (pairedTokenIsToken0) {
                // currency1 should be weth (if this was an ETH pair, currency0 would be ETH)
                if (currency1 != address(weth)) {
                    revert InvalidPairedTokenPoolKey();
                }
            } else {
                // currency0 should be W/ETH and currency1 should be paired token
                if (
                    (currency0 != address(weth) && currency0 != address(0))
                        || currency1 != pairedToken
                ) {
                    revert InvalidPairedTokenPoolKey();
                }
            }

            // convert ETH to WETH if needed and approve the spend
            // if paired token's paired token is weth
            if (pairedTokenIsToken0 ? currency1 == address(weth) : currency0 == address(weth)) {
                weth.deposit{value: amountPairedToken}();
                SafeERC20.forceApprove(IERC20(weth), address(permit2), amountPairedToken);
                permit2.approve(
                    address(weth),
                    address(universalRouter),
                    amountPairedToken,
                    uint48(block.timestamp)
                );
            }

            // swap from W/ETH to paired token
            amountPairedToken = uint128(
                _univ4Swap(
                    pairedTokenPoolKey,
                    pairedTokenIsToken0 ? currency1 : currency0,
                    pairedTokenIsToken0 ? currency0 : currency1,
                    amountPairedToken,
                    pairedTokenAmountOutMinimum
                )
            );
        }

        // if paired is weth, swap from ETH to weth
        // note: univ4 supports ETH as a currency, but we only allow WETH
        if (pairedToken == address(weth)) {
            weth.deposit{value: amountPairedToken}();
        }

        // approve the paired token to be spent by the router
        SafeERC20.forceApprove(IERC20(pairedToken), address(permit2), amountPairedToken);
        permit2.approve(
            pairedToken, address(universalRouter), amountPairedToken, uint48(block.timestamp)
        );

        // swap from paired token to new token
        return _univ4Swap(tokenPoolKey, pairedToken, token, amountPairedToken, 1);
    }

    /// @notice Executes a single-pool Uniswap V4 exact-in swap through the universal router.
    /// @param poolKey Pool used for the swap.
    /// @param tokenIn Token being spent.
    /// @param tokenOut Token being received.
    /// @param amountIn Exact input amount.
    /// @param amountOutMinimum Minimum output amount enforced by the router.
    /// @return Amount of `tokenOut` received by this contract.
    function _univ4Swap(
        PoolKey memory poolKey,
        address tokenIn,
        address tokenOut,
        uint128 amountIn,
        uint128 amountOutMinimum
    ) internal returns (uint256) {
        // initiate a swap command
        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));

        // Encode V4Router actions
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL)
        );
        bytes[] memory params = new bytes[](3);

        // token ordering
        bool tokenInIsToken0 = Currency.unwrap(poolKey.currency0) == tokenIn;

        // First parameter: SWAP_EXACT_IN_SINGLE, in the layout THIS chain's router decodes.
        params[0] = V4RouterExactInput.encodeExactInputSingle({
            poolKey: poolKey,
            zeroForOne: tokenInIsToken0, // swapping tokenIn -> tokenOut
            amountIn: amountIn, // amount of tokenIn to swap
            amountOutMinimum: amountOutMinimum, // minimum amount we expect to receive
            // no hook data needed, assuming we're using simple hooks
            hasMinHopPrice: v4RouterHasMinHopPrice
        });

        // Second parameter: SETTLE_ALL
        params[1] = abi.encode(tokenIn, uint256(amountIn));

        // Third parameter: TAKE_ALL
        params[2] = abi.encode(tokenOut, 1);

        // Combine actions and params into inputs
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        // Execute the swap
        uint256 tokenOutBefore = IERC20(tokenOut).balanceOf(address(this));

        universalRouter.execute{
            value: Currency.unwrap(poolKey.currency0) == address(0) ? amountIn : 0
        }(
            commands, inputs, block.timestamp
        );

        uint256 tokenOutAfter = IERC20(tokenOut).balanceOf(address(this));

        return tokenOutAfter - tokenOutBefore;
    }

    /// @notice Returns true for the `IBonkerExtension` ERC-165 interface ID.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IBonkerExtension).interfaceId;
    }
}
