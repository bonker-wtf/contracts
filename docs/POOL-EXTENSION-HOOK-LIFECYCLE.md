Pool extension hook lifecycle explains how `BonkerHookV2` decodes `poolData.extension`, gates hook-side extensions through `BonkerPoolExtensionAllowlist`, runs pre-locker and post-locker setup, and calls extension `afterSwap`; read this before changing `src/hooks/BonkerHookV2.sol`, `src/hooks/interfaces/IBonkerHookV2PoolExtension.sol`, `client/components/LaunchPage.jsx` pool data encoding, or pool-extension allowlisting.

This page covers natural-language queries such as `PoolInitializationData`, `PoolSwapData`, `poolExtension`, `poolExtensionSetup`, `PoolExtensionRegistered`, `PoolExtensionNotEnabled`, `OnlyFactoryPoolsCanHaveExtensions`, `initializePreLockerSetup`, `initializePostLockerSetup`, `afterSwap`, `poolExtensionSwapData`, and "why did a pool extension failure not revert the swap". It focuses on hook-side pool extensions. Factory launch extensions, such as vault, airdrop, dev buy, and presale, use `IBonker.ExtensionConfig[]` and are covered separately.

## Why It Exists

Bonker has two similarly named extension systems that run at different boundaries.

Factory extensions are launch-time token allocation modules. They reserve a percentage of the 100B token supply, optionally receive ETH, and run from `Bonker.deployToken()` through `IBonkerExtension.receiveTokens()`.

Pool extensions are hook-side modules. They are configured inside `IBonker.PoolConfig.poolData`, stored per Uniswap v4 pool by `BonkerHookV2`, and can observe or react to swaps after the pool has finished factory deployment.

That second boundary exists because some behaviors need access to hook state and swap deltas rather than token supply. The hook knows the `PoolKey`, token ordering, locker address, swap params, and `BalanceDelta`. A factory extension does not receive normal swap callbacks after launch.

The sharp edge is naming. `PoolInitializationData.extension` is not an `IBonker.ExtensionConfig`. It has no `extensionBps`, no `msgValue`, and no factory `enabledExtensions` check. It is decoded by the hook, gated by `BonkerPoolExtensionAllowlist`, and must implement `IBonkerHookV2PoolExtension`.

Current public launches set this address to `address(0)` in the React launch form. The lifecycle still matters because the V2 hooks and deployment scripts include the allowlist and interface, and a future non-zero pool extension must fit this exact sequencing.

## Key Files

| File | Why it matters |
| --- | --- |
| `src/interfaces/IBonker.sol:19` | Defines `PoolConfig.poolData`, the only factory field that carries hook-side pool extension configuration. |
| `src/hooks/interfaces/IBonkerHookV2.sol:22` | Defines `PoolInitializationData` as `(address extension, bytes extensionData, bytes feeData)`. |
| `src/hooks/interfaces/IBonkerHookV2.sol:28` | Defines `PoolSwapData` as `(bytes mevModuleSwapData, bytes poolExtensionSwapData)`. |
| `src/hooks/interfaces/IBonkerHookV2PoolExtension.sol:11` | Defines the required pool extension interface. |
| `src/hooks/BonkerPoolExtensionAllowlist.sol:8` | Stores the hook-side allowlist controlled by `OwnerAdmins`. |
| `src/hooks/BonkerPoolExtensionAllowlist.sol:16` | `setPoolExtension()` enables or disables a pool extension address. |
| `src/hooks/BonkerHookV2.sol:57` | Stores the factory address and immutable `poolExtensionAllowlist`. |
| `src/hooks/BonkerHookV2.sol:70` | Stores per-pool `poolExtension` and `poolExtensionSetup`. |
| `src/hooks/BonkerHookV2.sol:110` | `_initializePoolExtensionData()` checks the allowlist and runs pre-locker setup. |
| `src/hooks/BonkerHookV2.sol:129` | `initializePool()` is the factory-only pool creation path that supports pool extensions. |
| `src/hooks/BonkerHookV2.sol:164` | `initializePoolOpen()` rejects non-factory pools that try to configure pool extensions. |
| `src/hooks/BonkerHookV2.sol:236` | `_initializePool()` decodes `PoolInitializationData` from `poolData`. |
| `src/hooks/BonkerHookV2.sol:255` | `initializeMevModule()` also runs pool extension post-locker setup. |
| `src/hooks/BonkerHookV2.sol:351` | `_runPoolExtension()` conditionally runs the extension after swaps. |
| `src/hooks/BonkerHookV2.sol:386` | `_runPoolExtensionHelper()` performs the external `afterSwap()` call through `address(this)`. |
| `src/hooks/BonkerHookV2.sol:500` | `_afterSwap()` calls `_runPoolExtension()` after protocol fee delta handling. |
| `client/components/LaunchPage.jsx:314` | The public launch form currently encodes `extension: ZERO_ADDR` in `poolData`. |
| `script/DeployStep1.s.sol:25` | Deploys `BonkerPoolExtensionAllowlist` before hooks. |
| `script/DeployStep2.s.sol:51` | Passes the allowlist address into V2 hook constructors. |

