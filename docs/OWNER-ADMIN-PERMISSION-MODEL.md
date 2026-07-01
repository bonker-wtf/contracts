Owner/admin permission model explains how Bonker separates factory ownership, factory admins, token admins, extension admins, LP reward admins, and presale owners; read this before changing `OwnerAdmins`, privileged factory calls, admin console writes, launch config ownership fields, extension claim controls, or presale owner flows.

This page covers natural-language queries such as `OwnerAdmins`, `onlyOwnerOrAdmin`, `onlyAdmin`, `setAdmin`, `setDeprecated`, `setTeamFeeRecipient`, `claimTeamFees`, `tokenAdmin`, `originalAdmin`, `rewardAdmins`, `rewardRecipients`, `presaleOwner`, `PresaleSaltBufferNotExpired`, `editAllocationAdmin`, `updateMerkleRoot`, and `updateRewardAdmin`. Bonker deliberately has several "admin" words that do not mean the same thing. The factory owner controls protocol-level configuration, factory admins can operate selected factory surfaces, token admins own token metadata, LP reward admins control their own reward slot, and presale owners control presale proceeds plus early/salt-sensitive deployment windows.

## Why It Exists

Bonker is a public token factory, but not every sensitive action should be controlled by the same address.

The factory owner is the protocol authority. It can pause normal factory deployments with `setDeprecated`, choose the `teamFeeRecipient`, add or remove factory admins, and tune presale-wide owner-only parameters. Those are global controls; a wrong call can affect every future launch or protocol fee claim.

Factory admins are operational delegates. They can claim accumulated team fees, enable or disable modules for factory launches, and start presales on the presale contract. They cannot transfer ownership, change the factory's team fee recipient, undeprecate the factory, or change presale fee policy unless the specific contract exposes that function to admins.

Launch-time admins are per-token or per-allocation roles chosen in `IBonker.DeploymentConfig`. They survive after deployment and are separate from the factory. A token admin can update token metadata. A vault admin receives vested vault tokens. An airdrop admin manages the Merkle root before claims and can claim leftovers after the expiration interval. LP reward admins control fee recipient and fee preference for their reward slot.

Presales add a fourth authority shape. The contract-level presale admins may create presales, but each presale stores a `presaleOwner` that can end an active successful sale early, gets the salt-priority window, and receives raised ETH after fees. The Bonker protocol owner can assist with ETH claiming, but only to the stored presale owner.

The result is a layered model: protocol configuration is global, factory operation is delegated, launch ownership is per-token, and presale proceeds are per-sale.

## Key Files

### Shared Roles and Factory

| File | Why it matters |
| --- | --- |
| `src/utils/OwnerAdmins.sol:7` | Shared `Ownable` plus `admins` mapping used by factory-like contracts. |
| `src/utils/OwnerAdmins.sol:12` | `setAdmin` is owner-only and emits `SetAdmin`. |
| `src/utils/OwnerAdmins.sol:17` | `onlyAdmin` accepts only addresses in `admins`. |
| `src/utils/OwnerAdmins.sol:22` | `onlyOwnerOrAdmin` accepts either `owner()` or an enabled admin. |
| `src/Bonker.sol:36` | The main factory inherits `OwnerAdmins`. |
| `src/Bonker.sol:66` | `setDeprecated` is owner-only, so admins cannot pause or unpause normal launches. |
| `src/Bonker.sol:73` | `setTeamFeeRecipient` is owner-only. |
| `src/Bonker.sol:81` | `claimTeamFees` is available to owner or admins, but transfers to `teamFeeRecipient`. |
| `src/Bonker.sol:98` | `setHook` is available to owner or admins after interface validation. |
| `src/Bonker.sol:113` | `setLocker` is available to owner or admins for a specific hook. |
| `src/Bonker.sol:127` | `setMevModule` is available to owner or admins after interface validation. |
| `src/Bonker.sol:141` | `setExtension` is available to owner or admins after interface validation. |
| `src/Bonker.sol:220` | `TokenCreated` records `msgSender` and `tokenAdmin` as separate event fields. |
| `src/hooks/BonkerPoolExtensionAllowlist.sol:16` | Pool extension allowlisting also uses owner-or-admin delegation. |
| `src/interfaces/IBonker.sol:8` | `TokenConfig.tokenAdmin` is part of the launch config, not inferred from factory owner. |
| `src/interfaces/IBonker.sol:27` | `LockerConfig` stores `rewardAdmins` and `rewardRecipients` separately. |

