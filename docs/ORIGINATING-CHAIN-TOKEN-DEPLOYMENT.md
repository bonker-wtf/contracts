Originating-chain token deployment explains how Bonker decides which chain may mint initial supply, how `deployToken()` and `deployTokenZeroSupply()` share `BonkerDeployer`, and when to read this before changing `originatingChainId`, deterministic token salts, bridge mint/burn behavior, or public integration payloads.

This page covers natural-language queries such as `deployTokenZeroSupply`, `originatingChainId`, `OnlyOriginatingChain`, `OnlyNonOriginatingChains`, `BonkerDeployer.deployToken`, `keccak256(abi.encode(tokenAdmin, salt))`, `initialSupplyChainId_`, `crosschainMint`, `crosschainBurn`, and "why did this token deploy with no minted supply". It focuses on token creation and chain gating. It does not cover the full launch-form ABI, extension reservation math, token metadata editing, or production deploy scripts except where they feed this boundary.

## Why It Exists

Bonker tokens are meant to have one canonical initial-supply chain. Today the public product launches on Base, but the token contract is written with cross-chain support: the same token bytecode can exist on another Superchain network, and `IERC7802` bridge hooks can mint or burn bridged balances there.

That creates a supply-safety problem. If the same token configuration could mint `TOKEN_SUPPLY` on every chain where the factory exists, the bridge model would be broken before the first transfer. Bonker solves that by putting the chain ID into `IBonker.TokenConfig.originatingChainId`, then using two mutually exclusive factory entrypoints:

- `deployToken()` is the normal originating-chain path. It requires `block.chainid == originatingChainId`, mints the full 100B supply to the factory, initializes the pool, places liquidity, runs extensions, initializes MEV, stores deployment info, and emits `TokenCreated`.
- `deployTokenZeroSupply()` is the non-originating-chain path. It requires `block.chainid != originatingChainId` and only deploys the token contract. The constructor receives the same max supply value, but mints nothing because the current chain is not the initial supply chain.

The same `BonkerDeployer` library creates tokens for both paths. That keeps token constructor arguments and CREATE2 salt derivation identical across chains, while the `BonkerToken` constructor decides whether any initial supply is minted.

This split matters for integrators because `originatingChainId` is not display metadata. A wrong chain ID changes whether the token can be launched through the public factory path, whether liquidity receives any tokens, and whether a mirror deployment starts with zero supply.

## Key Files

| File | Why it matters |
| --- | --- |
| `src/interfaces/IBonker.sol:8` | Defines `TokenConfig`, including `salt` and `originatingChainId`. |
| `src/interfaces/IBonker.sol:72` | Declares `OnlyOriginatingChain()` and `OnlyNonOriginatingChains()` chain-gating errors. |
| `src/interfaces/IBonker.sol:136` | Exposes `deployTokenZeroSupply(TokenConfig)` on the factory interface. |
| `src/interfaces/IBonker.sol:140` | Exposes the payable `deployToken(DeploymentConfig)` launch entrypoint. |
| `src/Bonker.sol:155` | Implements `deployTokenZeroSupply()` and rejects calls on the originating chain. |
| `src/Bonker.sol:166` | Implements `deployToken()` and rejects calls off the originating chain. |
| `src/Bonker.sol:178` | Calls `BonkerDeployer.deployToken()` before supply splitting, pool setup, locker setup, extensions, and MEV initialization. |
| `src/Bonker.sol:220` | Emits `TokenCreated`, the event consumed by the server indexer and public token surfaces. |
| `src/utils/BonkerDeployer.sol:11` | Deploys `BonkerToken` with a salt derived from `tokenAdmin` and caller-provided `salt`. |
| `src/BonkerToken.sol:55` | Receives `initialSupplyChainId_` in the token constructor. |
| `src/BonkerToken.sol:71` | Mints initial supply only when `block.chainid == initialSupplyChainId_`. |
| `src/BonkerToken.sol:181` | Allows bridge-only cross-chain minting through `Predeploys.SUPERCHAIN_TOKEN_BRIDGE`. |
| `src/BonkerToken.sol:195` | Allows bridge-only cross-chain burning through `Predeploys.SUPERCHAIN_TOKEN_BRIDGE`. |
| `client/components/LaunchPage.jsx:425` | Public launch form sets `originatingChainId` to `BASE_CHAIN_ID`. |
| `client/components/admin/presaleConfig.js:58` | Admin presale creation also sets `originatingChainId` to `BASE_CHAIN_ID`. |
| `scripts/deploy-token.mjs:101` | Standalone operator deploy script mirrors the same Base originating-chain value. |

