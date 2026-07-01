// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IBonker} from "../interfaces/IBonker.sol";
import {IBonkerExtension} from "../interfaces/IBonkerExtension.sol";
import {IBonkerAirdrop} from "./interfaces/IBonkerAirdrop.sol";

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {Hashes} from "@openzeppelin/contracts/utils/cryptography/Hashes.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title BonkerAirdrop
/// @notice Factory extension that locks a portion of a token's supply for a Merkle-based
///         airdrop with configurable lockup and linear vesting periods.  Recipients prove
///         their allocation with a Merkle proof and can claim vested tokens incrementally
///         after the lockup ends.
contract BonkerAirdrop is ReentrancyGuard, IBonkerAirdrop {
    address public immutable factory;
    mapping(address token => Airdrop airdrop) public airdrops;

    uint256 public constant MIN_LOCKUP_DURATION = 1 days;

    modifier onlyFactory() {
        if (msg.sender != factory) revert Unauthorized();
        _;
    }

    constructor(address factory_) {
        factory = factory_;
    }

    /// @notice Called by the factory during token deployment to initialise the airdrop.
    /// @dev Decodes {AirdropExtensionData} from `deploymentConfig`, validates parameters, and
    ///      pulls `extensionSupply` tokens from the factory into this contract.
    ///      Reverts if an airdrop already exists for the token, if `msg.value` is non-zero,
    ///      if the Merkle root is unset, if BPS is zero, or if the lockup is too short.
    ///      Emits {AirdropCreated}.
    /// @param deploymentConfig Full deployment configuration containing the extension config array.
    /// @param token Address of the token being airdropped.
    /// @param extensionSupply Total token amount allocated to this airdrop.
    /// @param extensionIndex Index of this extension's config in `deploymentConfig.extensionConfigs`.
    function receiveTokens(
        IBonker.DeploymentConfig calldata deploymentConfig,
        PoolKey memory,
        address token,
        uint256 extensionSupply,
        uint256 extensionIndex
    ) external payable nonReentrant onlyFactory {
        AirdropExtensionData memory airdropData = abi.decode(
            deploymentConfig.extensionConfigs[extensionIndex].extensionData, (AirdropExtensionData)
        );

        // check that we don't already have an airdrop for this token
        if (airdrops[token].merkleRoot != bytes32(0)) {
            revert AirdropAlreadyExists();
        }

        // ensure that the msgValue is zero
        if (deploymentConfig.extensionConfigs[extensionIndex].msgValue != 0 || msg.value != 0) {
            revert IBonkerExtension.InvalidMsgValue();
        }

        // ensure that the merkle root is set
        if (airdropData.merkleRoot == bytes32(0)) {
            revert InvalidMerkleRoot();
        }

        // check the airdrop percentage is not zero
        if (deploymentConfig.extensionConfigs[extensionIndex].extensionBps == 0) {
            revert InvalidAirdropPercentage();
        }

        // check that minimum lockup duration is met
        if (airdropData.lockupDuration < MIN_LOCKUP_DURATION) {
            revert AirdropLockupDurationTooShort();
        }

        // set the lockup and vesting end times
        airdrops[token].lockupEndTime = block.timestamp + airdropData.lockupDuration;
        airdrops[token].vestingEndTime =
            block.timestamp + airdropData.lockupDuration + airdropData.vestingDuration;

        // set fields
        airdrops[token].merkleRoot = airdropData.merkleRoot;
        airdrops[token].totalClaimed = 0;
        airdrops[token].totalSupply = extensionSupply;

        // pull in token
        SafeERC20.safeTransferFrom(IERC20(token), msg.sender, address(this), extensionSupply);

        emit AirdropCreated({
            token: token,
            merkleRoot: airdropData.merkleRoot,
            supply: extensionSupply,
            lockupDuration: airdropData.lockupDuration,
            vestingDuration: airdropData.vestingDuration
        });
    }

    /// @notice Claims vested airdrop tokens for a recipient.
    /// @dev Verifies the Merkle proof, enforces the lockup period, and transfers the linearly
    ///      vested portion that has not yet been claimed.  Emits {AirdropClaimed}.
    /// @param token Address of the airdropped token.
    /// @param recipient Address entitled to the allocation (included in the Merkle leaf).
    /// @param allocatedAmount Total tokens allocated to `recipient` per the Merkle tree.
    /// @param proof Merkle proof verifying `recipient`/`allocatedAmount` against the stored root.
    function claim(
        address token,
        address recipient,
        uint256 allocatedAmount,
        bytes32[] calldata proof
    ) external nonReentrant {
        Airdrop storage airdrop = airdrops[token];

        // check that the airdrop exists
        if (airdrop.merkleRoot == bytes32(0)) {
            revert AirdropNotCreated();
        }

        // check that the lockup period has passed
        if (block.timestamp < airdrop.lockupEndTime) {
            revert AirdropNotUnlocked();
        }

        // check that the allocated amount is not zero
        if (allocatedAmount == 0) {
            revert ZeroClaim();
        }

        // check that the max claim amount has not been exceeded
        if (airdrop.totalClaimed >= airdrop.totalSupply) {
            revert TotalMaxClaimed();
        }

        // verify proof
        if (
            !MerkleProof.verifyCalldata(
                proof,
                airdrop.merkleRoot,
                keccak256(bytes.concat(keccak256(abi.encode(recipient, allocatedAmount))))
            )
        ) {
            revert InvalidProof();
        }

        // calculate amount available to claim
        uint256 amountClaimed = airdrop.amountClaimed[recipient];
        if (amountClaimed == allocatedAmount) {
            revert UserMaxClaimed();
        }

        // get total available amount unlocked
        uint256 claimableAmount = _getAmountClaimable(token, allocatedAmount, amountClaimed);

        // modulate down the amount available to claim if greater than available supply
        if (airdrop.totalClaimed + claimableAmount >= airdrop.totalSupply) {
            claimableAmount = airdrop.totalSupply - airdrop.totalClaimed;
        }

        if (claimableAmount == 0) {
            revert ZeroToClaim();
        }

        // update claimed amounts
        airdrop.amountClaimed[recipient] += claimableAmount;
        airdrop.totalClaimed += claimableAmount;

        // transfer tokens
        SafeERC20.safeTransfer(IERC20(token), recipient, claimableAmount);

        emit AirdropClaimed(
            token,
            recipient,
            airdrop.amountClaimed[recipient],
            allocatedAmount - airdrop.amountClaimed[recipient]
        );
    }

    /// @notice Returns the amount of tokens `recipient` can claim right now given a valid proof.
    /// @dev Returns 0 if still within the lockup period. Does not verify the Merkle proof.
    /// @param token Address of the airdropped token.
    /// @param recipient Address whose claimable balance to query.
    /// @param allocatedAmount Total tokens allocated to `recipient` per the Merkle tree.
    /// @return The number of tokens available to claim at the current block timestamp.
    function amountAvailableToClaim(address token, address recipient, uint256 allocatedAmount)
        external
        view
        returns (uint256)
    {
        if (airdrops[token].merkleRoot == bytes32(0)) {
            revert AirdropNotCreated();
        }

        if (block.timestamp < airdrops[token].lockupEndTime) return 0;

        return _getAmountClaimable(token, allocatedAmount, airdrops[token].amountClaimed[recipient]);
    }

    function _getAmountClaimable(address token, uint256 allocatedAmount, uint256 totalUserClaimed)
        internal
        view
        returns (uint256)
    {
        if (block.timestamp >= airdrops[token].vestingEndTime) {
            // if the vesting period has passed, withdraw the remaining balance
            return allocatedAmount - totalUserClaimed;
        } else {
            // if the vesting period has not passed, calculate the amount to withdraw based on the
            // vesting period and how much has already been withdrawn
            uint256 totalAmountAvailable = allocatedAmount
                * (block.timestamp - airdrops[token].lockupEndTime)
                / (airdrops[token].vestingEndTime - airdrops[token].lockupEndTime);

            return totalAmountAvailable - totalUserClaimed;
        }
    }

    /// @notice Returns true if this contract implements the given ERC-165 interface.
    /// @param interfaceId The interface identifier to check.
    /// @return True when `interfaceId` matches {IBonkerExtension}.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IBonkerExtension).interfaceId;
    }
}
