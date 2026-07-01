# Native ETH vs WETH Currency Model

This doc explains where Bonker uses native ETH versus wrapped `WETH` (`0x4200000000000000000000000000000000000006`) across the whole system, where the wrap/unwrap boundary sits, and why every internal balance is denominated in WETH; read this before changing dev-buy ETH routing, presale ETH handling, hook protocol-fee collection, LP fee escrow, sniper auction payments, `claimTeamFees`, or the buy/sell scripts.

This page answers natural-language queries such as "do I send ETH or WETH here", "why are fees in WETH not ETH", "where does ETH get wrapped", "weth.deposit", "CMD_WRAP_ETH", "CMD_UNWRAP_WETH", "claimEth pays native ETH", "poolManager.take feeCurrency factory", and "pool paired with WETH not native ETH". The one-sentence model: **native ETH appears only at user entry/exit points (dev buy, presale contribute/withdraw/claimEth, the buy script); every internal balance — pool reserves, protocol fees, LP fee escrow, auction payments, fee claims — is WETH (ERC20).**

## Why It Exists

Uniswap v4 supports native ETH as a pool currency, but Bonker deliberately does not use it. `BonkerHookV2` pools are always paired with WETH, an ERC20. This keeps the entire fee/accounting stack on one uniform ERC20 path: protocol fees are `take`n as ERC20, the `BonkerFeeLocker` escrow is a `mapping(token => balance)`, `claimTeamFees(token)` is a `SafeERC20.safeTransfer`, and the LP locker batches fee-currency swaps through the Universal Router. None of that has to special-case `address(0)` native ETH.

The cost of that uniformity is that humans hold and think in native ETH. So the system wraps ETH to WETH at exactly the points where a user (or a user-facing script) hands value in, and unwraps only where a user is paid back. Presales are the exception: they hold and pay native ETH end to end, because a presale never touches the WETH-paired pool until the token is deployed.

## Key Files

| File | Why it matters |
| --- | --- |
| `src/hooks/BonkerHookV2.sol:58` | Hook stores `weth` immutable; pools pair against it. |
| `src/hooks/BonkerHookV2.sol:175` | Prefers WETH not be the bonker token so the hook fee collects on the paired WETH side. |
| `src/hooks/BonkerHookV2.sol:431` | `poolManager.take(feeCurrency, factory, fee)` sends the protocol fee (WETH) to the factory. |
| `src/Bonker.sol:81` | `claimTeamFees(token)` `safeTransfer`s the accumulated WETH balance to `teamFeeRecipient`. |
| `src/BonkerFeeLocker.sol:16` | `feesToClaim[feeOwner][token]` — per-recipient, per-token (WETH) escrow ledger. |
| `src/BonkerFeeLocker.sol:26` | `storeFees(feeOwner, token, amount)` pulls ERC20 in via `safeTransferFrom`. |
| `src/extensions/BonkerUniv4EthDevBuy.sol:66` | Dev-buy entry is `payable onlyFactory`; validates `msg.value` against config. |
| `src/extensions/BonkerUniv4EthDevBuy.sol:164` | Comment: "univ4 supports ETH as a currency, but we only allow WETH". |
| `src/extensions/BonkerUniv4EthDevBuy.sol:166` | `weth.deposit{value: amountPairedToken}()` — the wrap on the way in. |
| `src/extensions/BonkerPresaleEthToCreator.sol:338` | `buyIntoPresale` is `payable`; contributions are native ETH. |
| `src/extensions/BonkerPresaleEthToCreator.sol:390` | Over-contribution refund via `call{value: ...}` (native ETH). |
| `src/extensions/BonkerPresaleEthToCreator.sol:517` | `claimEth` pays the presale owner native ETH minus the Bonker fee. |
| `src/mev-modules/BonkerSniperAuctionV2.sol:41` | "Winning swaps pay WETH based on the delta between `tx.gasprice` and a per-round gas peg." |
| `scripts/buy-token.mjs:125` | Universal Router commands `[CMD_WRAP_ETH, CMD_V4_SWAP]` — wrap then buy. |
| `scripts/sell-token.mjs:179` | Universal Router commands `[CMD_V4_SWAP, CMD_UNWRAP_WETH]` — sell then unwrap to ETH. |

## The Pool Is WETH-Paired

Every Bonker pool's paired currency is WETH, never native ETH (`Currency.wrap(WETH)` in `_initializePool`). The hook also prefers that WETH is *not* the bonker token when both could be WETH-like, so that the hook's protocol fee is collected on the paired (WETH) side rather than on the launched token — see `BonkerHookV2.sol:175`.

Consequence: any swap into or out of a Bonker pool moves WETH, not ETH. A caller holding native ETH must wrap first; a caller wanting ETH out must unwrap after. The pool itself is currency-agnostic to that and only ever sees WETH deltas.

## Internal Balances Are All WETH

Once value is inside the protocol, it stays WETH until a user withdraws.

### Protocol fee (factory → team)

`BonkerHookV2._beforeSwap` derives the protocol fee from the LP fee and `take`s it as the paired currency (WETH) directly to the factory at `BonkerHookV2.sol:431`. The factory accumulates a WETH balance. The owner/admin later calls `claimTeamFees(WETH)` (`Bonker.sol:81`), which `SafeERC20.safeTransfer`s the full balance to `teamFeeRecipient`. There is no ETH anywhere in this path.

### LP fees (locker → FeeLocker escrow → creator)

