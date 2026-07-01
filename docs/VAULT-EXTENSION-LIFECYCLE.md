Vault extension lifecycle explains how Bonker reserves token supply for a single beneficiary under a lockup-then-vesting schedule, how `BonkerVault` differs from the Merkle-based airdrop extension, and when to read this before changing launch vault encoding, vault admin transfers, vault claims, token-detail enrichment, or deployment scripts.

This page covers natural-language queries such as `BonkerVault`, `VaultExtensionData`, `Allocation`, `MIN_LOCKUP_DURATION`, `editAllocationAdmin`, `amountAvailableToClaim`, "why is the vault lockup at least 7 days", "why does the vault claim go to the admin not the caller", "why is there only one vault allocation per token", and "how does the vault vesting curve work". It focuses on the vault extension itself. The shared factory extension boundary, launch form deployment config, token-detail enrichment, and owner/admin model are covered by nearby docs.

## Why It Exists

Bonker lets a launch reserve part of the 100B token supply for the deployer (team, marketing, or a treasury) instead of putting all of it into the liquidity pool. The factory does the supply accounting, then calls an enabled vault extension during `Bonker.deployToken`. The vault pulls its reserved tokens out of the factory, records a per-token `Allocation`, and releases the tokens to a single `admin` address on a lockup-then-vesting schedule.

That solves a launch credibility problem: a reserved allocation that is publicly time-locked on-chain is more trustworthy than a deployer wallet that could dump immediately. The schedule is fixed at deploy time, the token detail page can show the locked percentage, unlock date, vesting end, and claimed amount, and nobody — including the admin — can pull tokens before the lockup passes.

The vault is deliberately simpler than the airdrop extension. There is no Merkle tree, no allowlist of many recipients, and no admin sweep of leftovers. A vault has exactly one beneficiary (`admin`) and exactly one allocation per token. The sharp edges are therefore different from the airdrop's: a longer minimum lockup (`7 days`, not `1 days`), an "only one allocation per token" guard, and the fact that the claim caller never receives the tokens — the registered `admin` always does.

## Key Files

| File | Why it matters |
| --- | --- |
| `src/extensions/BonkerVault.sol:18` | Declares the vault extension; holds the `allocation` mapping and the immutable `factory`. |
| `src/extensions/BonkerVault.sol:23` | `MIN_LOCKUP_DURATION = 7 days`, the minimum lockup the vault accepts. |
| `src/extensions/BonkerVault.sol:41` | `receiveTokens()` decodes `VaultExtensionData`, validates launch config, stores the allocation, and pulls reserved supply. |
| `src/extensions/BonkerVault.sol:102` | `editAllocationAdmin()` lets the current admin transfer beneficiary/controller rights. |
| `src/extensions/BonkerVault.sol:113` | `amountAvailableToClaim()` exposes the vesting preview without mutating state. |
| `src/extensions/BonkerVault.sol:121` | `claim()` releases all currently vested tokens to the registered admin. |
| `src/extensions/BonkerVault.sol:141` | `_getAmountToClaim()` holds the lockup gate and the linear vesting math. |
| `src/extensions/interfaces/IBonkerVault.sol:7` | `VaultExtensionData` is the launch tuple: `admin`, `lockupDuration`, `vestingDuration`. |
| `src/extensions/interfaces/IBonkerVault.sol:13` | `Allocation` is the stored struct returned by the public `allocation(token)` getter. |
| `src/Bonker.sol:313` | Factory sums every `extensionBps`, including the vault's, against the shared extension cap. |
| `src/Bonker.sol:360` | Factory calls `receiveTokens()` on each enabled extension with its supply slice and `msgValue`. |
| `client/config/contracts.js:8` | Client source of truth for the deployed `VAULT` address. |
| `client/components/LaunchPage.jsx:102` | `VAULT_LOCKUP_OPTIONS` offers 7/14/30/90-day lockups, aligned with the contract minimum. |
| `client/components/LaunchPage.jsx:352` | Public launch form encodes `VaultExtensionData` and appends it to `extensionConfigs`. |
| `client/components/LaunchPage.jsx:620` | The "Extension: Creator Vault" form section and its percentage/lockup/vesting inputs. |
| `server/tokens.js:67` | `VAULT_ABI` declares the `allocation(token)` getter used for enrichment. |
| `server/tokens.js:236` | Token-detail enrichment reads `allocation(token)` only when the launch included the deployed vault. |
| `client/components/TokenDetailPage.jsx:447` | Token detail renders Vaulted percent, unlock, vesting end, admin, and claimed fields. |
| `client/components/admin/FactorySections.jsx:54` | Admin console shows whether the vault extension is enabled on the factory. |
| `script/DeployExtensions.s.sol:24` | Standalone script constructs `BonkerVault` and enables it via `factory.setExtension`. |
| `test/BonkerExtensionVesting.t.sol:65` | `BonkerVaultVestingTest` covers the vault lockup, vesting, and SafeERC20 behavior. |

