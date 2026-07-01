Hook fee accounting explains how Bonker's Uniswap v4 hooks choose the current LP fee, derive the protocol fee, collect protocol-fee balances into the factory, trigger LP locker fee collection, and keep MEV and pool-extension callbacks ordered; read this before changing `src/hooks/BonkerHookV2.sol`, `src/hooks/BonkerHookDynamicFeeV2.sol`, `src/hooks/BonkerHookStaticFeeV2.sol`, hook fee constants, swap delta math, or hook permission flags.

This page covers natural-language queries such as `PROTOCOL_FEE_NUMERATOR`, `protocolFee`, `_setFee`, `_setProtocolFee`, `_hookFeeClaim`, `_lpLockerFeeClaim`, `beforeSwapReturnDelta`, `afterSwapReturnDelta`, `mevModuleSetFee`, `PoolSwapData`, `ClaimProtocolFees`, `simulateSwap`, "why are protocol fees claimed on the next swap", "why are hook fees only taken in the paired token", and "how does the hook keep factory protocol fees separate from creator LP fees". It focuses on the hook-level accounting path. Factory ownership, LP reward splitting, MEV module behavior, pool extension setup, and token-detail rendering are covered by nearby docs.

## Why It Exists

Bonker uses Uniswap v4 hooks to charge two related but separate fee streams on every launched pool.

The LP fee is the Uniswap pool fee. It stays in the pool position and is later collected by the LP locker for launch-time reward recipients. The protocol fee is Bonker's factory-owned fee. It is computed as a fixed fraction of the imposed LP fee and is accumulated in the factory balance, then claimed with `Bonker.claimTeamFees(token)`.

That split creates a subtle accounting problem. Uniswap v4 swap callbacks expose different specified and unspecified deltas depending on whether the user is doing exact input or exact output, and depending on whether the user is swapping into or out of the Bonker token. Bonker wants the protocol fee to be paid in the paired token, not in the launched token, so the hook has to decide whether to take the protocol fee in `beforeSwap` or `afterSwap`.

The hook also sits in the middle of other systems. Before the swap it can update the pool's dynamic LP fee, claim protocol fees left in PoolManager accounting from an earlier swap, claim LP locker rewards while the pool is already unlocked, and let an MEV module raise the fee for the current swap. After the swap it can run a pool extension with the corrected user-facing delta.

The result is a compact but high-risk lifecycle: a bad callback order, sign error, stale `protocolFee`, wrong max-fee guard, or missing hook permission can redirect money, block swaps, or make the LP fee and protocol fee diverge.

## Key Files

| File | Why it matters |
| --- | --- |
| `src/Bonker.sol:79` | `claimTeamFees(token)` transfers factory-held protocol-fee balances to `teamFeeRecipient`. |
| `src/Bonker.sol:253` | `_initializePool()` validates the hook allowlist and calls `IBonkerHook.initializePool()`. |
| `src/interfaces/IBonkerHook.sol:35` | Defines `MevModuleDisabled` and `ClaimProtocolFees`, the core events emitted by hook accounting. |
| `src/interfaces/IBonkerHook.sol:39` | Defines the factory and open pool initialization boundary every hook implementation must satisfy. |
| `src/hooks/interfaces/IBonkerHookV2.sol:22` | Defines `PoolInitializationData`, whose `feeData` is decoded by static or dynamic fee hooks. |
| `src/hooks/interfaces/IBonkerHookV2.sol:28` | Defines `PoolSwapData`, the shared swap-data envelope for MEV modules and pool extensions. |
| `src/hooks/BonkerHookV2.sol:50` | Sets `MAX_LP_FEE`, `MAX_MEV_LP_FEE`, `PROTOCOL_FEE_NUMERATOR`, and `FEE_DENOMINATOR`. |
| `src/hooks/BonkerHookV2.sol:100` | `_setProtocolFee()` derives `protocolFee` as 20% of the active LP fee. |
| `src/hooks/BonkerHookV2.sol:201` | `_initializePool()` builds the v4 `PoolKey`, stores `bonkerIsToken0`, initializes PoolManager, and decodes pool data. |
| `src/hooks/BonkerHookV2.sol:290` | `mevModuleSetFee()` lets the assigned MEV module raise the current swap fee within `MAX_MEV_LP_FEE`. |
| `src/hooks/BonkerHookV2.sol:401` | `_lpLockerFeeClaim()` asks the configured locker to collect LP rewards during the unlocked swap path. |
| `src/hooks/BonkerHookV2.sol:416` | `_hookFeeClaim()` converts PoolManager accounting for prior protocol fees into ERC20 balance on the factory. |
| `src/hooks/BonkerHookV2.sol:437` | `_beforeSwap()` orders fee update, protocol-fee claim, LP-fee claim, MEV callback, and before-swap protocol-fee delta math. |
| `src/hooks/BonkerHookV2.sol:500` | `_afterSwap()` handles after-swap protocol-fee delta math and then runs the pool extension. |
| `src/hooks/BonkerHookV2.sol:606` | `getHookPermissions()` declares the callback and return-delta permissions required by the accounting path. |
| `src/hooks/BonkerHookDynamicFeeV2.sol:42` | `_initializeFeeData()` stores dynamic fee parameters and enforces base/max fee bounds. |
| `src/hooks/BonkerHookDynamicFeeV2.sol:71` | Dynamic `_setFee()` estimates volatility, sets `protocolFee`, and updates the pool LP fee. |
| `src/hooks/BonkerHookDynamicFeeV2.sol:215` | `simulateSwap()` runs an internal swap and reverts with `TickReturned` to estimate post-swap tick. |
| `src/hooks/BonkerHookStaticFeeV2.sol:22` | Static `_initializeFeeData()` stores the per-direction Bonker and paired LP fee settings. |
| `src/hooks/BonkerHookStaticFeeV2.sol:39` | Static `_setFee()` chooses the LP fee by swap direction and updates `protocolFee`. |
| `src/lp-lockers/BonkerLpLockerFeeConversion.sol:314` | `collectRewardsWithoutUnlock()` is the hook-triggered LP-fee collection entrypoint. |

