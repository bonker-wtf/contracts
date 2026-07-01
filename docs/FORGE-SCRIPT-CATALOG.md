# Forge Script Catalog

A decision map over every `script/*.sol` file: which script to run for which situation, how they chain, and the traps that come from picking the wrong one. Read this when you open `script/`, when you are unsure whether to run the monolithic `Deploy.s.sol` or the split `DeployStep1`/`DeployStep2`/`DeployLpLocker` path, when a redeploy only touched token bytecode, when you need a one-off extension add, or before broadcasting any Forge script to Base mainnet. Natural-language queries this answers: "which deploy script do I run", "what is Deploy.s.sol vs DeployStep1", "why is there a separate LpLocker script", "what does TestExtensions do", "DEPLOYER_PRIVATE_KEY vs BONKER_PRIVATE_KEY", "how do I add a new extension", "what is HookDeployer", "RedeployStep1 vs DeployStep1".

This page is the index. For the canonical happy-path deploy walkthrough (env vars, `--code-size-limit`, the `lplocker` profile, BaseScan verification) see [CONTRACT-DEPLOYMENT-WORKFLOW](./CONTRACT-DEPLOYMENT-WORKFLOW.md). This page exists to disambiguate the 14 scripts, several of which overlap or are dead.

## Why It Exists

`script/` has accreted three generations of deployment code: a monolithic `Deploy.s.sol`, a split `DeployStep1` → `DeployStep2` → `DeployLpLocker` path, and a `RedeployStep1` → `RedeployStep2` path for partial redeploys. They overlap heavily — all three build the same factory stack — but only the split path actually works on mainnet, because `BonkerLpLockerFeeConversion` exceeds the 24KB contract size limit at the default 20k optimizer runs and must be compiled separately under `FOUNDRY_PROFILE=lplocker` (200 runs). The monolithic `Deploy.s.sol` keeps LpLocker inline and therefore cannot be broadcast as-is at the default profile.

A maintainer staring at `Deploy.s.sol`, `DeployStep1.s.sol`, and `RedeployStep1.s.sol` has no way to know from filenames alone which one is live. This catalog records that, plus the per-script env-key and broadcast hazards.

## Key Files

| File | Role |
| --- | --- |
| `script/Deploy.s.sol:43` | Monolithic full-stack deploy. **Reference only — do not broadcast.** |
| `script/DeployStep1.s.sol:13` | Live step 1: FeeLocker, Allowlist, Factory. |
| `script/MineHookAddress.s.sol:12` | Read-only: mine CREATE2 hook salts (no broadcast). |
| `script/DeployStep2.s.sol:19` | Live step 2: hooks, MevModule, Airdrop + factory config. |
| `script/DeployLpLocker.s.sol:12` | Live step 3: LpLocker under `lplocker` profile + locker wiring. |
| `script/HookDeployer.sol:8` | CREATE2 helper contract; not a `Script`. |

(continued)

| File | Role |
| --- | --- |
| `script/RedeployStep1.s.sol:9` | Partial redeploy: new Factory only (reuse FeeLocker/Allowlist). |
| `script/RedeployStep2.s.sol:16` | Partial redeploy: hooks, MevModule, Airdrop on the new factory. |
| `script/DeployExtensions.s.sol:11` | One-off: deploy + enable Vault and DevBuy. |
| `script/DeployPresale.s.sol:10` | One-off: deploy + enable Presale and PresaleAllowlist. |
| `script/TestExtensions.s.sol:19` | Mainnet smoke test: deploys two real test tokens. |
| `script/StartPresale.s.sol:11` | Operational: start a TBONK presale. |
| `script/SellToken.s.sol:22` | Operational: dump the operator's full token balance to WETH. |
| `script/TransferOwnership.s.sol:53` | Operational: hand ownership to `NEW_OWNER`, migrate fees. |

## The Three Deploy Generations

### Monolithic — `Deploy.s.sol` (do not broadcast)