### Token and Presale Roles

| File | Why it matters |
| --- | --- |
| `src/BonkerToken.sol:65` | A deployed token stores immutable `_originalAdmin` and mutable `_admin`. |
| `src/BonkerToken.sol:79` | Current token admin can transfer token admin rights. |
| `src/BonkerToken.sol:90` | Current token admin can update the token image. |
| `src/BonkerToken.sol:100` | Current token admin can update token metadata. |
| `src/BonkerToken.sol:116` | Only original token admin can call `verify`. |
| `src/extensions/BonkerPresaleEthToCreator.sol:86` | Presale allowlist registry is owner-only. |
| `src/extensions/BonkerPresaleEthToCreator.sol:93` | Minimum presale lockup duration is owner-only. |
| `src/extensions/BonkerPresaleEthToCreator.sol:102` | Default Bonker presale fee is owner-only. |
| `src/extensions/BonkerPresaleEthToCreator.sol:115` | Per-presale fee reduction is owner-only. |
| `src/extensions/BonkerPresaleEthToCreator.sol:137` | Presale fee recipient is owner-only. |
| `src/extensions/BonkerPresaleEthToCreator.sol:168` | `startPresale` is admin-only. |
| `src/extensions/BonkerPresaleEthToCreator.sol:280` | `endPresale` enforces presale-owner early ending and salt priority. |
| `src/extensions/BonkerPresaleEthToCreator.sol:517` | `claimEth` allows presale owner or contract owner, with owner constrained to the presale owner recipient. |

### Extension and Client Role Inputs

| File | Why it matters |
| --- | --- |
| `src/extensions/BonkerVault.sol:102` | Vault admin can transfer vault admin rights. |
| `src/extensions/BonkerVault.sol:121` | Anyone can call vault claim, but tokens transfer to the stored vault admin. |
| `src/extensions/BonkerAirdropV2.sol:97` | Airdrop admin can transfer airdrop admin rights. |
| `src/extensions/BonkerAirdropV2.sol:107` | Airdrop admin controls Merkle root updates under claim-safety constraints. |
| `src/extensions/BonkerAirdropV2.sol:136` | Airdrop admin can claim leftovers after claim expiration. |
| `src/lp-lockers/BonkerLpLockerFeeConversion.sol:102` | Factory-only liquidity placement stores reward admins and recipients. |
| `src/lp-lockers/BonkerLpLockerFeeConversion.sol:696` | Reward admin can update a reward recipient for one slot. |
| `src/lp-lockers/BonkerLpLockerFeeConversion.sol:718` | Reward admin can update fee preference for one slot. |
| `src/lp-lockers/BonkerLpLockerFeeConversion.sol:742` | Reward admin can transfer reward admin rights for one slot. |
| `client/components/LaunchPage.jsx:423` | Public launch form sets `tokenAdmin` to the connected wallet. |
| `client/components/LaunchPage.jsx:441` | Public launch form sets LP reward admins from form/default wallet state. |
| `client/components/admin/abis.js:11` | Admin console ABI includes factory owner/admin write functions. |
| `client/components/admin/presaleConfig.js:51` | Admin presale builder sets `tokenAdmin` to the connected admin wallet. |
| `client/components/admin/presaleConfig.js:69` | Admin presale builder sets reward admins and recipients from form/default wallet state. |
| `client/components/admin/presaleConfig.js:88` | Admin presale start call stores `presaleOwner` from form/default wallet state. |
| `server/tokens.js:510` | Token poller persists `msgSender` as deployer and `tokenAdmin` as admin. |

## How It Works

### Shared `OwnerAdmins`

`OwnerAdmins` wraps OpenZeppelin `Ownable` with a second role map:

```text
owner()
  |
  |-- setAdmin(admin, enabled)
  |-- owner-only functions on each inheriting contract
  |
admins[addr] == true
  |
  |-- onlyAdmin functions
  |-- onlyOwnerOrAdmin functions
```

The important detail is that admins do not inherit owner powers. `onlyAdmin` does not accept `owner()` unless the owner is also added to `admins`. `onlyOwnerOrAdmin` accepts either. Each function chooses its own boundary.

The factory uses this split heavily. `setDeprecated` and `setTeamFeeRecipient` are owner-only. `claimTeamFees`, `setHook`, `setLocker`, `setMevModule`, and `setExtension` are owner-or-admin. That means operational wallets can keep launches configured and sweep protocol fee balances without being able to redirect the fee recipient or pause the factory.

