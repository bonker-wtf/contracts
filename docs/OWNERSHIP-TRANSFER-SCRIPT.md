Ownership transfer script explains how `script/TransferOwnership.s.sol` drains deployer-held operational balances, updates fee recipients, and hands Ownable Bonker contracts to `NEW_OWNER`; read this before changing the ownership handoff script, mainnet owner addresses, fee recipient migration, emergency LpLocker withdrawals, or any broadcastable owner-transfer workflow.

This page covers natural-language queries such as `TransferOwnership`, `NEW_OWNER`, `BONKER_PRIVATE_KEY`, "why does the script claim WETH before transfer", "which contracts are handed off", "why are hooks not transferred", "why is Airdrop not in the ownable array", `setBonkerFeeRecipient`, `withdrawETH`, `withdrawERC20`, and "what does the ownership transfer script skip". It focuses on the one-off operator workflow in `script/TransferOwnership.s.sol`, not the normal deployment suite or public admin console.

## Why It Exists

Bonker's live Base contracts are owned by the deployment wallet until an operator deliberately moves ownership. That wallet also may hold claimable WETH from factory protocol fees, FeeLocker rewards, or stranded LpLocker balances. A plain `transferOwnership()` call on the factory would not move those balances and would not update every contract that has its own owner or fee recipient field.

`script/TransferOwnership.s.sol` is the repo's compact handoff workflow for that job. It uses the `BONKER_PRIVATE_KEY` wallet, points at hardcoded Base-mainnet contract addresses, claims or withdraws relevant WETH and ETH, transfers those proceeds to `NEW_OWNER`, transfers ownership for several Ownable contracts, updates the presale contract's Bonker fee recipient, and keeps a small ETH reserve for gas.

The script is broadcast-capable and production-facing. It contains many `vm.broadcast(deployerKey)` calls. It should be treated like deployment or selling scripts: dry-run first, inspect output, and only broadcast when the operator has explicitly chosen to perform the irreversible mainnet handoff.

This is not the same as the admin console. The `/admin` page can claim factory team fees and toggle modules from a connected wallet, but it does not sweep deployer balances or transfer contract ownership. It is also not the same as the Forge deployment workflow: deployment scripts create and configure the stack, while this script assumes the current live addresses already exist.

## Key Files

| File | Why it matters |
| --- | --- |
| `script/TransferOwnership.s.sol:36` | Declares the `TransferOwnership` script contract. |
| `script/TransferOwnership.s.sol:38` | Starts the hardcoded deployed-address block used by the script. |
| `script/TransferOwnership.s.sol:50` | Hardcodes `NEW_OWNER`, the recipient of balances and ownership. |
| `script/TransferOwnership.s.sol:52` | `run()` loads `BONKER_PRIVATE_KEY` and derives the current deployer address. |
| `script/TransferOwnership.s.sol:64` | Reads the factory WETH balance before calling `claimTeamFees(WETH)`. |
| `script/TransferOwnership.s.sol:73` | Reads FeeLocker claimable WETH for the deployer. |
| `script/TransferOwnership.s.sol:82` | Checks ETH and WETH balances stranded in the deployed LpLocker. |
| `script/TransferOwnership.s.sol:99` | Sends the deployer's WETH balance to `NEW_OWNER` after claims and withdrawals. |
| `script/TransferOwnership.s.sol:113` | Documents that hooks are not Ownable and are not transferred. |
| `script/TransferOwnership.s.sol:114` | Defines the five-contract Ownable transfer array. |
| `script/TransferOwnership.s.sol:129` | Loops over Ownable contracts and skips any not owned by the deployer. |
| `script/TransferOwnership.s.sol:141` | Handles the presale-specific recipient update and ownership transfer. |
| `script/TransferOwnership.s.sol:160` | Sends remaining deployer ETH to `NEW_OWNER`, leaving a gas reserve. |
| `src/Bonker.sol:81` | `claimTeamFees(token)` transfers the factory's full token balance to `teamFeeRecipient`. |
| `src/BonkerFeeLocker.sol:40` | `availableFees(feeOwner, token)` is the FeeLocker balance read used by the script. |
| `src/BonkerFeeLocker.sol:46` | `claim(feeOwner, token)` pays the stored balance to `feeOwner`. |
| `src/lp-lockers/BonkerLpLockerFeeConversion.sol:775` | `withdrawETH(recipient)` transfers all stranded ETH from the LpLocker to a recipient. |
| `src/lp-lockers/BonkerLpLockerFeeConversion.sol:783` | `withdrawERC20(token, recipient)` transfers the LpLocker full ERC20 balance for `token`. |
| `src/extensions/BonkerPresaleEthToCreator.sol:137` | `setBonkerFeeRecipient(recipient)` updates where presale Bonker fees go. |
| `src/hooks/BonkerPoolExtensionAllowlist.sol:8` | Pool extension allowlist is Ownable through `OwnerAdmins`, so the script transfers it. |
| `src/mev-modules/BonkerSniperAuctionV2.sol:89` | MEV module constructor stores an Ownable owner, so the script transfers it. |
| `src/extensions/BonkerAirdropV2.sol:18` | Airdrop V2 is not Ownable; it has per-token airdrop admins instead. |

