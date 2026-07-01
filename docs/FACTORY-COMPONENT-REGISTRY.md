# Factory Component Registry

How the `Bonker` factory decides which hook, LP locker, MEV module, and extension contracts a deployment is allowed to use. This page explains the four parallel `enabled*` allowlist mappings, the shared ERC-165 `supportsInterface` self-attestation enforced at registration time, the two-key locker-to-hook compatibility mapping, and the `*NotEnabled` reverts that fire mid-`deployToken` when a component was never allowlisted. Read it before changing `Bonker.setHook`/`setLocker`/`setMevModule`/`setExtension`, the `enabledHooks`/`enabledLockers`/`enabledExtensions`/`enabledMevModules` storage, deploy scripts that call those setters, or when triaging a `HookNotEnabled`, `LockerNotEnabled`, `MevModuleNotEnabled`, `ExtensionNotEnabled`, `InvalidHook`, `InvalidLocker`, `InvalidMevModule`, or `InvalidExtension` revert.

This is the *governance/trust* view of the factory's plug-in system: which addresses are blessed, who blesses them, and where an un-blessed address is rejected. For what each component *does* once it is allowed in, see the per-component lifecycle docs cross-referenced at the bottom.

## Why It Exists

`Bonker.deployToken()` is a generic assembler. It does not hardcode a single hook, locker, MEV module, or extension implementation — it accepts their addresses inside the caller-supplied `DeploymentConfig` and wires them together at launch. That flexibility is also the attack surface: a caller could otherwise point a deployment at a malicious "locker" that drains the pool supply approved to it, or a fake "extension" that keeps the reserved token supply.

The factory closes this with a registry. Only the owner or a factory admin can mark a component address as usable, and `deployToken` refuses any component that is not marked. This is why every pluggable contract type has the same three-part shape:

1. **Registration** — an `onlyOwnerOrAdmin` setter writes a boolean into an `enabled*` mapping.
2. **Self-attestation** — that setter first calls the candidate's `supportsInterface()` and reverts if the candidate does not claim the matching `IBonker*` interface.
3. **Deploy-time gate** — `deployToken` reads the `enabled*` mapping and reverts with a `*NotEnabled` error before ever calling into the component.

Separating registration from use lets the team add, rotate, or retire implementations (a new hook version, a second locker, an extra extension) without redeploying the factory. It also means the entire trust boundary is auditable from four storage mappings and four setters.

## Key Files

| File | Why it matters |
| --- | --- |
| `src/Bonker.sol:53` | `enabledHooks[hook]` — single-key hook allowlist (internal). |
| `src/Bonker.sol:54` | `enabledLockers[locker][hook]` — **two-key** locker-per-hook allowlist (public). |
| `src/Bonker.sol:55` | `enabledExtensions[extension]` — single-key extension allowlist (internal). |
| `src/Bonker.sol:56` | `enabledMevModules[mevModule]` — single-key MEV module allowlist (internal). |
| `src/Bonker.sol:98` | `setHook()` — ERC-165 check, then writes `enabledHooks`, emits `SetHook`. |
| `src/Bonker.sol:113` | `setLocker()` — ERC-165 check, then writes `enabledLockers[locker][hook]`, emits `SetLocker`. |
| `src/Bonker.sol:127` | `setMevModule()` — ERC-165 check, then writes `enabledMevModules`, emits `SetMevModule`. |
| `src/Bonker.sol:141` | `setExtension()` — ERC-165 check, then writes `enabledExtensions`, emits `SetExtension`. |
| `src/Bonker.sol:260` | `_initializePool()` hook gate → `HookNotEnabled`. |
| `src/Bonker.sol:284` | `_initializeLiquidity()` locker gate → `LockerNotEnabled`. |
| `src/Bonker.sol:243` | `_initializeMevModule()` module gate → `MevModuleNotEnabled`. |
| `src/Bonker.sol:335` | `_prepareExtensions()` extension gate → `ExtensionNotEnabled`. |
| `src/interfaces/IBonker.sol:78` | `InvalidHook`/`InvalidLocker`/`InvalidExtension`/`InvalidMevModule` registration errors. |
| `src/interfaces/IBonker.sol:85` | `HookNotEnabled`/`LockerNotEnabled`/`ExtensionNotEnabled`/`MevModuleNotEnabled` deploy-time errors. |
| `src/interfaces/IBonker.sol:125` | `SetHook`/`SetLocker`/`SetMevModule`/`SetExtension` registration events. |
| `script/DeployStep2.s.sol:74` | Post-deploy: enables both hooks, the MEV module, and the airdrop extension. |
| `script/DeployLpLocker.s.sol:49` | Separate LpLocker deploy enables the locker for both hooks. |
| `script/DeployExtensions.s.sol:30` | Enables vault + dev-buy extensions after they are deployed. |
| `script/DeployPresale.s.sol:33` | Enables the presale extension. |

