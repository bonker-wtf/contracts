// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";

/// @notice Guard for scripts that still carry hardcoded addresses for one specific chain.
///
/// Several operator scripts under `script/` hold Base-mainnet literals — factory, hooks,
/// locker, WETH — because they exist to drive the Base deployment, not to stand a new chain
/// up. That was harmless while Base was the only chain. It is not harmless now: `forge script`
/// takes its target from `--rpc-url`, so pointing one of these at another chain runs Base's
/// addresses against that chain's state. On a fresh chain those addresses hold no code, and a
/// call to a codeless address does not revert — it returns empty, which decodes as zero. The
/// script then reports success having done nothing, or worse, broadcasts a transaction whose
/// target is an address someone else may later deploy to.
///
/// Inheriting this and calling `onlyChain(...)` turns that silent wrong-chain run into an
/// immediate revert naming both chains. Scripts that are genuinely chain-agnostic (the
/// Deploy*/Redeploy* family, which read every address from the environment) do not need it.
abstract contract ChainPinnedScript is Script {
    error WrongChain(uint256 expected, uint256 actual);

    uint256 internal constant BASE_CHAIN_ID = 8453;

    modifier onlyChain(uint256 expectedChainId) {
        if (block.chainid != expectedChainId) revert WrongChain(expectedChainId, block.chainid);
        _;
    }
}
