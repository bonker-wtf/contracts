// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";

/// @title V4RouterExactInput
/// @notice Encodes the `SWAP_EXACT_IN_SINGLE` params blob in the layout the TARGET CHAIN'S
///         UniversalRouter actually decodes.
/// @dev Not every chain runs stock Uniswap. Robinhood Chain (4663) runs a UniversalRouter fork
///      whose `IV4Router` exact-input structs carry an extra `minHopPriceX36` — a per-hop price
///      floor — that stock v4-periphery has no field for:
///
///        stock: { poolKey, zeroForOne, amountIn, amountOutMinimum,                 hookData }
///        fork:  { poolKey, zeroForOne, amountIn, amountOutMinimum, minHopPriceX36, hookData }
///
///      It is INSERTED before `hookData`, not appended, so this is not a difference that stock
///      calldata survives. The fork's `CalldataDecoder.decodeSwapExactInSingleParams` only
///      lower-bounds the blob at `0x160` — exactly the size stock encoding produces — so the
///      call sails past the length check, then reads the stock `hookData` offset word as
///      `minHopPriceX36` and the stock `hookData` length word as the `hookData` offset. The
///      resulting `bytes` pointer lands far outside calldata and Solidity's own bounds check
///      reverts with EMPTY revert data, at ~1.8k gas, having made no inner call at all: no
///      selector, no message, nothing in the trace but `unlockCallback` dying instantly.
///
///      Everything else about that router looks healthy while every swap fails this way, which
///      is what makes it expensive to diagnose from behaviour alone — `WRAP_ETH`, `SWEEP`,
///      `SETTLE_ALL` and `TAKE_ALL` all work, unsupported actions answer with a proper
///      `UnsupportedAction`, and the V4Quoter keeps returning real quotes because it is a
///      separate contract whose own params struct the fork leaves alone.
///
///      Measured on mainnet 4663 against a live Bonker pool, changing nothing but the layout:
///        stock -> `0x` (empty revert), both directions.
///        fork  -> the swap executes; a buy simulates clean and a sell into a fresh
///                 single-sided pool reaches `V4TooLittleReceived(1, 0)`.
///
///      A zero `minHopPriceX36` means "no per-hop floor", so `amountOutMinimum` stays the one
///      slippage bound and the fork branch behaves identically to stock. Callers select the
///      layout with an immutable set at construction from `config/chains.js`'s
///      `v4RouterHasMinHopPrice`, so one source and one bytecode serve both kinds of chain and
///      the choice is made once, at deploy time, from the registry rather than from memory.
///
///      See `docs/UNIVERSAL-ROUTER-V4-SWAP-ENCODING.md` and `docs/ADDING-A-CHAIN.md` Phase 5.
library V4RouterExactInput {
    /// @notice Mirror of the FORKED router's `IV4Router.ExactInputSingleParams`.
    /// @dev Declared here rather than imported because stock `@uniswap/v4-periphery` has no
    ///      such struct. Member order copied from the verified source of the router at
    ///      0x8876789976dEcBfCbBbe364623C63652db8C0904,
    ///      `src/pkgs/universal-router/lib/v4-periphery/src/interfaces/IV4Router.sol`.
    ///      Nothing in `src/` encodes through this struct — `encodeExactInputSingle` writes the
    ///      words directly, because two `abi.encode` overloads over two dynamic structs cost
    ///      ~300 bytes of encoder and `BonkerLpLockerFeeConversion` has ~120 bytes of EIP-170
    ///      headroom. It exists so the layout stays declared in Solidity, and
    ///      `test/V4RouterExactInput.t.sol` asserts this function is byte-for-byte identical to
    ///      `abi.encode` of it and of the stock struct. Change one, that test fails.
    struct ExactInputSingleParamsWithMinHopPrice {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        uint256 minHopPriceX36;
        bytes hookData;
    }

    /// @notice ABI-encodes the params blob for the `SWAP_EXACT_IN_SINGLE` action, with empty
    ///         hook data.
    /// @dev Every Bonker-built swap passes empty `hookData`, and the name says so rather than
    ///      accepting a `bytes` argument it would have to ignore: with `hookData` fixed empty
    ///      the whole blob is a run of constant-width words, which is what keeps this cheap
    ///      enough for the LP locker. A caller that needs real hook data must not reach for
    ///      this function.
    /// @param poolKey Pool to swap through.
    /// @param zeroForOne True when the input currency is the pool's `currency0`.
    /// @param amountIn Exact input amount.
    /// @param amountOutMinimum Minimum output the router must produce.
    /// @param hasMinHopPrice True on a chain whose router expects the forked struct.
    /// @return The blob to place at `params[0]` of the `V4_SWAP` action payload.
    function encodeExactInputSingle(
        PoolKey memory poolKey,
        bool zeroForOne,
        uint128 amountIn,
        uint128 amountOutMinimum,
        bool hasMinHopPrice
    ) internal pure returns (bytes memory) {
        // The struct is dynamic (it ends in `bytes`), so the blob opens with an offset to it.
        // `tickSpacing` is an int24 and must be SIGN-extended — every Bonker pool uses a
        // positive 200, but a zero-extended negative tick would decode as a huge positive one.
        uint256 currency0 = uint256(uint160(Currency.unwrap(poolKey.currency0)));
        uint256 currency1 = uint256(uint160(Currency.unwrap(poolKey.currency1)));
        uint256 tickSpacing = uint256(int256(poolKey.tickSpacing));
        uint256 hooks = uint256(uint160(address(poolKey.hooks)));

        // One encoding, twelve words, with the two that differ selected inline — rather than
        // two `abi.encodePacked` branches, which cost ~260 bytes and put
        // `BonkerLpLockerFeeConversion` over EIP-170.
        //
        //   stock (11 words, 0x160): [0]=0x20 [1..5]=poolKey [6]=zeroForOne [7]=amountIn
        //                            [8]=amountOutMinimum [9]=hookData offset 0x120
        //                            [10]=hookData length 0
        //   fork  (12 words, 0x180): ... [9]=minHopPriceX36 0 [10]=hookData offset 0x140
        //                            [11]=hookData length 0
        //
        // Word 11 is written either way and then trimmed off for the stock layout, because
        // shortening the buffer is one `mstore` where a second encoder is a second copy loop.
        bytes memory blob = abi.encodePacked(
            uint256(0x20), // offset to the struct
            currency0,
            currency1,
            uint256(poolKey.fee),
            tickSpacing,
            hooks,
            zeroForOne ? uint256(1) : uint256(0),
            uint256(amountIn),
            uint256(amountOutMinimum),
            hasMinHopPrice ? uint256(0) : uint256(0x120), // minHopPriceX36 | hookData offset
            hasMinHopPrice ? uint256(0x140) : uint256(0), // hookData offset | hookData length
            uint256(0) // hookData length (fork only; trimmed below for stock)
        );

        if (!hasMinHopPrice) {
            // Memory-safe: this only shrinks the buffer's length word. The trailing word stays
            // allocated and unreferenced.
            assembly ("memory-safe") {
                mstore(blob, 0x160)
            }
        }

        return blob;
    }

    /// @notice The stock struct, encoded the ordinary way.
    /// @dev Only `test/V4RouterExactInput.t.sol` calls this — it is the reference
    ///      `encodeExactInputSingle`'s stock branch is asserted equal to. Keeping it here
    ///      rather than in the test file means the reference lives beside the thing it
    ///      references.
    function referenceEncodeStock(
        PoolKey memory poolKey,
        bool zeroForOne,
        uint128 amountIn,
        uint128 amountOutMinimum
    ) internal pure returns (bytes memory) {
        return abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: poolKey,
                zeroForOne: zeroForOne,
                amountIn: amountIn,
                amountOutMinimum: amountOutMinimum,
                hookData: bytes("")
            })
        );
    }

    /// @notice The forked struct, encoded the ordinary way.
    /// @dev Test-only reference, same reason as `referenceEncodeStock`.
    function referenceEncodeFork(
        PoolKey memory poolKey,
        bool zeroForOne,
        uint128 amountIn,
        uint128 amountOutMinimum
    ) internal pure returns (bytes memory) {
        return abi.encode(
            ExactInputSingleParamsWithMinHopPrice({
                poolKey: poolKey,
                zeroForOne: zeroForOne,
                amountIn: amountIn,
                amountOutMinimum: amountOutMinimum,
                minHopPriceX36: 0,
                hookData: bytes("")
            })
        );
    }
}
