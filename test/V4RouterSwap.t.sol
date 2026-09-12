// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {V4RouterSwap} from "../src/utils/V4RouterSwap.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {
    IUniversalRouter
} from "@uniswap/universal-router/contracts/interfaces/IUniversalRouter.sol";
import {Commands} from "@uniswap/universal-router/contracts/libraries/Commands.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Records everything the router is handed, and pays the caller the way a real swap
///         would, so the delegatecall can be observed from both ends.
contract RecordingRouter {
    bytes public commands;
    bytes public input0;
    uint256 public inputCount;
    uint256 public deadline;

    MintableToken public payout;
    uint256 public payoutAmount;

    function setPayout(MintableToken payout_, uint256 amount_) external {
        payout = payout_;
        payoutAmount = amount_;
    }

    function execute(bytes calldata commands_, bytes[] calldata inputs_, uint256 deadline_)
        external
        payable
    {
        commands = commands_;
        inputCount = inputs_.length;
        input0 = inputs_[0];
        deadline = deadline_;
        payout.mint(msg.sender, payoutAmount);
    }
}

contract RecordingPermit2 {
    address public token;
    address public spender;
    uint160 public amount;
    uint48 public expiration;

    function approve(address token_, address spender_, uint160 amount_, uint48 expiration_)
        external
    {
        token = token_;
        spender = spender_;
        amount = amount_;
        expiration = expiration_;
    }
}

