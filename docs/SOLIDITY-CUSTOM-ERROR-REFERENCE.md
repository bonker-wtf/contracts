Solidity custom error reference maps Bonker revert selectors to the launch, liquidity, extension, presale, MEV, fee-claim, and token-admin phases that emit them; read this when a wallet simulation, Forge test, BaseScan trace, or operator script returns a named custom error and you need the nearest cause before opening the deeper lifecycle doc.

Bonker uses custom errors as the public failure vocabulary for contracts. Natural-language queries such as `ExtensionMsgValueMismatch`, `PresaleSaltBufferNotExpired`, `NotExpectingTokenDeployment`, `TickRangeLowerThanStartingTick`, `PoolLocked`, `GasSignalNegative`, `TeamFeeRecipientNotSet`, `InvalidPairedTokenPoolKey`, and `AlreadyVerified` should land here. This page is a triage map, not a replacement for the subsystem docs: it names where an error comes from, what condition usually causes it, and which existing doc has the full flow.

## Why It Exists

Bonker's highest-risk write paths are all wallet or operator transactions. A launch simulation can fail inside the factory, hook, LP locker, an extension, or an MEV module; a presale can fail before token deployment or during the factory callback; a post-launch claim can fail because no fees or vested tokens are available. Those failures surface as custom error selectors, often without the surrounding Solidity branch.

The repo already documents the lifecycles that produce those errors. What was missing was a compact index from "I saw this revert" to "which config phase should I inspect first?" Without that map, a maintainer debugging a launch may start in the wrong layer: for example, `InvalidMsgValue` can come from an extension's local ETH invariant, while `ExtensionMsgValueMismatch` comes from the factory's sum of all extension `msgValue` fields.

This doc intentionally groups errors by transaction phase. The same name can appear in several contracts (`Unauthorized`, `OnlyHook`, `PoolAlreadyInitialized`), so phase and caller context matter more than the selector text alone.

## Key Files

