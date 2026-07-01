Airdrop extension lifecycle explains how Bonker reserves token supply for Merkle-based airdrops, how live `BonkerAirdropV2` differs from legacy `BonkerAirdrop`, and when to read this before changing launch airdrop encoding, admin Merkle-root updates, airdrop claims, token-detail enrichment, or deployment scripts.

This page covers natural-language queries such as `BonkerAirdropV2`, `AirdropV2ExtensionData`, `updateMerkleRoot`, `adminClaim`, `CLAIM_EXPIRATION_INTERVAL`, `ZERO_CLAIM_OVERWRITE_INTERVAL`, "why can the airdrop Merkle root be zero", "which airdrop contract is deployed", "why do tests still instantiate BonkerAirdrop", and "how does airdrop vesting match amountAvailableToClaim". It focuses on the airdrop extension itself. The shared factory extension boundary, launch form deployment config, token-detail enrichment, and owner/admin model are covered by nearby docs.

## Why It Exists

Bonker lets a launch reserve part of the 100B token supply for an allowlisted airdrop. The factory does the supply accounting, then calls an enabled airdrop extension during `Bonker.deployToken`. The extension pulls its reserved tokens from the factory, stores a Merkle root, and later lets claimers prove `(recipient, allocatedAmount)` against that root.

That solves a launch UX problem: the deployer can ship an airdrop allocation atomically with the token and pool, instead of holding a separate wallet balance and distributing manually. It also lets the token detail page show airdrop supply, claimed amount, unlock time, and vesting time from on-chain state.

The sharp edge is version drift. The repo keeps both `BonkerAirdrop` and `BonkerAirdropV2`. Production deploy scripts, client addresses, and verification point at `BonkerAirdropV2`, while several regression tests still instantiate the legacy contract. V1 and V2 share the same Merkle proof and vesting math, but V2 adds an airdrop admin, deferred Merkle-root setup, root overwrite constraints, and leftover admin claims.

Writing the split down matters because callers must encode the V2 tuple shape. A V1 payload omits `admin`; a V2 payload includes it. A route or UI that reads V2 storage using a V1 ABI can silently mislabel fields because public mapping getters return tuple fields positionally.

## Key Files

| File | Why it matters |
| --- | --- |
| `src/extensions/BonkerAirdropV2.sol:18` | Declares the live airdrop extension and its Bonker version markers. |
| `src/extensions/BonkerAirdropV2.sol:25` | Defines minimum lockup, claim expiration, and zero-claim overwrite intervals. |
| `src/extensions/BonkerAirdropV2.sol:38` | `receiveTokens()` decodes `AirdropV2ExtensionData`, validates launch config except the deferred root, stores airdrop state, and pulls reserved supply. |
| `src/extensions/BonkerAirdropV2.sol:97` | `updateAdmin()` lets the current airdrop admin transfer admin rights. |
| `src/extensions/BonkerAirdropV2.sol:107` | `updateMerkleRoot()` lets the admin set or replace the root only before claims and under timing constraints. |
| `src/extensions/BonkerAirdropV2.sol:138` | `adminClaim()` lets the admin sweep unclaimed supply after the claim window ends. |
| `src/extensions/BonkerAirdropV2.sol:153` | `claim()` verifies the Merkle proof, applies lockup and vesting, records claimed amounts, and transfers tokens. |
| `src/extensions/BonkerAirdropV2.sol:230` | `amountAvailableToClaim()` exposes the same vesting math as `claim()` without checking the Merkle proof. |
| `src/extensions/interfaces/IBonkerAirdropV2.sol:7` | Defines `AirdropV2ExtensionData` with `admin`, `merkleRoot`, `lockupDuration`, and `vestingDuration`. |
| `src/extensions/interfaces/IBonkerAirdropV2.sol:14` | Defines the stored `AirdropV2` fields returned by the public `airdrops(token)` getter. |
| `src/extensions/BonkerAirdrop.sol:23` | Legacy V1 airdrop contract that remains in the tree and in regression tests. |
| `src/extensions/interfaces/IBonkerAirdrop.sol:7` | Legacy `AirdropExtensionData` shape without `admin`. |
| `script/DeployStep2.s.sol:65` | Fresh deployment path constructs `BonkerAirdropV2`; `:81` enables it on the factory. |
| `script/RedeployStep2.s.sol:63` | Partial redeploy path also constructs `BonkerAirdropV2`. |
| `client/config/contracts.js:7` | Client source of truth for the deployed `AIRDROP` address. |
| `client/components/LaunchPage.jsx:372` | Public launch form encodes the V2 airdrop tuple and appends it to `extensionConfigs`. |
| `client/components/admin/presaleConfig.js:110` | Admin presale form encodes a V2 airdrop placeholder before the presale extension. |
| `server/tokens.js:80` | Token-detail enrichment declares the ABI used to read `airdrops(token)`. |
| `server/tokens.js:263` | Token-detail enrichment reads airdrop on-chain state only when the token launch included the deployed airdrop extension. |
| `client/components/TokenDetailPage.jsx:427` | Token detail renders the enriched airdrop supply, unlock, vesting, and claimed fields. |
| `test/BonkerExtensionVesting.t.sol:219` | Legacy V1 vesting test checks that `amountAvailableToClaim()` and `claim()` stay aligned. |
| `test/BonkerLegacyErc20Safety.t.sol:114` | Legacy V1 compatibility test confirms SafeERC20 behavior with no-return tokens. |