## How It Works

### The four registries are structurally identical except for the locker

Three of the four mappings are single-key — an address is either globally enabled for the factory or not:

```text
enabledHooks[hook]            -> bool
enabledExtensions[extension]  -> bool
enabledMevModules[mevModule]  -> bool
```

The locker registry is the one exception. It is **keyed by both locker and hook**:

```text
enabledLockers[locker][hook]  -> bool
```

A locker must be enabled *for a specific hook*. This exists because an LP locker mints and manages liquidity through a particular hook's pool, so a locker that is safe with the dynamic-fee hook is not automatically trusted with the static-fee hook. `setLocker(locker, hook, true)` must be called once per (locker, hook) pair — which is why the deploy scripts call it twice, once for `dynamicHook` and once for `staticHook` (`script/DeployLpLocker.s.sol:49`).

### Registration enforces ERC-165 self-attestation

Each setter rejects a candidate that does not claim the matching interface. For example `setHook` (`src/Bonker.sol:98`):

```text
if (!IBonkerHook(hook).supportsInterface(type(IBonkerHook).interfaceId)) revert InvalidHook();
enabledHooks[hook] = enabled;
emit SetHook(hook, enabled);
```

The other three follow the same template with `IBonkerLpLocker`/`InvalidLocker`, `IBonkerMevModule`/`InvalidMevModule`, and `IBonkerExtension`/`InvalidExtension`. Every first-party component therefore implements `supportsInterface` returning `true` for its interface id — `BonkerHookV2`, `BonkerLpLockerFeeConversion`, `BonkerSniperAuctionV2`, `BonkerVault`, `BonkerAirdropV2`, and the rest all carry one.

This check is a guard rail, not a security boundary: `supportsInterface` is self-reported, so a hostile contract can lie and still pass. The real protection is that only `onlyOwnerOrAdmin` can call the setter at all. The ERC-165 check exists to catch the common operator mistake of allowlisting the wrong address (a token, a library, a previous version) before it reaches production.

### `deployToken` gates each component at the point of use

The gates are not all in one place — each fires in the sub-step that first touches that component, so a deployment can do partial work before reverting:

- **Extensions** are checked first, in `_prepareExtensions()` (`src/Bonker.sol:335`), during the supply-split pass. Every extension in `extensionConfigs` must be enabled or the whole deploy reverts `ExtensionNotEnabled` before any token is minted into an extension.
- **Hook** is checked in `_initializePool()` (`src/Bonker.sol:260`) → `HookNotEnabled`.
- **Locker** is checked in `_initializeLiquidity()` (`src/Bonker.sol:284`) using the two-key lookup `enabledLockers[locker][hook]` → `LockerNotEnabled`. Note this couples the locker check to the hook the caller chose — a locker enabled for the *other* hook still reverts.
- **MEV module** is checked last, in `_initializeMevModule()` (`src/Bonker.sol:243`) → `MevModuleNotEnabled`.

Because the whole call is `nonReentrant` and a revert rolls back all state, the ordering only matters for gas and for which error you see first when several components are mis-configured: extension errors surface before hook, hook before locker, locker before MEV module.

### Registration happens in the deploy scripts, not at runtime

