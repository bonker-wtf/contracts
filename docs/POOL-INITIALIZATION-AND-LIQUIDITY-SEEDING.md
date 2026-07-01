Pool initialization and liquidity seeding explains how Bonker turns one `tickIfToken0IsBonker` value into both the pool's starting price and a set of single-sided Uniswap v4 LP positions, and why token ordering forces tick sign-flipping and mirroring. Read this before changing `Bonker._initializePool`, `Bonker._initializeLiquidity`, `BonkerHookV2._initializePool`, `BonkerLpLockerFeeConversion._mintLiquidity`, the `PoolConfig`/`LockerConfig` tick fields, or launch-form tick defaults.

This page answers natural-language queries such as "why is `tickIfToken0IsBonker` negative", "what is `token0IsBonker`", "why are launch positions single-sided", "why does the locker negate `tickLower`/`tickUpper`", "what does `TickRangeLowerThanStartingTick` mean", "why must ticks be a multiple of `tickSpacing`", "how does `positionBps` split the pool supply", and "where does the `startingTick` in `TokenCreated` come from". It is about price orientation and position placement, not fee collection — for accrued LP fees and claims see [LP-LOCKER-FEE-CONVERSION-LIFECYCLE](./LP-LOCKER-FEE-CONVERSION-LIFECYCLE.md).

## Why it exists

A Bonker launch must create a tradeable Uniswap v4 pool and seed it with liquidity in a single `deployToken` call, before the token has any market price. Two problems fall out of that:

1. **Uniswap orders pool currencies by address, not by intent.** A pool's `currency0` is whichever of the two token addresses is numerically smaller. The Bonker token address is mined at deploy time, so sometimes the Bonker token is `currency0` and sometimes it is `currency1`. Every tick and every price is expressed in the `currency0`-per-`currency1` frame, so the same economic price maps to a positive tick in one ordering and a negative tick in the other.

2. **The launch has only the Bonker token to deposit, not the paired token.** All initial liquidity is one-sided: the pool is seeded entirely with the freshly minted Bonker supply and zero paired token. For a one-sided deposit to be valid in Uniswap v4, every position's price range must sit entirely on one side of the current price.

Bonker solves both with a single canonical input — `tickIfToken0IsBonker` — defined in the "Bonker is `currency0`" frame. The hook and the locker each translate that canonical value into the real on-chain frame for the specific token ordering. Callers (launch form, scripts) reason in one frame; the contracts handle the flip.

## Key files

| Path:line | Role |
| --- | --- |
| `src/interfaces/IBonker.sol:19` | `PoolConfig` — `tickIfToken0IsBonker`, `tickSpacing`, `pairedToken`, `hook`, `poolData`. |
| `src/interfaces/IBonker.sol:27` | `LockerConfig` — parallel `tickLower[]`, `tickUpper[]`, `positionBps[]` arrays in the canonical frame. |
| `src/Bonker.sol:184` | `deployToken` calls `_initializePool` then `_initializeLiquidity`. |
| `src/Bonker.sol:253` | `_initializePool` forwards `tickIfToken0IsBonker`/`tickSpacing` to the hook. |
| `src/Bonker.sol:276` | `_initializeLiquidity` approves and calls `IBonkerLpLocker.placeLiquidity`. |
| `src/Bonker.sol:231` | `TokenCreated.startingTick` is emitted as the raw `tickIfToken0IsBonker` (canonical, not flipped). |
| `src/hooks/BonkerHookV2.sol:200` | `_initializePool` decides `token0IsBonker`, builds the `PoolKey`, flips the starting tick, and calls `poolManager.initialize`. |
| `src/lp-lockers/BonkerLpLockerFeeConversion.sol:198` | `_mintLiquidity` validates ticks, flips/mirrors them, computes liquidity, and mints positions. |
| `src/lp-lockers/BonkerLpLockerFeeConversion.sol:45` | `MAX_LP_POSITIONS = 7`; `BASIS_POINTS = 10_000` (line 43). |
| `src/Bonker.sol:40` | `TOKEN_SUPPLY = 100_000_000_000e18`; pool supply is this minus extension reservations. |

## How it works

### Step 1 — currency ordering and the price frame

The hook computes `token0IsBonker = bonker < pairedToken` (a raw address comparison) at `BonkerHookV2.sol:213`. The `PoolKey` sets `currency0`/`currency1` accordingly (`:217`), records `bonkerIsToken0[poolId]` for later swap accounting (`:225`), and uses a dynamic fee flag with the supplied `tickSpacing`.