## How It Works

### Shared Token Config

The chain decision starts in `IBonker.TokenConfig`, not in the pool, locker, extension, or MEV config. The relevant fields are:

- `tokenAdmin`: the token admin and one input to the deterministic deployment salt;
- `salt`: caller-provided entropy, usually random or derived by a script;
- `originatingChainId`: the only chain where the constructor should mint initial supply.

The public launch form, admin presale builder, and standalone deploy script all set `originatingChainId` to Base mainnet (`8453`). That matches the current production factory and means normal launches must execute on Base.

If a future caller constructs `TokenConfig` for another chain, the factory path must match that choice. `deployToken()` will reject a Base transaction whose `originatingChainId` is not Base. `deployTokenZeroSupply()` will reject a Base transaction whose `originatingChainId` is Base.

### Normal Originating-Chain Launch

`deployToken()` is the full token launch path.

```text
caller
  -> Bonker.deployToken(DeploymentConfig)
      require factory not deprecated
      require block.chainid == tokenConfig.originatingChainId
      -> BonkerDeployer.deployToken(tokenConfig, TOKEN_SUPPLY)
          -> new BonkerToken(..., TOKEN_SUPPLY, ..., originatingChainId)
              if block.chainid == originatingChainId:
                  mint TOKEN_SUPPLY to factory
      -> _prepareExtensions()
      -> _initializePool()
      -> _initializeLiquidity()
      -> _triggerExtensions()
      -> _initializeMevModule()
      -> store deploymentInfoForToken[token]
      -> emit TokenCreated(...)
```

The token constructor mints to `msg.sender`, which is the factory because the factory calls the library and the library creates the token. That is why the factory can then approve the locker and extensions for their supply slices.

No caller receives the full token supply directly. Pool supply moves through the locker, reserved supply moves through enabled extensions, and token recipients get their allocations through those downstream contracts.

### Non-Originating Zero-Supply Deployment

`deployTokenZeroSupply()` is intentionally much smaller.

```text
caller
  -> Bonker.deployTokenZeroSupply(TokenConfig)
      require block.chainid != tokenConfig.originatingChainId
      -> BonkerDeployer.deployToken(tokenConfig, TOKEN_SUPPLY)
          -> new BonkerToken(..., TOKEN_SUPPLY, ..., originatingChainId)
              if block.chainid != originatingChainId:
                  mint nothing
```

This path does not check `deprecated`, does not initialize a pool, does not place liquidity, does not run extensions, does not initialize MEV, does not write `deploymentInfoForToken`, and does not emit `TokenCreated`.

That is deliberate. It exists to create the token shell on a non-originating chain so bridged supply can be minted by the Superchain bridge. It is not a launch replacement and it will not make the token appear in Bonker's token indexer, sitemap, Telegram announcements, or token detail pages.

### Deterministic Address Salt

`BonkerDeployer.deployToken()` does not use `tokenConfig.salt` directly. It derives the CREATE2 salt as:

```solidity
keccak256(abi.encode(tokenConfig.tokenAdmin, tokenConfig.salt))
```

This binds deterministic deployment to both the admin and the caller-provided salt. Two admins using the same raw salt do not collide with each other. The same admin using the same raw salt and the same constructor arguments will target the same address on a given factory deployment.

Because constructor arguments include token name, symbol, supply, admin, image, metadata, context, and `originatingChainId`, address prediction must use the full creation bytecode plus the exact encoded constructor args. Matching only the raw salt is not enough.

### Constructor Mint Gate

`BonkerToken` receives `maxSupply_` and `initialSupplyChainId_`, but it does not store `maxSupply_` as a cap. The value is used only at construction:

- if the current chain is the initial-supply chain, `_mint(msg.sender, maxSupply_)`;
- otherwise, skip the mint.

