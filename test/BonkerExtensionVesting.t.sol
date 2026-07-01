// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Test} from "forge-std/Test.sol";

import {BonkerAirdrop} from "../src/extensions/BonkerAirdrop.sol";
import {BonkerVault} from "../src/extensions/BonkerVault.sol";
import {IBonkerAirdrop} from "../src/extensions/interfaces/IBonkerAirdrop.sol";
import {IBonkerVault} from "../src/extensions/interfaces/IBonkerVault.sol";
import {IBonker} from "../src/interfaces/IBonker.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock Token", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockTokenNoReturn {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external {
        _transfer(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }

        _transfer(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

function emptyPoolKey() pure returns (PoolKey memory) {
    return PoolKey({
        currency0: Currency.wrap(address(0)),
        currency1: Currency.wrap(address(0)),
        fee: 0,
        tickSpacing: 0,
        hooks: IHooks(address(0))
    });
}

contract BonkerVaultVestingTest is Test {
    address internal constant FACTORY = address(0xFAc7);
    address internal constant ADMIN = address(0xA11CE);
    uint256 internal constant LOCKUP_DURATION = 7 days;
    uint256 internal constant VESTING_DURATION = 10 days;
    uint256 internal constant EXTENSION_SUPPLY = 1000 ether;

    BonkerVault internal vault;
    MockToken internal token;
    uint256 internal startTime;

    function setUp() public {
        vault = new BonkerVault(FACTORY);
        token = new MockToken();
        startTime = block.timestamp;

        IBonker.ExtensionConfig[] memory extensionConfigs = new IBonker.ExtensionConfig[](1);
        extensionConfigs[0] = IBonker.ExtensionConfig({
            extension: address(vault),
            msgValue: 0,
            extensionBps: 1000,
            extensionData: abi.encode(
                IBonkerVault.VaultExtensionData({
                    admin: ADMIN, lockupDuration: LOCKUP_DURATION, vestingDuration: VESTING_DURATION
                })
            )
        });

        IBonker.DeploymentConfig memory deploymentConfig = IBonker.DeploymentConfig({
            tokenConfig: IBonker.TokenConfig({
                tokenAdmin: address(0),
                name: "",
                symbol: "",
                salt: bytes32(0),
                image: "",
                metadata: "",
                context: "",
                originatingChainId: 0
            }),
            poolConfig: IBonker.PoolConfig({
                hook: address(0),
                pairedToken: address(0),
                tickIfToken0IsBonker: 0,
                tickSpacing: 0,
                poolData: ""
            }),
            lockerConfig: IBonker.LockerConfig({
                locker: address(0),
                rewardAdmins: new address[](0),
                rewardRecipients: new address[](0),
                rewardBps: new uint16[](0),
                tickLower: new int24[](0),
                tickUpper: new int24[](0),
                positionBps: new uint16[](0),
                lockerData: ""
            }),
            mevModuleConfig: IBonker.MevModuleConfig({mevModule: address(0), mevModuleData: ""}),
            extensionConfigs: extensionConfigs
        });

        token.mint(FACTORY, EXTENSION_SUPPLY);

        vm.startPrank(FACTORY);
        token.approve(address(vault), EXTENSION_SUPPLY);
        vault.receiveTokens(deploymentConfig, emptyPoolKey(), address(token), EXTENSION_SUPPLY, 0);
        vm.stopPrank();
    }

    function testAmountAvailableToClaimTracksLinearVesting() public {
        vm.warp(startTime + LOCKUP_DURATION - 1);
        assertEq(vault.amountAvailableToClaim(address(token)), 0);

        vm.warp(startTime + LOCKUP_DURATION);
        assertEq(vault.amountAvailableToClaim(address(token)), 0);

        vm.warp(startTime + LOCKUP_DURATION + (VESTING_DURATION / 2));
        assertEq(vault.amountAvailableToClaim(address(token)), EXTENSION_SUPPLY / 2);

        vault.claim(address(token));
        assertEq(token.balanceOf(ADMIN), EXTENSION_SUPPLY / 2);

        vm.warp(startTime + LOCKUP_DURATION + VESTING_DURATION);
        assertEq(vault.amountAvailableToClaim(address(token)), EXTENSION_SUPPLY / 2);

        vault.claim(address(token));
        assertEq(token.balanceOf(ADMIN), EXTENSION_SUPPLY);
        assertEq(vault.amountAvailableToClaim(address(token)), 0);
    }

    function testNonStandardTokenWithoutBooleanReturnStillDepositsAndClaims() public {
        MockTokenNoReturn nonStandardToken = new MockTokenNoReturn();
        BonkerVault nonStandardVault = new BonkerVault(FACTORY);

        IBonker.ExtensionConfig[] memory extensionConfigs = new IBonker.ExtensionConfig[](1);
        extensionConfigs[0] = IBonker.ExtensionConfig({
            extension: address(nonStandardVault),
            msgValue: 0,
            extensionBps: 1000,
            extensionData: abi.encode(
                IBonkerVault.VaultExtensionData({
                    admin: ADMIN, lockupDuration: LOCKUP_DURATION, vestingDuration: VESTING_DURATION
                })
            )
        });

        IBonker.DeploymentConfig memory deploymentConfig = IBonker.DeploymentConfig({
            tokenConfig: IBonker.TokenConfig({
                tokenAdmin: address(0),
                name: "",
                symbol: "",
                salt: bytes32(0),
                image: "",
                metadata: "",
                context: "",
                originatingChainId: 0
            }),
            poolConfig: IBonker.PoolConfig({
                hook: address(0),
                pairedToken: address(0),
                tickIfToken0IsBonker: 0,
                tickSpacing: 0,
                poolData: ""
            }),
            lockerConfig: IBonker.LockerConfig({
                locker: address(0),
                rewardAdmins: new address[](0),
                rewardRecipients: new address[](0),
                rewardBps: new uint16[](0),
                tickLower: new int24[](0),
                tickUpper: new int24[](0),
                positionBps: new uint16[](0),
                lockerData: ""
            }),
            mevModuleConfig: IBonker.MevModuleConfig({mevModule: address(0), mevModuleData: ""}),
            extensionConfigs: extensionConfigs
        });

        nonStandardToken.mint(FACTORY, EXTENSION_SUPPLY);

        vm.startPrank(FACTORY);
        nonStandardToken.approve(address(nonStandardVault), EXTENSION_SUPPLY);
        nonStandardVault.receiveTokens(
            deploymentConfig, emptyPoolKey(), address(nonStandardToken), EXTENSION_SUPPLY, 0
        );
        vm.stopPrank();

        vm.warp(block.timestamp + LOCKUP_DURATION + VESTING_DURATION);
        nonStandardVault.claim(address(nonStandardToken));

        assertEq(nonStandardToken.balanceOf(ADMIN), EXTENSION_SUPPLY);
        assertEq(nonStandardToken.balanceOf(address(nonStandardVault)), 0);
    }
}

contract BonkerAirdropVestingTest is Test {
    address internal constant FACTORY = address(0xFAc7);
    address internal constant RECIPIENT = address(0xA11CE);
    uint256 internal constant LOCKUP_DURATION = 1 days;
    uint256 internal constant VESTING_DURATION = 8 days;
    uint256 internal constant ALLOCATION = 400 ether;

    BonkerAirdrop internal airdrop;
    MockToken internal token;
    bytes32 internal merkleRoot;
    uint256 internal startTime;

    function setUp() public {
        airdrop = new BonkerAirdrop(FACTORY);
        token = new MockToken();
        startTime = block.timestamp;

        merkleRoot = keccak256(bytes.concat(keccak256(abi.encode(RECIPIENT, ALLOCATION))));

        IBonker.ExtensionConfig[] memory extensionConfigs = new IBonker.ExtensionConfig[](1);
        extensionConfigs[0] = IBonker.ExtensionConfig({
            extension: address(airdrop),
            msgValue: 0,
            extensionBps: 1000,
            extensionData: abi.encode(
                IBonkerAirdrop.AirdropExtensionData({
                    merkleRoot: merkleRoot,
                    lockupDuration: LOCKUP_DURATION,
                    vestingDuration: VESTING_DURATION
                })
            )
        });

        IBonker.DeploymentConfig memory deploymentConfig = IBonker.DeploymentConfig({
            tokenConfig: IBonker.TokenConfig({
                tokenAdmin: address(0),
                name: "",
                symbol: "",
                salt: bytes32(0),
                image: "",
                metadata: "",
                context: "",
                originatingChainId: 0
            }),
            poolConfig: IBonker.PoolConfig({
                hook: address(0),
                pairedToken: address(0),
                tickIfToken0IsBonker: 0,
                tickSpacing: 0,
                poolData: ""
            }),
            lockerConfig: IBonker.LockerConfig({
                locker: address(0),
                rewardAdmins: new address[](0),
                rewardRecipients: new address[](0),
                rewardBps: new uint16[](0),
                tickLower: new int24[](0),
                tickUpper: new int24[](0),
                positionBps: new uint16[](0),
                lockerData: ""
            }),
            mevModuleConfig: IBonker.MevModuleConfig({mevModule: address(0), mevModuleData: ""}),
            extensionConfigs: extensionConfigs
        });

        token.mint(FACTORY, ALLOCATION);

        vm.startPrank(FACTORY);
        token.approve(address(airdrop), ALLOCATION);
        airdrop.receiveTokens(deploymentConfig, emptyPoolKey(), address(token), ALLOCATION, 0);
        vm.stopPrank();
    }

    function testClaimAndViewStayAlignedAtVestingBoundaries() public {
        bytes32[] memory proof = new bytes32[](0);

        vm.warp(startTime + LOCKUP_DURATION - 1);
        assertEq(airdrop.amountAvailableToClaim(address(token), RECIPIENT, ALLOCATION), 0);

        vm.warp(startTime + LOCKUP_DURATION);
        assertEq(airdrop.amountAvailableToClaim(address(token), RECIPIENT, ALLOCATION), 0);

        vm.warp(startTime + LOCKUP_DURATION + (VESTING_DURATION / 2));
        assertEq(
            airdrop.amountAvailableToClaim(address(token), RECIPIENT, ALLOCATION), ALLOCATION / 2
        );

        airdrop.claim(address(token), RECIPIENT, ALLOCATION, proof);
        assertEq(token.balanceOf(RECIPIENT), ALLOCATION / 2);
        assertEq(airdrop.amountAvailableToClaim(address(token), RECIPIENT, ALLOCATION), 0);

        vm.warp(startTime + LOCKUP_DURATION + VESTING_DURATION);
        assertEq(
            airdrop.amountAvailableToClaim(address(token), RECIPIENT, ALLOCATION), ALLOCATION / 2
        );

        airdrop.claim(address(token), RECIPIENT, ALLOCATION, proof);
        assertEq(token.balanceOf(RECIPIENT), ALLOCATION);
        assertEq(airdrop.amountAvailableToClaim(address(token), RECIPIENT, ALLOCATION), 0);
    }
}