The canonical input `tickIfToken0IsBonker` is the starting tick that would apply *if* the Bonker token were `currency0`. When it actually is, that tick is used as-is. When it is not, the real starting tick is its negation:

```text
startingTick = token0IsBonker ? tickIfToken0IsBonker : -tickIfToken0IsBonker
initialPrice = TickMath.getSqrtPriceAtTick(startingTick)
poolManager.initialize(poolKey, initialPrice)
```

The negation is exact because swapping `currency0` and `currency1` inverts the price, and inverting a price negates its tick. So the same `tickIfToken0IsBonker` produces the same economic starting price in both orderings.

### Step 2 — supply available to seed

Back in the factory, `poolSupply = TOKEN_SUPPLY - extensionsSupply` (`Bonker.sol:182`). Extensions (vault, airdrop, presale, dev-buy) reserve their cut first; whatever remains is the LP seed. The factory approves the locker for exactly `poolSupply` (`Bonker.sol:289`) and calls `placeLiquidity`.

### Step 3 — position validation (canonical frame)

`_mintLiquidity` reads `tickLower[]`, `tickUpper[]`, `positionBps[]` — all in the canonical "Bonker is `currency0`" frame, same as `tickIfToken0IsBonker`. The loop at `BonkerLpLockerFeeConversion.sol:225` enforces, per position:

- arrays are equal length (`MismatchedPositionInfos`) and non-empty (`NoPositions`), count ≤ `MAX_LP_POSITIONS = 7` (`TooManyPositions`);
- `tickLower[i] <= tickUpper[i]` (`TicksBackwards`);
- ticks within `TickMath.MIN_TICK`/`MAX_TICK` (`TicksOutOfTickBounds`);
- both ticks are multiples of `tickSpacing` (`TicksNotMultipleOfTickSpacing`);
- **`tickLower[i] >= tickIfToken0IsBonker`** (`TickRangeLowerThanStartingTick`).

That last rule is what guarantees single-sided seeding: every position sits at or above the starting tick, i.e. entirely on the Bonker side of the current price, so it can be funded with Bonker tokens alone. `positionBps[]` must sum to `BASIS_POINTS = 10_000` (`InvalidPositionBps`); each position gets `poolSupply * positionBps[i] / BASIS_POINTS` Bonker tokens.

### Step 4 — flip and mirror into the real frame

For each position the locker recomputes `token0IsBonker = token < pairedToken` and a local `startingTick` flipped the same way as the hook (`:251`, `:257`). When Bonker is `currency0`, the canonical ticks are used directly and the deposit is `amount0` (Bonker). When Bonker is `currency1`, the ticks are negated **and the lower/upper pair is swapped** so the range stays well-ordered after negation, and the deposit becomes `amount1`:

```text
amount0 = token0IsBonker ? tokenAmount : 0
amount1 = token0IsBonker ? 0          : tokenAmount

// negate, then swap lower<->upper when bonker is currency1
tickLower = token0IsBonker ?  L : -U
tickUpper = token0IsBonker ?  U : -L
```

(See `BonkerLpLockerFeeConversion.sol:266`–`:275`.) Negation alone would invert the ordering of a range; swapping lower and upper restores `tickLower < tickUpper` in the real frame.

### Step 5 — liquidity math and minting

Liquidity per position comes from `LiquidityAmounts.getLiquidityForAmounts(startingSqrtPrice, lowerSqrtPrice, upperSqrtPrice, amount0, amount1)` at `:280`, using the flipped `startingTick`'s sqrt price as the current price. Because one of `amount0`/`amount1` is zero and the range is fully on the funded side, the math resolves to a one-sided liquidity amount.

The locker batches one `MINT_POSITION` action per position plus a trailing `SETTLE_PAIR` (`:262`, `:297`), grabs `positionManager.nextTokenId()` as the position id, approves the position manager through Permit2 with a same-block expiry (`:302`–`:305`), and calls `positionManager.modifyLiquidities` (`:311`). The position NFTs are minted to the locker itself, which is what makes launch liquidity permanently locked.

### Step 6 — what downstream sees

The factory emits `TokenCreated.startingTick = tickIfToken0IsBonker` — the raw canonical value, **not** the flipped on-chain tick. The locker emits `TokenRewardAdded` (`src/interfaces/IBonkerLPLocker.sol:18`) carrying the per-position tick ranges, which token-detail enrichment reconstructs into the liquidity distribution chart. See [TOKEN-DETAIL-ENRICHMENT](./TOKEN-DETAIL-ENRICHMENT.md) and [TOKEN-INDEXER-LIFECYCLE](./TOKEN-INDEXER-LIFECYCLE.md).

