Factory extension lifecycle explains how `IBonker.ExtensionConfig[]` reserves token supply, forwards launch ETH, and calls enabled extension contracts during `Bonker.deployToken`; read this before changing `src/Bonker.sol`, `src/interfaces/IBonkerExtension.sol`, `src/extensions/`, launch extension encoding, admin presale extension ordering, or extension deployment scripts.

This page covers natural-language queries such as `ExtensionConfig`, `_prepareExtensions`, `_triggerExtensions`, `receiveTokens`, `ExtensionMsgValueMismatch`, `MaxExtensionBpsExceeded`, `ExtensionNotEnabled`, `InvalidMsgValue`, `DevBuy extension must be last`, `PresaleNotLastExtension`, `AirdropV2ExtensionData`, `VaultExtensionData`, and "why did extension supply reduce pool liquidity". It focuses on the common factory-to-extension contract boundary. The individual UI flows, presale buyer lifecycle, and token-detail enrichment are covered in nearby docs.

## Why It Exists

Bonker extensions are launch-time modules that receive either a reserved slice of the 100B token supply, an attached ETH payment, or both fields checked as zero/non-zero by the extension itself. The factory owns the sequencing: deploy token, split supply, initialize pool liquidity, then trigger each extension while the factory still holds the reserved tokens.

That solves three problems at once.

First, the factory can make extension use permissioned. `setExtension()` checks `IBonkerExtension` support and stores the enabled address before launches can reference it.

Second, the supply math stays centralized. `Bonker` caps the extension count and total BPS, subtracts the aggregate extension supply from pool liquidity, and then computes each extension's token amount from the original `TOKEN_SUPPLY`.

Third, each extension remains specialized. Vault and airdrop extensions store allocation schedules and pull tokens from the factory. DevBuy consumes ETH and expects zero reserved token supply. Presale stores a sale-specific token allocation after the sale is successful and deployment is expected.

The sharp edge is that all of this happens inside one deployment transaction. A bad extension address, disabled module, BPS overflow, wrong `msg.value`, wrong extension ordering, invalid lockup, or failed token transfer reverts the whole launch.

## Key Files

| File | Why it matters |
| --- | --- |
| `src/interfaces/IBonker.sol:40` | Defines `ExtensionConfig { extension, msgValue, extensionBps, extensionData }`, the tuple encoded by clients and scripts. |
| `src/interfaces/IBonker.sol:93` | Declares factory-level extension validation errors: `ExtensionMsgValueMismatch`, `MaxExtensionsExceeded`, and `MaxExtensionBpsExceeded`. |
| `src/interfaces/IBonkerExtension.sol:9` | Defines the common `IBonkerExtension` interface every factory extension must support. |
| `src/interfaces/IBonkerExtension.sol:14` | Defines `receiveTokens(deploymentConfig, poolKey, token, extensionSupply, extensionIndex)`. |
| `src/Bonker.sol:40` | Defines `TOKEN_SUPPLY`, `BPS`, `MAX_EXTENSIONS`, and `MAX_EXTENSION_BPS`. |
| `src/Bonker.sol:141` | `setExtension()` enables or disables extension contracts after checking ERC-165 support. |
| `src/Bonker.sol:166` | `deployToken()` runs the launch sequence that prepares and triggers extensions. |
| `src/Bonker.sol:297` | `_prepareExtensions()` validates extension count, aggregate BPS, aggregate ETH, and enabled addresses. |
| `src/Bonker.sol:345` | `_triggerExtensions()` approves and calls each extension with its per-extension token supply and ETH value. |
| `src/extensions/BonkerVault.sol:41` | Vault `receiveTokens()` decodes `VaultExtensionData`, enforces zero ETH, and pulls the reserved token allocation. |
| `src/extensions/BonkerAirdropV2.sol:38` | Airdrop V2 `receiveTokens()` decodes admin/root/vesting data and stores the airdrop allocation. |
| `src/extensions/BonkerUniv4EthDevBuy.sol:60` | DevBuy `receiveTokens()` consumes ETH, requires zero reserved supply, performs the buy, and sends tokens to the recipient. |
| `src/extensions/BonkerPresaleEthToCreator.sol:158` | `startPresale()` validates that the presale extension is the last entry before storing the deployment config. |
| `src/extensions/BonkerPresaleEthToCreator.sol:559` | Presale `receiveTokens()` records the deployed token and moves a successful presale to `Claimable`. |
| `client/components/LaunchPage.jsx:341` | Public launch form builds vault, airdrop, and dev-buy `extensionConfigs`. |
| `client/components/admin/presaleConfig.js:106` | Admin presale form builds optional airdrop plus presale extension configs, with presale last. |
| `script/DeployExtensions.s.sol:24` | Deploys Vault and DevBuy, then enables both extensions on the factory. |
| `script/DeployPresale.s.sol:23` | Deploys Presale and Allowlist, then enables the presale extension on the factory. |

