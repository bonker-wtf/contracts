// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IBonker} from "../interfaces/IBonker.sol";
import {IBonkerExtension} from "../interfaces/IBonkerExtension.sol";
import {IBonkerPresaleAllowlist} from "./interfaces/IBonkerPresaleAllowlist.sol";
import {IBonkerPresaleEthToCreator} from "./interfaces/IBonkerPresaleEthToCreator.sol";

import {IOwnerAdmins} from "../interfaces/IOwnerAdmins.sol";
import {OwnerAdmins} from "../utils/OwnerAdmins.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title BonkerPresaleEthToCreator
/// @notice Manages ETH-funded presales for Bonker token deployments. Contributors receive tokens
///         proportional to their ETH contribution once the token is deployed and lockup/vesting passes.
/// @dev Admins create presales referencing a full DeploymentConfig. On success the contract calls
///      `factory.deployToken()` and receives the token allocation via `receiveTokens`. The presale
///      extension must always be the last entry in `extensionConfigs`.
contract BonkerPresaleEthToCreator is ReentrancyGuard, IBonkerPresaleEthToCreator, OwnerAdmins {
    IBonker public immutable factory;

    // deployment time buffers
    uint256 public constant SALT_SET_BUFFER = 1 days; // buffer for presale admin to set salt for deployment
    uint256 public constant DEPLOYMENT_BAD_BUFFER = 3 days; // buffer for deployment to be considered bad

    // max presale duration
    uint256 public constant MAX_PRESALE_DURATION = 6 weeks;

    // min lockup duration
    uint256 public minLockupDuration;

    // bonker fee info
    uint256 public bonkerDefaultFeeBps;
    uint256 public constant BPS = 10_000;
    address public bonkerFeeRecipient;

    // next presale id
    uint256 private _presaleId;

    // per presale info
    mapping(uint256 presaleId => Presale presale) public presaleState;
    mapping(uint256 presaleId => mapping(address user => uint256 amount)) public presaleBuys;
    mapping(uint256 presaleId => mapping(address user => uint256 amount)) public presaleClaimed;

    // enabled allowlists
    mapping(address allowlist => bool enabled) public enabledAllowlists;

    modifier onlyFactory() {
        if (msg.sender != address(factory)) revert Unauthorized();
        _;
    }

    modifier presaleExists(uint256 presaleId_) {
        if (presaleState[presaleId_].maxEthGoal == 0) revert InvalidPresale();
        _;
    }

    modifier updatePresaleState(uint256 presaleId_) {
        Presale storage presale = presaleState[presaleId_];

        // update to minimum or failed if time expired if in active state
        if (presale.status == PresaleStatus.Active && presale.endTime <= block.timestamp) {
            if (presale.ethRaised >= presale.minEthGoal) {
                presale.status = PresaleStatus.SuccessfulMinimumHit;
            } else {
                presale.status = PresaleStatus.Failed;
            }
        }
        _;
    }

    constructor(address owner_, address factory_, address bonkerFeeRecipient_) OwnerAdmins(owner_) {
        factory = IBonker(factory_);
        _presaleId = 1;
        bonkerFeeRecipient = bonkerFeeRecipient_;
        minLockupDuration = 7 days;
        bonkerDefaultFeeBps = 500; // 5%
    }

    /// @notice Enables or disables an allowlist contract for use in presales.
    /// @param allowlist The allowlist contract address.
    /// @param enabled Whether the allowlist may be used in new presales.
    function setAllowlist(address allowlist, bool enabled) external onlyOwner {
        enabledAllowlists[allowlist] = enabled;
        emit SetAllowlist(allowlist, enabled);
    }

    /// @notice Sets the minimum lockup duration enforced on new presales.
    /// @param minLockupDuration_ New minimum in seconds.
    function setMinLockupDuration(uint256 minLockupDuration_) external onlyOwner {
        uint256 oldMinLockupDuration = minLockupDuration;
        minLockupDuration = minLockupDuration_;
        emit MinLockupDurationUpdated(oldMinLockupDuration, minLockupDuration_);
    }

    /// @notice Sets the default protocol fee (in BPS) applied to newly created presales.
    /// @dev Must be less than BPS (10_000). Existing presale fees are unaffected.
    /// @param bonkerDefaultFeeBps_ New default fee in basis points.
    function setBonkerDefaultFee(uint256 bonkerDefaultFeeBps_) external onlyOwner {
        if (bonkerDefaultFeeBps_ >= BPS) revert InvalidBonkerFee();

        uint256 oldFee = bonkerDefaultFeeBps;
        bonkerDefaultFeeBps = bonkerDefaultFeeBps_;

        emit BonkerDefaultFeeUpdated(oldFee, bonkerDefaultFeeBps_);
    }

    /// @notice Overrides the protocol fee for a specific presale (can only decrease it).
    /// @dev Reverts if `newFee >= presaleState[presaleId].bonkerFee`.
    /// @param presaleId The presale whose fee is being lowered.
    /// @param newFee New fee in basis points; must be strictly less than the current fee.
    function setBonkerFeeForPresale(uint256 presaleId, uint256 newFee)
        external
        presaleExists(presaleId)
        onlyOwner
    {
        // can only set lower
        if (newFee >= presaleState[presaleId].bonkerFee) revert InvalidBonkerFee();

        uint256 oldFee = presaleState[presaleId].bonkerFee;
        presaleState[presaleId].bonkerFee = newFee;
        emit BonkerFeeUpdatedForPresale(presaleId, oldFee, newFee);
    }

    /// @notice Returns the full state of a presale.
    /// @param presaleId_ The presale identifier.
    /// @return Full `Presale` struct.
    function getPresale(uint256 presaleId_) public view returns (Presale memory) {
        return presaleState[presaleId_];
    }

    /// @notice Updates the address that receives the Bonker protocol fee on ETH claims.
    /// @param recipient New fee recipient address.
    function setBonkerFeeRecipient(address recipient) external onlyOwner {
        address oldRecipient = bonkerFeeRecipient;
        bonkerFeeRecipient = recipient;
        emit BonkerFeeRecipientUpdated(oldRecipient, recipient);
    }

    /// @notice Creates a new presale backed by `deploymentConfig`.
    /// @dev Only callable by an admin. The last entry in `deploymentConfig.extensionConfigs` must
    ///      point to this contract with `extensionBps > 0` and `msgValue == 0`.
    ///      It is recommended to simulate `factory.deployToken(deploymentConfig)` before calling
    ///      this to verify the config reaches the `NotExpectingTokenDeployment` revert.
    /// @param deploymentConfig Token deployment config; the last extension config must be this presale.
    /// @param minEthGoal Minimum ETH that must be raised; presale fails if not met by `endTime`.
    /// @param maxEthGoal Maximum ETH cap; contributions beyond this are refunded.
    /// @param presaleDuration Active duration in seconds (max MAX_PRESALE_DURATION).
    /// @param presaleOwner Address that can end the presale early and claim raised ETH.
    /// @param lockupDuration Seconds after deployment before token claiming opens (min `minLockupDuration`).
    /// @param vestingDuration Seconds over which tokens vest linearly after lockup ends (0 = cliff only).
    /// @param allowlist Optional allowlist contract; use address(0) for no allowlist.
    /// @param allowlistInitializationData Arbitrary data forwarded to the allowlist on initialization.
    /// @return presaleId The newly assigned presale identifier.
    function startPresale(
        IBonker.DeploymentConfig memory deploymentConfig,
        uint256 minEthGoal,
        uint256 maxEthGoal,
        uint256 presaleDuration,
        address presaleOwner,
        uint256 lockupDuration,
        uint256 vestingDuration,
        address allowlist,
        bytes calldata allowlistInitializationData
    ) external onlyAdmin returns (uint256 presaleId) {
        presaleId = _presaleId++;

        // ensure presale presaleOwner is set
        if (presaleOwner == address(0)) {
            revert InvalidPresaleOwner();
        }

        // ensure presale is present the last extension in the token's deployment config
        if (
            deploymentConfig.extensionConfigs.length == 0
                || deploymentConfig.extensionConfigs[deploymentConfig.extensionConfigs.length
                            - 1].extension != address(this)
        ) {
            revert PresaleNotLastExtension();
        }

        // ensure presale supply is not zero
        if (
            deploymentConfig.extensionConfigs[deploymentConfig.extensionConfigs.length
                        - 1].extensionBps == 0
        ) {
            revert InvalidPresaleSupply();
        }

        // ensure msg value is zero
        if (
            deploymentConfig.extensionConfigs[deploymentConfig.extensionConfigs.length - 1].msgValue
                != 0
        ) {
            revert InvalidMsgValue();
        }

        // ensure min and max eth goals are present and valid
        if (maxEthGoal == 0 || minEthGoal > maxEthGoal) {
            revert InvalidEthGoal();
        }

        // ensure time limit is present and valid
        if (presaleDuration == 0 || presaleDuration > MAX_PRESALE_DURATION) {
            revert InvalidPresaleDuration();
        }

        // ensure lockup duration is valid
        if (lockupDuration < minLockupDuration) {
            revert LockupDurationTooShort();
        }

        // check that allowlist checker is enabled
        if (allowlist != address(0) && !enabledAllowlists[allowlist]) {
            revert AllowlistNotEnabled();
        }

        // initialize allowlist checker
        if (allowlist != address(0)) {
            IBonkerPresaleAllowlist(allowlist)
                .initialize(presaleId, presaleOwner, allowlistInitializationData);
        }

        // set token deployment config's presale ID
        deploymentConfig.extensionConfigs[deploymentConfig.extensionConfigs.length
                - 1].extensionData = abi.encode(presaleId);

        // note: it is recommended to simulate a call to deployToken() with the deploymentConfig
        // to ensure that the token will fail with 'NotExpectingTokenDeployment()',
        // reaching this error messages means that the deploymentConfig is valid up to the
        // point of this presale executing.
        // callers can perform that simulation before startPresale; this stores the live presale ID

        presaleState[presaleId] = Presale({
            presaleOwner: presaleOwner,
            allowlist: allowlist,
            deploymentConfig: deploymentConfig,
            status: PresaleStatus.Active,
            minEthGoal: minEthGoal,
            maxEthGoal: maxEthGoal,
            endTime: block.timestamp + presaleDuration,
            ethRaised: 0,
            deploymentExpected: false,
            deployedToken: address(0),
            tokenSupply: 0,
            ethClaimed: false,
            lockupDuration: lockupDuration,
            vestingDuration: vestingDuration,
            lockupEndTime: 0,
            vestingEndTime: 0,
            bonkerFee: bonkerDefaultFeeBps
        });

        emit PresaleStarted({
            presaleId: presaleId,
            allowlist: allowlist,
            deploymentConfig: deploymentConfig,
            minEthGoal: minEthGoal,
            maxEthGoal: maxEthGoal,
            presaleDuration: presaleDuration,
            presaleOwner: presaleOwner,
            lockupDuration: lockupDuration,
            vestingDuration: vestingDuration,
            bonkerFeeBps: bonkerDefaultFeeBps
        });
    }

    /// @notice Deploys the presale token once a successful condition is reached.
    /// @dev Can be called by anyone once status is SuccessfulMaximumHit or SuccessfulMinimumHit.
    ///      The presale owner can also end early while still Active (min goal must be met).
    ///      There is a SALT_SET_BUFFER window reserved for the presale owner to supply the salt first.
    ///      If DEPLOYMENT_BAD_BUFFER elapses after `endTime` with no successful deploy, the presale fails
    ///      (allowing refunds) — this handles configs that revert during deployment.
    /// @param presaleId The presale to end.
    /// @param salt CREATE2 salt for deterministic token deployment.
    /// @return token The deployed token address, or address(0) if the presale was marked failed.
    function endPresale(uint256 presaleId, bytes32 salt)
        external
        presaleExists(presaleId)
        updatePresaleState(presaleId)
        returns (address token)
    {
        Presale storage presale = presaleState[presaleId];

        // presale can be ended in three states:
        // 1. maximum eth is hit at any point
        // 2. min eth is hit and deadline has expired
        // 3. min eth is hit and the presale owner wants to end the presale early (must be in active state)
        bool presaleCanEnd = presale.status == PresaleStatus.SuccessfulMaximumHit
            || presale.status == PresaleStatus.SuccessfulMinimumHit
            || (presale.status == PresaleStatus.Active
                && msg.sender == presale.presaleOwner
                && presale.minEthGoal <= presale.ethRaised);
        if (!presaleCanEnd) revert PresaleNotReadyForDeployment();

        // if presale's end time has passed without a successful deployment, set the presale to failed
        //
        // presales with an invalid token deployment config can fail to deploy. we don't want
        // to fail the presale if a single bad deploy happens, as someone could force a bad deploy
        // by calling endPresale() with a salt that resolves to an already deployed token
        if (presale.endTime + DEPLOYMENT_BAD_BUFFER < block.timestamp) {
            // allow users to withdraw their eth
            presale.status = PresaleStatus.Failed;
            emit PresaleFailed(presaleId);
            return address(0);
        }

        // give presale owner opportunity to set the salt
        if (
            msg.sender != presale.presaleOwner
                && block.timestamp < presale.endTime + SALT_SET_BUFFER
        ) {
            revert PresaleSaltBufferNotExpired();
        }

        // update token deployment config with salt
        presale.deploymentConfig.tokenConfig.salt = salt;

        // record lockup and vesting end times
        presale.lockupEndTime = block.timestamp + presale.lockupDuration;
        presale.vestingEndTime = presale.lockupEndTime + presale.vestingDuration;

        // set deployment ongoing to true
        presale.deploymentExpected = true;

        // deploy token
        token = factory.deployToken(presale.deploymentConfig);

        emit PresaleDeployed(presaleId, token);
    }

    /// @notice Contributes ETH to the presale (no allowlist proof required).
    /// @dev Excess ETH beyond maxEthGoal is refunded. Presale must be Active and within its time limit.
    /// @param presaleId The presale to contribute to.
    function buyIntoPresale(uint256 presaleId) external payable {
        _buyIntoPresale(presaleId, bytes(""));
    }

    /// @notice Contributes ETH to the presale using an allowlist membership proof.
    /// @param presaleId The presale to contribute to.
    /// @param proof Membership proof forwarded to the allowlist contract.
    function buyIntoPresaleWithProof(uint256 presaleId, bytes calldata proof) external payable {
        _buyIntoPresale(presaleId, proof);
    }

    /// @dev Shared buy path for both public and allowlisted presale entries.
    function _buyIntoPresale(uint256 presaleId, bytes memory proof)
        internal
        presaleExists(presaleId)
        nonReentrant
    {
        Presale storage presale = presaleState[presaleId];

        // ensure presale is active and time limit has not been reached
        if (presale.status != PresaleStatus.Active || presale.endTime <= block.timestamp) {
            revert PresaleNotActive();
        }

        // determine amount of eth to use for presale
        uint256 ethToUse = msg.value + presale.ethRaised > presale.maxEthGoal
            ? presale.maxEthGoal - presale.ethRaised
            : msg.value;

        // record a user's eth contribution
        presaleBuys[presaleId][msg.sender] += ethToUse;

        // check if a user is allowlisted
        if (presale.allowlist != address(0)) {
            uint256 allowedAmount = IBonkerPresaleAllowlist(presale.allowlist)
                .getAllowedAmountForBuyer(presaleId, msg.sender, proof);
            if (presaleBuys[presaleId][msg.sender] > allowedAmount) {
                revert AllowlistAmountExceeded(allowedAmount);
            }
        }

        // update eth raised
        presale.ethRaised += ethToUse;

        // update presale state if max eth goal is met, do not update if min goal is met
        if (presale.ethRaised == presale.maxEthGoal) {
            presale.status = PresaleStatus.SuccessfulMaximumHit;
        }

        // refund excess eth
        if (msg.value > ethToUse) {
            // send eth to recipient
            (bool refundSent,) = payable(msg.sender).call{value: msg.value - ethToUse}("");
            if (!refundSent) revert EthTransferFailed();
        }

        emit PresaleBuy(presaleId, msg.sender, ethToUse, presale.ethRaised);
    }

    /// @notice Withdraws the caller's ETH contribution from an Active or Failed presale.
    /// @dev Reverts once the presale has succeeded (SuccessfulMinimumHit, SuccessfulMaximumHit, Claimable).
    /// @param presaleId The presale to withdraw from.
    /// @param amount ETH amount to withdraw (must not exceed caller's contribution).
    /// @param recipient Address to receive the ETH.
    function withdrawFromPresale(uint256 presaleId, uint256 amount, address recipient)
        external
        presaleExists(presaleId)
        updatePresaleState(presaleId)
        nonReentrant
    {
        Presale storage presale = presaleState[presaleId];

        // ensure presale is ongoing or failed
        if (presale.status != PresaleStatus.Failed && presale.status != PresaleStatus.Active) {
            revert PresaleSuccessful();
        }

        // ensure user has a balance in the presale
        if (presaleBuys[presaleId][msg.sender] < amount) revert InsufficientBalance();

        // update user's balance
        presaleBuys[presaleId][msg.sender] -= amount;

        // update eth raised
        presale.ethRaised -= amount;

        // send eth to recipient
        (bool sent,) = payable(recipient).call{value: amount}("");
        if (!sent) revert EthTransferFailed();

        emit WithdrawFromPresale(presaleId, msg.sender, amount, presale.ethRaised);
    }

    /// @notice Claims vested tokens proportional to the caller's ETH contribution.
    /// @dev Only callable once the presale is Claimable and the lockup has passed. Uses linear vesting
    ///      between lockupEndTime and vestingEndTime; full allocation claimable after vestingEndTime.
    /// @param presaleId The presale to claim from.
    function claimTokens(uint256 presaleId) external presaleExists(presaleId) {
        Presale storage presale = presaleState[presaleId];

        // ensure presale is claimable
        if (presale.status != PresaleStatus.Claimable) revert PresaleNotClaimable();

        // ensure lockup period has passed
        if (block.timestamp < presale.lockupEndTime) revert PresaleLockupNotPassed();

        // determine amount of tokens to send to user
        uint256 ethBuyInAmount = _getAmountClaimable(
            presaleId,
            msg.sender,
            presale.lockupEndTime,
            presale.vestingEndTime,
            presale.vestingDuration
        );

        // update user's claimed amount
        presaleClaimed[presaleId][msg.sender] += ethBuyInAmount;

        // determine token amount to send to user
        uint256 tokenAmount = presale.tokenSupply * ethBuyInAmount / presale.ethRaised;
        if (tokenAmount == 0) revert NoTokensToClaim();

        // send tokens to user
        SafeERC20.safeTransfer(IERC20(presale.deployedToken), msg.sender, tokenAmount);

        emit ClaimTokens(presaleId, msg.sender, tokenAmount);
    }

    /// @notice Returns how many tokens `user` can currently claim from the presale.
    /// @param presaleId The presale to query.
    /// @param user The contributor address.
    /// @return Token amount currently claimable by `user`.
    function amountAvailableToClaim(uint256 presaleId, address user)
        external
        view
        presaleExists(presaleId)
        returns (uint256)
    {
        Presale memory presale = presaleState[presaleId];

        if (presale.status != PresaleStatus.Claimable) return 0;
        if (block.timestamp < presale.lockupEndTime) return 0;

        uint256 ethBuyInAmount = _getAmountClaimable(
            presaleId, user, presale.lockupEndTime, presale.vestingEndTime, presale.vestingDuration
        );
        return presale.tokenSupply * ethBuyInAmount / presale.ethRaised;
    }

    /// @dev Computes the unclaimed ETH contribution amount that has vested for `user`.
    function _getAmountClaimable(
        uint256 presaleId,
        address user,
        uint256 lockupEndTime,
        uint256 vestingEndTime,
        uint256 vestingDuration
    ) internal view returns (uint256) {
        // determine amount of vested ETH contribution for user
        uint256 ethBuyInAmount;
        if (block.timestamp >= vestingEndTime) {
            // if vesting period has passed, claim rest of contribution
            ethBuyInAmount = presaleBuys[presaleId][user] - presaleClaimed[presaleId][user];
        } else {
            // if vesting period has not passed, claim vested contribution minus what
            // has already been claimed
            ethBuyInAmount =
                presaleBuys[presaleId][user] * (block.timestamp - lockupEndTime) / vestingDuration;
            ethBuyInAmount = ethBuyInAmount - presaleClaimed[presaleId][user];
        }

        return ethBuyInAmount;
    }

    /// @notice Sends raised ETH (minus the Bonker fee) to the presale owner.
    /// @dev Callable by the presale owner or the contract owner. When the contract owner calls,
    ///      `recipient` must equal the presale's `presaleOwner`. Can only be called once per presale.
    ///      Presale must be in Claimable state.
    /// @param presaleId The presale whose ETH is being claimed.
    /// @param recipient Destination for the ETH; must be `presaleOwner` if called by contract owner.
    function claimEth(uint256 presaleId, address recipient) external presaleExists(presaleId) {
        Presale storage presale = presaleState[presaleId];

        // if not presale owner or owner, revert
        if (msg.sender != presale.presaleOwner && msg.sender != owner()) revert Unauthorized();

        // if owner, the raised ETH recipient must be the presale owner
        if (msg.sender == owner() && recipient != presale.presaleOwner) {
            revert RecipientMustBePresaleOwner();
        }

        // if eth has already been claimed, revert
        if (presale.ethClaimed) revert PresaleAlreadyClaimed();
        presale.ethClaimed = true;

        // ensure presale is claimable
        if (presale.status != PresaleStatus.Claimable) revert PresaleNotClaimable();

        // determine fee
        uint256 fee = (presale.ethRaised * presale.bonkerFee) / BPS;
        uint256 amountAfterFee = presale.ethRaised - fee;

        // send eth to user's recipient
        (bool recipientPaid,) = payable(recipient).call{value: amountAfterFee}("");
        if (!recipientPaid) revert EthTransferFailed();

        // send eth to bonker
        if (fee > 0) {
            (bool feePaid,) = payable(bonkerFeeRecipient).call{value: fee}("");
            if (!feePaid) revert EthTransferFailed();
        }

        emit ClaimEth(presaleId, recipient, amountAfterFee, fee);
    }

    /// @notice Called by the factory to deliver the deployed token supply to the presale contract.
    /// @dev Only callable by the factory as part of the `deployToken` flow. Requires
    ///      `presale.deploymentExpected == true` (set by `endPresale`). Moves the presale to Claimable.
    /// @param deploymentConfig The deployment config; `extensionData` at `extensionIndex` encodes the presale ID.
    /// @param token The deployed ERC20 token address.
    /// @param extensionSupply Token amount allocated to this presale.
    /// @param extensionIndex Index of this extension in `deploymentConfig.extensionConfigs`.
    function receiveTokens(
        IBonker.DeploymentConfig calldata deploymentConfig,
        PoolKey memory,
        address token,
        uint256 extensionSupply,
        uint256 extensionIndex
    ) external payable nonReentrant onlyFactory {
        uint256 presaleId = abi.decode(
            deploymentConfig.extensionConfigs[extensionIndex].extensionData, (uint256)
        );
        Presale storage presale = presaleState[presaleId];

        // ensure that the msgValue is zero
        if (deploymentConfig.extensionConfigs[extensionIndex].msgValue != 0 || msg.value != 0) {
            revert IBonkerExtension.InvalidMsgValue();
        }

        // ensure token deployment is ongoing
        if (!presale.deploymentExpected) revert NotExpectingTokenDeployment();
        presale.deploymentExpected = false;

        // pull in token supply
        SafeERC20.safeTransferFrom(IERC20(token), msg.sender, address(this), extensionSupply);

        // update deployed token
        presale.deployedToken = token;

        // record token supply
        presale.tokenSupply = extensionSupply;

        // update presale state to claimable
        presale.status = PresaleStatus.Claimable;
    }

    /// @notice Returns true for the IBonkerExtension interface ID.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IBonkerExtension).interfaceId;
    }
}
