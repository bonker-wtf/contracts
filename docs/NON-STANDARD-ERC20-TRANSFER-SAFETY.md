Non-standard ERC20 transfer safety explains how Bonker tolerates tokens that omit boolean return values, fee-on-transfer tokens in fee escrow, and temporary Permit2 approval paths; read this before replacing `SafeERC20`, changing `forceApprove`, editing token movement in extensions, lockers, MEV modules, FeeLocker, or modifying `BonkerLegacyErc20Safety.t.sol`.

This page answers natural-language queries such as `MockTokenNoReturn`, `MockFeeOnTransferERC20`, `SafeERC20.safeTransferFrom`, `SafeERC20.forceApprove`, `storeFees tracks actual amount received`, "why does a token transfer without bool still work", "why does FeeLocker use balance deltas", "why are Permit2 approvals timestamp-limited", and "which Bonker contracts touch third-party ERC20s". The core rule is: **any contract path that moves a token it did not just deploy must assume ERC20 behavior may be weird, and the accounting path must measure reality instead of trusting the requested amount.**

## Why It Exists

Bonker deploys its own `BonkerToken`, but the protocol does not only move that token. The factory, hooks, LP lockers, extensions, presale contract, and MEV auction also touch WETH, paired tokens, routed swap outputs, reward currencies, and arbitrary ERC20 balances that can land in emergency withdrawal paths.

The common failure mode is small but expensive: a Solidity call through `IERC20.transfer(...)` expects a `bool` return. Older tokens and wrappers sometimes return no data. Raw interface calls to those tokens can revert during ABI decoding even when the token moved correctly. The result would be a launch, claim, LP placement, dev buy, or fee distribution path that fails only with a real-world token variant.

OpenZeppelin `SafeERC20` is the compatibility boundary for those no-return tokens. It treats empty return data as success, bubbles real reverts, and rejects explicit `false` returns. Bonker uses it on token transfers and approvals throughout protocol-owned token flows.

There is a second class of weird token behavior: fee-on-transfer. `SafeERC20` confirms the transfer call succeeded, but it cannot guarantee that the receiver got the nominal `amount`. `BonkerFeeLocker.storeFees()` therefore credits its escrow ledger from `balanceAfter - balanceBefore`, not from the caller-supplied amount. This is the difference between a ledger that can be safely claimed and a ledger that over-credits recipients.

The regression tests encode both boundaries. `MockTokenNoReturn` omits return values from `approve`, `transfer`, and `transferFrom`. `MockFeeOnTransferERC20` burns a percentage of the requested transfer into a collector. The tests exist because replacing a `SafeERC20` call with a raw `IERC20` call can compile cleanly and still break production behavior.

## Key Files

