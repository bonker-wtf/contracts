Fee flow end-to-end traces a single swap's fees from the Uniswap v4 hook to their two terminal payees — the token creator and the factory owner — across the hook, LP locker, FeeLocker, and factory protocol-fee paths; read this when you need the continuous money-flow narrative that no single subsystem doc provides, before changing anything that moves fees between those four contracts.

This page is a synthesis walkthrough, not a re-derivation. It answers natural-language queries such as "where does the money go after a swap", "trace one WETH of LP fee end to end", "who calls `storeFees` and who calls `claim`", "why does the creator claim from FeeLocker but the team claim from the factory", "what is the order of `_hookFeeClaim` vs `_lpLockerFeeClaim`", and "the two fee destinations of a Bonker pool". It deliberately stops at each subsystem boundary and links to the doc that owns the details: [HOOK-FEE-ACCOUNTING](./HOOK-FEE-ACCOUNTING.md), [LP-LOCKER-FEE-CONVERSION-LIFECYCLE](./LP-LOCKER-FEE-CONVERSION-LIFECYCLE.md), [FEE-ESCROW-AND-CLAIM](./FEE-ESCROW-AND-CLAIM.md), and [NATIVE-ETH-WETH-CURRENCY-MODEL](./NATIVE-ETH-WETH-CURRENCY-MODEL.md).

## Why this doc exists

Bonker's entire reason for forking Clanker is the money flow: we own the factory, so the protocol fee goes to us. That value proposition is implemented as **two unrelated settlement mechanisms that both originate at the same swap** but terminate at different payees through different contracts and different claim functions.

Each existing fee doc owns one slice and explicitly disclaims the others. HOOK-FEE-ACCOUNTING says LP reward splitting and factory ownership are "covered by nearby docs". LP-LOCKER-FEE-CONVERSION-LIFECYCLE says "It focuses on LP fees, not factory protocol fees". FEE-ESCROW-AND-CLAIM says Bonker has "two unrelated fee-settlement mechanisms that are easy to confuse". The result: a maintainer who asks "follow the money from one swap" has to read four pages and stitch the handoffs themselves.

This page is that stitch. It walks one swap forward, naming the exact function that hands off to the next subsystem, and stops where the owning doc takes over.

## Key files

| Anchor | Role in the flow |
| --- | --- |
| `src/hooks/BonkerHookV2.sol:446` | `_beforeSwap` calls `_hookFeeClaim` first. |
| `src/hooks/BonkerHookV2.sol:449` | `_beforeSwap` then calls `_lpLockerFeeClaim`. |
| `src/hooks/BonkerHookV2.sol:415` | `_hookFeeClaim` burns the accrued ERC-6909 fee and `take`s it to the factory. |
| `src/hooks/BonkerHookV2.sol:431` | `poolManager.take(feeCurrency, factory, fee)` — protocol fee lands in the factory. |
| `src/hooks/BonkerHookV2.sol:400` | `_lpLockerFeeClaim` triggers `collectRewardsWithoutUnlock` on the locker. |
| `src/lp-lockers/BonkerLpLockerFeeConversion.sol:318` | `collectRewardsWithoutUnlock` entrypoint the hook calls each swap. |
| `src/lp-lockers/BonkerLpLockerFeeConversion.sol:423` | `_handleFees` optionally swaps then deposits to FeeLocker. |
| `src/lp-lockers/BonkerLpLockerFeeConversion.sol:478` | `feeLocker.storeFees(...)` — creator/reward-recipient escrow deposit. |
| `src/BonkerFeeLocker.sol:26` | `storeFees` credits the per-recipient `feesToClaim` ledger. |
| `src/BonkerFeeLocker.sol:46` | `claim(feeOwner, token)` — the creator pulls escrowed LP fees. |
| `src/Bonker.sol:81` | `claimTeamFees(token)` — the owner sweeps protocol fees to `teamFeeRecipient`. |

## The two destinations

Every Bonker pool produces two fee streams from the same trades. Keeping them straight is the whole point:

- **LP fee → token creator.** The LP position's accrued fees are collected by the locker, optionally converted to each recipient's preferred token, and deposited into `BonkerFeeLocker` under the reward recipient's address. The creator later calls `BonkerFeeLocker.claim(owner, WETH)`.
- **Protocol fee → factory owner/admin.** A derived slice of each swap is `take`n directly into the `Bonker` factory contract's own balance. The owner or admin later calls `Bonker.claimTeamFees(WETH)`, which sweeps that balance to `teamFeeRecipient`.

These never touch the same ledger. The FeeLocker is a per-recipient escrow map; the protocol fee is a raw ERC-20 balance sitting on the factory. They are claimed by different callers through different functions. Confusing them is the single most common fee-path mistake, which is why FEE-ESCROW-AND-CLAIM exists as the disambiguation map.

