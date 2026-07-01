LP locker fee conversion lifecycle explains how Bonker locks Uniswap v4 LP positions, collects accrued LP fees, optionally swaps them into each reward recipient's preferred token, stores claim balances in `BonkerFeeLocker`, and exposes those balances on token detail pages; read this before changing `src/lp-lockers/BonkerLpLockerFeeConversion.sol`, `src/BonkerFeeLocker.sol`, hook fee-claim timing, launch `lockerData`, or LP reward recipient controls.

This page covers natural-language queries such as `BonkerLpLockerFeeConversion`, `LpFeeConversionInfo`, `feePreferences`, `collectRewardsWithoutUnlock`, `collectRewards`, `_bringFeesIntoContract`, `_handleFees`, `FeesSwapped`, `TokenRewardAdded`, `availableFees`, `FeeIn.Both`, `FeeIn.Paired`, `FeeIn.Bonker`, "why LP rewards skip while MEV is active", "where do creator LP fees accrue", and "why FeeLocker claim is separate from factory team fees". It focuses on LP fees, not factory protocol fees. The factory team-fee path remains `Bonker.claimTeamFees(token)` and pays `teamFeeRecipient`.

## Why It Exists

Bonker launch liquidity is meant to be permanent. The factory transfers the pool's token supply into an LP locker, the locker mints Uniswap v4 position NFTs to itself, and no normal user flow can withdraw those LP NFTs.

Locked liquidity still earns LP fees. Those fees need a separate accounting path because the position NFT owner is the locker contract, while the intended beneficiaries are the launch-time `rewardRecipients`. Bonker solves that with two contracts:

- `BonkerLpLockerFeeConversion` owns the Uniswap v4 positions and periodically pulls accrued fees out of the pool.
- `BonkerFeeLocker` stores per-recipient, per-token claim balances and lets anyone trigger `claim(feeOwner, token)` to send the balance to `feeOwner`.

The fee conversion locker adds one more feature on top of a basic locker: each reward slot can choose whether it wants collected fees in the Bonker token, the paired token, or both. If a slot prefers the opposite side of a collected fee token, the locker batches that portion into one swap and then stores the swapped output in `BonkerFeeLocker`.

This design keeps swap-heavy work out of the API server and out of frontend state. The chain stores the LP position, reward split, reward admins, reward recipients, fee preferences, and claimable balances. The server only reads that state for `/api/tokens/:address`.

## Key Files

