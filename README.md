# Bonker Contracts — Audit Package

Self-contained Foundry project with the Bonker Solidity contracts, tests, and
deployment scripts. Frontend, server, and operator tooling are intentionally
excluded — this repo is the audit scope only.

## What Bonker is

Bonker is a custom token factory on **Base**, a fork of
[clanker-devco/v4-contracts](https://github.com/clanker-devco/v4-contracts).
The factory owner (Bonker) receives the protocol fee instead of Clanker.

Only two intentional changes from upstream Clanker:

1. `PROTOCOL_FEE_NUMERATOR` is unchanged (`200_000`) — the difference is factory
   ownership, not the fee math.
2. `BonkerToken.sol` sets `FACTORY_BRAND = "bonker.wtf"`, so the ERC20 bytecode
   differs from `ClankerToken` (verified-source distinction on BaseScan).

All other logic mirrors upstream Clanker v4 contracts.

## Build & test

Dependencies are git submodules. Clone recursively (or init after cloning):

```bash
git clone --recurse-submodules https://github.com/bonker-wtf/contracts.git
# or, in an existing clone:
git submodule update --init --recursive

forge build --via-ir
forge test  --via-ir
```

Toolchain: Foundry (forge 1.3.2), `solc 0.8.28`, `viaIR = true`,
`evm_version = cancun`, 20k optimizer runs (see `foundry.toml`).

> **LpLocker profile:** `BonkerLpLockerFeeConversion` exceeds the 24KB EIP-170
> limit at 20k runs. It is compiled under the `lplocker` profile (200 runs):
> `FOUNDRY_PROFILE=lplocker forge build --via-ir`. This affects **only** that
> contract's production bytecode; all other contracts use the default profile.

`lib/` submodules: Uniswap v4-core/v4-periphery, universal-router, permit2,
OpenZeppelin, Solady, Optimism, forge-std (pinned to the exact commits used for
the mainnet deployment).

## Layout

```
src/
  Bonker.sol                     # Factory: deployToken, pool init, protocol-fee sweep
  BonkerToken.sol                # ERC20Votes/Permit/Burnable token
  BonkerFeeLocker.sol            # Per-recipient escrow ledger for creator/reward fees
  hooks/                         # Uniswap v4 hooks (live: *V2; legacy: non-V2)
    BonkerHookV2.sol             #   base hook (fee accounting, pool extensions)
    BonkerHookDynamicFeeV2.sol   #   dynamic-fee variant (MEV/sniper aware)
    BonkerHookStaticFeeV2.sol    #   static-fee variant
    BonkerPoolExtensionAllowlist.sol
  extensions/                    # Airdrop (v1/v2), Vault, Presale, DevBuy (v3/v4)
  lp-lockers/                    # Fee-conversion locker (live) + multi-recipient (dormant)
  mev-modules/                   # Sniper auction (v0/v2), block/time delay, descending fees
  interfaces/                    # Shared interfaces
  utils/                         # BonkerDeployer (linked library), OwnerAdmins
script/                          # Forge deployment scripts (not audit-critical logic)
test/                            # Foundry regression suite
lib/                             # Vendored dependencies
```

### Live vs. legacy / dormant

Some contracts are kept for history but are **not** the deployed path. The live
production set on Base uses the `*V2` hooks, `BonkerSniperAuctionV2`,
`BonkerLpLockerFeeConversion`, and `BonkerUniv4EthDevBuy`. Legacy/dormant:
`BonkerHook.sol`, `BonkerHookDynamicFee.sol`, `BonkerHookStaticFee.sol`,
`BonkerSniperAuctionV0.sol`, `BonkerSniperUtilV0.sol`,
`BonkerLpLockerMultiple.sol`, `BonkerUniv3EthDevBuy.sol`, `BonkerAirdrop.sol`.

## Deployed contracts (Base mainnet, chainId 8453)

| Contract | Address |
|----------|---------|
| BonkerDeployer (library) | `0x140c9eb85b4204cfcc8e345ce7894edb315a3043` |
| FeeLocker | `0x473e52D89bE6ea78f94d1b5c62Bd1f01b1E32e21` |
| PoolExtensionAllowlist | `0x00d9C6dda8D6DC9fc735B8a10a62AA6AE070510C` |
| Factory (Bonker) | `0xD850DACe6c3E3B3cf09ABb92342Fab681013c8cB` |
| DynamicHook | `0x963E91A45148b39737b9DF10c5b897B55cA9e8cC` |
| StaticHook | `0xC9156C1868E122eF5b3e6ed946e1E88ff7da68Cc` |
| LpLocker | `0xBf05b1d5E356f3219D0086A4e09c969ADbe2e7d0` |
| MevModule (SniperAuctionV2) | `0x6a04057180F8cc02E18DabEE3f3437E438BE657A` |
| Airdrop | `0xa727da00eDd0F98Dc5Fb5D3b9eA09646CB809A87` |
| Vault | `0x26a4654E85CD8cc3Ba08dBC05418c63300624c8e` |
| DevBuy | `0xc00Ab3631E82902f55B62EB95A0101eE2eb91a69` |
| Presale | `0x60729328cF4fd3E6996dee350308EcB238FCa5D7` |
| PresaleAllowlist | `0x824a424808F9a20a0bBf831634e2f460D8db256B` |

All verified on BaseScan.

## Documentation (`docs/`)

Contract-level design docs are included to speed up review (frontend/server/ops
docs from the main repo are intentionally omitted). Highlights:

- `FEE-FLOW-END-TO-END.md`, `FEE-ESCROW-AND-CLAIM.md`, `HOOK-FEE-ACCOUNTING.md` — money flow
- `FACTORY-EXTENSION-LIFECYCLE.md`, `FACTORY-COMPONENT-REGISTRY.md` — deploy-time wiring & allowlisting
- `MEV-MODULE-LIFECYCLE.md`, `SNIPER-AUCTION-BID-MECHANICS.md` — launch MEV protection
- `POOL-INITIALIZATION-AND-LIQUIDITY-SEEDING.md`, `POOL-EXTENSION-HOOK-LIFECYCLE.md` — pool setup
- `RESERVED-SUPPLY-VESTING-MODEL.md`, `VAULT-/AIRDROP-/PRESALE-*` — reserved supply & vesting
- `NATIVE-ETH-WETH-CURRENCY-MODEL.md`, `NON-STANDARD-ERC20-TRANSFER-SAFETY.md`, `V4-FLASH-ACCOUNTING-SETTLEMENT.md` — value-handling invariants
- `SOLIDITY-CUSTOM-ERROR-REFERENCE.md`, `HOOK-VERSION-COMPARISON.md` — triage & live-vs-legacy map

## Notes for reviewers

- **Fee flow** splits two ways: LP fees escrow in `BonkerFeeLocker` for the
  reward recipient; the protocol fee is swept to the factory and claimed by the
  factory owner via `claimTeamFees`.
- **Native ETH vs WETH:** every internal balance (pool reserves, protocol fees,
  LP escrow, auction payments) is WETH (ERC20). ETH only wraps/unwraps at user
  entry/exit points.
- **Non-standard ERC20 safety:** `SafeERC20` + balance-delta accounting tolerate
  missing-return-value and fee-on-transfer tokens (see
  `test/BonkerLegacyErc20Safety.t.sol`).
- **Reserved-supply vesting** (cliff lockup + linear vesting) is reimplemented
  independently in the vault, both airdrops, and the presale extension.
