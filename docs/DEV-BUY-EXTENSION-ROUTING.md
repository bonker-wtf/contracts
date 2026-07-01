Dev-buy extension routing compares Bonker's two coexisting creator-buy extensions — `BonkerUniv4EthDevBuy` (deployed) and `BonkerUniv3EthDevBuy` (dormant) — explaining how each turns launch ETH into the freshly deployed token, why two exist, and which one production wires up. Read this before changing `src/extensions/BonkerUniv3EthDevBuy.sol`, `src/extensions/BonkerUniv4EthDevBuy.sol`, their `Univ3EthDevBuyExtensionData`/`Univ4EthDevBuyExtensionData` structs, the launch-form dev-buy encoding in `client/components/LaunchPage.jsx`, or the `EthDevBuy` event decode in `server/tokens.js`.

This page answers natural-language queries such as "what is the difference between Univ3 and Univ4 dev buy", "how does the creator buy route ETH to the token", `pairedTokenPoolKey` vs `uniV3Fee`, `InvalidEthDevBuyPercentage`, `InvalidPairedTokenPoolKey`, `InvalidMsgValue`, "why does dev buy need a V3 swap router", "which DevBuy contract is deployed", and "dev buy must be last extension". The single most important fact: the production `DEVBUY` address (`0xc00Ab3631E82902f55B62EB95A0101eE2eb91a69`) is `BonkerUniv4EthDevBuy`, and the Univ3 variant is compiled, tested, and verifiable but is **not** enabled on the live factory.

## Why two dev-buy extensions exist

A dev buy ("creator buy") lets the deployer spend ETH in the same transaction that creates the token, so they own a bag from block one with no chance for a sniper to front-run them. Both extensions implement that with the same contract shape: factory-only, zero reserved supply, and all value coming from the attached `msg.value`.

The two contracts diverge only on **how ETH reaches the paired token** when the launched token is paired against something other than WETH. Bonker pools are WETH-paired, so the launched token's pool is `pairedToken == WETH` and the buy is a single WETH→token swap. But the upstream Clanker design supports tokens paired against an arbitrary `pairedToken`, and that intermediate token might have deep liquidity on either a Uniswap **V3** pool or a Uniswap **V4** pool. Each extension encodes one of those two intermediate-hop strategies.

Because Bonker only launches WETH-paired pools today, the simpler V4-only variant is the one deployed and allowlisted. The V3 variant is kept in the tree (source, Foundry tests, and `verify-all.sh`) so it can be deployed later if a non-WETH pairing that only lives on V3 is ever needed — but it is currently dormant.

## Side-by-side comparison

| Aspect | `BonkerUniv4EthDevBuy` (deployed) | `BonkerUniv3EthDevBuy` (dormant) |
| --- | --- | --- |
| WETH→paired hop | Uniswap **V4** swap via `pairedTokenPoolKey` | Uniswap **V3** `exactInputSingle` via `uniV3Fee` tier |
| Extra dependency | none | `ISwapRouterV3 swapRouter` (extra constructor arg) |
| Constructor args | `(factory, weth, universalRouter, permit2)` | `(factory, weth, universalRouter, permit2, swapRouter)` |
| Extension data | `pairedTokenPoolKey` (PoolKey) + min-out + recipient | `uniV3Fee` (uint24) + min-out + recipient |
| Extra validation | `InvalidPairedTokenPoolKey` on the paired pool key | none beyond shared guards |
| Production status | allowlisted; `DEVBUY` points here | source/test only; not allowlisted |
| Paired→token leg | identical shared `_univ4Swap` (V4) | identical shared `_univ4Swap` (V4) |

Everything else — the factory-only modifier, zero-supply requirement, `msg.value` matching, the final V4 swap into the launched token, and the emitted `EthDevBuy` event — is identical between the two. The hop strategy and its single struct field are the entire delta.

## Key files

