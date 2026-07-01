Forge sell-token script workflow explains how `script/SellToken.s.sol` sells the operator wallet's full Bonker token balance for WETH through Uniswap Universal Router; read this before changing the Forge sell script, its hardcoded Base addresses, Permit2 approvals, V4 swap calldata, pool key assumptions, or broadcast command.

This page covers natural-language queries such as `SellToken.s.sol`, `TOKEN=0x... forge script`, `BONKER_PRIVATE_KEY`, `Commands.V4_SWAP`, `Actions.SWAP_EXACT_IN_SINGLE`, `Permit2 approve`, `amountOutMinimum: 1`, `zeroForOne: true`, "why did the Forge sell script receive WETH not ETH", and "why does the Forge script differ from scripts/sell-token.mjs". It focuses on the Forge operator script under `script/`, not the browser launch form and not the Node trading scripts under `scripts/`.

## Why It Exists

Bonker has two local sell paths for operator wallets.

The Node path is `scripts/sell-token.mjs`. It uses viem, checks existing allowances, builds a Universal Router `V4_SWAP`, unwraps WETH into ETH, and is covered by [STANDALONE-MAINNET-SCRIPT-WORKFLOW](./STANDALONE-MAINNET-SCRIPT-WORKFLOW.md).

The Forge path is `script/SellToken.s.sol`. It is shorter and more direct: load `TOKEN` and `BONKER_PRIVATE_KEY` from the Forge environment, read the private-key wallet's full ERC20 balance, approve Permit2, approve Universal Router through Permit2, execute a single V4 exact-input swap, and print the resulting WETH balance.

That split is useful because Forge already has the Uniswap Solidity types in scope and can be convenient while working near deployment scripts. The cost is that it looks like a deployment script but is actually a Base-mainnet trading script. Running it with `--broadcast` spends real gas, changes allowances, and sells the entire token balance held by the key.

The script also carries narrower assumptions than the Node sell helper. It always targets the deployed dynamic WETH pool, assumes the token is `currency0`, does not unwrap WETH to ETH, and uses a minimal output floor. Those choices are fine for unwinding local test-token inventory, but they should not be mistaken for a generic or price-safe trading tool.

## Key Files

| File | Why it matters |
| --- | --- |
| `script/SellToken.s.sol:15` | Declares the Forge `SellToken` script contract. |
| `script/SellToken.s.sol:16` | Hardcodes canonical Base WETH. |
| `script/SellToken.s.sol:17` | Hardcodes the deployed Bonker dynamic hook used by the pool key. |
| `script/SellToken.s.sol:18` | Hardcodes Base Universal Router. |
| `script/SellToken.s.sol:19` | Hardcodes Permit2. |
| `script/SellToken.s.sol:22` | Reads `TOKEN` from the Forge environment. |
| `script/SellToken.s.sol:23` | Reads `BONKER_PRIVATE_KEY` and derives the broadcaster wallet. |
| `script/SellToken.s.sol:26` | Reads the wallet's full token balance before broadcasting. |
| `script/SellToken.s.sol:29` | Stops if there is no token balance to sell. |
| `script/SellToken.s.sol:33` | Builds a `PoolKey` with token as `currency0`, WETH as `currency1`, dynamic fee, tick spacing 200, and the dynamic hook. |
| `script/SellToken.s.sol:41` | Starts the broadcast boundary. Everything after this can change Base mainnet when `--broadcast` is supplied. |
| `script/SellToken.s.sol:44` | Unconditionally approves Permit2 for the token with `uint256.max`. |
| `script/SellToken.s.sol:47` | Approves Universal Router through Permit2 for the current balance with one-hour expiration. |
| `script/SellToken.s.sol:50` | Encodes a single `Commands.V4_SWAP` router command. |
| `script/SellToken.s.sol:52` | Encodes the V4 action triplet: swap, settle, take. |
| `script/SellToken.s.sol:60` | Builds `IV4Router.ExactInputSingleParams`. |
| `script/SellToken.s.sol:62` | Sets `zeroForOne: true`, matching the token-to-WETH direction only when token is `currency0`. |
| `script/SellToken.s.sol:64` | Sets `amountOutMinimum: 1`, which is effectively no slippage protection. |
| `script/SellToken.s.sol:68` | Settles the token balance into the V4 swap path. |
| `script/SellToken.s.sol:69` | Takes WETH output with a minimum of 1 wei. |
| `script/SellToken.s.sol:74` | Executes the Universal Router command with a five-minute deadline. |
| `script/SellToken.s.sol:78` | Reads WETH balance after the swap for console output. |
| `scripts/sell-token.mjs:21` | Node sell helper's comparable hardcoded address block. |
| `scripts/sell-token.mjs:179` | Node helper appends `CMD_UNWRAP_WETH`, unlike the Forge script. |
| `CLAUDE.md:198` | Maintainer command snippet for running the Forge sell script. |

## How It Works

### Invocation Shape

The intended command shape is:

```bash
source .env.local
TOKEN=0x... forge script script/SellToken.s.sol --rpc-url https://mainnet.base.org --broadcast --via-ir --code-size-limit 49152
```

`TOKEN` is the ERC20 to sell. `BONKER_PRIVATE_KEY` is the account that owns the token balance and signs all transactions. The script derives `deployer = vm.addr(deployerKey)` and sells that address's entire `IERC20(token).balanceOf(deployer)`.

Running without `--broadcast` is the dry-run path. Running with `--broadcast` sends the approval and router transactions to Base mainnet.

### Address And Pool Assumptions

The script does not discover pool configuration from the factory, token deployment info, or the indexer. It constructs the pool key directly:

```text
currency0  = TOKEN
currency1  = WETH
fee        = 0x800000
tickSpacing = 200
hooks      = DYNAMIC_HOOK
```

