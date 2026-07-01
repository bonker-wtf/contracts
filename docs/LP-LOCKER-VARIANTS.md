LP locker variants compares the two coexisting Uniswap v4 LP locker implementations in `src/lp-lockers/` — the deployed `BonkerLpLockerFeeConversion` and the dormant, source/test-only `BonkerLpLockerMultiple` — so you know which one Bonker actually ships, why the other still exists, and what changes when you move config between them; read this before changing either locker, the `IBonkerLpLocker` family of interfaces, or any deploy script that constructs a locker.

This page answers natural-language queries such as "difference between BonkerLpLockerMultiple and BonkerLpLockerFeeConversion", "which LP locker is deployed on Base", "why does the locker constructor take universalRouter and poolManager", "does the multiple locker swap fees", "FeeIn enum vs no fee preference", "lockerData empty vs LpFeeConversionInfo", "BONKER_VERSION 2 locker", and "why is BonkerLpLockerMultiple still in the repo". It is a comparison, not a deep dive: the deployed locker's full lifecycle lives in [LP-LOCKER-FEE-CONVERSION-LIFECYCLE](./LP-LOCKER-FEE-CONVERSION-LIFECYCLE.md).

## Why two lockers exist

Bonker forks Clanker's contract set. Clanker shipped a basic multi-recipient LP locker (`BonkerLpLockerMultiple` here) that splits collected LP fees across up to seven reward slots and stores each side in its native pool currency. Bonker then added a second locker, `BonkerLpLockerFeeConversion`, that keeps everything the basic locker does and layers one feature on top: each reward slot can ask for its share to be consolidated into one preferred side (Bonker token or paired token) via a batched swap before the balance is stored.

The fee-conversion locker is the one Bonker deploys (`LpLocker` = `0xBf05b1d5E356f3219D0086A4e09c969ADbe2e7d0`). The multiple locker is never constructed by any deploy script — it stays in the tree as the upstream baseline and as a second implementation that the non-standard-ERC20 regression test exercises side-by-side with the deployed one.

The two are not unrelated forks. `IBonkerLpLockerFeeConversion` **inherits** `IBonkerLpLockerMultiple`, so the fee-conversion locker is a strict superset of the multiple locker's external surface. Every error, event, and admin function the multiple locker exposes is also present on the deployed locker; the deployed locker only adds members.

Writing the comparison down matters because the launch form, the admin presale flow, and the deploy scripts all hardcode the fee-conversion shape (a `LpFeeConversionInfo` `lockerData` payload, a seven-argument constructor). If someone reuses config or a constructor call against the multiple locker — or vice versa — it silently fails to decode or reverts on arity. The differences below are exactly the places that breaks.

## Key files