Both streams are denominated in `WETH`, not native ETH — see [NATIVE-ETH-WETH-CURRENCY-MODEL](./NATIVE-ETH-WETH-CURRENCY-MODEL.md). Native ETH only appears at user entry/exit points; everything internal to the fee flow is the ERC-20.

## Stage 1 — the swap accrues fees in the hook

A swap on a Bonker pool enters `BonkerHookV2._beforeSwap`. Before the swap's own delta math runs, the hook performs two claims in a fixed order (`src/hooks/BonkerHookV2.sol:446` then `:449`):

1. `_hookFeeClaim(poolKey)` — settle the **previous** swap's accrued protocol fee.
2. `_lpLockerFeeClaim(poolKey)` — trigger the LP locker to collect **its** accrued position fees.

The ordering is deliberate and load-bearing: the protocol fee for a swap is taken on the *next* swap, because the v4 hook accumulates it as an ERC-6909 claim balance (`poolManager.mint`) during the prior swap and only realizes it as a real ERC-20 transfer here. HOOK-FEE-ACCOUNTING owns the "why are protocol fees claimed on the next swap" detail and the `beforeSwapReturnDelta`/`afterSwapReturnDelta` sign math. This doc only needs the handoff: after stage 1, the protocol fee has left the pool and the locker has been told to collect.

For the deeper flash-accounting mechanics of `mint`/`burn`/`take`/`settle`, see [V4-FLASH-ACCOUNTING-SETTLEMENT](./V4-FLASH-ACCOUNTING-SETTLEMENT.md).

## Stage 2a — protocol fee lands in the factory

`_hookFeeClaim` (`src/hooks/BonkerHookV2.sol:415`) reads the hook's own accrued ERC-6909 balance for the fee currency, and if non-zero:

```text
poolManager.burn(address(this), feeCurrency.toId(), fee)   // give up the claim token
poolManager.take(feeCurrency, factory, fee)                // pull real WETH to the factory
emit ClaimProtocolFees(feeCurrency, fee)
```

The recipient of the `take` is `factory` — the `Bonker` contract address. The protocol fee is now plain WETH sitting on the factory's balance. There is no per-token, per-creator, or per-pool accounting here: all pools' protocol fees pile into one factory balance per token. This is the divergence point from Clanker — Clanker's factory owner is Clanker; ours is us, so this WETH is ours.

The protocol-fee size is derived from the active LP fee via `PROTOCOL_FEE_NUMERATOR` (200_000, identical to Clanker) in `_setProtocolFee` (`src/hooks/BonkerHookV2.sol:100`). The numerator is unchanged from upstream on purpose; only the factory *owner* differs. HOOK-FEE-ACCOUNTING owns the numerator math and the scaled-delta accounting.

## Stage 2b — LP fees flow to the locker, then FeeLocker

In parallel, `_lpLockerFeeClaim` (`src/hooks/BonkerHookV2.sol:400`) skips silently if `locker[poolId]` is zero; otherwise it calls `collectRewardsWithoutUnlock(token)` on the configured locker (`src/lp-lockers/BonkerLpLockerFeeConversion.sol:318`).

The locker brings the position's accrued fees into the contract (`_bringFeesIntoContract`), then routes each side through `_handleFees` (`src/lp-lockers/BonkerLpLockerFeeConversion.sol:423`). Per reward recipient, `_handleFees` consults `feePreferences[token]` and may swap the fee into the recipient's preferred side (`FeeIn.Paired`, `FeeIn.Bonker`, or `FeeIn.Both`) before depositing. The final deposit is `feeLocker.storeFees(recipient, rewardToken, amount)` (`src/lp-lockers/BonkerLpLockerFeeConversion.sol:478`).

LP-LOCKER-FEE-CONVERSION-LIFECYCLE owns the swap-preference logic, BPS splitting, the `TokenRewardAdded` event, and why LP rewards skip while a MEV module is active. This doc only needs the handoff: LP fees end up in FeeLocker, credited to each reward recipient.

## Stage 3 — escrow ledger and the two claims

`BonkerFeeLocker.storeFees` (`src/BonkerFeeLocker.sol:26`) is allowlist-gated: only `allowedDepositors[msg.sender]` (the lockers and MEV modules wired in deploy scripts) may deposit. It credits `feesToClaim[feeOwner][token]` using balance-delta accounting so fee-on-transfer tokens are counted correctly. The reward recipient later pulls their balance with `claim(feeOwner, token)` (`src/BonkerFeeLocker.sol:46`), which zeroes the ledger entry and `safeTransfer`s the WETH out.

