Token contract metadata lifecycle explains how each deployed `BonkerToken` stores admin-controlled image and metadata strings, exposes verification state, supports ERC20Votes/Permit/Burnable behavior, and gates IERC7802 cross-chain mint/burn; read this before changing `src/BonkerToken.sol`, `src/utils/BonkerDeployer.sol`, token metadata update UI, token verification UI, or token source verification assumptions.

This page covers natural-language queries such as `FACTORY_BRAND`, `BONKER_VERSION`, `updateImage`, `updateMetadata`, `updateAdmin`, `verify`, `isVerified`, `allData`, `imageUrl`, `metadata`, `context`, `crosschainMint`, `crosschainBurn`, `SuperchainTokenBridge`, and "why can original admin verify but current admin edit metadata". It focuses on the deployed ERC20 token contract itself. Factory launch config, token indexing, API formatting, and token-detail enrichment are covered by nearby docs.

## Why It Exists

Bonker launches are usually described from the factory outward: a user submits `IBonker.DeploymentConfig`, the factory deploys a token, initializes a Uniswap v4 pool, locks liquidity, and emits `TokenCreated`.

The token contract has its own post-deployment behavior that is easy to miss because there is no large UI around it yet. `BonkerToken` is the contract wallets, explorers, indexers, and future admin tools will call directly after launch. It stores mutable metadata strings, separates current admin authority from immutable original-admin verification authority, inherits Permit/Votes/Burnable behavior, and exposes IERC7802 bridge hooks gated to the Optimism Superchain bridge predeploy.

That surface matters for three reasons.

First, token metadata has two layers. The factory emits the launch-time image and metadata in `TokenCreated`, and the token stores image, metadata, and context onchain. Updating the token later does not automatically update SQLite rows that were indexed from the launch event.

Second, "admin" is intentionally split. The current token admin can rotate admin rights and update image or metadata. The original admin is immutable and remains the only account that can mark the token verified.

Third, `BonkerToken` bytecode is part of Bonker's explorer identity. `FACTORY_BRAND = "bonker.wtf"` and `BONKER_VERSION = 2` make the deployed token source distinct from upstream Clanker-derived bytecode and give future tools an onchain marker for Bonker tokens.

## Key Files