That is the normal Bonker dynamic WETH launch shape, but it is not universal. The script does not support static-hook launches, non-WETH pairs, custom tick spacing, open pools with a different hook, or swap paths that need hook data.

The script sets `TOKEN` as `currency0`, WETH as `currency1`, and `zeroForOne = true`. That only matches the real Uniswap v4 pool if the target token address sorts below WETH and the pool was created with token as `currency0`. If a token address sorts after WETH, this `PoolKey` is not the deployed pool key and the swap path is wrong.

### Broadcasted Steps

The pre-broadcast work is read-only:

```text
read TOKEN env
read BONKER_PRIVATE_KEY env
derive wallet address
read token balance
require balance > 0
build PoolKey
```

After `vm.startBroadcast(deployerKey)`, the script performs three main writes:

```text
1. IERC20(TOKEN).approve(PERMIT2, uint256.max)
2. IPermit2(PERMIT2).approve(TOKEN, UNIVERSAL_ROUTER, uint160(balance), now + 1 hour)
3. IUniversalRouter(UNIVERSAL_ROUTER).execute(V4_SWAP, inputs, now + 5 minutes)
```

The ERC20 approval is unconditional and unlimited. The Permit2 approval is unconditional for the current balance and expires after one hour. The script does not check existing allowance state before sending either approval.

### Router Calldata

The command stream contains exactly one command:

```text
Commands.V4_SWAP
```

The V4 action stream contains:

```text
Actions.SWAP_EXACT_IN_SINGLE
Actions.SETTLE_ALL
Actions.TAKE_ALL
```

`SWAP_EXACT_IN_SINGLE` sells `uint128(balance)` of `TOKEN` into WETH with `hookData = ""`. `SETTLE_ALL` settles the input token balance. `TAKE_ALL` takes WETH output with a 1 wei minimum.

The router deadline is `block.timestamp + 300`. The script does not quote expected output, compare reserves, or calculate a slippage bound.

### Output Asset

The Forge script ends by reading:

```solidity
IERC20(WETH).balanceOf(deployer)
```

That is the whole WETH balance after the trade, not the delta from before the trade. If the wallet already held WETH, the printed value includes the old balance.

This is different from `scripts/sell-token.mjs`, which appends Universal Router `CMD_UNWRAP_WETH` and estimates ETH received by comparing wallet ETH balances before and after the swap. The Forge script keeps output as WETH.

## Invariants And Edge Cases

### Mainnet Writes Stay Opt-In

This script is safe to inspect and dry-run, but `--broadcast` changes Base mainnet state. It can approve allowances and sell tokens from the private-key wallet. Keep the repo rule intact: do not run broadcast commands without explicit approval.

### It Sells The Full Balance

There is no amount parameter. The script sells whatever `IERC20(token).balanceOf(deployer)` returns at runtime. To sell a partial balance, the script would need a new environment input and the approval, `amountIn`, and settle amount would all need to use that value consistently.

### It Assumes Token-To-WETH Dynamic Pools

The hardcoded pool key is suitable only for the normal dynamic WETH Bonker pool shape where token is `currency0`.

If a launch used the static hook, a non-WETH paired token, a different tick spacing, a different hook address after redeploy, or a token address that should be `currency1`, this script can route against the wrong pool key.

### Slippage Protection Is Minimal

`amountOutMinimum: 1` and `TAKE_ALL(WETH, 1)` only prevent a literal zero-output path. They do not protect the operator from price movement, MEV, taxes, or poor execution.

This mirrors the script's purpose: quick cleanup for test-token balances, not production-grade trading infrastructure.

### Allowance State Persists

`IERC20(token).approve(PERMIT2, type(uint256).max)` leaves Permit2 with unlimited ERC20 allowance after the transaction unless the token or a later operation changes it.

The Permit2 allowance to Universal Router is narrower: it is for the current balance and expires after one hour. Still, changing `PERMIT2`, `UNIVERSAL_ROUTER`, or token selection should include a deliberate allowance review.

### The Balance Cast Must Fit

The swap passes `amountIn: uint128(balance)`. Normal Bonker token balances are expected to fit, but the cast is still part of the script contract. If this script is reused for a token with a balance above `type(uint128).max`, the amount used in swap calldata would not represent the full `uint256` balance the script read.

### Console Output Is Not Net Proceeds

`WETH received:` prints the WETH balance after execution. It is not `wethAfter - wethBefore`, and it does not account for gas paid in ETH.

Use transaction logs, wallet balance deltas, or router output inspection when exact proceeds matter.

## Cross-References

- [STANDALONE-MAINNET-SCRIPT-WORKFLOW](./STANDALONE-MAINNET-SCRIPT-WORKFLOW.md) explains the Node launch, buy, and sell scripts, including the sell helper that unwraps WETH to ETH.
- [CONTRACT-DEPLOYMENT-WORKFLOW](./CONTRACT-DEPLOYMENT-WORKFLOW.md) explains the Forge deployment scripts and why `--broadcast` must be treated as a mainnet write boundary.
- [CONTRACT-CONFIG-TOPOLOGY](./CONTRACT-CONFIG-TOPOLOGY.md) maps hardcoded deployed addresses and redeploy drift surfaces across client, server, scripts, and human-facing docs.
- [DEV-BUY-EXTENSION-ROUTING](./DEV-BUY-EXTENSION-ROUTING.md) documents another Universal Router V4 exact-input path that uses Permit2 and a near-zero output floor during launch-time creator buys.
- [HOOK-FEE-ACCOUNTING](./HOOK-FEE-ACCOUNTING.md) explains why normal Bonker pools use the dynamic hook and how hook-level protocol fees interact with swaps.
