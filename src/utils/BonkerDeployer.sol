// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BonkerToken} from "../BonkerToken.sol";
import {IBonker} from "../interfaces/IBonker.sol";

/// @notice Bonker Token Launcher
library BonkerDeployer {
    uint8 public constant BONKER_VERSION = 2;
    bytes32 public constant BONKER_PROTOCOL_ID = keccak256("bonker.wtf");
    function deployToken(IBonker.TokenConfig memory tokenConfig, uint256 supply)
        external
        returns (address tokenAddress)
    {
        BonkerToken token = new BonkerToken{
            salt: keccak256(abi.encode(tokenConfig.tokenAdmin, tokenConfig.salt))
        }(
            tokenConfig.name,
            tokenConfig.symbol,
            supply,
            tokenConfig.tokenAdmin,
            tokenConfig.image,
            tokenConfig.metadata,
            tokenConfig.context,
            tokenConfig.originatingChainId
        );
        tokenAddress = address(token);
    }
}