## How It Works

### Launch-Time Reservation

The airdrop starts as one entry in `IBonker.ExtensionConfig[]`. The factory computes `extensionSupply` from `extensionBps` against the full token supply, keeps that slice out of pool liquidity, and calls `receiveTokens()` on the enabled extension.

`BonkerAirdropV2.receiveTokens()` accepts only factory calls. It decodes `AirdropV2ExtensionData`, rejects nonzero ETH value, rejects zero `extensionBps`, rejects lockups shorter than `MIN_LOCKUP_DURATION`, stores timing and supply fields, then pulls the reserved token amount from the factory with `SafeERC20.safeTransferFrom()`.

The V2 extension data shape is:

```text
AirdropV2ExtensionData
  admin: address
  merkleRoot: bytes32
  lockupDuration: uint256
  vestingDuration: uint256
```

That differs from legacy `AirdropExtensionData`, which has no `admin` field and rejects a zero Merkle root during `receiveTokens()`.

### Public Launch Form

`LaunchPage` builds the Merkle root in the browser from a CSV of `address,amount` rows using the same double-hashed ABI-encoded leaves that `BonkerAirdropV2.claim()` verifies; see [MERKLE-ROOT-PROOF-BOUNDARY](./MERKLE-ROOT-PROOF-BOUNDARY.md).

The public launch form sets `admin` to the connected wallet. That means the launcher can later update the root, transfer airdrop admin rights, or claim leftovers after the claim window. The form offers airdrop lockup options starting at `7 days`, safely above the live V2 contract minimum of `1 days`; any launch with a shorter encoded lockup reverts at the extension boundary.

### Admin Presale Form

`AdminPage` can include an airdrop extension before the presale extension. The presale extension must be last, so the admin form appends optional airdrop first and presale second.

The admin presale form encodes a V2 tuple with `admin` set to the connected wallet and `merkleRoot` set to zero. V2 permits deferred root setup because it does not reject a zero root in `receiveTokens()`. The admin is expected to call `updateMerkleRoot()` later before claimers can prove allocations.

The same minimum lockup invariant still applies. A placeholder Merkle root is allowed; a too-short lockup is not.

### Claim Flow

Claimers call `claim(token, recipient, allocatedAmount, proof)`. The caller does not need to equal `recipient`; value always transfers to `recipient`.

The function checks that the airdrop exists, the admin has not swept leftovers, the lockup has passed, the user has a nonzero allocation, total supply remains, and the Merkle proof verifies against `keccak256(bytes.concat(keccak256(abi.encode(recipient, allocatedAmount))))`.

