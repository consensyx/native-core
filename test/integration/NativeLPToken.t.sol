// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {NativeLPToken} from "../../src/NativeLPToken.sol";
import {BaseTest} from "../BaseTest.t.sol";
import {ErrorsLib} from "../../src/libraries/ErrorsLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract NativeLPTokenTest is BaseTest {
    uint256 constant MINIMUM_SHARE = 1000;

    // Helper arrays for batch function calls
    address[] private singleAccount;
    bool[] private singleStatus;
    address[] private multiAccounts;
    bool[] private multiStatuses;

    function setUp() public override {
        super.setUp();
        vm.prank(deployer);
        lpUSDC.setMinRedeemInterval(8 hours);

        // Initialize helper arrays
        singleAccount = new address[](1);
        singleStatus = new bool[](1);
        multiAccounts = new address[](2);
        multiStatuses = new bool[](2);
    }

    function test_deposit_success() public {
        // Setup
        uint256 depositAmount = 100_000_000; // 100 USDC

        // Record initial states
        uint256 initialTotalShares = lpUSDC.totalShares();
        uint256 initialTotalUnderlying = lpUSDC.totalUnderlying();
        uint256 initialBalance = USDC.balanceOf(alice);
        uint256 initialVaultBalance = USDC.balanceOf(address(creditVault));

        // Execute deposit
        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), depositAmount);
        uint256 mintedShares = lpUSDC.deposit(depositAmount);
        vm.stopPrank();

        // Verify states - account for MINIMUM_SHARE deducted from first deposit
        uint256 expectedTotalShares = initialTotalShares + depositAmount;

        assertEq(mintedShares, depositAmount - MINIMUM_SHARE, "Incorrect shares minted");
        assertEq(lpUSDC.totalShares(), expectedTotalShares, "Incorrect total shares");
        assertEq(lpUSDC.totalUnderlying(), initialTotalUnderlying + depositAmount, "Incorrect total underlying");
        assertEq(USDC.balanceOf(alice), initialBalance - depositAmount, "Incorrect user balance");
        assertEq(USDC.balanceOf(address(creditVault)), initialVaultBalance + depositAmount, "Incorrect vault balance");
        assertEq(lpUSDC.shares(alice), depositAmount - MINIMUM_SHARE, "Incorrect user shares");
        assertEq(lpUSDC.lastDepositTimestamp(alice), block.timestamp, "Incorrect last deposit timestamp");
    }

    function test_deposit_belowMinDeposit() public {
        // Setup - set min deposit to 100 USDC
        vm.prank(deployer);
        lpUSDC.setMinDeposit(100_000_000);

        // Try to deposit 99 USDC
        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), 99_000_000);
        vm.expectRevert(ErrorsLib.BelowMinimumDeposit.selector);
        lpUSDC.deposit(99_000_000);
        vm.stopPrank();
    }

    function test_deposit_whenPaused() public {
        // Setup
        vm.prank(deployer);
        lpUSDC.pauseDeposit();

        // Try to deposit while paused
        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), 100_000_000);
        vm.expectRevert(ErrorsLib.FeaturePaused.selector);
        lpUSDC.deposit(100_000_000);
        vm.stopPrank();
    }

    function test_deposit_insufficientAllowance() public {
        uint256 depositAmount = 100_000_000;

        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), 0);
        vm.expectRevert("ERC20: insufficient allowance");
        lpUSDC.deposit(depositAmount);
        vm.stopPrank();
    }

    function test_deposit_insufficientBalance() public {
        // Setup - drain alice's balance
        uint256 aliceBalance = USDC.balanceOf(alice);
        vm.startPrank(alice);
        USDC.transfer(bob, aliceBalance);

        // Try to deposit with insufficient balance
        USDC.approve(address(lpUSDC), 100_000_000);
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        lpUSDC.deposit(100_000_000);
        vm.stopPrank();
    }

    function test_deposit_zeroAmount() public {
        vm.startPrank(alice);
        vm.expectRevert(ErrorsLib.BelowMinimumDeposit.selector);
        lpUSDC.deposit(0);
        vm.stopPrank();
    }

    function test_deposit_multipleUsers() public {
        // First user deposits
        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), 100_000_000);
        uint256 aliceShares = lpUSDC.deposit(100_000_000);
        vm.stopPrank();

        // After first deposit, get current state
        uint256 totalSharesAfterFirst = lpUSDC.totalShares(); // 100_000_000 (MINIMUM_SHARE deducted from first depositor)
        uint256 totalUnderlyingAfterFirst = lpUSDC.totalUnderlying(); // 100_000_000

        // Second user deposits
        vm.startPrank(bob);
        USDC.approve(address(lpUSDC), 200_000_000);
        uint256 bobShares = lpUSDC.deposit(200_000_000);
        vm.stopPrank();

        // Calculate expected shares for second deposit
        uint256 expectedBobShares = (200_000_000 * totalSharesAfterFirst) / totalUnderlyingAfterFirst;

        // Verify share calculations
        assertEq(aliceShares, 100_000_000 - MINIMUM_SHARE, "Incorrect shares for first user");
        assertEq(bobShares, expectedBobShares, "Incorrect shares for second user");
        assertEq(lpUSDC.totalShares(), aliceShares + bobShares + MINIMUM_SHARE, "Incorrect total shares");
    }

    function test_redeem_success() public {
        // Setup
        uint256 depositAmount = 100_000_000; // 100 USDC

        // Execute deposit
        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), depositAmount);
        uint256 mintedShares = lpUSDC.deposit(depositAmount);

        // Wait for minimum redeem interval
        vm.warp(block.timestamp + lpUSDC.minRedeemInterval() + 1);

        // Record states before redeem
        uint256 beforeRedeemTotalShares = lpUSDC.totalShares();
        uint256 beforeRedeemTotalUnderlying = lpUSDC.totalUnderlying();
        uint256 beforeRedeemBalance = USDC.balanceOf(alice);
        uint256 beforeRedeemVaultBalance = USDC.balanceOf(address(creditVault));

        // Calculate expected redeem amount accounting for MINIMUM_SHARE dilution
        uint256 expectedRedeemAmount = (mintedShares * beforeRedeemTotalUnderlying) / beforeRedeemTotalShares;

        // Execute redeem
        uint256 redeemedAmount = lpUSDC.redeem(mintedShares);
        vm.stopPrank();

        // Verify states
        assertEq(redeemedAmount, expectedRedeemAmount, "Incorrect redeemed amount");
        assertEq(lpUSDC.totalShares(), beforeRedeemTotalShares - mintedShares, "Incorrect total shares");
        assertEq(lpUSDC.totalUnderlying(), beforeRedeemTotalUnderlying - redeemedAmount, "Incorrect total underlying");
        assertEq(USDC.balanceOf(alice), beforeRedeemBalance + redeemedAmount, "Incorrect user balance");
        assertEq(
            USDC.balanceOf(address(creditVault)), beforeRedeemVaultBalance - redeemedAmount, "Incorrect vault balance"
        );
        assertEq(lpUSDC.shares(alice), 0, "Incorrect user shares");
    }

    function test_redeem_earlyWithdrawalFee() public {
        // Setup
        uint256 depositAmount = 100_000_000; // 100 USDC
        uint256 earlyWithdrawFeeBips = 100; // 1%

        vm.prank(deployer);
        lpUSDC.setEarlyWithdrawFeeBips(earlyWithdrawFeeBips);

        // Deposit
        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), depositAmount);
        uint256 mintedShares = lpUSDC.deposit(depositAmount);

        // Record deposit timestamp and current states
        uint256 depositTime = lpUSDC.lastDepositTimestamp(alice);
        uint256 initialBalance = USDC.balanceOf(alice);

        // Ensure we're still within early withdrawal period
        // Move time forward but stay within early withdrawal period
        vm.warp(depositTime + lpUSDC.minRedeemInterval() - 1);

        // Calculate expected amounts accounting for MINIMUM_SHARE dilution
        uint256 totalSharesBeforeRedeem = lpUSDC.totalShares();
        uint256 totalUnderlyingBeforeRedeem = lpUSDC.totalUnderlying();
        uint256 grossAmount = (mintedShares * totalUnderlyingBeforeRedeem) / totalSharesBeforeRedeem;
        uint256 expectedFee = (grossAmount * earlyWithdrawFeeBips) / 10_000;
        uint256 expectedRedeemAmount = grossAmount - expectedFee;

        // Execute early redeem
        uint256 redeemedAmount = lpUSDC.redeem(mintedShares);
        vm.stopPrank();

        // Verify states
        assertEq(redeemedAmount, expectedRedeemAmount, "Incorrect redeemed amount");
        assertEq(USDC.balanceOf(alice), initialBalance + expectedRedeemAmount, "Incorrect user balance");
        assertEq(lpUSDC.shares(alice), 0, "Should have no shares left");
    }

    function test_redeem_insufficientShares() public {
        // Try to redeem without any shares
        vm.startPrank(alice);
        vm.expectRevert(ErrorsLib.InsufficientShares.selector);
        lpUSDC.redeem(100_000_000);
        vm.stopPrank();
    }

    function test_redeem_zeroAmount() public {
        vm.startPrank(alice);
        vm.expectRevert(ErrorsLib.ZeroAmount.selector);
        lpUSDC.redeem(0);
        vm.stopPrank();
    }

    function test_redeem_whenPaused() public {
        // Setup - first deposit
        uint256 depositAmount = 100_000_000;
        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), depositAmount);
        uint256 mintedShares = lpUSDC.deposit(depositAmount);
        vm.stopPrank();

        // Pause contract
        vm.prank(deployer);
        lpUSDC.pauseRedeem();

        // Try to redeem while paused
        vm.startPrank(alice);
        vm.expectRevert(ErrorsLib.FeaturePaused.selector);
        lpUSDC.redeem(mintedShares);
        vm.stopPrank();
    }

    function test_redeem_partialAmount() public {
        // Setup - first deposit
        uint256 depositAmount = 100_000_000;
        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), depositAmount);
        uint256 mintedShares = lpUSDC.deposit(depositAmount);

        // Wait for minimum redeem interval
        vm.warp(block.timestamp + lpUSDC.minRedeemInterval() + 1);

        // Redeem half of shares
        uint256 redeemShares = mintedShares / 2;

        // Calculate expected redeem amount accounting for MINIMUM_SHARE dilution
        uint256 totalSharesBeforeRedeem = lpUSDC.totalShares();
        uint256 totalUnderlyingBeforeRedeem = lpUSDC.totalUnderlying();
        uint256 expectedRedeemAmount = (redeemShares * totalUnderlyingBeforeRedeem) / totalSharesBeforeRedeem;

        uint256 redeemedAmount = lpUSDC.redeem(redeemShares);
        vm.stopPrank();

        // Verify states
        assertEq(redeemedAmount, expectedRedeemAmount, "Incorrect redeemed amount");
        assertEq(lpUSDC.shares(alice), redeemShares, "Incorrect remaining shares");
    }

    function test_redeem_afterYieldDistribution() public {
        // Setup - first deposit
        uint256 depositAmount = 100_000_000;
        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), depositAmount);
        uint256 mintedShares = lpUSDC.deposit(depositAmount);
        vm.stopPrank();

        // Record initial balance
        uint256 initialBalance = USDC.balanceOf(alice);

        // Distribute yield
        uint256 yieldAmount = 10_000_000; // 10 USDC yield

        // Transfer additional USDC to creditVault for yield distribution
        deal(address(USDC), address(creditVault), USDC.balanceOf(address(creditVault)) + yieldAmount);

        vm.startPrank(address(creditVault));
        USDC.approve(address(lpUSDC), yieldAmount);
        lpUSDC.distributeYield(yieldAmount);
        vm.stopPrank();

        // Wait for minimum redeem interval
        vm.warp(block.timestamp + lpUSDC.minRedeemInterval() + 1);

        // Calculate expected redeem amount with yield and MINIMUM_SHARE dilution
        uint256 totalSharesBeforeRedeem = lpUSDC.totalShares();
        uint256 totalUnderlyingBeforeRedeem = lpUSDC.totalUnderlying();
        uint256 expectedRedeemAmount = (mintedShares * totalUnderlyingBeforeRedeem) / totalSharesBeforeRedeem;

        // Redeem all shares
        vm.startPrank(alice);
        uint256 redeemedAmount = lpUSDC.redeem(mintedShares);
        vm.stopPrank();

        // Verify redeemed amount includes yield
        assertEq(redeemedAmount, expectedRedeemAmount, "Incorrect redeemed amount with yield");
        assertEq(USDC.balanceOf(alice), initialBalance + redeemedAmount, "Incorrect final balance");
    }

    function test_setMinDeposit() public {
        // Non-owner should not be able to set minDeposit
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        lpUSDC.setMinDeposit(1000);

        // Owner sets first value
        uint256 firstMinDeposit = 1000;
        vm.startPrank(deployer); // Ensure using deployer account
        lpUSDC.setMinDeposit(firstMinDeposit);
        assertEq(lpUSDC.minDeposit(), firstMinDeposit);

        // Owner updates to second value
        uint256 secondMinDeposit = 2000;
        lpUSDC.setMinDeposit(secondMinDeposit);
        assertEq(lpUSDC.minDeposit(), secondMinDeposit);
        vm.stopPrank();
    }

    function test_setMinRedeemInterval() public {
        // Non-owner should not be able to set minRedeemInterval
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        lpUSDC.setMinRedeemInterval(1 hours);

        // Owner sets first value
        vm.startPrank(deployer);

        uint256 firstInterval = 1 hours;
        lpUSDC.setMinRedeemInterval(firstInterval);
        assertEq(lpUSDC.minRedeemInterval(), firstInterval);

        // Owner updates to second value
        uint256 secondInterval = 2 hours;
        lpUSDC.setMinRedeemInterval(secondInterval);
        assertEq(lpUSDC.minRedeemInterval(), secondInterval);

        vm.stopPrank();
    }

    function test_SetEarlyWithdrawFeeBips() public {
        // Setup initial parameters
        uint256 newFeeBips = 50; // 0.5%

        // Only owner can set the fee
        vm.startPrank(deployer);
        lpUSDC.setEarlyWithdrawFeeBips(newFeeBips);
        vm.stopPrank();

        // Check if the fee was updated correctly
        assertEq(lpUSDC.earlyWithdrawFeeBips(), newFeeBips, "Early withdraw fee bips not updated correctly");

        // Try setting a fee greater than 10000 (should fail)
        vm.startPrank(deployer);
        vm.expectRevert(ErrorsLib.InvalidFeeBips.selector);
        lpUSDC.setEarlyWithdrawFeeBips(10_001);
        vm.stopPrank();

        // Check if the fee remains unchanged after the failed attempt
        assertEq(
            lpUSDC.earlyWithdrawFeeBips(), newFeeBips, "Early withdraw fee bips should not change after failed attempt"
        );

        // Non-owner should not be able to set the fee
        vm.startPrank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        lpUSDC.setEarlyWithdrawFeeBips(100);
        vm.stopPrank();

        // Check if the fee remains unchanged after the unauthorized attempt
        assertEq(
            lpUSDC.earlyWithdrawFeeBips(),
            newFeeBips,
            "Early withdraw fee bips should not change after unauthorized attempt"
        );
    }

    function test_pauseAndUnpause() public {
        // Ensure only the owner can pause
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        lpUSDC.pauseDeposit();

        // Owner pauses the contract
        vm.startPrank(deployer);
        lpUSDC.pauseDeposit();
        lpUSDC.pauseRedeem();
        vm.stopPrank();

        // Attempt to deposit while paused
        vm.startPrank(alice);
        uint256 depositAmount = 100_000_000; // 100 USDC
        vm.expectRevert(ErrorsLib.FeaturePaused.selector);
        lpUSDC.deposit(depositAmount);
        vm.stopPrank();

        // Attempt to redeem while paused
        vm.startPrank(alice);
        uint256 aliceShares = lpUSDC.shares(alice);
        vm.expectRevert(ErrorsLib.FeaturePaused.selector);
        lpUSDC.redeem(aliceShares);
        vm.stopPrank();

        // Ensure only the owner can unpause
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        lpUSDC.unpauseDeposit();

        // Owner unpauses deposit
        vm.startPrank(deployer);
        lpUSDC.unpauseDeposit();
        vm.stopPrank();

        // Deposit should succeed after unpausing deposit
        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), depositAmount);
        lpUSDC.deposit(depositAmount);
        assertEq(lpUSDC.shares(alice), depositAmount - MINIMUM_SHARE);
        vm.stopPrank();

        // Warp forward past the minimum redeem interval
        vm.warp(block.timestamp + lpUSDC.minRedeemInterval() + 1);

        // Owner unpauses redeem
        vm.startPrank(deployer);
        lpUSDC.unpauseRedeem();
        vm.stopPrank();

        // Redeem should succeed after unpausing redeem
        vm.startPrank(alice);
        aliceShares = lpUSDC.shares(alice);
        // Calculate expected redeem amount accounting for MINIMUM_SHARE dilution
        uint256 totalSharesBeforeRedeem = lpUSDC.totalShares();
        uint256 totalUnderlyingBeforeRedeem = lpUSDC.totalUnderlying();
        uint256 expectedRedeemAmount = (aliceShares * totalUnderlyingBeforeRedeem) / totalSharesBeforeRedeem;
        uint256 redeemAmount = lpUSDC.redeem(aliceShares);
        assertEq(redeemAmount, expectedRedeemAmount);
        vm.stopPrank();
    }

    function test_ComplexDepositRedeemScenario() public {
        // Setup initial parameters
        uint256 EPOCH = 8 hours;
        vm.startPrank(deployer);
        lpUSDC.setMinRedeemInterval(EPOCH);
        lpUSDC.setEarlyWithdrawFeeBips(2); // 0.02%
        vm.stopPrank();

        uint256 firstEpochStart = block.timestamp;

        // Execute test phases
        (uint256 aliceShares, uint256 bobShares) = _executeFirstEpoch();
        (aliceShares, bobShares) = _executeSecondEpoch(firstEpochStart, EPOCH, aliceShares, bobShares);
        _executeThirdEpoch(firstEpochStart, EPOCH, aliceShares, bobShares);

        // Final state checks
        _verifyFinalState();
    }

    function _executeFirstEpoch() internal returns (uint256 aliceShares, uint256 bobShares) {
        // Execute deposits
        uint256 aliceFirstShares = _executeFirstEpochDeposits();

        // Execute Alice's early redeem
        aliceShares = _executeFirstEpochRedeem(aliceFirstShares);

        // Get Bob's final shares
        bobShares = lpUSDC.shares(bob);
        return (aliceShares, bobShares);
    }

    function _executeFirstEpochDeposits() internal returns (uint256 aliceFirstShares) {
        // Alice's first deposit
        vm.startPrank(alice);
        uint256 aliceFirstDeposit = 111_111_111;
        aliceFirstShares = lpUSDC.deposit(aliceFirstDeposit);
        assertEq(aliceFirstShares, aliceFirstDeposit - MINIMUM_SHARE, "Alice's first shares incorrect");
        vm.stopPrank();

        // Advance 1 hour
        vm.warp(block.timestamp + 1 hours);

        // Bob's deposit
        vm.startPrank(bob);
        uint256 bobFirstDeposit = 222_222_222;
        uint256 bobExpectedShares = (bobFirstDeposit * lpUSDC.totalShares()) / lpUSDC.totalUnderlying();
        uint256 bobShares = lpUSDC.deposit(bobFirstDeposit);
        assertEq(bobShares, bobExpectedShares, "Bob's shares incorrect");
        vm.stopPrank();

        // Charlie's deposit
        vm.startPrank(charlie);
        uint256 charlieDeposit = 333_333_333;
        uint256 charlieExpectedShares = (charlieDeposit * lpUSDC.totalShares()) / lpUSDC.totalUnderlying();
        uint256 charlieShares = lpUSDC.deposit(charlieDeposit);
        assertEq(charlieShares, charlieExpectedShares, "Charlie's shares incorrect");
        vm.stopPrank();

        // Alice's second deposit
        vm.startPrank(alice);
        uint256 aliceSecondDeposit = 444_444_444;
        uint256 aliceSecondExpectedShares = (aliceSecondDeposit * lpUSDC.totalShares()) / lpUSDC.totalUnderlying();
        uint256 aliceSecondShares = lpUSDC.deposit(aliceSecondDeposit);
        assertEq(aliceSecondShares, aliceSecondExpectedShares, "Alice's second shares incorrect");
        vm.stopPrank();

        return aliceFirstShares;
    }

    function _executeFirstEpochRedeem(uint256 aliceFirstShares) internal returns (uint256) {
        vm.startPrank(alice);
        uint256 aliceRedeemShares = aliceFirstShares / 2;
        uint256 expectedUnderlying = (aliceRedeemShares * lpUSDC.totalUnderlying()) / lpUSDC.totalShares();
        uint256 expectedFee = (expectedUnderlying * 2) / 10_000;
        uint256 expectedRedeemAmount = expectedUnderlying - expectedFee;
        uint256 actualRedeemAmount = lpUSDC.redeem(aliceRedeemShares);
        assertEq(actualRedeemAmount, expectedRedeemAmount, "Alice's early redeem amount incorrect");
        vm.stopPrank();

        return lpUSDC.shares(alice);
    }

    function _executeSecondEpoch(
        uint256 firstEpochStart,
        uint256 EPOCH,
        uint256 aliceShares,
        uint256 bobShares
    ) internal returns (uint256 newAliceShares, uint256 newBobShares) {
        vm.warp(firstEpochStart + EPOCH);

        // Second epoch deposits and redeems
        vm.startPrank(alice);
        uint256 aliceThirdDeposit = 555_555_555;
        // uint256 aliceThirdShares = lpUSDC.deposit(aliceThirdDeposit);
        lpUSDC.deposit(aliceThirdDeposit);
        vm.stopPrank();

        vm.startPrank(bob);
        uint256 bobSecondDeposit = 666_666_666;
        // uint256 bobSecondShares = lpUSDC.deposit(bobSecondDeposit);
        lpUSDC.deposit(bobSecondDeposit);
        vm.stopPrank();

        vm.startPrank(charlie);
        uint256 charlieSecondDeposit = 777_777_777;
        // uint256 charlieSecondShares = lpUSDC.deposit(charlieSecondDeposit);
        lpUSDC.deposit(charlieSecondDeposit);
        vm.stopPrank();

        // Distribute yield
        vm.warp(block.timestamp + 1 hours);
        uint256 yieldAmount = lpUSDC.totalUnderlying() / 1000;
        vm.prank(address(creditVault));
        lpUSDC.distributeYield(yieldAmount);

        // Early redeems
        _executeSecondEpochRedeems(aliceShares, bobShares);

        return (lpUSDC.shares(alice), lpUSDC.shares(bob));
    }

    function _executeSecondEpochRedeems(uint256 aliceShares, uint256 bobShares) internal {
        vm.startPrank(alice);
        uint256 aliceRedeemShares = aliceShares / 2;
        uint256 expectedUnderlying = (aliceRedeemShares * lpUSDC.totalUnderlying()) / lpUSDC.totalShares();
        uint256 expectedFee = (expectedUnderlying * 2) / 10_000;
        uint256 actualRedeemAmount = lpUSDC.redeem(aliceRedeemShares);
        assertEq(actualRedeemAmount, expectedUnderlying - expectedFee, "Alice's second redeem amount incorrect");
        vm.stopPrank();

        vm.startPrank(bob);
        uint256 bobRedeemShares = bobShares / 2;
        expectedUnderlying = (bobRedeemShares * lpUSDC.totalUnderlying()) / lpUSDC.totalShares();
        expectedFee = (expectedUnderlying * 2) / 10_000;
        actualRedeemAmount = lpUSDC.redeem(bobRedeemShares);
        assertEq(actualRedeemAmount, expectedUnderlying - expectedFee, "Bob's redeem amount incorrect");
        vm.stopPrank();
    }

    function _executeThirdEpoch(
        uint256 firstEpochStart,
        uint256 EPOCH,
        uint256 aliceShares,
        uint256 bobShares
    ) internal {
        vm.warp(firstEpochStart + (2 * EPOCH));

        // Distribute yield
        uint256 yieldAmount = lpUSDC.totalUnderlying() / 1000;
        vm.prank(address(creditVault));
        lpUSDC.distributeYield(yieldAmount);

        // Final redeems
        vm.startPrank(alice);
        uint256 aliceFinalShares = (aliceShares * 30) / 100;
        uint256 expectedUnderlying = (aliceFinalShares * lpUSDC.totalUnderlying()) / lpUSDC.totalShares();
        uint256 actualRedeemAmount = lpUSDC.redeem(aliceFinalShares);
        assertEq(actualRedeemAmount, expectedUnderlying, "Alice's final redeem amount incorrect");
        vm.stopPrank();

        vm.startPrank(bob);
        uint256 bobFinalShares = (bobShares * 30) / 100;
        expectedUnderlying = (bobFinalShares * lpUSDC.totalUnderlying()) / lpUSDC.totalShares();
        actualRedeemAmount = lpUSDC.redeem(bobFinalShares);
        assertEq(actualRedeemAmount, expectedUnderlying, "Bob's final redeem amount incorrect");
        vm.stopPrank();
    }

    function _verifyFinalState() internal view {
        assertEq(
            lpUSDC.balanceOf(alice),
            lpUSDC.getUnderlyingByShares(lpUSDC.shares(alice)),
            "Alice's final balance incorrect"
        );
        assertEq(
            lpUSDC.balanceOf(bob), lpUSDC.getUnderlyingByShares(lpUSDC.shares(bob)), "Bob's final balance incorrect"
        );
        assertEq(
            lpUSDC.balanceOf(charlie),
            lpUSDC.getUnderlyingByShares(lpUSDC.shares(charlie)),
            "Charlie's final balance incorrect"
        );
        assertEq(lpUSDC.totalSupply(), lpUSDC.totalUnderlying(), "Total supply incorrect");

        // Total shares should equal user shares plus MINIMUM_SHARE locked in address(0)
        uint256 expectedTotalShares = lpUSDC.shares(alice) + lpUSDC.shares(bob) + lpUSDC.shares(charlie) + MINIMUM_SHARE;
        assertEq(lpUSDC.totalShares(), expectedTotalShares, "Total shares incorrect");
    }

    function test_distributeYield_success() public {
        // Setup - first deposit
        uint256 depositAmount = 100_000_000;
        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), depositAmount);
        lpUSDC.deposit(depositAmount);
        vm.stopPrank();

        // Record initial states
        uint256 initialTotalUnderlying = lpUSDC.totalUnderlying();
        uint256 initialVaultBalance = USDC.balanceOf(address(creditVault));

        // Distribute yield
        uint256 yieldAmount = 10_000_000; // 10 USDC yield
        vm.startPrank(address(creditVault));
        USDC.approve(address(lpUSDC), yieldAmount);
        lpUSDC.distributeYield(yieldAmount);
        vm.stopPrank();

        // Verify states
        assertEq(
            lpUSDC.totalUnderlying(), initialTotalUnderlying + yieldAmount, "Incorrect total underlying after yield"
        );
        assertEq(USDC.balanceOf(address(creditVault)), initialVaultBalance, "Incorrect vault balance after yield");
    }

    function test_distributeYield_onlyVault() public {
        // Make sure LP token total shares > 0
        uint256 depositAmount = 100_000_000;
        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), depositAmount);
        lpUSDC.deposit(depositAmount);
        vm.stopPrank();

        uint256 yieldAmount = 10_000_000;

        // Try to distribute yield from non-vault address (alice)
        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), yieldAmount);
        vm.expectRevert(ErrorsLib.OnlyCreditVault.selector);
        lpUSDC.distributeYield(yieldAmount);
        vm.stopPrank();

        // Try to distribute yield from non-vault address (deployer)
        vm.startPrank(deployer);
        USDC.approve(address(lpUSDC), yieldAmount);
        vm.expectRevert(ErrorsLib.OnlyCreditVault.selector);
        lpUSDC.distributeYield(yieldAmount);
        vm.stopPrank();
    }

    function test_distributeYield_zeroAmount() public {
        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), 10_000_000);
        lpUSDC.deposit(10_000_000);
        vm.stopPrank();

        // Try to distribute zero yield from vault
        vm.startPrank(address(creditVault));
        vm.expectRevert(ErrorsLib.NoYieldToDistribute.selector);
        lpUSDC.distributeYield(0);
        vm.stopPrank();
    }

    function test_distributeYield_whenPoolNotInitialized() public {
        // Try to distribute yield without any deposits
        vm.startPrank(address(creditVault));
        USDC.approve(address(lpUSDC), 10_000_000);
        vm.expectRevert(ErrorsLib.PoolNotInitialized.selector);
        lpUSDC.distributeYield(10_000_000);
        vm.stopPrank();
    }

    function test_distributeYield_multipleDistributions() public {
        // Setup - first deposit
        uint256 depositAmount = 100_000_000;
        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), depositAmount);
        lpUSDC.deposit(depositAmount);
        vm.stopPrank();

        // First yield distribution
        uint256 firstYield = 10_000_000;
        vm.startPrank(address(creditVault));
        USDC.approve(address(lpUSDC), firstYield);
        lpUSDC.distributeYield(firstYield);

        // Second yield distribution
        uint256 secondYield = 5_000_000;
        USDC.approve(address(lpUSDC), secondYield);
        lpUSDC.distributeYield(secondYield);
        vm.stopPrank();

        // Verify total underlying includes both yields (no MINIMUM_SHARE in totalUnderlying)
        assertEq(
            lpUSDC.totalUnderlying(),
            depositAmount + firstYield + secondYield,
            "Incorrect total underlying after multiple yields"
        );
    }

    function test_transfer_inCooldown() public {
        // Setup - first deposit
        uint256 depositAmount = 100_000_000; // 100 USDC
        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), depositAmount);
        lpUSDC.deposit(depositAmount);

        // Try to transfer immediately after deposit (while in cooldown)
        uint256 transferAmount = 50_000_000; // 50 USDC
        vm.expectRevert(ErrorsLib.TransferInCooldown.selector);
        lpUSDC.transfer(bob, transferAmount);
        vm.stopPrank();

        // Verify states remain unchanged
        assertEq(lpUSDC.shares(alice), depositAmount - MINIMUM_SHARE, "Alice's shares should remain unchanged");
        assertEq(lpUSDC.shares(bob), 0, "Bob should have no shares");

        // Warp time to after cooldown period
        vm.warp(block.timestamp + lpUSDC.minRedeemInterval() + 1);

        // Transfer should succeed after cooldown
        vm.startPrank(alice);
        lpUSDC.transfer(bob, transferAmount);
        vm.stopPrank();

        // Verify transfer succeeded
        assertEq(
            lpUSDC.shares(alice),
            (depositAmount - MINIMUM_SHARE) - lpUSDC.getSharesByUnderlying(transferAmount),
            "Alice's remaining shares incorrect"
        );
        assertEq(lpUSDC.shares(bob), lpUSDC.getSharesByUnderlying(transferAmount), "Bob's received shares incorrect");
    }

    function test_transfer_whitelist() public {
        // Setup - first deposit
        uint256 depositAmount = 100_000_000; // 100 USDC
        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), depositAmount);
        lpUSDC.deposit(depositAmount);
        vm.stopPrank();

        // Try to transfer immediately after deposit (should fail as not whitelisted)
        uint256 transferAmount = 50_000_000; // 50 USDC
        vm.startPrank(alice);
        vm.expectRevert(ErrorsLib.TransferInCooldown.selector);
        lpUSDC.transfer(bob, transferAmount);
        vm.stopPrank();

        // Add alice to whitelist
        vm.startPrank(deployer);
        singleAccount[0] = alice;
        singleStatus[0] = true;
        lpUSDC.setRedeemCooldownExempt(singleAccount, singleStatus);
        vm.stopPrank();

        // Verify alice is whitelisted
        assertTrue(lpUSDC.redeemCooldownExempt(alice), "Alice should be whitelisted");

        // Transfer should now succeed even in cooldown period
        vm.startPrank(alice);
        lpUSDC.transfer(bob, transferAmount);
        vm.stopPrank();

        // Verify transfer succeeded
        assertEq(
            lpUSDC.shares(alice),
            (depositAmount - MINIMUM_SHARE) - lpUSDC.getSharesByUnderlying(transferAmount),
            "Alice's remaining shares incorrect"
        );
        assertEq(lpUSDC.shares(bob), lpUSDC.getSharesByUnderlying(transferAmount), "Bob's received shares incorrect");

        // Remove alice from whitelist
        vm.startPrank(deployer);
        singleAccount[0] = alice;
        singleStatus[0] = false;
        lpUSDC.setRedeemCooldownExempt(singleAccount, singleStatus);
        vm.stopPrank();

        // Verify alice is no longer whitelisted
        assertFalse(lpUSDC.redeemCooldownExempt(alice), "Alice should not be whitelisted");

        // Try to transfer again (should fail as no longer whitelisted)
        vm.startPrank(alice);
        vm.expectRevert(ErrorsLib.TransferInCooldown.selector);
        lpUSDC.transfer(bob, transferAmount);
        vm.stopPrank();
    }

    function test_transferShares() public {
        // Setup - first deposit
        uint256 depositAmount = 100_000_000; // 100 USDC
        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), depositAmount);
        lpUSDC.deposit(depositAmount);
        vm.stopPrank();

        // Wait for cooldown period to end
        vm.warp(block.timestamp + lpUSDC.minRedeemInterval() + 1);

        // Record initial states
        uint256 aliceInitialShares = lpUSDC.shares(alice);
        uint256 bobInitialShares = lpUSDC.shares(bob);
        uint256 sharesToTransfer = 40_000_000; // Transfer 40 USDC worth of shares

        // Calculate expected underlying amount
        uint256 expectedTokenAmount = lpUSDC.getUnderlyingByShares(sharesToTransfer);

        // Transfer shares
        vm.startPrank(alice);
        uint256 transferredTokenAmount = lpUSDC.transferShares(bob, sharesToTransfer);
        vm.stopPrank();

        // Verify states
        assertEq(transferredTokenAmount, expectedTokenAmount, "Incorrect token amount returned");
        assertEq(lpUSDC.shares(alice), aliceInitialShares - sharesToTransfer, "Incorrect sender shares");
        assertEq(lpUSDC.shares(bob), bobInitialShares + sharesToTransfer, "Incorrect recipient shares");

        // Verify balances (in terms of underlying tokens)
        assertEq(
            lpUSDC.balanceOf(alice),
            lpUSDC.getUnderlyingByShares(aliceInitialShares - sharesToTransfer),
            "Incorrect sender balance"
        );
        assertEq(lpUSDC.balanceOf(bob), lpUSDC.getUnderlyingByShares(sharesToTransfer), "Incorrect recipient balance");
    }

    function test_transferShares_inCooldown() public {
        // Setup - first deposit
        uint256 depositAmount = 100_000_000; // 100 USDC
        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), depositAmount);
        lpUSDC.deposit(depositAmount);

        uint256 sharesToTransfer = 40_000_000;

        // Try to transfer shares immediately after deposit (should fail due to cooldown)
        vm.expectRevert(ErrorsLib.TransferInCooldown.selector);
        lpUSDC.transferShares(bob, sharesToTransfer);
        vm.stopPrank();

        // Add alice to whitelist
        vm.prank(deployer);
        singleAccount[0] = alice;
        singleStatus[0] = true;
        lpUSDC.setRedeemCooldownExempt(singleAccount, singleStatus);

        vm.startPrank(alice);
        uint256 transferredAmount = lpUSDC.transferShares(bob, sharesToTransfer);
        vm.stopPrank();

        // Verify transfer succeeded
        assertEq(lpUSDC.shares(alice), (depositAmount - MINIMUM_SHARE) - sharesToTransfer, "Incorrect sender shares");
        assertEq(lpUSDC.shares(bob), sharesToTransfer, "Incorrect recipient shares");
        assertEq(transferredAmount, lpUSDC.getUnderlyingByShares(sharesToTransfer), "Incorrect transferred amount");
    }

    function test_transferShares_insufficientShares() public {
        // Setup - first deposit
        uint256 depositAmount = 100_000_000;
        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), depositAmount);
        lpUSDC.deposit(depositAmount);

        // Try to transfer more shares than owned
        vm.expectRevert(); // Should revert with arithmetic underflow
        lpUSDC.transferShares(bob, depositAmount + 1);
        vm.stopPrank();
    }

    function test_depositFor_success() public {
        // Setup
        uint256 depositAmount = 100_000_000; // 100 USDC

        // Set alice as deposit delegator
        vm.prank(deployer);
        singleAccount[0] = alice;
        singleStatus[0] = true;
        lpUSDC.setTrustedOperator(singleAccount, singleStatus);

        // Record initial states
        uint256 initialTotalShares = lpUSDC.totalShares();
        uint256 initialTotalUnderlying = lpUSDC.totalUnderlying();
        uint256 initialBalance = USDC.balanceOf(alice);
        uint256 initialVaultBalance = USDC.balanceOf(address(creditVault));

        // Execute depositFor
        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), depositAmount);
        uint256 mintedShares = lpUSDC.depositFor(bob, depositAmount);
        vm.stopPrank();

        // Verify states - account for MINIMUM_SHARE deducted from first deposit
        uint256 expectedTotalShares = initialTotalShares + depositAmount;
        uint256 expectedMintedShares = depositAmount - MINIMUM_SHARE;

        assertEq(mintedShares, expectedMintedShares, "Incorrect shares minted");
        assertEq(lpUSDC.totalShares(), expectedTotalShares, "Incorrect total shares");
        assertEq(lpUSDC.totalUnderlying(), initialTotalUnderlying + depositAmount, "Incorrect total underlying");
        assertEq(USDC.balanceOf(alice), initialBalance - depositAmount, "Incorrect depositor balance");
        assertEq(USDC.balanceOf(address(creditVault)), initialVaultBalance + depositAmount, "Incorrect vault balance");
        assertEq(lpUSDC.shares(bob), depositAmount - MINIMUM_SHARE, "Incorrect recipient shares");
        assertEq(lpUSDC.lastDepositTimestamp(bob), block.timestamp, "Incorrect last deposit timestamp");
    }

    function test_depositFor_notTrustedOperator() public {
        // Try to deposit without being a trusted operator
        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), 100_000_000);
        vm.expectRevert(ErrorsLib.NotTrustedOperator.selector);
        lpUSDC.depositFor(bob, 100_000_000);
        vm.stopPrank();
    }

    function test_depositFor_belowMinDeposit() public {
        // Setup - set min deposit to 100 USDC
        vm.startPrank(deployer);
        lpUSDC.setMinDeposit(100_000_000);
        singleAccount[0] = alice;
        singleStatus[0] = true;
        lpUSDC.setTrustedOperator(singleAccount, singleStatus);
        vm.stopPrank();

        // Try to deposit 99 USDC
        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), 99_000_000);
        vm.expectRevert(ErrorsLib.BelowMinimumDeposit.selector);
        lpUSDC.depositFor(bob, 99_000_000);
        vm.stopPrank();
    }

    function test_depositFor_whenPaused() public {
        // Setup
        vm.startPrank(deployer);
        lpUSDC.pauseDeposit();
        singleAccount[0] = alice;
        singleStatus[0] = true;
        lpUSDC.setTrustedOperator(singleAccount, singleStatus);
        vm.stopPrank();

        // Try to deposit while paused
        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), 100_000_000);
        vm.expectRevert(ErrorsLib.FeaturePaused.selector);
        lpUSDC.depositFor(bob, 100_000_000);
        vm.stopPrank();
    }

    function test_depositFor_insufficientAllowance() public {
        // Setup trusted delegator
        vm.prank(deployer);
        singleAccount[0] = alice;
        singleStatus[0] = true;
        lpUSDC.setTrustedOperator(singleAccount, singleStatus);

        uint256 depositAmount = 100_000_000;

        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), 0);
        vm.expectRevert("ERC20: insufficient allowance");
        lpUSDC.depositFor(bob, depositAmount);
        vm.stopPrank();
    }

    function test_depositFor_insufficientBalance() public {
        // Setup trusted delegator
        vm.prank(deployer);
        singleAccount[0] = alice;
        singleStatus[0] = true;
        lpUSDC.setTrustedOperator(singleAccount, singleStatus);

        // Setup - drain alice's balance
        uint256 aliceBalance = USDC.balanceOf(alice);
        vm.startPrank(alice);
        USDC.transfer(charlie, aliceBalance);

        // Try to deposit with insufficient balance
        USDC.approve(address(lpUSDC), 100_000_000);
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        lpUSDC.depositFor(bob, 100_000_000);
        vm.stopPrank();
    }

    function test_depositFor_zeroAmount() public {
        // Setup trusted delegator
        vm.prank(deployer);
        singleAccount[0] = alice;
        singleStatus[0] = true;
        lpUSDC.setTrustedOperator(singleAccount, singleStatus);

        vm.startPrank(alice);
        vm.expectRevert(ErrorsLib.BelowMinimumDeposit.selector);
        lpUSDC.depositFor(bob, 0);
        vm.stopPrank();
    }

    function test_depositFor_zeroAddress() public {
        // Setup trusted delegator
        vm.prank(deployer);
        singleAccount[0] = alice;
        singleStatus[0] = true;
        lpUSDC.setTrustedOperator(singleAccount, singleStatus);

        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), 100_000_000);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        lpUSDC.depositFor(address(0), 100_000_000);
        vm.stopPrank();
    }

    function test_depositFor_multipleDeposits() public {
        // Setup trusted delegators
        vm.startPrank(deployer);
        multiAccounts[0] = alice;
        multiAccounts[1] = charlie;
        multiStatuses[0] = true;
        multiStatuses[1] = true;
        lpUSDC.setTrustedOperator(multiAccounts, multiStatuses);
        vm.stopPrank();

        // First deposit from Alice to Bob
        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), 100_000_000);
        uint256 aliceDepositShares = lpUSDC.depositFor(bob, 100_000_000);
        vm.stopPrank();

        // After first deposit, totalShares = 100_000_000 + MINIMUM_SHARE, totalUnderlying = 100_000_000
        uint256 totalSharesAfterFirst = lpUSDC.totalShares();
        uint256 totalUnderlyingAfterFirst = lpUSDC.totalUnderlying();

        // Second deposit from Charlie to Bob
        vm.startPrank(charlie);
        USDC.approve(address(lpUSDC), 200_000_000);
        uint256 charlieDepositShares = lpUSDC.depositFor(bob, 200_000_000);
        vm.stopPrank();

        // Calculate expected shares for second deposit
        uint256 expectedCharlieShares = (200_000_000 * totalSharesAfterFirst) / totalUnderlyingAfterFirst;

        // Verify share calculations
        assertEq(aliceDepositShares, 100_000_000 - MINIMUM_SHARE, "Incorrect shares for first deposit");
        assertEq(charlieDepositShares, expectedCharlieShares, "Incorrect shares for second deposit");
        assertEq(lpUSDC.shares(bob), aliceDepositShares + charlieDepositShares, "Incorrect total recipient shares");
        assertEq(lpUSDC.shares(alice), 0, "Depositor should not receive shares");
        assertEq(lpUSDC.shares(charlie), 0, "Depositor should not receive shares");
    }

    function test_redeemTo_success() public {
        // Setup - first set alice as trusted operator
        vm.prank(deployer);
        singleAccount[0] = alice;
        singleStatus[0] = true;
        lpUSDC.setTrustedOperator(singleAccount, singleStatus);

        // Setup - first deposit
        uint256 depositAmount = 100_000_000; // 100 USDC
        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), depositAmount);
        uint256 mintedShares = lpUSDC.deposit(depositAmount);

        // Wait for minimum redeem interval
        vm.warp(block.timestamp + lpUSDC.minRedeemInterval() + 1);

        // Record states before redeem
        uint256 initialTotalShares = lpUSDC.totalShares();
        uint256 initialTotalUnderlying = lpUSDC.totalUnderlying();
        uint256 initialBobBalance = USDC.balanceOf(bob);
        uint256 initialVaultBalance = USDC.balanceOf(address(creditVault));

        // Calculate expected redeem amount accounting for MINIMUM_SHARE dilution
        uint256 expectedRedeemAmount = (mintedShares * initialTotalUnderlying) / initialTotalShares;

        // Execute redeemTo
        uint256 redeemedAmount = lpUSDC.redeemTo(mintedShares, bob);
        vm.stopPrank();

        // Verify states
        assertEq(redeemedAmount, expectedRedeemAmount, "Incorrect redeemed amount");
        assertEq(lpUSDC.totalShares(), initialTotalShares - mintedShares, "Incorrect total shares");
        assertEq(lpUSDC.totalUnderlying(), initialTotalUnderlying - redeemedAmount, "Incorrect total underlying");
        assertEq(USDC.balanceOf(bob), initialBobBalance + redeemedAmount, "Incorrect recipient balance");
        assertEq(USDC.balanceOf(address(creditVault)), initialVaultBalance - redeemedAmount, "Incorrect vault balance");
        assertEq(lpUSDC.shares(alice), 0, "Incorrect user shares");
    }

    function test_redeemTo_notTrustedOperator() public {
        // Setup - first deposit
        uint256 depositAmount = 100_000_000;
        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), depositAmount);
        lpUSDC.deposit(depositAmount);

        // Try to redeemTo without being trusted operator
        vm.expectRevert(ErrorsLib.NotTrustedOperator.selector);
        lpUSDC.redeemTo(depositAmount, bob);
        vm.stopPrank();
    }

    function test_redeemTo_earlyWithdrawalFee() public {
        // Setup - set alice as trusted operator
        vm.prank(deployer);
        singleAccount[0] = alice;
        singleStatus[0] = true;
        lpUSDC.setTrustedOperator(singleAccount, singleStatus);

        uint256 depositAmount = 100_000_000; // 100 USDC
        uint256 earlyWithdrawFeeBips = 100; // 1%

        vm.prank(deployer);
        lpUSDC.setEarlyWithdrawFeeBips(earlyWithdrawFeeBips);

        // Deposit
        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), depositAmount);
        uint256 mintedShares = lpUSDC.deposit(depositAmount);

        // Record states
        uint256 depositTime = lpUSDC.lastDepositTimestamp(alice);
        uint256 initialBobBalance = USDC.balanceOf(bob);

        // Ensure we're still within early withdrawal period
        vm.warp(depositTime + lpUSDC.minRedeemInterval() - 1);

        // Calculate expected amounts accounting for MINIMUM_SHARE dilution
        uint256 totalSharesBeforeRedeem = lpUSDC.totalShares();
        uint256 totalUnderlyingBeforeRedeem = lpUSDC.totalUnderlying();
        uint256 grossAmount = (mintedShares * totalUnderlyingBeforeRedeem) / totalSharesBeforeRedeem;
        uint256 expectedFee = (grossAmount * earlyWithdrawFeeBips) / 10_000;
        uint256 expectedRedeemAmount = grossAmount - expectedFee;

        // Execute early redeemTo
        uint256 redeemedAmount = lpUSDC.redeemTo(mintedShares, bob);
        vm.stopPrank();

        // Verify states
        assertEq(redeemedAmount, expectedRedeemAmount, "Incorrect redeemed amount");
        assertEq(USDC.balanceOf(bob), initialBobBalance + expectedRedeemAmount, "Incorrect recipient balance");
        assertEq(lpUSDC.shares(alice), 0, "Should have no shares left");
    }

    function test_redeemTo_insufficientShares() public {
        // Setup - set alice as trusted operator
        vm.prank(deployer);
        singleAccount[0] = alice;
        singleStatus[0] = true;
        lpUSDC.setTrustedOperator(singleAccount, singleStatus);

        // Try to redeem without any shares
        vm.startPrank(alice);
        vm.expectRevert(ErrorsLib.InsufficientShares.selector);
        lpUSDC.redeemTo(100_000_000, bob);
        vm.stopPrank();
    }

    function test_redeemTo_zeroAmount() public {
        // Setup - set alice as trusted operator
        vm.prank(deployer);
        singleAccount[0] = alice;
        singleStatus[0] = true;
        lpUSDC.setTrustedOperator(singleAccount, singleStatus);

        vm.startPrank(alice);
        vm.expectRevert(ErrorsLib.ZeroAmount.selector);
        lpUSDC.redeemTo(0, bob);
        vm.stopPrank();
    }

    function test_redeemTo_zeroAddress() public {
        // Setup - set alice as trusted operator
        vm.prank(deployer);
        singleAccount[0] = alice;
        singleStatus[0] = true;
        lpUSDC.setTrustedOperator(singleAccount, singleStatus);

        // Setup - first deposit
        uint256 depositAmount = 100_000_000;
        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), depositAmount);
        lpUSDC.deposit(depositAmount);

        // Try to redeem to zero address
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        lpUSDC.redeemTo(depositAmount, address(0));
        vm.stopPrank();
    }

    function test_redeemTo_whenPaused() public {
        // Setup - set alice as trusted operator
        vm.prank(deployer);
        singleAccount[0] = alice;
        singleStatus[0] = true;
        lpUSDC.setTrustedOperator(singleAccount, singleStatus);

        // Setup - first deposit
        uint256 depositAmount = 100_000_000;
        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), depositAmount);
        uint256 mintedShares = lpUSDC.deposit(depositAmount);
        vm.stopPrank();

        // Pause contract
        vm.prank(deployer);
        lpUSDC.pauseRedeem();

        // Try to redeem while paused
        vm.startPrank(alice);
        vm.expectRevert(ErrorsLib.FeaturePaused.selector);
        lpUSDC.redeemTo(mintedShares, bob);
        vm.stopPrank();
    }

    function test_redeemTo_partialAmount() public {
        // Setup - set alice as trusted operator
        vm.prank(deployer);
        singleAccount[0] = alice;
        singleStatus[0] = true;
        lpUSDC.setTrustedOperator(singleAccount, singleStatus);

        // Setup - first deposit
        uint256 depositAmount = 100_000_000;
        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), depositAmount);
        uint256 mintedShares = lpUSDC.deposit(depositAmount);

        // Wait for minimum redeem interval
        vm.warp(block.timestamp + lpUSDC.minRedeemInterval() + 1);

        // Record initial balance
        uint256 initialBobBalance = USDC.balanceOf(bob);

        // Redeem half of shares
        uint256 redeemShares = mintedShares / 2;

        // Calculate expected redeem amount accounting for MINIMUM_SHARE dilution
        uint256 totalSharesBeforeRedeem = lpUSDC.totalShares();
        uint256 totalUnderlyingBeforeRedeem = lpUSDC.totalUnderlying();
        uint256 expectedRedeemAmount = (redeemShares * totalUnderlyingBeforeRedeem) / totalSharesBeforeRedeem;

        uint256 redeemedAmount = lpUSDC.redeemTo(redeemShares, bob);
        vm.stopPrank();

        // Verify states
        assertEq(redeemedAmount, expectedRedeemAmount, "Incorrect redeemed amount");
        assertEq(lpUSDC.shares(alice), redeemShares, "Incorrect remaining shares");
        assertEq(USDC.balanceOf(bob), initialBobBalance + expectedRedeemAmount, "Incorrect recipient balance");
    }

    function test_redeemTo_afterYieldDistribution() public {
        // Setup - set alice as trusted operator
        vm.prank(deployer);
        singleAccount[0] = alice;
        singleStatus[0] = true;
        lpUSDC.setTrustedOperator(singleAccount, singleStatus);

        // Setup - first deposit
        uint256 depositAmount = 100_000_000;
        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), depositAmount);
        uint256 mintedShares = lpUSDC.deposit(depositAmount);
        vm.stopPrank();

        // Record initial balance
        uint256 initialBobBalance = USDC.balanceOf(bob);

        // Distribute yield
        uint256 yieldAmount = 10_000_000; // 10 USDC yield
        deal(address(USDC), address(creditVault), USDC.balanceOf(address(creditVault)) + yieldAmount);

        vm.startPrank(address(creditVault));
        USDC.approve(address(lpUSDC), yieldAmount);
        lpUSDC.distributeYield(yieldAmount);
        vm.stopPrank();

        // Wait for minimum redeem interval
        vm.warp(block.timestamp + lpUSDC.minRedeemInterval() + 1);

        // Calculate expected redeem amount with yield and MINIMUM_SHARE dilution
        uint256 totalSharesBeforeRedeem = lpUSDC.totalShares();
        uint256 totalUnderlyingBeforeRedeem = lpUSDC.totalUnderlying();
        uint256 expectedRedeemAmount = (mintedShares * totalUnderlyingBeforeRedeem) / totalSharesBeforeRedeem;

        // Redeem all shares to bob
        vm.startPrank(alice);
        uint256 redeemedAmount = lpUSDC.redeemTo(mintedShares, bob);
        vm.stopPrank();

        // Verify redeemed amount includes yield
        assertEq(redeemedAmount, expectedRedeemAmount, "Incorrect redeemed amount with yield");
        assertEq(USDC.balanceOf(bob), initialBobBalance + redeemedAmount, "Incorrect final balance");
    }

    function test_withdrawEarlyFees() public {
        uint256 depositAmount = 100_000_000; // 100 USDC
        uint256 earlyWithdrawFeeBips = 100; // 1%

        // Setup early withdrawal fee and minimum deposit
        vm.startPrank(deployer);
        lpUSDC.setEarlyWithdrawFeeBips(earlyWithdrawFeeBips);
        lpUSDC.setMinDeposit(100); // Set minimum deposit to 0.0001 USDC
        vm.stopPrank();

        // Test 1: Try to withdraw when no fees have been accumulated
        {
            assertEq(lpUSDC.accEarlyWithdrawFee(), 0, "Should start with 0 accumulated fees");

            uint256 initialBalance = USDC.balanceOf(bob);
            vm.prank(deployer);
            lpUSDC.withdrawEarlyFees(bob);
            assertEq(lpUSDC.accEarlyWithdrawFee(), 0, "Should remain 0 when no fees");
            assertEq(USDC.balanceOf(bob), initialBalance, "Bob's balance should not change");
        }

        // Test 2: Access control and zero address validation
        {
            vm.startPrank(alice);
            USDC.approve(address(lpUSDC), depositAmount);
            uint256 shares = lpUSDC.deposit(depositAmount);
            lpUSDC.redeem(shares); // Early redeem to accumulate fees
            vm.stopPrank();

            // Non-owner should not be able to withdraw fees
            vm.prank(alice);
            vm.expectRevert("Ownable: caller is not the owner");
            lpUSDC.withdrawEarlyFees(bob);

            // Zero address validation
            vm.prank(deployer);
            vm.expectRevert(ErrorsLib.ZeroAddress.selector);
            lpUSDC.withdrawEarlyFees(address(0));

            // Reset accumulated fees for clean slate
            uint256 totalFees = lpUSDC.accEarlyWithdrawFee();
            if (totalFees > 0) {
                vm.startPrank(bob);
                USDC.approve(address(lpUSDC), totalFees * 2);
                lpUSDC.deposit(totalFees * 2);
                vm.stopPrank();

                vm.prank(deployer);
                lpUSDC.withdrawEarlyFees(bob);
            }
        }

        // Test 3: Alice's multiple early withdrawals with detailed tracking
        {
            uint256 expectedFees = lpUSDC.accEarlyWithdrawFee(); // Start from current state

            // Alice's first withdrawal
            uint256 amount1 = 50_000_000;
            vm.startPrank(alice);
            USDC.approve(address(lpUSDC), amount1);
            uint256 shares1 = lpUSDC.deposit(amount1);

            uint256 grossAmount = (shares1 * lpUSDC.totalUnderlying()) / lpUSDC.totalShares();
            uint256 expectedFee = (grossAmount * earlyWithdrawFeeBips) / 10_000;
            uint256 expectedNet = grossAmount - expectedFee;

            uint256 balanceBefore = USDC.balanceOf(alice);
            uint256 actualNet = lpUSDC.redeem(shares1);
            vm.stopPrank();

            assertEq(actualNet, expectedNet, "Alice's first withdrawal incorrect");
            assertEq(USDC.balanceOf(alice), balanceBefore + expectedNet, "Alice's balance incorrect");
            expectedFees += expectedFee;
            assertEq(lpUSDC.accEarlyWithdrawFee(), expectedFees, "Fee accumulation incorrect");

            // Alice's second withdrawal (reuse variables)
            uint256 amount2 = 80_000_000;
            vm.startPrank(alice);
            USDC.approve(address(lpUSDC), amount2);
            shares1 = lpUSDC.deposit(amount2); // Reuse shares1

            grossAmount = (shares1 * lpUSDC.totalUnderlying()) / lpUSDC.totalShares();
            expectedFee = (grossAmount * earlyWithdrawFeeBips) / 10_000;
            expectedNet = grossAmount - expectedFee;

            balanceBefore = USDC.balanceOf(alice);
            actualNet = lpUSDC.redeem(shares1);
            vm.stopPrank();

            assertEq(actualNet, expectedNet, "Alice's second withdrawal incorrect");
            expectedFees += expectedFee;
            assertEq(lpUSDC.accEarlyWithdrawFee(), expectedFees, "Fee accumulation after second withdrawal incorrect");
            assertEq(USDC.balanceOf(address(creditVault)), expectedFees + lpUSDC.totalUnderlying());
        }

        // Test 4: Bob and Charlie's withdrawals
        {
            uint256 currentFees = lpUSDC.accEarlyWithdrawFee();

            // Bob's withdrawal
            vm.warp(block.timestamp + 1 hours);
            uint256 bobAmount = 75_000_000;
            vm.startPrank(bob);
            USDC.approve(address(lpUSDC), bobAmount);
            uint256 bobShares = lpUSDC.deposit(bobAmount);

            uint256 bobGross = (bobShares * lpUSDC.totalUnderlying()) / lpUSDC.totalShares();
            uint256 bobFee = (bobGross * earlyWithdrawFeeBips) / 10_000;
            uint256 bobNet = bobGross - bobFee;

            uint256 bobBalanceBefore = USDC.balanceOf(bob);
            uint256 bobActualNet = lpUSDC.redeem(bobShares);
            vm.stopPrank();

            assertEq(bobActualNet, bobNet, "Bob's withdrawal incorrect");
            assertEq(USDC.balanceOf(bob), bobBalanceBefore + bobNet, "Bob's balance incorrect");
            currentFees += bobFee;
            assertEq(lpUSDC.accEarlyWithdrawFee(), currentFees, "Fee accumulation after Bob incorrect");

            // Charlie's withdrawal
            vm.warp(block.timestamp + 30 minutes);
            uint256 charlieAmount = 30_000_000;
            vm.startPrank(charlie);
            USDC.approve(address(lpUSDC), charlieAmount);
            bobShares = lpUSDC.deposit(charlieAmount);

            bobGross = (bobShares * lpUSDC.totalUnderlying()) / lpUSDC.totalShares();
            bobFee = (bobGross * earlyWithdrawFeeBips) / 10_000;
            bobNet = bobGross - bobFee;

            bobBalanceBefore = USDC.balanceOf(charlie);
            bobActualNet = lpUSDC.redeem(bobShares);
            vm.stopPrank();

            assertEq(bobActualNet, bobNet, "Charlie's withdrawal incorrect");
            assertEq(USDC.balanceOf(charlie), bobBalanceBefore + bobNet, "Charlie's balance incorrect");
            currentFees += bobFee;
            assertEq(lpUSDC.accEarlyWithdrawFee(), currentFees, "Final fee accumulation incorrect");
            assertEq(USDC.balanceOf(address(creditVault)), currentFees + lpUSDC.totalUnderlying());
        }

        // Test 5: Fee withdrawal
        {
            uint256 totalFees = lpUSDC.accEarlyWithdrawFee();
            assertTrue(totalFees > 0, "Should have accumulated fees");

            // Add sufficient balance for withdrawal
            uint256 additionalDeposit = totalFees * 2;
            vm.startPrank(bob);
            USDC.approve(address(lpUSDC), additionalDeposit);
            lpUSDC.deposit(additionalDeposit);
            vm.stopPrank();

            uint256 deployerBefore = USDC.balanceOf(deployer);
            vm.prank(deployer);
            lpUSDC.withdrawEarlyFees(deployer);

            assertEq(lpUSDC.accEarlyWithdrawFee(), 0, "Fees should be reset");
            assertEq(USDC.balanceOf(deployer), deployerBefore + totalFees, "Deployer should receive fees");
        }

        // Test 6: Normal redeem doesn't accumulate fees
        {
            vm.startPrank(alice);
            USDC.approve(address(lpUSDC), depositAmount);
            uint256 shares = lpUSDC.deposit(depositAmount);
            vm.warp(block.timestamp + lpUSDC.minRedeemInterval() + 1);
            lpUSDC.redeem(shares);
            vm.stopPrank();

            assertEq(lpUSDC.accEarlyWithdrawFee(), 0, "Normal redeems should not accumulate fees");
        }
    }

    function test_setTrustedOperator() public {
        uint256 depositAmount = 100_000_000; // 100 USDC

        // Test 1: Initially alice should not be a trusted operator
        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), depositAmount);
        vm.expectRevert(ErrorsLib.NotTrustedOperator.selector);
        lpUSDC.depositFor(bob, depositAmount);
        vm.stopPrank();

        // Test 2: Set alice as trusted operator (single address)
        vm.prank(deployer);
        singleAccount[0] = alice;
        singleStatus[0] = true;
        lpUSDC.setTrustedOperator(singleAccount, singleStatus);

        // Verify alice is now a trusted operator
        assertTrue(lpUSDC.trustedOperators(alice), "Alice should be a trusted operator");

        // Test 3: Alice should now be able to perform trusted operations
        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), depositAmount);
        uint256 shares = lpUSDC.depositFor(bob, depositAmount);
        assertTrue(shares > 0, "DepositFor should succeed for trusted operator");
        assertEq(lpUSDC.shares(bob), shares, "Bob should receive shares");

        // Alice also needs to deposit for herself to have shares for redeemTo test
        USDC.approve(address(lpUSDC), depositAmount);
        uint256 aliceShares = lpUSDC.deposit(depositAmount);

        // Wait for redeem interval and test redeemTo
        vm.warp(block.timestamp + lpUSDC.minRedeemInterval() + 1);
        uint256 charlieBalanceBefore = USDC.balanceOf(charlie);
        uint256 redeemAmount = lpUSDC.redeemTo(aliceShares, charlie);
        assertTrue(redeemAmount > 0, "RedeemTo should succeed for trusted operator");
        assertEq(
            USDC.balanceOf(charlie), charlieBalanceBefore + redeemAmount, "Charlie should receive the redeemed USDC"
        );
        vm.stopPrank();

        // Test 4: Remove alice's trusted operator status
        vm.prank(deployer);
        singleAccount[0] = alice;
        singleStatus[0] = false;
        lpUSDC.setTrustedOperator(singleAccount, singleStatus);

        // Verify alice is no longer a trusted operator
        assertFalse(lpUSDC.trustedOperators(alice), "Alice should not be a trusted operator");

        // Test 5: Alice should no longer be able to perform trusted operations
        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), depositAmount);
        vm.expectRevert(ErrorsLib.NotTrustedOperator.selector);
        lpUSDC.depositFor(bob, depositAmount);
        vm.stopPrank();

        // Test 6: Batch operation - set multiple trusted operators
        vm.prank(deployer);
        multiAccounts[0] = alice;
        multiAccounts[1] = charlie;
        multiStatuses[0] = true;
        multiStatuses[1] = true;
        lpUSDC.setTrustedOperator(multiAccounts, multiStatuses);

        // Verify both are trusted operators
        assertTrue(lpUSDC.trustedOperators(alice), "Alice should be trusted after batch operation");
        assertTrue(lpUSDC.trustedOperators(charlie), "Charlie should be trusted after batch operation");

        // Test 7: Both should be able to perform trusted operations
        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), depositAmount);
        shares = lpUSDC.depositFor(bob, depositAmount);
        assertTrue(shares > 0, "Alice should be able to depositFor");
        vm.stopPrank();

        vm.startPrank(charlie);
        USDC.approve(address(lpUSDC), depositAmount);
        shares = lpUSDC.depositFor(bob, depositAmount);
        assertTrue(shares > 0, "Charlie should be able to depositFor");
        vm.stopPrank();

        // Test 8: Batch operation - mixed statuses (one true, one false)
        vm.prank(deployer);
        multiAccounts[0] = alice;
        multiAccounts[1] = charlie;
        multiStatuses[0] = false; // Remove alice
        multiStatuses[1] = true; // Keep charlie
        lpUSDC.setTrustedOperator(multiAccounts, multiStatuses);

        // Verify statuses
        assertFalse(lpUSDC.trustedOperators(alice), "Alice should not be trusted");
        assertTrue(lpUSDC.trustedOperators(charlie), "Charlie should still be trusted");

        // Test 9: Only charlie should be able to perform trusted operations
        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), depositAmount);
        vm.expectRevert(ErrorsLib.NotTrustedOperator.selector);
        lpUSDC.depositFor(bob, depositAmount);
        vm.stopPrank();

        vm.startPrank(charlie);
        USDC.approve(address(lpUSDC), depositAmount);
        shares = lpUSDC.depositFor(bob, depositAmount);
        assertTrue(shares > 0, "Charlie should still be able to depositFor");
        vm.stopPrank();

        // Test 10: Only owner can set trusted operators
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        lpUSDC.setTrustedOperator(singleAccount, singleStatus);

        // Test 11: Cannot set zero address as trusted operator
        vm.prank(deployer);
        singleAccount[0] = address(0);
        singleStatus[0] = true;
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        lpUSDC.setTrustedOperator(singleAccount, singleStatus);
    }
}
