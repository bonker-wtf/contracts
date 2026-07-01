Fee escrow and claim model — how `BonkerFeeLocker` holds creator/reward-recipient fees and how the factory's separate protocol-fee path settles to the team; read this before changing `src/BonkerFeeLocker.sol`, the `claimTeamFees` path in `src/Bonker.sol`, depositor allowlisting in deploy scripts, or any code that calls `storeFees`/`claim`/`availableFees`.

This doc covers natural-language queries such as `BonkerFeeLocker`, `storeFees`, `claim(feeOwner, token)`, `availableFees`, `allowedDepositors`, `addDepositor`, `Unauthorized`, `NoFeesToClaim`, `feesToClaim` ledger, balance-delta accounting for fee-on-transfer tokens, `claimTeamFees`, `teamFeeRecipient`, `PROTOCOL_FEE_NUMERATOR`, and the difference between LP-fee claims and protocol-fee claims. Bonker has **two** unrelated fee-settlement mechanisms that are easy to confuse: a per-recipient escrow ledger (the FeeLocker) and a factory-balance sweep (protocol fees). This page is the map of which is which.

## Why it exists

Bonker forks Clanker so the protocol fee flows to us instead of Clanker (see the project `CLAUDE.md` "Fee Flow" table). That economic claim resolves into two separate on-chain paths, and a maintainer changing one must not assume it touches the other.

The FeeLocker exists because LP fees and MEV-auction proceeds are owed to **many** addresses (the per-token reward recipients), and those addresses should pull their own funds on their own schedule. A push model — transferring to each recipient inside the swap/fee-collection path — would be gas-heavy and would let a reverting recipient brick fee collection for everyone. So the lockers and MEV modules **deposit** into a shared escrow keyed by `(feeOwner, token)`, and recipients **claim** later. The factory protocol fee, by contrast, is owed to exactly one address (`teamFeeRecipient`), so it needs no ledger — it just accumulates as the factory's own token balance and gets swept on demand.

## Key files

| Anchor | Role |
|--------|------|
| `src/BonkerFeeLocker.sol:16` | `feesToClaim[feeOwner][token]` — the escrow ledger mapping. |
| `src/BonkerFeeLocker.sol:17` | `allowedDepositors[depositor]` — authorization set for `storeFees`. |
| `src/BonkerFeeLocker.sol:21` | `addDepositor()` — owner-only; whitelists a locker/MEV module. |
| `src/BonkerFeeLocker.sol:26` | `storeFees()` — pulls tokens in, credits the ledger via balance delta. |
| `src/BonkerFeeLocker.sol:41` | `availableFees()` — read-only ledger balance for `(feeOwner, token)`. |
| `src/BonkerFeeLocker.sol:46` | `claim()` — debits the ledger, transfers to `feeOwner`. |
| `src/interfaces/IBonkerFeeLocker.sol` | Interface, errors (`Unauthorized`, `NoFeesToClaim`), and events. |
| `src/Bonker.sol:49` | `teamFeeRecipient` — single recipient of factory protocol fees. |
| `src/Bonker.sol:73` | `setTeamFeeRecipient()` — owner-only recipient update. |
| `src/Bonker.sol:81` | `claimTeamFees()` — sweeps the factory's full token balance to the recipient. |
| `src/lp-lockers/BonkerLpLockerFeeConversion.sol:478` | A `storeFees` deposit site (per reward recipient). |
| `src/mev-modules/BonkerSniperAuctionV2.sol:344` | MEV-auction proceeds deposited per reward recipient. |
| `script/DeployStep2.s.sol:71` | `addDepositor(mevModule)` at deploy time. |

## Path A — the FeeLocker escrow ledger

This path handles LP fees (via the LP locker) and sniper-auction proceeds (via the MEV modules). Both end up as WETH (or the configured reward token) credited to per-token reward recipients.

### Deposit (`storeFees`)

Only an address in `allowedDepositors` may call `storeFees(feeOwner, token, amount)` — otherwise it reverts with `Unauthorized()`. The allowed depositors are wired during deployment: `addDepositor(address(lpLocker))` and `addDepositor(address(mevModule))` (see `script/DeployStep2.s.sol:71`, `script/DeployLpLocker.s.sol:46`, and the redeploy script). The FeeLocker owner is the only one who can extend this set.

A depositor first `forceApprove`s the FeeLocker for the amount, then calls `storeFees`. The locker calls it once per reward recipient, splitting the collected fee by `rewardBps` (`BonkerLpLockerFeeConversion.sol:478`–`494`).

`storeFees` credits the ledger using a **balance delta**, not the declared `amount`:

```text
balanceBefore = token.balanceOf(this)
safeTransferFrom(token, msg.sender, this, amount)
balanceAfter  = token.balanceOf(this)
feesToClaim[feeOwner][token] += (balanceAfter - balanceBefore)
```

This is deliberate (see the inline comment at `src/BonkerFeeLocker.sol:29`): it makes the ledger correct for fee-on-transfer and other non-standard ERC20s, where the contract receives less than `amount`. Crediting the declared `amount` would over-credit the ledger and eventually let claims drain funds owed to other recipients. The `StoreTokens` event carries both the new running `balance` and the original `amount`.

### Claim (`claim`)

