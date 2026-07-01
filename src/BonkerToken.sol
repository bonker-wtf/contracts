// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC7802} from "@contracts-bedrock/interfaces/L2/IERC7802.sol";
import {Predeploys} from "@contracts-bedrock/src/libraries/Predeploys.sol";
import {Unauthorized} from "@contracts-bedrock/src/libraries/errors/CommonErrors.sol";
import {IERC165} from "@openzeppelin/contracts/interfaces/IERC165.sol";
import {IERC5805} from "@openzeppelin/contracts/interfaces/IERC5805.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";

import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";

/*
╔════════════════════════════════════════════════════════════════╗
║                                                                ║
║      ██████╗  ██████╗ ███╗   ██╗██╗  ██╗███████╗██████╗        ║
║      ██╔══██╗██╔═══██╗████╗  ██║██║ ██╔╝██╔════╝██╔══██╗       ║
║      ██████╔╝██║   ██║██╔██╗ ██║█████╔╝ █████╗  ██████╔╝       ║
║      ██╔══██╗██║   ██║██║╚██╗██║██╔═██╗ ██╔══╝  ██╔══██╗       ║
║      ██████╔╝╚██████╔╝██║ ╚████║██║  ██╗███████╗██║  ██║       ║
║      ╚═════╝  ╚═════╝ ╚═╝  ╚═══╝╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝       ║
║                                                                ║
║                   ░▒▓█ BONKER PROTOCOL █▓▒░                    ║
║                                                                ║
╚════════════════════════════════════════════════════════════════╝
*/

contract BonkerToken is ERC20, ERC20Permit, ERC20Votes, ERC20Burnable, IERC7802 {
    /// @notice Identifies tokens deployed by the Bonker factory
    string public constant FACTORY_BRAND = "bonker.wtf";
    uint8 public constant BONKER_VERSION = 2;

    error NotAdmin();
    error NotOriginalAdmin();
    error AlreadyVerified();

    address private immutable _originalAdmin;
    address private _admin;
    string private _metadata;
    string private _context;
    string private _image;

    bool private _verified;

    event Verified(address indexed admin, address indexed token);
    event UpdateImage(string image);
    event UpdateMetadata(string metadata);
    event UpdateAdmin(address indexed oldAdmin, address indexed newAdmin);

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 maxSupply_,
        address admin_,
        string memory image_,
        string memory metadata_,
        string memory context_,
        uint256 initialSupplyChainId_
    ) ERC20(name_, symbol_) ERC20Permit(name_) {
        _originalAdmin = admin_;
        _admin = admin_;
        _image = image_;
        _metadata = metadata_;
        _context = context_;

        // Only mint initial supply on a single chain
        if (block.chainid == initialSupplyChainId_) {
            _mint(msg.sender, maxSupply_);
        }
    }

    /// @notice Transfers token admin rights to a new address.
    /// @param admin_ The address that will become the new token admin.
    function updateAdmin(address admin_) external {
        if (msg.sender != _admin) {
            revert NotAdmin();
        }
        address oldAdmin = _admin;
        _admin = admin_;
        emit UpdateAdmin(oldAdmin, admin_);
    }

    /// @notice Updates the token image URL stored onchain.
    /// @param image_ The new image URL or URI.
    function updateImage(string memory image_) external {
        if (msg.sender != _admin) {
            revert NotAdmin();
        }
        _image = image_;
        emit UpdateImage(image_);
    }

    /// @notice Updates the token metadata pointer stored onchain.
    /// @param metadata_ The new metadata URL or URI.
    function updateMetadata(string memory metadata_) external {
        if (msg.sender != _admin) {
            revert NotAdmin();
        }
        _metadata = metadata_;
        emit UpdateMetadata(metadata_);
    }

    function _update(address from, address to, uint256 value)
        internal
        override(ERC20, ERC20Votes)
    {
        super._update(from, to, value);
    }

    /// @notice Marks the token as verified by its original admin.
    function verify() external {
        if (msg.sender != _originalAdmin) {
            revert NotOriginalAdmin();
        }
        if (_verified) {
            revert AlreadyVerified();
        }
        _verified = true;
        emit Verified(msg.sender, address(this));
    }

    /// @notice Returns whether the original admin has verified this token.
    function isVerified() external view returns (bool) {
        return _verified;
    }

    /// @notice Returns the current permit nonce for an owner.
    /// @param owner The address whose nonce is being queried.
    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }

    /// @notice Returns the current token admin.
    function admin() external view returns (address) {
        return _admin;
    }

    /// @notice Returns the immutable original token admin.
    function originalAdmin() external view returns (address) {
        return _originalAdmin;
    }

    /// @notice Returns the token image URL or URI.
    function imageUrl() external view returns (string memory) {
        return _image;
    }

    /// @notice Returns the token metadata URL or URI.
    function metadata() external view returns (string memory) {
        return _metadata;
    }

    /// @notice Returns the token context string.
    function context() external view returns (string memory) {
        return _context;
    }

    /// @notice Returns the token's full admin and metadata payload in a single call.
    function allData()
        external
        view
        returns (
            address originalAdmin,
            address admin,
            string memory image,
            string memory metadata,
            string memory context
        )
    {
        return (_originalAdmin, _admin, _image, _metadata, _context);
    }

    /// @notice Mints bridged supply on the destination chain.
    /// @param _to The recipient of the bridged tokens.
    /// @param _amount The amount of tokens to mint.
    function crosschainMint(address _to, uint256 _amount) external {
        // Only the `SuperchainTokenBridge` has permissions to mint tokens during crosschain transfers.
        if (msg.sender != Predeploys.SUPERCHAIN_TOKEN_BRIDGE) revert Unauthorized();

        // Mint tokens to the `_to` account's balance.
        _mint(_to, _amount);

        // Emit the CrosschainMint event included on IERC7802 for tracking token mints associated with cross chain transfers.
        emit CrosschainMint(_to, _amount, msg.sender);
    }

    /// @notice Burns bridged supply on the source chain.
    /// @param _from The address whose bridged tokens will be burned.
    /// @param _amount The amount of tokens to burn.
    function crosschainBurn(address _from, uint256 _amount) external {
        // Only the `SuperchainTokenBridge` has permissions to burn tokens during crosschain transfers.
        if (msg.sender != Predeploys.SUPERCHAIN_TOKEN_BRIDGE) revert Unauthorized();

        // Burn the tokens from the `_from` account's balance.
        _burn(_from, _amount);

        // Emit the CrosschainBurn event included on IERC7802 for tracking token burns associated with cross chain transfers.
        emit CrosschainBurn(_from, _amount, msg.sender);
    }

    /// @notice Reports ERC-165 interface support for Bonker tokens.
    /// @param _interfaceId The interface selector being queried.
    function supportsInterface(bytes4 _interfaceId) public pure returns (bool) {
        return _interfaceId == type(IERC7802).interfaceId
            || _interfaceId == type(IERC20).interfaceId || _interfaceId == type(IERC165).interfaceId
            || _interfaceId == type(IERC5805).interfaceId;
    }
}
