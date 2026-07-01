# Universal Router V4 Swap Encoding

Reference for how Bonker hand-builds Uniswap Universal Router `execute(commands, inputs, deadline)` calldata to swap against its dynamic-fee v4 pools; read this before changing any buy/sell path, dev-buy extension, or sniper util that calls `IUniversalRouter.execute`.

Every Bonker swap that is not a normal user wallet swap goes through the same Universal Router calldata grammar: a top-level `commands` byte string, a parallel `inputs` array, and — for the `V4_SWAP` command — a nested `(bytes actions, bytes[] params)` payload. This page is the single place that documents that grammar, the command byte table, the two coexisting action encodings (`SWAP_EXACT_IN` multi-hop in JS scripts vs `SWAP_EXACT_IN_SINGLE` in Solidity), the `SETTLE`/`TAKE` settlement actions, the Permit2 approval triad, and the recipient sentinel addresses. Natural-language queries like `V4_SWAP`, `SWAP_EXACT_IN_SINGLE`, `SETTLE_ALL`, `TAKE_ALL`, `Commands.V4_SWAP`, `Actions`, `ExactInputSingleParams`, `PathKey`, `ROUTER_INTERNAL`, `0x800000`, `tickSpacing 200`, "wrap ETH before swap", "amountOutMinimum 1", or "Permit2 approve to Universal Router" should land here.

## Why It Exists

Bonker tokens trade in Uniswap v4 pools that carry a custom hook (`DYNAMIC_HOOK` / `STATIC_HOOK`). The v4 PoolManager has no public swap function — all swaps route through a periphery contract. Bonker uses the canonical Base **Universal Router** at `0x6fF5693b99212Da76ad316178A184AB56D299b43` rather than a thin V4 router because the same call must also wrap/unwrap ETH around the swap.

There is no SDK in this repo that builds this calldata. Each call site assembles the bytes by hand, so the same encoding is duplicated in operator scripts, two dev-buy extensions, and the sniper auction util. When any of the pool constants (`fee`, `tickSpacing`, hook address) or the action byte sequence drifts in one place, the others silently diverge. This reference exists so a change to one swap path can be checked against the shared contract instead of reverse-engineered from each file again.

The subtle part is that the codebase contains **two different but functionally equivalent action encodings**. JavaScript operator scripts encode a multi-hop `SWAP_EXACT_IN` with a `PathKey[]` path and the non-`ALL` `SETTLE`/`TAKE` actions. Solidity contracts encode a single-pool `SWAP_EXACT_IN_SINGLE` with `SETTLE_ALL`/`TAKE_ALL`. Both produce the same one-hop swap against the same pool, but their action bytes and per-action `params` shapes are not interchangeable.

## Key Files

| File | Why it matters |
| --- | --- |
| `scripts/buy-token.mjs:28` | JS command/action byte constants for the buy direction (`WRAP_ETH` + `V4_SWAP`). |
| `scripts/buy-token.mjs:75` | Builds the multi-hop `SWAP_EXACT_IN` swap param with a `PathKey[]` path. |
| `scripts/buy-token.mjs:125` | Concatenates `[WRAP_ETH, V4_SWAP]` commands and calls `execute` with `value`. |
| `scripts/sell-token.mjs:30` | JS command/action constants for the sell direction (`V4_SWAP` + `UNWRAP_WETH`). |
| `scripts/sell-token.mjs:91` | Permit2 approval triad: ERC20 `approve` to Permit2, then Permit2 `approve` to the router. |
| `scripts/sell-token.mjs:179` | Concatenates `[V4_SWAP, UNWRAP_WETH]` and routes output WETH to the router before unwrap. |
| `script/SellToken.s.sol:50` | Solidity `SWAP_EXACT_IN_SINGLE` / `SETTLE_ALL` / `TAKE_ALL` encoding via the `Actions` library. |
| `script/SellToken.s.sol:64` | Uses `amountOutMinimum: 1` instead of `0` (one-wei floor). |
| `src/extensions/BonkerUniv4EthDevBuy.sol:186` | `_univ4Swap()` single-pool exact-in helper used by the V4 dev-buy extension. |
| `src/extensions/BonkerUniv4EthDevBuy.sol:229` | `execute{value: ...}` forwards native ETH only when `currency0` is the zero address. |
| `src/extensions/BonkerUniv3EthDevBuy.sol:180` | Same V4 action sequence, reached after an initial Uniswap v3 leg. |
| `src/mev-modules/sniper-utils/BonkerSniperUtilV2.sol:176` | `_univ4Swap()` that packages an auction-winning swap, with its own Permit2 approval. |