## How It Works

### Extension config shape

Every launch carries a `DeploymentConfig`, and the extension part is an ordered array of `IBonker.ExtensionConfig`.

Each item has four fields:

- `extension`: the contract address to call.
- `msgValue`: ETH the factory forwards to that extension call.
- `extensionBps`: basis points of total token supply reserved for that extension.
- `extensionData`: extension-specific ABI-encoded data decoded by the target contract.

The factory does not decode `extensionData`. It only passes the full deployment config and the active index into `receiveTokens()`. That lets each extension decode exactly the tuple it owns while still seeing the broader launch context if needed.

### Factory preparation

`deployToken()` deploys the ERC20 first, then calls `_prepareExtensions()` before initializing pool liquidity.

`_prepareExtensions()` is deliberately generic:

- zero extensions returns zero reserved supply;
- more than `MAX_EXTENSIONS` reverts with `MaxExtensionsExceeded`;
- total `extensionBps` above `MAX_EXTENSION_BPS` reverts with `MaxExtensionBpsExceeded`;
- the sum of all configured `msgValue` fields must equal transaction `msg.value`;
- every `extension` address must be enabled in the factory.

The return value is aggregate extension supply:

```text
extensionSupplyPercentage = sum(extensionConfigs[i].extensionBps)
extensionsSupply = extensionSupplyPercentage * TOKEN_SUPPLY / BPS
poolSupply = TOKEN_SUPPLY - extensionsSupply
```

That means reserved extension allocations reduce the amount sent to the LP locker. DevBuy has `extensionBps = 0`, so it does not reduce pool supply.

### Launch sequencing

The extension flow runs after pool liquidity is placed and before the MEV module is initialized.

```text
deployToken()
  deploy ERC20 with TOKEN_SUPPLY
  _prepareExtensions(extensionConfigs)
  poolSupply = TOKEN_SUPPLY - extensionsSupply
  _initializePool(...)
  _initializeLiquidity(..., poolSupply, token)
  _triggerExtensions(deploymentConfig, poolKey, token)
  _initializeMevModule(...)
  store DeploymentInfo and emit TokenCreated
```

The ordering matters. DevBuy needs a live pool so it can swap ETH into the launched token. Vault and airdrop only need token approval, but they still run after liquidity. Presale needs the deployed token address and only accepts the call when `endPresale()` has marked token deployment as expected.

### Triggering each extension

`_triggerExtensions()` loops over `deploymentConfig.extensionConfigs` in order.

For each extension, the factory computes:

```text
extensionSupply = extensionConfig.extensionBps * TOKEN_SUPPLY / BPS
```

Then it approves that extension to spend exactly that many newly deployed tokens and calls:

```solidity
receiveTokens{value: extensionConfig.msgValue}(
    deploymentConfig,
    poolKey,
    token,
    extensionSupply,
    i
)
```

The factory emits `ExtensionTriggered` after the call returns. If the extension reverts, no later extension runs and the whole token deployment reverts.

### Extension contract responsibilities

Every extension must implement `supportsInterface(type(IBonkerExtension).interfaceId)` so `setExtension()` can allowlist it.

Every extension should also enforce its own domain rules inside `receiveTokens()`. The factory guarantees only the generic checks: count, aggregate BPS, aggregate ETH, enabled address, per-extension approval, and ETH forwarding. It does not know whether a given extension should require non-zero BPS, zero BPS, a minimum lockup, a Merkle root, or a recipient.

Vault uses `extensionBps > 0`, `msgValue == 0`, a non-zero admin, and a lockup of at least 7 days. It stores one allocation per token and pulls the reserved tokens from the factory.

Airdrop V2 uses `extensionBps > 0`, `msgValue == 0`, and a lockup of at least 1 day. It stores admin, Merkle root, lockup, vesting, claim expiration, and total supply, then pulls the reserved tokens.