## How It Works

### Configuration Shape

Pool extension configuration lives inside the hook's `PoolInitializationData`.

```text
IBonker.PoolConfig.poolData
└── abi.encode(PoolInitializationData)
    ├── extension: address
    ├── extensionData: bytes
    └── feeData: bytes
```

`feeData` is passed to the concrete hook implementation through `_initializeFeeData()`. `extension` and `extensionData` are consumed by `BonkerHookV2._initializePoolExtensionData()`.

Swap-time extension data uses a separate wrapper:

```text
hookData / swapData
└── abi.encode(PoolSwapData)
    ├── mevModuleSwapData: bytes
    └── poolExtensionSwapData: bytes
```

If no swap data is provided, the hook builds empty byte arrays for both fields. This lets ordinary swaps work without extension-specific hook data, while still allowing routers or helper contracts to pass extension payloads when needed.

### Deployment Wiring

`DeployStep1.s.sol` deploys `BonkerPoolExtensionAllowlist` as a core contract. `DeployStep2.s.sol` passes that allowlist address into both V2 hook constructors.

The allowlist is not the factory's `enabledExtensions` mapping. It is a separate `OwnerAdmins`-controlled contract with `setPoolExtension(address extension, bool enabled)`. `BonkerHookV2` reads it directly through `poolExtensionAllowlist.enabledExtensions(extension)`.

That separation is intentional. Factory extensions and pool extensions have different interfaces and different risk surfaces. A contract that is safe to receive reserved launch tokens is not automatically safe to run inside hook swap flow.

### Factory Pool Initialization

Factory-created pools enter through `Bonker.deployToken()`.

```text
Bonker.deployToken()
  ├── deploy token
  ├── prepare factory extensions
  ├── _initializePool()
  │   └── hook.initializePool(..., poolConfig.poolData)
  ├── _initializeLiquidity()
  ├── _triggerExtensions()
  └── _initializeMevModule()
      └── hook.initializeMevModule(poolKey, mevModuleData)
```

Inside `BonkerHookV2.initializePool()`, the hook calls `_initializePool()`, stores the locker and MEV module for the pool, and emits `PoolExtensionRegistered(poolId, poolExtension[poolId])`.

`_initializePool()` creates the Uniswap v4 `PoolKey`, initializes the pool price, stores `bonkerIsToken0`, stores `poolCreationTimestamp`, decodes `PoolInitializationData`, initializes fee data, then initializes pool extension data.

If `PoolInitializationData.extension == address(0)`, no pool extension is stored and the later extension steps are skipped.

### Pre-Locker Setup

When `PoolInitializationData.extension` is non-zero, `_initializePoolExtensionData()` first checks `poolExtensionAllowlist.enabledExtensions(extension)`.

