Forge presale script workflow explains how the operator-only `DeployPresale.s.sol` and `StartPresale.s.sol` scripts deploy, enable, and seed a mainnet presale; read this before changing those scripts, their hardcoded Base addresses, presale extension ordering, TBONK defaults, or the seeded presale metadata in `server/presales.js`.

This page covers natural-language queries such as `DeployPresale`, `StartPresale`, `BonkerPresaleEthToCreator`, `BonkerPresaleAllowlist`, `startPresale`, `PRESALE_CONTRACT`, `seedPresaleEvents`, "why is presale the last extension", "why does StartPresale set deployer as admin", "what is the TBONK presale config", and "why is presale event metadata hardcoded in the poller". It focuses on the Forge script path. The browser `/admin` workflow, buyer lifecycle, and allowlist claim rules are covered by nearby docs.

## Why It Exists

Bonker has a public presale system, but the first production presale stack was bootstrapped through Forge scripts. That path is different from both normal factory deployment and the browser admin console.

`script/DeployPresale.s.sol` deploys the presale extension contract and its allowlist companion, enables the allowlist on the presale contract, then enables the presale extension on the factory. It is an infrastructure script: it changes which contracts can participate in `Bonker.deployToken`.

`script/StartPresale.s.sol` is a one-off starter for a TBONK test presale. It assembles a full `IBonker.DeploymentConfig`, adds a 10% airdrop and 20% presale extension, ensures the broadcaster is a presale admin, and calls `BonkerPresaleEthToCreator.startPresale`.

Writing this down matters because the scripts are mainnet-facing and broadcast real contract writes when run with `--broadcast`. They also carry hardcoded deployed addresses. If one address drifts from `client/config/contracts.js`, `server/presales.js`, or `CLAUDE.md`, the script can create a presale that the website cannot poll or a contract stack that the factory will not accept.

The scripts also leave one server-side follow-up: `server/presales.js` stores event metadata for known presales by hand. Chain reads expose the presale struct, but the UI also wants original event-only fields such as presale duration and extension composition.

## Key Files