| File | Why it matters |
| --- | --- |
| `src/interfaces/IBonker.sol:67` | Declares the factory-level launch, module registration, chain-gating, and team-fee custom errors. |
| `src/Bonker.sol:81` | `claimTeamFees()` emits `TeamFeeRecipientNotSet` before sweeping factory-held protocol fees. |
| `src/Bonker.sol:98` | Admin module registration validates ERC-165 support before enabling hooks, lockers, MEV modules, or extensions. |
| `src/Bonker.sol:166` | `deployToken()` is the main launch entrypoint and orders factory, hook, locker, extension, and MEV setup. |
| `src/Bonker.sol:240` | `_initializeMevModule()` emits `MevModuleNotEnabled` before calling hook MEV initialization. |
| `src/Bonker.sol:253` | `_initializePool()` emits `HookNotEnabled` before delegating pool setup to the hook. |
| `src/Bonker.sol:276` | `_initializeLiquidity()` emits `LockerNotEnabled` before calling the LP locker. |
| `src/Bonker.sol:297` | `_prepareExtensions()` emits the factory extension-count, BPS, ETH-sum, and allowlist errors. |
| `src/hooks/BonkerHookV2.sol:73` | V2 hook factory-only pool initialization gate. |
| `src/hooks/BonkerHookV2.sol:109` | Pool-extension allowlist validation during hook pool setup. |
| `src/hooks/BonkerHookV2.sol:168` | Open pool path rejects WETH as the Bonker token and forbids pool extensions. |
| `src/hooks/BonkerHookV2.sol:200` | Shared hook pool initialization rejects native ETH pools. |
| `src/hooks/BonkerHookV2.sol:289` | MEV module callback authorization for `mevModuleSetFee()`. |
| `src/hooks/BonkerHookV2.sol:385` | Pool-extension helper is intentionally callable only by the hook itself. |
| `src/hooks/BonkerHookV2.sol:576` | Raw Uniswap v4 initialization and MEV-active liquidity adds are blocked. |
| `src/hooks/BonkerHookDynamicFeeV2.sol:42` | Dynamic fee pool-data validation. |
| `src/hooks/BonkerHookStaticFeeV2.sol:22` | Static fee pool-data validation. |
| `src/lp-lockers/BonkerLpLockerFeeConversion.sol:77` | LP locker factory-only `placeLiquidity()` authorization. |
| `src/lp-lockers/BonkerLpLockerFeeConversion.sol:102` | LP reward-recipient and fee-preference validation. |
| `src/lp-lockers/BonkerLpLockerFeeConversion.sol:198` | LP tick-range and position-BPS validation. |
| `src/lp-lockers/BonkerLpLockerFeeConversion.sol:696` | Reward recipient, fee preference, and admin updates require the reward admin. |
| `src/extensions/BonkerVault.sol:41` | Vault extension launch callback validation. |
| `src/extensions/BonkerAirdropV2.sol:38` | Live airdrop extension launch callback validation. |
| `src/extensions/BonkerUniv4EthDevBuy.sol:60` | Live dev-buy extension launch callback validation. |
| `src/extensions/BonkerPresaleEthToCreator.sol:158` | Presale creation validates owner, extension ordering, goals, duration, lockup, and allowlist. |
| `src/extensions/BonkerPresaleEthToCreator.sol:280` | Presale deployment state machine and salt-buffer guard. |
| `src/extensions/BonkerPresaleEthToCreator.sol:350` | Presale contribution and allowlist cap validation. |
| `src/extensions/BonkerPresaleEthToCreator.sol:435` | Presale token claim lockup and vesting validation. |
| `src/extensions/BonkerPresaleEthToCreator.sol:517` | Presale ETH claim authorization, one-shot guard, and ETH transfer errors. |
| `src/extensions/BonkerPresaleEthToCreator.sol:559` | Factory callback guard that turns a presale into `Claimable`. |
| `src/extensions/BonkerPresaleAllowlist.sol:42` | Presale allowlist owner controls and proof validation. |
| `src/mev-modules/BonkerMevBlockDelay.sol:25` | Block-delay module hook authorization and lock error. |
| `src/mev-modules/BonkerMevTimeDelay.sol:21` | Time-delay module constructor and lock error. |
| `src/mev-modules/BonkerMevDescendingFees.sol:51` | Descending-fee module config validation. |
| `src/mev-modules/BonkerSniperAuctionV2.sol:177` | Sniper auction fee-decay config validation. |
| `src/mev-modules/BonkerSniperAuctionV2.sol:220` | Sniper auction one-time pool initialization. |
| `src/mev-modules/BonkerSniperAuctionV2.sol:424` | Sniper auction block timing. |
| `src/BonkerFeeLocker.sol:26` | FeeLocker depositor authorization and zero-balance claim errors. |
| `src/utils/OwnerAdmins.sol:17` | Shared owner/admin authorization errors used by factory and presale owner surfaces. |
| `src/BonkerToken.sol:38` | Token metadata, verification, and Superchain bridge authorization errors. |

## How It Works

### Error Flow By Launch Phase

```text
wallet / script
  |
  | deployToken(DeploymentConfig)
  v
Bonker factory
  |-- module enabled checks: HookNotEnabled, LockerNotEnabled, ExtensionNotEnabled, MevModuleNotEnabled
  |-- extension accounting: MaxExtensionsExceeded, MaxExtensionBpsExceeded, ExtensionMsgValueMismatch
  v
hook initializePool()
  |-- pool shape: ETHPoolNotAllowed, WethCannotBeBonker
  |-- pool extension: PoolExtensionNotEnabled, OnlyFactoryPoolsCanHaveExtensions
  |-- fee data: BaseFeeTooLow, MaxLpFeeTooHigh, BonkerFeeTooHigh
  v
LP locker placeLiquidity()
  |-- reward arrays: MismatchedRewardArrays, InvalidRewardBps, ZeroRewardAddress
  |-- position arrays: MismatchedPositionInfos, NoPositions, InvalidPositionBps
  |-- ticks: TicksBackwards, TicksOutOfTickBounds, TicksNotMultipleOfTickSpacing
  v
extensions receiveTokens()
  |-- extension-local msg.value / BPS / lockup / admin / proof checks
  v
MEV module initialize()
  |-- module-local delay, fee-decay, auction timing checks
```

