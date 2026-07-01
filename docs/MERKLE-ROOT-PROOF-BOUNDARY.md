Merkle root/proof boundary explains how Bonker hashes airdrop allocations and presale allowlist caps, where roots enter launch or presale setup, and when to read this before changing `buildMerkleTree`, claim proof generation, `BonkerAirdropV2.claim`, `BonkerPresaleAllowlist.getAllowedAmountForBuyer`, or any UI that uploads CSV allowlists.

This page covers natural-language queries such as `buildMerkleTree`, `parseCsv`, `keccak256(bytes.concat(keccak256(abi.encode(...))))`, `MerkleProof.verifyCalldata`, `AllowlistProof`, `buyIntoPresaleWithProof`, "why does my airdrop proof fail", "why does a public launch CSV root not match the Solidity leaf", and "who computes Merkle proofs". It focuses on the off-chain/on-chain compatibility boundary. Contract lifecycle rules for airdrops and presale allowlists are covered by nearby docs.

## Why It Exists

Bonker uses Merkle roots in two places that look similar but are wired through different user flows:

- a token airdrop stores one root for `(recipient, allocatedAmount)` claims;
- a presale allowlist stores one root for `(buyer, allowedAmount)` contribution caps.

Both contracts verify the same Solidity leaf shape: `keccak256(bytes.concat(keccak256(abi.encode(address, uint256))))`. That is the OpenZeppelin-style double-hashed ABI-encoded leaf, not a single `abi.encodePacked(address,uint256)` leaf.

The sharp edge is that root creation is mostly off-chain. The server does not build Merkle trees, store CSVs, or generate proofs. The public launch page currently has a local CSV parser and root builder for airdrops, while admin presale creation usually starts with zero roots and expects an owner to set the real root later. If a root and proof generator do not use the same leaf and pair ordering as the contract, launches still deploy but later claims or gated buys fail with `InvalidProof`.

This boundary is worth documenting separately because the lifecycle docs describe each contract in isolation. Maintainers also need the compatibility map: which code path computes a root, which code path only stores a root, which proof envelope is raw `bytes32[]`, and which proof envelope is ABI-encoded as a tuple.

## Key Files

| File | Why it matters |
| --- | --- |
| `client/components/LaunchPage.jsx:113` | Defines the public launch page's `buildMerkleTree(entries)` helper. |
| `client/components/LaunchPage.jsx:117` | Hashes public airdrop CSV leaves with the Solidity-compatible double-hashed `abi.encode` shape. |
| `client/components/LaunchPage.jsx:130` | Sorts each pair before hashing parent nodes. |
| `client/components/LaunchPage.jsx:139` | Parses `address,amount` CSV rows for public launch airdrops. |
| `client/components/LaunchPage.jsx:371` | Builds an airdrop Merkle root from the parsed CSV during `buildDeploymentConfig()`. |
| `client/components/LaunchPage.jsx:379` | Encodes that root into `AirdropV2ExtensionData.merkleRoot`. |
| `client/components/LaunchPage.jsx:701` | Tells launchers to keep the CSV because proofs are generated from the same allocation data. |
| `client/components/admin/presaleConfig.js:91` | Sends the presale allowlist address or `ZERO_ADDR`, with empty initialization data. |
| `client/components/admin/presaleConfig.js:125` | Encodes admin presale airdrops with a zero Merkle root placeholder. |
| `src/extensions/BonkerAirdropV2.sol:184` | Verifies airdrop proofs against the stored V2 root. |
| `src/extensions/BonkerAirdropV2.sol:189` | Defines the V2 airdrop claim leaf as `keccak256(bytes.concat(keccak256(abi.encode(recipient, allocatedAmount))))`. |
| `src/extensions/BonkerAirdropV2.sol:228` | Exposes `amountAvailableToClaim()` but assumes the supplied allocation has a valid proof. |
| `src/extensions/BonkerAirdrop.sol:143` | Legacy V1 airdrop uses the same proof verifier shape. |
| `src/extensions/BonkerAirdrop.sol:146` | Legacy V1 claim leaf also uses double-hashed `abi.encode`. |
| `src/extensions/BonkerPresaleAllowlist.sol:23` | Defines the ABI envelope for presale allowlist proofs. |
| `src/extensions/BonkerPresaleAllowlist.sol:114` | Decodes proof bytes into `AllowlistProof`. |
| `src/extensions/BonkerPresaleAllowlist.sol:122` | Verifies the presale proof against the stored allowlist root. |
| `src/extensions/BonkerPresaleAllowlist.sol:125` | Defines the presale allowlist leaf as `keccak256(bytes.concat(keccak256(abi.encode(buyer, allowedAmount))))`. |
| `test/BonkerExtensionVesting.t.sol:236` | Builds a one-leaf test root with the Solidity-compatible double-hashed `abi.encode` shape. |
| `test/BonkerExtensionVesting.t.sol:293` | Uses an empty proof for a one-leaf tree in the airdrop vesting test. |
| `test/BonkerLegacyErc20Safety.t.sol:124` | Repeats the same one-leaf root shape for legacy ERC20 safety coverage. |