The protocol fee has **no** such ledger. It sits on the factory until the owner or admin calls `Bonker.claimTeamFees(token)` (`src/Bonker.sol:81`), which reverts if `teamFeeRecipient` is unset, otherwise transfers the factory's entire balance of that token to `teamFeeRecipient` and emits `ClaimTeamFees`. There is no per-recipient bookkeeping because there is exactly one recipient: the team.

So the two terminal claims are asymmetric by design:

```text
creator:  BonkerFeeLocker.claim(creatorAddr, WETH)   -> per-recipient escrow debit
owner:    Bonker.claimTeamFees(WETH)                 -> whole factory balance sweep
```

## End-to-end map

```text
                    swap on Bonker pool
                            │
                  BonkerHookV2._beforeSwap
                   ┌────────┴─────────┐
        _hookFeeClaim            _lpLockerFeeClaim
            │                          │
   poolManager.take            locker.collectRewardsWithoutUnlock
   (feeCurrency, factory)             │
            │                    _handleFees (optional swap)
            │                          │
   WETH on factory balance     feeLocker.storeFees(recipient, token, amt)
            │                          │
   Bonker.claimTeamFees        BonkerFeeLocker.claim(feeOwner, token)
            │                          │
       teamFeeRecipient           token creator / reward recipient
```

For our own launches the creator share and the protocol fee both come back to us, summing to ~100%. For third-party launches on our factory, we keep only the protocol fee while their reward recipients claim the LP fees — that is the rationale recorded in the project `CLAUDE.md` Fee Flow table.

## Invariants and edge cases

The protocol fee is realized one swap late. A pool that trades once and never again leaves its last protocol fee accrued as an ERC-6909 claim balance that is only `take`n on the next swap that never comes. The same is true of the LP locker claim trigger — both are swap-driven, not time-driven. There is no keeper sweeping idle pools.

`claimTeamFees` sweeps the **entire** factory balance for a token, across all pools. It is not scoped per pool or per launch. Anyone auditing "how much did pool X earn the team" cannot read it from the factory balance after a claim — only `ClaimProtocolFees` per-swap events distinguish pools.

`storeFees` callers must be allowlisted. If a redeploy introduces a new locker or MEV module that deposits fees, it must be added via `addDepositor` in the deploy script or `storeFees` reverts `Unauthorized` and the LP fee path silently strips revenue. This is a known redeploy footgun — see the depositor-allowlisting note in [FEE-ESCROW-AND-CLAIM](./FEE-ESCROW-AND-CLAIM.md) and the deploy-script wiring in [CONTRACT-DEPLOYMENT-WORKFLOW](./CONTRACT-DEPLOYMENT-WORKFLOW.md).

Both terminal claims pay WETH. A creator or team expecting native ETH must unwrap themselves; nothing in the fee flow unwraps on their behalf. See [NATIVE-ETH-WETH-CURRENCY-MODEL](./NATIVE-ETH-WETH-CURRENCY-MODEL.md).

MEV modules can also deposit auction proceeds into FeeLocker as a depositor, so a reward recipient's claimable balance may include auction WETH, not only swap LP fees — see [MEV-MODULE-LIFECYCLE](./MEV-MODULE-LIFECYCLE.md) and [SNIPER-AUCTION-BID-MECHANICS](./SNIPER-AUCTION-BID-MECHANICS.md).

## Cross-references

- [HOOK-FEE-ACCOUNTING](./HOOK-FEE-ACCOUNTING.md) — how the hook chooses the LP fee, derives the protocol fee, and orders the `_beforeSwap` claims.
- [LP-LOCKER-FEE-CONVERSION-LIFECYCLE](./LP-LOCKER-FEE-CONVERSION-LIFECYCLE.md) — fee collection, swap preferences, BPS splitting, and FeeLocker deposit.
- [FEE-ESCROW-AND-CLAIM](./FEE-ESCROW-AND-CLAIM.md) — the FeeLocker escrow ledger versus the factory protocol-fee sweep, side by side.
- [NATIVE-ETH-WETH-CURRENCY-MODEL](./NATIVE-ETH-WETH-CURRENCY-MODEL.md) — why every internal fee balance is WETH.
- [V4-FLASH-ACCOUNTING-SETTLEMENT](./V4-FLASH-ACCOUNTING-SETTLEMENT.md) — the `mint`/`burn`/`take`/`settle` mechanics behind stage 1.
- [OWNER-ADMIN-PERMISSION-MODEL](./OWNER-ADMIN-PERMISSION-MODEL.md) — who may call `claimTeamFees` and set `teamFeeRecipient`.
- [CONTRACT-DEPLOYMENT-WORKFLOW](./CONTRACT-DEPLOYMENT-WORKFLOW.md) — depositor allowlisting and fee-recipient wiring at deploy time.
