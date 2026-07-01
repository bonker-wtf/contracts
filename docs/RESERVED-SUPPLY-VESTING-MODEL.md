# Reserved-Supply Vesting Model

This doc explains the shared **cliff lockup + linear vesting** schedule that Bonker's reserved-supply extensions — `BonkerVault`, `BonkerAirdrop`, `BonkerAirdropV2`, and `BonkerPresaleEthToCreator` — each reimplement independently. Read it before changing any `_getAmountToClaim` / `_getAmountClaimable` math, the `lockupEndTime` / `vestingEndTime` time anchors, `MIN_LOCKUP_DURATION`, or the launch encoding of `lockupDuration` / `vestingDuration`. It is the cross-cutting companion to the per-extension lifecycle docs, which describe each contract's full flow; here we isolate just the vesting formula and the four contracts' divergences so a maintainer can reason about all of them at once.

## Why it exists

Several extensions hold a slice of a token's 100B supply and release it over time instead of all at once: the team `BonkerVault`, the Merkle `BonkerAirdrop`/`BonkerAirdropV2`, and the per-buyer `BonkerPresaleEthToCreator` allocation. They share an identical economic intent — "nothing for a lockup period, then a straight-line drip until fully vested" — but there is **no shared library**. Each contract carries its own copy of the two-phase formula. That duplication is easy to break in one place and not the others, so the invariant ("the four schedules behave the same, except where deliberately different") only lives in the code, not in one spot. This doc is that spot.

## Key files

| Anchor | Role |
|---|---|
| `src/extensions/BonkerVault.sol:141` | `_getAmountToClaim` — vault two-phase formula |
| `src/extensions/BonkerVault.sol:77` | `Allocation` set: `lockupEndTime`, `vestingEndTime = lockupEndTime + vestingDuration` |
| `src/extensions/BonkerVault.sol:23` | `MIN_LOCKUP_DURATION = 7 days` (vault is the strict one) |
| `src/extensions/BonkerAirdropV2.sol:247` | `_getAmountClaimable` — per-recipient airdrop formula |
| `src/extensions/BonkerAirdropV2.sol:71` | lockup/vesting/`adminClaimTime` anchors set in `receiveTokens` |
| `src/extensions/BonkerAirdropV2.sol:25` | `MIN_LOCKUP_DURATION = 1 days`, `CLAIM_EXPIRATION_INTERVAL = 14 days`, `ZERO_CLAIM_OVERWRITE_INTERVAL = 1 days` |
| `src/extensions/BonkerAirdropV2.sol:138` | `adminClaim` — sweep unclaimed dust after `adminClaimTime` |
| `src/extensions/BonkerAirdrop.sol:205` | legacy `_getAmountClaimable` — identical math, no `adminClaim` |
| `src/extensions/BonkerPresaleEthToCreator.sol:488` | `_getAmountClaimable` — per-buyer formula keyed on ETH contribution |
| `src/extensions/BonkerPresaleEthToCreator.sol:323` | clock anchors set at **token deployment**, not presale creation |

## The two-phase formula

Every schedule is defined by two timestamps anchored at the moment the token's supply is handed to the extension:

```text
lockupEndTime  = anchorTime + lockupDuration
vestingEndTime = lockupEndTime + vestingDuration
```

The claimable amount at the current block is a pure function of those two anchors, the total allocation, and what the claimant already took:

```text
if  now <  lockupEndTime   -> 0                                    (cliff: nothing)
if  now >= vestingEndTime  -> total - alreadyClaimed              (fully vested: remainder)
else                       -> total * (now - lockupEndTime)
                                     / (vestingEndTime - lockupEndTime)
                             - alreadyClaimed                       (linear drip)
```

The lockup is a hard cliff: zero is claimable until it passes, then vesting starts from zero and rises linearly. `alreadyClaimed` is subtracted last so partial claims don't reset the curve — each claim takes only the newly-vested delta. This is the effective schedule exposed by `BonkerVault.sol:141`, `BonkerAirdropV2.sol:247`, and `BonkerAirdrop.sol:205`.

### What the "total" is keyed on

The formula is the same; only the unit differs per contract.

- **Vault** — one allocation per token, total = `amountTotal`, claimed = `amountClaimed`, paid to the single `admin`. Anyone may call `claim`, but tokens always route to the registered admin (`BonkerVault.sol:121`).
- **Airdrop / AirdropV2** — total = each recipient's Merkle `allocatedAmount`, claimed = `amountClaimed[recipient]`. The curve runs per-recipient against the same shared `lockupEndTime`/`vestingEndTime`. A valid Merkle proof gates every claim.
- **Presale** — the vested unit is the buyer's **ETH contribution** (`presaleBuys[presaleId][user]`), not tokens. The vested ETH fraction is computed first, then converted to tokens pro-rata via `tokenSupply * ethBuyInAmount / ethRaised` at `BonkerPresaleEthToCreator.sol:457`.