| File | Why it matters |
| --- | --- |
| `src/interfaces/IBonker.sol:8` | Defines `TokenConfig`, including `tokenAdmin`, `image`, `metadata`, `context`, and `originatingChainId`. |
| `src/interfaces/IBonker.sol:105` | Defines the `TokenCreated` event fields that the indexer stores as launch-time token metadata. |
| `src/utils/BonkerDeployer.sol:9` | Defines the deployer-side `BONKER_VERSION` marker. |
| `src/utils/BonkerDeployer.sol:10` | Defines `BONKER_PROTOCOL_ID = keccak256("bonker.wtf")`. |
| `src/utils/BonkerDeployer.sol:15` | Deploys `BonkerToken` with CREATE2. |
| `src/utils/BonkerDeployer.sol:16` | Derives the CREATE2 salt from `tokenConfig.tokenAdmin` and `tokenConfig.salt`. |
| `src/utils/BonkerDeployer.sol:18` | Passes name, symbol, supply, admin, image, metadata, context, and originating chain into the token constructor. |
| `src/Bonker.sol:155` | Exposes `deployTokenZeroSupply` for non-originating-chain bridge deployments. |
| `src/Bonker.sol:159` | Rejects zero-supply deployment on the originating chain. |
| `src/Bonker.sol:173` | Rejects normal full-supply deployment on non-originating chains. |
| `src/Bonker.sol:178` | Calls `BonkerDeployer.deployToken` during normal factory deployment. |
| `src/Bonker.sol:220` | Emits `TokenCreated` with token address, admin, image, metadata, context, and launch module data. |
| `src/BonkerToken.sol:33` | Declares `BonkerToken` inheritance: `ERC20`, `ERC20Permit`, `ERC20Votes`, `ERC20Burnable`, and `IERC7802`. |
| `src/BonkerToken.sol:35` | Defines `FACTORY_BRAND = "bonker.wtf"`. |
| `src/BonkerToken.sol:36` | Defines token-side `BONKER_VERSION = 2`. |
| `src/BonkerToken.sol:42` | Stores immutable `_originalAdmin`. |
| `src/BonkerToken.sol:43` | Stores mutable `_admin`. |
| `src/BonkerToken.sol:44` | Stores mutable `_metadata`. |
| `src/BonkerToken.sol:45` | Stores immutable-by-convention `_context`; there is no setter. |
| `src/BonkerToken.sol:46` | Stores mutable `_image`. |
| `src/BonkerToken.sol:48` | Stores one-way `_verified` state. |
| `src/BonkerToken.sol:55` | Constructor records admin and metadata inputs and mints only on the originating chain. |
| `src/BonkerToken.sol:79` | Lets the current admin transfer current admin rights. |
| `src/BonkerToken.sol:90` | Lets the current admin update the image string. |
| `src/BonkerToken.sol:100` | Lets the current admin update the metadata string. |
| `src/BonkerToken.sol:116` | Lets only the original admin mark the token verified. |
| `src/BonkerToken.sol:128` | Exposes `isVerified()`. |
| `src/BonkerToken.sol:164` | Exposes `allData()` for a single admin/metadata read. |
| `src/BonkerToken.sol:183` | Gates `crosschainMint` to `Predeploys.SUPERCHAIN_TOKEN_BRIDGE`. |
| `src/BonkerToken.sol:197` | Gates `crosschainBurn` to `Predeploys.SUPERCHAIN_TOKEN_BRIDGE`. |
| `src/BonkerToken.sol:208` | Reports ERC-165 support for IERC7802, IERC20, IERC165, and IERC5805. |
| `server/db.js:98` | Persists launch-time token metadata from the indexed event, not live token storage reads. |
| `server/token-format.js:4` | Formats the persisted token row into the public API shape consumed by the client. |
| `docs/OWNER-ADMIN-PERMISSION-MODEL.md:125` | Summarizes token admin authority in the broader permission model. |

## How It Works

### Deployment Inputs

The token metadata boundary starts in `IBonker.TokenConfig`.

`TokenConfig` carries:

- `tokenAdmin`, the initial current admin and immutable original admin;
- `name` and `symbol`, passed to the ERC20 constructor;
- `salt`, combined with `tokenAdmin` for deterministic deployment;
- `image`, stored as `_image`;
- `metadata`, stored as `_metadata`;
- `context`, stored as `_context`;
- `originatingChainId`, used to decide whether the constructor mints initial supply.

Normal launches use `Bonker.deployToken`. That path rejects calls where `block.chainid` does not match `deploymentConfig.tokenConfig.originatingChainId`, then calls `BonkerDeployer.deployToken` with the full `TOKEN_SUPPLY`.

Bridge-oriented deployments use `Bonker.deployTokenZeroSupply`. That path rejects calls on the originating chain, then calls the same deployer with the same token supply argument. The token constructor receives the supply value, but it only mints when the current chain equals `initialSupplyChainId_`, so a non-originating-chain deployment starts with zero supply.

### Deterministic Token Address

`BonkerDeployer.deployToken` wraps `new BonkerToken{salt: ...}`.

The CREATE2 salt is:

```text
keccak256(abi.encode(tokenConfig.tokenAdmin, tokenConfig.salt))
```

Including `tokenAdmin` means the same user-provided salt can produce different token addresses for different admins. That reduces accidental address collision between launchers that use the same salt value.

The deployer passes the metadata fields directly into the token constructor. There is no normalization step in Solidity. UI and scripts are responsible for deciding whether `metadata` is a JSON string, URL, URI, or empty string.