DevBuy uses `msgValue > 0`, `extensionBps == 0`, and `extensionSupply == 0`. It wraps ETH as needed, routes through Uniswap V4, and sends acquired launch tokens to the configured recipient.

Presale uses `extensionBps > 0`, `msgValue == 0`, and `extensionData` containing a presale ID. Its `startPresale()` path overwrites the last extension's data with that ID, and `receiveTokens()` only accepts the factory call while `deploymentExpected` is true.

## Invariants And Edge Cases

### Enabled extension gate

An extension contract can exist, but launches cannot use it until the factory owner or admin calls `setExtension(extension, true)`. Deployment scripts do this for Vault, DevBuy, Presale, and Airdrop. The admin console can inspect or change module status, but the final authority is the factory mapping checked in `_prepareExtensions()`.

If the frontend points at an address in `client/config/contracts.js` that is not enabled on the factory, simulation or deployment reverts with `ExtensionNotEnabled`.

### Aggregate ETH must match transaction value

The factory sums `extensionConfigs[i].msgValue` and compares it with `msg.value`. This catches both underpayment and accidental extra ETH.

The public launch form tracks `totalMsgValue` only for DevBuy today. Vault and airdrop pass zero. If a future extension consumes ETH, the client or script building that config must include its `msgValue` in the transaction value.

### Aggregate BPS is capped before individual calls

The factory allows at most `MAX_EXTENSION_BPS` across all extensions, currently 9000 BPS. This preserves at least 10% of total supply for pool liquidity. Individual extensions can impose tighter rules; for example, DevBuy requires zero BPS because it buys from the pool instead of receiving a reserved supply slice.

### Ordering is semantic

The factory triggers extensions in array order and passes `extensionIndex` into every call. Some extension order is just about user intent, but two order constraints are real:

- DevBuy should be last in normal launches because it buys after liquidity exists and after reserved allocations have been carved out.
- Presale must be last in presale launch configs, and `startPresale()` enforces that with `PresaleNotLastExtension`.

Do not sort or de-duplicate extension arrays in a generic helper unless that helper understands these constraints.

### `extensionData` is owned by the target extension

The factory never validates the ABI shape of `extensionData`. A wrong tuple order can pass factory preparation and then revert inside the extension's `abi.decode` or domain checks.

When changing UI encoding, keep the encoded tuple aligned with the exact interface struct:

- `IBonkerVault.VaultExtensionData`
- `IBonkerAirdropV2.AirdropV2ExtensionData`
- `IBonkerUniv4EthDevBuy.Univ4EthDevBuyExtensionData`
- presale `uint256 presaleId`

### Token transfers depend on ERC20 safety wrappers

The factory grants allowance before calling an extension. Token-reserving extensions then pull tokens with `SafeERC20.safeTransferFrom`. DevBuy receives no reserved supply, but it uses `SafeERC20` and Permit2 approvals around swap tokens.

Tests cover non-standard ERC20 behavior for vault, airdrop, and dev-buy paths. Keep new extension transfer logic behind `SafeERC20` unless there is a specific reason to do otherwise.

### Pool extensions are different

Do not confuse factory extensions with hook pool extensions.

Factory extensions are `IBonkerExtension` contracts listed in `deploymentConfig.extensionConfigs` and called by `Bonker._triggerExtensions()`.

Hook pool extensions are configured inside `poolData` as `(address extension, bytes extensionData, bytes feeData)` and are initialized by `BonkerHookV2`. The public launch and admin presale forms currently encode the pool extension address as zero.

## Cross-References

- [LAUNCH-FORM-DEPLOYMENT-CONFIG](./LAUNCH-FORM-DEPLOYMENT-CONFIG.md)
- [PRESALE-LIFECYCLE](./PRESALE-LIFECYCLE.md)
- [ADMIN-OPERATIONS-CONSOLE](./ADMIN-OPERATIONS-CONSOLE.md)
- [TOKEN-DETAIL-ENRICHMENT](./TOKEN-DETAIL-ENRICHMENT.md)
- [OWNER-ADMIN-PERMISSION-MODEL](./OWNER-ADMIN-PERMISSION-MODEL.md)
- [CONTRACT-DEPLOYMENT-WORKFLOW](./CONTRACT-DEPLOYMENT-WORKFLOW.md)