| File | Why it matters |
| --- | --- |
| `src/Bonker.sol:288` | Approves the locker to pull the pool token supply during deployment. |
| `src/Bonker.sol:291` | Calls `IBonkerLpLocker.placeLiquidity()` after pool initialization. |
| `src/interfaces/IBonkerLPLocker.sol:8` | Defines `TokenRewardInfo`, the persistent reward split and position metadata returned by `tokenRewards()`. |
| `src/interfaces/IBonkerLPLocker.sol:18` | Defines `TokenRewardAdded`, the event used by token-detail enrichment to reconstruct initial liquidity ranges. |
| `src/lp-lockers/interfaces/IBonkerLpLockerFeeConversion.sol:8` | Defines `FeeIn` values: `Both`, `Paired`, and `Bonker`. |
| `src/lp-lockers/interfaces/IBonkerLpLockerFeeConversion.sol:14` | Defines `LpFeeConversionInfo`, the ABI payload stored in `lockerConfig.lockerData`. |
| `src/lp-lockers/BonkerLpLockerFeeConversion.sol:102` | `placeLiquidity()` validates reward arrays, decodes fee preferences, pulls launch supply, mints LP positions, and stores reward state. |
| `src/lp-lockers/BonkerLpLockerFeeConversion.sol:198` | `_mintLiquidity()` validates tick/position BPS config and mints one or more Uniswap v4 positions. |
| `src/lp-lockers/BonkerLpLockerFeeConversion.sol:318` | `collectRewardsWithoutUnlock()` is the hook-safe collection path used while the pool is already unlocked. |
| `src/lp-lockers/BonkerLpLockerFeeConversion.sol:325` | `collectRewards()` is the public collection path that opens a normal Uniswap v4 lock. |
| `src/lp-lockers/BonkerLpLockerFeeConversion.sol:329` | `_mevModuleOperating()` skips collection while a launch MEV module can block swap-backs. |
| `src/lp-lockers/BonkerLpLockerFeeConversion.sol:357` | `_collectRewards()` guards recursion, claims position fees, handles both pool currencies, and emits `ClaimedRewards`. |
| `src/lp-lockers/BonkerLpLockerFeeConversion.sol:423` | `_handleFees()` splits direct deposits from swapped deposits according to `rewardBps` and `feePreferences`. |
| `src/lp-lockers/BonkerLpLockerFeeConversion.sol:556` | `_bringFeesIntoContract()` uses zero-liquidity `DECREASE_LIQUIDITY` actions to collect accrued fees. |
| `src/lp-lockers/BonkerLpLockerFeeConversion.sol:594` | `_uniSwapUnlocked()` swaps directly through `IPoolManager` from the hook-triggered unlocked path. |
| `src/lp-lockers/BonkerLpLockerFeeConversion.sol:631` | `_uniSwapLocked()` swaps through Universal Router when collection starts outside the hook. |
| `src/lp-lockers/BonkerLpLockerFeeConversion.sol:696` | `updateRewardRecipient()` lets a reward admin change the destination for one reward slot. |
| `src/lp-lockers/BonkerLpLockerFeeConversion.sol:718` | `updateFeePreference()` lets a reward admin change future conversion behavior for one reward slot. |
| `src/lp-lockers/BonkerLpLockerFeeConversion.sol:742` | `updateRewardAdmin()` transfers control of one reward slot. |
| `src/BonkerFeeLocker.sol:16` | Stores claim balances by `feeOwner` and ERC20 token. |
| `src/BonkerFeeLocker.sol:26` | `storeFees()` accepts deposits only from allowed depositors and credits received balance deltas. |
| `src/BonkerFeeLocker.sol:41` | `availableFees()` is the read path used by token-detail enrichment. |
| `src/BonkerFeeLocker.sol:46` | `claim()` zeros and transfers the stored balance to the fee owner. |
| `src/hooks/BonkerHookV2.sol:401` | `_lpLockerFeeClaim()` finds the Bonker token for a pool and calls `collectRewardsWithoutUnlock()`. |
| `src/hooks/BonkerHookV2.sol:436` | `_beforeSwap()` triggers hook protocol-fee claims, then LP locker fee claims, before MEV module handling. |
| `client/components/LaunchPage.jsx:324` | Encodes `lockerData` as `LpFeeConversionInfo` from the launch form reward token choice. |
| `client/components/LaunchPage.jsx:434` | Builds `lockerConfig` with LP locker address, reward arrays, tick ranges, position BPS, and `lockerData`. |
| `client/components/admin/presaleConfig.js:41` | Encodes presale launch `lockerData` for the admin presale deployment flow. |
| `server/tokens.js:290` | Token-detail enrichment reads `tokenRewards()` from the LP locker. |
| `server/tokens.js:305` | Token-detail enrichment reads `availableFees(recipient, WETH)` from `BonkerFeeLocker`. |

## How It Works

### Launch-Time Liquidity Placement

The launch form and admin presale deployment flow both build a `lockerConfig` inside `IBonker.DeploymentConfig`. The important fields for this lifecycle are:

- `locker`: the deployed `BonkerLpLockerFeeConversion` address.
- `rewardAdmins`: addresses allowed to update one reward slot.
- `rewardRecipients`: addresses that accrue fee balances.
- `rewardBps`: BPS splits that must sum to `10_000`.
- `tickLower`, `tickUpper`, `positionBps`: the initial LP range plan.
- `lockerData`: ABI-encoded `IBonkerLpLockerFeeConversion.LpFeeConversionInfo`.