## How It Works

### Launch-Time Allocation

The vault starts as one entry in `IBonker.ExtensionConfig[]`. During `Bonker.deployToken`, the factory sums every entry's `extensionBps`, rejects the launch if the total exceeds `MAX_EXTENSION_BPS` (9000, i.e. 90%) or there are more than `MAX_EXTENSIONS` (10) entries, confirms each `extension` is enabled, then computes `extensionSupply = extensionBps * TOKEN_SUPPLY / BPS` and calls `receiveTokens()` on the vault with that slice (`src/Bonker.sol:313`, `src/Bonker.sol:360`).

`BonkerVault.receiveTokens()` accepts only factory calls (`onlyFactory`). It decodes `VaultExtensionData`, rejects any nonzero ETH value, rejects zero `extensionBps` (`InvalidVaultBps`), rejects lockups shorter than `MIN_LOCKUP_DURATION` (`VaultLockupDurationTooShort`), rejects a zero `admin` (`InvalidVaultAdmin`), and rejects a second allocation for the same token (`AllocationAlreadyExists`). It then writes the `Allocation`, pulls the reserved token amount from the factory with `SafeERC20.safeTransferFrom()`, and emits `AllocationCreated`.

### VaultExtensionData And Allocation Storage

The launch tuple is intentionally small — it carries no supply amount and no recipient list, because the factory supplies the amount and the vault has a single beneficiary:

```text
VaultExtensionData
  admin: address            // beneficiary + controller
  lockupDuration: uint256   // seconds before any claim is possible
  vestingDuration: uint256  // seconds of linear release after lockup
```

`receiveTokens()` turns that into stored `Allocation` state keyed by token:

```text
Allocation
  token: address
  amountTotal: uint256      // = extensionSupply pulled from the factory
  amountClaimed: uint256
  lockupEndTime: uint256    // block.timestamp + lockupDuration
  vestingEndTime: uint256   // lockupEndTime + vestingDuration
  admin: address
```

Note `lockupEndTime` is computed from `block.timestamp` at deploy, so the clock starts at launch, not at some absolute date passed in. A `vestingDuration` of `0` makes `vestingEndTime == lockupEndTime`, meaning the whole allocation unlocks at once when lockup ends.

### Public Launch Form

`LaunchPage` exposes the vault under the "Extension: Creator Vault" section. It encodes `VaultExtensionData` with `admin` defaulted to the connected wallet (overridable via the Vault Recipient field), `lockupDuration` chosen from `VAULT_LOCKUP_OPTIONS`, and `vestingDuration` from the shared vesting options. The percentage input is constrained to 1–10% in the UI, and `extensionBps` is `Math.round(parseFloat(vaultPct) * 100)`.

The launch form's lockup choices start at `604800` (7 days), which matches the contract's `MIN_LOCKUP_DURATION`. This is a deliberate contrast with the airdrop form, which historically offered a `0` lockup that the airdrop contract then rejects. Because the vault UI never offers a sub-7-day lockup, a wallet using the form will not hit `VaultLockupDurationTooShort` — but a hand-built `DeploymentConfig` still can.

### Claim And Linear Vesting

