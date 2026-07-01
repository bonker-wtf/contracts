Hook version comparison explains why the repo keeps both legacy `BonkerHook` contracts and live `BonkerHookV2` contracts, what changed at the hook boundary, and when to read this before touching hook constructors, pool data encoding, MEV fee modules, or deployment scripts.

This page answers natural-language queries such as `BonkerHook` vs `BonkerHookV2`, `BonkerHookDynamicFee` vs `BonkerHookDynamicFeeV2`, `BonkerHookStaticFee` vs `BonkerHookStaticFeeV2`, `PoolInitializationData`, `PoolSwapData`, `mevModuleSetFee`, `MAX_MEV_LP_FEE`, `PoolExtensionRegistered`, "which hook version is deployed", and "why do V2 hooks take a pool extension allowlist". It does not re-explain protocol-fee math or pool-extension setup in full; those flows have their own docs.

## Why It Exists

Bonker has two generations of Uniswap v4 hook contracts in `src/hooks/`.

The legacy family is `BonkerHook`, `BonkerHookDynamicFee`, and `BonkerHookStaticFee`. Those contracts implement the base factory/open-pool hook lifecycle, LP locker auto-claim, protocol-fee collection, and MEV module callback support. They are still compiled source, but the live deployment scripts do not construct them.

The live family is `BonkerHookV2`, `BonkerHookDynamicFeeV2`, and `BonkerHookStaticFeeV2`. V2 keeps the same public `IBonkerHook` pool initialization boundary, but changes the internal pool data envelope, exposes extra state publicly, supports hook-side pool extensions, and gives MEV modules a controlled way to raise LP fees during the launch window.

That coexistence is useful but easy to misread. A maintainer searching for `_beforeSwap`, `_initializePoolData`, `initializeMevModule`, or `simulateSwap` will find both generations with similar code. The question is not "which one is newer by filename"; the deployment scripts and deployed Base addresses make V2 the production path.

## Key Files

| File | Why it matters |
| --- | --- |
| `src/hooks/BonkerHook.sol:39` | Defines the legacy abstract hook base as `BaseHook`, `Ownable`, and `IBonkerHook`. |
| `src/hooks/BonkerHook.sol:43` | Legacy `MAX_LP_FEE` is 30%, with no separate MEV fee ceiling. |
| `src/hooks/BonkerHook.sol:90` | Legacy `_initializePoolData()` passes all `poolData` directly to the concrete fee hook. |
| `src/hooks/BonkerHook.sol:216` | Legacy `initializeMevModule()` only initializes and enables the assigned module. |
| `src/hooks/BonkerHook.sol:227` | Legacy `_runMevModule()` passes raw swap data directly to the module. |
| `src/hooks/BonkerHook.sol:428` | Legacy ERC-165 support reports only `IBonkerHook`. |
| `src/hooks/BonkerHookV2.sol:42` | Defines the live abstract hook base as `BaseHook` and `IBonkerHookV2`. |
| `src/hooks/BonkerHookV2.sol:47` | Adds V2 identity constants `BONKER_VERSION` and `BONKER_PROTOCOL_ID`. |
| `src/hooks/BonkerHookV2.sol:50` | Lowers normal `MAX_LP_FEE` to 10% and adds `MAX_MEV_LP_FEE` at 80%. |
| `src/hooks/BonkerHookV2.sol:57` | Stores the factory, pool extension allowlist, and WETH immutables. |
| `src/hooks/BonkerHookV2.sol:70` | Stores per-pool `poolExtension` and `poolExtensionSetup` state. |
| `src/hooks/BonkerHookV2.sol:110` | Checks the allowlist and runs pool extension pre-locker setup. |
| `src/hooks/BonkerHookV2.sol:185` | Rejects non-factory open pools that try to configure a pool extension. |
| `src/hooks/BonkerHookV2.sol:236` | Decodes `PoolInitializationData` before forwarding `feeData` to the concrete hook. |
| `src/hooks/BonkerHookV2.sol:255` | Initializes the MEV module and runs pool extension post-locker setup. |
| `src/hooks/BonkerHookV2.sol:276` | Centralizes the "is this MEV module still operational" check. |
| `src/hooks/BonkerHookV2.sol:291` | Lets the assigned MEV module raise the current LP fee within the V2 cap. |
| `src/hooks/BonkerHookV2.sol:321` | Decodes `PoolSwapData` before calling a MEV module. |
| `src/hooks/BonkerHookV2.sol:351` | Runs hook-side pool extensions after swaps when setup is complete. |
| `src/hooks/BonkerHookV2.sol:500` | Adjusts the post-swap delta that is passed to pool extensions. |
| `src/hooks/BonkerHookV2.sol:601` | Reports both `IBonkerHook` and `IBonkerHookV2` ERC-165 support. |
| `src/hooks/interfaces/IBonkerHookV2.sol:22` | Defines `PoolInitializationData` as `(extension, extensionData, feeData)`. |
| `src/hooks/interfaces/IBonkerHookV2.sol:28` | Defines `PoolSwapData` as `(mevModuleSwapData, poolExtensionSwapData)`. |
| `src/hooks/BonkerHookDynamicFee.sol:50` | Legacy dynamic hook decodes `poolData` directly as `PoolDynamicConfigVars`. |
| `src/hooks/BonkerHookDynamicFeeV2.sol:42` | V2 dynamic hook decodes only `feeData` as `PoolDynamicConfigVars`. |
| `src/hooks/BonkerHookStaticFee.sol:19` | Legacy static hook decodes `poolData` directly as `PoolStaticConfigVars`. |
| `src/hooks/BonkerHookStaticFeeV2.sol:22` | V2 static hook decodes only `feeData` as `PoolStaticConfigVars`. |
| `script/DeployStep2.s.sol:50` | Deploys `BonkerHookDynamicFeeV2` with a mined salt. |
| `script/DeployStep2.s.sol:56` | Deploys `BonkerHookStaticFeeV2` with a mined salt. |
| `script/RedeployStep2.s.sol:45` | Redeploy path also constructs only V2 hook contracts. |