## How It Works

### Pool setup

Factory deployments enter the hook through `Bonker._initializePool()`. The factory checks that the selected hook is enabled, then calls `IBonkerHook.initializePool()` with the new token, paired token, starting tick, tick spacing, locker, MEV module, and encoded `poolData`.

`BonkerHookV2._initializePool()` rejects native ETH pools, determines whether the Bonker token is `currency0`, builds a `PoolKey` with `LPFeeLibrary.DYNAMIC_FEE_FLAG`, initializes the pool in PoolManager, stores `poolCreationTimestamp`, and decodes `poolData` into `PoolInitializationData`.

`PoolInitializationData` has three fields in order:

```text
PoolInitializationData
  extension      -> optional pool extension address
  extensionData  -> bytes forwarded to initializePreLockerSetup
  feeData        -> bytes decoded by the concrete fee hook
```

The concrete hook decides what `feeData` means. `BonkerHookStaticFeeV2` decodes `PoolStaticConfigVars` and stores one LP fee for swaps into the paired side and one LP fee for swaps into the Bonker side. `BonkerHookDynamicFeeV2` decodes `PoolDynamicConfigVars` and stores parameters for volatility-based fee calculation.

### Swap callback order

The V2 hook needs both `beforeSwap` and `afterSwap` because not every swap shape exposes the paired-token amount at the same time.

The high-level order is:

```text
beforeSwap
  _setFee(poolKey, swapParams)
  _hookFeeClaim(poolKey)
  _lpLockerFeeClaim(poolKey)
  _runMevModule(poolKey, swapParams, swapData)
  mint protocol-fee accounting for cases that need before-swap deltas

PoolManager swap

afterSwap
  mint protocol-fee accounting for cases that need after-swap deltas
  normalize delta for pool extensions
  _runPoolExtension(poolKey, swapParams, sender, delta, swapData)
```

`_setFee()` always runs before the MEV module. That gives the pool its normal static or dynamic fee and sets `protocolFee` to 20% of that LP fee. If an operational MEV module wants a higher fee for this swap, it calls `mevModuleSetFee()`. The hook accepts that raise only when the caller is the pool's assigned module, the module is still operational, the requested fee is at or below `MAX_MEV_LP_FEE`, and the requested fee is higher than the pool's current LP fee.

`_hookFeeClaim()` intentionally claims fees from the previous swap before the current swap mints new protocol-fee accounting. It reads the hook's PoolManager balance for the paired token, burns that accounting balance, and takes the real ERC20 token to the factory. `ClaimProtocolFees(token, amount)` is emitted for this transfer into the factory.

