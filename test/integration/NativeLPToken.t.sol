// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {NativeLPToken} from "../../src/NativeLPToken.sol";
import {BaseTest} from "../BaseTest.t.sol";
import {ErrorsLib} from "../../src/libraries/ErrorsLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract NativeLPTokenTest is BaseTest {
    function setUp() public override {
        super.setUp();
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

        // Verify states
        assertEq(mintedShares, depositAmount, "Incorrect shares minted");
        assertEq(lpUSDC.totalShares(), initialTotalShares + depositAmount, "Incorrect total shares");
        assertEq(lpUSDC.totalUnderlying(), initialTotalUnderlying + depositAmount, "Incorrect total underlying");
        assertEq(USDC.balanceOf(alice), initialBalance - depositAmount, "Incorrect user balance");
        assertEq(USDC.balanceOf(address(creditVault)), initialVaultBalance + depositAmount, "Incorrect vault balance");
        assertEq(lpUSDC.shares(alice), depositAmount, "Incorrect user shares");
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
        lpUSDC.pause();

        // Try to deposit while paused
        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), 100_000_000);
        vm.expectRevert("Pausable: paused");
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

        // Second user deposits
        vm.startPrank(bob);
        USDC.approve(address(lpUSDC), 200_000_000);
        uint256 bobShares = lpUSDC.deposit(200_000_000);
        vm.stopPrank();

        // Verify share calculations
        assertEq(aliceShares, 100_000_000, "Incorrect shares for first user");
        assertEq(bobShares, 200_000_000, "Incorrect shares for second user");
        assertEq(lpUSDC.totalShares(), 300_000_000, "Incorrect total shares");
    }

    function test_redeem_success() public {
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
        uint256 initialBalance = USDC.balanceOf(alice);
        uint256 initialVaultBalance = USDC.balanceOf(address(creditVault));

        // Execute redeem
        uint256 redeemedAmount = lpUSDC.redeem(mintedShares);
        vm.stopPrank();

        // Verify states
        assertEq(redeemedAmount, depositAmount, "Incorrect redeemed amount");
        assertEq(lpUSDC.totalShares(), initialTotalShares - mintedShares, "Incorrect total shares");
        assertEq(lpUSDC.totalUnderlying(), initialTotalUnderlying - redeemedAmount, "Incorrect total underlying");
        assertEq(USDC.balanceOf(alice), initialBalance + redeemedAmount, "Incorrect user balance");
        assertEq(USDC.balanceOf(address(creditVault)), initialVaultBalance - redeemedAmount, "Incorrect vault balance");
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

        // Calculate expected amounts
        uint256 expectedFee = (depositAmount * earlyWithdrawFeeBips) / 10_000; // 1% of 100 USDC
        uint256 expectedRedeemAmount = depositAmount - expectedFee; // Should be 99 USDC

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
        lpUSDC.pause();

        // Try to redeem while paused
        vm.startPrank(alice);
        vm.expectRevert("Pausable: paused");
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
        uint256 expectedRedeemAmount = depositAmount / 2;

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

        // Calculate expected redeem amount with yield
        uint256 expectedRedeemAmount = depositAmount + yieldAmount;

        // Redeem all shares
        vm.startPrank(alice);
        uint256 redeemedAmount = lpUSDC.redeem(mintedShares);
        vm.stopPrank();

        // Verify redeemed amount includes yield
        assertEq(redeemedAmount, expectedRedeemAmount, "Incorrect redeemed amount with yield");
        assertEq(USDC.balanceOf(alice), initialBalance + redeemedAmount, "Incorrect final balance");
    }

    function test_setMinDeposit() public {
        // Get current minDeposit
        uint256 currentMinDeposit = lpUSDC.minDeposit();

        // Non-owner should not be able to set minDeposit
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        lpUSDC.setMinDeposit(1000);

        // Owner sets first value
        uint256 firstMinDeposit = 1000;
        vm.startPrank(deployer); // Ensure using deployer account
        vm.expectEmit(false, false, false, true, address(lpUSDC));
        emit NativeLPToken.MinDepositUpdated(currentMinDeposit, firstMinDeposit);
        lpUSDC.setMinDeposit(firstMinDeposit);
        assertEq(lpUSDC.minDeposit(), firstMinDeposit);

        // Owner updates to second value
        uint256 secondMinDeposit = 2000;
        vm.expectEmit(false, false, false, true, address(lpUSDC));
        emit NativeLPToken.MinDepositUpdated(firstMinDeposit, secondMinDeposit);
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
        vm.expectEmit(false, false, false, true, address(lpUSDC));
        emit NativeLPToken.MinRedeemIntervalUpdated(firstInterval);
        lpUSDC.setMinRedeemInterval(firstInterval);
        assertEq(lpUSDC.minRedeemInterval(), firstInterval);

        // Owner updates to second value
        uint256 secondInterval = 2 hours;
        vm.expectEmit(false, false, false, true, address(lpUSDC));
        emit NativeLPToken.MinRedeemIntervalUpdated(secondInterval);
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
        lpUSDC.pause();

        // Owner pauses the contract
        vm.startPrank(deployer);
        lpUSDC.pause();
        vm.stopPrank();

        // Attempt to deposit while paused
        vm.startPrank(alice);
        uint256 depositAmount = 100_000_000; // 100 USDC
        vm.expectRevert("Pausable: paused");
        lpUSDC.deposit(depositAmount);
        vm.stopPrank();

        // Attempt to redeem while paused
        vm.startPrank(alice);
        uint256 aliceShares = lpUSDC.shares(alice);
        vm.expectRevert("Pausable: paused");
        lpUSDC.redeem(aliceShares);
        vm.stopPrank();

        // Ensure only the owner can unpause
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        lpUSDC.unpause();

        // Owner unpauses the contract
        vm.startPrank(deployer);
        lpUSDC.unpause();
        vm.stopPrank();

        // Deposit should succeed after unpausing
        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), depositAmount); // 使用 underlying 替代 usdc
        lpUSDC.deposit(depositAmount);
        assertEq(lpUSDC.shares(alice), depositAmount); // Assuming 1:1 share ratio for simplicity
        vm.stopPrank();

        // Warp forward past the minimum redeem interval
        vm.warp(block.timestamp + lpUSDC.minRedeemInterval() + 1);

        // Redeem should succeed after unpausing
        vm.startPrank(alice);
        uint256 redeemAmount = lpUSDC.redeem(depositAmount);
        assertEq(redeemAmount, depositAmount);
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
        assertEq(aliceFirstShares, aliceFirstDeposit, "Alice's first shares incorrect");
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
        assertEq(
            lpUSDC.totalShares(),
            lpUSDC.shares(alice) + lpUSDC.shares(bob) + lpUSDC.shares(charlie),
            "Total shares incorrect"
        );
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

        // Verify total underlying includes both yields
        assertEq(
            lpUSDC.totalUnderlying(),
            depositAmount + firstYield + secondYield,
            "Incorrect total underlying after multiple yields"
        );
    }
}