### Factory Owner

The `Bonker` factory starts with `deprecated = true`, then deployment scripts enable modules and call `setDeprecated(false)`. Only the factory owner can flip that flag later. If the flag is true, `deployToken` reverts with `Deprecated`.

The factory owner also controls `teamFeeRecipient`. `claimTeamFees(token)` can be called by owner or admin, but it always transfers the factory's token balance to the current `teamFeeRecipient`. The caller cannot choose a recipient.

Factory module registration is delegated to owner-or-admin because it is operational. The factory still validates interfaces before setting hooks, lockers, MEV modules, or extensions. Registration is not ownership transfer; it only controls what future deployments may reference in `DeploymentConfig`.

### Factory Admins

Factory admins are addresses in the factory's `admins` mapping. They are managed by owner-only `setAdmin`.

In the admin console, the "Toggle Module" panel can call `setHook`, `setMevModule`, `setExtension`, `setLocker`, and `setAdmin` through the same factory ABI. The contract boundary still decides which connected wallet is authorized. A non-owner admin can run module toggles, but `setAdmin` itself remains owner-only because it is implemented in `OwnerAdmins`.

The same console exposes `claimTeamFees`. That call is intentionally available to admins because it does not let the caller redirect funds. It moves accumulated protocol fees from the factory balance to the configured team recipient.

### Pool Extension Allowlist Admins

`BonkerPoolExtensionAllowlist` is a separate contract with its own `OwnerAdmins` state. Its owner and admins are not automatically the same mapping as the factory's, even if deployment uses the same owner address.

`setPoolExtension(extension, enabled)` is owner-or-admin on the allowlist contract. This controls pool extension allowlisting, not factory extension allowlisting. Changing one allowlist does not update the other.

### Token Admins

`IBonker.TokenConfig.tokenAdmin` is chosen in the launch config. Public `/launch` sets it to the connected wallet. Admin-started presales also set it to the connected admin wallet when building the deployment config.

`BonkerToken` stores two admin values:

- `_originalAdmin` is immutable and set in the constructor.
- `_admin` is mutable and starts equal to `_originalAdmin`.

The current `_admin` can call `updateAdmin`, `updateImage`, and `updateMetadata`. Only `_originalAdmin` can call `verify`, even if current admin has been transferred. This distinction matters when adding UI for token verification or metadata edits: "current admin" and "original admin" are separate contract checks.

The token poller stores `TokenCreated.msgSender` as `deployer` and `TokenCreated.tokenAdmin` as `admin`. These can differ. The deployer is whoever called the factory or presale deployment flow; the admin is the address encoded into the token config.

### LP Reward Admins

LP fee recipient control is per reward slot. `LockerConfig.rewardAdmins`, `rewardRecipients`, and `rewardBps` are parallel arrays. `BonkerLpLockerFeeConversion.placeLiquidity` stores those arrays during factory deployment and rejects mismatched arrays, zero reward addresses, zero reward amounts, and reward BPS totals that do not sum to 10,000.

After deployment, each reward slot is controlled by its own `rewardAdmins[rewardIndex]` entry:

- `updateRewardRecipient(token, rewardIndex, newRecipient)` changes who receives future fees for that slot.
- `updateFeePreference(token, rewardIndex, newFeePreference)` changes whether that slot prefers Bonker token or paired token fees.
- `updateRewardAdmin(token, rewardIndex, newAdmin)` transfers control of that slot.

Reward admin authority does not grant token admin authority, factory admin authority, or access to another reward slot. It is scoped by token and reward index.

### Vault Admins

The vault extension stores `VaultData.admin` in `allocation[token].admin` when `receiveTokens` is called by the factory deployment flow.

The vault admin can transfer vault admin rights with `editAllocationAdmin`. The vault claim function has a different pattern: anyone can call `claim(token)` after lockup/vesting conditions allow a positive claim, but the transfer always goes to `allocation[token].admin`. The caller cannot redirect claimed tokens.

This makes vault claiming permissionless while keeping value routing admin-bound.

### Airdrop Admins

The airdrop extension stores `AirdropData.admin` per token. That admin can transfer admin rights, update the Merkle root under strict conditions, and claim leftovers after `adminClaimTime`.

`updateMerkleRoot` is intentionally constrained. The admin must be the caller, no user claims can have happened, the admin cannot already have claimed leftovers, and an already-nonzero root can only be overwritten after the zero-claim overwrite interval. That prevents an admin from changing the claim set after participants have started claiming.

