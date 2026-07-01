Contract deployment workflow explains how Bonker's Forge scripts deploy, configure, and verify the factory stack on Base; read this before changing `script/DeployStep1.s.sol`, `script/MineHookAddress.s.sol`, `script/RedeployStep2.s.sol`, `script/DeployLpLocker.s.sol`, `scripts/verify-all.sh`, Forge profiles, linked libraries, or hook constructor arguments.

This doc covers natural-language queries such as `FOUNDRY_PROFILE=lplocker`, `optimizer_runs = 200`, `DeployLpLocker`, `MineHookAddress`, `DYNAMIC_HOOK_SALT`, `STATIC_HOOK_SALT`, `BonkerDeployer` library linking, `CREATE2_PROXY`, `setLocker`, `setDeprecated(false)`, `forge verify-contract`, "LpLocker exceeds 24KB", "hook permission flags", "profile leak", and "BaseScan similar match". The deployment workflow is not just a list of commands. It is a dependency graph where hook addresses depend on factory and allowlist addresses, LpLocker bytecode depends on a different optimizer profile, and BaseScan verification depends on rebuilding with the same profile that produced each deployed bytecode.

## Why It Exists

Bonker owns a forked Clanker-style token factory. The deployed contracts need to agree on a shared set of factory-owned modules before public launches work: hooks, lockers, MEV modules, extensions, fee lockers, and fee recipients.

The tricky part is that several addresses cannot be chosen independently. Uniswap v4 hooks encode permission flags in the low bits of the hook contract address. Bonker therefore mines CREATE2 salts after the factory and pool extension allowlist addresses are known, then deploys the hooks with those salts.

The LpLocker has a separate constraint. The default Forge profile uses 20,000 optimizer runs for the rest of the stack, but `BonkerLpLockerFeeConversion` needs the `lplocker` profile with 200 optimizer runs to stay under the 24KB runtime bytecode limit. That means deployment and verification must switch profiles deliberately, then restore the default profile so other contracts are not accidentally built with LpLocker settings.

The factory starts deprecated. Deployment scripts must explicitly enable the modules that launches are allowed to use, set the team fee recipient, and undeprecate the factory. Missing one config call can produce a deployed contract suite that verifies cleanly but rejects launch transactions.

## Key Files

| File | Why it matters |
| --- | --- |
| `foundry.toml:1` | Defines the default Forge profile used by most contracts. |
| `foundry.toml:14` | Defines the `lplocker` profile with 200 optimizer runs. |
| `src/Bonker.sol:36` | Factory contract that owns deployment allowlists and launch behavior. |
| `src/Bonker.sol:58` | Constructor starts the factory in `deprecated = true` mode. |
| `src/Bonker.sol:66` | `setDeprecated` toggles whether originating-chain deployments are allowed. |
| `src/Bonker.sol:73` | `setTeamFeeRecipient` points protocol fee claims to the Bonker recipient. |
| `src/Bonker.sol:98` | `setHook` enables dynamic and static hooks for new deployments. |
| `src/Bonker.sol:113` | `setLocker` enables a locker for a specific hook. |
| `src/Bonker.sol:127` | `setMevModule` enables the sniper auction module. |
| `src/Bonker.sol:141` | `setExtension` enables launch extensions. |
| `src/Bonker.sol:178` | Factory calls `BonkerDeployer.deployToken` during `deployToken`. |
| `src/utils/BonkerDeployer.sol:8` | Library that deploys `BonkerToken` and must be linked when verifying `Bonker`. |
| `src/utils/BonkerDeployer.sol:15` | Token CREATE2 deployment uses `tokenAdmin` plus token salt. |
| `script/DeployStep1.s.sol:10` | Deploys `BonkerFeeLocker`, `BonkerPoolExtensionAllowlist`, and `Bonker`. |
| `script/MineHookAddress.s.sol:12` | Mines hook salts for Foundry's deterministic CREATE2 deployer. |
| `script/MineHookAddress.s.sol:19` | Defines the Uniswap v4 hook flags that the mined address must carry. |
| `script/MineHookAddress.s.sol:57` | Brute-force salt loop and predicted address check. |
| `script/RedeployStep1.s.sol:7` | Redeploys only the factory when FeeLocker and allowlist can be reused. |
| `script/RedeployStep2.s.sol:13` | Redeploys hooks, MEV module, and airdrop while leaving LpLocker for the 200-run script. |
| `script/RedeployStep2.s.sol:71` | Enables hooks, MEV module, airdrop, team fee recipient, and deployments. |
| `script/DeployLpLocker.s.sol:10` | Deploys LpLocker under the low-run optimizer profile. |
| `script/DeployLpLocker.s.sol:45` | Adds LpLocker as a FeeLocker depositor and enables it for both hooks. |
| `script/DeployExtensions.s.sol:10` | Deploys and enables vault and dev-buy extensions. |
| `script/DeployPresale.s.sol:10` | Deploys presale contracts and enables the presale extension on the factory. |
| `scripts/verify-all.sh:37` | Rebuilds default-profile artifacts before default-profile verification. |
| `scripts/verify-all.sh:56` | Verifies `Bonker` with the linked `BonkerDeployer` library. |
| `scripts/verify-all.sh:92` | Switches to the `lplocker` profile for LpLocker verification. |
| `scripts/verify-all.sh:105` | Unsets `FOUNDRY_PROFILE` and rebuilds default artifacts after LpLocker verification. |

