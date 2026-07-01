# V4 Flash-Accounting & Settlement Model

This page explains the Uniswap v4 flash-accounting primitive that every on-chain Bonker contract uses to move value in and out of the `PoolManager`: the unlocked-context requirement, the `BalanceDelta` / `BeforeSwapDelta` sign convention, the `sync` → `transfer` → `settle` pay-in sequence, the `take` pay-out call, and the ERC-6909 claim-token accumulation done with `poolManager.mint` / `burn` / `balanceOf`. Read this before changing any code that calls `poolManager.take`, `poolManager.settle`, `poolManager.sync`, `poolManager.mint`, `poolManager.burn`, `poolManager.swap`, `toBeforeSwapDelta`, `toBalanceDelta`, or `modifyLiquiditiesWithoutUnlock` — that is, `src/hooks/BonkerHookV2.sol`, `src/lp-lockers/BonkerLpLockerFeeConversion.sol`, and any new contract that settles deltas against the pool. It is the shared substrate under the hook fee math, the LP locker fee conversion, and the dev-buy/sell swap paths.

## Why this concept exists

Uniswap v3 transferred tokens on every pool interaction. Uniswap v4 replaced that with a single `PoolManager` singleton and a **flash-accounting** model: operations record signed balance *deltas* per currency while the pool is "unlocked", and the caller must net every delta back to zero before the unlock returns, or the whole transaction reverts. No tokens move per-operation; settlement happens once at the end.

This is efficient but unforgiving. Bonker's contracts repeatedly need to take a protocol fee, convert LP fees through a swap, or pull collected fees into the factory — each of which is a delta that must be settled correctly. Getting the sign wrong, settling the wrong currency, or operating outside an unlocked context reverts the swap that triggered it. Because the same primitive shows up in the hook, the LP locker, the dev-buy extensions, and the sell script — each with slightly different framing — this doc pins down the primitive once so the per-subsystem docs can assume it.

## Key files

| Anchor | Role |
|--------|------|
| `src/hooks/BonkerHookV2.sol:421` | `_hookFeeClaim()` reads accumulated claim balance via `poolManager.balanceOf(address(this), feeCurrency.toId())`. |
| `src/hooks/BonkerHookV2.sol:428` | `poolManager.burn(...)` destroys the claim token before withdrawing real tokens. |
| `src/hooks/BonkerHookV2.sol:431` | `poolManager.take(feeCurrency, factory, fee)` pays the protocol fee out to the factory. |
| `src/hooks/BonkerHookV2.sol:471` | `poolManager.mint(address(this), ...)` accrues the before-swap protocol fee as an ERC-6909 claim token. |
| `src/hooks/BonkerHookV2.sol:470` | `toBeforeSwapDelta(fee, 0)` returns the specified-currency delta from `beforeSwap`. |
| `src/hooks/BonkerHookV2.sol:529` | `sub(delta, toBalanceDelta(...))` adjusts the after-swap delta to charge the unspecified-currency fee. |
| `src/lp-lockers/BonkerLpLockerFeeConversion.sol:613` | `poolManager.swap(...)` swaps directly against the unlocked pool inside the locker. |
| `src/lp-lockers/BonkerLpLockerFeeConversion.sol:619` | `poolManager.sync` → `transfer` → `poolManager.settle` pays the swap input. |
| `src/lp-lockers/BonkerLpLockerFeeConversion.sol:624` | `poolManager.take` withdraws the swap output to the locker. |
| `src/lp-lockers/BonkerLpLockerFeeConversion.sol:582` | `modifyLiquiditiesWithoutUnlock` collects position fees when the pool is already unlocked. |

## The unlocked-context requirement

Every `take`, `settle`, `sync`, `mint`, `burn`, and direct `swap` call must happen while the `PoolManager` is unlocked. There are two ways Bonker code finds itself in an unlocked context:

- **Inside a hook callback.** When a user swaps, the `PoolManager` is already unlocked and calls into `BonkerHookV2._beforeSwap()` / `_afterSwap()`. Everything those callbacks do — claiming the prior protocol fee, claiming LP locker rewards, minting the new protocol fee — runs in that borrowed unlocked context. This is why `_lpLockerFeeClaim()` calls `collectRewardsWithoutUnlock()` and the locker then uses `modifyLiquiditiesWithoutUnlock()`: re-unlocking an already-unlocked manager would revert.
- **By unlocking yourself.** Outside a swap, a caller (the Universal Router, or the locker's public `collectRewards()` path) opens its own unlock, does its work, and settles before returning.

The `withoutUnlock` variants throughout `BonkerLpLockerFeeConversion` exist purely to pick the right branch. See [LP-LOCKER-FEE-CONVERSION-LIFECYCLE](./LP-LOCKER-FEE-CONVERSION-LIFECYCLE.md) for the two collection entry points and the `_inCollect` recursion guard that keeps a collection-triggered swap from starting a nested collection.

## Delta sign convention

A `BalanceDelta` packs two `int128` values, one per pool currency (`amount0`, `amount1`). The sign is always written from the **counterparty's** perspective relative to the pool:

- **Negative** delta = the account *owes the pool* (must pay in).
- **Positive** delta = the pool *owes the account* (may take out).

The hook comments state this directly: at `BonkerHookV2.sol:528` "positive for the swapper means amount owed to the swapper", and at `:552` "negative for the swapper means amount owed to the pool". This is why the after-swap fee logic *subtracts* `unspecifiedDelta` from the swapper's delta in both the exact-input-out and exact-output-in cases — subtracting reduces what the swapper receives or increases what they pay, redirecting that slice to the hook.

`BeforeSwapDelta` is the analogous two-field type returned from `beforeSwap`, but its fields are *specified* vs *unspecified* amount (not currency0/currency1), because before the swap runs the manager does not yet know the final per-currency split. `toBeforeSwapDelta(fee, 0)` charges the fee against the specified currency only.

## Pay-in: sync → transfer → settle

To pay a currency *into* the pool (settle a negative delta), the canonical sequence in `_uniSwapUnlocked` is:

```text
poolManager.sync(currencyIn)              // snapshot manager's current balance of currencyIn
currencyIn.transfer(poolManager, amount)  // send the real tokens
poolManager.settle()                      // manager diffs new balance vs snapshot, credits the delta
```

`sync` must come *before* the transfer: it records the baseline so `settle` can compute exactly how much arrived. Skipping `sync`, transferring first, or settling the wrong currency leaves the delta unbalanced and the unlock reverts. Native ETH has a slightly different settle path; see [NATIVE-ETH-WETH-CURRENCY-MODEL](./NATIVE-ETH-WETH-CURRENCY-MODEL.md) for how Bonker pools standardize on WETH so this ERC-20 sequence applies uniformly.

## Pay-out: take

To withdraw a currency the pool owes you (settle a positive delta), call `poolManager.take(currency, recipient, amount)`. It transfers real tokens out and clears that much of the delta in one step. The hook uses it to push the protocol fee straight to the factory (`take(feeCurrency, factory, fee)`); the locker uses it to pull swap output into itself (`take(currencyOut, address(this), deltaOut)`).

## ERC-6909 claim tokens: mint / burn / balanceOf

The hook does not always take real tokens immediately. During a swap it accrues the protocol fee as an **ERC-6909 claim token** — an internal IOU the `PoolManager` mints to a holder:

- `poolManager.mint(address(this), currency.toId(), amount)` settles the hook's positive delta *as a claim balance* instead of withdrawing tokens. This is cheap and stays inside the unlocked context.
- On the *next* swap, `_hookFeeClaim()` reads the accrued balance with `poolManager.balanceOf(address(this), feeCurrency.toId())`, calls `poolManager.burn(...)` to destroy the claim, then `poolManager.take(...)` to materialize real tokens to the factory.

That mint-now / burn-and-take-later split is why protocol fees are always claimed one swap behind. The accounting reasoning — which currency the fee lands in and whether it is minted in `beforeSwap` or `afterSwap` — lives in [HOOK-FEE-ACCOUNTING](./HOOK-FEE-ACCOUNTING.md). This doc only establishes that `mint`/`burn`/`balanceOf` operate on claim tokens, not on the underlying ERC-20.

## Invariants and edge cases

- **Net-zero or revert.** Every delta opened during an unlock must be settled (`take`/`settle`/`mint`/`burn`) before the unlock returns. A leftover delta reverts the entire transaction, including the user's swap.
- **Never re-unlock an unlocked manager.** Inside a hook callback the manager is already unlocked. Always route through the `withoutUnlock` variants there; only the public, outside-swap paths may open a fresh unlock.
- **`sync` precedes `transfer`.** The pay-in sequence is order-sensitive; `settle` measures the delta against the `sync` snapshot.
- **Sign discipline.** Negative = owe the pool, positive = pool owes you. Flipping a sign in the after-swap math silently misroutes the fee or unbalances the delta.
- **Claim tokens ≠ tokens.** `mint`/`burn`/`balanceOf` move ERC-6909 claim balances inside the manager; only `take` (or `settle` for pay-in) crosses the boundary to real ERC-20 transfers.
- **Specified vs unspecified.** `BeforeSwapDelta` is specified/unspecified-keyed; `BalanceDelta` is currency0/currency1-keyed. Converting between them wrong is a common source of fee-routing bugs.

## Cross-references

- [HOOK-FEE-ACCOUNTING](./HOOK-FEE-ACCOUNTING.md) — which fee to take, in which currency, in `beforeSwap` vs `afterSwap`, built on the primitive here.
- [LP-LOCKER-FEE-CONVERSION-LIFECYCLE](./LP-LOCKER-FEE-CONVERSION-LIFECYCLE.md) — the `collectRewards` / `collectRewardsWithoutUnlock` paths and the `_uniSwapUnlocked` vs `_uniSwapLocked` swap choice.
- [NATIVE-ETH-WETH-CURRENCY-MODEL](./NATIVE-ETH-WETH-CURRENCY-MODEL.md) — how Bonker standardizes pool currencies so the settle/take sequence is uniform.
- [UNIVERSAL-ROUTER-V4-SWAP-ENCODING](./UNIVERSAL-ROUTER-V4-SWAP-ENCODING.md) — the off-chain `execute(commands, inputs)` grammar for the locked/router swap path that wraps this primitive.
- [HOOK-FEE-ACCOUNTING](./HOOK-FEE-ACCOUNTING.md) and [POOL-EXTENSION-HOOK-LIFECYCLE](./POOL-EXTENSION-HOOK-LIFECYCLE.md) — the callback ordering inside which the unlocked-context operations run.