The registry is populated immediately after the components are deployed. `script/DeployStep2.s.sol` enables both hooks, the MEV module, and the airdrop extension; `script/DeployLpLocker.s.sol` enables the locker for each hook (it is deployed separately under the `lplocker` Foundry profile); `script/DeployExtensions.s.sol` and `script/DeployPresale.s.sol` enable the vault, dev-buy, and presale extensions as they come online. `script/RedeployStep2.s.sol` re-runs the hook/MEV/airdrop enables during a partial redeploy. The full deployed-and-enabled component set lives in [CONTRACT-CONFIG-TOPOLOGY](./CONTRACT-CONFIG-TOPOLOGY.md).

## Invariants and Edge Cases

- **`deprecated = true` in the constructor.** The factory ships paused (`src/Bonker.sol:61`); originating-chain `deployToken` reverts `Deprecated` until the owner calls `setDeprecated(false)`. Allowlisting components does not un-pause the factory — these are independent switches.
- **Disabling is a one-liner.** Calling any setter with `enabled = false` (or `setLocker(locker, hook, false)`) instantly blocks *new* deployments from using that component. It does not affect already-deployed tokens — their hook/locker/module/extension wiring is fixed at launch and stored in `deploymentInfoForToken`.
- **The locker's hook key must match the pool's hook.** A deployment that picks `dynamicHook` but a locker only enabled for `staticHook` reverts `LockerNotEnabled` even though the locker address itself is "enabled" somewhere. This is the single most surprising registry behavior.
- **ERC-165 is necessary but not sufficient.** Passing `supportsInterface` only proves the contract claims the interface. Operators must still verify they are allowlisting the intended audited address.
- **This registry is distinct from the pool-extension allowlist.** Pool-side extensions (consulted by the hook during pool setup/`afterSwap`) live in the separate `BonkerPoolExtensionAllowlist` contract, not in these four factory mappings. Do not conflate `setExtension` (factory supply-reservation extensions) with pool-extension allowlisting — see [POOL-EXTENSION-HOOK-LIFECYCLE](./POOL-EXTENSION-HOOK-LIFECYCLE.md).
- **Only owner/admin can register.** The setters are `onlyOwnerOrAdmin`; the deprecate and team-fee-recipient toggles are stricter (`onlyOwner`). The permission tiers are detailed in [OWNER-ADMIN-PERMISSION-MODEL](./OWNER-ADMIN-PERMISSION-MODEL.md).

## Cross-references

- [FACTORY-EXTENSION-LIFECYCLE](./FACTORY-EXTENSION-LIFECYCLE.md) — what an enabled extension does during `deployToken` (supply reservation, ETH forwarding, callbacks).
- [LP-LOCKER-VARIANTS](./LP-LOCKER-VARIANTS.md) — the deployed fee-conversion locker vs. the dormant multi-recipient locker that the locker registry gates.
- [HOOK-VERSION-COMPARISON](./HOOK-VERSION-COMPARISON.md) — the legacy vs. V2 hooks the hook registry chooses between.
- [MEV-MODULE-LIFECYCLE](./MEV-MODULE-LIFECYCLE.md) — how an enabled MEV module is initialized and consulted per swap.
- [POOL-EXTENSION-HOOK-LIFECYCLE](./POOL-EXTENSION-HOOK-LIFECYCLE.md) — the separate, hook-side pool-extension allowlist.
- [OWNER-ADMIN-PERMISSION-MODEL](./OWNER-ADMIN-PERMISSION-MODEL.md) — who may call the registry setters.
- [CONTRACT-CONFIG-TOPOLOGY](./CONTRACT-CONFIG-TOPOLOGY.md) — the concrete deployed, enabled component addresses.
- [CONTRACT-DEPLOYMENT-WORKFLOW](./CONTRACT-DEPLOYMENT-WORKFLOW.md) — the deploy-script sequence that registers components.
- [SOLIDITY-CUSTOM-ERROR-REFERENCE](./SOLIDITY-CUSTOM-ERROR-REFERENCE.md) — triage map for the `*NotEnabled` / `Invalid*` reverts.
