// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Test} from "forge-std/Test.sol";
import {BaseTest} from "../BaseTest.t.sol";
import {LPToken} from "../../src/LPToken.sol";
import "../../src/libraries/ConstantsLib.sol";
import {ErrorsLib} from "../../src/libraries/ErrorsLib.sol";

contract LPTokenFuzzTest is BaseTest {
    // Set reasonable amount range to avoid overflow
    uint256 constant MAX_DEPOSIT = type(uint128).max;

    function setUp() public override {
        super.setUp();

        // Give test contract enough USDC for testing
        deal(address(USDC), address(this), type(uint256).max);
        USDC.approve(address(lpUSDC), type(uint256).max);
    }

    /// @dev Fuzz test deposit function
    function testFuzz_deposit(uint256 amount) public {
        // Only need to ensure amount is above minimum deposit
        vm.assume(amount >= lpUSDC.minDeposit());

        // Record initial states
        uint256 initialTotalShares = lpUSDC.totalShares();
        uint256 initialTotalUnderlying = lpUSDC.totalUnderlying();
        uint256 initialBalance = USDC.balanceOf(address(this));
        uint256 initialVaultBalance = USDC.balanceOf(address(creditVault));

        // Execute deposit
        uint256 expectedShares = amount;
        uint256 sharesToMint = lpUSDC.deposit(amount);

        // Verify states after deposit
        assertEq(sharesToMint, expectedShares, "Incorrect shares minted");
        assertEq(lpUSDC.totalShares(), initialTotalShares + expectedShares, "Incorrect total shares");
        assertEq(lpUSDC.totalUnderlying(), initialTotalUnderlying + amount, "Incorrect total underlying");
        assertEq(USDC.balanceOf(address(this)), initialBalance - amount, "Incorrect user balance");
        assertEq(USDC.balanceOf(address(creditVault)), initialVaultBalance + amount, "Incorrect vault balance");
        assertEq(lpUSDC.shares(address(this)), expectedShares, "Incorrect user shares");
        assertEq(lpUSDC.lastDepositTimestamp(address(this)), block.timestamp, "Incorrect last deposit timestamp");
    }

    /// @dev Fuzz test redeem function
    function testFuzz_redeem(uint256 depositAmount, uint256 redeemShares) public {
        // Limit deposit amount range
        vm.assume(depositAmount >= lpUSDC.minDeposit() && depositAmount <= MAX_DEPOSIT);
        uint256 mintedShares = lpUSDC.deposit(depositAmount);

        // Ensure redeem shares within valid range
        vm.assume(redeemShares > 0 && redeemShares <= mintedShares);

        // Record initial states
        uint256 initialTotalShares = lpUSDC.totalShares();
        uint256 initialTotalUnderlying = lpUSDC.totalUnderlying();
        uint256 initialBalance = USDC.balanceOf(address(this));
        uint256 initialVaultBalance = USDC.balanceOf(address(creditVault));

        // Calculate expected underlying amount
        uint256 expectedUnderlying = (redeemShares * initialTotalUnderlying) / initialTotalShares;

        // If early withdrawal fee applies
        if (
            block.timestamp < lpUSDC.lastDepositTimestamp(address(this)) + lpUSDC.minRedeemInterval()
                && lpUSDC.earlyWithdrawFeeBips() > 0
        ) {
            expectedUnderlying -= (expectedUnderlying * lpUSDC.earlyWithdrawFeeBips()) / 10_000;
        }

        // Execute redeem
        uint256 redeemedAmount = lpUSDC.redeem(redeemShares);

        // Verify states after redeem
        assertEq(redeemedAmount, expectedUnderlying, "Incorrect redeemed amount");
        assertEq(lpUSDC.totalShares(), initialTotalShares - redeemShares, "Incorrect total shares");
        assertEq(lpUSDC.totalUnderlying(), initialTotalUnderlying - redeemedAmount, "Incorrect total underlying");
        assertEq(USDC.balanceOf(address(this)), initialBalance + redeemedAmount, "Incorrect user balance");
        assertEq(USDC.balanceOf(address(creditVault)), initialVaultBalance - redeemedAmount, "Incorrect vault balance");
        assertEq(lpUSDC.shares(address(this)), mintedShares - redeemShares, "Incorrect user shares");
    }

    /// @dev Test deposit with early withdrawal fee
    function testFuzz_depositAndEarlyRedeem(
        uint256 depositAmount,
        uint256 redeemSharesPercent,
        uint256 earlyWithdrawFeeBips
    ) public {
        // Bound input values instead of using assume
        depositAmount = bound(depositAmount, lpUSDC.minDeposit(), MAX_DEPOSIT);
        redeemSharesPercent = bound(redeemSharesPercent, 1, 10_000); // 0.01% to 100%
        earlyWithdrawFeeBips = bound(earlyWithdrawFeeBips, 0, MAX_EARLY_WITHDRAW_FEE_BIPS);

        // Setup early withdrawal fee
        vm.prank(deployer);
        lpUSDC.setEarlyWithdrawFeeBips(earlyWithdrawFeeBips);

        // Do deposit
        uint256 mintedShares = lpUSDC.deposit(depositAmount);

        // Calculate redeemShares as a percentage of mintedShares
        uint256 redeemShares = (mintedShares * redeemSharesPercent) / 10_000;

        // Skip test if redeemShares is 0
        if (redeemShares == 0) return;

        // Record states before redeem
        uint256 initialBalance = USDC.balanceOf(address(this));

        // Calculate expected underlying amount using contract's function
        uint256 expectedUnderlying = lpUSDC.getUnderlyingByShares(redeemShares);
        uint256 expectedAfterFee = expectedUnderlying;

        // Apply early withdrawal fee if applicable
        if (block.timestamp < lpUSDC.lastDepositTimestamp(address(this)) + lpUSDC.minRedeemInterval()) {
            expectedAfterFee = expectedUnderlying - (expectedUnderlying * earlyWithdrawFeeBips) / 10_000;
        }

        // Execute early redeem
        uint256 redeemedAmount = lpUSDC.redeem(redeemShares);

        // Verify amount after fee with 1 unit tolerance
        assertApproxEqAbs(
            redeemedAmount, expectedAfterFee, 1, "Redeemed amount should be approximately equal to expected"
        );
        assertApproxEqAbs(
            USDC.balanceOf(address(this)),
            initialBalance + expectedAfterFee,
            1,
            "User balance should be approximately equal to expected"
        );
    }

    /// @dev Test deposit reverts with invalid amounts
    function testFuzz_depositReverts(uint256 amount) public {
        vm.assume(amount < lpUSDC.minDeposit());

        vm.expectRevert(ErrorsLib.BelowMinimumDeposit.selector);
        lpUSDC.deposit(amount);
    }

    /// @dev Test redeem reverts with invalid shares
    function testFuzz_redeemReverts(uint256 shares) public {
        vm.assume(shares > 0);

        vm.expectRevert(ErrorsLib.InsufficientShares.selector);
        lpUSDC.redeem(shares);
    }

    /// @dev Test deposit and normal redeem
    function testFuzz_depositAndNormalRedeem(
        uint256 depositAmount,
        uint256 redeemSharesPercent,
        uint256 waitTime
    ) public {
        // Bound deposit amount between minDeposit and MAX_DEPOSIT
        depositAmount = bound(depositAmount, lpUSDC.minDeposit(), MAX_DEPOSIT);

        // Bound wait time between minRedeemInterval and 365 days
        waitTime = bound(waitTime, lpUSDC.minRedeemInterval(), 365 days);

        // Bound redeem shares percent between 1 and 10000 (0.01% to 100%)
        redeemSharesPercent = bound(redeemSharesPercent, 1, 10_000);

        // Deposit
        uint256 mintedShares = lpUSDC.deposit(depositAmount);

        // Wait for the specified time
        vm.warp(block.timestamp + waitTime);

        // Calculate redeemShares as a percentage of mintedShares
        uint256 redeemShares = (mintedShares * redeemSharesPercent) / 10_000;

        // Record states before redeem
        uint256 initialBalance = USDC.balanceOf(address(this));

        // Calculate expected underlying amount
        uint256 expectedUnderlying = lpUSDC.getUnderlyingByShares(redeemShares);
        uint256 expectedAfterFee = expectedUnderlying; // No fee for normal redeem

        // Execute redeem
        uint256 redeemedAmount = lpUSDC.redeem(redeemShares);

        // Verify amount
        assertApproxEqAbs(
            redeemedAmount, expectedAfterFee, 1, "Redeemed amount should be approximately equal to expected"
        );
        assertApproxEqAbs(
            USDC.balanceOf(address(this)),
            initialBalance + expectedAfterFee,
            1,
            "User balance should be approximately equal to expected"
        );
    }
}
