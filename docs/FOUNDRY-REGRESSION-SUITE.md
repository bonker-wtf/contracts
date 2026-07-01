Foundry regression suite explains how the Solidity `test/*.t.sol` files protect Bonker's fee accounting, lockup/vesting math, presale settlement, and non-standard ERC20 compatibility; read this before changing `test/`, `src/extensions/`, `src/BonkerFeeLocker.sol`, `src/Bonker.sol`, LP lockers, or token-transfer helpers.

This page covers natural-language queries such as `forge test`, `BonkerFeeFlow.t.sol`, `BonkerExtensionVesting.t.sol`, `BonkerPresaleEthToCreator.t.sol`, `BonkerLegacyErc20Safety.t.sol`, `MockTokenNoReturn`, `SafeERC20`, `amountAvailableToClaim`, `claimTeamFees`, `storeFees`, `PresaleAlreadyClaimed`, and "why does the test use a token with no boolean return". The suite is small, but it encodes several production invariants that are easy to break while refactoring extension, locker, or fee code.

## Why It Exists

Bonker's Solidity surface includes a factory, hooks, lockers, extensions, presales, token metadata, and owner/admin permissions. Not every branch is covered by Foundry tests, so the tests that do exist are intentionally concentrated around money movement and compatibility regressions.

The suite checks four high-risk areas.

First, protocol fees and LP fee locker balances must move to the right recipient and must not be claimable by unauthorized accounts. `Bonker.claimTeamFees()` is the factory protocol-fee path, while `BonkerFeeLocker.claim()` is the creator LP-fee path. Confusing those paths would route funds incorrectly.

Second, lockup and linear vesting views must match claim behavior. Vault, airdrop, and presale claims expose `amountAvailableToClaim` style views that the frontend and API can display before a transaction. If the view and claim math diverge, users see a claimable balance that either reverts or underpays.

Third, successful presales must split raised ETH once, preserve the Bonker fee, and vest token claims proportionally to each buyer's contribution. The tests avoid a full Uniswap deployment by using a mock factory that calls the presale extension boundary directly.

Fourth, token transfer code must tolerate legacy ERC20s that do not return `bool` from `transfer`, `transferFrom`, or `approve`. Bonker's deployed token is standard, but extensions and lockers interact with paired tokens, WETH wrappers, and routed swap outputs. `SafeERC20` compatibility is therefore a real integration property, not cosmetic defensive code.

## Key Files

| File | Why it matters |
| --- | --- |
| `foundry.toml:1` | Defines the default Foundry profile used by `forge test`, including Solidity `0.8.28`, `viaIR = true`, and optimizer settings. |
| `foundry.toml:17` | Defines the repo-wide Forge formatting rules used for Solidity sources and tests. |
| `test/BonkerFeeFlow.t.sol:52` | Starts `BonkerClaimTeamFeesTest`, which covers factory team-fee recipient requirements and owner/admin authorization. |
| `test/BonkerFeeFlow.t.sol:114` | Starts `BonkerFeeLockerClaimTest`, which covers authorized fee deposits, fee-on-transfer accounting, open claims, and empty-claim reverts. |
| `test/BonkerExtensionVesting.t.sol:65` | Starts `BonkerVaultVestingTest`, which checks vault lockup and linear vesting behavior. |
| `test/BonkerExtensionVesting.t.sol:219` | Starts `BonkerAirdropVestingTest`, which checks airdrop claim/view alignment around vesting boundaries. |
| `test/BonkerPresaleEthToCreator.t.sol:65` | Defines `MockPresaleFactory`, a minimal factory stand-in that deploys a mock token and calls presale `receiveTokens()`. |
| `test/BonkerPresaleEthToCreator.t.sol:129` | Starts `BonkerPresaleEthToCreatorTest`, which covers buyer vesting, ETH fee splits, and non-standard token settlement. |
| `test/BonkerLegacyErc20Safety.t.sol:21` | Defines `MockTokenNoReturn`, the shared non-standard ERC20 used to catch unsafe transfer assumptions. |
| `test/BonkerLegacyErc20Safety.t.sol:114` | Starts non-standard ERC20 coverage for `BonkerAirdrop`. |
| `test/BonkerLegacyErc20Safety.t.sol:198` | Starts non-standard ERC20 coverage for Uniswap v3 and v4 dev-buy extensions. |
| `test/BonkerLegacyErc20Safety.t.sol:329` | Starts non-standard ERC20 coverage for both LP locker implementations. |
| `src/extensions/BonkerVault.sol:41` | `receiveTokens()` creates vault allocations and pulls extension supply from the factory. |
| `src/extensions/BonkerVault.sol:113` | `amountAvailableToClaim()` exposes vault claimable balance before a claim transaction. |
| `src/extensions/BonkerAirdrop.sol:48` | `receiveTokens()` creates airdrop state and pulls the airdrop supply. |
| `src/extensions/BonkerAirdrop.sol:113` | `claim()` verifies a Merkle allocation and transfers the vested airdrop amount. |
| `src/extensions/BonkerAirdrop.sol:191` | `amountAvailableToClaim()` mirrors airdrop vesting math for reads. |
| `src/extensions/BonkerPresaleEthToCreator.sol:61` | `updatePresaleState` mutates expired active presales into success or failure states. |
| `src/extensions/BonkerPresaleEthToCreator.sol:158` | `startPresale()` validates sale bounds, extension ordering, owner, allowlist, lockup, and stored config. |