`claim(token)` is permissionless to call but always pays the registered `admin`. It reverts before `lockupEndTime` (`AllocationNotUnlocked`) and reverts if nothing is currently vested (`NoBalanceToClaim`). On success it adds the vested amount to `amountClaimed` and transfers via `SafeERC20.safeTransfer()`, emitting `AllocationClaimed`.

The releasable amount comes from `_getAmountToClaim()`, the same linear model the airdrop uses:

```text
before lockupEndTime:
  available = 0

between lockupEndTime and vestingEndTime:
  amountTotal * (now - lockupEndTime) / (vestingEndTime - lockupEndTime)
  minus amountClaimed

after vestingEndTime:
  amountTotal - amountClaimed
```

`amountAvailableToClaim(token)` exposes this as a view so UIs and `claim()` agree. `BonkerVaultVestingTest` pins the behavior: zero before unlock, half at the vesting midpoint, full remainder after vesting end (`test/BonkerExtensionVesting.t.sol:133`), and a separate test confirms claims work with non-standard ERC20 tokens that omit a boolean return (`test/BonkerExtensionVesting.t.sol:154`).

### Admin Transfer

`editAllocationAdmin(token, newAdmin)` lets the current admin hand both the beneficiary role and the controller role to another address. Only the current `admin` may call it, and it emits `AllocationAdminUpdated`. After transfer, future `claim()` payouts go to `newAdmin`. There is no separate "owner" vs "recipient" split in the vault — the `admin` is always both.

### Token Detail Enrichment

The token indexer stores extension addresses from `TokenCreated`. On `/api/tokens/:address`, `enrichWithOnChainData()` checks whether any emitted extension address maps to the `vault` feature in `server/contract-features.js`. If so, it reads `allocation(token)` from that emitted extension address via `VAULT_ABI` and, when `amountTotal > 0`, sets `features.vault` with `amountTotal`, `amountClaimed`, `lockupEndTime`, `vestingEndTime`, and `admin` (`server/tokens.js:236`).

`TokenDetailPage` renders that feature as the Vaulted percentage (computed against the 100B total supply by the `vaultPercent` helper at `client/components/TokenDetailPage.jsx:69`), plus Vault Unlock, an optional Vault Vesting row shown only when `vestingEndTime > lockupEndTime`, Vault Admin, and Vault Claimed. It is an inspection surface only — there is no claim UI on the page.

## Vault Versus Airdrop

The vault and the airdrop are the two supply-reserving, lockup-then-vesting extensions, and they share the linear vesting math and SafeERC20 transfers. They differ in who receives, how recipients are identified, and how the allocation can change after launch.

| Aspect | `BonkerVault` | `BonkerAirdropV2` |
| --- | --- | --- |
| Beneficiaries | Single `admin` address | Many recipients via a Merkle tree |
| Launch tuple | `(admin, lockupDuration, vestingDuration)` | `(admin, merkleRoot, lockupDuration, vestingDuration)` |
| Minimum lockup | `7 days` | `1 days` |
| Recipient proof | None — admin is fixed in storage | Merkle proof of `(recipient, allocatedAmount)` |
| Who receives on claim | Always the registered `admin` | Always the proven `recipient` |
| Post-launch mutation | `editAllocationAdmin` only | `updateMerkleRoot`, `updateAdmin`, `adminClaim` |
| Leftover sweep | None | `adminClaim()` after the claim window |
| Allocations per token | Exactly one (`AllocationAlreadyExists`) | One airdrop record per token |

If you are deciding which extension a launch needs: pick the vault for a single team/treasury lock, and the airdrop when many wallets must each claim a proven slice. See [AIRDROP-EXTENSION-LIFECYCLE](./AIRDROP-EXTENSION-LIFECYCLE.md) for the airdrop side.

## Invariants And Edge Cases

### The Factory Is The Only Initializer

`receiveTokens()` is `onlyFactory`. Vault state must be created through `Bonker.deployToken`, not by transferring tokens directly to the vault. A direct transfer leaves `allocation[token]` empty, so there is nothing to `claim()` and the tokens are stranded.