### Token Constructor State

`BonkerToken` records `_originalAdmin` and `_admin` as the same constructor `admin_` value. `_originalAdmin` is immutable, while `_admin` can change later through `updateAdmin`.

The constructor also stores `_image`, `_metadata`, and `_context`. Only `_image` and `_metadata` have setters. There is no `updateContext` function, so context is fixed after deployment unless a replacement token is deployed.

The constructor mints `maxSupply_` to `msg.sender` only when `block.chainid == initialSupplyChainId_`. During normal factory launches, `msg.sender` is the factory because the token is created through the deployer library during the factory call. The factory then splits token supply between pool liquidity and enabled extensions.

On a non-originating-chain deployment, the constructor does not mint. Supply can later arrive only through the IERC7802 bridge mint path.

### Metadata and Admin Updates

The current admin can call:

- `updateAdmin(address admin_)`;
- `updateImage(string image_)`;
- `updateMetadata(string metadata_)`.

Each function checks `msg.sender == _admin` and reverts with `NotAdmin()` otherwise. `updateAdmin` emits `UpdateAdmin(oldAdmin, admin_)`, while the metadata setters emit `UpdateImage(image_)` and `UpdateMetadata(metadata_)`.

There is no zero-address guard for `updateAdmin`. Setting `_admin` to `address(0)` effectively burns current admin control over image and metadata updates. It does not affect `_originalAdmin`, and it does not remove any existing token balances or ERC20 permissions.

Current admin updates do not emit a factory event. Existing server persistence stores launch-time `TokenCreated` values in SQLite. A future UI that wants live token metadata after `updateImage` or `updateMetadata` must read `BonkerToken.imageUrl()` and `BonkerToken.metadata()` or index the token-level update events.

### Original Admin Verification

`verify()` is separate from current admin metadata control.

Only `_originalAdmin` can call `verify()`. If a transferred current admin calls it, the token reverts with `NotOriginalAdmin()`. If `_originalAdmin` calls it a second time, the token reverts with `AlreadyVerified()`.

Successful verification sets `_verified = true` and emits `Verified(msg.sender, address(this))`. There is no unverify path and no owner override in `BonkerToken`.

This gives the original launcher a one-way attestation that survives later current-admin transfers. That is useful for future UI or crawler features that need to distinguish "metadata can be edited by the current admin" from "the original admin has vouched for this token".

### Read Surface

`BonkerToken` exposes small direct getters:

- `admin()`;
- `originalAdmin()`;
- `imageUrl()`;
- `metadata()`;
- `context()`;
- `isVerified()`.

It also exposes `allData()`, which returns original admin, current admin, image, metadata, and context in one call. Use `allData()` when a caller needs the whole token metadata/admin payload and wants to avoid several independent RPC reads.

`FACTORY_BRAND` and `BONKER_VERSION` are public constants. They are useful for source identity and coarse version checks, but they are not an authorization mechanism. Permission checks still come from the token's own admin fields and the bridge predeploy gate.

### ERC20 Extensions

`BonkerToken` inherits OpenZeppelin `ERC20Permit`, `ERC20Votes`, and `ERC20Burnable`.

`ERC20Permit` adds signature approvals using the token name as the permit domain name. `nonces(address)` is overridden only to resolve the shared OpenZeppelin inheritance between `ERC20Permit` and `Nonces`.

`ERC20Votes` hooks into `_update`, so transfers, mints, and burns update voting checkpoints according to OpenZeppelin's votes implementation. The token also reports IERC5805 support through `supportsInterface`.

`ERC20Burnable` lets token holders burn their own tokens or burn from an approved allowance. This is separate from `crosschainBurn`, which is bridge-only and uses IERC7802 semantics.

### Cross-Chain Mint and Burn

The token implements IERC7802 bridge hooks:

```text
SuperchainTokenBridge -> crosschainBurn(source chain)
SuperchainTokenBridge -> crosschainMint(destination chain)
```