When a revert occurs during a launch, inspect the first phase in this diagram whose error family matches the selector. A factory allowlist error means the address is disabled or the aggregate extension configuration is invalid. A hook fee error means `poolData` decoded successfully but its fee fields are out of range. An LP locker error means pool setup passed and the failure is in reward or tick placement.

### Factory And Module Registration Errors

`InvalidHook`, `InvalidLocker`, `InvalidMevModule`, and `InvalidExtension` are admin registration errors, not launch config errors. They mean `setHook()`, `setLocker()`, `setMevModule()`, or `setExtension()` was given an address that does not report the expected interface ID through `supportsInterface()`.

`HookNotEnabled`, `LockerNotEnabled`, `ExtensionNotEnabled`, and `MevModuleNotEnabled` are launch-time allowlist errors. The deployment config may point at a real contract, but the factory's enabled mapping does not permit that contract for this launch. `LockerNotEnabled` is keyed by both locker and hook, so a locker enabled for one hook can still fail with another hook.

`Deprecated` means the factory owner has deprecated new token launches. `OnlyOriginatingChain` means `deployToken()` was called on a chain that is not `deploymentConfig.tokenConfig.originatingChainId`. `OnlyNonOriginatingChains` is the inverse guard for `deployTokenZeroSupply()`.

`MaxExtensionsExceeded`, `MaxExtensionBpsExceeded`, and `ExtensionMsgValueMismatch` are aggregate checks before any extension receives tokens. The factory sums all extension BPS against `MAX_EXTENSION_BPS`, sums all extension `msgValue` fields against transaction `msg.value`, and only then calls each enabled extension.

`TeamFeeRecipientNotSet` is isolated to `claimTeamFees()`. The factory can hold protocol-fee balances, but the owner/admin sweep refuses to run until `teamFeeRecipient` is nonzero.

### Hook And Pool-Data Errors

`OnlyFactory` on `BonkerHookV2.initializePool()` means someone called the factory-only pool path directly. Public open pools must use `initializePoolOpen()`, which does not set LP locker auto-claim, pool extensions, or MEV module behavior.

`ETHPoolNotAllowed` means either token address in hook pool initialization is the zero address. Bonker pools use ERC-20 addresses, and the production pairing model uses WETH rather than native ETH.

`WethCannotBeBonker` appears on the open pool path when the caller tries to make WETH the Bonker-side token. The hook's fee accounting assumes fees are collected on the paired token side.

`PoolExtensionNotEnabled` means the pool extension address decoded from V2 pool data is not enabled in `BonkerPoolExtensionAllowlist`. `OnlyFactoryPoolsCanHaveExtensions` means an open pool tried to set a pool extension even though only factory-created pools get the post-locker setup step.

`UnsupportedInitializePath` is deliberate. The hook blocks raw Uniswap v4 initialization so pools go through Bonker's `initializePool()` or `initializePoolOpen()` wrappers.

`MevModuleEnabled` blocks direct liquidity adds while a pool's MEV module is still operational. This preserves the launch protection window before external liquidity modification.

`BaseFeeTooLow`, `MaxLpFeeTooHigh`, and `BaseFeeGreaterThanMaxLpFee` come from dynamic-fee `feeData`. `BonkerFeeTooHigh` and `PairedFeeTooHigh` come from static-fee `feeData`. These are ABI-decoded pool-data errors, so check the exact pool-data tuple before looking at factory allowlists.

`TickReturned(int24 tick)` is not a user-facing launch failure. The dynamic hook uses a revert-and-decode simulation pattern to read the post-swap tick from `simulateSwap()`.

### LP Locker Errors

`Unauthorized` in the LP locker usually means the caller is not the factory during `placeLiquidity()`, not the reward admin during reward updates, or not the factory while sending position NFTs through `onERC721Received()`.

Reward recipient errors are about the arrays in `LockerConfig` and the decoded fee-conversion preference data. `MismatchedRewardArrays` means `rewardBps`, `rewardAdmins`, `rewardRecipients`, and fee preferences do not have equal lengths. `TooManyRewardParticipants`, `NoRewardRecipients`, `ZeroRewardAmount`, `InvalidRewardBps`, and `ZeroRewardAddress` are the per-slot reward split guards.