| File | Why it matters |
| --- | --- |
| `src/extensions/BonkerUniv4EthDevBuy.sol:60` | Deployed variant `receiveTokens()` — validates msgValue, decodes `Univ4EthDevBuyExtensionData`, performs the buy. |
| `src/extensions/BonkerUniv4EthDevBuy.sol:106` | `_performDevBuy()` — optional WETH→paired V4 hop with pool-key validation, then paired→token V4 swap. |
| `src/extensions/BonkerUniv4EthDevBuy.sol:186` | `_univ4Swap()` — universal-router `V4_SWAP` exact-in helper (shared shape with the V3 variant). |
| `src/extensions/interfaces/IBonkerUniv4EthDevBuy.sol:8` | `Univ4EthDevBuyExtensionData { PoolKey pairedTokenPoolKey; uint128 pairedTokenAmountOutMinimum; address recipient; }`. |
| `src/extensions/BonkerUniv3EthDevBuy.sol:70` | Dormant variant `receiveTokens()` — same validation, decodes `Univ3EthDevBuyExtensionData`. |
| `src/extensions/BonkerUniv3EthDevBuy.sol:121` | `_performDevBuy()` — optional WETH→paired **V3** hop via `swapRouter.exactInputSingle`, then paired→token V4 swap. |
| `src/extensions/interfaces/IBonkerUniv3EthDevBuy.sol:8` | `Univ3EthDevBuyExtensionData { uint24 uniV3Fee; uint128 pairedTokenAmountOutMinimum; address recipient; }`. |
| `src/utils/ISwapRouterV3.sol:15` | Minimal `exactInputSingle` interface — the extra constructor dependency only the V3 variant needs. |
| `script/DeployExtensions.s.sol:27` | Deploys `BonkerUniv4EthDevBuy`; `:31` allowlists it on the factory. |
| `scripts/verify-all.sh:81` | Verifies the deployed `DEVBUY` address as `BonkerUniv4EthDevBuy` on BaseScan. |
| `client/config/contracts.js:9` | `DEVBUY` constant — the live Univ4 extension address used by the launch form. |
| `client/components/LaunchPage.jsx:391` | Encodes the Univ4 struct (zeroed `pairedTokenPoolKey`) and appends dev buy as the **last** extension. |
| `server/tokens.js:95` | `DEVBUY_EVENT_ABI` for the shared `EthDevBuy` event; `:209` enriches token detail with the buy amount. |

## How it works

Both extensions are invoked by `Bonker.deployToken()` through the standard extension callback (`receiveTokens`), after the pool is initialized and liquidity is locked. The factory forwards the configured `msgValue` as `msg.value` and passes the launched token's V4 `PoolKey` (`tokenPoolKey`). See [FACTORY-EXTENSION-LIFECYCLE](./FACTORY-EXTENSION-LIFECYCLE.md) for the supply-reservation and ETH-forwarding handshake that wraps this call.

### Shared entry and guards

`receiveTokens()` is identical in both contracts up to the decode:

1. Revert `InvalidMsgValue` if the attached `msg.value` does not exactly equal the extension's configured `msgValue`, or if it is zero.
2. Revert `InvalidEthDevBuyPercentage` if `extensionBps != 0` or `extensionSupply != 0` — a dev buy reserves **no** token supply; it only spends ETH.
3. `abi.decode` the extension's `extensionData` into the variant-specific struct.
4. Call `_performDevBuy(...)`, then `SafeERC20.safeTransfer` the acquired tokens to `recipient`, and emit `EthDevBuy(token, recipient, msg.value, tokenAmount)`.

### The WETH-paired fast path (both variants)

When `pairedToken == WETH` — every Bonker launch today — there is no intermediate hop. The extension wraps the ETH with `weth.deposit{value: msg.value}()`, approves the paired token through Permit2 to the universal router, and runs one `_univ4Swap` from WETH into the launched token using the launched token's `tokenPoolKey`. The two variants behave identically here.

### The non-WETH hop (where the variants diverge)

When `pairedToken != WETH`, ETH must first be converted into the paired token before the final V4 swap. This is the only structural difference:

- **Univ4 variant** (`BonkerUniv4EthDevBuy._performDevBuy`): reads `pairedTokenPoolKey` from the extension data, validates that the pool key pairs the paired token against WETH (or native ETH) in either currency slot — reverting `InvalidPairedTokenPoolKey` otherwise — wraps ETH to WETH, and runs a **Uniswap V4** swap WETH→paired token via `_univ4Swap`. No external router dependency.
- **Univ3 variant** (`BonkerUniv3EthDevBuy._performDevBuy`): builds an `ISwapRouterV3.ExactInputSingleParams` with the `uniV3Fee` tier and calls `swapRouter.exactInputSingle{value: msg.value}(...)` to swap WETH→paired token on **Uniswap V3**. This is why its constructor takes an extra `swapRouter_` address that the V4 variant omits.

After the hop, both variants approve the paired token via Permit2 and run the same final `_univ4Swap` from paired token into the launched token.

```text
                 receiveTokens(msg.value = configured ETH)
                          │  guards: InvalidMsgValue, InvalidEthDevBuyPercentage
                          ▼
            pairedToken == WETH ? ──── yes ──► weth.deposit ──► V4 swap WETH→token
                          │
                          no
            ┌─────────────┴──────────────┐
            ▼                             ▼
   Univ4: V4 swap WETH→paired     Univ3: V3 exactInputSingle WETH→paired
   (validate pairedTokenPoolKey)  (uniV3Fee tier)
            └─────────────┬──────────────┘
                          ▼
                 V4 swap paired→token  (amountOutMinimum = 1)
                          ▼
                 safeTransfer token → recipient ; emit EthDevBuy
```

