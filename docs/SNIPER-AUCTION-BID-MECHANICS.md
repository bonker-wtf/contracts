# Sniper Auction Bid Mechanics

How a sniper actually *wins* a Bonker launch auction: bids are encoded in `tx.gasprice`, not in calldata or `msg.value`. This page explains the gas-price-as-bid-signal mechanism, the per-round `gasPeg` derived from EIP-1559 dynamics, the `paymentPerGasUnit` quantization, and the `BonkerSniperUtilV0`/`BonkerSniperUtilV2` helper contracts that package a winning bid. Read it before changing `src/mev-modules/BonkerSniperAuctionV2.sol`, `src/mev-modules/sniper-utils/`, the `gasPeg`/`paymentPerGasUnit`/`nextAuctionBlock` state, or any off-chain bot that bids into a Bonker auction. Natural-language queries this answers: "how do snipers bid", "what is gasPeg", "getTxGasPriceForBidAmount", "GasSignalNegative", "GasPriceTooLow", "paymentPerGasUnit", "auction round timing", "AuctionDidNotAdvance", "1.125 EIP-1559 peg".

This is the bidder's-eye view. For the module *lifecycle* (allowlisting, hook handshake, `MAX_MEV_MODULE_DELAY`, post-auction fee decay) see [MEV-MODULE-LIFECYCLE](./MEV-MODULE-LIFECYCLE.md).

## Why It Exists

A fresh meme-token pool has one obviously profitable trade: the very first swap before price discovery. Rather than let that value leak to whoever spams the most transactions, Bonker auctions the right to swap on specific blocks and routes the proceeds back to the pool's LP reward recipients and the factory.

The hard part is running a sealed-ish auction inside a single Uniswap v4 `beforeSwap` callback, with no separate commit/reveal transaction. Bonker's trick is to use `tx.gasprice` as the bid channel. The chain already orders transactions by gas price, so the bidder who is willing to pay the most also lands highest in the block — and the contract reads that same number to compute what they owe. The bid and the priority are the same signal, so there is nothing extra to commit or reveal.

The catch is that base fee drifts block to block under EIP-1559, so a raw `tx.gasprice` is not a clean bid. The auction subtracts a per-pool **`gasPeg`** floor and charges WETH proportional to the gas units *above* that floor. The peg is pre-computed to sit above the worst-case base-fee climb, so every legal bid maps to a non-negative, quantized WETH amount.

## Key Files

| File | Why it matters |
| --- | --- |
| `src/mev-modules/BonkerSniperAuctionV2.sol:52` | `gasPeg`, `nextAuctionBlock`, `round` per-pool auction state. |
| `src/mev-modules/BonkerSniperAuctionV2.sol:67` | `paymentPerGasUnit` — WETH charged per gas unit above the peg (default `0.0001 ether`). |
| `src/mev-modules/BonkerSniperAuctionV2.sol:263` | `_getBaseAuctionGasPeg()` — EIP-1559 `1.125^n` peg derivation. |
| `src/mev-modules/BonkerSniperAuctionV2.sol:279` | `_pullPayment()` — reads `tx.gasprice`, computes the gas signal, pulls WETH. |
| `src/mev-modules/BonkerSniperAuctionV2.sol:306` | `_sendPayment()` — 20% factory / 80% LP-recipient split. |
| `src/mev-modules/BonkerSniperAuctionV2.sol:352` | `_prepareNextRound()` — bumps round, re-pegs, schedules next auction block. |
| `src/mev-modules/BonkerSniperAuctionV2.sol:424` | `beforeSwap()` — block-timing guard, then auction-vs-decay branch. |
| `src/mev-modules/sniper-utils/BonkerSniperUtilV2.sol:75` | `getTxGasPriceForBidAmount()` — inverts the bid math to a target gas price. |
| `src/mev-modules/sniper-utils/BonkerSniperUtilV2.sol:90` | `bidInAuction()` — full winning-bid wrapper (validate, WETH, swap, payout). |
| `src/mev-modules/sniper-utils/BonkerSniperUtilV2.sol:140` | V1-vs-V2 hook `hookData` shape selection. |
| `src/mev-modules/sniper-utils/BonkerSniperUtilV2.sol:176` | `_univ4Swap()` — Universal Router `V4_SWAP` with Permit2 approval. |
| `src/mev-modules/sniper-utils/BonkerSniperUtilV0.sol:39` | V0 helper — same flow and same `getTxGasPriceForBidAmount`, but no V2-hook data branch (always bare-payee `hookData`). |
| `src/mev-modules/interfaces/IBonkerSniperAuctionV0.sol` | Shared auction interface (`round`, `gasPeg`, `nextAuctionBlock`, `paymentPerGasUnit`, `maxRounds`). |