contract MintableToken is ERC20 {
    constructor() ERC20("Mock", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Stands in for `BonkerLpLockerFeeConversion`: a contract that reaches the library the
///         way the deployed locker does, by `DELEGATECALL` into its linked address. Nothing here
///         can be exercised by calling the library from a test directly — that would be a plain
///         internal call and would not prove the linked deployment works at all.
contract LinkedCaller {
    function swap(
        IUniversalRouter universalRouter,
        IPermit2 permit2,
        PoolKey memory poolKey,
        address tokenIn,
        address tokenOut,
        uint128 amountIn,
        bool hasMinHopPrice
    ) external returns (uint256) {
        return V4RouterSwap.swapSingleHopExactIn(
            universalRouter, permit2, poolKey, tokenIn, tokenOut, amountIn, 0, hasMinHopPrice
        );
    }
}

/// @notice `V4RouterSwap` exists to move `BonkerLpLockerFeeConversion`'s swap-calldata assembly
///         off that contract's EIP-170 budget, and it changed the exact-input params layout to
///         the per-chain one at the same time. Both of those are invisible from outside: a
///         wrong blob reverts inside the Universal Router with EMPTY revert data.
///
///         So the property these tests pin is the one that matters on Base — that with
///         `hasMinHopPrice = false` the library reproduces, byte for byte, the blob the locker
///         assembled inline before the library existed. If that ever stops holding, Base's fee
///         conversions change behaviour, and this fails instead.
contract V4RouterSwapTest is Test {
    // Bonker's real pool constants: dynamic-fee flag and tickSpacing 200.
    uint24 constant DYNAMIC_FEE_FLAG = 0x800000;
    int24 constant TICK_SPACING = 200;

    address constant TOKEN = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant WETH = 0x172691C26e8fC73b64AB5fF8bCB404b3D3d025D5;

    function _poolKey() internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(TOKEN),
            currency1: Currency.wrap(WETH),
            fee: DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0x79e394e79C54936C7582452736d18890cE1368cC))
        });
    }

    /// @dev Verbatim copy of what `BonkerLpLockerFeeConversion._uniSwapLocked` built inline
    ///      before `V4RouterSwap` existed — stock `IV4Router.ExactInputSingleParams` and all.
    ///      This is the thing Base's locker has been sending since it was deployed, so it is
    ///      the reference the stock branch must not drift from.
    function _legacyInlineAssembly(
        PoolKey memory poolKey,
        address tokenIn,
        address tokenOut,
        uint128 amountIn,
        uint128 amountOutMinimum
    ) internal pure returns (bytes memory) {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL)
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: poolKey,
                zeroForOne: tokenIn < tokenOut,
                amountIn: amountIn,
                amountOutMinimum: amountOutMinimum,
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(tokenIn, uint256(amountIn));
        params[2] = abi.encode(tokenOut, 1);
        return abi.encode(actions, params);
    }

    /// @dev The one that protects Base. `amountOutMinimum` is 0 because that is what the locker
    ///      passes on the fee-conversion path.
    function testStockBranchIsByteIdenticalToTheOldInlineAssembly() public pure {
        assertEq(
            V4RouterSwap.encodeSingleHopExactIn(_poolKey(), TOKEN, WETH, 1 ether, 0, false),
            _legacyInlineAssembly(_poolKey(), TOKEN, WETH, 1 ether, 0)
        );
    }

    function testStockBranchMatchesInTheOtherSwapDirectionToo() public pure {
        assertEq(
            V4RouterSwap.encodeSingleHopExactIn(_poolKey(), WETH, TOKEN, 5, 7, false),
            _legacyInlineAssembly(_poolKey(), WETH, TOKEN, 5, 7)
        );
    }

    /// @dev Robinhood Chain's fork inserts `minHopPriceX36` before `hookData`, so the fork blob
    ///      must differ — and differ by exactly the one word `V4RouterExactInput` adds. Equal
    ///      blobs would mean the layout switch silently stopped happening, which is the failure
    ///      that costs a redeploy to notice.
    function testForkBranchDiffersFromStockByExactlyOneWord() public pure {
        bytes memory stock =
            V4RouterSwap.encodeSingleHopExactIn(_poolKey(), TOKEN, WETH, 1 ether, 0, false);
        bytes memory fork_ =
            V4RouterSwap.encodeSingleHopExactIn(_poolKey(), TOKEN, WETH, 1 ether, 0, true);

        assertEq(fork_.length - stock.length, 0x20);
        assertTrue(keccak256(stock) != keccak256(fork_));
    }

    /// @dev The blob is what the router decodes, so decode it the way the router does: three
    ///      actions in the documented order, three params, and a `params[0]` that is a valid
    ///      stock `ExactInputSingleParams`.
    function testStockBlobDecodesAsTheRouterWouldReadIt() public pure {
        (bytes memory actions, bytes[] memory params) = abi.decode(
            V4RouterSwap.encodeSingleHopExactIn(_poolKey(), TOKEN, WETH, 1 ether, 0, false),
            (bytes, bytes[])
        );

        assertEq(actions.length, 3);
        assertEq(uint8(actions[0]), uint8(Actions.SWAP_EXACT_IN_SINGLE));
        assertEq(uint8(actions[1]), uint8(Actions.SETTLE_ALL));
        assertEq(uint8(actions[2]), uint8(Actions.TAKE_ALL));
        assertEq(params.length, 3);

        IV4Router.ExactInputSingleParams memory swap =
            abi.decode(params[0], (IV4Router.ExactInputSingleParams));
        assertTrue(swap.zeroForOne); // TOKEN < WETH for these two constants
        assertEq(swap.amountIn, 1 ether);
        assertEq(swap.amountOutMinimum, 0);
        assertEq(swap.hookData.length, 0);
        assertEq(Currency.unwrap(swap.poolKey.currency0), TOKEN);

        // SETTLE_ALL pays the input; TAKE_ALL pulls the output with a one-wei floor.
        (address settleCurrency, uint256 maxAmountIn) = abi.decode(params[1], (address, uint256));
        assertEq(settleCurrency, TOKEN);
        assertEq(maxAmountIn, 1 ether);
        (address takeCurrency, uint256 minAmountOut) = abi.decode(params[2], (address, uint256));
        assertEq(takeCurrency, WETH);
        assertEq(minAmountOut, 1);
    }

    /// @dev `encodeSingleHopExactIn` derives `zeroForOne` as `tokenIn < tokenOut` rather than
    ///      taking it as an argument, on the grounds that it is the same predicate as
    ///      `currency0 == tokenIn` for the pool's own two currencies. That claim is the reason
    ///      the argument was dropped, so it gets asserted rather than believed.
    function testFuzzZeroForOneAgreesWithTheCurrency0Comparison(
        address a,
        address b,
        bool inIsFirst
    ) public pure {
        vm.assume(a != b);
        (address currency0, address currency1) = a < b ? (a, b) : (b, a);
        (address tokenIn, address tokenOut) =
            inIsFirst ? (currency0, currency1) : (currency1, currency0);

        assertEq(tokenIn < tokenOut, currency0 == tokenIn);
    }

    function testFuzzStockBranchNeverDriftsFromTheOldInlineAssembly(
        address currency0,
        address currency1,
        uint24 fee,
        int24 tickSpacing,
        address hooks,
        bool inIsFirst,
        uint128 amountIn,
        uint128 amountOutMinimum
    ) public pure {
        vm.assume(currency0 != currency1);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hooks)
        });
        (address tokenIn, address tokenOut) =
            inIsFirst ? (currency0, currency1) : (currency1, currency0);

        assertEq(
            V4RouterSwap.encodeSingleHopExactIn(
                key, tokenIn, tokenOut, amountIn, amountOutMinimum, false
            ),
            _legacyInlineAssembly(key, tokenIn, tokenOut, amountIn, amountOutMinimum)
        );
    }

    // ---------------------------------------------------------------- the linked path

    /// @dev Everything above tests the encoder as an internal call. This one goes through the
    ///      shape that actually ships: a contract holding a link placeholder, `DELEGATECALL`ing
    ///      the separately deployed library, which then approves and calls the router. What the
    ///      router receives is asserted against the same legacy reference — so the split into a
    ///      linked library is proven not to have changed the calldata, not just the encoder.
    function testDelegatecallIntoTheLinkedLibraryHandsTheRouterTheSameCalldata() public {
        MintableToken tokenIn = new MintableToken();
        MintableToken tokenOut = new MintableToken();
        RecordingRouter router = new RecordingRouter();
        RecordingPermit2 permit2 = new RecordingPermit2();
        LinkedCaller caller = new LinkedCaller();

        tokenIn.mint(address(caller), 10 ether);
        router.setPayout(tokenOut, 3 ether);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(tokenIn)),
            currency1: Currency.wrap(address(tokenOut)),
            fee: DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });

        uint256 received = caller.swap(
            IUniversalRouter(address(router)),
            IPermit2(address(permit2)),
            key,
            address(tokenIn),
            address(tokenOut),
            1 ether,
            false
        );

        // The return value is the caller's balance delta, measured on the caller — proof the
        // library ran in the caller's context and not its own.
        assertEq(received, 3 ether);
        assertEq(tokenOut.balanceOf(address(caller)), 3 ether);

        // One V4_SWAP command, one input, and that input is byte-for-byte the legacy blob.
        assertEq(router.commands(), abi.encodePacked(uint8(Commands.V4_SWAP)));
        assertEq(router.inputCount(), 1);
        assertEq(router.deadline(), block.timestamp);
        assertEq(
            router.input0(),
            _legacyInlineAssembly(key, address(tokenIn), address(tokenOut), 1 ether, 0)
        );

        // Approvals are the CALLER's, not the library's: ERC20 allowance to Permit2, then
        // Permit2 allowance to the router.
        assertEq(tokenIn.allowance(address(caller), address(permit2)), 1 ether);
        assertEq(permit2.token(), address(tokenIn));
        assertEq(permit2.spender(), address(router));
        assertEq(permit2.amount(), 1 ether);
        assertEq(permit2.expiration(), uint48(block.timestamp));
    }

    /// @dev The flag has to survive the delegatecall — this is the assertion that would have
    ///      caught the original bug had the locker been reachable this way.
    function testDelegatecallCarriesTheForkLayoutThrough() public {
        MintableToken tokenIn = new MintableToken();
        MintableToken tokenOut = new MintableToken();
        RecordingRouter router = new RecordingRouter();
        LinkedCaller caller = new LinkedCaller();

        tokenIn.mint(address(caller), 10 ether);
        router.setPayout(tokenOut, 1);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(tokenIn)),
            currency1: Currency.wrap(address(tokenOut)),
            fee: DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });

        caller.swap(
            IUniversalRouter(address(router)),
            IPermit2(address(new RecordingPermit2())),
            key,
            address(tokenIn),
            address(tokenOut),
            1 ether,
            true
        );

        assertEq(
            router.input0(),
            V4RouterSwap.encodeSingleHopExactIn(
                key, address(tokenIn), address(tokenOut), 1 ether, 0, true
            )
        );
        // And NOT the stock blob — the one the live 4663 router answers with `0x`.
        assertTrue(
            keccak256(router.input0())
                != keccak256(
                    _legacyInlineAssembly(key, address(tokenIn), address(tokenOut), 1 ether, 0)
                )
        );
    }
}
