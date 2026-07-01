Presale allowlist lifecycle explains how optional presale buyer caps are enabled, initialized, checked, surfaced, and operated; read this before changing `src/extensions/BonkerPresaleAllowlist.sol`, presale `allowlist` fields, admin presale creation, allowlisted contribution flows, or presale owner allowlist controls.

This page covers natural-language queries such as `BonkerPresaleAllowlist`, `setAllowlist`, `allowlistInitializationData`, `buyIntoPresaleWithProof`, `getAllowedAmountForBuyer`, `SetAddressOverride`, `SetMerkleRoot`, `SetAllowlistEnabled`, `AllowlistAmountExceeded`, `MerkleRootNotSet`, and "why does enabling the admin allowlist still start with an empty root". It focuses only on the optional allowlist checker attached to `BonkerPresaleEthToCreator`. The broader presale status machine, token deployment, ETH claims, and buyer token claims are covered by the presale lifecycle doc.

## Why It Exists

Most presales are public: anyone can call `buyIntoPresale` until the sale ends or reaches `maxEthGoal`.

Bonker also supports gated presales where each buyer has an individual maximum ETH allowance. The gate is not hardcoded into the presale contract. Instead, `BonkerPresaleEthToCreator` stores an optional allowlist contract address per presale and delegates buyer allowance checks to that contract during contribution.

That split solves three problems.

First, the presale contract stays focused on sale accounting. It only knows whether an allowlist address is enabled, how to initialize it, and how to ask it for a buyer's allowed total.

Second, allowlist policy can evolve behind a narrow interface. The deployed `BonkerPresaleAllowlist` supports presale-owner overrides, Merkle roots, and a per-presale enable switch without changing the presale contribution accounting.

Third, admins can decide at presale creation whether the sale is public or allowlisted. The current admin UI exposes a simple `Enable Allowlist` switch. When enabled, it passes the deployed `PRESALE_ALLOWLIST` address with empty initialization data, so the presale owner must configure address overrides or a Merkle root before buyers can contribute through the gate.

The sharp edge is that an enabled allowlist with no overrides and no Merkle root denies ordinary `buyIntoPresale` calls. A buyer can only contribute if the allowlist is disabled for that presale, the buyer has an address override, or the buyer supplies a valid Merkle proof with a positive allowed amount.

## Key Files

| File | Why it matters |
| --- | --- |
| `src/extensions/BonkerPresaleAllowlist.sol:8` | Defines the deployed allowlist checker contract. |
| `src/extensions/BonkerPresaleAllowlist.sol:19` | Defines `AllowlistInitializationData`, currently just an optional Merkle root. |
| `src/extensions/BonkerPresaleAllowlist.sol:23` | Defines `AllowlistProof`, the ABI-encoded buyer proof shape. |
| `src/extensions/BonkerPresaleAllowlist.sol:28` | Stores the per-presale owner, root, enabled flag, and address overrides. |
| `src/extensions/BonkerPresaleAllowlist.sol:42` | Lets the presale owner set a direct per-buyer allowance override. |
| `src/extensions/BonkerPresaleAllowlist.sol:48` | Lets the presale owner update the Merkle root after initialization. |
| `src/extensions/BonkerPresaleAllowlist.sol:54` | Lets the presale owner enable or disable allowlist enforcement for one presale. |
| `src/extensions/BonkerPresaleAllowlist.sol:61` | Initializes allowlist state; only the presale contract may call it. |
| `src/extensions/BonkerPresaleAllowlist.sol:85` | Computes the buyer's allowed total contribution for a presale. |
| `src/extensions/BonkerPresaleEthToCreator.sol:48` | Stores which allowlist contracts may be used for new presales. |
| `src/extensions/BonkerPresaleEthToCreator.sol:86` | Owner-only registry toggle for allowlist contracts. |
| `src/extensions/BonkerPresaleEthToCreator.sol:158` | `startPresale` accepts the optional allowlist address and initialization data. |
| `src/extensions/BonkerPresaleEthToCreator.sol:216` | Rejects non-zero allowlist contracts that have not been enabled. |
| `src/extensions/BonkerPresaleEthToCreator.sol:222` | Calls allowlist initialization for the new presale ID. |
| `src/extensions/BonkerPresaleEthToCreator.sol:345` | Exposes `buyIntoPresaleWithProof` for proof-bearing contributions. |
| `src/extensions/BonkerPresaleEthToCreator.sol:370` | Enforces the delegated allowed amount during contribution. |
| `client/components/admin/abis.js:66` | Mirrors the `startPresale` ABI, including allowlist fields. |
| `client/components/admin/StartPresaleTab.jsx:51` | Holds the admin UI's `allowlistEnabled` state. |
| `client/components/admin/presaleConfig.js:91` | Sends `PRESALE_ALLOWLIST` or `ZERO_ADDR` and currently sends empty initialization data. |
| `client/components/admin/StartPresaleSections.jsx:90` | Renders the `Enable Allowlist` switch. |
| `server/presales.js:54` | Serializes the on-chain `allowlist` address into presale API responses. |
| `client/components/PresaleDetailPage.jsx:644` | Shows the presale allowlist address or `None (public)`. |
| `script/DeployPresale.s.sol:23` | Deploys the presale extension. |
| `script/DeployPresale.s.sol:26` | Deploys `BonkerPresaleAllowlist` bound to that presale extension. |
| `script/DeployPresale.s.sol:30` | Enables the deployed allowlist on the presale extension. |