### The shared `_univ4Swap` helper

Both contracts carry a byte-identical `_univ4Swap`: it packs a single `Commands.V4_SWAP`, encodes the action triplet `SWAP_EXACT_IN_SINGLE` / `SETTLE_ALL` / `TAKE_ALL`, derives `zeroForOne` from currency ordering, and measures `tokenOut` balance before/after to return the amount received. It forwards `value` to the router only when `currency0` is the native sentinel (`address(0)`); since Bonker uses WETH (never native ETH as a currency), that path is dormant and the swap settles from the Permit2 approval instead.

## Invariants and edge cases

### Zero reserved supply

Both extensions hard-require `extensionBps == 0` and `extensionSupply == 0`. A dev buy is not a vault or airdrop — it never receives a pre-allocated slice of the 100B supply. All tokens it delivers are bought from the live pool with the attached ETH. Mixing a nonzero `extensionBps` into a dev-buy config reverts `InvalidEthDevBuyPercentage`.

### Must run last

The launch form appends the dev-buy extension as the final entry (`client/components/LaunchPage.jsx:391`, comment "must be last — buys after pool is live"). The buy swaps against the pool the launch just created, so any extension that mutates supply or liquidity (vault, airdrop) must execute before it. Ordering is the launch config's responsibility; the contract does not enforce it.

### No slippage protection on the final leg

The paired→token swap passes `amountOutMinimum = 1`. There is effectively no slippage guard on the launched-token leg — acceptable because the buyer is the deployer hitting their own brand-new pool in the same transaction, where there is no adversarial price to protect against. The intermediate hop *does* honor `pairedTokenAmountOutMinimum`, but the launch form sets it to `0` for the (zeroed) WETH-paired case.

### Identical event, one decoder

Both variants emit the same `EthDevBuy(address indexed token, address indexed user, uint256 ethAmount, uint256 tokenAmount)`. `server/tokens.js` decodes it with a single `DEVBUY_EVENT_ABI` and queries logs from whichever emitted extension address maps to the `devBuy` feature in `server/contract-features.js`, so token-detail enrichment works regardless of which variant is live as long as the feature map includes the deployed address. See [TOKEN-DETAIL-ENRICHMENT](./TOKEN-DETAIL-ENRICHMENT.md).

### Permit2 approval lifetime

Each swap calls `permit2.approve(token, universalRouter, amount, uint48(block.timestamp))`. The deadline is the current block timestamp, so the approval is valid only within the deploy transaction — there is no lingering allowance after the buy settles.

### Deploying or swapping the variant

If a non-WETH pairing ever requires the V3 hop, deploying `BonkerUniv3EthDevBuy` needs the extra Uniswap V3 SwapRouter constructor argument, allowlisting it via `setExtension`, updating `DEVBUY` in `client/config/contracts.js`, switching the launch-form encoding to the `Univ3EthDevBuyExtensionData` struct (`uniV3Fee` instead of `pairedTokenPoolKey`), and updating `scripts/verify-all.sh` to verify the V3 contract. The shared `EthDevBuy` event keeps the server side unchanged.

## Cross-references

- [FACTORY-EXTENSION-LIFECYCLE](./FACTORY-EXTENSION-LIFECYCLE.md) — the `ExtensionConfig[]` supply-reservation, ETH-forwarding, and `receiveTokens` callback contract that invokes both dev-buy variants.
- [LAUNCH-FORM-DEPLOYMENT-CONFIG](./LAUNCH-FORM-DEPLOYMENT-CONFIG.md) — how `/launch` encodes the Univ4 dev-buy struct and bundles ETH into `deployToken`.
- [TOKEN-DETAIL-ENRICHMENT](./TOKEN-DETAIL-ENRICHMENT.md) — how the `EthDevBuy` event surfaces the creator buy on the token detail page.
- [FOUNDRY-REGRESSION-SUITE](./FOUNDRY-REGRESSION-SUITE.md) — the dev-buy tests that exercise both `BonkerUniv3EthDevBuy` and `BonkerUniv4EthDevBuy` against mock routers.
- [CONTRACT-DEPLOYMENT-WORKFLOW](./CONTRACT-DEPLOYMENT-WORKFLOW.md) — Forge deployment and BaseScan verification, including the constructor-arg difference between the two variants.