| File | Why it matters |
| --- | --- |
| `src/Bonker.sol:81` | `claimTeamFees(token)` sweeps the factory's accumulated ERC20 balance with `SafeERC20.safeTransfer`. |
| `src/BonkerFeeLocker.sol:26` | `storeFees(feeOwner, token, amount)` is the fee escrow deposit boundary and uses a balance delta. |
| `src/BonkerFeeLocker.sol:29` | Inline rationale: balance deltas support fee-on-transfer and weird tokens. |
| `src/BonkerFeeLocker.sol:46` | `claim(feeOwner, token)` clears escrow before `SafeERC20.safeTransfer` to the fee owner. |
| `src/extensions/BonkerVault.sol:87` | Vault launch callback pulls reserved supply with `safeTransferFrom`. |
| `src/extensions/BonkerVault.sol:121` | Vault claims pay the registered admin through `safeTransfer`. |
| `src/extensions/BonkerAirdropV2.sol:84` | Airdrop V2 launch callback pulls reserved supply with `safeTransferFrom`. |
| `src/extensions/BonkerAirdropV2.sol:136` | Airdrop admin sweep uses `safeTransfer` after the claim expiration interval. |
| `src/extensions/BonkerAirdropV2.sol:151` | Airdrop recipient claims use `safeTransfer` after proof and vesting checks. |
| `src/extensions/BonkerPresaleEthToCreator.sol:461` | Presale token claims pay buyers with `safeTransfer`. |
| `src/extensions/BonkerPresaleEthToCreator.sol:559` | Presale deployment callback pulls the deployed token supply with `safeTransferFrom`. |
| `src/extensions/BonkerUniv4EthDevBuy.sol:95` | V4 dev buy sends routed output tokens to the recipient with `safeTransfer`. |
| `src/extensions/BonkerUniv4EthDevBuy.sol:142` | V4 dev buy approves WETH to Permit2 with `forceApprove`. |
| `src/extensions/BonkerUniv4EthDevBuy.sol:170` | V4 dev buy approves the paired token to Permit2 with `forceApprove`. |
| `src/lp-lockers/BonkerLpLockerFeeConversion.sol:172` | Live LP locker pulls initial pool supply with `safeTransferFrom`. |
| `src/lp-lockers/BonkerLpLockerFeeConversion.sol:302` | Live LP locker uses `forceApprove` before Permit2 approval for minting liquidity. |
| `src/lp-lockers/BonkerLpLockerFeeConversion.sol:477` | Live LP locker approves reward tokens before depositing them into FeeLocker. |
| `src/lp-lockers/BonkerLpLockerFeeConversion.sol:783` | Live LP locker emergency ERC20 sweep uses `safeTransfer`. |
| `src/lp-lockers/BonkerLpLockerMultiple.sol:144` | Dormant multi-recipient locker has the same safe initial token pull. |
| `src/lp-lockers/BonkerLpLockerMultiple.sol:330` | Dormant locker approves reward token deposits with `forceApprove`. |
| `src/mev-modules/BonkerSniperAuctionV2.sol:297` | Sniper auction pulls WETH bid payment with `safeTransferFrom`. |
| `src/mev-modules/BonkerSniperAuctionV2.sol:318` | Sniper auction sends the factory share with `safeTransfer`. |
| `src/mev-modules/BonkerSniperAuctionV2.sol:342` | Sniper auction approves FeeLocker before LP-recipient reward deposits. |
| `test/BonkerLegacyErc20Safety.t.sol:21` | `MockTokenNoReturn` defines a no-return ERC20 for compatibility regression tests. |
| `test/BonkerLegacyErc20Safety.t.sol:121` | Legacy airdrop test proves no-return tokens still deposit and claim. |
| `test/BonkerLegacyErc20Safety.t.sol:204` | V3 dev-buy test proves no-return routed output can still pay the recipient. |
| `test/BonkerLegacyErc20Safety.t.sol:248` | V4 dev-buy test proves no-return routed output can still pay the recipient. |
| `test/BonkerLegacyErc20Safety.t.sol:336` | Multi-recipient locker test proves no-return token LP placement still works. |
| `test/BonkerLegacyErc20Safety.t.sol:366` | Fee-conversion locker test proves no-return token LP placement still works. |
| `test/BonkerPresaleEthToCreator.t.sol:24` | Presale-specific no-return token mock covers the deployed-token claim path. |
| `test/BonkerPresaleEthToCreator.t.sol:251` | Presale test proves no-return deployed tokens can become claimable and be claimed. |
| `test/BonkerFeeFlow.t.sol:21` | `MockFeeOnTransferERC20` models tokens that deliver less than the requested transfer amount. |
| `test/BonkerFeeFlow.t.sol:139` | FeeLocker test pins balance-delta accounting for fee-on-transfer deposits. |

## How It Works

### Transfer Calls

Bonker's Solidity code treats ERC20 transfers as an integration boundary, not as a simple local function call. The recurring pattern is:

```text
token movement needed
  -> wrap the token as IERC20
  -> call SafeERC20.safeTransfer / safeTransferFrom
  -> let SafeERC20 accept empty return data or a true bool
  -> let SafeERC20 reject false returns or bubbled token reverts
```

That pattern appears anywhere protocol contracts move ERC20 balances directly: factory protocol fee claims, extension supply pulls, vault and airdrop claims, presale token delivery, LP locker deposits, dev-buy output delivery, sniper auction WETH payments, and owner emergency sweeps.

The tests intentionally use a mock whose ERC20 methods have no return value. That mock is not an ERC20 recommendation; it is a compatibility tripwire. If a future edit replaces `SafeERC20.safeTransfer(IERC20(token), recipient, amount)` with `IERC20(token).transfer(recipient, amount)`, the call can fail against that mock because the caller expects a boolean return that does not exist.

### Approval Calls

Bonker also uses `SafeERC20.forceApprove` before Permit2 or FeeLocker handoffs. This matters for two reasons.