After proof verification, V2 reads `amountClaimed[recipient]`, computes the currently vested unclaimed amount, caps the claim so `totalClaimed` cannot exceed `totalSupply`, updates both user and total claimed counters, then transfers tokens to the recipient.

The vesting math is linear after lockup:

```text
before lockupEndTime:
  amountAvailableToClaim = 0

between lockupEndTime and vestingEndTime:
  allocatedAmount * (now - lockupEndTime) / (vestingEndTime - lockupEndTime)
  minus amount already claimed

after vestingEndTime:
  allocatedAmount minus amount already claimed
```

`amountAvailableToClaim()` exposes that math as a view, but it assumes the caller already has a valid proof for the supplied allocation. It is a vesting preview, not an allowlist verifier.

### Admin Root Updates

V2 introduces an `admin` address per token airdrop. Only that address can call `updateAdmin()`, `updateMerkleRoot()`, and `adminClaim()`.

`updateMerkleRoot()` is intentionally narrow. The admin cannot update after any user claim, cannot update after the admin has swept leftovers, and cannot replace a nonzero root immediately after unlock. A nonzero root can be replaced only after `lockupEndTime + ZERO_CLAIM_OVERWRITE_INTERVAL` when zero claims have occurred.

This creates two intended paths:

- deferred setup: start with a zero root, then set the real root before claims;
- failed launch correction: if a nonzero root was wrong and nobody claimed, wait through the overwrite interval and replace it.

Because claims are blocked while `merkleRoot == bytes32(0)`, a deferred-root airdrop is inert until the admin sets a nonzero root.

### Admin Leftover Claim

V2 sets `adminClaimTime` to lockup plus vesting plus `CLAIM_EXPIRATION_INTERVAL`. After that timestamp, the airdrop admin can call `adminClaim(token, recipient)` once.

The function marks `adminClaimed = true` and transfers `totalSupply - totalClaimed` to the requested recipient. Future user claims and `amountAvailableToClaim()` calls revert with `AdminClaimed()`. This gives the airdrop a finite claim window instead of leaving dust or unclaimed allocations locked forever.

### Token Detail Enrichment

The token indexer stores extension addresses from `TokenCreated`. On `/api/tokens/:address`, `enrichWithOnChainData()` checks whether any emitted extension address maps to the `airdrop` feature in `server/contract-features.js`. If so, it reads `airdrops(token)` from that emitted extension address and adds `features.airdrop`.

`TokenDetailPage` renders that feature as an active airdrop with total supply, claimed supply, unlock time, and vesting end time. It does not render claim UI or Merkle proofs; it is an inspection surface.

The ABI used for the public mapping getter must match the deployed contract's tuple order. V2 storage includes `admin` before `merkleRoot` and also includes `adminClaimTime` and `adminClaimed`; a V1-shaped ABI omits those fields. Keep that in mind when changing `server/tokens.js` enrichment or adding more airdrop fields to the API.

## V1 Versus V2

| Aspect | `BonkerAirdrop` legacy V1 | `BonkerAirdropV2` live |
| --- | --- | --- |
| Deployed by current scripts | No | Yes |
| Extension data | `(merkleRoot, lockupDuration, vestingDuration)` | `(admin, merkleRoot, lockupDuration, vestingDuration)` |
| Zero Merkle root at launch | Reverts `InvalidMerkleRoot()` | Allowed, but claims are blocked until updated |
| Airdrop admin | None | Per-token `admin` |
| Root update | None | `updateMerkleRoot()` before claims and under overwrite rules |
| Leftover sweep | None | `adminClaim()` after `CLAIM_EXPIRATION_INTERVAL` |
| Version markers | None | `BONKER_VERSION = 2`, `BONKER_PROTOCOL_ID = keccak256("bonker.wtf")` |
| Shared behavior | Merkle proof claims, lockup, linear vesting, SafeERC20 transfers | Same claim and vesting model with admin guards |

The legacy contract remains useful because tests still exercise the shared vesting and SafeERC20 semantics there. Do not infer from those tests that V1 is production-enabled. Current deploy scripts construct V2, the client `AIRDROP` constant points to the V2 deployment, and `scripts/verify-all.sh` verifies `src/extensions/BonkerAirdropV2.sol:BonkerAirdropV2`.