## How It Works

### Deployment Graph

The deployed stack is ordered around address dependencies:

```text
BONKER_PRIVATE_KEY
  |
  v
DeployStep1
  - BonkerFeeLocker
  - BonkerPoolExtensionAllowlist
  - Bonker factory (deprecated by constructor)
  |
  v
MineHookAddress
  - uses FACTORY
  - uses POOL_EXTENSION_ALLOWLIST
  - uses POOL_MANAGER
  - uses WETH
  - outputs DYNAMIC_HOOK_SALT and STATIC_HOOK_SALT
  |
  v
RedeployStep2 or DeployStep2
  - dynamic hook
  - static hook
  - MEV module
  - airdrop extension
  - factory allowlist config
  - team fee recipient
  - setDeprecated(false)
  |
  v
DeployLpLocker with FOUNDRY_PROFILE=lplocker
  - LpLocker
  - FeeLocker depositor config
  - factory locker-by-hook config
  |
  v
Optional extension scripts
  - vault and dev buy
  - presale and presale allowlist
```

`DeployStep1` creates the addresses that hook mining needs. It deploys the FeeLocker, pool extension allowlist, and factory with the same deployer as owner. The factory constructor sets `deprecated = true`, so this first step is not enough to launch tokens.

`MineHookAddress` is read-only. It builds the exact hook init code for `BonkerHookDynamicFeeV2` and `BonkerHookStaticFeeV2`, including constructor args, then searches salts against Foundry's deterministic CREATE2 proxy address. The matching salt is valid only for that init code hash. Changing the factory, allowlist, pool manager, WETH, hook bytecode, compiler settings, or constructor shape changes the predicted address and invalidates the old salt.

`RedeployStep2` is the current split redeploy path for factory/token bytecode changes. It reuses the existing FeeLocker and allowlist, deploys new hooks with the mined salts, deploys a new MEV module and airdrop extension, enables those modules on the new factory, sets `teamFeeRecipient`, and calls `setDeprecated(false)`.

`DeployLpLocker` handles the locker after the default-profile contracts are done. It deploys `BonkerLpLockerFeeConversion`, adds it as a FeeLocker depositor, then enables the same locker for both the dynamic and static hook addresses. The factory stores lockers by `(locker, hook)`, so enabling the locker once is not enough.

`DeployExtensions` and `DeployPresale` are post-core scripts. They use fixed deployed factory and infrastructure addresses in the script body rather than environment-driven Step 1 outputs. They are still part of the live factory configuration because they call `factory.setExtension(...)`.

### Fresh Deploy Versus Factory Redeploy