## How It Works

### The execute envelope

The router entrypoint is:

```text
execute(bytes commands, bytes[] inputs, uint256 deadline)
```

`commands` is a tightly packed list of one-byte command ids. `inputs[i]` is the ABI-encoded argument blob for `commands[i]`. The router walks the two arrays in lockstep and dispatches each command. `deadline` is a unix timestamp after which the whole call reverts.

Bonker only ever uses three commands:

| Command | Byte | Used by | Purpose |
| --- | --- | --- | --- |
| `WRAP_ETH` | `0x0b` | buy | Mint WETH from the ETH sent as `msg.value`. |
| `UNWRAP_WETH` | `0x0c` | sell | Burn WETH held by the router back to ETH for the recipient. |
| `V4_SWAP` | `0x10` | all | Run a Uniswap v4 swap described by a nested action sequence. |

In Solidity these are referenced symbolically as `Commands.V4_SWAP` (from `@uniswap/universal-router`); the JS scripts hardcode the numeric bytes (`CMD_V4_SWAP = 0x10`, `CMD_WRAP_ETH = 0x0b`, `CMD_UNWRAP_WETH = 0x0c`). The values must match the deployed router's `Commands` library — do not invent new ones.

### The V4_SWAP nested payload

The `inputs` entry for a `V4_SWAP` command is itself an ABI-encoded pair:

```text
abi.encode(bytes actions, bytes[] params)
```

`actions` is a packed list of one-byte V4Router action ids, and `params[i]` is the argument blob for `actions[i]`. Every Bonker swap uses exactly three actions: do the swap, settle the input currency owed to the PoolManager, then take the output currency out. Both encodings follow swap → settle → take.

### Encoding A — Solidity single-pool (SWAP_EXACT_IN_SINGLE)

`SellToken.s.sol`, both dev-buy extensions, and `BonkerSniperUtilV2` use the `Actions` library constants:

```text
actions = [SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL]
params[0] = IV4Router.ExactInputSingleParams{ poolKey, zeroForOne, amountIn (uint128), amountOutMinimum (uint128), hookData }
params[1] = abi.encode(currencyIn,  maxAmountIn)     // SETTLE_ALL
params[2] = abi.encode(currencyOut, minAmountOut)    // TAKE_ALL
```

`zeroForOne` is derived from token ordering: it is `true` when `currencyIn == poolKey.currency0`. `SellToken.s.sol` knows the token sorts below WETH and hardcodes `zeroForOne: true`; the reusable helpers compute it from `Currency.unwrap(poolKey.currency0) == tokenIn`. `SETTLE_ALL` declares the input the router must pay to the PoolManager; `TAKE_ALL` declares the output the router pulls and a minimum (`1` wei in every Bonker call).

### Encoding B — JS multi-hop path (SWAP_EXACT_IN)

`buy-token.mjs` and `sell-token.mjs` instead use the multi-hop exact-in action and the non-`ALL` settle/take:

```text
ACTION_SWAP_EXACT_IN = 0x07, ACTION_SETTLE = 0x0b, ACTION_TAKE = 0x0e
params[0] = { currencyIn, PathKey[] path, amountIn (uint128), amountOutMinimum (uint128) }
params[1] = abi.encode(currency, amount, payerIsUser)   // SETTLE
params[2] = abi.encode(currency, recipient, amount)     // TAKE
```