After construction, cross-chain supply movement is controlled by `crosschainMint()` and `crosschainBurn()`. Both functions reject every caller except `Predeploys.SUPERCHAIN_TOKEN_BRIDGE`, then emit the `IERC7802` events expected by bridge-aware tooling.

This means `deployTokenZeroSupply()` can still pass `TOKEN_SUPPLY` safely. The token sees the same max initial-supply argument, but the constructor does not mint on the wrong chain.

## Invariants And Edge Cases

### One Full Initial Mint

For a given token configuration, full initial supply should be minted on exactly one chain: the chain whose `block.chainid` equals `originatingChainId`.

Breaking this invariant creates duplicate unbridged supply. The factory guards prevent the normal `deployToken()` path from running on a non-originating chain, and the token constructor independently avoids minting initial supply when deployed through `deployTokenZeroSupply()`.

### Zero-Supply Tokens Are Not Indexed Launches

`TokenCreated` is emitted only by `deployToken()`. The server token poller watches that event from the Base factory, persists the launch, enriches market data, pings IndexNow, and sends Telegram notifications.

A `deployTokenZeroSupply()` transaction will not flow through those systems. If a future UI or script creates mirror tokens, it must not expect `/api/tokens`, `/token/:address`, sitemap generation, or token detail enrichment to discover them from the current event pipeline.

### Deprecated Factory Still Allows Mirror Deployment

`deployToken()` checks `deprecated`; `deployTokenZeroSupply()` does not.

That means pausing normal originating-chain launches does not necessarily pause non-originating token shell deployments. This is consistent with the constructor-level supply gate, but it is still an operational distinction worth preserving deliberately if factory pause semantics change.

### Full Launch Requires Minted Factory Balance

The launch path assumes the factory owns the full token supply immediately after `BonkerDeployer.deployToken()`. `_initializeLiquidity()` approves pool supply to the locker, and `_triggerExtensions()` approves each extension's reserved allocation.

If `originatingChainId` is wrong for the chain executing `deployToken()`, the factory reverts before deployment. If that guard were bypassed, the token constructor would mint nothing and the later locker or extension transfers would fail.

### Salt Collisions Are Admin-Scoped

The deployment salt includes `tokenAdmin`. This reduces accidental collisions between different launchers, but it does not make salts globally unique for the same admin.

A script that reuses the same raw salt, token admin, factory address, bytecode, and constructor args will target an already-used address and fail at deployment. Public UI code uses a fresh random salt; deterministic scripts should treat raw salt reuse as an intentional address-prediction action.

### Bridge Hooks Are Permissioned, Not User Mints

`crosschainMint()` and `crosschainBurn()` are not admin tools. They are callable only by `Predeploys.SUPERCHAIN_TOKEN_BRIDGE`; token admins cannot invoke them directly.

Admin authority covers metadata, image, and admin rotation. Original-admin authority covers verification. Bridge supply movement is a separate permission surface inside `BonkerToken`.

## Cross-References

- [LAUNCH-FORM-DEPLOYMENT-CONFIG](./LAUNCH-FORM-DEPLOYMENT-CONFIG.md) for the browser-side `DeploymentConfig` builder, wallet simulation, and `deployToken()` submission.
- [PUBLIC-DEPLOYTOKEN-INTEGRATION-GUIDE](./PUBLIC-DEPLOYTOKEN-INTEGRATION-GUIDE.md) for the static `/skill.md` artifact that external builders consume.
- [FACTORY-EXTENSION-LIFECYCLE](./FACTORY-EXTENSION-LIFECYCLE.md) for supply reservation and extension callbacks after the initial token mint.
- [TOKEN-CONTRACT-METADATA-LIFECYCLE](./TOKEN-CONTRACT-METADATA-LIFECYCLE.md) for token admin metadata, verification, and `IERC7802` bridge hook behavior inside `BonkerToken`.
- [TOKEN-INDEXER-LIFECYCLE](./TOKEN-INDEXER-LIFECYCLE.md) for how `TokenCreated` becomes SQLite rows, market enrichment, sitemap input, and notifications.
- [CONTRACT-CONFIG-TOPOLOGY](./CONTRACT-CONFIG-TOPOLOGY.md) for where Base chain constants and deployed addresses live across client, server, scripts, and docs.