## How It Works

### Address and wallet setup

The script is hardcoded for the currently deployed Base-mainnet stack. The constants include `FACTORY`, `FEE_LOCKER`, `POOL_EXTENSION_ALLOWLIST`, `DYNAMIC_HOOK`, `STATIC_HOOK`, `LP_LOCKER`, `MEV_MODULE`, `AIRDROP`, `PRESALE`, `WETH`, and `NEW_OWNER`.

Only some of those constants are acted on. `DYNAMIC_HOOK`, `STATIC_HOOK`, and `AIRDROP` are present in the address block, but the ownership loop excludes them. The script comment explains hooks are not Ownable. The current Airdrop V2 contract is also not Ownable; its authority is stored per token in airdrop state.

`run()` loads `BONKER_PRIVATE_KEY`, derives the deployer address, and prints both the old and new owner. All live transactions in the script are wrapped with `vm.broadcast(deployerKey)`, so the script signs as the deployer wallet.

```text
BONKER_PRIVATE_KEY
  -> deployer address
  -> claim and withdrawal calls
  -> WETH transfer to NEW_OWNER
  -> Ownable transferOwnership calls
  -> presale fee-recipient update and ownership transfer
  -> final ETH transfer to NEW_OWNER
```

### Step 1 claims and withdraws balances

The first block handles balances that are tied to old ownership or to the deployer wallet.

For factory protocol fees, the script reads `IERC20(WETH).balanceOf(FACTORY)`. If the balance is positive, it calls `IBonkerFactory(FACTORY).claimTeamFees(WETH)`. The factory contract sends its full WETH balance to the factory's current `teamFeeRecipient`, not necessarily to `msg.sender`.

For FeeLocker rewards, the script reads `availableFees(deployer, WETH)`. If positive, it calls `claim(deployer, WETH)`. FeeLocker claims always pay the `feeOwner` argument, so this sends the claimable WETH to the deployer address.

For LpLocker dust, the script reads the LpLocker ETH balance and WETH balance directly. If either is positive, it calls `withdrawETH(deployer)` or `withdrawERC20(WETH, deployer)`. Those functions are owner-only emergency withdrawals and transfer the full balance of the requested asset.

### Step 2 sends WETH to `NEW_OWNER`

After the factory claim, FeeLocker claim, and LpLocker withdrawals, the script reads the deployer's WETH balance. If it is positive, it transfers the full WETH balance to `NEW_OWNER`.

This sequencing matters. The WETH transfer happens after the claim and withdrawal operations so that all WETH the deployer can collect in this run is forwarded together. If the factory's current `teamFeeRecipient` is not the deployer, then factory `claimTeamFees(WETH)` will pay that configured recipient instead; the later deployer WETH sweep only forwards WETH actually held by the deployer wallet.

### Step 3 transfers Ownable contracts

The main ownership loop contains five contracts:

| Name in script | Address constant | Why included |
| --- | --- | --- |
| `Factory` | `FACTORY` | Global factory owner controls deprecation, team fee recipient, admins, and module allowlists. |
| `FeeLocker` | `FEE_LOCKER` | Owner controls allowed depositors that can call `storeFees()`. |
| `PoolExtensionAllowlist` | `POOL_EXTENSION_ALLOWLIST` | Owner/admin controls enabled pool extensions. |
| `LpLocker` | `LP_LOCKER` | Owner can perform emergency withdrawals and owner-gated locker operations. |
| `MevModule` | `MEV_MODULE` | Owner can tune sniper auction settings. |

For each entry, the script reads `Ownable(contract).owner()`. It transfers ownership only when the current owner equals the deployer. If the owner is already someone else, it prints a skip message and does not attempt the transfer.

The skip behavior is important for partial handoffs and reruns. It prevents the script from reverting just because one contract has already moved, but it also means the output must be read carefully. A skipped contract is not corrected by the script.

### Step 3 also handles presale-specific state

The presale contract has two pieces of state that matter for a handoff:

- Ownable owner, which controls owner-only presale settings.
- `bonkerFeeRecipient`, which receives the Bonker fee on presale ETH claims.

The script reads the current presale owner. If it equals the deployer, it first calls `setBonkerFeeRecipient(NEW_OWNER)`, then calls `transferOwnership(NEW_OWNER)`. If the presale is not owned by the deployer, it skips both actions.

The order is deliberate. `setBonkerFeeRecipient` is owner-only, so it must happen before the presale ownership transfer if the deployer is the current owner.

### Step 4 sends remaining ETH with a reserve