## How It Works

### Shared Hook Boundary

Both generations implement `IBonkerHook`, so the factory can call the same high-level functions:

```text
Bonker.deployToken
  -> IBonkerHook.initializePool(...)
  -> place initial liquidity through the locker
  -> trigger launch extensions
  -> IBonkerHook.initializeMevModule(...)
```

Both generations also force pool creation through `initializePool()` or `initializePoolOpen()`, store whether the launched token is token0, collect pending protocol fees from PoolManager accounting, ask the configured locker to collect LP rewards, and use `beforeSwap` plus `afterSwap` return deltas to take the protocol fee in the paired token.

The concrete fee hooks have the same user-facing fee models across generations:

- Dynamic fee hooks store `PoolDynamicConfigVars`, estimate tick movement through `simulateSwap()`, and choose an LP fee between `baseFee` and `maxLpFee`.
- Static fee hooks store a `bonkerFee` and `pairedFee`, then choose between them from swap direction.

The difference is the envelope around those fee models.

### Legacy Pool Data

The legacy hook base treats `poolData` as fee data.

```text
BonkerHook._initializePool(...)
  -> _initializePoolData(poolKey, poolData)

BonkerHookDynamicFee._initializePoolData(...)
  -> abi.decode(poolData, (PoolDynamicConfigVars))

BonkerHookStaticFee._initializePoolData(...)
  -> abi.decode(poolData, (PoolStaticConfigVars))
```

That means a caller using a legacy dynamic hook must encode the dynamic fee struct directly. A caller using a legacy static hook must encode the static fee struct directly. There is no hook-side pool extension field and no separate MEV/pool-extension swap data envelope.

### V2 Pool Data

The V2 hook base treats `poolData` as a hook-level envelope.

```text
BonkerHookV2._initializePool(...)
  -> abi.decode(poolData, (PoolInitializationData))
  -> _initializeFeeData(poolKey, poolInitializationData.feeData)
  -> _initializePoolExtensionData(
       poolKey,
       poolInitializationData.extension,
       poolInitializationData.extensionData
     )

BonkerHookDynamicFeeV2._initializeFeeData(...)
  -> abi.decode(feeData, (PoolDynamicConfigVars))

BonkerHookStaticFeeV2._initializeFeeData(...)
  -> abi.decode(feeData, (PoolStaticConfigVars))
```

The field order matters: `PoolInitializationData` is `(address extension, bytes extensionData, bytes feeData)`. Any frontend, script, or helper that sends `(feeData, extension, extensionData)` will produce a valid ABI blob with the wrong meaning and can make Solidity read fee bytes as an extension address.

This is why V2 hook constructor calls need `POOL_EXTENSION_ALLOWLIST`. Even launches that set `extension = address(0)` must deploy hooks with the allowlist address because the V2 base owns the hook-side extension gate.

### MEV Behavior

Legacy hooks can call an assigned MEV module before swaps, but the module cannot change the pool LP fee through a hook-owned API. `_runMevModule()` checks whether `mevModuleEnabled` is true and whether the pool is younger than `MAX_MEV_MODULE_DELAY`, then forwards raw swap data to `IBonkerMevModule.beforeSwap()`.

V2 adds `mevModuleOperational()` and `mevModuleSetFee()`. The operational helper both checks and expires a module once the hook-level two-minute limit is reached. `mevModuleSetFee()` lets only the pool's assigned module raise the active LP fee, only while operational, only above the current LP fee, and only up to `MAX_MEV_LP_FEE`.

That API is the reason `BonkerSniperAuctionV2` and `BonkerMevDescendingFees` require a `BonkerHookV2`-compatible hook. They are fee-setting modules, not just block/time gates.

### Swap Data

Legacy hooks pass the hook callback `bytes` straight to the MEV module. A sniper auction helper can ABI-encode whatever the module expects, and the hook does not split the payload.