`_lpLockerFeeClaim()` calls `collectRewardsWithoutUnlock(token)` on the configured locker when the pool was created by the factory. Open pools have no locker and skip this path. The locker has its own re-entrancy and MEV-active guards, so a hook-triggered collection can no-op without blocking the user swap.

### Protocol fee basis

`PROTOCOL_FEE_NUMERATOR` is `200_000` and `FEE_DENOMINATOR` is `1_000_000`, so `_setProtocolFee(lpFee)` sets:

```text
protocolFee = lpFee * 200_000 / 1_000_000
```

The protocol fee is therefore 20% of the active LP fee, not 20% of the trade notional. If the LP fee is 1%, `protocolFee` becomes 0.2% of the relevant paired-token side of the swap.

The value lives in the hook's `protocolFee` storage slot, shared by the hook contract. `_setFee()` updates it at the start of every swap before the hook uses it for delta math. That storage shape is why every swap must call `_setFee()` before any MEV fee raise or protocol-fee minting.

### Fee token selection

The hook treats the launched token as the Bonker side and the other currency as the paired side. `bonkerIsToken0[poolId]` records which v4 currency is the Bonker token.

Protocol fees are collected in the paired token. `_hookFeeClaim()` chooses `poolKey.currency1` when Bonker is token0 and `poolKey.currency0` when Bonker is token1. The same paired-token choice is used when `_beforeSwap()` and `_afterSwap()` mint PoolManager accounting to the hook.

This is also why `initializePoolOpen()` rejects `bonker == weth`. The open-pool path lets any token use the hook, but the hook assumes the Bonker side is not the preferred paired asset for protocol fees.

### Four swap shapes

The hook distinguishes exact input from exact output and whether the user is swapping for the Bonker token.

`isExactInput` is `swapParams.amountSpecified < 0`. `swappingForBonker` is `swapParams.zeroForOne != bonkerIsToken0[poolId]`.

The protocol fee is taken in `beforeSwap` when the paired-token amount is specified before the pool swap:

| Shape | Callback | What the hook does |
| --- | --- | --- |
| Exact input, swapping for Bonker | `beforeSwap` | Decreases the specified paired input by a scaled protocol fee and mints that fee to the hook. |
| Exact output, swapping away from Bonker | `beforeSwap` | Increases the specified paired output by a scaled protocol fee and mints that fee to the hook. |

The protocol fee is taken in `afterSwap` when the paired-token amount is only known from the swap result:

| Shape | Callback | What the hook does |
| --- | --- | --- |
| Exact input, swapping away from Bonker | `afterSwap` | Decreases paired output by the protocol fee and mints that fee to the hook. |
| Exact output, swapping for Bonker | `afterSwap` | Increases paired input by the protocol fee and mints that fee to the hook. |

The before-swap cases use scaled formulas:

```text
exact input into Bonker:
  scaledProtocolFee = protocolFee / (1_000_000 + protocolFee)

exact output away from Bonker:
  scaledProtocolFee = protocolFee / (1_000_000 - protocolFee)
```

Those formulas compensate for taking the protocol fee before the LP swap so the effective relationship between LP fee and protocol fee stays close to the after-swap cases.

### Dynamic fee path

`BonkerHookDynamicFeeV2` updates the LP fee from an estimated volatility accumulator. The accumulator compares a reference tick to a simulated post-swap tick, applies decay/reset rules, and feeds `_getLpFee()`.

The dynamic fee is:

```text
variableFee = feeControlNumerator * volatilityAccumulator^2 / FEE_CONTROL_DENOMINATOR
lpFee = min(variableFee + baseFee, maxLpFee)
```

`_getTicks()` calls `this.simulateSwap(poolKey, swapParams)` and expects it to revert with `TickReturned(tickAfter)`. `simulateSwap()` can only be called by the hook itself, applies the same before-swap protocol-fee adjustments used for the real swap, performs a PoolManager swap, reads slot0, and reverts with the estimated ending tick.

This is an estimation loop, not a second real user swap. The revert is the return channel.

### Static fee path

`BonkerHookStaticFeeV2` uses two configured LP fees:

```text
if swapParams.zeroForOne != bonkerIsToken0[poolId]:
  fee = pairedFee[poolId]
else:
  fee = bonkerFee[poolId]
```

After choosing the directional fee, it sets `protocolFee` from that fee and calls `updateDynamicLPFee()`. The pool still uses Uniswap's dynamic fee flag, but the hook supplies a static direction-based value immediately before each swap.

### Factory claim path

The hook does not transfer protocol fees directly to `teamFeeRecipient`.

