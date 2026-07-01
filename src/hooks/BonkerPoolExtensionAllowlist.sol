// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IBonkerPoolExtensionAllowlist} from "./interfaces/IBonkerPoolExtensionAllowlist.sol";

import {OwnerAdmins} from "../utils/OwnerAdmins.sol";

contract BonkerPoolExtensionAllowlist is IBonkerPoolExtensionAllowlist, OwnerAdmins {
    uint8 public constant BONKER_VERSION = 2;
    bytes32 public constant BONKER_PROTOCOL_ID = keccak256("bonker.wtf");

    mapping(address extension => bool enabled) public enabledExtensions;

    constructor(address owner_) OwnerAdmins(owner_) {}

    function setPoolExtension(address extension, bool enabled) external onlyOwnerOrAdmin {
        enabledExtensions[extension] = enabled;
        emit SetPoolExtension(extension, enabled);
    }
}