A `PathKey` is `{ intermediateCurrency, fee (uint24), tickSpacing (int24), hooks, hookData }`. The scripts pass a single-element path, so the multi-hop form still describes one pool hop, but the byte ids and `params` shapes differ from Encoding A. `SETTLE` carries a `payerIsUser` boolean and `TAKE` carries an explicit `recipient` — that recipient field is what makes the buy/sell ETH routing work (next section).

### Pool key constants

Every encoding reconstructs the same pool identity. These four values must stay aligned with the deployed pool or the swap targets a non-existent pool and reverts:

| Field | Value | Source |
| --- | --- | --- |
| `fee` | `0x800000` | Dynamic-fee flag, not a static bps fee. |
| `tickSpacing` | `200` | Bonker launch default. |
| `hooks` | `DYNAMIC_HOOK` (`0x963E91...e8cC`) | The pool's hook address. |
| currency pair | token + WETH | Sorted so `currency0 < currency1`. |

`hookData` is always empty (`0x` / `bytes("")`) — Bonker's hooks read no per-swap caller data on this path, except the sniper auction, whose bid data is supplied separately as `mevModuleSwapData` (see SNIPER-AUCTION-BID-MECHANICS).

### ETH wrap/unwrap framing and recipient sentinels

The router uses the sentinel address `0x0000000000000000000000000000000000000002` (`ROUTER_INTERNAL`, Uniswap's `ADDRESS_THIS`) to mean "keep funds inside the router for the next command".

**Buy** (`[WRAP_ETH, V4_SWAP]`): `WRAP_ETH` input is `(ROUTER_INTERNAL, value)`, and `execute` is called with `value: value`. The minted WETH stays in the router, the swap settles WETH with `payerIsUser = false` (the router pays from its own balance), and `TAKE` sends the bought token directly to the user's address.

**Sell** (`[V4_SWAP, UNWRAP_WETH]`): the swap settles the token with `payerIsUser = true` (pulled from the user via Permit2), `TAKE` sends the output WETH to `ROUTER_INTERNAL`, and the trailing `UNWRAP_WETH` input `(userAddress, 0)` burns that WETH to native ETH for the user.

The Solidity dev-buy and sniper helpers issue a single `V4_SWAP` command with no wrap/unwrap because they already hold WETH (or the paired token) and take the output to `address(this)`. `BonkerUniv4EthDevBuy._univ4Swap` does forward `value` to `execute` only when `currency0 == address(0)`, i.e. a native-ETH pool rather than a WETH pool.

### Permit2 approval triad

Whenever the input currency is an ERC20 the router must pull (selling a token, or a util spending a paired token), the caller first arranges a two-step Permit2 allowance:

```text
1. IERC20(tokenIn).approve(PERMIT2, max)                     // ERC20 → Permit2
2. IPermit2(PERMIT2).approve(tokenIn, UNIVERSAL_ROUTER,      // Permit2 → router
                             uint160(amount), uint48(expiration))
```

`sell-token.mjs` does both with `maxUint160`/`maxUint48` and skips them when the existing allowance already covers the balance. `BonkerSniperUtilV2._univ4Swap` re-approves per swap with `amountIn` and `uint48(block.timestamp)` expiry. The native-ETH buy path needs no Permit2 because its input is WETH minted inside the router, settled with `payerIsUser = false`.

### Slippage and deadline

`amountOutMinimum` and the `TAKE`/`TAKE_ALL` minimum are the only slippage guards. Operator scripts set `amountOutMinimum: 0` (no protection — acceptable for disposable test tokens); `SellToken.s.sol` uses `1`, and the Solidity helpers take a caller-supplied minimum with `TAKE_ALL` floored at `1`. The deadline is `now + 300` in the scripts and `SellToken.s.sol`, but `block.timestamp` (same-block, no slack) in the dev-buy and sniper helpers, which must execute atomically within their own transaction.

## Invariants And Edge Cases

### commands and inputs must be the same length

`inputs.length` must equal the number of command bytes. The buy path packs two commands and passes a two-element `inputs` array (`[wrapInput, v4Input]`); the sell path passes `[v4Input, unwrapInput]`. Adding or removing a command without updating `inputs` shifts every subsequent decode and reverts inside the router.

### actions and params must be the same length

Inside `V4_SWAP`, `params.length` must equal the action byte count. All Bonker swaps use exactly three actions and a three-element `params`. The three actions are ordered swap → settle → take; reordering them breaks the PoolManager's flash-accounting (you cannot take output before the swap creates the delta).

### Encoding A and Encoding B are not interchangeable

`SWAP_EXACT_IN_SINGLE` (Solidity) and `SWAP_EXACT_IN` (JS scripts) are different action bytes with different `params[0]` shapes (`ExactInputSingleParams` vs `{ currencyIn, PathKey[], ... }`), and `SETTLE_ALL`/`TAKE_ALL` differ from `SETTLE`/`TAKE` in both byte id and argument layout. If you port logic from a script into a contract (or vice versa) you must switch the whole action triple, not just one action.

### Pool constants are duplicated, not shared

`fee = 0x800000`, `tickSpacing = 200`, and the hook address are hardcoded independently in `buy-token.mjs`, `sell-token.mjs`, `SellToken.s.sol`, and the on-chain helpers. There is no single constant they import. A redeploy that changes the hook address or a launch that uses a different tick spacing requires editing every call site; see CONTRACT-CONFIG-TOPOLOGY for the address-drift surface.

### Currency ordering controls direction

`zeroForOne` and the settle/take currency assignments depend on whether the Bonker token sorts above or below WETH. The Solidity helpers derive ordering from `poolKey.currency0`; `SellToken.s.sol` assumes `token < WETH`. A token whose address sorts above WETH would invert `zeroForOne`, so any new hardcoded direction must be checked against the actual address ordering. See NATIVE-ETH-WETH-CURRENCY-MODEL for how native ETH and WETH are treated across the pool boundary.

### Output recipient determines who is paid

In the JS sell path the output is taken to `ROUTER_INTERNAL` precisely so `UNWRAP_WETH` can convert it to ETH for the user. If a future change takes the output directly to the user's address, the trailing `UNWRAP_WETH` would have nothing to unwrap and the user would receive WETH instead of ETH.

## Cross-references

- [FORGE-SELL-TOKEN-SCRIPT](./FORGE-SELL-TOKEN-SCRIPT.md) — the Forge sell script that uses Encoding A.
- [STANDALONE-MAINNET-SCRIPT-WORKFLOW](./STANDALONE-MAINNET-SCRIPT-WORKFLOW.md) — the operator scripts (`buy-token.mjs`, `sell-token.mjs`) that use Encoding B.
- [DEV-BUY-EXTENSION-ROUTING](./DEV-BUY-EXTENSION-ROUTING.md) — the V3/V4 dev-buy extensions that call `_univ4Swap` during launch.
- [SNIPER-AUCTION-BID-MECHANICS](./SNIPER-AUCTION-BID-MECHANICS.md) — `BonkerSniperUtilV2`'s auction-winning swap and bid data.
- [NATIVE-ETH-WETH-CURRENCY-MODEL](./NATIVE-ETH-WETH-CURRENCY-MODEL.md) — why ETH is wrapped/unwrapped around the swap and how currency ordering works.
- [POOL-INITIALIZATION-AND-LIQUIDITY-SEEDING](./POOL-INITIALIZATION-AND-LIQUIDITY-SEEDING.md) — where the pool `fee`, `tickSpacing`, and hook these swaps target come from.
- [CONTRACT-CONFIG-TOPOLOGY](./CONTRACT-CONFIG-TOPOLOGY.md) — the deployed router/Permit2/hook addresses and their drift surfaces.