There are two script families:

| Path | What it is for | Main consequence |
| --- | --- | --- |
| `DeployStep1.s.sol` plus `DeployStep2.s.sol` plus `DeployLpLocker.s.sol` | A fresh stack from scratch. | Deploys FeeLocker, allowlist, factory, hooks, MEV module, and airdrop first, then deploys LpLocker under the 200-run profile. |
| `RedeployStep1.s.sol` plus `RedeployStep2.s.sol` plus `DeployLpLocker.s.sol` | A narrower factory/token-bytecode redeploy that reuses independent contracts. | Reuses FeeLocker and allowlist, then deploys hooks and LpLocker separately so each contract uses the intended optimizer profile. |

`DeployStep2.s.sol` leaves LpLocker for the split path: default-profile contracts first, then `DeployLpLocker.s.sol` with `FOUNDRY_PROFILE=lplocker`.

### Hook Salt Mining

Uniswap v4 hook contracts must have addresses with permission bits set in the low 14 bits. Bonker's hooks need:

- `BEFORE_INITIALIZE_FLAG`
- `BEFORE_ADD_LIQUIDITY_FLAG`
- `BEFORE_SWAP_FLAG`
- `AFTER_SWAP_FLAG`
- `BEFORE_SWAP_RETURNS_DELTA_FLAG`
- `AFTER_SWAP_RETURNS_DELTA_FLAG`

`MineHookAddress` combines those flags into `REQUIRED_FLAGS`, masks predicted addresses with `0x3FFF`, and prints the first salt whose low bits match. It computes predicted addresses with:

- deployer: Foundry deterministic CREATE2 proxy `0x4e59b44847b379578588920cA78FbF26c0B4956C`;
- salt: each integer candidate converted to `bytes32`;
- init code hash: hook creation code plus ABI-encoded constructor args.

The output salt is not a general-purpose salt for that hook contract. It is tied to the exact constructor inputs used during mining. After any Step 1 redeploy, mine again with the new `FACTORY` and `POOL_EXTENSION_ALLOWLIST`.

### Factory Configuration

The factory exposes explicit allowlists rather than trusting arbitrary caller-supplied module addresses. That gives deployments a narrow, owner-controlled surface:

- `setHook(address(dynamicHook), true)` and `setHook(address(staticHook), true)` allow pool initialization through those hooks.
- `setLocker(address(lpLocker), address(dynamicHook), true)` allows that locker with the dynamic hook.
- `setLocker(address(lpLocker), address(staticHook), true)` allows that locker with the static hook.
- `setMevModule(address(mevModule), true)` allows launch configs to attach the sniper auction module.
- `setExtension(address(airdrop), true)`, plus later extension scripts, allows launch extension calls.
- `setTeamFeeRecipient(teamFeeRecipient)` controls where `claimTeamFees(token)` sends factory-held protocol fees.
- `setDeprecated(false)` opens originating-chain deployments after all required modules are enabled.

The order matters operationally. Undeprecating before the expected modules are enabled can expose a factory that accepts only a partial set of launch configs. Enabling a module without the corresponding FeeLocker depositor can produce downstream fee or reward behavior that looks like a launch bug.

### Profile Switching

The default Forge profile is for normal contract bytecode:

- Solidity `0.8.28`;
- `viaIR = true`;
- optimizer enabled;
- `optimizer_runs = 20_000`.

The `lplocker` profile overrides only the optimizer runs to `200`. It exists because LpLocker bytecode size is the limiting constraint, not because the rest of the stack should use 200 runs.

`FOUNDRY_PROFILE` is process-wide. If it remains set after a LpLocker operation, later build, verification, or deployment commands can silently use the wrong optimizer settings. The verification script handles this by unsetting `FOUNDRY_PROFILE`, rebuilding default artifacts, switching only for LpLocker verification, then unsetting and rebuilding default artifacts again.

### Verification

`scripts/verify-all.sh` is the canonical verification loop for the deployed address set in that script. It does three important things:

1. It sources `.env.local` if present and requires `ETHERSCAN_API`.
2. It rebuilds with the default profile before verifying default-profile contracts.
3. It switches to `FOUNDRY_PROFILE=lplocker` only for the LpLocker build and verification, then restores default artifacts.

`Bonker` verification needs library linking because `src/Bonker.sol` calls the external `BonkerDeployer` library. The script passes:

```text
--libraries src/utils/BonkerDeployer.sol:BonkerDeployer:<BONKER_DEPLOYER_ADDRESS>
```

Constructor args must match each deployed contract. The script uses `cast abi-encode` so BaseScan receives the same ABI-encoded constructor arguments that Forge used on deployment.

The script deliberately verifies through the Etherscan/BaseScan API. Sourcify is not the expected path for this repo because dependency remappings and relative imports can fail there even when the bytecode is correct.

## Invariants and Edge Cases

### Mainnet Broadcasts Are Explicit

Any command with `--broadcast` changes Base mainnet state and spends real ETH. The deployment scripts do not contain a dry-run guard. Running without `--broadcast` is the safe simulation path; broadcasting should happen only when the exact addresses, salts, env vars, and profile are known.

### Hook Salts Must Match Constructor Args

The mined hook salt is valid only for the hook bytecode and constructor tuple used by `MineHookAddress`. A stale salt can deploy a hook at an address whose low bits do not match the required flags. That kind of mismatch is address-level, so fixing it means mining and deploying again, not changing a factory allowlist entry.

### LpLocker Must Be Enabled Per Hook

`enabledLockers` is a nested mapping from locker to hook. A successful LpLocker deployment plus `feeLocker.addDepositor(address(lpLocker))` is still incomplete unless the factory also enables that locker for each hook that launch configs can use.

### Factory Starts Closed

The factory constructor sets `deprecated = true`. This is a deployment safety rail: a freshly deployed factory should not accept token launches until owner/admin config has been applied. If launches revert with `Deprecated()`, check whether the final `setDeprecated(false)` step ran against the same factory address the frontend uses.

### Extension Scripts Use Embedded Addresses

`DeployExtensions.s.sol` and `DeployPresale.s.sol` contain fixed addresses in the source file. After a factory redeploy, these scripts must be inspected before use because they can still point at the previous factory.

### Verification Depends on Artifact Profile

BaseScan verification compares deployed bytecode against compiler output. If default-profile contracts are built under `FOUNDRY_PROFILE=lplocker`, their verification can fail or, worse, produce artifacts that do not represent the deployed stack. Always rebuild with the intended profile before verifying each profile group.

### `verify-all.sh` Address Constants Are Part of the Input

The verification script is not address discovery. It verifies the hardcoded address set near the top of the file. After any redeploy, those constants must match the newly deployed contracts before the script is run.

### Fee Recipient Is Runtime Configuration

The team fee recipient is not a constructor arg on `Bonker`. It is set after deployment through `setTeamFeeRecipient`. A factory can be deployed and verified while still having `teamFeeRecipient == address(0)`, which would make `claimTeamFees(token)` revert with `TeamFeeRecipientNotSet()`.

## Cross-References

- [LAUNCH-FORM-DEPLOYMENT-CONFIG](./LAUNCH-FORM-DEPLOYMENT-CONFIG.md) explains how the frontend builds `IBonker.DeploymentConfig` for the factory after this deployment workflow has enabled hooks, lockers, MEV modules, and extensions.
- [TOKEN-DETAIL-ENRICHMENT](./TOKEN-DETAIL-ENRICHMENT.md) explains how deployed factory events and configured module addresses become API and token detail page data.
- [PRESALE-LIFECYCLE](./PRESALE-LIFECYCLE.md) explains how the presale extension interacts with the deployed factory and why `DeployPresale.s.sol` matters after the core stack exists.
- [SEO-CRAWLER-PIPELINE](./SEO-CRAWLER-PIPELINE.md) explains the crawler-facing behavior that depends on the server knowing token pages emitted by the deployed factory.
