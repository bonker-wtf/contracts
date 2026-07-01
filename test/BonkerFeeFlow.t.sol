// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Bonker} from "../src/Bonker.sol";
import {BonkerFeeLocker} from "../src/BonkerFeeLocker.sol";
import {IBonker} from "../src/interfaces/IBonker.sol";
import {IBonkerFeeLocker} from "../src/interfaces/IBonkerFeeLocker.sol";
import {IOwnerAdmins} from "../src/interfaces/IOwnerAdmins.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockFeeOnTransferERC20 is ERC20 {
    uint256 internal constant BPS = 10_000;

    uint256 public immutable feeBps;
    address public immutable feeCollector;

    constructor(string memory name_, string memory symbol_, uint256 feeBps_, address feeCollector_)
        ERC20(name_, symbol_)
    {
        feeBps = feeBps_;
        feeCollector = feeCollector_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && feeBps != 0) {
            uint256 fee = value * feeBps / BPS;
            uint256 netAmount = value - fee;

            super._update(from, feeCollector, fee);
            super._update(from, to, netAmount);
            return;
        }

        super._update(from, to, value);
    }
}

contract BonkerClaimTeamFeesTest is Test {
    address internal constant OWNER = address(0xA11CE);
    address internal constant ADMIN = address(0xB0B);
    address internal constant OUTSIDER = address(0xBAD);
    address internal constant TEAM_RECIPIENT = address(0xFEE);

    Bonker internal factory;
    MockERC20 internal token;

    function setUp() public {
        factory = new Bonker(OWNER);
        token = new MockERC20("Mock Token", "MOCK");
    }

    function testClaimTeamFeesRevertsWhenRecipientUnset() public {
        token.mint(address(factory), 12 ether);

        vm.expectRevert(IBonker.TeamFeeRecipientNotSet.selector);
        vm.prank(OWNER);
        factory.claimTeamFees(address(token));
    }

    function testClaimTeamFeesTransfersFullBalanceToTeamRecipient() public {
        uint256 amount = 25 ether;

        vm.prank(OWNER);
        factory.setTeamFeeRecipient(TEAM_RECIPIENT);
        token.mint(address(factory), amount);

        vm.expectEmit();
        emit IBonker.ClaimTeamFees(address(token), TEAM_RECIPIENT, amount);

        vm.prank(OWNER);
        factory.claimTeamFees(address(token));

        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(token.balanceOf(TEAM_RECIPIENT), amount);
    }

    function testAdminCanClaimTeamFees() public {
        uint256 amount = 7 ether;

        vm.startPrank(OWNER);
        factory.setAdmin(ADMIN, true);
        factory.setTeamFeeRecipient(TEAM_RECIPIENT);
        vm.stopPrank();

        token.mint(address(factory), amount);

        vm.prank(ADMIN);
        factory.claimTeamFees(address(token));

        assertEq(token.balanceOf(TEAM_RECIPIENT), amount);
    }

    function testNonAdminCannotClaimTeamFees() public {
        vm.prank(OUTSIDER);
        vm.expectRevert(IOwnerAdmins.Unauthorized.selector);
        factory.claimTeamFees(address(token));
    }
}

contract BonkerFeeLockerClaimTest is Test {
    address internal constant OWNER = address(0xA11CE);
    address internal constant DEPOSITOR = address(0xD37);
    address internal constant FEE_OWNER = address(0xFEE0);
    address internal constant CALLER = address(0xCA11);
    address internal constant FEE_COLLECTOR = address(0xFEE5);

    BonkerFeeLocker internal feeLocker;
    MockERC20 internal plainToken;
    MockFeeOnTransferERC20 internal feeToken;

    function setUp() public {
        feeLocker = new BonkerFeeLocker(OWNER);
        plainToken = new MockERC20("Plain Token", "PLAIN");
        feeToken = new MockFeeOnTransferERC20("Fee Token", "FEE", 500, FEE_COLLECTOR);

        vm.prank(OWNER);
        feeLocker.addDepositor(DEPOSITOR);
    }

    function testStoreFeesRevertsForUnauthorizedDepositor() public {
        vm.expectRevert(IBonkerFeeLocker.Unauthorized.selector);
        feeLocker.storeFees(FEE_OWNER, address(plainToken), 1 ether);
    }

    function testStoreFeesTracksActualAmountReceivedForFeeOnTransferToken() public {
        uint256 depositedAmount = 100 ether;
        uint256 expectedReceivedAmount = 95 ether;

        feeToken.mint(DEPOSITOR, depositedAmount);

        vm.startPrank(DEPOSITOR);
        feeToken.approve(address(feeLocker), depositedAmount);
        feeLocker.storeFees(FEE_OWNER, address(feeToken), depositedAmount);
        vm.stopPrank();

        assertEq(feeLocker.availableFees(FEE_OWNER, address(feeToken)), expectedReceivedAmount);
        assertEq(feeToken.balanceOf(address(feeLocker)), expectedReceivedAmount);
        assertEq(feeToken.balanceOf(FEE_COLLECTOR), depositedAmount - expectedReceivedAmount);
    }

    function testClaimTransfersFeesAndClearsBalance() public {
        uint256 depositedAmount = 11 ether;

        plainToken.mint(DEPOSITOR, depositedAmount);

        vm.startPrank(DEPOSITOR);
        plainToken.approve(address(feeLocker), depositedAmount);
        feeLocker.storeFees(FEE_OWNER, address(plainToken), depositedAmount);
        vm.stopPrank();

        vm.expectEmit();
        emit IBonkerFeeLocker.ClaimTokens(FEE_OWNER, address(plainToken), depositedAmount);

        vm.prank(CALLER);
        feeLocker.claim(FEE_OWNER, address(plainToken));

        assertEq(feeLocker.availableFees(FEE_OWNER, address(plainToken)), 0);
        assertEq(plainToken.balanceOf(address(feeLocker)), 0);
        assertEq(plainToken.balanceOf(FEE_OWNER), depositedAmount);
    }

    function testClaimRevertsWhenNoFeesAreAvailable() public {
        vm.expectRevert(IBonkerFeeLocker.NoFeesToClaim.selector);
        feeLocker.claim(FEE_OWNER, address(plainToken));
    }
}
