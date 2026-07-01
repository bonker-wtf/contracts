MEV module lifecycle explains how Bonker configures launch-time sniper protection, block/time locks, and descending LP fees through `IBonkerMevModule`; read this before changing `src/mev-modules/`, `src/hooks/BonkerHookV2.sol`, `client/components/LaunchPage.jsx`, factory MEV allowlisting, or token-detail MEV display.

This page covers natural-language queries such as `BonkerSniperAuctionV2`, `BonkerMevDescendingFees`, `BonkerMevBlockDelay`, `BonkerMevTimeDelay`, `initializeMevModule`, `mevModuleOperational`, `mevModuleSetFee`, `NotAuctionBlock`, `GasSignalNegative`, `FeeConfig`, `MAX_MEV_MODULE_DELAY`, `MAX_MEV_LP_FEE`, `mevModuleSwapData`, and "sniper tax duration". The important distinction is that Bonker has several MEV module contracts, but the production launch form currently wires every normal launch to the deployed `MEV_MODULE` address, which is `BonkerSniperAuctionV2` on Base.

## Why It Exists

Fresh meme-token pools are exposed to the first few blocks of trading. Bonker uses MEV modules as optional per-pool launch guards that the hook can consult before every swap while the guard is still live.

The module boundary keeps the hook generic. `BonkerHookV2` owns the Uniswap v4 callbacks, dynamic LP fee updates, protocol fee accounting, LP locker claims, and pool extension calls. MEV contracts own launch-specific policies such as "block swaps until this block", "run an auction on this exact block", or "charge a high fee that decays over time".

This separation lets the factory enable or disable modules without redeploying the hooks. It also means every module must obey the same handshake:

- the factory must allowlist the module;
- the hook stores the module address for the pool during pool initialization;
- the factory later calls `initializeMevModule()` after liquidity and extensions are ready;
- the hook calls `beforeSwap()` while the module is operational;
- the module either reverts, updates the LP fee, collects auction payment, or returns `true` to disable itself.

The subtle part is timing. The hook hard-stops MEV modules after `MAX_MEV_MODULE_DELAY`, currently two minutes. Some modules also disable themselves earlier. Launch UI, deployment scripts, and module init data must stay inside that hook-level ceiling.

## Key Files

| File | Why it matters |
| --- | --- |
| `src/interfaces/IBonkerMevModule.sol:9` | Defines the shared MEV module interface, errors, `initialize()`, and `beforeSwap()`. |
| `src/Bonker.sol:127` | `setMevModule()` allowlists modules after checking `supportsInterface()`. |
| `src/Bonker.sol:204` | `deployToken()` initializes the MEV module after liquidity and extensions. |
| `src/Bonker.sol:240` | `_initializeMevModule()` rejects disabled modules and forwards init data through the hook. |
| `src/hooks/BonkerHookV2.sol:64` | Hook-level two-minute `MAX_MEV_MODULE_DELAY` ceiling for all modules. |
| `src/hooks/BonkerHookV2.sol:255` | `initializeMevModule()` calls the module, runs post-locker pool extension setup, then enables the module. |
| `src/hooks/BonkerHookV2.sol:276` | `mevModuleOperational()` disables expired modules before swaps or liquidity adds continue. |
| `src/hooks/BonkerHookV2.sol:291` | `mevModuleSetFee()` lets only the assigned module raise the active LP fee within the MEV cap. |
| `src/hooks/BonkerHookV2.sol:321` | `_runMevModule()` decodes `PoolSwapData`, calls `beforeSwap()`, and stores module disablement. |
| `src/hooks/BonkerHookV2.sol:436` | `_beforeSwap()` runs base fee logic, fee claims, then the MEV module before protocol fee deltas. |
| `src/hooks/BonkerHookV2.sol:587` | `_beforeAddLiquidity()` blocks new liquidity while the MEV module is operational. |
| `src/mev-modules/BonkerSniperAuctionV2.sol:42` | Production sniper auction module with post-auction descending fee behavior. |
| `src/mev-modules/BonkerSniperAuctionV2.sol:220` | `initialize()` seeds auction round state and decodes `FeeConfig`. |
| `src/mev-modules/BonkerSniperAuctionV2.sol:426` | `beforeSwap()` runs auction rounds or post-auction fee decay. |
| `src/mev-modules/BonkerMevDescendingFees.sol:51` | Standalone descending-fee module initialization and validation. |
| `src/mev-modules/BonkerMevBlockDelay.sol:35` | Block-delay module records the unlock block. |
| `src/mev-modules/BonkerMevTimeDelay.sol:39` | Time-delay module records the unlock timestamp. |
| `client/config/contracts.js:6` | Frontend `MEV_MODULE` points at the deployed Base module address. |
| `client/components/LaunchPage.jsx:326` | Launch form ABI-encodes sniper `FeeConfig` as `mevModuleData`. |
| `client/components/LaunchPage.jsx:449` | Launch form includes `mevModuleConfig` in `DeploymentConfig`. |
| `server/tokens.js:193` | Token detail enrichment marks MEV protection present from the indexed module address. |
| `script/DeployStep2.s.sol:60` | Deployment script creates `BonkerSniperAuctionV2`. |
| `script/DeployStep2.s.sol:78` | Deployment script enables the deployed module on the factory. |