`LaunchPage` lets the user choose a reward token preference, converts it to a numeric `FeeIn` enum value, and encodes it as a one-element `feePreference` array. The public launch flow usually builds one reward slot with the connected address as admin and recipient. The admin presale flow also builds one reward slot, with `lockerData` encoded in the same tuple shape.

When `Bonker.deployToken()` reaches liquidity placement, the factory has already deployed the ERC20 and computed the pool supply after extension reservations. It approves the locker for `poolSupply`, then calls `placeLiquidity(lockerConfig, poolConfig, poolKey, poolSupply, token)`.

### Locker Validation and Position Minting

`placeLiquidity()` is callable only by the factory. It decodes `lockerConfig.lockerData` as `LpFeeConversionInfo` and stores `feePreference` separately from `TokenRewardInfo`.

The reward arrays are intentionally strict:

- `rewardBps`, `rewardAdmins`, `rewardRecipients`, and `feePreference` must have the same length.
- the number of reward participants must be at most `MAX_REWARD_PARTICIPANTS`, currently 7;
- there must be at least one reward recipient;
- each BPS value must be non-zero;
- all reward BPS values must sum to `BASIS_POINTS`, currently `10_000`;
- reward admin and recipient addresses cannot be zero.

After reward validation, the locker pulls `poolSupply` from the factory and calls `_mintLiquidity()`. Position config is also strict:

- `tickLower`, `tickUpper`, and `positionBps` must have equal length;
- there must be at least one position and at most `MAX_LP_POSITIONS`, currently 7;
- each lower tick must be less than or equal to its upper tick;
- ticks must be inside `TickMath.MIN_TICK` and `TickMath.MAX_TICK`;
- ticks must align to `poolConfig.tickSpacing`;
- each lower tick must be at or above `poolConfig.tickIfToken0IsBonker`;
- all position BPS values must sum to `10_000`.

The locker computes liquidity for each range from the launch token amount allocated to that range, mints Uniswap v4 position NFTs to itself through `positionManager.modifyLiquidities()`, stores the first `positionId`, and assumes consecutive position IDs for the remaining minted ranges.

```text
Launch form / admin presale
  -> lockerConfig.rewardRecipients + lockerData.feePreference
  -> Bonker.deployToken()
  -> Bonker approves poolSupply to locker
  -> BonkerLpLockerFeeConversion.placeLiquidity()
  -> Uniswap v4 position NFTs minted to the locker
  -> TokenRewardAdded + InitialFeePreferences
```

### Collection Triggers

LP fee collection has two entry points.

`collectRewardsWithoutUnlock(token)` is the hook path. During swaps, `BonkerHookV2._beforeSwap()` calls `_lpLockerFeeClaim()`, which calls `collectRewardsWithoutUnlock()` on the locker registered for the pool. The pool is already unlocked in this context, so the locker later uses `positionManager.modifyLiquiditiesWithoutUnlock()`.

`collectRewards(token)` is the public path. Anyone can call it when they want to collect accrued LP fees outside of a swap. Because the pool is not already unlocked, this path uses the normal `positionManager.modifyLiquidities()` flow and Universal Router for any needed conversion swap.

Both entry points call `_collectRewards(token, withoutUnlock)`. `_collectRewards()` first checks `_inCollect` and returns early on recursion. This matters because a swap-back can itself move through hook code. The guard prevents a collection-triggered swap from starting another nested collection.

Before collecting, `_collectRewards()` checks `_mevModuleOperating(token)`. If the pool has an enabled MEV module and the hook's `MAX_MEV_MODULE_DELAY` window has not expired, collection returns without doing anything. This avoids swap-backs being blocked by launch protection. Once the MEV module is disabled or the max delay expires, collection can proceed.

### Pulling Fees Out of Positions

`_bringFeesIntoContract()` collects accrued fees from each locked position without reducing liquidity. It builds one zero-liquidity `DECREASE_LIQUIDITY` action per position, then a `TAKE_PAIR` action to move both pool currencies into the locker.