`TokenAlreadyHasRewards` means the locker already has a stored `TokenRewardInfo` for that token. A token can only receive the initial LP reward configuration once.

Position errors are about tick arrays and BPS splits. `MismatchedPositionInfos`, `NoPositions`, `TooManyPositions`, and `InvalidPositionBps` validate the number and total split of LP positions. `TicksBackwards`, `TicksOutOfTickBounds`, `TicksNotMultipleOfTickSpacing`, and `TickRangeLowerThanStartingTick` validate each tick range against Uniswap tick bounds, the pool tick spacing, and the configured starting tick.

### Extension Callback Errors

Most extension launch errors happen inside `receiveTokens()`, after the factory has deployed the token and initialized liquidity. They usually mean the extension's `extensionData`, `extensionBps`, or `msgValue` does not match that extension's local contract rules.

`InvalidMsgValue` is declared on `IBonkerExtension` and is reused by vault, airdrop, presale, and dev-buy callbacks. For vault, airdrop, and presale supply reservations, both configured `msgValue` and actual `msg.value` must be zero. For ETH dev buy, configured `msgValue` must exactly equal the ETH forwarded and must be nonzero.

Vault errors: `InvalidVaultBps` means the vault received zero reserved supply. `VaultLockupDurationTooShort` means `lockupDuration` is below 7 days. `InvalidVaultAdmin` means the admin is zero. `AllocationAlreadyExists` means the token already has a vault allocation. `AllocationNotUnlocked` and `NoBalanceToClaim` happen on post-launch vault claims.

Airdrop V2 errors: `InvalidAirdropPercentage`, `AirdropLockupDurationTooShort`, and `AirdropAlreadyExists` happen during launch callback validation. `AirdropNotCreated`, `AirdropNotUnlocked`, `ZeroClaim`, `TotalMaxClaimed`, `InvalidProof`, `UserMaxClaimed`, and `ZeroToClaim` happen during user claims. `AdminClaimed`, `AirdropClaimsOccurred`, `UpdateMerkleRootNotAllowed`, and `ClaimNotEnded` belong to the V2 admin root-update and leftover-claim lifecycle.

Dev-buy errors: `InvalidEthDevBuyPercentage` means the dev buy tried to reserve token supply even though ETH dev buy should consume ETH only. `InvalidPairedTokenPoolKey` means the intermediate paired-token pool does not match WETH/native-ETH and the target paired token as expected by `BonkerUniv4EthDevBuy`.

Presale extension errors are split out below because presale has its own state machine and post-launch user flows.

## Presale Error Map

### Creating A Presale

`InvalidPresaleOwner` means `presaleOwner` is zero. `PresaleNotLastExtension` means the presale extension is missing or not the last entry in `deploymentConfig.extensionConfigs`. `InvalidPresaleSupply` means the presale extension BPS is zero. `InvalidMsgValue` means the presale extension config tried to carry ETH during launch.

`InvalidEthGoal` means `maxEthGoal` is zero or `minEthGoal > maxEthGoal`. `InvalidPresaleDuration` means the duration is zero or greater than `MAX_PRESALE_DURATION`. `LockupDurationTooShort` means the presale token claim lockup is below the mutable `minLockupDuration`. `AllowlistNotEnabled` means a nonzero allowlist address was supplied before the presale contract enabled it.

`InvalidBonkerFee` appears when setting a default fee greater than or equal to 10_000 BPS, or when trying to set a per-presale fee that is not strictly lower than the current fee.

### Buying, Withdrawing, And Allowlist Proofs

`PresaleNotActive` means a contribution arrived after the presale left `Active` or after its end time. `AllowlistAmountExceeded(uint256 allowedAmount)` means the buyer's cumulative contribution exceeds the allowlist contract's returned cap.

In the allowlist contract, `MerkleRootNotSet` means a proof was provided but the presale allowlist has no root. `InvalidProof` means the decoded `(buyer, allowedAmount)` proof does not verify. Empty proof is not an error by itself; it returns an allowed amount of zero.