## How It Works

### Shared Module Interface

Every module implements `IBonkerMevModule`. The hook expects two functions:

```text
initialize(poolKey, mevModuleInitData)
beforeSwap(poolKey, swapParams, bonkerIsToken0, mevModuleSwapData) -> disableMevModule
```

`initialize()` receives pool-scoped data during token deployment. `beforeSwap()` receives swap-scoped data during each guarded swap. Returning `true` tells the hook to turn the module off for that pool.

The interface also defines `OnlyHook` and `PoolLocked`. Individual modules add their own errors and events.

### Factory Allowlisting

The factory does not accept arbitrary module addresses in a user-supplied `DeploymentConfig`. `Bonker.setMevModule()` first calls `supportsInterface(type(IBonkerMevModule).interfaceId)`, then writes `enabledMevModules[mevModule]`.

During `deployToken()`, the factory stores the module address in the hook while it initializes the pool, then calls `_initializeMevModule()` after liquidity and extensions are complete. If the module is not enabled, deployment reverts with `MevModuleNotEnabled()`.

That order matters. Extensions can take pool actions during deployment, and the MEV module should not block those setup actions before the launch is fully configured.

### Hook Runtime

`BonkerHookV2.initializePool()` stores `mevModule[poolId]` while the factory creates the pool. `initializeMevModule()` later calls the selected module's `initialize()`, runs post-locker setup for any pool extension, then sets `mevModuleEnabled[poolId] = true`.

On each swap, `_beforeSwap()` does this sequence:

```text
normal hook fee logic
hook fee claim
LP locker fee claim
MEV module run
protocol fee delta accounting
```

`_runMevModule()` first checks `mevModuleOperational(poolId)`. That helper returns false if the module is already disabled or if two minutes have passed since pool creation. If swap data exists, the hook decodes it as `PoolSwapData` and forwards only `poolSwapData.mevModuleSwapData` to the module.

Modules that want to raise LP fees call back into `mevModuleSetFee(poolKey, fee)`. The hook rejects unauthorized callers, ignores inactive modules, ignores fees above `MAX_MEV_LP_FEE`, and ignores fees that are not higher than the current pool fee. Accepted fees are applied through `updateDynamicLPFee()`, and the hook recalculates the protocol fee from the imposed LP fee.

While a module is operational, `_beforeAddLiquidity()` reverts with `MevModuleEnabled()`. Launch protection is therefore a swap-only window; new liquidity cannot be added until the module turns off or expires.

### Production Launch Path

The frontend currently imports `MEV_MODULE` from `client/config/contracts.js`, and that address is included in every launch form deployment config.

`LaunchPage.jsx` encodes the module init data as:

```text
(uint24 startingFee, uint24 endingFee, uint256 secondsToDecay)
```

Those fields match `IBonkerMevDescendingFees.FeeConfig`. For the deployed `BonkerSniperAuctionV2`, the fee config is used after the auction phase ends. The UI passes:

- `startingFee = 666777`;
- `endingFee = 41673`;
- `secondsToDecay = sniperTaxDuration`.

The current launch form does not expose module selection. It assumes the configured Base `MEV_MODULE` understands the descending-fee `FeeConfig` shape.

### Token Detail Display

The `TokenCreated` event includes the selected `mevModule` address. The token poller stores that address, and `enrichWithOnChainData()` reports `features.mevModule.enabled = true` when the row has a non-zero module.

The detail page uses this as a protection signal and links to the module address. It does not currently decode per-pool auction round state, fee decay state, unlock timestamps, or module-expired status.

## Module Types

### BonkerSniperAuctionV2

`BonkerSniperAuctionV2` is the production module deployed by `DeployStep2.s.sol`. It combines a block-timed auction phase with a post-auction descending LP fee phase.

Initialization sets:

- `gasPeg[poolId]` using `_getBaseAuctionGasPeg(blocksBetweenDeploymentAndFirstAuction)`;
- `nextAuctionBlock[poolId]` to the deployment block plus the first-auction delay;
- `round[poolId]` to `1`;
- `feeConfig[poolId]` from ABI-decoded `FeeConfig`;
- `auctionTimestamp[poolId]` to the current timestamp.

The auction phase only settles on the exact `nextAuctionBlock`. A swap before that block reverts `NotAuctionBlock()`. A swap after that block emits `AuctionExpired`, starts decay from the previous auction timestamp, and lets decay logic handle the swap.

On the exact auction block, the module decodes `auctionData` as an address, calculates `tx.gasprice - gasPeg[poolId]`, reverts `GasSignalNegative()` if the signal is below the peg, pulls WETH from the payee, splits payment between the factory and LP reward recipients, sets the LP fee to the configured starting fee, and schedules the next round.

When `round > maxRounds`, the module emits `AuctionEnded` and starts the fee decay phase. During decay, `_handleFeeDecay()` calls `mevModuleSetFee()` with the parabolic fee curve until `secondsToDecay` completes, then returns `true` so the hook disables the module.

### BonkerSniperAuctionV0

`BonkerSniperAuctionV0` is the older auction-only module. It has the same gas peg, exact-block auction, WETH payment, and reward split model, but no descending fee phase after the final round.

If a swap misses the target auction block, V0 emits `AuctionExpired` and returns `true`, so the hook disables the module immediately. If all rounds complete, `_prepareNextRound()` emits `AuctionEnded` and also returns `true`.

V0 is useful as the simpler reference for the auction behavior inside V2. It is not the module address used by the current launch form.

### BonkerMevDescendingFees

`BonkerMevDescendingFees` is the standalone fee-decay module. It has no auction payment, no WETH transfer, and no exact-block bidding.

Its `initialize()` decodes `FeeConfig`, validates that `secondsToDecay` and `startingFee` are non-zero, validates `startingFee >= endingFee`, requires a `BonkerHookV2`, and checks the hook's `MAX_MEV_LP_FEE` and `MAX_MEV_MODULE_DELAY`.

`beforeSwap()` reverts during the exact deployment second with `SameSecondAsDeployment()`. After that it calculates a parabolic decay from `startingFee` down toward `endingFee`, calls `mevModuleSetFee()`, and returns false until the decay period is over. At the end it emits `DecayPeriodOver` and returns true.

This module is the cleanest reference for the fee curve that V2 reuses after auction rounds finish.

### BonkerMevBlockDelay

`BonkerMevBlockDelay` is a minimal lock. Its constructor sets a global `blockDelay`, and `initialize()` stores `block.number + blockDelay` per pool.

`beforeSwap()` reverts `PoolLocked()` until the current block reaches the stored unlock block. Once unlocked, it returns true, so the hook disables the module on the first allowed swap.

This module does not change fees or collect payments. It is useful when the desired behavior is simply "no swaps for N blocks".

### BonkerMevTimeDelay

`BonkerMevTimeDelay` is the timestamp version of block delay. Its constructor rejects zero delay with `TimeDelayMustBeGreaterThanZero()`, and `initialize()` stores `block.timestamp + timeDelay` per pool.