| File | Why it matters |
| --- | --- |
| `src/lp-lockers/BonkerLpLockerMultiple.sol:27` | Dormant baseline locker contract declaration; `version = "1"`, no `BONKER_VERSION`. |
| `src/lp-lockers/BonkerLpLockerMultiple.sol:43` | Five-argument constructor: owner, factory, feeLocker, positionManager, permit2. No swap dependencies. |
| `src/lp-lockers/BonkerLpLockerMultiple.sol:80` | `placeLiquidity()` — same validation and minting as the deployed locker, but ignores `lockerData`. |
| `src/lp-lockers/BonkerLpLockerMultiple.sol:297` | `_collectRewards()` splits both currencies by `rewardBps` and stores each side natively — no swap, no recursion guard, no MEV check. |
| `src/lp-lockers/BonkerLpLockerMultiple.sol:389` | `updateRewardRecipient()` and `updateRewardAdmin()` (line 411) — the only per-slot admin functions. |
| `src/lp-lockers/BonkerLpLockerFeeConversion.sol:36` | Deployed locker contract declaration; `is IBonkerLpLockerFeeConversion`. |
| `src/lp-lockers/BonkerLpLockerFeeConversion.sol:37` | `BONKER_VERSION = 2` distinguishes it from the baseline's `version = "1"` (line 41). |
| `src/lp-lockers/BonkerLpLockerFeeConversion.sol:48` | Extra immutables `poolManager` (line 48) and `universalRouter` (line 51) exist only to run swap-backs. |
| `src/lp-lockers/BonkerLpLockerFeeConversion.sol:60` | Seven-argument constructor adds `universalRouter_` and `poolManager_`. |
| `src/lp-lockers/BonkerLpLockerFeeConversion.sol:329` | `_mevModuleOperating()` — collection no-ops while a launch MEV module can block swap-backs. Absent from the baseline. |
| `src/lp-lockers/BonkerLpLockerFeeConversion.sol:423` | `_handleFees()` routes each slot's share to a direct deposit or a batched swap based on its `FeeIn` preference. |
| `src/lp-lockers/BonkerLpLockerFeeConversion.sol:718` | `updateFeePreference()` — extra per-slot admin function with no baseline equivalent. |
| `src/lp-lockers/interfaces/IBonkerLpLockerMultiple.sol:7` | Baseline interface: errors, `Received`, `RewardRecipientUpdated`, `RewardAdminUpdated`, two update functions. |
| `src/lp-lockers/interfaces/IBonkerLpLockerFeeConversion.sol:7` | `is IBonkerLpLockerMultiple` — proves the superset relationship. |
| `src/lp-lockers/interfaces/IBonkerLpLockerFeeConversion.sol:8` | `FeeIn { Both, Paired, Bonker }` enum — the added concept. |
| `src/lp-lockers/interfaces/IBonkerLpLockerFeeConversion.sol:14` | `LpFeeConversionInfo { FeeIn[] feePreference }` — the `lockerData` payload the deployed locker requires. |
| `script/DeployLpLocker.s.sol:34` | Split production deploy constructs `BonkerLpLockerFeeConversion` under the LpLocker profile. No script constructs `BonkerLpLockerMultiple`. |
| `test/BonkerLegacyErc20Safety.t.sol:336` | `testMultipleLockerStillPullsNonStandardToken` exercises the baseline locker. |
| `test/BonkerLegacyErc20Safety.t.sol:366` | `testFeeConversionLockerStillPullsNonStandardToken` exercises the deployed locker beside it. |

## What is identical

Both lockers share the upstream skeleton, so most behavior is the same and only the deltas below differ.

- Both implement `IBonkerLpLocker` and accept `placeLiquidity()` **only from the factory** (`onlyFactory`).
- Both enforce the same reward-array rules: up to `MAX_REWARD_PARTICIPANTS` (7) slots, non-zero `rewardBps` summing to `BASIS_POINTS` (10_000), no zero admin/recipient addresses.
- Both enforce the same position rules: up to `MAX_LP_POSITIONS` (7) ranges, ticks aligned to `tickSpacing`, `positionBps` summing to 10_000, lower ticks at or above `tickIfToken0IsBonker`.
- Both mint Uniswap v4 position NFTs to themselves and assume consecutive position IDs after `positionManager.nextTokenId()`.
- Both collect fees with zero-liquidity `DECREASE_LIQUIDITY` + `TAKE_PAIR` actions in `_bringFeesIntoContract()`, measuring balance deltas rather than trusting reported amounts.
- Both store recipient balances in `BonkerFeeLocker` via `storeFees()`, so the claim path (`claim(feeOwner, token)`) is the same.
- Both expose `updateRewardRecipient()`/`updateRewardAdmin()`, `onERC721Received()` (factory-only), owner emergency `withdrawETH`/`withdrawERC20`, and `supportsInterface()`.

Because the validation and minting halves are byte-for-byte the same logic, the choice between lockers is purely about **what happens to fees after they are pulled out of the position**.

## What differs

### Fee handling after collection

This is the core difference. After `_bringFeesIntoContract()` returns `(amount0, amount1)`:

`BonkerLpLockerMultiple._collectRewards()` immediately splits each currency by `rewardBps`, assigns rounding dust to the last slot, and calls `feeLocker.storeFees()` once per slot per currency. Every recipient receives fees in whatever the pool currencies are — for a WETH-paired launch, that means both Bonker-token balances and WETH balances. There is no swap and no concept of a preferred side.

`BonkerLpLockerFeeConversion._collectRewards()` passes each currency to `_handleFees()`, which reads each slot's `FeeIn` preference. Slots that want the other side go into a swap bucket; the locker swaps that bucket once and distributes the output. Slots that want the native side get a direct deposit. The result: a recipient can choose to accrue a single consolidated token instead of a mix.

### Constructor and dependencies

The multiple locker's constructor takes five addresses and holds no swap infrastructure. The fee-conversion locker's constructor takes seven — adding `universalRouter_` and `poolManager_` — because it needs `IUniversalRouter` for locked-path swaps (`_uniSwapLocked`) and `IPoolManager` for unlocked-path swaps (`_uniSwapUnlocked`). Passing five args to the deployed locker, or seven to the baseline, will not compile against the wrong constructor.

### Collection safety machinery

The fee-conversion locker carries two guards the baseline lacks, both consequences of swapping:

- `_inCollect` — a reentrancy/recursion flag. A swap-back can route through hook code that re-enters collection; the flag makes the nested call return early.
- `_mevModuleOperating(token)` — skips collection entirely while a launch MEV module is still within `MAX_MEV_MODULE_DELAY`, so a swap-back is not blocked by launch protection.

The multiple locker never swaps, so it never re-enters and never trips MEV protection; it has neither guard and always collects when called.

### The `lockerData` payload

The baseline ignores `lockerConfig.lockerData` — an empty value is fine. The deployed locker decodes `lockerData` as `LpFeeConversionInfo` and stores the `feePreference` array; an empty or wrong-shaped `lockerData` will not decode. This is why `LaunchPage`, the admin presale flow, and the standalone scripts all build a `feePreference` array even when every slot uses `FeeIn.Both`.

### Surface added by the superset

The deployed locker adds the `FeeIn` enum, the `LpFeeConversionInfo` struct, the `feePreferences(token, index)` view, `updateFeePreference()`, and the `FeesSwapped` / `FeePreferenceUpdated` / `InitialFeePreferences` events. None of these exist on the baseline.

```text
shared (both lockers):
  factory -> placeLiquidity() -> validate arrays + ticks -> mint v4 positions
  collect -> _bringFeesIntoContract() -> (amount0, amount1)

BonkerLpLockerMultiple (dormant):
  (amount0, amount1) -> split by rewardBps -> storeFees() per side, native token

BonkerLpLockerFeeConversion (deployed):
  (amount0, amount1) -> _handleFees() per slot
     -> FeeIn.Both:   direct deposit, native token
     -> FeeIn.Paired: Bonker-side share swapped to paired, then deposit
     -> FeeIn.Bonker: paired-side share swapped to Bonker, then deposit
```

## Invariants and edge cases

The factory still gates which locker a hook may use. `Bonker.deployToken()` checks `enabledLockers[locker][hook]`, so even though both contracts satisfy `IBonkerLpLocker`, only the locker explicitly enabled for the chosen hook can place liquidity. Bonker only enables the fee-conversion locker.

`lockerData` is not interchangeable between the two. A payload built for the baseline (effectively empty) will revert when the deployed locker tries to decode `LpFeeConversionInfo`, and a `LpFeeConversionInfo` payload is simply ignored by the baseline. Config is not portable across the variant boundary.

`FeeIn.Both` is the closest the deployed locker gets to baseline behavior: it stores each side in its native token without swapping. A launch using `Both` for every slot accrues the same Bonker + WETH mix the multiple locker would produce — the difference is only that the deployed locker still went through the `_handleFees` path and recorded `feePreferences`.