## Worked example (launch defaults)

`scripts/deploy-token.mjs` and `client/components/LaunchPage.jsx` ship the same defaults: `tickIfToken0IsBonker: -230400`, `tickSpacing: 200`, and five positions whose `positionBps` sum to 10000:

```text
tickLower: [-230400, -214000, -202000, -155000, -141000]
tickUpper: [-214000, -155000, -155000, -120000, -120000]
positionBps:[  1000,    5000,    1500,    2000,     500]
```

Every `tickLower` is ≥ -230400 (passes `TickRangeLowerThanStartingTick`) and every tick is a multiple of 200 (passes `TicksNotMultipleOfTickSpacing`). The negative starting tick reflects the typical case where the Bonker token, priced cheaply against the paired token, sits low in the `currency0`-per-`currency1` frame. If the deployed Bonker address turns out to be `currency1`, the hook and locker mirror all of these to positive ticks automatically — the caller never changes its inputs.

## Invariants and edge cases

- **Canonical frame is the contract boundary.** All caller-supplied ticks (`tickIfToken0IsBonker`, `tickLower[]`, `tickUpper[]`) are in the "Bonker is `currency0`" frame. Never pre-flip them for token ordering; the hook and locker own that flip. Pre-flipping double-negates and breaks both price and ranges.
- **Single-sided requires `tickLower[i] >= tickIfToken0IsBonker`.** A range that dips below the starting tick would need paired token to fund and reverts with `TickRangeLowerThanStartingTick`. The factory deposits only Bonker tokens.
- **Tick-spacing alignment is mandatory.** Both bounds of every position must be exact multiples of `tickSpacing` or `_mintLiquidity` reverts. Keep `tickSpacing` consistent with the hook config (Base launches use `200`).
- **`positionBps` and `rewardBps` are different sums.** `positionBps[]` (how supply splits across LP ranges) sums to `BASIS_POINTS`; the reward split `rewardBps[]` validated in `placeLiquidity` also sums to `BASIS_POINTS` but governs fee recipients, not liquidity. Don't conflate them.
- **At most 7 positions.** `MAX_LP_POSITIONS` caps the array length; exceeding it reverts with `TooManyPositions`.
- **`TokenCreated.startingTick` is canonical.** Consumers comparing it to on-chain pool ticks must apply the same `token0IsBonker` flip; the event value is not the live pool tick when Bonker is `currency1`.
- **Permit2 approval is same-block.** The locker approves the position manager with a `block.timestamp` expiry, so the approval is consumed within the deploy transaction and leaves no standing allowance. See [NON-STANDARD-ERC20-TRANSFER-SAFETY](./NON-STANDARD-ERC20-TRANSFER-SAFETY.md).

## Cross-references

- [LP-LOCKER-FEE-CONVERSION-LIFECYCLE](./LP-LOCKER-FEE-CONVERSION-LIFECYCLE.md) — what happens to the locked positions afterward: fee collection, conversion, and claims.
- [LP-LOCKER-VARIANTS](./LP-LOCKER-VARIANTS.md) — the deployed fee-conversion locker vs the dormant multi-recipient locker.
- [HOOK-FEE-ACCOUNTING](./HOOK-FEE-ACCOUNTING.md) — how `bonkerIsToken0` set during initialization drives swap-time fee deltas.
- [HOOK-VERSION-COMPARISON](./HOOK-VERSION-COMPARISON.md) — `BonkerHook` vs `BonkerHookV2` constructor and pool-data differences.
- [DEPLOYTOKEN-CALLDATA-SCHEMA](./DEPLOYTOKEN-CALLDATA-SCHEMA.md) — the full `PoolConfig`/`LockerConfig` tuple layout these ticks live in.
- [FACTORY-EXTENSION-LIFECYCLE](./FACTORY-EXTENSION-LIFECYCLE.md) — how `extensionsSupply` is reserved before `poolSupply` is computed.
- [NATIVE-ETH-WETH-CURRENCY-MODEL](./NATIVE-ETH-WETH-CURRENCY-MODEL.md) — why the paired token is WETH, not native ETH (`ETHPoolNotAllowed`).
- [TOKEN-DETAIL-ENRICHMENT](./TOKEN-DETAIL-ENRICHMENT.md) — reconstructing the liquidity distribution chart from `TokenRewardAdded`.