`PresaleSuccessful` blocks withdrawals after the presale succeeds. `InsufficientBalance` means the caller is withdrawing more ETH than their recorded contribution. `EthTransferFailed` means a native ETH refund, withdrawal, owner payout, or fee payout call returned false.

### Ending And Deploying A Presale

`PresaleNotReadyForDeployment` means the presale has not hit max goal, has not hit min goal after deadline, and is not being ended early by the presale owner after min goal. `PresaleSaltBufferNotExpired` means a non-owner caller tried to deploy during the reserved salt-setting window after end time.

`NotExpectingTokenDeployment` is expected during the admin preflight simulation described in the presale code comments: the stored presale has not set `deploymentExpected`, so the callback proves the deployment config reached the presale extension. During real `endPresale()`, the contract sets `deploymentExpected = true` immediately before calling `factory.deployToken()`.

`InvalidPresale` is the generic presale-exists guard for paths that require an initialized `presaleState[presaleId]`. It means `maxEthGoal` is zero for that ID.

### Claiming Presale Tokens Or ETH

`PresaleNotClaimable` means the presale has not reached the post-deployment `Claimable` state. `PresaleLockupNotPassed` means token claims are still inside the lockup window. `NoTokensToClaim` means the caller has no newly vested proportional token amount.

`Unauthorized` on `claimEth()` means the caller is neither the presale owner nor the contract owner. `RecipientMustBePresaleOwner` means the contract owner is exercising the recovery path but tried to pay a recipient other than the presale owner. `PresaleAlreadyClaimed` means the raised ETH was already claimed once.

## MEV And Sniper Protection Errors

`OnlyHook` on block delay, time delay, descending fee, or sniper auction modules means the caller is not the pool's hook. These modules are not public entrypoints for users or scripts.

`PoolLocked` means a block-delay or time-delay module is still active. In a swap trace, this is the expected protection behavior before the configured block number or timestamp unlocks.

Descending-fee and sniper-auction config errors share the same fee-decay vocabulary: `TimeDecayMustBeGreaterThanZero`, `StartingFeeMustBeGreaterThanZero`, `StartingFeeMustBeGreaterThanEndingFee`, `OnlyBonkerHookV2`, `StartingFeeGreaterThanMaxLpFee`, and `TimeDecayLongerThanMaxMevDelay`. Check MEV module data before checking swap calldata.

`PoolAlreadyInitialized` means the same MEV module state was initialized twice for one pool. `SameSecondAsDeployment` blocks descending-fee swaps in the exact deployment timestamp.

Sniper auction runtime errors: `NotAuctionBlock` means the auction round has not reached its required block. `GasSignalNegative` means the transaction gas price is below the stored gas peg, so the bid signal would be negative. Utility-contract errors `InvalidBidAmount`, `GasPriceTooLow`, `ValueBidMismatch`, `InvalidRound`, `InvalidBlock`, and `AuctionDidNotAdvance` come from helper contracts that package auction bids before calling the router.

## FeeLocker, Admin, And Token Errors

`Unauthorized` in `OwnerAdmins` means the caller is not in the admin mapping for `onlyAdmin()`, or is neither owner nor admin for `onlyOwnerOrAdmin()`. This is the shared authorization boundary behind factory admin writes and presale admin creation.

`Unauthorized` in `BonkerFeeLocker.storeFees()` means the caller is not an allowed depositor. Fee deposits should come from allowed LP lockers or MEV payment paths. `NoFeesToClaim` means the per-recipient escrow ledger has zero balance for the requested token.

Token metadata errors are local to `BonkerToken`. `NotAdmin` protects `updateAdmin()`, `updateImage()`, and `updateMetadata()`. `NotOriginalAdmin` protects `verify()`, and `AlreadyVerified` prevents verifying the same token twice. `Unauthorized` on `crosschainMint()` or `crosschainBurn()` means the caller is not the Optimism `SuperchainTokenBridge` predeploy.

## Invariants And Edge Cases