The function measures token balances before and after the position manager call and returns the deltas as `(amount0, amount1)`. Those deltas are the actual fee amounts now held by the locker contract.

This balance-delta approach keeps the rest of the collection logic independent from Uniswap internals. `_collectRewards()` receives `amount0` and `amount1`, identifies the ERC20 addresses for `poolKey.currency0` and `poolKey.currency1`, and passes each non-zero amount to `_handleFees()`.

### Fee Preferences and Conversion

Each reward slot has a `FeeIn` value:

| `FeeIn` | Behavior |
| --- | --- |
| `Both` | Keeps each collected fee token as-is. Bonker-side fees stay Bonker; paired-side fees stay paired. |
| `Paired` | Converts the slot's share of Bonker-side fees into the paired token, while keeping paired-side fees as-is. |
| `Bonker` | Converts the slot's share of paired-side fees into Bonker, while keeping Bonker-side fees as-is. |

`_handleFees(token, rewardToken, amount, withoutUnlock)` decides which reward slots need conversion for the current `rewardToken`. If `rewardToken` is the Bonker token, slots that prefer `FeeIn.Paired` go into the swap bucket. If `rewardToken` is the paired token, slots that prefer `FeeIn.Bonker` go into the swap bucket. Every other slot receives a direct deposit in the current `rewardToken`.

Direct deposits are credited immediately:

1. compute the slot's share from `rewardBps[i] * amount / 10_000`;
2. approve `BonkerFeeLocker` for that amount;
3. call `feeLocker.storeFees(rewardRecipient, rewardToken, amountForSlot)`.

The swap bucket is batched. The locker swaps the remaining portion once, then distributes the swap output across the slots that requested conversion. Dust is assigned to the last relevant recipient in each distribution loop so the contract does not strand tiny balances.

Unlocked collection swaps directly through `IPoolManager.swap()` because it is already inside the pool unlock context. Locked collection uses Universal Router with a `V4_SWAP` command, Permit2 approval, and `amountOutMinimum: 0`.

### FeeLocker Storage and Claims

`BonkerFeeLocker` is the accounting endpoint for LP rewards. It only accepts deposits from addresses the owner has added through `addDepositor()`. Deployment scripts add the LP locker as an allowed depositor, and MEV auction modules can also deposit auction proceeds into the same fee locker path.

`storeFees(feeOwner, token, amount)` pulls tokens from the depositor and credits `feesToClaim[feeOwner][token]` by the received balance delta. The balance-delta accounting is deliberate: if a token charges transfer fees or behaves strangely, the claim balance reflects what the FeeLocker actually received, not the requested transfer amount.

`availableFees(feeOwner, token)` returns the current claimable balance. `claim(feeOwner, token)` can be called by anyone, but it always transfers to `feeOwner`, not to `msg.sender`. That lets UIs or helpers trigger a claim on behalf of a recipient without taking custody.

For normal WETH-paired Bonker launches, the creator-facing claim path is:

```text
swap on Bonker pool
  -> hook calls collectRewardsWithoutUnlock()
  -> locker collects LP fees from locked positions
  -> locker stores WETH or converted WETH in FeeLocker
  -> recipient or helper calls feeLocker.claim(recipient, WETH)
  -> WETH transfers to recipient
```

This is distinct from protocol fees. Protocol fees accumulate in the factory and are claimed through `Bonker.claimTeamFees(WETH)` to `teamFeeRecipient`.

### Reward Slot Administration

Reward admins are per-slot. A reward admin for `rewardIndex` can:

- call `updateRewardRecipient(token, rewardIndex, newRecipient)` to change where future fee deposits for that slot are credited;
- call `updateFeePreference(token, rewardIndex, newFeePreference)` to change future conversion behavior;
- call `updateRewardAdmin(token, rewardIndex, newAdmin)` to transfer control of that slot.