## How It Works

### Deployment And Registry

`BonkerPresaleAllowlist` is constructed with the address of one `BonkerPresaleEthToCreator` contract. That immutable `presale` address is the only caller allowed to initialize per-presale allowlist state.

Deploying the checker is not enough. `BonkerPresaleEthToCreator` has its own owner-controlled `enabledAllowlists` registry. `startPresale` rejects any non-zero allowlist address that has not been enabled through `setAllowlist(address,bool)`.

The deployed mainnet stack has one `PresaleAllowlist` address. The admin console imports that address from `client/config/contracts.js` and passes it when the operator flips `Enable Allowlist` while starting a presale.

```text
DeployPresale.s.sol
  deploy BonkerPresaleEthToCreator
  deploy BonkerPresaleAllowlist(presale)
  presale.setAllowlist(allowlist, true)
  factory.setExtension(presale, true)

AdminPage startPresale
  allowlist off -> allowlist = address(0), initializationData = 0x
  allowlist on  -> allowlist = PRESALE_ALLOWLIST, initializationData = 0x
```

### Presale Initialization

`startPresale` assigns the next presale ID before it initializes the checker. If the selected allowlist is non-zero and enabled, the presale contract calls:

```text
IBonkerPresaleAllowlist(allowlist).initialize(
  presaleId,
  presaleOwner,
  allowlistInitializationData
)
```

The checker records `presaleOwner`, optionally decodes `AllowlistInitializationData` to set `merkleRoot`, and sets `enabled = true`.

Empty initialization data is valid. In that case, the root starts as `bytes32(0)`. This is the current admin UI behavior. It creates a gated presale shell, but it does not automatically grant anyone an allowance.

### Owner Controls

Every mutable allowlist operation is scoped to one presale ID and restricted to that presale's `presaleOwner`.

`setAddressOverride(presaleId, buyer, allowedAmount)` writes a direct allowance for one buyer. This path is useful for small curated lists, emergency fixes, or wallets that should not need a Merkle proof.

`setMerkleRoot(presaleId, merkleRoot)` updates the Merkle root used by proof-based buyers. The root can be set during initialization or later by the presale owner.

`setAllowlistEnabled(presaleId, enabled)` turns enforcement on or off for the presale. Disabling does not delete the root or overrides; it makes `getAllowedAmountForBuyer` return `type(uint256).max` for everyone while disabled.

### Buyer Contribution

Public presales call `buyIntoPresale(presaleId)`, which forwards an empty proof into the shared `_buyIntoPresale` path.