Conversion swaps use no slippage floor (`amountOutMinimum: 0`). The baseline has no swap and therefore no slippage exposure at all; this is one risk that exists only on the deployed locker.

`BONKER_VERSION = 2` vs `version = "1"` are independent constants and do not track each other. `version` is `"1"` on both contracts; only the deployed locker also declares `BONKER_VERSION = 2`. Do not treat the string `version` as the discriminator between variants — use the contract type or the presence of `feePreferences`.

Both lockers assume consecutive position IDs after `nextTokenId()`. Any change to `_mintLiquidity()` minting order in one locker must be mirrored in the other if you intend to keep them behaviorally aligned, because `_bringFeesIntoContract()` iterates `positionId + i` in both.

Reward-slot administration is positional in both. `rewardBps[i]`, `rewardAdmins[i]`, and `rewardRecipients[i]` describe one slot; the deployed locker adds a parallel `feePreference[i]`. Reordering one array without the others reassigns control or destination of a slot.

## Regression coverage

`test/BonkerLegacyErc20Safety.t.sol` is where the two lockers sit side by side, and the pair of tests doubles as an executable spec of the differences above. Both feed a `MockTokenNoReturn` (an ERC20 whose `transfer`/`approve` return nothing) through `placeLiquidity()` to prove the locker pulls supply via `SafeERC20` rather than trusting a boolean return.

`testMultipleLockerStillPullsNonStandardToken` constructs the baseline with **five** constructor arguments and calls `placeLiquidity()` with `_lockerConfig("")` — an **empty** `lockerData`. It asserts the position mints (`positionId == 1`), the locker holds `POOL_SUPPLY`, and Permit2 saw the full approval amount. The empty payload is accepted because the baseline never decodes `lockerData`.

`testFeeConversionLockerStillPullsNonStandardToken` constructs the deployed locker with **seven** arguments (passing `address(0)` for `universalRouter` and `poolManager`, which is safe here because `FeeIn.Both` never triggers a swap). It must build a real `LpFeeConversionInfo` payload — a one-element `feePreference` array — and pass it as `lockerData`, otherwise the decode reverts. Beyond the same supply/Permit2 assertions, it adds `assertEq(locker.feePreferences(token, 0), FeeIn.Both)`, confirming the preference was stored.

The constructor arity (5 vs 7) and the `lockerData` requirement (empty vs `LpFeeConversionInfo`) are therefore not stylistic — they are the exact lines a caller must change when targeting one locker instead of the other, and the test fails immediately if they are mismatched.

## Cross-references

- [LP-LOCKER-FEE-CONVERSION-LIFECYCLE](./LP-LOCKER-FEE-CONVERSION-LIFECYCLE.md) is the full lifecycle of the deployed locker: collection triggers, `_handleFees` batching, FeeLocker claims, and reward-slot administration.
- [CONTRACT-DEPLOYMENT-WORKFLOW](./CONTRACT-DEPLOYMENT-WORKFLOW.md) covers the split LpLocker deploy (`FOUNDRY_PROFILE=lplocker`, 200 optimizer runs) and enabling a locker per hook.
- [LAUNCH-FORM-DEPLOYMENT-CONFIG](./LAUNCH-FORM-DEPLOYMENT-CONFIG.md) covers how `/launch` encodes `lockerData` as `LpFeeConversionInfo` and builds `lockerConfig`.
- [FOUNDRY-REGRESSION-SUITE](./FOUNDRY-REGRESSION-SUITE.md) covers `BonkerLegacyErc20Safety.t.sol`, where both lockers are tested against non-standard ERC20s.
- [MEV-MODULE-LIFECYCLE](./MEV-MODULE-LIFECYCLE.md) explains the launch MEV window that the deployed locker's `_mevModuleOperating()` check defers to.
- [OWNER-ADMIN-PERMISSION-MODEL](./OWNER-ADMIN-PERMISSION-MODEL.md) distinguishes per-slot LP reward admins from factory owner/admin roles.