First, some tokens require allowances to be set to zero before setting a new nonzero allowance. `forceApprove` handles the zero-then-set fallback that a direct `approve` call does not.

Second, several Bonker flows intentionally separate ERC20 approval from Permit2 approval:

```text
contract holds ERC20 balance
  -> forceApprove(token, Permit2, amount)
  -> Permit2.approve(token, spender, amount, expiration)
  -> Universal Router or FeeLocker pulls exactly the intended path amount
```

Dev-buy and LP locker Universal Router paths use a Permit2 expiration of `uint48(block.timestamp)`. Those approvals are transaction-local in practice: they are meant to be consumed immediately by the router call in the same transaction, not left as reusable spending authority.

FeeLocker deposits are different. The LP locker or MEV auction approves the FeeLocker for the amount it is about to deposit, then calls `storeFees`. The FeeLocker pulls the balance with `safeTransferFrom` and credits recipients from the actual received amount.

### Balance-Delta Accounting

`BonkerFeeLocker.storeFees()` is the one place where transfer success is not enough. It records:

```text
balanceBefore = token.balanceOf(FeeLocker)
safeTransferFrom(token, depositor, FeeLocker, requestedAmount)
balanceAfter = token.balanceOf(FeeLocker)
receivedAmount = balanceAfter - balanceBefore
feesToClaim[feeOwner][token] += receivedAmount
```

This supports fee-on-transfer tokens. If a depositor asks to store `100` tokens and the token takes a `5` token transfer fee, the recipient's escrow balance becomes `95`, not `100`. That keeps `availableFees()` equal to the FeeLocker balance that can actually be paid.

The `StoreTokens` event still includes the caller-requested `amount`. Consumers should not treat that value as the claimable balance. The claimable balance is the emitted running `balance` and the `availableFees(feeOwner, token)` view.

### Native ETH Is Outside This Boundary

Native ETH transfers do not use `SafeERC20`. Presale `claimEth()` uses raw `call{value: ...}` and reverts with `EthTransferFailed()` if the recipient or fee recipient rejects ETH. Dev-buy entry starts with native ETH, but as soon as the flow wraps into WETH or receives ERC20 output, it returns to the `SafeERC20` boundary.

Do not mix the two models. `SafeERC20` protects ERC20 call-return quirks. It does not help with native ETH receiver behavior.

## Flow Diagram

```text
Factory / Hook / Locker / Extension / MEV module
        |
        | ERC20 transfer or approval needed
        v
SafeERC20 boundary
        |
        | empty return accepted, true accepted, false/revert rejected
        v
Token balance moves
        |
        +-- normal payment path: update state according to intended amount
        |
        +-- FeeLocker deposit path:
              measure balance delta
              credit only receivedAmount
              allow permissionless claim to feeOwner
```

## Invariants and Edge Cases

### Keep SafeERC20 On Protocol-Owned Token Flows

Any path that transfers a token from or to a Bonker contract should use `SafeERC20` unless there is a specific lower-level API that already handles token movement, such as Uniswap `Currency.transfer` inside v4 settlement. This includes claim functions, extension callbacks, locker setup, auction payments, reward escrow deposits, dev-buy output delivery, and owner rescue functions.

Raw `IERC20.transfer`, `IERC20.transferFrom`, or `IERC20.approve` calls are suspicious in first-party protocol contracts. They may be acceptable in tests or scripts, but replacing a safe call in `src/` should come with a concrete reason and targeted regression coverage.

### Balance Deltas Belong At Escrow Boundaries

FeeLocker is an accounting contract. It must never credit more than it actually received. Balance-delta accounting is therefore required in `storeFees()`.

Do not copy the caller-supplied `amount` into `feesToClaim`. Doing so would over-credit fee-on-transfer deposits and eventually make claims depend on funds that the locker does not hold.

Balance deltas are not needed everywhere. A dev-buy output amount is already measured by `tokenOutAfter - tokenOutBefore` in the swap helper before it is paid to the recipient. LP fee collection similarly measures balance deltas around Position Manager calls before calculating distributions.

### Claims Update State Before External Token Transfer

Claim paths that hold a per-user or per-owner ledger update their accounting before the external token transfer. Examples include FeeLocker `claim`, vault `claim`, airdrop recipient `claim`, and presale `claimTokens`.