## How It Works

The tests are not end-to-end Base mainnet simulations. They are focused regression tests that instantiate the contracts under test directly, use simple mock contracts for external dependencies, and assert the accounting or compatibility behavior that must survive implementation changes.

```text
forge test
  |
  |-- BonkerFeeFlow.t.sol
  |     |-- factory protocol fees -> teamFeeRecipient
  |     `-- LP/creator fees -> BonkerFeeLocker balances -> feeOwner
  |
  |-- BonkerExtensionVesting.t.sol
  |     |-- BonkerVault lockup + vesting + claim
  |     `-- BonkerAirdrop lockup + vesting + claim/view alignment
  |
  |-- BonkerPresaleEthToCreator.t.sol
  |     |-- start presale through admin
  |     |-- buyers contribute ETH
  |     |-- presale owner ends sale and mock factory deploys token
  |     |-- buyers claim vested tokens
  |     `-- presale owner claims ETH minus Bonker fee
  |
  `-- BonkerLegacyErc20Safety.t.sol
        |-- no-return token through airdrop
        |-- no-return token through dev-buy extensions
        `-- no-return token through both LP lockers
```

### Fee Flow Tests

`BonkerFeeFlow.t.sol` separates factory protocol fees from LP fee-locker balances.

`BonkerClaimTeamFeesTest` constructs a `Bonker` factory and mints a mock ERC20 directly into the factory. It verifies that `claimTeamFees()` reverts when `teamFeeRecipient` is unset, transfers the full token balance to `teamFeeRecipient` once configured, emits `ClaimTeamFees`, allows a factory admin to claim, and rejects an outsider with `IOwnerAdmins.Unauthorized`.

`BonkerFeeLockerClaimTest` constructs a `BonkerFeeLocker`, adds one authorized depositor, and covers three invariants. Unauthorized callers cannot `storeFees()`. Fee-on-transfer tokens credit only the actual amount received by the locker. Anyone may trigger `claim(feeOwner, token)`, but the transfer always goes to `feeOwner` and the stored balance is cleared.

These tests intentionally do not exercise Uniswap v4 fee collection. LP position fee collection is covered conceptually by the LP locker lifecycle; this file protects the final accounting boundary after tokens are already in the factory or fee locker.

### Extension Vesting Tests

`BonkerExtensionVesting.t.sol` protects the shared lockup and linear vesting semantics used by vault and airdrop extensions.

`BonkerVaultVestingTest` builds a single-entry `IBonker.ExtensionConfig[]`, calls `BonkerVault.receiveTokens()` as the factory, and then warps time across three boundaries: just before lockup end, exactly at lockup end, and partway through vesting. The test claims halfway through vesting, then warps to vesting end and confirms the remainder is claimable and transferred to the vault admin.

`BonkerAirdropVestingTest` follows the same shape for a Merkle airdrop. It uses a one-leaf Merkle root where an empty proof is valid, checks `amountAvailableToClaim()` before lockup, at lockup, midway through vesting, and after full vesting, then confirms claims and views stay aligned after partial claiming.

The important invariant is not just "tokens can be claimed." It is that the read path and write path agree after partial claims. Frontend and API code rely on those reads to avoid telling a user that a claim is available when the transaction would transfer zero or revert.

### Presale Tests

`BonkerPresaleEthToCreator.t.sol` tests presale settlement without deploying the full factory, hook, pool, or locker stack.

`MockPresaleFactory` implements only the part the presale needs: `deployToken(DeploymentConfig)`. It mints a mock token, approves the presale, and calls `presale.receiveTokens()` with the presale extension index. `MockPresaleFactoryNoReturn` repeats the same behavior with a token that has no boolean transfer return.

`BonkerPresaleEthToCreatorTest.setUp()` creates a presale contract, enables an admin, starts a presale, sends two buyer contributions, ends the presale as `presaleOwner`, and asserts the sale is `Claimable`. The setup intentionally caps total ETH at `MAX_ETH_GOAL` and stores `deploymentTime`, because later tests use those values for proportional vesting and fee checks.

The buyer-vesting test checks both buyers at lockup boundaries and after partial claims. Buyer one contributed twice as much ETH as buyer two, so the final token balances must be `600 ether` and `300 ether` from a `900 ether` presale allocation. The ETH-claim test verifies that `claimEth()` pays the owner share and Bonker fee exactly once, then reverts on a second claim with `PresaleAlreadyClaimed`.

### Legacy ERC20 Safety Tests

`BonkerLegacyErc20Safety.t.sol` is a compatibility suite for token interactions that must use OpenZeppelin `SafeERC20` semantics.

`MockTokenNoReturn` mutates balances and allowances but returns no value from `approve`, `transfer`, or `transferFrom`. Solidity callers that expect `bool` directly can fail against this shape; `SafeERC20` treats a missing return as success when the low-level call itself succeeds.

The airdrop test proves `BonkerAirdrop.receiveTokens()` can pull a no-return token from the factory and later `claim()` can send it to the recipient.

The dev-buy tests use `MockWethNoReturn`, `MockPermit2`, and `MockUniversalRouter`. They prove both `BonkerUniv3EthDevBuy` and `BonkerUniv4EthDevBuy` can wrap ETH, approve Permit2, execute a router call, and transfer the bought no-return token to the recipient.

The locker tests instantiate `BonkerLpLockerMultiple` and `BonkerLpLockerFeeConversion` with mock position manager, fee locker, and Permit2 contracts. They confirm `placeLiquidity()` pulls the full no-return token supply into the locker, records Permit2 approval amount, returns the mock position ID, and, for the fee-conversion locker, stores the encoded `feePreferences`.

## Invariants And Edge Cases

### Factory Fees And FeeLocker Balances Stay Separate

`claimTeamFees(token)` transfers the factory's entire balance of `token` to `teamFeeRecipient`. It is guarded by `onlyOwnerOrAdmin` and reverts if the recipient is unset. It is not the LP reward claim path.

`BonkerFeeLocker.storeFees(feeOwner, token, amount)` is depositor-gated and credits claimable balances by actual received amount. `BonkerFeeLocker.claim(feeOwner, token)` can be called by anyone, but the token transfer target is always `feeOwner`.

If future tests combine these paths, keep the assertions explicit about which contract holds funds and which address receives funds.

### Views Must Match Claims

Vault, airdrop, and presale tests all check read functions before and after claims. A view returning a positive amount after that exact amount has just been claimed is a bug. A view returning zero before lockup ends is required even when the allocation exists.

Partial claims matter because linear vesting uses `amountClaimed` or per-buyer claimed state. Tests should include at least one mid-vesting claim before the final vesting-end claim when changing that math.

### Mock Factories Are Intentional

The presale tests do not try to initialize a real Uniswap v4 pool. That is deliberate. The contract behavior under test is the presale extension's state machine and accounting after `factory.deployToken()` calls back into `receiveTokens()`.

When adding presale tests, prefer extending the mock factory if the behavior is about presale state. Use full deployment scripts or integration tests only when the behavior depends on the real factory, hook, locker, or pool manager.

### No-Return Tokens Are A Regression Fixture

`MockTokenNoReturn` is not a toy ERC20. It represents a common legacy token shape. Any extension or locker that calls arbitrary ERC20s should keep using `SafeERC20`-compatible transfer and approval paths.

When a production contract starts interacting with a new external token in tests, add no-return coverage if it transfers, approves, pulls, or pays that token. This is especially important for extension contracts and lockers because they sit at the boundary between Bonker deployments and arbitrary paired assets.

### Fee-On-Transfer Accounting Uses Received Amount

`MockFeeOnTransferERC20` in `BonkerFeeFlow.t.sol` catches a different class of bug than `MockTokenNoReturn`. It returns normally, but the recipient receives less than the requested transfer amount. `BonkerFeeLocker.storeFees()` must credit the delta in locker balance, not the caller-supplied amount.

Do not reuse the no-return token to test fee-on-transfer behavior. The two fixtures protect different assumptions.

## Where To Add New Coverage

Add factory team-fee and FeeLocker balance tests to `BonkerFeeFlow.t.sol` when changing `Bonker.claimTeamFees()`, `BonkerFeeLocker`, depositor authorization, claim events, or accounting for tokens already held by those contracts.

Add vault and airdrop vesting tests to `BonkerExtensionVesting.t.sol` when changing `amountAvailableToClaim()`, `claim()`, lockup boundaries, vesting duration behavior, or extension token pull logic for `BonkerVault` or `BonkerAirdrop`.

Add presale state-machine and presale accounting tests to `BonkerPresaleEthToCreator.t.sol` when changing `startPresale()`, `buyIntoPresale()`, `endPresale()`, `receiveTokens()`, `claimTokens()`, `claimEth()`, presale fee math, salt timing, or per-buyer vesting.

Add no-return ERC20 compatibility tests to `BonkerLegacyErc20Safety.t.sol` when a contract starts using `IERC20.transfer`, `IERC20.transferFrom`, `IERC20.approve`, WETH wrapping, Permit2 approvals, or Universal Router swap outputs in a new way.

Add new full deployment or hook behavior tests in a new focused `*.t.sol` file when the behavior depends on actual factory deployment, hook callbacks, pool manager state, dynamic fee updates, MEV modules, or Uniswap v4 position behavior. Keep the filename scoped to the behavior under test rather than growing the current regression files into unrelated integration suites.

## Verification

Run the Solidity suite with:

```bash
forge test
```

For a small contract-only change, a targeted command is acceptable while iterating:

```bash
forge test --match-path test/BonkerFeeFlow.t.sol
```

Use the default Foundry profile for tests unless the change specifically targets LpLocker bytecode size or deployment verification. The `lplocker` profile exists for deployment bytecode constraints, not as the default test profile.

Run `forge fmt` or format consistently with `foundry.toml` after editing Solidity tests. The repo expects 100-character lines, sorted imports, and underscore-separated large numbers.

## Cross-References

- [FACTORY-EXTENSION-LIFECYCLE](./FACTORY-EXTENSION-LIFECYCLE.md) for how vault, airdrop, dev-buy, and presale extensions are invoked by `Bonker.deployToken`.
- [LP-LOCKER-FEE-CONVERSION-LIFECYCLE](./LP-LOCKER-FEE-CONVERSION-LIFECYCLE.md) for locked LP positions, reward recipients, fee preferences, and FeeLocker claims.
- [PRESALE-LIFECYCLE](./PRESALE-LIFECYCLE.md) for the full presale path across Solidity, polling, API responses, SQLite metadata, and React pages.
- [OWNER-ADMIN-PERMISSION-MODEL](./OWNER-ADMIN-PERMISSION-MODEL.md) for the distinction between factory owner/admins, token admins, reward admins, and presale owners.
- [CONTRACT-DEPLOYMENT-WORKFLOW](./CONTRACT-DEPLOYMENT-WORKFLOW.md) for Forge deployment scripts, hook salt mining, optimizer profiles, and BaseScan verification.