`Deploy.s.sol:43` deploys all eight pieces in dependency order (FeeLocker → Allowlist → Factory → both hooks via mined salts → LpLocker → MevModule → Airdrop) and runs every post-deploy config call in one transaction batch. It is the cleanest description of the *full* dependency chain and the post-deploy wiring, which is why it survives as documentation-in-code.

But it constructs `BonkerLpLockerFeeConversion` inline at `Deploy.s.sol:87`. At the default 20k-run profile that bytecode blows the 24KB limit, so the broadcast reverts. It also reads `DEPLOYER_PRIVATE_KEY` (`Deploy.s.sol:45`) — the **only** script in the directory that does not use `BONKER_PRIVATE_KEY`. Treat it as a read-only map of the stack, not a runnable deploy.

### Split — `DeployStep1` → mine → `DeployStep2` → `DeployLpLocker` (live)

This is the path that actually deployed the live Base contracts. It exists precisely to break LpLocker out into its own 200-run compile:

- `DeployStep1.s.sol:13` — FeeLocker, Allowlist, Factory. No hooks yet (their addresses depend on the factory + allowlist addresses).
- `MineHookAddress.s.sol:11` — read-only; prints `DYNAMIC_HOOK_SALT` / `STATIC_HOOK_SALT` for the step-1 addresses.
- `DeployStep2.s.sol:19` — both hooks via CREATE2 mined salts (`DeployStep2.s.sol:48`), MevModule, Airdrop, then `setHook`/`setMevModule`/`setExtension`/`setTeamFeeRecipient`/`setDeprecated(false)`. Adds the MevModule as a FeeLocker depositor. Does **not** touch LpLocker.
- `DeployLpLocker.s.sol:12` — builds LpLocker (`DeployLpLocker.s.sol:34`), adds it as a FeeLocker depositor, and calls `setLocker` for each hook. Must run with `FOUNDRY_PROFILE=lplocker`.

### Partial redeploy — `RedeployStep1` → mine → `RedeployStep2` → `DeployLpLocker` (live)

When only `BonkerToken`/`BonkerDeployer`/factory bytecode changed, FeeLocker and Allowlist are unchanged and reusable. `RedeployStep1.s.sol:9` deploys just a fresh Factory; everything downstream (hooks, MevModule, Airdrop, LpLocker) must be redeployed against it because hook salts and module wiring are factory-specific. `RedeployStep2.s.sol:16` mirrors `DeployStep2` but reads the existing `FEE_LOCKER`/`POOL_EXTENSION_ALLOWLIST` instead of deploying them. Finish with `DeployLpLocker` as in the fresh path.

The difference from the fresh split path is only steps 1: `DeployStep1` creates three contracts, `RedeployStep1` creates one.

## HookDeployer Is Not a Script

`script/HookDeployer.sol:7` is a plain contract, not a `forge-std` `Script`. It wraps `new BonkerHookDynamicFeeV2{salt}(...)` / `new BonkerHookStaticFeeV2{salt}(...)` so a hook can be deployed via CREATE2 "from a known address so salt mining is deterministic." The live deploy scripts inline the same `new X{salt: ...}` expression directly (Foundry routes those through the deterministic CREATE2 proxy automatically), so `HookDeployer` is not on the critical path of the split deploy — it is an alternate deterministic-deploy helper. Do not confuse it with `MineHookAddress.s.sol`, which only *computes* salts and never deploys.

## One-Off and Operational Scripts

`DeployExtensions.s.sol:11` and `DeployPresale.s.sol:10` are additive: they deploy a pair of extension contracts against the already-live factory at `0xD850DACe6c3E3B3cf09ABb92342Fab681013c8cB` (hardcoded) and call `setExtension`. They are how Vault/DevBuy (deployed 2026-03-06) and Presale/PresaleAllowlist (2026-03-07) were added without a full redeploy. Use this shape to register a new extension: deploy it, then `setExtension(addr, true)`.

`TestExtensions.s.sol:19` is a mainnet smoke test, not infrastructure. It deploys two *real* tokens through the live factory — a "Vault Test" token with 5% supply vaulted on a 7-day lockup, and a "DevBuy Test" token with a 0.001 ETH creator buy bundled into deploy (`TestExtensions.s.sol:70` and `:103`). Its `_baseConfig` helper (`TestExtensions.s.sol:110`) is a faithful, hand-written `IBonker.DeploymentConfig` tuple — useful as a concrete reference for the calldata schema. Broadcasting it spends real ETH and mints real tokens.