## The Gas-Price Bid Signal

A bid is one number: how much WETH you offer for the right to swap on the auction block. That number is communicated by setting your transaction's gas price.

The auction stores a per-pool floor, `gasPeg[poolId]`. On a winning swap, `_pullPayment` computes:

```text
gasSignal     = tx.gasprice - gasPeg[poolId]      // must be >= 0
paymentAmount = gasSignal * paymentPerGasUnit     // WETH owed
```

So with the default `paymentPerGasUnit = 0.0001 ether`, every 1 wei of gas price above the peg costs 0.0001 WETH. To offer 0.05 WETH you set `tx.gasprice = gasPeg + 500`.

The inverse lives in the helper: `getTxGasPriceForBidAmount(auctionGasPeg, desiredBidAmount)` returns `auctionGasPeg + desiredBidAmount / paymentPerGasUnit`. It reverts `InvalidBidAmount` if `desiredBidAmount` is not a whole multiple of `paymentPerGasUnit`, because the gas signal is integer gas units — bids are quantized to the per-unit price and cannot be finer-grained.

Two failure modes guard the floor. `_pullPayment` reverts `GasSignalNegative` if `tx.gasprice < gasPeg` (you bid below the floor). The helper's own pre-check reverts `GasPriceTooLow` for the same condition before doing any work, and `ValueBidMismatch` if the `msg.value` you forwarded does not equal the WETH the gas signal implies.

## Why the Peg Is `basefee * 1.125^n`

`_getBaseAuctionGasPeg(blocks)` returns `block.basefee * (1125 ** blocks) / (1000 ** blocks)`.

Under vanilla EIP-1559 the base fee can rise at most 12.5% per block when the previous block is full. The auction is scheduled `blocks` blocks in the future (2 by default), so by the time the auction block lands, base fee could legitimately be up to `1.125^blocks` higher than it is now. Pegging to that worst-case ceiling guarantees that even an honest, non-bidding transaction's base fee stays at or below the peg — so its gas signal is ~0 and it owes ~0. Any gas price *above* the ceiling is then unambiguously a deliberate bid, not base-fee drift. This keeps the signal clean: legal bids are always non-negative and the peg never accidentally taxes a normal swapper who happened to land in a high-base-fee block.

The peg is recomputed every round in `_prepareNextRound` using `blocksBetweenAuction` (also 2 by default), so each round gets a fresh ceiling relative to that round's base fee.

## Round and Block Timing

Each pool runs up to `maxRounds` auction rounds (default 5), one per scheduled block, before the module hands off to its post-auction fee-decay phase (V2 only — see [MEV-MODULE-LIFECYCLE](./MEV-MODULE-LIFECYCLE.md)).

- `initialize` sets `round = 1`, `nextAuctionBlock = block.number + blocksBetweenDeploymentAndFirstAuction`, and the first `gasPeg`.
- `beforeSwap` enforces block timing strictly: `block.number < nextAuctionBlock` reverts `NotAuctionBlock`; `block.number > nextAuctionBlock` means the round was missed (nobody bid in time), so the module emits `AuctionExpired` and starts fee decay early.
- Only `block.number == nextAuctionBlock` runs the auction: pull payment, split it, set the LP fee to `feeConfig.startingFee`, then `_prepareNextRound`.

`_prepareNextRound` increments `round`, and once `round > maxRounds` it sets `poolDecayStartTime` and stops auctioning. Otherwise it re-pegs and sets the next `nextAuctionBlock`. A bidder must therefore read `round(poolId)` and `nextAuctionBlock(poolId)` immediately before submitting and land in exactly that block.

## What the Helper Wraps

`BonkerSniperUtilV2.bidInAuction(swapParams, round)` is the reference winning-bid path. It is not deployed by the factory — it documents, in Solidity, exactly what an off-chain sniper bot must replicate. Its sequence:

1. Validate `round == bonkerSniperAuction.round(poolId)` and `round <= maxRounds` (`InvalidRound`).
2. Validate `block.number == nextAuctionBlock(poolId)` (`InvalidBlock`).
3. Validate `tx.gasprice >= gasPeg(poolId)` (`GasPriceTooLow`) and that `msg.value` exactly equals `paymentPerGasUnit * (tx.gasprice - gasPeg)` (`ValueBidMismatch`).
4. Wrap `msg.value` ETH into WETH and approve the auction to pull it (the auction's `_pullPayment` does `safeTransferFrom` of WETH).
5. Pull in the swap's `tokenIn`, set `hookData` to the payee, run the swap through the Universal Router, forward output tokens back to the caller.
6. Assert the round advanced (`round + 1 == bonkerSniperAuction.round(poolId)`), else revert `AuctionDidNotAdvance`.

Step 5 chooses the `hookData` shape based on hook version: a `BonkerHookV2` pool wants a `PoolSwapData{ mevModuleSwapData, poolExtensionSwapData }` struct (with the payee encoded inside `mevModuleSwapData`), while a legacy V1 hook wants a bare `abi.encode(payee)`. The auction's `beforeSwap` decodes that payee out of `auctionData` and bills it.

### V0 vs V2 Helper

`BonkerSniperUtilV0` is the same flow minus one thing: it always encodes `hookData` as a bare payee address (it predates the V2 hook's `PoolSwapData` struct). It still ships the identical `getTxGasPriceForBidAmount` convenience inverter. The deployed Base module is `BonkerSniperAuctionV2`, so production bidders use the V2 helper's data shape. The contract-level V0/V2 *module* differences (decay phase, return-value handshake) are tabulated in [HOOK-VERSION-COMPARISON](./HOOK-VERSION-COMPARISON.md) and [MEV-MODULE-LIFECYCLE](./MEV-MODULE-LIFECYCLE.md).

## Where the Payment Goes

A winning bid's WETH is split in `_sendPayment`: `FACTORY_PORTION = 2000` BPS (20%) goes straight to the factory address, and the remaining 80% is distributed to the pool's LP reward recipients via `feeLocker.storeFees`, using the same `rewardBps`/`rewardRecipients` arrays the LP locker holds for that token. The last recipient absorbs any rounding dust (`lpPayment - rewardTotal`). So auction proceeds follow the same recipient topology as ordinary LP fees — see [FEE-ESCROW-AND-CLAIM](./FEE-ESCROW-AND-CLAIM.md) and [LP-LOCKER-FEE-CONVERSION-LIFECYCLE](./LP-LOCKER-FEE-CONVERSION-LIFECYCLE.md).

## Invariants and Edge Cases

- **Bids are quantized.** Any payment that is not an exact multiple of `paymentPerGasUnit` is unrepresentable; the helper rejects it up front (`InvalidBidAmount`) because the on-chain math only sees integer gas units.
- **The peg must exceed worst-case base-fee drift.** If `blocksBetweenAuction` is raised without re-deriving the `1.125^n` peg, an honest swapper landing in a high-base-fee block could be charged a phantom bid. The peg formula and the block delay are coupled — change them together.
- **Strict block equality.** A bid is only valid on `nextAuctionBlock`. Submitting one block early reverts `NotAuctionBlock`; one block late, the round is treated as expired and the module starts fee decay (`AuctionExpired`), permanently skipping any remaining rounds for that pool.
- **`gasPeg == 0` means uninitialized.** The auction uses a zero `gasPeg[poolId]` as the "not initialized" sentinel (`getFee` returns 0, `initialize` reverts `PoolAlreadyInitialized` if it is already non-zero). A real peg is never 0 because it derives from a live `block.basefee`.
- **WETH, not raw ETH, settles the bid.** `_pullPayment` does `safeTransferFrom` of WETH from the payee, so the bidder must hold and approve WETH (the helper wraps `msg.value` for you, but a hand-rolled bot must pre-wrap and approve the auction contract).
- **Payee == swapper is enforced by the helper, not the auction.** The auction bills whatever address is encoded in `auctionData`; the helper hardwires `address(this)` so the contract that runs the swap also pays. A custom integration that encodes a different payee must ensure that payee approved the WETH.

## Cross-References

- [MEV-MODULE-LIFECYCLE](./MEV-MODULE-LIFECYCLE.md) — module allowlisting, hook handshake, `MAX_MEV_MODULE_DELAY`, post-auction descending-fee decay.
- [HOOK-VERSION-COMPARISON](./HOOK-VERSION-COMPARISON.md) — legacy `BonkerHook*` vs `BonkerHook*V2`, pool-data and MEV boundary differences.
- [HOOK-FEE-ACCOUNTING](./HOOK-FEE-ACCOUNTING.md) — how the hook applies `mevModuleSetFee` LP fees and protocol-fee deltas around the module call.
- [FEE-ESCROW-AND-CLAIM](./FEE-ESCROW-AND-CLAIM.md) — the `feeLocker.storeFees` escrow that auction proceeds flow into.
- [LP-LOCKER-FEE-CONVERSION-LIFECYCLE](./LP-LOCKER-FEE-CONVERSION-LIFECYCLE.md) — the `rewardBps`/`rewardRecipients` topology the LP split reuses.
