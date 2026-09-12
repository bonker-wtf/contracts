// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {V4RouterExactInput} from "../src/utils/V4RouterExactInput.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Test} from "forge-std/Test.sol";

/// @notice `V4RouterExactInput.encodeExactInputSingle` writes the params blob word by word
///         instead of calling `abi.encode` on a struct, because two ABI encoders do not fit in
///         `BonkerLpLockerFeeConversion`'s EIP-170 budget. These tests are what makes that safe:
///         every case asserts the hand-written bytes are byte-for-byte identical to what the
///         compiler produces from the corresponding struct.
///
///         The stock reference is `IV4Router.ExactInputSingleParams` straight from stock
///         v4-periphery; the fork reference is
///         `V4RouterExactInput.ExactInputSingleParamsWithMinHopPrice`, whose member order is
///         copied from Robinhood Chain's verified router source. If either upstream struct ever
///         changes shape, these fail rather than shipping calldata that reverts with nothing in
///         it — which is exactly how this bug class hides.
contract V4RouterExactInputTest is Test {
    // Bonker's real pool constants: dynamic-fee flag and tickSpacing 200.
    uint24 constant DYNAMIC_FEE_FLAG = 0x800000;
    int24 constant TICK_SPACING = 200;

    function _poolKey(int24 tickSpacing) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73)),
            currency1: Currency.wrap(address(0x172691C26e8fC73b64AB5fF8bCB404b3D3d025D5)),
            fee: DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0x79e394e79C54936C7582452736d18890cE1368cC))
        });
    }

    function testStockLayoutMatchesAbiEncodeOfStockStruct() public pure {
        PoolKey memory key = _poolKey(TICK_SPACING);
        bytes memory built = V4RouterExactInput.encodeExactInputSingle(key, true, 1 ether, 1, false);

        assertEq(built, V4RouterExactInput.referenceEncodeStock(key, true, 1 ether, 1));
        // 11 words: offset, 5 poolKey, zeroForOne, amountIn, amountOutMinimum, hookData
        // offset, hookData length.
        assertEq(built.length, 0x160);
    }

    function testForkLayoutMatchesAbiEncodeOfForkStruct() public pure {
        PoolKey memory key = _poolKey(TICK_SPACING);
        bytes memory built = V4RouterExactInput.encodeExactInputSingle(key, true, 1 ether, 1, true);

        assertEq(built, V4RouterExactInput.referenceEncodeFork(key, true, 1 ether, 1));
        // One word longer than stock: `minHopPriceX36` is INSERTED, not appended.
        assertEq(built.length, 0x180);
    }

    /// @dev The whole bug in one assertion. The two layouts must differ, and by exactly one
    ///      word — a change that made them equal would silently restore the broken behaviour.
    function testTheTwoLayoutsDifferByExactlyOneWord() public pure {
        PoolKey memory key = _poolKey(TICK_SPACING);
        bytes memory stock = V4RouterExactInput.encodeExactInputSingle(key, true, 1 ether, 1, false);
        bytes memory fork_ = V4RouterExactInput.encodeExactInputSingle(key, true, 1 ether, 1, true);

        assertEq(fork_.length - stock.length, 0x20);
        assertTrue(keccak256(stock) != keccak256(fork_));

        // Both agree through amountOutMinimum (words 0..8); they part at word 9.
        for (uint256 w = 0; w < 9; w++) {
            assertEq(_word(stock, w), _word(fork_, w));
        }
        // Stock word 9 is the hookData offset; the fork reads that slot as `minHopPriceX36`,
        // which is why stock calldata makes the fork see 0x120 as a per-hop price floor and
        // then follows a hookData offset of 0 straight out of bounds.
        assertEq(_word(stock, 9), 0x120);
        assertEq(_word(stock, 10), 0);
        assertEq(_word(fork_, 9), 0); // minHopPriceX36: no per-hop floor
        assertEq(_word(fork_, 10), 0x140);
        assertEq(_word(fork_, 11), 0);
    }

    function testZeroForOneFalseEncodesFalseInBothLayouts() public pure {
        PoolKey memory key = _poolKey(TICK_SPACING);
        assertEq(
            V4RouterExactInput.encodeExactInputSingle(key, false, 7, 3, false),
            V4RouterExactInput.referenceEncodeStock(key, false, 7, 3)
        );
        assertEq(
            V4RouterExactInput.encodeExactInputSingle(key, false, 7, 3, true),
            V4RouterExactInput.referenceEncodeFork(key, false, 7, 3)
        );
    }

    /// @dev `tickSpacing` is an int24. Bonker only ever uses +200, but a zero-extended negative
    ///      tick decodes as a huge positive one, so the sign extension is asserted rather than
    ///      assumed.
    function testNegativeTickSpacingIsSignExtended() public pure {
        PoolKey memory key = _poolKey(-60);
        bytes memory stock = V4RouterExactInput.encodeExactInputSingle(key, true, 1, 1, false);
        bytes memory fork_ = V4RouterExactInput.encodeExactInputSingle(key, true, 1, 1, true);

        assertEq(stock, V4RouterExactInput.referenceEncodeStock(key, true, 1, 1));
        assertEq(fork_, V4RouterExactInput.referenceEncodeFork(key, true, 1, 1));
        assertEq(_word(stock, 4), uint256(int256(-60)));
    }

    function testFuzzMatchesTheCompilerForBothLayouts(
        address currency0,
        address currency1,
        uint24 fee,
        int24 tickSpacing,
        address hooks,
        bool zeroForOne,
        uint128 amountIn,
        uint128 amountOutMinimum
    ) public pure {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hooks)
        });

        assertEq(
            V4RouterExactInput.encodeExactInputSingle(
                key, zeroForOne, amountIn, amountOutMinimum, false
            ),
            V4RouterExactInput.referenceEncodeStock(key, zeroForOne, amountIn, amountOutMinimum)
        );
        assertEq(
            V4RouterExactInput.encodeExactInputSingle(
                key, zeroForOne, amountIn, amountOutMinimum, true
            ),
            V4RouterExactInput.referenceEncodeFork(key, zeroForOne, amountIn, amountOutMinimum)
        );
    }

    function _word(bytes memory blob, uint256 index) internal pure returns (uint256 value) {
        assembly {
            value := mload(add(add(blob, 0x20), mul(index, 0x20)))
        }
    }
}