### One Allocation Per Token Is Permanent

The first allocation sets `lockupEndTime` to a nonzero value, and `receiveTokens()` reverts with `AllocationAlreadyExists` if `allocation[token].lockupEndTime != 0`. There is no way to add a second vault slice or re-lock the same token's vault later. Get the schedule right at launch.

### Lockup Must Be At Least Seven Days

`lockupDuration < MIN_LOCKUP_DURATION` reverts `VaultLockupDurationTooShort`. This is stricter than the airdrop's one-day minimum. The launch UI only offers 7/14/30/90-day lockups, so it cannot trip this guard, but a hand-encoded `DeploymentConfig` can.

### The Vault Forwards No ETH

`receiveTokens()` rejects both a nonzero `ExtensionConfig.msgValue` and any `msg.value` with `InvalidMsgValue`. The vault only ever moves the ERC20 supply it is allocated. The factory separately enforces that the sum of all `ExtensionConfig.msgValue` equals `msg.value` (`ExtensionMsgValueMismatch`), so a vault entry must carry `msgValue: 0`.

### Claim Caller Is Not The Beneficiary

Anyone can call `claim(token)`, but `SafeERC20.safeTransfer()` always pays `allocation[token].admin`. This allows a keeper or helper to trigger claims without becoming a custodian, and it means a claim by a third party still credits the admin.

### Extension BPS Reserves Real Pool Supply

The vault receives `extensionBps * TOKEN_SUPPLY / BPS` from the factory, and that supply is held out of pool liquidity. The vault's BPS counts toward the shared `MAX_EXTENSION_BPS` cap (90%) across all extensions, so a large vault percentage leaves less for airdrop, dev buy, presale, and the pool itself. Zero BPS reverts `InvalidVaultBps`.

### Vesting Of Zero Means Cliff Unlock

When `vestingDuration` is `0`, `vestingEndTime == lockupEndTime`, and `_getAmountToClaim()` returns the full `amountTotal` immediately after lockup. The token detail page detects this by hiding the Vault Vesting row whenever `vestingEndTime` is not greater than `lockupEndTime`.

### Public Mapping Getter Order Matters

`allocation(token)` returns fields positionally: `token`, `amountTotal`, `amountClaimed`, `lockupEndTime`, `vestingEndTime`, `admin`. The server's destructuring at `server/tokens.js:236` skips the first field and reads the rest in that order. If the `Allocation` struct order ever changes, `VAULT_ABI` and that destructuring must change together or the enriched API fields will silently mislabel.

## Cross-References

- [FACTORY-EXTENSION-LIFECYCLE](./FACTORY-EXTENSION-LIFECYCLE.md) for the shared `ExtensionConfig[]`, supply reservation, ETH forwarding, extension BPS cap, and callback order.
- [AIRDROP-EXTENSION-LIFECYCLE](./AIRDROP-EXTENSION-LIFECYCLE.md) for the Merkle-based sibling extension and the shared linear vesting model.
- [LAUNCH-FORM-DEPLOYMENT-CONFIG](./LAUNCH-FORM-DEPLOYMENT-CONFIG.md) for how `/launch` builds `DeploymentConfig`, including vault encoding and wallet submission.
- [OWNER-ADMIN-PERMISSION-MODEL](./OWNER-ADMIN-PERMISSION-MODEL.md) for how the vault admin differs from factory owner, factory admin, token admin, airdrop admin, and presale owner.
- [TOKEN-DETAIL-ENRICHMENT](./TOKEN-DETAIL-ENRICHMENT.md) for request-time reads that add vault state to `/api/tokens/:address`.
- [FOUNDRY-REGRESSION-SUITE](./FOUNDRY-REGRESSION-SUITE.md) for the Solidity tests that protect vault vesting math and non-standard ERC20 transfer compatibility.
- [CONTRACT-DEPLOYMENT-WORKFLOW](./CONTRACT-DEPLOYMENT-WORKFLOW.md) for the scripts that deploy and enable extensions on the factory.