| File | Why it matters |
| --- | --- |
| `script/DeployPresale.s.sol:10` | Declares the script purpose: deploy Presale + Allowlist extensions and enable them on the factory. |
| `script/DeployPresale.s.sol:13` | Reads `BONKER_PRIVATE_KEY`, the only environment input used by the deploy script. |
| `script/DeployPresale.s.sol:15` | Hardcodes the owner address passed to `BonkerPresaleEthToCreator`. |
| `script/DeployPresale.s.sol:16` | Hardcodes the live Bonker factory address that receives `setExtension`. |
| `script/DeployPresale.s.sol:17` | Hardcodes the Bonker ETH fee recipient for presale `claimEth` fees. |
| `script/DeployPresale.s.sol:23` | Deploys `BonkerPresaleEthToCreator(owner, factoryAddr, bonkerFeeRecipient)`. |
| `script/DeployPresale.s.sol:26` | Deploys `BonkerPresaleAllowlist` bound to the presale contract address. |
| `script/DeployPresale.s.sol:30` | Enables the allowlist contract on the presale extension. |
| `script/DeployPresale.s.sol:33` | Enables the presale extension on the factory. |
| `script/StartPresale.s.sol:11` | Documents the TBONK starter intent: 10% airdrop, 20% presale, 1-week duration. |
| `script/StartPresale.s.sol:14` | Hardcodes the live factory address used by the starter config. |
| `script/StartPresale.s.sol:15` | Hardcodes the dynamic hook used for the presale token pool. |
| `script/StartPresale.s.sol:16` | Hardcodes the fee-conversion LP locker used in the deployment config. |
| `script/StartPresale.s.sol:17` | Hardcodes the MEV module used in the deployment config. |
| `script/StartPresale.s.sol:19` | Hardcodes the live airdrop V2 extension. |
| `script/StartPresale.s.sol:20` | Hardcodes the live presale extension address. |
| `script/StartPresale.s.sol:28` | Encodes dynamic hook fee data for the token pool. |
| `script/StartPresale.s.sol:32` | Encodes `poolData` as `(extension, extensionData, feeData)`. |
| `script/StartPresale.s.sol:33` | Encodes MEV module descending-fee data. |
| `script/StartPresale.s.sol:38` | Encodes LP locker fee-conversion preferences. |
| `script/StartPresale.s.sol:45` | Adds the airdrop extension as the first extension config. |
| `script/StartPresale.s.sol:60` | Adds the presale extension as the last extension config. |
| `script/StartPresale.s.sol:76` | Casts the presale contract before admin setup and `startPresale`. |
| `script/StartPresale.s.sol:77` | Checks whether the broadcaster is already a presale admin. |
| `script/StartPresale.s.sol:79` | Grants presale admin rights to the broadcaster when missing. |
| `script/StartPresale.s.sol:82` | Calls `startPresale` with the assembled config and sale parameters. |
| `script/StartPresale.s.sol:99` | Starts `_baseConfig`, the helper that builds the full `IBonker.DeploymentConfig`. |
| `src/extensions/BonkerPresaleEthToCreator.sol:143` | Documents `startPresale` contract requirements for the last extension entry. |
| `src/extensions/BonkerPresaleEthToCreator.sol:176` | Enforces that the presale extension is the last extension config. |
| `src/extensions/BonkerPresaleEthToCreator.sol:227` | Rewrites the presale extension data to encode the assigned `presaleId`. |
| `src/extensions/BonkerPresaleEthToCreator.sol:280` | Begins `endPresale`, which later deploys the token through the saved config. |
| `src/extensions/BonkerPresaleEthToCreator.sol:330` | Calls `factory.deployToken(presale.deploymentConfig)`. |
| `src/extensions/BonkerPresaleEthToCreator.sol:559` | Receives the reserved token supply from the factory after deployment. |
| `server/presales.js:11` | Reads `PRESALE_CONTRACT`; without it the poller is disabled. |
| `server/presales.js:155` | Starts the hardcoded event metadata seeding function. |
| `server/presales.js:156` | Seeds metadata for presale 1, the TBONK script-created presale. |

## How It Works

### Deployment Script

`DeployPresale` is for installing the presale infrastructure, not for creating a sale.

It starts from `BONKER_PRIVATE_KEY`, then uses three hardcoded addresses:

- `owner`: the owner/admin root for `BonkerPresaleEthToCreator`;
- `factoryAddr`: the already deployed Bonker factory;
- `bonkerFeeRecipient`: the address that receives the Bonker fee when raised ETH is claimed.

Inside the broadcast window it deploys `BonkerPresaleEthToCreator`, deploys `BonkerPresaleAllowlist(address(presale))`, calls `presale.setAllowlist(address(allowlist), true)`, and calls `factory.setExtension(address(presale), true)`.

The allowlist enablement is scoped to the presale contract. The factory does not know about `BonkerPresaleAllowlist`; the factory only needs to know that `BonkerPresaleEthToCreator` is an enabled extension allowed to receive reserved token supply during `deployToken`.

The script does not set `PRESALE_CONTRACT` for the server, does not update `client/config/contracts.js`, and does not update `CLAUDE.md`. Those are separate config propagation tasks after a new presale deployment.

### Starter Script

`StartPresale` creates a specific sale against already deployed infrastructure.

It hardcodes the live factory, dynamic hook, LP locker, MEV module, WETH, airdrop, and presale addresses. It then builds the same kind of `IBonker.DeploymentConfig` the browser admin console builds, but with TBONK defaults baked into Solidity source.

The config has four important nested payloads:

```text
feeData
  -> dynamic hook config
poolData
  -> (extension = address(0), extensionData = "", feeData)
mevModuleData
  -> descending fee config
lockerData
  -> fee-conversion locker preferences
extensionConfigs
  -> [AirdropV2 10%, Presale 20%]
```

The presale extension must be the final entry in `extensionConfigs`. The contract enforces that in `startPresale`, then overwrites the final entry's placeholder `extensionData` with `abi.encode(presaleId)`. That rewritten deployment config is what later powers `endPresale`.

Before calling `startPresale`, the script checks `presale.admins(deployer)`. If false, it calls `presale.setAdmin(deployer, true)` inside the same broadcast. That only works when the broadcaster is authorized to mutate `OwnerAdmins`; it is not a bypass around contract permissions.

The starter's sale parameters are fixed in source:

| Setting | Value |
| --- | --- |
| Name | `Test Bonk` |
| Symbol | `TBONK` |
| Airdrop supply | `1000` BPS, or 10% |
| Presale supply | `2000` BPS, or 20% |
| Minimum ETH goal | `0.001 ether` |
| Maximum ETH goal | `0.01 ether` |
| Presale duration | `7 days` |
| Presale owner | broadcaster/deployer |
| Claim lockup | `7 days` |
| Claim vesting | `7 days` |
| Allowlist | `address(0)` |

### After The Sale Starts

Once `startPresale` succeeds, the presale exists on chain and the server can discover it only if production has `PRESALE_CONTRACT` set to the presale extension address.

The poller reads `getPresale(id)` for sequential IDs. That returns the durable presale struct, including the saved deployment config, status, goals, raised ETH, token address, token supply, and claim timing.

The poller also calls `seedPresaleEvents()` at startup. For presale 1, it manually inserts event metadata:

- block `43127039`;
- duration `604800`;
- a 10% airdrop extension;
- a 20% presale extension.

That seed exists because `getPresale` does not expose every UI-friendly event field in the same shape the launchpad wants. If a future Forge-created presale needs extension badges or duration shown correctly before a general event indexer exists, its event metadata needs a similar entry in `server/presales.js`.

### Ending The Presale

`StartPresale` does not deploy the token. Token deployment happens later through `BonkerPresaleEthToCreator.endPresale`.

`endPresale` can proceed when the presale has hit max, or when min has been reached and the presale can be ended after the deadline, or when the presale owner ends early after min is reached. The owner gets a `SALT_SET_BUFFER` window to choose the salt before other callers can provide one.

When `endPresale` proceeds, it writes the chosen salt into the saved `deploymentConfig`, sets `deploymentExpected = true`, and calls `factory.deployToken(presale.deploymentConfig)`. During that factory deployment, the presale extension's `receiveTokens` receives the reserved presale supply and moves the sale to `Claimable`.

## Invariants And Edge Cases

### Address Drift

Both scripts hardcode mainnet addresses. Any redeploy of factory, hook, LP locker, MEV module, airdrop, presale, or WETH assumptions must be propagated before running the scripts.

The important drift surfaces are `client/config/contracts.js`, `server/presales.js`, `CLAUDE.md`, `client/public/skill.md`, and the Forge scripts themselves. A mismatch can create a presale that starts successfully but is invisible to the UI, points at disabled modules, or cannot deploy its token.

### Broadcast Safety

Both scripts call `vm.startBroadcast(deployerKey)`. Running them with `--broadcast` submits real Base mainnet transactions.

Dry-run first without `--broadcast`, inspect the target addresses and emitted logs, and only broadcast after the operator intentionally approves the live write. This is the same mainnet safety rule as deployment scripts and token-selling scripts.

### Extension Ordering

The presale extension must be the last entry in `deploymentConfig.extensionConfigs`. This is not just convention. `BonkerPresaleEthToCreator.startPresale` checks the last entry and then rewrites only that last entry's `extensionData` to the assigned `presaleId`.