## Invariants And Edge Cases

### The Factory Is The Only Initializer

`receiveTokens()` is `onlyFactory`. Airdrop state should be initialized through `Bonker.deployToken`, not by sending tokens directly to the extension. Direct token transfers do not create `airdrops[token]` state and cannot be claimed through the Merkle path.

### Extension BPS Reserves Real Supply

The airdrop receives `extensionSupply` from the factory. If `extensionBps` is too high, pool liquidity shrinks accordingly. If it is zero, V2 reverts `InvalidAirdropPercentage()`.

### Lockup Must Be At Least One Day

Both V1 and V2 require `lockupDuration >= MIN_LOCKUP_DURATION`. UI defaults or admin placeholders that encode `0` will not pass the contract check.

### Zero Root Means Deferred, Not Claimable

V2 permits a zero Merkle root at setup so an admin can attach the claim set later. Claims still require `merkleRoot != bytes32(0)`, so zero-root airdrops show as unclaimable until the root is updated.

### Root Replacement Stops After Claims

Once `totalClaimed > 0`, `updateMerkleRoot()` reverts `AirdropClaimsOccurred()`. This protects claimers from the admin changing the distribution after anyone has used the original tree.

### Admin Claim Ends User Claims

After `adminClaim()`, V2 sets `adminClaimed = true`. User claims and claimable previews revert. UI or API code should treat `adminClaimed` as terminal for the airdrop claim window if it starts exposing that field.

### Public Mapping Getter Order Matters

The `airdrops(token)` getter returns fields in struct order. V2 order starts with `admin`, then `merkleRoot`, `totalSupply`, `totalClaimed`, `lockupEndTime`, `vestingEndTime`, `adminClaimTime`, and `adminClaimed`. A V1 ABI starts with `merkleRoot`. Using the wrong ABI does not change contract state, but it can make off-chain data wrong.

### Amounts Are Relative To The Merkle Tree

The contract does not know the full CSV. It only knows `totalSupply`, `totalClaimed`, each recipient's claimed amount, and whether a submitted `(recipient, allocatedAmount)` pair proves against the root. If the tree encodes allocations that sum above the reserved supply, claims are capped by remaining `totalSupply`, and late claimers may receive less or revert once the cap is exhausted.

### Claim Caller Does Not Receive Tokens

Anyone can submit a valid proof for a recipient, but `SafeERC20.safeTransfer()` pays `recipient`. This allows helper claims without making the helper a custodian.

## Cross-References

- [FACTORY-EXTENSION-LIFECYCLE](./FACTORY-EXTENSION-LIFECYCLE.md) for the shared `ExtensionConfig[]`, supply reservation, ETH forwarding, and extension callback order.
- [LAUNCH-FORM-DEPLOYMENT-CONFIG](./LAUNCH-FORM-DEPLOYMENT-CONFIG.md) for how `/launch` builds `DeploymentConfig`, including extension encoding and wallet submission.
- [ADMIN-OPERATIONS-CONSOLE](./ADMIN-OPERATIONS-CONSOLE.md) for admin presale creation, optional airdrop ordering, and factory module toggles.
- [OWNER-ADMIN-PERMISSION-MODEL](./OWNER-ADMIN-PERMISSION-MODEL.md) for how airdrop admin differs from factory owner, factory admin, token admin, vault admin, and presale owner.
- [TOKEN-DETAIL-ENRICHMENT](./TOKEN-DETAIL-ENRICHMENT.md) for request-time reads that add airdrop state to `/api/tokens/:address`.
- [FOUNDRY-REGRESSION-SUITE](./FOUNDRY-REGRESSION-SUITE.md) for the Solidity tests that protect vesting math and non-standard ERC20 transfer compatibility.
- [CONTRACT-DEPLOYMENT-WORKFLOW](./CONTRACT-DEPLOYMENT-WORKFLOW.md) for the scripts that deploy and enable `BonkerAirdropV2` on the factory.