## How It Works

### Contract Leaf Shape

The live airdrop and presale allowlist contracts both hash a leaf as:

```text
leaf = keccak256(bytes.concat(keccak256(abi.encode(account, amount))))
```

For airdrops, `account` is `recipient` and `amount` is `allocatedAmount`. For presale allowlists, `account` is `buyer` and `amount` is `allowedAmount`.

The outer hash protects against second-preimage ambiguity when a pair of 32-byte values could otherwise be interpreted as an internal node. The inner `abi.encode` uses normal ABI padding, not packed encoding. Any external proof generator must mirror that shape exactly before building parent nodes.

The repo's Solidity tests show the one-leaf case clearly. A one-leaf root is just that leaf, and the proof array is empty:

```text
merkleRoot = keccak256(bytes.concat(keccak256(abi.encode(RECIPIENT, ALLOCATION))))
proof = []
```

### Airdrop Claims

`BonkerAirdropV2.claim(token, recipient, allocatedAmount, proof)` receives the raw `bytes32[]` proof array. It does not decode a proof envelope. It computes the double-hashed leaf from `recipient` and `allocatedAmount`, then calls `MerkleProof.verifyCalldata`.

That means the caller chooses the `allocatedAmount` they are trying to prove. If the root was built with a different amount for the same recipient, verification fails. If the root was built from the same CSV row but with packed leaf encoding, verification also fails because the contract leaf is different.

`amountAvailableToClaim(token, recipient, allocatedAmount)` does not verify the proof. It is only a vesting preview for an allocation the caller already knows can be proven. A UI that exposes claimability must treat this as a time-and-claimed-amount helper, not as membership validation.

### Presale Allowlist Proofs

`BonkerPresaleAllowlist` uses the same double-hashed `abi.encode` leaf, but the presale call path wraps the proof differently.

Buyers call `BonkerPresaleEthToCreator.buyIntoPresaleWithProof(presaleId, proof)`, and the `proof` bytes are forwarded to the allowlist checker. The checker decodes those bytes as:

```text
AllowlistProof
  allowedAmount: uint256
  proof: bytes32[]
```

The `allowedAmount` is the buyer's cumulative ETH cap for that presale. The verifier recomputes the leaf from `buyer` and `allowedAmount`, not from the transaction's `msg.value`. If the proof is valid, the presale compares the buyer's cumulative contribution against that cap.

A public presale contribution calls `buyIntoPresale(presaleId)`, which forwards empty proof bytes. Empty proof bytes return an allowance of zero while the allowlist is enabled, unless a positive address override exists or the allowlist has been disabled for that presale.

### Public Launch Airdrop CSV

The public `/launch` page is the only first-party UI that currently computes a nonzero Merkle root from user-entered rows. `parseCsv()` accepts lines shaped as `address,amount`, skips malformed rows, and preserves the amount string for later `BigInt(amount)` conversion.

`buildMerkleTree()` then hashes leaves as:

```text
leaf = keccak256(bytes.concat(keccak256(abi.encode(address, uint256))))
```

It pads the leaf array to a power of two by duplicating the last leaf, sorts each sibling pair lexicographically, hashes parents with packed `bytes32,bytes32`, and returns the final root. That matches the leaf shape used by `BonkerAirdropV2.claim()`, so proof generators should use the same leaf formula and pair ordering.

This is a compatibility boundary, not a server indexing concern. The token indexer stores the extension address and token detail enrichment can read airdrop state, but neither path can repair a root that was committed with a different leaf algorithm.

### Admin Presale Roots

The admin presale path does not build Merkle trees from CSV data.

For optional presale allowlists, `buildStartPresaleArgs()` passes either `PRESALE_ALLOWLIST` or `ZERO_ADDR`, then passes `allowlistInitializationData = '0x'`. When the allowlist is enabled, this creates a gated presale with no root. The presale owner must later set a root or use address overrides before proof-based buyers can contribute.

For optional airdrops attached to admin-started presales, `buildExtensionConfigs()` encodes an airdrop V2 tuple with `merkleRoot = bytes32(0)`. V2 allows this deferred root setup. Claims remain blocked until the airdrop admin sets a nonzero root.