Allowlisted buyers can call `buyIntoPresaleWithProof(presaleId, proof)`, where `proof` is ABI-encoded as `AllowlistProof`:

```text
(
  uint256 allowedAmount,
  bytes32[] proof
)
```

The allowed amount is a total contribution cap for that buyer and presale, not a per-transaction cap. `_buyIntoPresale` first adds the accepted ETH to `presaleBuys[presaleId][msg.sender]`, then rejects the transaction if the buyer's cumulative amount is greater than the delegated allowed amount.

### Allowance Resolution

`getAllowedAmountForBuyer` resolves allowance in this order:

1. If allowlist enforcement is disabled for the presale, return `type(uint256).max`.
2. If the buyer has a positive address override, return that override.
3. If the proof bytes are empty, return `0`.
4. If the Merkle root is zero, revert `MerkleRootNotSet`.
5. Decode `AllowlistProof`.
6. If `allowedAmount` is zero, return `0`.
7. Verify the proof against `keccak256(bytes.concat(keccak256(abi.encode(buyer, allowedAmount))))`.
8. Return the proof's `allowedAmount`, or revert `InvalidProof`.

The address override wins over Merkle proofs. That means a presale owner can rescue or cap one address without rebuilding the full tree.

### API And UI Surface

The server does not compute allowlist membership. `serializePresale` includes the `allowlist` address returned by the presale contract, and `/api/presales` or `/api/presales/:id` can expose whether a sale is public or gated.

The presale detail page currently displays only the allowlist contract address. It does not collect Merkle proofs, encode `AllowlistProof`, or expose presale-owner controls for overrides, roots, or enforcement toggles.

That means allowlisted buyer participation currently requires an external transaction builder, direct contract interaction, or a future UI addition that encodes `buyIntoPresaleWithProof` correctly.

## Invariants And Edge Cases

`BonkerPresaleAllowlist.initialize` must only be callable by the bound presale contract. If an arbitrary caller could initialize a presale ID first, they could seize presale-owner control for that ID.

The allowlist address used in `startPresale` must already be enabled in `BonkerPresaleEthToCreator.enabledAllowlists`. This is separate from the factory extension allowlist. Factory extension enablement makes the presale extension usable during token deployment; presale allowlist enablement makes a checker address usable during presale creation.

The current admin UI sends `allowlistInitializationData = '0x'`. With enforcement enabled, buyers without overrides receive an allowed amount of `0` when calling `buyIntoPresale`, and proof-bearing buyers hit `MerkleRootNotSet` until the presale owner sets a non-zero root.

Address overrides are ignored when set to zero. A zero override does not explicitly deny an address; it falls through to proof handling or returns zero for empty proof.

The Merkle leaf includes both buyer address and allowed amount. If a buyer supplies the right proof with a different amount, verification fails.

Allowed amount is cumulative across the presale. A buyer can split contributions across transactions, but their `presaleBuys[presaleId][buyer]` total must stay at or below the returned allowance.

If the sale is near `maxEthGoal`, `_buyIntoPresale` may accept less ETH than `msg.value` and refund the excess. The allowlist comparison uses only the accepted `ethToUse` amount added to the buyer's cumulative total.

Disabling allowlist enforcement returns unlimited allowance for everyone. Use it as an intentional public-sale switch, not as a temporary pause.

The API and detail page expose the checker address, not its Merkle root, enabled state, overrides, or a buyer's remaining allowance.

## Cross-References

- [PRESALE-LIFECYCLE](./PRESALE-LIFECYCLE.md)
- [ADMIN-OPERATIONS-CONSOLE](./ADMIN-OPERATIONS-CONSOLE.md)
- [FACTORY-EXTENSION-LIFECYCLE](./FACTORY-EXTENSION-LIFECYCLE.md)
- [OWNER-ADMIN-PERMISSION-MODEL](./OWNER-ADMIN-PERMISSION-MODEL.md)
- [PUBLIC-API-ROUTE-CONTRACT](./PUBLIC-API-ROUTE-CONTRACT.md)