Protocol-fee accounting moves in two steps:

1. Swap callbacks mint paired-token PoolManager accounting to the hook.
2. A later `_hookFeeClaim()` burns the hook accounting balance and takes the paired token to the factory.

The factory then holds a normal ERC20 balance. `Bonker.claimTeamFees(token)` transfers the entire factory balance of that token to `teamFeeRecipient`. This separation is why factory protocol fees and creator LP fees have different claim functions.

## Invariants And Edge Cases

### Hook permissions must match callback behavior

`getHookPermissions()` must keep `beforeSwap`, `afterSwap`, `beforeSwapReturnDelta`, and `afterSwapReturnDelta` enabled. The protocol-fee logic depends on returning deltas from both callbacks. It also keeps `beforeInitialize` enabled so direct PoolManager initialization reverts through `_beforeInitialize()`, forcing pool creation through `initializePool()` or `initializePoolOpen()`.

### `_setFee()` must run before protocol-fee math

`protocolFee` is contract storage. The active swap's fee value is only correct after the concrete hook runs `_setFee()`. Moving MEV callbacks, protocol-fee minting, or simulation ahead of `_setFee()` can use a stale value from another pool or prior swap.

### MEV can raise but not lower the active fee

`mevModuleSetFee()` only accepts a fee above the current pool LP fee. It also caps the value at `MAX_MEV_LP_FEE`. Normal static or dynamic fee behavior sets the baseline; MEV modules can temporarily increase the fee during their launch window.

### LP fee collection is best-effort during swaps

`_lpLockerFeeClaim()` can be called while the pool is already unlocked, but the locker may return early. It skips during recursive collection and while the MEV module is still operating. Hook callers should not depend on every swap distributing LP fees.

### Protocol fees are claimed one swap later

`_hookFeeClaim()` reads the hook's PoolManager balance before the current swap mints new protocol-fee accounting. That means protocol fees minted by this swap remain in PoolManager accounting until a later swap triggers another claim. Pools with no later swaps can still have protocol-fee accounting sitting at the hook level.

### Open pools do not have factory-side modules

`initializePoolOpen()` creates a pool without locker, MEV module, or pool extension support. It still uses the hook fee accounting path, so protocol fees can accrue to the factory, but LP locker auto-claim and pool-extension callbacks are absent.

### Pool extension deltas should see user-facing amounts

For before-swap protocol-fee cases, `_afterSwap()` rewrites the relevant balance delta back to the user's specified amount before calling `_runPoolExtension()`. Pool extensions should receive deltas that reflect the completed user swap, not the intermediate hook accounting adjustment.

### The paired-token assumption is load-bearing

Protocol fees are always taken in the non-Bonker currency. Launch config, open-pool setup, fee displays, and accounting assumptions should preserve that distinction. Treating WETH or any paired asset as the Bonker side changes which token the factory receives.

## Cross-References

- [LP-LOCKER-FEE-CONVERSION-LIFECYCLE](./LP-LOCKER-FEE-CONVERSION-LIFECYCLE.md) for creator LP fee collection, conversion preferences, and FeeLocker claims.
- [MEV-MODULE-LIFECYCLE](./MEV-MODULE-LIFECYCLE.md) for launch-time module behavior and sniper-protection fee raises.
- [POOL-EXTENSION-HOOK-LIFECYCLE](./POOL-EXTENSION-HOOK-LIFECYCLE.md) for pool extension setup and after-swap callback semantics.
- [FACTORY-EXTENSION-LIFECYCLE](./FACTORY-EXTENSION-LIFECYCLE.md) for launch-time extension supply reservation and factory sequencing.
- [LAUNCH-FORM-DEPLOYMENT-CONFIG](./LAUNCH-FORM-DEPLOYMENT-CONFIG.md) for frontend encoding of `PoolInitializationData` and fee presets.
- [CONTRACT-DEPLOYMENT-WORKFLOW](./CONTRACT-DEPLOYMENT-WORKFLOW.md) for hook deployment, mined addresses, and verification profile constraints.
- [FOUNDRY-REGRESSION-SUITE](./FOUNDRY-REGRESSION-SUITE.md) for Solidity tests around fee flow and hook-adjacent invariants.
- [OWNER-ADMIN-PERMISSION-MODEL](./OWNER-ADMIN-PERMISSION-MODEL.md) for factory owner/admin permissions that govern hook allowlisting and team-fee claims.