Both `crosschainMint` and `crosschainBurn` require `msg.sender == Predeploys.SUPERCHAIN_TOKEN_BRIDGE`. Any other caller reverts with the Optimism `Unauthorized()` error.

`crosschainMint(address _to, uint256 _amount)` mints tokens to `_to` and emits `CrosschainMint(_to, _amount, msg.sender)`.

`crosschainBurn(address _from, uint256 _amount)` burns tokens from `_from` and emits `CrosschainBurn(_from, _amount, msg.sender)`.

This bridge surface depends on the constructor's originating-chain supply behavior. The full supply starts only on the originating chain. Non-originating-chain token deployments start at zero and are supplied by bridge mints.

## Invariants and Edge Cases

### Original Admin Is Immutable

`_originalAdmin` is set once in the constructor. `updateAdmin` changes `_admin` only. Verification authority stays with `_originalAdmin` even after current admin rights move.

Do not use `admin()` as a proxy for who can call `verify()`. Use `originalAdmin()` for verification authority and `admin()` for metadata-edit authority.

### Context Has No Setter

`image` and `metadata` are mutable. `context` is not. A UI that exposes token metadata editing should not imply that all launch-time metadata fields can be edited after deployment.

### Indexed Metadata Can Become Stale

`TokenCreated` carries launch-time image, metadata, and context. The token can later emit `UpdateImage` or `UpdateMetadata`, but the current SQLite token row is populated from the launch event path.

If a feature needs live metadata, it must either read the token contract at request time or add an indexer path for the token-level update events. Reading `server/token-format.js` output alone does not prove the onchain image or metadata strings are still current.

### Verification Is One-Way

Once `_verified` is true, `verify()` cannot be called again and there is no unverify function. Avoid designs that assume verification is a mutable moderation flag.

### Zero Admin Is Allowed

`updateAdmin(address(0))` is not rejected. That can intentionally or accidentally freeze future image and metadata updates by making the current-admin check impossible to satisfy.

It does not freeze the original-admin verification path unless `_originalAdmin` was also zero at construction. Normal launch forms set `tokenAdmin` to a connected wallet, not zero.

### Bridge Hooks Are Not General Mint Authority

`crosschainMint` and `crosschainBurn` are not admin functions. Current admin, original admin, factory owner, and factory admins cannot call them unless they are the Superchain token bridge predeploy.

Changing bridge behavior requires reviewing IERC7802 compatibility, `supportsInterface`, constructor supply rules, and the non-originating-chain factory path together.

### Interface Support Is Explicit

`supportsInterface` returns true for IERC7802, IERC20, IERC165, and IERC5805. It does not advertise every inherited OpenZeppelin extension as an ERC-165 interface.

If integrations depend on interface detection, confirm the selector is included before assuming a token reports support.

### Brand Constants Are Identity Markers

`FACTORY_BRAND` and `BONKER_PROTOCOL_ID` identify Bonker's token/deployer bytecode lineage. They do not prove the token was launched through the current production factory, and they do not replace event indexing or factory deployment-info reads.

For app-level token discovery, use the factory `TokenCreated` event and SQLite indexer. For token bytecode/source identity, use the constants and verified source.

## Cross-References

- [LAUNCH-FORM-DEPLOYMENT-CONFIG](./LAUNCH-FORM-DEPLOYMENT-CONFIG.md)
- [TOKEN-INDEXER-LIFECYCLE](./TOKEN-INDEXER-LIFECYCLE.md)
- [TOKEN-DETAIL-ENRICHMENT](./TOKEN-DETAIL-ENRICHMENT.md)
- [OWNER-ADMIN-PERMISSION-MODEL](./OWNER-ADMIN-PERMISSION-MODEL.md)
- [CONTRACT-DEPLOYMENT-WORKFLOW](./CONTRACT-DEPLOYMENT-WORKFLOW.md)