At the end, the script reads the deployer's ETH balance. If it is greater than `0.001 ether`, it sends `balance - 0.001 ether` to `NEW_OWNER` and leaves `0.001 ether` behind as a gas reserve.

The reserve is a local safety margin for the old owner wallet. It is not a contract invariant and it does not reserve funds inside any Bonker contract.

## Invariants and Edge Cases

### The script is mainnet-address specific

The address constants are the live Base-mainnet deployment addresses. A redeploy changes the ownership handoff surface. If any deployed address changes, this script can become stale in the same way client config, server indexer config, and verification scripts can become stale.

`NEW_OWNER` is also hardcoded. The script is not a generic "pass a new owner through env" utility. Changing the recipient means editing source code, reviewing the exact address, and treating the change as production-facing.

### Broadcast calls are irreversible

Every state-changing action uses `vm.broadcast(deployerKey)`. Running with `--broadcast` can claim balances, move WETH, move ETH, and transfer ownership on Base mainnet.

Do not treat this as a harmless inspection script. A dry run can show what it would do, but a broadcasted run acts on live contracts.

### Factory team fees may not land in the deployer wallet

`claimTeamFees(WETH)` pays the factory's configured `teamFeeRecipient`. The script does not call `setTeamFeeRecipient(NEW_OWNER)` before claiming. It only forwards the deployer's WETH balance after the claim block.

That means the factory claim path depends on current factory state. If the goal is to migrate the factory fee recipient as part of a broader ownership handoff, the operator must verify `teamFeeRecipient()` separately or update it through the correct owner-only path.

### FeeLocker claims are fee-owner scoped

The FeeLocker claim block only claims `availableFees(deployer, WETH)`. It does not enumerate every possible LP reward recipient and it does not claim non-WETH balances.

This matches the script's purpose: drain the old deployer wallet's claimable WETH before handing off ownership. Existing FeeLocker balances for other reward recipients remain claimable by those recipients.

### LpLocker withdrawals transfer full balances

`withdrawETH(recipient)` sends all ETH in the LpLocker. `withdrawERC20(token, recipient)` sends the full balance of the specified token. The script passes WETH only.

These are emergency withdrawal methods for stranded balances. They are distinct from normal LP fee collection, which stores recipient balances in FeeLocker.

### Skips are normal but not silent

The ownership loop and presale block skip entries that are not currently owned by the deployer. This makes reruns possible after a partial handoff, but it also means the script can finish while some contracts remain under a different owner.

The console output is the source of truth for what happened in a run. A skipped line should be treated as a concrete ownership fact to verify, not as a harmless warning.

### Hooks and Airdrop are excluded

The V2 hook addresses are immutable hook contracts and the script comment says they are not Ownable. Airdrop V2 is also not Ownable; it stores per-token airdrop admins in its `airdrops` mapping. The presence of `AIRDROP` in the constants block does not mean it will be transferred.

If a future extension or hook variant becomes Ownable, it should not be assumed that this script already covers it. The current script transfers only the five entries in `ownableContracts` plus the presale contract.

### Presale recipient update is coupled to presale ownership

The script updates `bonkerFeeRecipient` only when the deployer is the presale owner. If presale ownership has already moved, the script skips the recipient update too.

That protects against unauthorized calls but creates a handoff edge case: an already-transferred presale may still have an old `bonkerFeeRecipient`. Verify both `owner()` and `bonkerFeeRecipient()` after a partial or repeated run.

## Cross-References

- [CONTRACT-CONFIG-TOPOLOGY](./CONTRACT-CONFIG-TOPOLOGY.md) for deployed address drift surfaces and why hardcoded Base-mainnet addresses must move together.
- [CONTRACT-DEPLOYMENT-WORKFLOW](./CONTRACT-DEPLOYMENT-WORKFLOW.md) for the Forge scripts that create and configure the stack before any ownership handoff.
- [OWNER-ADMIN-PERMISSION-MODEL](./OWNER-ADMIN-PERMISSION-MODEL.md) for factory owner/admin authority, team fee recipient semantics, reward admins, and presale owner roles.
- [ADMIN-OPERATIONS-CONSOLE](./ADMIN-OPERATIONS-CONSOLE.md) for the browser-side factory fee claim and module toggles that are separate from the ownership transfer script.
- [LP-LOCKER-FEE-CONVERSION-LIFECYCLE](./LP-LOCKER-FEE-CONVERSION-LIFECYCLE.md) for normal LP fee collection into FeeLocker, distinct from emergency LpLocker withdrawals.
- [PRESALE-LIFECYCLE](./PRESALE-LIFECYCLE.md) for presale ETH claims, token deployment, and the presale owner flow affected by `bonkerFeeRecipient`.
- [PRODUCTION-RUNTIME-TOPOLOGY](./PRODUCTION-RUNTIME-TOPOLOGY.md) for production deployment and live server operations, which are separate from on-chain ownership changes.