`beforeSwap()` reverts `PoolLocked()` until the stored unlock timestamp has passed, then returns true.

Like block delay, it does not update fees or collect payments. It depends on timestamps rather than block numbers, so it is easier to reason about user-facing duration but still bounded by the hook's two-minute operational window.

## Invariants And Edge Cases

### Authorization

Modules are pool-local helpers, not public control planes. Every module in this tree uses `onlyHook(poolKey)` and rejects calls where `msg.sender != address(poolKey.hooks)`.

`mevModuleSetFee()` has the opposite authorization check: only the module assigned to that pool can ask the hook to update the LP fee. This prevents one module from raising fees on another pool.

### Hook Version Expectations

Fee-setting modules require `BonkerHookV2` behavior because they call `mevModuleSetFee()` and validate `MAX_MEV_LP_FEE` and `MAX_MEV_MODULE_DELAY`. `BonkerMevDescendingFees` and `BonkerSniperAuctionV2` explicitly check the hook's interface during initialization.

Delay-only modules use only the base `IBonkerMevModule` interface and do not need hook fee callbacks.

### Time Ceiling

`BonkerHookV2` disables any module once `block.timestamp >= poolCreationTimestamp[poolId] + MAX_MEV_MODULE_DELAY`. A module can have its own shorter duration, but it cannot reliably operate beyond this hook-level ceiling.

For descending-fee configs, `secondsToDecay` must fit under the hook's maximum. For sniper auction V2, auction rounds plus decay behavior must be understood inside the same operational ceiling, even though auction scheduling is block-based.

### Fee Cap

The hook caps MEV-set LP fees at `MAX_MEV_LP_FEE`, currently `800_000` in Uniswap's million-denominator fee units. If a module calls `mevModuleSetFee()` with a larger fee, the hook silently ignores it.

The hook also ignores fee updates that are less than or equal to the current LP fee. MEV modules can raise the active fee during protection, but they cannot lower the pool below the hook's normal fee behavior.

### Auction Swap Data

Auction modules expect `mevModuleSwapData` to ABI-decode as an address that funds the WETH payment. If routers or custom swap callers do not provide the expected data, the module call will fail during decode or payment.

The launch form configures module initialization data, not swap-time auction data. Swap integrations that want to win auction rounds must supply the correct swap data when interacting with the pool.

### Payment Splitting

Auction payments are WETH transfers, separate from normal LP swap fees. `BonkerSniperAuctionV0` and `BonkerSniperAuctionV2` split each winning payment into:

- `FACTORY_PORTION = 2000` BPS sent to the factory;
- the remaining WETH distributed through `FeeLocker.storeFees()` according to the LP locker reward recipients.

This is related to the normal factory protocol fee flow, but it is not claimed through the same hook fee accounting path.

### UI Meaning

The token detail page treats any non-zero indexed MEV module address as "MEV protection enabled". That is accurate for launch configuration, but it is not a live status indicator after the two-minute operational window ends.

Do not use the current token detail boolean as proof that a module is still active on-chain. Read the hook's `mevModuleEnabled(poolId)` or module-specific state if live status matters.

## Cross-References

- [CONTRACT-DEPLOYMENT-WORKFLOW](./CONTRACT-DEPLOYMENT-WORKFLOW.md) for deployment order, hook salts, and factory module enablement.
- [LAUNCH-FORM-DEPLOYMENT-CONFIG](./LAUNCH-FORM-DEPLOYMENT-CONFIG.md) for how `/launch` builds `DeploymentConfig`, including `mevModuleConfig`.
- [ADMIN-OPERATIONS-CONSOLE](./ADMIN-OPERATIONS-CONSOLE.md) for the admin UI that inspects and toggles factory module registration.
- [TOKEN-DETAIL-ENRICHMENT](./TOKEN-DETAIL-ENRICHMENT.md) for how indexed module addresses become token detail `features.mevModule`.
- [SQLITE-PERSISTENCE-LIFECYCLE](./SQLITE-PERSISTENCE-LIFECYCLE.md) for how `mev_module` is stored from `TokenCreated` rows.