## Where the contracts deliberately diverge

These are intentional differences — do not "normalize" them without understanding why.

### Minimum lockup floor

`BonkerVault` enforces `MIN_LOCKUP_DURATION = 7 days` (`BonkerVault.sol:23`); both airdrop variants enforce `1 days` (`BonkerAirdropV2.sol:25`, `BonkerAirdrop.sol:27`). The vault holds team supply, so it carries the stricter floor. The launch UI must mirror whichever floor applies — see the memory note that the vault form must never offer a lockup below 7 days.

### Presale divides by `vestingDuration`, the others by the anchor delta

The presale formula at `BonkerPresaleEthToCreator.sol:504` divides by `vestingDuration` directly, while vault/airdrop divide by `(vestingEndTime - lockupEndTime)`. These are algebraically identical because `vestingEndTime = lockupEndTime + vestingDuration`. Keep them in sync if you ever touch one — they must stay equal.

### Admin dust sweep (AirdropV2 only)

AirdropV2 adds a third anchor, `adminClaimTime = lockupEnd + vestingDuration + CLAIM_EXPIRATION_INTERVAL (14 days)` (`BonkerAirdropV2.sol:74`). After it passes, `adminClaim` (`BonkerAirdropV2.sol:138`) lets the admin sweep `totalSupply - totalClaimed` — the unclaimed remainder from recipients who never showed up. Legacy `BonkerAirdrop` has no such sweep; its unclaimed supply is stranded. AirdropV2 also allows a Merkle-root rewrite before any claim, or after `ZERO_CLAIM_OVERWRITE_INTERVAL` with zero claims (`BonkerAirdropV2.sol:120`).

### When the clock starts

Vault and airdrop anchor at `receiveTokens`, i.e. token-deployment time inside `Bonker.deployToken`. The presale anchors later: `lockupEndTime`/`vestingEndTime` are set in the deploy/salt-set path at `BonkerPresaleEthToCreator.sol:323`, after the presale settles and the token is actually deployed — so a presale buyer's lockup begins at token deployment, consistent with the others, not at contribution time.

## Invariants and edge cases

- **`vestingDuration == 0` is a pure cliff, not a division by zero.** When vesting is zero, `vestingEndTime == lockupEndTime`. The `now >= vestingEndTime` branch is checked before the dividing branch, so once the lockup passes the full remainder is returned and the `/ (vestingEndTime - lockupEndTime)` (or `/ vestingDuration`) line is never reached. Preserve the branch ordering if you refactor.
- **Monotonic claims.** `alreadyClaimed` is added to (vault `amountClaimed`, airdrop `amountClaimed[recipient]`, presale `presaleClaimed[presaleId][user]`) on every successful claim and subtracted from the vested figure, so re-claiming in the same block yields zero and the schedule never over-pays.
- **Caps at the total.** AirdropV2 additionally clamps a claim to `totalSupply - totalClaimed` (`BonkerAirdropV2.sol:203`) so rounding in the per-recipient curve can never drain more than the pool holds.
- **Single allocation per token (vault).** `BonkerVault.sol:75` reverts if `lockupEndTime != 0`, using the anchor itself as the "exists" flag — a zero `lockupEndTime` means "no allocation". Don't introduce a legitimate zero anchor.
- **Server enrichment reads these anchors.** `/api/tokens/:address` surfaces vault/airdrop lockup and vesting end dates; keep the field meanings aligned with the on-chain anchors when changing either side.

## Cross-references

- [VAULT-EXTENSION-LIFECYCLE](./VAULT-EXTENSION-LIFECYCLE.md) — full vault flow, admin transfer, token-detail enrichment.
- [AIRDROP-EXTENSION-LIFECYCLE](./AIRDROP-EXTENSION-LIFECYCLE.md) — Merkle root updates, V2-vs-legacy behavior, claim timing.
- [PRESALE-LIFECYCLE](./PRESALE-LIFECYCLE.md) — presale settlement, deployment, and the claim path that consumes this curve.
- [PRESALE-ALLOWLIST-LIFECYCLE](./PRESALE-ALLOWLIST-LIFECYCLE.md) — buyer caps and Merkle gating layered on top of presale contributions.
- [FACTORY-EXTENSION-LIFECYCLE](./FACTORY-EXTENSION-LIFECYCLE.md) — how `receiveTokens` supply reservation feeds these allocations during `deployToken`.
- [DEPLOYTOKEN-CALLDATA-SCHEMA](./DEPLOYTOKEN-CALLDATA-SCHEMA.md) — where `lockupDuration` / `vestingDuration` sit in the launch `extensionData` payloads.
