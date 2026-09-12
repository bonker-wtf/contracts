// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Test} from "forge-std/Test.sol";

import {BonkerAirdrop} from "../src/extensions/BonkerAirdrop.sol";
import {BonkerUniv3EthDevBuy} from "../src/extensions/BonkerUniv3EthDevBuy.sol";
import {BonkerUniv4EthDevBuy} from "../src/extensions/BonkerUniv4EthDevBuy.sol";
import {IBonkerAirdrop} from "../src/extensions/interfaces/IBonkerAirdrop.sol";
import {IBonkerUniv3EthDevBuy} from "../src/extensions/interfaces/IBonkerUniv3EthDevBuy.sol";
import {IBonkerUniv4EthDevBuy} from "../src/extensions/interfaces/IBonkerUniv4EthDevBuy.sol";
import {IBonker} from "../src/interfaces/IBonker.sol";
import {BonkerLpLockerFeeConversion} from "../src/lp-lockers/BonkerLpLockerFeeConversion.sol";
import {BonkerLpLockerMultiple} from "../src/lp-lockers/BonkerLpLockerMultiple.sol";
import {
    IBonkerLpLockerFeeConversion
} from "../src/lp-lockers/interfaces/IBonkerLpLockerFeeConversion.sol";

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

contract MockWethNoReturn is MockTokenNoReturn {
    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }
}

contract MockPermit2 {
    address public lastToken;
    address public lastSpender;
    uint160 public lastAmount;
    uint48 public lastExpiration;

    function approve(address token, address spender, uint160 amount, uint48 expiration) external {
        lastToken = token;
        lastSpender = spender;
        lastAmount = amount;
        lastExpiration = expiration;
    }
}

contract MockUniversalRouter {
    address public tokenToMint;
    uint256 public amountToMint;

    function setMint(address tokenToMint_, uint256 amountToMint_) external {
        tokenToMint = tokenToMint_;
        amountToMint = amountToMint_;
    }

    function execute(bytes calldata, bytes[] calldata, uint256) external payable {
        MockTokenNoReturn(tokenToMint).mint(msg.sender, amountToMint);
    }
}

contract MockPositionManager {
    uint256 public nextTokenId = 1;

    function modifyLiquidities(bytes calldata, uint256) external payable {}
}

contract MockFeeLocker {}

function emptyPoolKey() pure returns (PoolKey memory) {
    return PoolKey({
        currency0: Currency.wrap(address(0)),
        currency1: Currency.wrap(address(0)),
        fee: 0,
        tickSpacing: 0,
        hooks: IHooks(address(0))
    });
}

function poolKeyFor(address currency0, address currency1) pure returns (PoolKey memory) {
    return PoolKey({
        currency0: Currency.wrap(currency0),
        currency1: Currency.wrap(currency1),
        fee: 0,
        tickSpacing: 200,
        hooks: IHooks(address(0))
    });
}

contract BonkerAirdropLegacyErc20SafetyTest is Test {
    address internal constant FACTORY = address(0xFAc7);
    address internal constant RECIPIENT = address(0xA11CE);
    uint256 internal constant LOCKUP_DURATION = 1 days;
    uint256 internal constant VESTING_DURATION = 8 days;
    uint256 internal constant ALLOCATION = 400 ether;

    function testNonStandardTokenWithoutBooleanReturnStillDepositsAndClaims() public {
        BonkerAirdrop airdrop = new BonkerAirdrop(FACTORY);
        MockTokenNoReturn token = new MockTokenNoReturn();
        bytes32 merkleRoot = keccak256(bytes.concat(keccak256(abi.encode(RECIPIENT, ALLOCATION))));

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

        IBonker.DeploymentConfig memory deploymentConfig =
            _deploymentConfig(extensionConfigs, address(0), address(0), "");

        token.mint(FACTORY, ALLOCATION);

        vm.startPrank(FACTORY);
        token.approve(address(airdrop), ALLOCATION);
        airdrop.receiveTokens(deploymentConfig, emptyPoolKey(), address(token), ALLOCATION, 0);
        vm.stopPrank();

        vm.warp(block.timestamp + LOCKUP_DURATION + VESTING_DURATION);
        airdrop.claim(address(token), RECIPIENT, ALLOCATION, new bytes32[](0));

        assertEq(token.balanceOf(RECIPIENT), ALLOCATION);
        assertEq(token.balanceOf(address(airdrop)), 0);
    }

    function _deploymentConfig(
        IBonker.ExtensionConfig[] memory extensionConfigs,
        address pairedToken,
        address locker,
        bytes memory lockerData
    ) internal pure returns (IBonker.DeploymentConfig memory) {
        return IBonker.DeploymentConfig({
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
                pairedToken: pairedToken,
                tickIfToken0IsBonker: 0,
                tickSpacing: 200,
                poolData: ""
            }),
            lockerConfig: IBonker.LockerConfig({
                locker: locker,
                rewardAdmins: new address[](0),
                rewardRecipients: new address[](0),
                rewardBps: new uint16[](0),
                tickLower: new int24[](0),
                tickUpper: new int24[](0),
                positionBps: new uint16[](0),
                lockerData: lockerData
            }),
            mevModuleConfig: IBonker.MevModuleConfig({mevModule: address(0), mevModuleData: ""}),
            extensionConfigs: extensionConfigs
        });
    }
}

