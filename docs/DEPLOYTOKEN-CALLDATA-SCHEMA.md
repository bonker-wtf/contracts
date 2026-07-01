Canonical `deployToken` calldata schema — the full positional tuple tree of `IBonker.DeploymentConfig` plus every opaque inner `bytes` payload (`poolData`, `feeData`, `mevModuleData`, `lockerData`, per-extension `extensionData`); read this before changing any ABI literal that encodes a `deployToken` call.

This page is the single reference for how a `deployToken(DeploymentConfig)` call is laid out on the wire. ABI encoding is **positional**: the field names in a viem/forge ABI literal are documentation only — the encoder serializes fields in declaration order. If a caller's tuple order drifts from the Solidity struct in `src/interfaces/IBonker.sol`, the contract reads the wrong bytes for each slot and reverts (or silently mis-deploys). The same `DeploymentConfig` shape is hand-written in at least four places — `client/components/LaunchPage.jsx`, `scripts/deploy-token.mjs`, `client/public/skill.md`, and the Solidity source — so this doc exists to keep them aligned and to explain the nested `bytes` blobs that the top-level ABI cannot describe. Query terms: `DeploymentConfig`, `PoolInitializationData`, `tickIfToken0IsBonker`, `feeData`, `mevModuleData`, `lockerData`, `feePreference`, `extensionData`, `ExtensionMsgValueMismatch`, "deployToken tuple order", "poolData field order".

## Why It Exists

The factory's `deployToken` takes one giant nested struct. Solidity's `abi.decode` is positional and so is every encoder that builds the calldata. There is no field-name negotiation at the ABI boundary — a `tuple` with the right component *types* in the wrong *order* still encodes and still decodes, just into the wrong fields.

This already caused a production revert (recorded in `CLAUDE.md` → "Bugs Fixed"): `custom-factory.mjs` encoded `poolData` as `(feeData, extension, extensionData)` while the Solidity `PoolInitializationData` struct is `(extension, extensionData, feeData)`. The encoder read the `feeData` bytes as the `extension` address and the call reverted.

Because the schema is duplicated by hand across the client, the standalone scripts, and the public `skill.md` artifact, any field added or reordered in `IBonker.sol` must be mirrored everywhere in the same change. This doc is the checklist for that.

## Key Files