`claim(feeOwner, token)` is **permissionless to call** but always pays `feeOwner` — anyone can trigger a claim on a recipient's behalf, and the funds can only go to that recipient. It reads `feesToClaim[feeOwner][token]`, reverts with `NoFeesToClaim()` if zero, zeroes the ledger entry **before** transferring (checks-effects-interactions), then `safeTransfer`s the balance and emits `ClaimTokens`. The contract is `ReentrancyGuard`, so both `storeFees` and `claim` are `nonReentrant`.

In the project `CLAUDE.md` "Fee Flow" table this is the row `feeLocker.claim(owner, WETH) → token creator (reward recipient)`. The deployed FeeLocker is at `0x473e52D89bE6ea78f94d1b5c62Bd1f01b1E32e21`.

## Path B — the factory protocol-fee sweep

The protocol fee is taken by the hooks during swaps and accumulates **as the factory contract's own token balance** — the hooks collect protocol-fee deltas into the factory (see [HOOK-FEE-ACCOUNTING](./HOOK-FEE-ACCOUNTING.md) for how the swap-delta math derives the protocol fee using `PROTOCOL_FEE_NUMERATOR = 200_000`, identical to Clanker). There is no per-recipient ledger here because there is exactly one beneficiary.

`claimTeamFees(token)` (`src/Bonker.sol:81`) is `onlyOwnerOrAdmin`. It reverts with `TeamFeeRecipientNotSet()` if `teamFeeRecipient` is the zero address, then transfers the factory's **entire** `balanceOf` for that token to `teamFeeRecipient` and emits `ClaimTeamFees`. Because it sweeps the full balance rather than a tracked amount, the factory must never hold protocol-fee tokens it does not intend to pay out to the team. The recipient is updated via `setTeamFeeRecipient` (owner-only) and is the `TEAM_FEE_RECIPIENT` constant `0x1750d61A438aE6317b2Ee7De0A16201F68530C8F` set at deploy time.

## A vs B at a glance

```text
LP fees / MEV proceeds                 Protocol fees
─────────────────────                  ─────────────
hook collects LP fee                   hook collects protocol fee
  → LP locker / MEV module               → factory's own token balance
  → storeFees(recipient, token, amt)   claimTeamFees(token)  [owner/admin]
  → feesToClaim[recipient][token] += d   → sweeps full factory balance
recipient: claim(recipient, token)     → teamFeeRecipient
  → paid the ledger balance
many recipients, pull model            one recipient, sweep model
```

## Invariants and edge cases

- **Ledger solvency.** The sum of `feesToClaim[*][token]` must never exceed the FeeLocker's actual `token` balance. The balance-delta crediting in `storeFees` is what preserves this for non-standard tokens; do not "optimize" it back to crediting the declared `amount`.
- **Depositor allowlist is the only write gate.** A bug that lets an arbitrary caller pass the `allowedDepositors` check would let attackers credit themselves and drain the escrow. Any new depositor must be added through `addDepositor` by the owner, and new lockers/MEV modules must be allowlisted in the deploy/redeploy scripts (`DeployStep2.s.sol`, `RedeployStep2.s.sol`, `DeployLpLocker.s.sol`) or their deposits will revert `Unauthorized()`.
- **Claim cannot be redirected.** `claim` always sends to `feeOwner`; the caller identity is irrelevant. The permissioned-claim event `ClaimTokensPermissioned` is declared in the interface but the current implementation only emits `ClaimTokens`.
- **`claimTeamFees` sweeps everything.** It does not track a per-token accrued amount; it pays out the whole factory balance. If the factory ever holds a token for a reason other than protocol fees, that balance would also be swept.
- **Two paths, two owners' concerns.** Changing `teamFeeRecipient` does not affect FeeLocker claims, and adding a FeeLocker depositor does not affect protocol-fee settlement. Keep them decoupled; do not collapse them into one "fees" abstraction.
- **Versioning.** `BonkerFeeLocker` exposes `BONKER_VERSION = 2` and `BONKER_PROTOCOL_ID = keccak256("bonker.wtf")`, and `supportsInterface` returns true only for `IBonkerFeeLocker`.

## Cross-references

- [HOOK-FEE-ACCOUNTING](./HOOK-FEE-ACCOUNTING.md) — how the hooks split LP vs protocol fees and collect protocol fees into the factory balance that `claimTeamFees` later sweeps.
- [LP-LOCKER-FEE-CONVERSION-LIFECYCLE](./LP-LOCKER-FEE-CONVERSION-LIFECYCLE.md) — how the LP locker collects position fees, applies reward splits, and deposits into the FeeLocker via `storeFees`.
- [MEV-MODULE-LIFECYCLE](./MEV-MODULE-LIFECYCLE.md) — how sniper-auction proceeds reach reward recipients through the same `storeFees` escrow.
- [OWNER-ADMIN-PERMISSION-MODEL](./OWNER-ADMIN-PERMISSION-MODEL.md) — the `onlyOwner` / `onlyOwnerOrAdmin` gating behind `addDepositor`, `setTeamFeeRecipient`, and `claimTeamFees`.
- [OWNERSHIP-TRANSFER-SCRIPT](./OWNERSHIP-TRANSFER-SCRIPT.md) — how owner handoff interacts with `availableFees` and fee-recipient migration.
- [CONTRACT-CONFIG-TOPOLOGY](./CONTRACT-CONFIG-TOPOLOGY.md) — deployed FeeLocker/Factory addresses and where each is referenced.