The important distinction is that a zero root is inert but recoverable by the authorized owner or admin. A nonzero root built with the wrong leaf shape is a committed compatibility problem unless the specific contract's root-update rules still allow replacement.

### Server And API Boundary

The Express server does not accept CSV uploads, build roots, generate proofs, or check buyer membership.

For airdrops, token detail enrichment only reads stored on-chain state and claimed totals. For presale allowlists, presale API responses expose the allowlist address, but not the root, proof set, override map, enabled flag, or a connected wallet's remaining allowance.

This keeps the API out of custody of allocation lists, but it also means proof generation has to be handled by the launch/admin operator, an external tool, or a future browser-side feature that exactly matches the Solidity leaf and proof envelope.

## Invariants And Edge Cases

### Leaf Encoding Must Match The Verifier

The live Solidity verifier is authoritative. For both airdrop and presale allowlist membership, the leaf is double-hashed `abi.encode(address,uint256)`. Packed leaves produce different roots and invalid proofs.

### Pair Ordering Must Match The Proof Library

The contracts use OpenZeppelin `MerkleProof`, which expects the proof to be ordered consistently with the tree construction. When using sorted pairs, every parent level must sort siblings the same way the proof generator expects. Mixing sorted-pair roots with positional proofs fails.

### Airdrop Proofs Are Raw Arrays

An airdrop claim takes `bytes32[] proof` directly. Do not ABI-encode `(allocatedAmount, proof)` for `BonkerAirdropV2.claim`; `allocatedAmount` is already its own function argument.

### Presale Proofs Are ABI-Encoded Tuples

A presale allowlist contribution does not pass `bytes32[]` directly to the checker. It passes `bytes` that decode to `(uint256 allowedAmount, bytes32[] proof)`. Sending raw proof bytes to `buyIntoPresaleWithProof` will fail ABI decoding or verification.

### Amount Means Different Things By Domain

For airdrops, `allocatedAmount` is token units. For presale allowlists, `allowedAmount` is an ETH contribution cap in wei. The Merkle hashing shape is the same, but the unit semantics are not.

### One-Leaf Trees Use Empty Proofs

The tests use a one-leaf root and an empty proof. That only works because the root equals the exact contract leaf. It is not evidence that arbitrary empty proofs should pass for multi-leaf roots.

### Zero Roots Are Deferred State

V2 airdrops and presale allowlists can start with zero roots. A zero root does not make anyone eligible. It means the authorized admin or presale owner still has to set a compatible nonzero root, use overrides, or disable allowlist enforcement where that domain permits it.

### Public Launch CSV Uses The Contract Leaf Shape

`LaunchPage.buildMerkleTree()` and `BonkerAirdropV2.claim()` both use double-hashed ABI-encoded leaves. A maintainer changing airdrop CSV behavior must treat that as a root/proof compatibility issue, not a display-only refactor.

### CSV Rows Are Not Stored By Bonker

The public launch UI warns the launcher to keep the CSV. The chain stores only the root; the server stores only indexed launch and feature data. Losing the CSV means the allocation set cannot be reconstructed from Bonker state.

## Cross-References

- [AIRDROP-EXTENSION-LIFECYCLE](./AIRDROP-EXTENSION-LIFECYCLE.md) for V2 root updates, claim timing, admin leftovers, and legacy airdrop differences.
- [PRESALE-ALLOWLIST-LIFECYCLE](./PRESALE-ALLOWLIST-LIFECYCLE.md) for presale owner controls, address overrides, allowlist enablement, and buyer contribution checks.
- [LAUNCH-FORM-DEPLOYMENT-CONFIG](./LAUNCH-FORM-DEPLOYMENT-CONFIG.md) for how `/launch` builds the full `DeploymentConfig` around extension data.
- [ADMIN-OPERATIONS-CONSOLE](./ADMIN-OPERATIONS-CONSOLE.md) for admin presale creation and the zero-root airdrop/allowlist setup path.
- [FACTORY-EXTENSION-LIFECYCLE](./FACTORY-EXTENSION-LIFECYCLE.md) for how extension configs reserve token supply and forward extension data.
- [TOKEN-DETAIL-ENRICHMENT](./TOKEN-DETAIL-ENRICHMENT.md) for request-time reads that surface airdrop state without generating proofs.
- [SOLIDITY-CUSTOM-ERROR-REFERENCE](./SOLIDITY-CUSTOM-ERROR-REFERENCE.md) for `InvalidProof`, `MerkleRootNotSet`, and related launch or claim revert triage.