The LP locker collects accrued LP fees from the v4 position. Fees that land in the "wrong" currency (the launched token) are swapped to the reward currency in a single batched Universal Router swap before distribution, then deposited into `BonkerFeeLocker` via `storeFees(feeOwner, token, amount)`. The escrow ledger `feesToClaim[feeOwner][token]` is keyed by token address, and the reward recipient later calls `claim(owner, WETH)`. Again, ERC20 throughout.

### Sniper auction payments

Auction winners pay WETH, not ETH. The bid signal is `tx.gasprice` relative to a per-round gas peg, but the actual payment charged is WETH (`BonkerSniperAuctionV2.sol:41`, `:88`). The factory's portion and reward-recipient portions are settled in WETH through the same FeeLocker escrow.

## Where ETH Crosses the Boundary

### Dev buy — wrap on the way in

`BonkerUniv4EthDevBuy` is the one extension that takes native ETH and pushes it into the pool. Its entry is `payable onlyFactory` and it validates `msg.value` equals the extension's configured `msgValue`. It then calls `weth.deposit{value: amountPairedToken}()` (`:166`) to wrap, approves Permit2/Universal Router, and swaps WETH → token. So the user supplies ETH at launch, but the buy itself is a WETH swap. The wrap is the only ETH→WETH conversion inside the protocol.

### Presale — native ETH end to end

`BonkerPresaleEthToCreator` never touches the WETH pool during the sale, so it stays in native ETH the whole time:

- `buyIntoPresale` / `buyIntoPresaleWithProof` are `payable`; contributions are `msg.value`.
- Over-contribution beyond `maxEthGoal` is refunded immediately via `call{value: ...}` (`:390`).
- `withdrawFromPresale` returns native ETH for active or failed sales.
- On success, `claimEth` pays the presale owner native ETH minus the Bonker fee, and pays the fee recipient native ETH too (`:517`, `:540`).

The presale's `receiveTokens` factory callback and `endPresale` deploy the token, but the *ETH raised* is paid out as native ETH; it is never wrapped. This is why presale code uses raw `call{value}` transfers while the rest of the system uses `SafeERC20`.

### Buy/sell scripts — wrap in, unwrap out

The operator scripts mirror the boundary so a human can deal in ETH:

- `scripts/buy-token.mjs` sends native ETH and packs Universal Router commands `[CMD_WRAP_ETH (0x0b), CMD_V4_SWAP (0x10)]` — wrap, then swap WETH → token.
- `scripts/sell-token.mjs` packs `[CMD_V4_SWAP (0x10), CMD_UNWRAP_WETH (0x0c)]` — swap token → WETH, then unwrap so the wallet receives native ETH.

Note the asymmetry with the Forge sell path: `script/SellToken.s.sol` swaps the balance to **WETH** and stops (no unwrap), so the operator wallet ends holding WETH there, whereas the `.mjs` script ends holding native ETH. See [FORGE-SELL-TOKEN-SCRIPT](./FORGE-SELL-TOKEN-SCRIPT.md) and [STANDALONE-MAINNET-SCRIPT-WORKFLOW](./STANDALONE-MAINNET-SCRIPT-WORKFLOW.md).

## Invariants and Edge Cases

- **Pools are always WETH-paired.** Do not introduce native-ETH (`address(0)`) currency pools — the fee accounting, escrow, and `claimTeamFees` all assume an ERC20 and would break on native ETH.
- **`claimTeamFees` and `FeeLocker.claim` take a token argument.** In production that argument is WETH. Passing native ETH is meaningless; there is no ETH balance to claim.
- **Dev buy `msg.value` must match the configured `msgValue`.** The extension reverts otherwise (`BonkerUniv4EthDevBuy.sol:66`), then wraps the exact amount. A mismatch is a launch-config bug, not a currency bug.
- **Presale transfers use raw `call{value}`, not `SafeERC20`.** Because presales hold native ETH, recipients must accept ETH; a contract recipient that rejects ETH will fail the transfer. The rest of the system never has this concern because WETH transfers can't revert on a plain receive.
- **Unwrap happens only client-side / script-side.** No on-chain Bonker contract unwraps WETH back to ETH for the protocol; unwrapping is purely a user convenience in the Universal Router command list.

## Cross-References

- [HOOK-FEE-ACCOUNTING](./HOOK-FEE-ACCOUNTING.md) — how the hook derives and `take`s the protocol fee in WETH.
- [FEE-ESCROW-AND-CLAIM](./FEE-ESCROW-AND-CLAIM.md) — FeeLocker per-token escrow vs the factory's single-recipient WETH sweep.
- [DEV-BUY-EXTENSION-ROUTING](./DEV-BUY-EXTENSION-ROUTING.md) — V4 vs V3 dev-buy paths and launch ETH routing.
- [PRESALE-LIFECYCLE](./PRESALE-LIFECYCLE.md) — full presale flow including native-ETH contribution and `claimEth`.
- [LP-LOCKER-FEE-CONVERSION-LIFECYCLE](./LP-LOCKER-FEE-CONVERSION-LIFECYCLE.md) — fee-currency swap-back before FeeLocker deposit.
- [SNIPER-AUCTION-BID-MECHANICS](./SNIPER-AUCTION-BID-MECHANICS.md) — gas-price bid signal that resolves to a WETH payment.
- [FORGE-SELL-TOKEN-SCRIPT](./FORGE-SELL-TOKEN-SCRIPT.md) — Forge sell path that stops at WETH.
- [STANDALONE-MAINNET-SCRIPT-WORKFLOW](./STANDALONE-MAINNET-SCRIPT-WORKFLOW.md) — buy/sell scripts that wrap in and unwrap out.
- [CONTRACT-CONFIG-TOPOLOGY](./CONTRACT-CONFIG-TOPOLOGY.md) — deployed WETH address and per-consumer config copies.