`StartPresale.s.sol:13`, `SellToken.s.sol:21`, and `TransferOwnership.s.sol:53` are operational, covered in depth by their own docs (linked below). `SellToken` reads the target from the `TOKEN` env var and sells the operator's entire balance with no slippage protection.

## Invariants and Edge Cases

- **`BONKER_PRIVATE_KEY` everywhere except `Deploy.s.sol`.** Every live script reads `BONKER_PRIVATE_KEY`; only the dead `Deploy.s.sol` reads `DEPLOYER_PRIVATE_KEY`. A copy-paste from `Deploy.s.sol` that keeps the wrong env key fails or signs with the wrong account.

- **LpLocker is always separate.** Whichever deploy path you take, LpLocker is built by `DeployLpLocker.s.sol` under `FOUNDRY_PROFILE=lplocker`. Letting that profile leak into other builds changes their bytecode and breaks BaseScan verification — `unset FOUNDRY_PROFILE` after.

- **Hook salts are factory-specific.** Any path that deploys a new Factory (`DeployStep1` or `RedeployStep1`) invalidates previously mined salts. Re-run `MineHookAddress` with the new factory + allowlist before `DeployStep2`/`RedeployStep2`.

- **The factory ships deprecated.** `setDeprecated(false)` in `DeployStep2`/`RedeployStep2` is what enables `deployToken`. Skipping it leaves the factory unable to launch tokens even though every module is wired.

- **Post-deploy depositor wiring is mandatory.** LpLocker and MevModule both call `feeLocker.addDepositor(...)`. A locker or MEV module that is not an allowlisted FeeLocker depositor cannot store fees, so launches that route fees through it revert. The split path adds the MevModule depositor in `DeployStep2` and the LpLocker depositor in `DeployLpLocker`.

- **None of these scripts dry-run by default.** There is no broadcast guard; running without `--broadcast` is the only simulation. Broadcasting touches Base mainnet and spends real ETH.

## Cross-References

- [CONTRACT-DEPLOYMENT-WORKFLOW](./CONTRACT-DEPLOYMENT-WORKFLOW.md) — the canonical step-by-step deploy + verify workflow with full env vars and the `lplocker` profile.
- [CONTRACT-CONFIG-TOPOLOGY](./CONTRACT-CONFIG-TOPOLOGY.md) — where the deployed addresses these scripts produce get recorded across client/server/scripts.
- [HOOK-VERSION-COMPARISON](./HOOK-VERSION-COMPARISON.md) — why the live scripts deploy `BonkerHook*V2` and what the V2 constructor shape is.
- [LP-LOCKER-VARIANTS](./LP-LOCKER-VARIANTS.md) — why `BonkerLpLockerFeeConversion` is the deployed locker and why it needs the 200-run profile.
- [FACTORY-EXTENSION-LIFECYCLE](./FACTORY-EXTENSION-LIFECYCLE.md) — what `setExtension` registers and how extensions run during `deployToken`.
- [ENVIRONMENT-VARIABLE-TOPOLOGY](./ENVIRONMENT-VARIABLE-TOPOLOGY.md) — where `BONKER_PRIVATE_KEY` and the infrastructure addresses come from.
- [DEPLOYTOKEN-CALLDATA-SCHEMA](./DEPLOYTOKEN-CALLDATA-SCHEMA.md) — the `IBonker.DeploymentConfig` tuple that `TestExtensions.s.sol` builds by hand.
- [FORGE-PRESALE-SCRIPT-WORKFLOW](./FORGE-PRESALE-SCRIPT-WORKFLOW.md), [FORGE-SELL-TOKEN-SCRIPT](./FORGE-SELL-TOKEN-SCRIPT.md), [OWNERSHIP-TRANSFER-SCRIPT](./OWNERSHIP-TRANSFER-SCRIPT.md) — the operational scripts in depth.