V2 decodes the callback `bytes` as `PoolSwapData` when present:

```text
PoolSwapData
  mevModuleSwapData       -> forwarded to IBonkerMevModule.beforeSwap()
  poolExtensionSwapData   -> forwarded to IBonkerHookV2PoolExtension.afterSwap()
```

If the callback data is empty, V2 uses empty bytes for both fields. If it is non-empty, it must decode as `PoolSwapData`. This is a wire-format change from legacy hooks and is separate from the pool initialization data change.

### Pool Extensions

Legacy hooks have no pool extension state.

V2 hooks support hook-side pool extensions in two deployment phases. During pool initialization, `_initializePoolExtensionData()` checks `poolExtensionAllowlist.enabledExtensions(extension)`, calls `initializePreLockerSetup()`, and stores the extension address. After initial liquidity and factory launch extensions finish, `initializeMevModule()` calls `initializePostLockerSetup()` and marks `poolExtensionSetup` true.

After swaps, V2 passes a corrected user-facing `BalanceDelta` to the pool extension. The extra delta normalization in `_afterSwap()` exists because protocol fees can be taken in either callback depending on swap shape, but pool extensions need a consistent post-swap view.

### Deployment Choice

Production deployment scripts construct V2 hooks.

`DeployStep2.s.sol` imports `BonkerHookDynamicFeeV2` and `BonkerHookStaticFeeV2`, deploys each with mined salts, passes `(poolManager, factory, allowlist, weth)`, and enables both addresses on the factory. `RedeployStep2.s.sol` follows the same V2-only pattern for partial redeploys.

The deployed Base mainnet addresses in `CLAUDE.md` therefore refer to V2 hooks:

- DynamicHook: `0x963E91A45148b39737b9DF10c5b897B55cA9e8cC`
- StaticHook: `0xC9156C1868E122eF5b3e6ed946e1E88ff7da68Cc`

Legacy hook contracts remain useful as source context for the original design, but they are not the live Bonker factory hook path.

## Invariants and Edge Cases

V2 `poolData` must always be encoded as `PoolInitializationData`. The concrete static or dynamic fee struct belongs inside `feeData`, not at the top level.

Legacy hook `poolData` must not be sent to a V2 hook unchanged. `BonkerHookV2._initializePool()` will try to decode it as `(extension, extensionData, feeData)`.

V2 swap callback data must be empty or decode as `PoolSwapData`. Passing legacy raw auction data directly to a V2 hook makes the hook decode the wrong outer shape before the auction module sees anything.

V2 normal LP fees are capped by `MAX_LP_FEE` at 10%. MEV launch fees are separately capped by `MAX_MEV_LP_FEE` at 80% and can only be applied through `mevModuleSetFee()`.

MEV modules that call `mevModuleSetFee()` require V2 behavior. A legacy hook may support the base `IBonkerHook` interface, but it does not expose `IBonkerHookV2` or the fee-setting API.

Pool extensions are factory-pool-only. `initializePoolOpen()` still decodes V2 `PoolInitializationData`, but it reverts if the decoded extension is non-zero because open pools have no post-locker setup step.

V2 hooks report both `IBonkerHook` and `IBonkerHookV2` support. Code that only needs factory pool initialization can use the base interface; code that needs `PoolInitializationData`, `PoolSwapData`, `mevModuleSetFee()`, or V2 caps must check the V2 interface.

The public mappings in V2 are intentional. `bonkerIsToken0` and `locker` are internal in the legacy base but public in V2, which makes external inspection and helper contracts easier without changing the core accounting flow.

Do not mix the hook version with the fee model. "Dynamic" versus "static" decides how the normal LP fee is calculated. "V1" versus "V2" decides the hook envelope, pool extension lifecycle, MEV fee-setting capability, and deployment constructor shape.

## Cross-References

- [HOOK-FEE-ACCOUNTING](./HOOK-FEE-ACCOUNTING.md) explains the shared swap-time accounting path and protocol-fee deltas.
- [POOL-EXTENSION-HOOK-LIFECYCLE](./POOL-EXTENSION-HOOK-LIFECYCLE.md) explains V2 pool extension setup and `afterSwap` behavior in detail.
- [MEV-MODULE-LIFECYCLE](./MEV-MODULE-LIFECYCLE.md) explains how `BonkerSniperAuctionV2` and descending-fee modules use `mevModuleSetFee()`.
- [LAUNCH-FORM-DEPLOYMENT-CONFIG](./LAUNCH-FORM-DEPLOYMENT-CONFIG.md) explains how the React launch form encodes V2 `PoolInitializationData`.
- [CONTRACT-DEPLOYMENT-WORKFLOW](./CONTRACT-DEPLOYMENT-WORKFLOW.md) explains hook salt mining and why V2 hooks are deployed with the pool extension allowlist.
- [OWNER-ADMIN-PERMISSION-MODEL](./OWNER-ADMIN-PERMISSION-MODEL.md) explains the factory allowlists that decide which deployed hook addresses launches can use.
