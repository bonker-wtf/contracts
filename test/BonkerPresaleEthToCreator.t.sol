// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Test} from "forge-std/Test.sol";

import {BonkerPresaleEthToCreator} from "../src/extensions/BonkerPresaleEthToCreator.sol";
import {
    IBonkerPresaleEthToCreator
} from "../src/extensions/interfaces/IBonkerPresaleEthToCreator.sol";
import {IBonker} from "../src/interfaces/IBonker.sol";

contract MockPresaleToken is ERC20 {
    constructor() ERC20("Mock Presale Token", "MPT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockPresaleTokenNoReturn {
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

contract MockPresaleFactory {
    BonkerPresaleEthToCreator internal presale;
    MockPresaleToken internal token;
    uint256 internal immutable extensionSupply;

    constructor(uint256 extensionSupply_) {
        extensionSupply = extensionSupply_;
        token = new MockPresaleToken();
    }

    function setPresale(BonkerPresaleEthToCreator presale_) external {
        presale = presale_;
    }

    function deployToken(IBonker.DeploymentConfig memory deploymentConfig)
        external
        payable
        returns (address tokenAddress)
    {
        tokenAddress = address(token);
        token.mint(address(this), extensionSupply);
        token.approve(address(presale), extensionSupply);
        presale.receiveTokens(
            deploymentConfig,
            emptyPoolKey(),
            tokenAddress,
            extensionSupply,
            deploymentConfig.extensionConfigs.length - 1
        );
    }
}

contract MockPresaleFactoryNoReturn {
    BonkerPresaleEthToCreator internal presale;
    MockPresaleTokenNoReturn internal token;
    uint256 internal immutable extensionSupply;

    constructor(uint256 extensionSupply_) {
        extensionSupply = extensionSupply_;
        token = new MockPresaleTokenNoReturn();
    }

    function setPresale(BonkerPresaleEthToCreator presale_) external {
        presale = presale_;
    }

    function deployToken(IBonker.DeploymentConfig memory deploymentConfig)
        external
        payable
        returns (address tokenAddress)
    {
        tokenAddress = address(token);
        token.mint(address(this), extensionSupply);
        token.approve(address(presale), extensionSupply);
        presale.receiveTokens(
            deploymentConfig,
            emptyPoolKey(),
            tokenAddress,
            extensionSupply,
            deploymentConfig.extensionConfigs.length - 1
        );
    }
}

contract BonkerPresaleEthToCreatorTest is Test {
    address internal constant ADMIN = address(0xA11CE);
    address internal constant PRESALE_OWNER = address(0xB0B);
    address internal constant BUYER_ONE = address(0xB01);
    address internal constant BUYER_TWO = address(0xB02);
    address internal constant BONKER_FEE_RECIPIENT = address(0xFEE);

    uint256 internal constant MIN_ETH_GOAL = 1 ether;
    uint256 internal constant MAX_ETH_GOAL = 3 ether;
    uint256 internal constant BUYER_ONE_CONTRIBUTION = 2 ether;
    uint256 internal constant BUYER_TWO_CONTRIBUTION = 1 ether;
    uint256 internal constant LOCKUP_DURATION = 7 days;
    uint256 internal constant VESTING_DURATION = 10 days;
    uint256 internal constant TOKEN_SUPPLY = 900 ether;
    uint256 internal constant BONKER_FEE_BPS = 500;

    BonkerPresaleEthToCreator internal presale;
    MockPresaleFactory internal factory;
    MockPresaleToken internal token;
    uint256 internal presaleId;
    uint256 internal deploymentTime;

    function setUp() public {
        factory = new MockPresaleFactory(TOKEN_SUPPLY);
        presale =
            new BonkerPresaleEthToCreator(address(this), address(factory), BONKER_FEE_RECIPIENT);
        factory.setPresale(presale);

        presale.setAdmin(ADMIN, true);

        vm.deal(BUYER_ONE, BUYER_ONE_CONTRIBUTION);
        vm.deal(BUYER_TWO, BUYER_TWO_CONTRIBUTION);

        vm.prank(ADMIN);
        presaleId = presale.startPresale(
            _deploymentConfig(),
            MIN_ETH_GOAL,
            MAX_ETH_GOAL,
            14 days,
            PRESALE_OWNER,
            LOCKUP_DURATION,
            VESTING_DURATION,
            address(0),
            ""
        );

        vm.prank(BUYER_ONE);
        presale.buyIntoPresale{value: BUYER_ONE_CONTRIBUTION}(presaleId);

        vm.prank(BUYER_TWO);
        presale.buyIntoPresale{value: BUYER_TWO_CONTRIBUTION}(presaleId);

        deploymentTime = block.timestamp;

        vm.prank(PRESALE_OWNER);
        presale.endPresale(presaleId, bytes32("presale-salt"));

        IBonkerPresaleEthToCreator.Presale memory state = presale.getPresale(presaleId);
        token = MockPresaleToken(state.deployedToken);

        assertEq(uint256(state.status), uint256(IBonkerPresaleEthToCreator.PresaleStatus.Claimable));
        assertEq(state.ethRaised, MAX_ETH_GOAL);
        assertEq(state.tokenSupply, TOKEN_SUPPLY);
        assertEq(state.bonkerFee, BONKER_FEE_BPS);
    }

    function testAmountAvailableAndClaimsTrackVestingPerBuyer() public {
        vm.warp(deploymentTime + LOCKUP_DURATION - 1);
        assertEq(presale.amountAvailableToClaim(presaleId, BUYER_ONE), 0);
        assertEq(presale.amountAvailableToClaim(presaleId, BUYER_TWO), 0);

        vm.warp(deploymentTime + LOCKUP_DURATION);
        assertEq(presale.amountAvailableToClaim(presaleId, BUYER_ONE), 0);
        assertEq(presale.amountAvailableToClaim(presaleId, BUYER_TWO), 0);

        vm.warp(deploymentTime + LOCKUP_DURATION + 4 days);
        assertEq(presale.amountAvailableToClaim(presaleId, BUYER_ONE), 240 ether);
        assertEq(presale.amountAvailableToClaim(presaleId, BUYER_TWO), 120 ether);

        vm.prank(BUYER_ONE);
        presale.claimTokens(presaleId);
        vm.prank(BUYER_TWO);
        presale.claimTokens(presaleId);

        assertEq(token.balanceOf(BUYER_ONE), 240 ether);
        assertEq(token.balanceOf(BUYER_TWO), 120 ether);
        assertEq(presale.amountAvailableToClaim(presaleId, BUYER_ONE), 0);
        assertEq(presale.amountAvailableToClaim(presaleId, BUYER_TWO), 0);

        vm.warp(deploymentTime + LOCKUP_DURATION + VESTING_DURATION);
        assertEq(presale.amountAvailableToClaim(presaleId, BUYER_ONE), 360 ether);
        assertEq(presale.amountAvailableToClaim(presaleId, BUYER_TWO), 180 ether);

        vm.prank(BUYER_ONE);
        presale.claimTokens(presaleId);
        vm.prank(BUYER_TWO);
        presale.claimTokens(presaleId);

        assertEq(token.balanceOf(BUYER_ONE), 600 ether);
        assertEq(token.balanceOf(BUYER_TWO), 300 ether);
        assertEq(token.balanceOf(address(presale)), 0);
        assertEq(presale.amountAvailableToClaim(presaleId, BUYER_ONE), 0);
        assertEq(presale.amountAvailableToClaim(presaleId, BUYER_TWO), 0);
    }

    function testClaimEthSendsCreatorShareAndBonkerFee() public {
        uint256 ownerBalanceBefore = PRESALE_OWNER.balance;
        uint256 bonkerBalanceBefore = BONKER_FEE_RECIPIENT.balance;
        uint256 expectedFee = (MAX_ETH_GOAL * BONKER_FEE_BPS) / 10_000;
        uint256 expectedOwnerAmount = MAX_ETH_GOAL - expectedFee;

        vm.prank(PRESALE_OWNER);
        presale.claimEth(presaleId, PRESALE_OWNER);

        assertEq(PRESALE_OWNER.balance - ownerBalanceBefore, expectedOwnerAmount);
        assertEq(BONKER_FEE_RECIPIENT.balance - bonkerBalanceBefore, expectedFee);

        vm.expectRevert(IBonkerPresaleEthToCreator.PresaleAlreadyClaimed.selector);
        vm.prank(PRESALE_OWNER);
        presale.claimEth(presaleId, PRESALE_OWNER);
    }

    function testNonStandardTokenWithoutBooleanReturnStillBecomesClaimable() public {
        MockPresaleFactoryNoReturn nonStandardFactory = new MockPresaleFactoryNoReturn(TOKEN_SUPPLY);
        BonkerPresaleEthToCreator nonStandardPresale = new BonkerPresaleEthToCreator(
            address(this), address(nonStandardFactory), BONKER_FEE_RECIPIENT
        );
        nonStandardFactory.setPresale(nonStandardPresale);
        nonStandardPresale.setAdmin(ADMIN, true);

        vm.deal(BUYER_ONE, BUYER_ONE_CONTRIBUTION);
        vm.deal(BUYER_TWO, BUYER_TWO_CONTRIBUTION);

        vm.prank(ADMIN);
        uint256 nonStandardPresaleId = nonStandardPresale.startPresale(
            _deploymentConfigFor(address(nonStandardPresale)),
            MIN_ETH_GOAL,
            MAX_ETH_GOAL,
            14 days,
            PRESALE_OWNER,
            LOCKUP_DURATION,
            VESTING_DURATION,
            address(0),
            ""
        );

        vm.prank(BUYER_ONE);
        nonStandardPresale.buyIntoPresale{value: BUYER_ONE_CONTRIBUTION}(nonStandardPresaleId);

        vm.prank(BUYER_TWO);
        nonStandardPresale.buyIntoPresale{value: BUYER_TWO_CONTRIBUTION}(nonStandardPresaleId);

        uint256 nonStandardDeploymentTime = block.timestamp;

        vm.prank(PRESALE_OWNER);
        nonStandardPresale.endPresale(nonStandardPresaleId, bytes32("no-return-salt"));

        IBonkerPresaleEthToCreator.Presale memory state =
            nonStandardPresale.getPresale(nonStandardPresaleId);
        MockPresaleTokenNoReturn nonStandardToken = MockPresaleTokenNoReturn(state.deployedToken);

        vm.warp(nonStandardDeploymentTime + LOCKUP_DURATION + VESTING_DURATION);

        vm.prank(BUYER_ONE);
        nonStandardPresale.claimTokens(nonStandardPresaleId);
        vm.prank(BUYER_TWO);
        nonStandardPresale.claimTokens(nonStandardPresaleId);

        assertEq(nonStandardToken.balanceOf(BUYER_ONE), 600 ether);
        assertEq(nonStandardToken.balanceOf(BUYER_TWO), 300 ether);
        assertEq(nonStandardToken.balanceOf(address(nonStandardPresale)), 0);
    }

    function _deploymentConfig() internal view returns (IBonker.DeploymentConfig memory) {
        return _deploymentConfigFor(address(presale));
    }

    function _deploymentConfigFor(address extension)
        internal
        pure
        returns (IBonker.DeploymentConfig memory)
    {
        IBonker.ExtensionConfig[] memory extensionConfigs = new IBonker.ExtensionConfig[](1);
        extensionConfigs[0] = IBonker.ExtensionConfig({
            extension: extension, msgValue: 0, extensionBps: 1000, extensionData: ""
        });

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
    }
}