If another extension is placed after the presale, `startPresale` reverts with `PresaleNotLastExtension`. If the presale entry has `extensionBps == 0`, it reverts with `InvalidPresaleSupply`. If the presale entry carries `msgValue`, it reverts with `InvalidMsgValue`.

### Placeholder Extension Data

`StartPresale` encodes the presale extension's initial `extensionData` as `abi.encode(uint256(0))`. That value is intentionally temporary.

The contract replaces it with `abi.encode(presaleId)` during `startPresale`, then `receiveTokens` decodes that value during the later token deployment. Callers should not expect the placeholder ID to survive into the saved config.

### Admin Mutation

The starter tries to grant the broadcaster presale admin rights if missing. That works only if the broadcaster can call `setAdmin` on `BonkerPresaleEthToCreator`.

If the broadcaster is not the presale owner or an authorized admin root, the script will fail before `startPresale`. The browser admin console has the same underlying contract permission boundary: UI controls do not create authorization.

### Simulation Target

`BonkerPresaleEthToCreator.startPresale` recommends simulating `factory.deployToken(deploymentConfig)` until it reaches `NotExpectingTokenDeployment()`. That means the config is valid deep enough to reach the presale extension, where deployment is intentionally blocked because `deploymentExpected` is false.

The Forge starter does not perform that simulation. If its hardcoded config drifts, the sale can start but later fail to deploy after contributors have bought in. The contract has `DEPLOYMENT_BAD_BUFFER` to eventually mark such a sale failed, but avoiding the bad config is better than relying on that escape hatch.

### Server Visibility

The presale poller is disabled when `PRESALE_CONTRACT` is unset. A successful Forge `startPresale` transaction will not appear on `/launchpad` unless the running server points at the same presale extension contract.

The poller discovers presales by sequential IDs and stops when a missing ID is reached. That matches the contract's monotonic `_presaleId` assignment, but it means event metadata seeding must use the same numeric ID the contract emitted.

### Allowlist Wiring

`DeployPresale` enables the allowlist contract globally on the presale extension. Individual sales still choose whether to use an allowlist in their `startPresale` call.

The TBONK starter passes `allowlist: address(0)` and empty initialization data, so it creates a public presale. To start an allowlisted Forge presale, the script would need to pass the enabled allowlist address and ABI-encoded `BonkerPresaleAllowlist.AllowlistInitializationData`.

## Cross-References

- [PRESALE-LIFECYCLE](./PRESALE-LIFECYCLE.md) for the buyer-facing and contract-facing lifecycle after a presale exists.
- [PRESALE-ALLOWLIST-LIFECYCLE](./PRESALE-ALLOWLIST-LIFECYCLE.md) for Merkle proofs, owner overrides, and per-presale allowlist controls.
- [ADMIN-OPERATIONS-CONSOLE](./ADMIN-OPERATIONS-CONSOLE.md) for the browser `/admin` path that creates and manages presales without the Forge starter.
- [CONTRACT-DEPLOYMENT-WORKFLOW](./CONTRACT-DEPLOYMENT-WORKFLOW.md) for the broader Forge deployment suite and mainnet broadcast safety.
- [CONTRACT-CONFIG-TOPOLOGY](./CONTRACT-CONFIG-TOPOLOGY.md) for address drift surfaces across client, server, scripts, and public docs.
- [FACTORY-EXTENSION-LIFECYCLE](./FACTORY-EXTENSION-LIFECYCLE.md) for the shared `IBonker.ExtensionConfig[]` boundary that presales use to reserve supply.
- [AIRDROP-EXTENSION-LIFECYCLE](./AIRDROP-EXTENSION-LIFECYCLE.md) for the airdrop extension payload used by the TBONK starter.
- [LP-LOCKER-FEE-CONVERSION-LIFECYCLE](./LP-LOCKER-FEE-CONVERSION-LIFECYCLE.md) for the fee-conversion `lockerData` encoded by the starter script.
