// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IBonker} from "../interfaces/IBonker.sol";
import {IBonkerExtension} from "../interfaces/IBonkerExtension.sol";
import {IBonkerVault} from "./interfaces/IBonkerVault.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title BonkerVault
/// @notice Holds a portion of a Bonker token's supply under a lockup/vesting schedule for the vault admin.
/// @dev Created via `receiveTokens` called by the factory at token deployment time. Only one allocation
///      per token is allowed.
contract BonkerVault is ReentrancyGuard, IBonkerVault {
    address public immutable factory;

    mapping(address => Allocation) public allocation;

    uint256 public constant MIN_LOCKUP_DURATION = 7 days;

    modifier onlyFactory() {
        if (msg.sender != factory) revert Unauthorized();
        _;
    }

    constructor(address factory_) {
        factory = factory_;
    }

    /// @notice Called by the factory at token deployment to create the vault allocation.
    /// @dev Only callable by the factory. Reverts if an allocation already exists for this token or
    ///      lockup duration is below MIN_LOCKUP_DURATION.
    /// @param deploymentConfig Full deployment config; `extensionData` at `extensionIndex` encodes `VaultExtensionData`.
    /// @param token The deployed ERC20 token address.
    /// @param extensionSupply Token amount allocated to this vault.
    /// @param extensionIndex Index of this extension in `deploymentConfig.extensionConfigs`.
    function receiveTokens(
        IBonker.DeploymentConfig calldata deploymentConfig,
        PoolKey memory,
        address token,
        uint256 extensionSupply,
        uint256 extensionIndex
    ) external payable nonReentrant onlyFactory {
        VaultExtensionData memory vaultData = abi.decode(
            deploymentConfig.extensionConfigs[extensionIndex].extensionData, (VaultExtensionData)
        );

        // ensure that the msgValue is zero
        if (deploymentConfig.extensionConfigs[extensionIndex].msgValue != 0 || msg.value != 0) {
            revert IBonkerExtension.InvalidMsgValue();
        }

        uint256 lockupEndTime = block.timestamp + vaultData.lockupDuration;

        // check the vault percentage is not zero
        if (deploymentConfig.extensionConfigs[extensionIndex].extensionBps == 0) {
            revert InvalidVaultBps();
        }

        // check that minimum lockup duration is met
        if (vaultData.lockupDuration < MIN_LOCKUP_DURATION) {
            revert VaultLockupDurationTooShort();
        }

        // check the admin is set
        if (vaultData.admin == address(0)) {
            revert InvalidVaultAdmin();
        }

        // only one allocation per token
        if (allocation[token].lockupEndTime != 0) revert AllocationAlreadyExists();

        allocation[token] = Allocation({
            token: token,
            amountTotal: extensionSupply,
            amountClaimed: 0,
            lockupEndTime: lockupEndTime,
            vestingEndTime: lockupEndTime + vaultData.vestingDuration,
            admin: vaultData.admin
        });

        // pull in token
        SafeERC20.safeTransferFrom(IERC20(token), msg.sender, address(this), extensionSupply);

        emit AllocationCreated({
            token: token,
            admin: vaultData.admin,
            supply: extensionSupply,
            lockupDuration: vaultData.lockupDuration,
            vestingDuration: vaultData.vestingDuration
        });
    }

    /// @notice Transfers vault admin rights to a new address.
    /// @dev Only the current admin for `token` can call this. The admin receives all claimed tokens.
    /// @param token The token whose vault admin is being changed.
    /// @param newAdmin The new admin address.
    function editAllocationAdmin(address token, address newAdmin) external {
        if (msg.sender != allocation[token].admin) revert Unauthorized();
        allocation[token].admin = newAdmin;

        emit AllocationAdminUpdated(token, msg.sender, newAdmin);
    }

    /// @notice Returns how many tokens are currently claimable from the vault for `token`.
    /// @dev Returns 0 during lockup. Increases linearly during vesting. Full remainder after vesting ends.
    /// @param token The token to query.
    /// @return Amount of tokens claimable right now.
    function amountAvailableToClaim(address token) external view returns (uint256) {
        return _getAmountToClaim(token);
    }

    /// @notice Claims all currently vested tokens and sends them to the vault admin.
    /// @dev Anyone can call this; tokens always go to the registered admin. Reverts if lockup has
    ///      not passed or there is nothing vested yet.
    /// @param token The token to claim from the vault.
    function claim(address token) external nonReentrant {
        // ensure lockup period has passed
        if (block.timestamp < allocation[token].lockupEndTime) {
            revert AllocationNotUnlocked();
        }

        uint256 amountToClaim;

        // check amount to claim
        amountToClaim = _getAmountToClaim(token);
        if (amountToClaim == 0) revert NoBalanceToClaim();

        // update the amount claimed
        allocation[token].amountClaimed += amountToClaim;

        SafeERC20.safeTransfer(IERC20(token), allocation[token].admin, amountToClaim);

        emit AllocationClaimed(token, amountToClaim, allocation[token].amountTotal - amountToClaim);
    }

    function _getAmountToClaim(address token) internal view returns (uint256) {
        if (block.timestamp < allocation[token].lockupEndTime) {
            // still in lockup period
            return 0;
        } else if (block.timestamp >= allocation[token].vestingEndTime) {
            // if the vesting period has passed, claim the remaining balance
            return allocation[token].amountTotal - allocation[token].amountClaimed;
        } else {
            // if the vesting period has not passed, calculate the amount to claim based on the
            // vesting period and how much has already been claimed
            uint256 totalAmountAvailable = allocation[token].amountTotal
                * (block.timestamp - allocation[token].lockupEndTime)
                / (allocation[token].vestingEndTime - allocation[token].lockupEndTime);

            return totalAmountAvailable - allocation[token].amountClaimed;
        }
    }

    /// @notice Returns true for the IBonkerExtension interface ID.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IBonkerExtension).interfaceId;
    }
}