These changes do not rewrite already stored FeeLocker balances. If fees have already been deposited for an old recipient, those balances remain claimable by the old recipient. The updated recipient or fee preference affects the next successful LP fee collection.

## Invariants and Edge Cases

The factory must enable the locker for the hook used by the pool. `Bonker.deployToken()` checks `enabledLockers[locker][hook]`, so a locker deployed for one hook is not automatically valid for another hook.

`BonkerFeeLocker` must allow the LP locker as a depositor. If the locker can collect and swap fees but cannot call `storeFees()`, collection reverts at the accounting boundary.

`lockerConfig.lockerData` must encode `IBonkerLpLockerFeeConversion.LpFeeConversionInfo`. An empty `lockerData` value can work for older or different locker contracts, but it will not decode for this fee conversion locker.

Reward arrays and fee preferences are positional. `rewardBps[i]`, `rewardAdmins[i]`, `rewardRecipients[i]`, and `feePreference[i]` describe one slot. Reordering one array without the others changes who controls or receives that slot.

Position IDs are assumed consecutive after `positionManager.nextTokenId()`. `_bringFeesIntoContract()` later iterates `positionId + i` for `numPositions`, so the mint sequence must remain uninterrupted inside `_mintLiquidity()`.

MEV protection can make collection a no-op during the launch window. This is expected and prevents swap-backs from being blocked by active launch protection.

`_inCollect` makes recursive collection return early. If a collection-triggered swap moves through hook code, nested `collectRewardsWithoutUnlock()` calls intentionally do nothing.

Conversion swaps use no slippage floor. `_uniSwapLocked()` sets `amountOutMinimum` to `0`, and `_uniSwapUnlocked()` accepts whatever the pool returns. This keeps fee collection permissionless but means conversion output is market-dependent at call time.

`FeeIn.Both` does not mean "convert everything to WETH". It means "do not convert this slot's share; store each collected side in that side's token." For WETH-paired pools, a slot using `Both` can accrue both Bonker and WETH balances.

Token-detail enrichment currently reads WETH `availableFees` for each reward recipient. If a launch uses fee preferences that leave Bonker balances in FeeLocker, those non-WETH balances are not the same number as the WETH display.

`claim(feeOwner, token)` sends funds to `feeOwner` regardless of caller. A helper can pay gas for another recipient, but it cannot redirect the payout.

Already deposited fees stay with the recipient that was current when `storeFees()` ran. Changing `rewardRecipients` only affects later deposits.

Emergency owner withdrawals on the LP locker are for stranded ETH or ERC20 balances in the locker contract. They do not withdraw the locked Uniswap v4 position NFTs through the normal reward lifecycle.

## Cross-References

- [CONTRACT-DEPLOYMENT-WORKFLOW](./CONTRACT-DEPLOYMENT-WORKFLOW.md) covers the split LpLocker deployment, `FOUNDRY_PROFILE=lplocker`, and enabling the locker per hook.
- [LAUNCH-FORM-DEPLOYMENT-CONFIG](./LAUNCH-FORM-DEPLOYMENT-CONFIG.md) covers how `/launch` builds `IBonker.DeploymentConfig`, including `lockerConfig`.
- [TOKEN-DETAIL-ENRICHMENT](./TOKEN-DETAIL-ENRICHMENT.md) covers how `/api/tokens/:address` reads `tokenRewards()`, `availableFees()`, and liquidity range events for display.
- [MEV-MODULE-LIFECYCLE](./MEV-MODULE-LIFECYCLE.md) explains why launch-time MEV modules can affect swap and collection timing.
- [OWNER-ADMIN-PERMISSION-MODEL](./OWNER-ADMIN-PERMISSION-MODEL.md) distinguishes LP reward admins from factory owner/admin roles and token admins.
- [ADMIN-OPERATIONS-CONSOLE](./ADMIN-OPERATIONS-CONSOLE.md) covers the separate factory protocol-fee claim path exposed in `/admin`.