contract BonkerDevBuyLegacyErc20SafetyTest is Test {
    address internal constant FACTORY = address(0xFAc7);
    address internal constant RECIPIENT = address(0xA11CE);
    uint256 internal constant ETH_AMOUNT = 1 ether;
    uint256 internal constant TOKEN_AMOUNT = 123 ether;

    function testUniv3DevBuyStillPaysRecipientWithNonStandardToken() public {
        MockWethNoReturn weth = new MockWethNoReturn();
        MockTokenNoReturn token = new MockTokenNoReturn();
        MockPermit2 permit2 = new MockPermit2();
        MockUniversalRouter universalRouter = new MockUniversalRouter();
        universalRouter.setMint(address(token), TOKEN_AMOUNT);

        BonkerUniv3EthDevBuy extension = new BonkerUniv3EthDevBuy(
            FACTORY, address(weth), address(universalRouter), address(permit2), address(0), false
        );

        IBonker.ExtensionConfig[] memory extensionConfigs = new IBonker.ExtensionConfig[](1);
        extensionConfigs[0] = IBonker.ExtensionConfig({
            extension: address(extension),
            msgValue: ETH_AMOUNT,
            extensionBps: 0,
            extensionData: abi.encode(
                IBonkerUniv3EthDevBuy.Univ3EthDevBuyExtensionData({
                    uniV3Fee: 0, pairedTokenAmountOutMinimum: 0, recipient: RECIPIENT
                })
            )
        });

        IBonker.DeploymentConfig memory deploymentConfig =
            _deploymentConfig(extensionConfigs, address(weth));

        vm.deal(FACTORY, ETH_AMOUNT);
        vm.prank(FACTORY);
        extension.receiveTokens{value: ETH_AMOUNT}(
            deploymentConfig, poolKeyFor(address(weth), address(token)), address(token), 0, 0
        );

        assertEq(token.balanceOf(RECIPIENT), TOKEN_AMOUNT);
        assertEq(token.balanceOf(address(extension)), 0);
        assertEq(permit2.lastToken(), address(weth));
        assertEq(uint256(permit2.lastAmount()), ETH_AMOUNT);
    }

    function testUniv4DevBuyStillPaysRecipientWithNonStandardToken() public {
        MockWethNoReturn weth = new MockWethNoReturn();
        MockTokenNoReturn token = new MockTokenNoReturn();
        MockPermit2 permit2 = new MockPermit2();
        MockUniversalRouter universalRouter = new MockUniversalRouter();
        universalRouter.setMint(address(token), TOKEN_AMOUNT);

        BonkerUniv4EthDevBuy extension = new BonkerUniv4EthDevBuy(
            FACTORY, address(weth), address(universalRouter), address(permit2), false
        );

        IBonker.ExtensionConfig[] memory extensionConfigs = new IBonker.ExtensionConfig[](1);
        extensionConfigs[0] = IBonker.ExtensionConfig({
            extension: address(extension),
            msgValue: ETH_AMOUNT,
            extensionBps: 0,
            extensionData: abi.encode(
                IBonkerUniv4EthDevBuy.Univ4EthDevBuyExtensionData({
                    pairedTokenPoolKey: emptyPoolKey(),
                    pairedTokenAmountOutMinimum: 0,
                    recipient: RECIPIENT
                })
            )
        });

        IBonker.DeploymentConfig memory deploymentConfig =
            _deploymentConfig(extensionConfigs, address(weth));

        vm.deal(FACTORY, ETH_AMOUNT);
        vm.prank(FACTORY);
        extension.receiveTokens{value: ETH_AMOUNT}(
            deploymentConfig, poolKeyFor(address(weth), address(token)), address(token), 0, 0
        );

        assertEq(token.balanceOf(RECIPIENT), TOKEN_AMOUNT);
        assertEq(token.balanceOf(address(extension)), 0);
        assertEq(permit2.lastToken(), address(weth));
        assertEq(uint256(permit2.lastAmount()), ETH_AMOUNT);
    }

    function _deploymentConfig(
        IBonker.ExtensionConfig[] memory extensionConfigs,
        address pairedToken
    ) internal pure returns (IBonker.DeploymentConfig memory) {
        return IBonker.DeploymentConfig({
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
                pairedToken: pairedToken,
                tickIfToken0IsBonker: 0,
                tickSpacing: 200,
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
    }
}

contract BonkerLockerLegacyErc20SafetyTest is Test {
    address internal constant FACTORY = address(0xFAc7);
    address internal constant ADMIN = address(0xA11CE);
    address internal constant RECIPIENT = address(0xB0B);
    address internal constant PAIRED_TOKEN = address(0xFFFF);
    uint256 internal constant POOL_SUPPLY = 1000 ether;

    function testMultipleLockerStillPullsNonStandardToken() public {
        MockTokenNoReturn token = new MockTokenNoReturn();
        MockPositionManager positionManager = new MockPositionManager();
        MockPermit2 permit2 = new MockPermit2();
        BonkerLpLockerMultiple locker = new BonkerLpLockerMultiple(
            address(this),
            FACTORY,
            address(new MockFeeLocker()),
            address(positionManager),
            address(permit2)
        );

        token.mint(FACTORY, POOL_SUPPLY);

        vm.startPrank(FACTORY);
        token.approve(address(locker), POOL_SUPPLY);
        uint256 positionId = locker.placeLiquidity(
            _lockerConfig(""),
            _poolConfig(),
            poolKeyFor(address(token), PAIRED_TOKEN),
            POOL_SUPPLY,
            address(token)
        );
        vm.stopPrank();

        assertEq(positionId, 1);
        assertEq(token.balanceOf(address(locker)), POOL_SUPPLY);
        assertEq(uint256(permit2.lastAmount()), POOL_SUPPLY);
    }

    function testFeeConversionLockerStillPullsNonStandardToken() public {
        MockTokenNoReturn token = new MockTokenNoReturn();
        MockPositionManager positionManager = new MockPositionManager();
        MockPermit2 permit2 = new MockPermit2();
        BonkerLpLockerFeeConversion locker = new BonkerLpLockerFeeConversion(
            address(this),
            FACTORY,
            address(new MockFeeLocker()),
            address(positionManager),
            address(permit2),
            address(0),
            address(0),
            false
        );

        IBonkerLpLockerFeeConversion.FeeIn[] memory feePreference =
            new IBonkerLpLockerFeeConversion.FeeIn[](1);
        feePreference[0] = IBonkerLpLockerFeeConversion.FeeIn.Both;
        bytes memory lockerData = abi.encode(
            IBonkerLpLockerFeeConversion.LpFeeConversionInfo({feePreference: feePreference})
        );

        token.mint(FACTORY, POOL_SUPPLY);

        vm.startPrank(FACTORY);
        token.approve(address(locker), POOL_SUPPLY);
        uint256 positionId = locker.placeLiquidity(
            _lockerConfig(lockerData),
            _poolConfig(),
            poolKeyFor(address(token), PAIRED_TOKEN),
            POOL_SUPPLY,
            address(token)
        );
        vm.stopPrank();

        assertEq(positionId, 1);
        assertEq(token.balanceOf(address(locker)), POOL_SUPPLY);
        assertEq(uint256(permit2.lastAmount()), POOL_SUPPLY);
        assertEq(uint8(locker.feePreferences(address(token), 0)), uint8(feePreference[0]));
    }

    function _poolConfig() internal pure returns (IBonker.PoolConfig memory) {
        return IBonker.PoolConfig({
            hook: address(0),
            pairedToken: PAIRED_TOKEN,
            tickIfToken0IsBonker: 0,
            tickSpacing: 200,
            poolData: ""
        });
    }

    function _lockerConfig(bytes memory lockerData)
        internal
        pure
        returns (IBonker.LockerConfig memory)
    {
        address[] memory rewardAdmins = new address[](1);
        rewardAdmins[0] = ADMIN;
        address[] memory rewardRecipients = new address[](1);
        rewardRecipients[0] = RECIPIENT;
        uint16[] memory rewardBps = new uint16[](1);
        rewardBps[0] = 10_000;
        int24[] memory tickLower = new int24[](1);
        tickLower[0] = 0;
        int24[] memory tickUpper = new int24[](1);
        tickUpper[0] = 200;
        uint16[] memory positionBps = new uint16[](1);
        positionBps[0] = 10_000;

        return IBonker.LockerConfig({
            locker: address(0),
            rewardAdmins: rewardAdmins,
            rewardRecipients: rewardRecipients,
            rewardBps: rewardBps,
            tickLower: tickLower,
            tickUpper: tickUpper,
            positionBps: positionBps,
            lockerData: lockerData
        });
    }
}