| File | Why it matters |
| --- | --- |
| `src/interfaces/IBonker.sol:47` | `DeploymentConfig` — the authoritative top-level struct order. |
| `src/interfaces/IBonker.sol:8` | `TokenConfig` struct (8 fields). |
| `src/interfaces/IBonker.sol:19` | `PoolConfig` struct (carries opaque `poolData`). |
| `src/interfaces/IBonker.sol:27` | `LockerConfig` struct (reward + position arrays + opaque `lockerData`). |
| `src/interfaces/IBonker.sol:40` | `ExtensionConfig` struct (per-extension supply + ETH + opaque `extensionData`). |
| `src/interfaces/IBonker.sol:55` | `MevModuleConfig` struct (module + opaque `mevModuleData`). |
| `src/interfaces/IBonker.sol:140` | `deployToken(DeploymentConfig)` entrypoint. |
| `src/Bonker.sol:166` | `deployToken` implementation — supply mint, extensions, locker, MEV init. |
| `src/Bonker.sol:297` | `_prepareExtensions()` validates `MAX_EXTENSIONS`, `MAX_EXTENSION_BPS`, and `ExtensionMsgValueMismatch`. |
| `src/hooks/interfaces/IBonkerHookV2.sol:22` | `PoolInitializationData` — the struct that `poolData` decodes into. |
| `src/hooks/BonkerHookV2.sol:237` | `abi.decode(poolData, (PoolInitializationData))` at pool init. |
| `src/hooks/interfaces/IBonkerHookDynamicFee.sol:24` | `PoolDynamicConfigVars` — dynamic-hook `feeData` layout. |
| `src/hooks/interfaces/IBonkerHookStaticFee.sol:12` | `PoolStaticConfigVars` — static-hook `feeData` layout. |
| `client/components/LaunchPage.jsx:14` | Client ABI literal + `buildDeploymentConfig()` encoding (lines 301–450). |
| `scripts/deploy-token.mjs:34` | Standalone-script ABI literal (must match the client's byte-for-byte). |
| `client/public/skill.md:25` | Public integration ABI for external builders. |

## Top-Level Tuple Order

`DeploymentConfig` has exactly five fields, in this order (`src/interfaces/IBonker.sol:47`):

```text
DeploymentConfig
├─ tokenConfig      TokenConfig
├─ poolConfig       PoolConfig
├─ lockerConfig     LockerConfig
├─ mevModuleConfig  MevModuleConfig
└─ extensionConfigs ExtensionConfig[]
```

Note that `mevModuleConfig` comes **before** `extensionConfigs` in the wire order even though `MevModuleConfig` is *declared* after `ExtensionConfig` in the source file. The struct member order inside `DeploymentConfig` (line 47) is authoritative, not the order the helper structs happen to appear in the file.

### tokenConfig (`TokenConfig`, 8 fields)

`tokenAdmin (address)`, `name (string)`, `symbol (string)`, `salt (bytes32)`, `image (string)`, `metadata (string)`, `context (string)`, `originatingChainId (uint256)`.

`salt` is combined with `tokenAdmin` inside the deployer (`keccak256(abi.encode(tokenAdmin, salt))`) to derive the CREATE2 token address — see [ORIGINATING-CHAIN-TOKEN-DEPLOYMENT](./ORIGINATING-CHAIN-TOKEN-DEPLOYMENT.md). `metadata` is a JSON string the client assembles from description/socials. On Base, `originatingChainId` is the Base chain id; a non-originating chain would call `deployTokenZeroSupply` instead.

### poolConfig (`PoolConfig`, 5 fields)

`hook (address)`, `pairedToken (address)`, `tickIfToken0IsBonker (int24)`, `tickSpacing (int24)`, `poolData (bytes)`.

`hook` selects the dynamic or static hook address. `pairedToken` is WETH for normal launches. `tickIfToken0IsBonker` is the initial price tick (the client uses `-230400`). `poolData` is opaque here and decoded by the hook — see below.

### lockerConfig (`LockerConfig`, 8 fields)

`locker (address)`, `rewardAdmins (address[])`, `rewardRecipients (address[])`, `rewardBps (uint16[])`, `tickLower (int24[])`, `tickUpper (int24[])`, `positionBps (uint16[])`, `lockerData (bytes)`.

The three reward arrays are parallel (one entry per recipient); `rewardBps` must sum to 10000. The three tick/position arrays are parallel (one entry per liquidity position); the client ships a fixed 5-position curve. `lockerData` is opaque — decoded by the LP locker. See [LP-LOCKER-FEE-CONVERSION-LIFECYCLE](./LP-LOCKER-FEE-CONVERSION-LIFECYCLE.md).

### mevModuleConfig (`MevModuleConfig`, 2 fields)

`mevModule (address)`, `mevModuleData (bytes)`. `mevModuleData` is opaque and forwarded to the module's `initialize()` after liquidity is placed. See [MEV-MODULE-LIFECYCLE](./MEV-MODULE-LIFECYCLE.md).

### extensionConfigs (`ExtensionConfig[]`, 4 fields each)

`extension (address)`, `msgValue (uint256)`, `extensionBps (uint16)`, `extensionData (bytes)`.

`extensionBps` reserves a share of the 100B supply for the extension; `msgValue` is the ETH forwarded to it. See [FACTORY-EXTENSION-LIFECYCLE](./FACTORY-EXTENSION-LIFECYCLE.md). The per-extension `extensionData` blobs are opaque and decoded by each extension contract.

## Opaque `bytes` Payloads

The top-level ABI describes the five `bytes` fields above only as `bytes`. Their real structure is a second layer of ABI encoding the factory never sees — the hook, locker, MEV module, and each extension `abi.decode` them. Getting the *outer* tuple order right is not enough; each inner blob has its own positional schema.

### poolData → `PoolInitializationData`

Decoded at `src/hooks/BonkerHookV2.sol:237` into `PoolInitializationData` (`src/hooks/interfaces/IBonkerHookV2.sol:22`):

```text
(address extension, bytes extensionData, bytes feeData)
```

This is the exact order that the historical `custom-factory.mjs` bug got wrong. The client encodes it at `client/components/LaunchPage.jsx:319` with `extension = address(0)` and `extensionData = 0x` for a normal launch (no pool extension), leaving only `feeData` populated.

### feeData (inside `poolData`)

`feeData` is itself opaque and decoded by the chosen hook's `_initializeFeeData`:

- **Dynamic hook** (`src/hooks/BonkerHookDynamicFeeV2.sol:42`) decodes `PoolDynamicConfigVars` (`src/hooks/interfaces/IBonkerHookDynamicFee.sol:24`): `baseFee (uint24)`, `maxLpFee (uint24)`, `referenceTickFilterPeriod (uint256)`, `resetPeriod (uint256)`, `resetTickFilter (int24)`, `feeControlNumerator (uint256)`, `decayFilterBps (uint24)`. The client packs these as `uint24, uint24, uint256, uint256, int24, uint256, uint24` at `client/components/LaunchPage.jsx:310`.
- **Static hook** (`src/hooks/BonkerHookStaticFeeV2.sol:22`) decodes `PoolStaticConfigVars` (`src/hooks/interfaces/IBonkerHookStaticFee.sol:12`): `bonkerFee (uint24)`, `pairedFee (uint24)`. The client packs `uint24, uint24` at `LaunchPage.jsx:316`.

See [HOOK-FEE-ACCOUNTING](./HOOK-FEE-ACCOUNTING.md) for what these fields control at swap time.

### mevModuleData

For the production sniper auction the client encodes `(uint24 startingFee, uint24 endingFee, uint256 secondsToDecay)` at `client/components/LaunchPage.jsx:324`. The module decodes its own `FeeConfig`/init shape — see [MEV-MODULE-LIFECYCLE](./MEV-MODULE-LIFECYCLE.md).

### lockerData

Decoded by `BonkerLpLockerFeeConversion` (`src/lp-lockers/BonkerLpLockerFeeConversion.sol:110`) as `(uint8[] feePreference)` — one `FeeIn` enum entry per reward recipient, choosing whether that recipient's fees are converted to the paired token or kept as the Bonker token. The client builds it at `client/components/LaunchPage.jsx:330`.

### extensionData (per extension)

Each extension defines its own tuple. As encoded by the client:

- **Vault** (`LaunchPage.jsx:352`): `(address admin, uint256 lockupDuration, uint256 vestingDuration)`. See [VAULT-EXTENSION-LIFECYCLE](./VAULT-EXTENSION-LIFECYCLE.md).
- **Airdrop** (`LaunchPage.jsx:372`): `(address admin, bytes32 merkleRoot, uint256 lockupDuration, uint256 vestingDuration)`. See [AIRDROP-EXTENSION-LIFECYCLE](./AIRDROP-EXTENSION-LIFECYCLE.md).
- **DevBuy** (`LaunchPage.jsx:393`): `(PoolKey pairedTokenPoolKey, uint128 pairedTokenAmountOutMinimum, address recipient)`, where `pairedTokenPoolKey` is `(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks)` — zeroed for WETH-paired pools. See [DEV-BUY-EXTENSION-ROUTING](./DEV-BUY-EXTENSION-ROUTING.md).

## Invariants and Edge Cases

- **Positional order is the contract.** Adding or reordering any field in `IBonker.sol` (or in an inner struct) is a breaking change to every hand-written ABI literal: `LaunchPage.jsx`, `deploy-token.mjs`, and `skill.md` must change in the same commit. Field names in the ABI literals do not protect you.
- **`mevModuleConfig` precedes `extensionConfigs`** on the wire (`IBonker.sol:47`), regardless of the helper structs' declaration order in the file.
- **DevBuy must be last** in `extensionConfigs` — it buys after the pool is live (`LaunchPage.jsx:389`).
- **ETH must reconcile.** The transaction `value` must equal the sum of all `extensionConfigs[i].msgValue`, or the factory reverts `ExtensionMsgValueMismatch` (`src/Bonker.sol:329`). The client accumulates `totalMsgValue` for exactly this reason (`LaunchPage.jsx:417`).
- **Supply caps.** At most `MAX_EXTENSIONS` (10) extensions, and the summed `extensionBps` must not exceed `MAX_EXTENSION_BPS` (9000) — `src/Bonker.sol:42`.
- **Inner blobs are decoded by different contracts.** A correct outer tuple with a malformed `poolData`/`feeData`/`extensionData` still reverts, just deeper in the call (at hook init or extension `receiveTokens`), so errors can surface far from the field that is actually wrong.

## Cross-References

- [LAUNCH-FORM-DEPLOYMENT-CONFIG](./LAUNCH-FORM-DEPLOYMENT-CONFIG.md) — how `/launch` inputs map to this schema and the simulate-then-submit flow.
- [PUBLIC-DEPLOYTOKEN-INTEGRATION-GUIDE](./PUBLIC-DEPLOYTOKEN-INTEGRATION-GUIDE.md) — the public `skill.md` artifact that mirrors this schema for external callers.
- [FACTORY-EXTENSION-LIFECYCLE](./FACTORY-EXTENSION-LIFECYCLE.md) — `ExtensionConfig` supply reservation and ETH forwarding.
- [HOOK-FEE-ACCOUNTING](./HOOK-FEE-ACCOUNTING.md) and [HOOK-VERSION-COMPARISON](./HOOK-VERSION-COMPARISON.md) — `feeData` consumers and pool-data differences.
- [MEV-MODULE-LIFECYCLE](./MEV-MODULE-LIFECYCLE.md) — `mevModuleData` consumer.
- [LP-LOCKER-FEE-CONVERSION-LIFECYCLE](./LP-LOCKER-FEE-CONVERSION-LIFECYCLE.md) — `lockerData` `feePreference` consumer.
- [ORIGINATING-CHAIN-TOKEN-DEPLOYMENT](./ORIGINATING-CHAIN-TOKEN-DEPLOYMENT.md) — `salt`/`originatingChainId` semantics and `deployTokenZeroSupply`.
- [STANDALONE-MAINNET-SCRIPT-WORKFLOW](./STANDALONE-MAINNET-SCRIPT-WORKFLOW.md) — `scripts/deploy-token.mjs` consumer of this ABI.