This keeps reentrancy risk constrained alongside `nonReentrant` guards. If a token callback or malicious token tries to reenter, the claimable state has already been reduced or the guard blocks the nested call.

### Permit2 Approval Expiration Is Intentional

Router paths approve Permit2 and then call Permit2-approved spenders immediately. The expiration is often `uint48(block.timestamp)`, which means the approval is valid only for the current block timestamp. Do not replace this with a long-lived approval unless the surrounding workflow explicitly requires reusable allowance.

Long-lived approvals are more appropriate in operator scripts where the signer controls the wallet and the script documents the leftover allowance. Protocol contracts should keep router spend authority short and amount-scoped.

### No-Return Is Different From False-Return

The compatibility target is no-return success. A token that explicitly returns `false` from `transfer`, `transferFrom`, or `approve` should still fail through `SafeERC20`. That is correct: Bonker should not treat an explicit token-level failure as a successful movement.

### Fee-On-Transfer Can Still Break Other Assumptions

FeeLocker handles fee-on-transfer deposits by measuring what arrived. That does not mean every Bonker path is designed for arbitrary transfer-tax launched tokens.

For example, LP placement and extension supply reservations assume the factory can move exact token amounts into lockers and extensions. If a launched token itself taxed transfers, supply splits and liquidity math would no longer match the requested deployment config. Bonker-launched `BonkerToken` does not tax transfers, so fee-on-transfer compatibility is mainly relevant to escrowed reward tokens and defensive accounting.

### Emergency Sweeps Are Still Token Calls

LP locker emergency `withdrawERC20` functions also use `SafeERC20`. These are owner-only rescue paths, but they can still be called for arbitrary tokens accidentally sent to the contract. The same no-return compatibility applies.

## Test Coverage

`BonkerLegacyErc20Safety.t.sol` is the focused no-return compatibility suite. It covers:

- legacy airdrop deposit and claim;
- V3 and V4 dev-buy output delivery;
- dormant multi-recipient LP locker placement;
- live fee-conversion LP locker placement.

`BonkerPresaleEthToCreator.t.sol` adds presale-specific no-return coverage because the presale deploys through a factory callback and then pays buyers later through `claimTokens`.

`BonkerFeeFlow.t.sol` adds fee-on-transfer coverage for FeeLocker. The important assertion is not just that the transfer call succeeds, but that `availableFees()` equals the net amount actually received.

When changing transfer, approval, or escrow logic under `src/`, run `forge test`. For a narrow ERC20-safety change, a targeted run is usually enough while iterating:

```bash
forge test --match-path test/BonkerLegacyErc20Safety.t.sol
forge test --match-path test/BonkerFeeFlow.t.sol
forge test --match-path test/BonkerPresaleEthToCreator.t.sol
```

Before shipping a broader Solidity change, run the full Foundry suite.

## Cross-References

- [FEE-ESCROW-AND-CLAIM](./FEE-ESCROW-AND-CLAIM.md) for FeeLocker escrow semantics and the creator-vs-protocol fee split.
- [LP-LOCKER-FEE-CONVERSION-LIFECYCLE](./LP-LOCKER-FEE-CONVERSION-LIFECYCLE.md) for reward collection, conversion, and FeeLocker deposits.
- [DEV-BUY-EXTENSION-ROUTING](./DEV-BUY-EXTENSION-ROUTING.md) for ETH dev-buy routing and short-lived Permit2 approvals.
- [NATIVE-ETH-WETH-CURRENCY-MODEL](./NATIVE-ETH-WETH-CURRENCY-MODEL.md) for the native ETH boundary that sits outside `SafeERC20`.
- [FOUNDRY-REGRESSION-SUITE](./FOUNDRY-REGRESSION-SUITE.md) for the broader Solidity test suite and when to run it.
- [AIRDROP-EXTENSION-LIFECYCLE](./AIRDROP-EXTENSION-LIFECYCLE.md) for airdrop V2 claim behavior and legacy-vs-live contract context.
- [VAULT-EXTENSION-LIFECYCLE](./VAULT-EXTENSION-LIFECYCLE.md) for vault supply reservation and admin-paid claims.
- [PRESALE-LIFECYCLE](./PRESALE-LIFECYCLE.md) for the presale deployment and buyer claim path.