- Factory-level `ExtensionMsgValueMismatch` is checked before extension callbacks. Extension-level `InvalidMsgValue` is checked inside one extension callback. The fix surface is different.
- Factory enabled-module errors do not prove the address is invalid. Registration-time `Invalid*` errors validate interface support; launch-time `*NotEnabled` errors validate factory mappings.
- `Unauthorized` is not globally meaningful by itself. Always pair it with the emitting contract and function.
- Presale simulation may intentionally reach `NotExpectingTokenDeployment()`. That is a positive preflight signal when testing a presale config before `startPresale()`.
- A hook `TickReturned(int24)` revert can be an internal simulation transport, not an end-user failure.
- Native ETH transfer failures use `EthTransferFailed`; WETH/ERC-20 transfer failures usually bubble from `SafeERC20` or the token implementation rather than a Bonker custom error.
- LP tick validation happens after hook pool initialization has already succeeded. A tick error means the pool-data layer was accepted and the failure moved to locker placement.
- Airdrop V2 permits a zero Merkle root at launch, but claims fail with `AirdropNotCreated` until the admin sets a nonzero root.

## Cross-References

- [DEPLOYTOKEN-CALLDATA-SCHEMA](./DEPLOYTOKEN-CALLDATA-SCHEMA.md) for the positional `deployToken` tuple and nested bytes payloads that often cause launch reverts.
- [LAUNCH-FORM-DEPLOYMENT-CONFIG](./LAUNCH-FORM-DEPLOYMENT-CONFIG.md) for how the browser builds and simulates deployment configs before wallet submission.
- [FACTORY-EXTENSION-LIFECYCLE](./FACTORY-EXTENSION-LIFECYCLE.md) for factory extension supply reservation and ETH forwarding.
- [HOOK-FEE-ACCOUNTING](./HOOK-FEE-ACCOUNTING.md) for hook swap-fee behavior and protocol fee collection.
- [POOL-EXTENSION-HOOK-LIFECYCLE](./POOL-EXTENSION-HOOK-LIFECYCLE.md) for V2 pool extension allowlisting and callback ordering.
- [LP-LOCKER-FEE-CONVERSION-LIFECYCLE](./LP-LOCKER-FEE-CONVERSION-LIFECYCLE.md) for LP position placement, reward recipients, and FeeLocker deposits.
- [MEV-MODULE-LIFECYCLE](./MEV-MODULE-LIFECYCLE.md) for launch-time protection module setup and swap gating.
- [SNIPER-AUCTION-BID-MECHANICS](./SNIPER-AUCTION-BID-MECHANICS.md) for gas-price-as-bid errors and sniper utility helpers.
- [PRESALE-LIFECYCLE](./PRESALE-LIFECYCLE.md) for presale creation, contribution, deployment, claims, API polling, and UI state.
- [PRESALE-ALLOWLIST-LIFECYCLE](./PRESALE-ALLOWLIST-LIFECYCLE.md) for allowlist root, overrides, proof shape, and buyer caps.
- [AIRDROP-EXTENSION-LIFECYCLE](./AIRDROP-EXTENSION-LIFECYCLE.md) for V2 root updates, claims, admin leftovers, and legacy differences.
- [VAULT-EXTENSION-LIFECYCLE](./VAULT-EXTENSION-LIFECYCLE.md) for vault allocation and lockup-plus-vesting claims.
- [DEV-BUY-EXTENSION-ROUTING](./DEV-BUY-EXTENSION-ROUTING.md) for ETH dev-buy routing and paired-token pool-key assumptions.
- [FEE-ESCROW-AND-CLAIM](./FEE-ESCROW-AND-CLAIM.md) for FeeLocker escrow versus factory protocol-fee claims.
- [OWNER-ADMIN-PERMISSION-MODEL](./OWNER-ADMIN-PERMISSION-MODEL.md) for owner/admin roles behind `Unauthorized` and privileged writes.
- [TOKEN-CONTRACT-METADATA-LIFECYCLE](./TOKEN-CONTRACT-METADATA-LIFECYCLE.md) for token admin, original-admin verification, and bridge-gated mint/burn.