If the address is not enabled, the entire launch reverts with `PoolExtensionNotEnabled()`. This happens before liquidity placement, factory extension triggering, and MEV module initialization.

If the address is enabled, the hook calls:

```solidity
IBonkerHookV2PoolExtension(extension).initializePreLockerSetup(
    poolKey,
    bonkerIsToken0[poolKey.toId()],
    poolExtensionData
);
```

Then it stores `poolExtension[poolId] = extension`.

At this point the locker address has not yet been written to hook storage, and the locker has not placed liquidity. Pre-locker setup should treat `extensionData` as launch configuration and avoid assuming the locker or LP position exists.

### Post-Locker Setup

Post-locker setup runs inside `BonkerHookV2.initializeMevModule()`, which the factory calls only after `_initializeLiquidity()` and `_triggerExtensions()`.

If a pool extension is stored, the hook calls:

```solidity
IBonkerHookV2PoolExtension(poolExtension[poolId]).initializePostLockerSetup(
    poolKey,
    locker[poolId],
    bonkerIsToken0[poolId]
);
```

Then the hook sets `poolExtensionSetup[poolId] = true`.

This second phase is where a pool extension can validate or store settings that depend on the final locker address. It also marks the extension eligible for post-swap callbacks. Without this flag, `_runPoolExtension()` will not call `afterSwap()`.

The method name can be misleading because it lives in `initializeMevModule()`. The call is not MEV-specific. It is placed there because the factory already needs a final post-liquidity hook call before enabling the MEV module, and extensions may need the pool to be fully deployed before they inspect settings.

### Open Pool Initialization

`initializePoolOpen()` lets non-factory tokens create pools with Bonker hooks, but those pools do not get locker auto-claim, MEV module functionality, or pool extensions.

The function still calls `_initializePool()`, which means malformed `poolData` can decode and even set a pool extension. Immediately after initialization, `initializePoolOpen()` checks `poolExtension[poolId]` and reverts with `OnlyFactoryPoolsCanHaveExtensions()` if an extension was set.

That guard matters because open pools have no factory post-locker step. There is no `_initializeLiquidity()` and no `initializeMevModule()` call to run `initializePostLockerSetup()` or set `poolExtensionSetup`.

### Swap Callback

Pool extensions run after the hook has handled protocol fee deltas in `_afterSwap()`.

```text
_afterSwap()
  ├── compute protocol-fee deltas
  ├── mint protocol-fee claim balance when needed
  ├── normalize deltas for beforeSwap fee cases
  └── _runPoolExtension(poolKey, swapParams, sender, delta, swapData)
```

`_runPoolExtension()` requires all of these conditions:

- `poolExtension[poolId] != address(0)`;
- `poolExtensionSetup[poolId] == true`;
- `sender != locker[poolId]`.

The locker sender check avoids invoking extension code during locker-managed swaps. The source comment calls out the concern: locker swaps could run extension code before the user's swap is complete.

When the extension is eligible, the hook decodes `PoolSwapData` and passes only `poolExtensionSwapData` to the extension. MEV module swap data and pool extension swap data share the same outer payload but are routed to different contracts.

### Failure Isolation

The hook does not call the extension directly from `_runPoolExtension()`. It calls `this._runPoolExtensionHelper(...)` inside a `try/catch`.

`_runPoolExtensionHelper()` requires `msg.sender == address(this)` and then calls the stored extension's `afterSwap()`. If the extension succeeds, the hook emits `PoolExtensionSuccess(poolId)`. If the extension reverts, the hook catches the failure and emits `PoolExtensionFailed(poolId, swapParams)`.

That means a post-swap pool extension failure does not revert the user's swap. Initialization failures still revert launch, because pre-locker and post-locker setup are direct external calls in the deployment path.

## Invariants And Edge Cases

### Pool Data Field Order Is Positional

`PoolInitializationData` is decoded as `(address extension, bytes extensionData, bytes feeData)`. The order must match across Solidity scripts, frontend encoding, and any helper script that builds `poolData`.

