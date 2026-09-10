// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {V4RouterExactInput} from "./V4RouterExactInput.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {
    IUniversalRouter
} from "@uniswap/universal-router/contracts/interfaces/IUniversalRouter.sol";
import {Commands} from "@uniswap/universal-router/contracts/libraries/Commands.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

/// @title V4RouterSwap
/// @notice One-pool exact-in swap through the Uniswap Universal Router: build the `V4_SWAP`
///         calldata, approve the input through Permit2, `execute`, and report what came back.
///
/// @dev **`swapSingleHopExactIn` IS `external`, SO THIS LIBRARY IS DEPLOYED SEPARATELY AND
///      LINKED.** The compiler leaves a `__$…$__` placeholder in every contract that calls it
///      and the code runs by `DELEGATECALL` against a standalone deployment — the same shape
///      `BonkerDeployer` already has, for the same reason.
///
///      That reason is `BonkerLpLockerFeeConversion`, the one contract in this repo that lives
///      against EIP-170's 24_576-byte ceiling. Its fee-conversion swap was still emitting the
///      stock exact-input layout, which reverts with empty revert data on Robinhood Chain
///      (4663), and the one-call fix did not fit. Measured with
///      `FOUNDRY_PROFILE=lplocker forge build --via-ir`, 200 optimizer runs:
///
///      | locker | what                                                        |
///      | ------ | ----------------------------------------------------------- |
///      | 24_452 | before: stock-only encoding, broken on 4663, 124 bytes spare |
///      | 24_619 | the fix inlined: 43 bytes OVER the limit, will not deploy    |
///      | 24_371 | only the params blob moved out here: 205 bytes spare         |
///      | 23_722 | this shape — the whole swap moved out: 854 bytes spare       |
///
///      Moving the whole swap rather than just the encoder is also the cheaper of the two at
///      run time, which is the opposite of what "more work behind a `DELEGATECALL`" suggests:
///      the encoder-only split hands a ~450-byte blob back across the call boundary and pays to
///      copy it, where this returns one word. What the locker pays either way is a single cold
///      `DELEGATECALL` — 2_600 gas, against a `collectRewards` path that spends six figures
///      inside the router.
///
///      What linking obliges, and the reason this notice is this long:
///        * `deploy-chain.sh` records the library address as `V4_ROUTER_SWAP`, the way it
///          already records `BONKER_DEPLOYER`, and `verify-chain.sh` passes
///          `--libraries src/utils/V4RouterSwap.sol:V4RouterSwap:<addr>`. Without that, the
///          locker's verification fails on a bytecode mismatch that reads like a
///          compiler-settings problem and is not one.
///        * `forge script` and `forge test` deploy and link it on their own, so nothing about
///          working locally changes.
///        * The library is deployed by `DeployLpLocker.s.sol`, so it is built at the `lplocker`
///          profile's 200 runs and must be VERIFIED at 200 runs too, not the default 20k.
///
///      The layout choice itself — stock, versus the Robinhood Chain fork's extra
///      `minHopPriceX36` — is not made here. It is `V4RouterExactInput`'s, and this library only
///      forwards the flag its caller took as a constructor immutable. See
///      `docs/UNIVERSAL-ROUTER-V4-SWAP-ENCODING.md`.
library V4RouterSwap {
    /// @notice Swaps `amountIn` of `tokenIn` into `tokenOut` through `poolKey`.
    /// @dev Runs by `DELEGATECALL`, so every `address(this)` below is the CALLER's address: the
    ///      approvals are the caller's, the router pays the caller, and the balances measured
    ///      are the caller's. It reads and writes no storage of its own — a library cannot have
    ///      any — so it cannot disturb the caller's reentrancy guards or reward accounting.
    ///
    ///      `universalRouter` and `permit2` are arguments rather than constants because a
    ///      library has no immutables to hold them; the caller passes its own.
    /// @param universalRouter Router to execute through.
    /// @param permit2 Permit2 deployment the router pulls the input token from.
    /// @param poolKey Pool to swap through.
    /// @param tokenIn Token being spent.
    /// @param tokenOut Token being received.
    /// @param amountIn Exact input amount.
    /// @param amountOutMinimum Minimum output the router must produce.
    /// @param hasMinHopPrice True on a chain whose UniversalRouter is the fork that expects
    ///        `minHopPriceX36` in its exact-input params.
    /// @return Amount of `tokenOut` the caller received.
    function swapSingleHopExactIn(
        IUniversalRouter universalRouter,
        IPermit2 permit2,
        PoolKey memory poolKey,
        address tokenIn,
        address tokenOut,
        uint128 amountIn,
        uint128 amountOutMinimum,
        bool hasMinHopPrice
    ) external returns (uint256) {
        // initiate a swap command
        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = encodeSingleHopExactIn(
            poolKey, tokenIn, tokenOut, amountIn, amountOutMinimum, hasMinHopPrice
        );

        // approvals
        SafeERC20.forceApprove(IERC20(tokenIn), address(permit2), amountIn);
        permit2.approve(tokenIn, address(universalRouter), amountIn, uint48(block.timestamp));

        // Execute the swap
        uint256 tokenOutBefore = IERC20(tokenOut).balanceOf(address(this));

        universalRouter.execute(commands, inputs, block.timestamp);

        uint256 tokenOutAfter = IERC20(tokenOut).balanceOf(address(this));

        return tokenOutAfter - tokenOutBefore;
    }

    /// @notice Encodes the `V4_SWAP` command's `inputs` entry: `abi.encode(actions, params)` for
    ///         swap → settle the input → take the output.
    /// @dev `internal`, and deliberately so even though only `swapSingleHopExactIn` calls it: a
    ///      pure function returning bytes is a thing a test can pin byte-for-byte against the
    ///      assembly the locker used to inline, and `test/V4RouterSwap.t.sol` does exactly that.
    ///      The blob is otherwise unobservable — a wrong one reverts inside the router with
    ///      empty revert data, which is the whole reason this file exists. Being `internal` it
    ///      inlines into the function above and costs the deployed library nothing.
    ///
    ///      `zeroForOne` is derived rather than taken as an argument. `tokenIn` and `tokenOut`
    ///      are the pool's two currencies, so `tokenIn < tokenOut` is the same predicate as
    ///      `Currency.unwrap(poolKey.currency0) == tokenIn` — `currency0` is the lower address
    ///      by definition of a `PoolKey`. Taking it separately would let a caller hand over a
    ///      `zeroForOne` that disagrees with the `SETTLE_ALL`/`TAKE_ALL` currencies built from
    ///      those same two addresses a few lines below.
    ///
    ///      `hookData` is empty and `TAKE_ALL`'s floor is one wei, matching every other Bonker
    ///      swap; `amountOutMinimum` is the only slippage bound and it is the caller's.
    /// @param poolKey Pool to swap through.
    /// @param tokenIn Token being spent.
    /// @param tokenOut Token being received.
    /// @param amountIn Exact input amount.
    /// @param amountOutMinimum Minimum output the router must produce.
    /// @param hasMinHopPrice True on a chain whose router expects the forked struct.
    /// @return The `V4_SWAP` command's `inputs` entry.
    function encodeSingleHopExactIn(
        PoolKey memory poolKey,
        address tokenIn,
        address tokenOut,
        uint128 amountIn,
        uint128 amountOutMinimum,
        bool hasMinHopPrice
    ) internal pure returns (bytes memory) {
        // Encode V4Router actions
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL)
        );
        bytes[] memory params = new bytes[](3);

        // First parameter: SWAP_EXACT_IN_SINGLE, in the layout THIS chain's router decodes.
        params[0] = V4RouterExactInput.encodeExactInputSingle({
            poolKey: poolKey,
            zeroForOne: tokenIn < tokenOut, // swapping tokenIn -> tokenOut
            amountIn: amountIn,
            amountOutMinimum: amountOutMinimum,
            hasMinHopPrice: hasMinHopPrice
        });

        // Second parameter: SETTLE_ALL
        params[1] = abi.encode(tokenIn, uint256(amountIn));

        // Third parameter: TAKE_ALL
        params[2] = abi.encode(tokenOut, 1);

        // Combine actions and params into the single V4_SWAP input
        return abi.encode(actions, params);
    }
}