### Presale Contract Owner, Presale Admins, and Presale Owners

`BonkerPresaleEthToCreator` also inherits `OwnerAdmins`, but its roles have presale-specific meanings.

The contract owner controls protocol-level presale settings:

- enabled allowlist contracts;
- minimum lockup duration;
- default Bonker fee;
- per-presale fee reductions;
- Bonker fee recipient.

Contract admins can call `startPresale`. This creates a `Presale` struct with a stored `presaleOwner`. The admin that starts the presale is not automatically the presale owner unless the config passes the same address.

The stored `presaleOwner` controls sale-specific authority. If the sale is active and has reached the minimum goal, the presale owner can end it early. After the sale deadline, anyone can end a successful presale, but the presale owner gets `SALT_SET_BUFFER` priority to choose the deployment salt. During that buffer, non-owner callers hit `PresaleSaltBufferNotExpired`.

For ETH proceeds, `claimEth` accepts either the presale owner or the contract owner. If the contract owner calls, `recipient` must equal the stored presale owner. That lets protocol operations help finish a claim without redirecting sale proceeds.

## Invariants and Edge Cases

### Role Names Are Not Interchangeable

`admin` can mean factory admin, token admin, vault admin, airdrop admin, LP reward admin, or presale contract admin. Always check the contract and storage field. UI labels should avoid implying that one admin role grants another.

### Owner Is Not Automatically Admin Everywhere

`onlyAdmin` checks only `admins[msg.sender]`. If a contract owner needs to call an `onlyAdmin` function such as `startPresale`, the owner address must also be added as an admin on that contract.

`onlyOwnerOrAdmin` is different and accepts either role. Do not "simplify" these modifiers into one concept.

### Admin Mappings Are Per Contract

The factory, pool extension allowlist, and presale contract each have their own `admins` mapping. Adding an admin to the factory does not add that address to the presale contract or pool extension allowlist.

### Fee Claims Do Not Choose Recipients

Factory `claimTeamFees(token)` sends the full factory token balance to `teamFeeRecipient`. Vault `claim(token)` sends vested tokens to the stored vault admin. These functions can be callable by someone other than the recipient, but the recipient is fixed by contract state.

### Per-Launch Roles Are Captured at Deployment

Token admin, LP reward admins, LP reward recipients, vault admin, airdrop admin, and presale owner come from launch or presale config. Factory ownership does not rewrite those values after deployment. Each role must use its own transfer function if the responsible address changes later.

### Original Token Admin Cannot Be Reassigned

`BonkerToken.updateAdmin` changes current admin only. `verify` still requires `_originalAdmin`, which is immutable. Any UI or operational script that adds verification must read or reason about `originalAdmin`, not just `admin`.

### Reward Admin Scope Is Token Plus Index

LP reward admin functions index into arrays. The caller must match `rewardAdmins[rewardIndex]` for that token. Bad indexes revert through Solidity bounds checks. A reward admin for one slot has no authority over another slot.

### Presale Owner Has a Time Window, Not Exclusive Deployment Forever

After a successful presale deadline, the presale owner gets the salt-priority buffer. Once that buffer expires, another caller can end the presale with a salt if the presale is otherwise ready. This is intentional liveness protection, not a loss of presale owner proceeds.

### Contract Owner Assistance Cannot Redirect Presale ETH

When the presale contract owner calls `claimEth`, the recipient must be the stored `presaleOwner`. This prevents owner-assisted operational claims from becoming a custody bypass.

### Server and API Do Not Enforce These Roles

Express routes expose indexed data and read-only API responses. The admin console signs wallet transactions directly. Authorization happens in Solidity, so frontend and server changes must preserve ABI shape and call targets rather than inventing parallel access checks.

## Cross-References

- [ADMIN-OPERATIONS-CONSOLE](./ADMIN-OPERATIONS-CONSOLE.md)
- [CONTRACT-DEPLOYMENT-WORKFLOW](./CONTRACT-DEPLOYMENT-WORKFLOW.md)
- [LAUNCH-FORM-DEPLOYMENT-CONFIG](./LAUNCH-FORM-DEPLOYMENT-CONFIG.md)
- [PRESALE-LIFECYCLE](./PRESALE-LIFECYCLE.md)
- [TOKEN-DETAIL-ENRICHMENT](./TOKEN-DETAIL-ENRICHMENT.md)
- [SQLITE-PERSISTENCE-LIFECYCLE](./SQLITE-PERSISTENCE-LIFECYCLE.md)