Encoding `(feeData, extension, extensionData)` or any other order will make Solidity read bytes as the wrong field. This class of bug is especially hard to see from TypeScript because `bytes` can hold arbitrary ABI payloads until the hook decodes them.

### Address Zero Means No Pool Extension

The normal no-extension value is `extension: address(0)` with `extensionData: ""` or `0x`. The current public launch form encodes exactly that shape.

Do not substitute a factory extension address here. Vault, airdrop, dev buy, and presale contracts implement factory extension interfaces, not `IBonkerHookV2PoolExtension`.

### Allowlisting Is Hook-Side

Pool extension approval uses `BonkerPoolExtensionAllowlist.setPoolExtension()`. Factory `setExtension()` does not affect hook-side pool extension eligibility.

A non-zero extension address that is not enabled in the pool extension allowlist reverts during pool initialization with `PoolExtensionNotEnabled()`.

### Post-Swap Failures Are Non-Fatal

`afterSwap()` failures are caught and converted into `PoolExtensionFailed`. This protects swaps from extension bugs after launch, but it also means off-chain monitoring must watch events if extension execution is expected to be reliable.

By contrast, `initializePreLockerSetup()` and `initializePostLockerSetup()` are not wrapped in `try/catch`. A revert there fails the deployment transaction.

### Post-Locker Setup Gates Swap Execution

`poolExtension[poolId]` alone is not enough. `_runPoolExtension()` also requires `poolExtensionSetup[poolId]`.

If a future custom factory path initialized a pool but skipped `initializeMevModule()`, the extension would be registered but would not run after swaps. The current `Bonker.deployToken()` path calls `_initializeMevModule()` after liquidity placement and factory extensions.

### Open Pools Cannot Use Pool Extensions

Non-factory initialization is deliberately limited. `initializePoolOpen()` reverts if `_initializePool()` leaves a non-zero `poolExtension[poolId]`.

This keeps open pools from entering a half-initialized state with no locker address, no post-locker setup, and no factory-controlled deployment sequence.

### Locker Swaps Skip Pool Extensions

`_runPoolExtension()` skips when `sender == locker[poolId]`. This protects locker fee-conversion or liquidity-management swaps from recursively triggering extension behavior while the locker is doing internal work.

If an extension is meant to observe every economic swap, remember that locker-originated swaps are intentionally excluded.

### Interface Support Is Declared But Not Enforced By The Allowlist

`IBonkerHookV2PoolExtension` includes `supportsInterface(bytes4)`, but `BonkerPoolExtensionAllowlist.setPoolExtension()` only writes the mapping and emits `SetPoolExtension`.

The practical enforcement point is the hook's external calls. If the allowlisted address does not implement the expected functions, pool initialization or swap callbacks will fail according to where the missing function is reached.

## Cross-References

- [Factory Extension Lifecycle](./FACTORY-EXTENSION-LIFECYCLE.md) explains the separate `IBonker.ExtensionConfig[]` launch-time extension system.
- [Launch Form Deployment Config](./LAUNCH-FORM-DEPLOYMENT-CONFIG.md) explains how `/launch` builds `PoolConfig.poolData` and currently sets no pool extension.
- [MEV Module Lifecycle](./MEV-MODULE-LIFECYCLE.md) explains the sibling hook-side module path that shares `PoolSwapData`.
- [LP Locker Fee Conversion Lifecycle](./LP-LOCKER-FEE-CONVERSION-LIFECYCLE.md) explains why locker-originated swaps and `collectRewardsWithoutUnlock()` matter to hook execution.
- [Contract Deployment Workflow](./CONTRACT-DEPLOYMENT-WORKFLOW.md) explains why the pool extension allowlist address is deployed before hook construction.
- [Owner/Admin Permission Model](./OWNER-ADMIN-PERMISSION-MODEL.md) explains the `OwnerAdmins` authority model used by `BonkerPoolExtensionAllowlist`.
