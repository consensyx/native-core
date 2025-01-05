// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BaseTest} from "../BaseTest.t.sol";
import {NativeLPToken} from "../../src/NativeLPToken.sol";
import {ErrorsLib} from "../../src/libraries/ErrorsLib.sol";

contract NativeLPTokenERC20Test is BaseTest {
    uint256 constant EIGHT_HOURS = 8 * 60 * 60;
    uint256 constant INITIAL_DEPOSIT = 1000e6; // 1000 USDC
    uint256 constant MIN_DEPOSIT = 1e6; // 1 USDC

    address carol;

    function setUp() public override {
        super.setUp();

        carol = makeAddr("carol");

        vm.startPrank(deployer);
        lpUSDC.setMinRedeemInterval(EIGHT_HOURS);
        lpUSDC.setMinDeposit(MIN_DEPOSIT); // Set min deposit to 1 USDC
        vm.stopPrank();

        // Setup initial deposit for testing transfers
        deal(address(USDC), alice, INITIAL_DEPOSIT);
        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), INITIAL_DEPOSIT);
        lpUSDC.deposit(INITIAL_DEPOSIT);
        vm.stopPrank();
    }

    function test_transfer_success() public {
        uint256 transferAmount = 500e6;

        // Record initial states
        uint256 aliceInitialBalance = lpUSDC.balanceOf(alice);
        uint256 aliceInitialShares = lpUSDC.sharesOf(alice);
        uint256 bobInitialBalance = lpUSDC.balanceOf(bob);
        uint256 bobInitialShares = lpUSDC.sharesOf(bob);

        vm.startPrank(alice);
        lpUSDC.transfer(bob, transferAmount);
        vm.stopPrank();

        // Verify balances after transfer
        assertEq(lpUSDC.balanceOf(alice), aliceInitialBalance - transferAmount, "Alice's balance not reduced correctly");
        assertEq(lpUSDC.balanceOf(bob), bobInitialBalance + transferAmount, "Bob's balance not increased correctly");

        // Verify shares after transfer
        uint256 expectedShares = lpUSDC.getSharesByUnderlying(transferAmount);
        assertEq(lpUSDC.sharesOf(alice), aliceInitialShares - expectedShares, "Alice's shares not reduced correctly");
        assertEq(lpUSDC.sharesOf(bob), bobInitialShares + expectedShares, "Bob's shares not increased correctly");

        // Verify total supply and shares remain unchanged
        assertEq(lpUSDC.totalSupply(), INITIAL_DEPOSIT, "Total supply should not change");
        assertEq(lpUSDC.totalShares(), INITIAL_DEPOSIT, "Total shares should not change");
    }

    function test_transfer_zeroAddress() public {
        vm.startPrank(alice);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        lpUSDC.transfer(address(0), 100e6);
        vm.stopPrank();
    }

    function test_transfer_toContract() public {
        vm.startPrank(alice);
        vm.expectRevert(ErrorsLib.TransferToContract.selector);
        lpUSDC.transfer(address(lpUSDC), 100e6);
        vm.stopPrank();
    }

    function test_transfer_toSelf() public {
        vm.startPrank(alice);
        vm.expectRevert(ErrorsLib.TransferSelf.selector);
        lpUSDC.transfer(alice, 100e6);
        vm.stopPrank();
    }

    function test_transfer_insufficientBalance() public {
        uint256 excessAmount = INITIAL_DEPOSIT + 1;

        vm.startPrank(alice);
        vm.expectRevert(ErrorsLib.InsufficientShares.selector);
        lpUSDC.transfer(bob, excessAmount);
        vm.stopPrank();
    }

    function test_transfer_zeroAmount() public {
        vm.startPrank(alice);
        // Zero amount transfers should succeed
        bool success = lpUSDC.transfer(bob, 0);
        assertTrue(success, "Zero amount transfer should succeed");
        vm.stopPrank();
    }

    function test_transfer_emitsEvents() public {
        uint256 transferAmount = 500e6;
        uint256 expectedShares = lpUSDC.getSharesByUnderlying(transferAmount);

        vm.startPrank(alice);
        vm.expectEmit(true, true, false, true, address(lpUSDC));
        emit IERC20.Transfer(alice, bob, transferAmount);
        vm.expectEmit(true, true, false, true, address(lpUSDC));
        emit NativeLPToken.TransferShares(alice, bob, expectedShares);
        lpUSDC.transfer(bob, transferAmount);
        vm.stopPrank();
    }

    function test_transfer_pausedState() public {
        // Pause the contract
        vm.prank(deployer);
        lpUSDC.pause();

        // Transfers should still work when paused
        vm.startPrank(alice);
        bool success = lpUSDC.transfer(bob, 100e6);
        assertTrue(success, "Transfer should work when paused");
        vm.stopPrank();
    }

    function test_transfer_withComplexExchangeRate() public {
        // Set minimum deposit to 0.001 USDC
        vm.prank(deployer);
        lpUSDC.setMinDeposit(1000); // 0.001 USDC = 1000 wei (6 decimals)

        // Setup 10 users with different deposit amounts
        address[10] memory users;
        uint256[10] memory depositAmounts;
        depositAmounts[0] = 1_111_111; // 1.111111 USDC
        depositAmounts[1] = 2_222_222; // 2.222222 USDC
        depositAmounts[2] = 3_333_333; // 3.333333 USDC
        depositAmounts[3] = 4_444_444; // 4.444444 USDC
        depositAmounts[4] = 5_555_555; // 5.555555 USDC
        depositAmounts[5] = 6_666_666; // 6.666666 USDC
        depositAmounts[6] = 7_777_777; // 7.777777 USDC
        depositAmounts[7] = 8_888_888; // 8.888888 USDC
        depositAmounts[8] = 9_999_999; // 9.999999 USDC
        depositAmounts[9] = 1_234_567; // 1.234567 USDC

        // Calculate expected total (including initial deposit)
        uint256 expectedTotal = 1_000_000_000; // Initial 1000 USDC
        for (uint256 i = 0; i < 10; i++) {
            expectedTotal += depositAmounts[i];
        }

        // Create users and fund them
        for (uint256 i = 0; i < 10; i++) {
            users[i] = makeAddr(string.concat("complex_user", vm.toString(i)));
            deal(address(USDC), users[i], depositAmounts[i]);

            // Deposit into LP token
            vm.startPrank(users[i]);
            USDC.approve(address(lpUSDC), depositAmounts[i]);
            lpUSDC.deposit(depositAmounts[i]);
            vm.stopPrank();
        }

        // Test multiple transfers with very small amounts relative to user's balance
        uint256[] memory transferAmounts = new uint256[](3);
        // Use a small percentage of first user's deposit as transfer amounts
        transferAmounts[0] = depositAmounts[0] / 10; // 10% of their deposit
        transferAmounts[1] = depositAmounts[0] / 20; // 5% of their deposit
        transferAmounts[2] = depositAmounts[0] / 40; // 2.5% of their deposit

        // Record initial states for first user
        uint256 user0InitialBalance = lpUSDC.balanceOf(users[0]);
        uint256 user0InitialShares = lpUSDC.sharesOf(users[0]);

        // Perform transfers from first user to several other users
        for (uint256 i = 0; i < transferAmounts.length; i++) {
            address recipient = users[i + 1];
            uint256 recipientInitialBalance = lpUSDC.balanceOf(recipient);
            uint256 recipientInitialShares = lpUSDC.sharesOf(recipient);
            uint256 expectedShares = lpUSDC.getSharesByUnderlying(transferAmounts[i]);

            // Execute transfer
            vm.prank(users[0]);
            lpUSDC.transfer(recipient, transferAmounts[i]);

            // Verify recipient's new balance and shares
            assertEq(
                lpUSDC.balanceOf(recipient),
                recipientInitialBalance + transferAmounts[i],
                string.concat("Recipient ", vm.toString(i), " balance incorrect")
            );
            assertEq(
                lpUSDC.sharesOf(recipient),
                recipientInitialShares + expectedShares,
                string.concat("Recipient ", vm.toString(i), " shares incorrect")
            );
        }

        // Calculate total amount transferred and shares
        uint256 totalTransferred = 0;
        uint256 totalSharesTransferred = 0;
        for (uint256 i = 0; i < transferAmounts.length; i++) {
            totalTransferred += transferAmounts[i];
            totalSharesTransferred += lpUSDC.getSharesByUnderlying(transferAmounts[i]);
        }

        // Verify final balance and shares of first user
        assertEq(lpUSDC.balanceOf(users[0]), user0InitialBalance - totalTransferred, "Sender final balance incorrect");
        assertEq(
            lpUSDC.sharesOf(users[0]), user0InitialShares - totalSharesTransferred, "Sender final shares incorrect"
        );

        // Verify total supply and shares remain unchanged
        assertEq(lpUSDC.totalUnderlying(), expectedTotal, "Total underlying should not change");
        assertEq(lpUSDC.totalShares(), expectedTotal, "Total shares should not change");
    }

    function test_transferFrom() public {
        // Ensure Alice has enough USDC
        deal(address(USDC), alice, 100_000 * 10 ** 6); // Add 100k USDC to Alice's balance

        // Alice approves lpUSDC to spend her USDC and deposits 100k USDC
        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), 100_000 * 10 ** 6);
        lpUSDC.deposit(100_000 * 10 ** 6);
        vm.stopPrank();

        // Record initial states
        uint256 aliceInitialBalance = lpUSDC.balanceOf(alice);
        uint256 aliceInitialShares = lpUSDC.sharesOf(alice);
        uint256 charlieInitialBalance = lpUSDC.balanceOf(charlie);
        uint256 charlieInitialShares = lpUSDC.sharesOf(charlie);

        // Alice approves Bob to spend 50k USDC worth of shares
        vm.startPrank(alice);
        lpUSDC.approve(bob, 50_000 * 10 ** 6);
        vm.stopPrank();

        // Bob transfers 50k USDC worth of shares from Alice to Charlie
        vm.startPrank(bob);
        uint256 transferAmount = 50_000 * 10 ** 6;
        uint256 expectedShares = lpUSDC.getSharesByUnderlying(transferAmount);
        bool success = lpUSDC.transferFrom(alice, charlie, transferAmount);
        assertTrue(success, "TransferFrom should succeed");
        vm.stopPrank();

        // Verify final states
        uint256 aliceFinalBalance = lpUSDC.balanceOf(alice);
        uint256 aliceFinalShares = lpUSDC.sharesOf(alice);
        uint256 charlieFinalBalance = lpUSDC.balanceOf(charlie);
        uint256 charlieFinalShares = lpUSDC.sharesOf(charlie);

        // Verify Alice's balance and shares
        assertEq(aliceFinalBalance, aliceInitialBalance - transferAmount, "Alice's balance incorrect");
        assertEq(aliceFinalShares, aliceInitialShares - expectedShares, "Alice's shares incorrect");

        // Verify Charlie's balance and shares
        assertEq(charlieFinalBalance, charlieInitialBalance + transferAmount, "Charlie's balance incorrect");
        assertEq(charlieFinalShares, charlieInitialShares + expectedShares, "Charlie's shares incorrect");

        // Verify allowance
        assertEq(lpUSDC.allowance(alice, bob), 0, "Bob's allowance should be zero");
    }

    function test_transferFrom_zeroAddress() public {
        // Ensure Alice has enough USDC
        deal(address(USDC), alice, 100_000 * 10 ** 6); // Add 100k USDC to Alice's balance

        // Alice approves lpUSDC to spend her USDC and deposits 100k USDC
        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), 100_000 * 10 ** 6);
        lpUSDC.deposit(100_000 * 10 ** 6);
        lpUSDC.approve(bob, 50_000 * 10 ** 6);
        vm.stopPrank();

        // Test transfer to zero address
        vm.startPrank(bob);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        lpUSDC.transferFrom(alice, address(0), 50_000 * 10 ** 6);
        vm.stopPrank();
    }

    function test_transferFrom_insufficientAllowance() public {
        // Ensure Alice has enough USDC
        deal(address(USDC), alice, 100_000 * 10 ** 6);

        // Alice approves lpUSDC to spend her USDC and deposits 100k USDC
        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), 100_000 * 10 ** 6);
        lpUSDC.deposit(100_000 * 10 ** 6);
        lpUSDC.approve(bob, 40_000 * 10 ** 6); // Approve less than transfer amount
        vm.stopPrank();

        // Ensure Bob tries to transfer more than approved amount
        vm.startPrank(bob);
        vm.expectRevert("ERC20: insufficient allowance");
        lpUSDC.transferFrom(alice, charlie, 50_000 * 10 ** 6);
        vm.stopPrank();
    }

    function test_transferFrom_insufficientBalance() public {
        // Ensure Alice has enough USDC
        deal(address(USDC), alice, 100_000 * 10 ** 6);

        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), 100_000 * 10 ** 6);
        lpUSDC.deposit(100_000 * 10 ** 6);
        lpUSDC.approve(bob, 200_000 * 10 ** 6); // Approve more than balance
        vm.stopPrank();

        vm.startPrank(bob);
        vm.expectRevert(ErrorsLib.InsufficientShares.selector);
        lpUSDC.transferFrom(alice, charlie, 150_000 * 10 ** 6); // Try to transfer more than balance
        vm.stopPrank();
    }

    function test_transferFrom_toSelf() public {
        // Ensure Alice has enough USDC
        deal(address(USDC), alice, 100_000 * 10 ** 6);

        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), 100_000 * 10 ** 6);
        lpUSDC.deposit(100_000 * 10 ** 6);
        lpUSDC.approve(bob, 50_000 * 10 ** 6);
        vm.stopPrank();

        vm.startPrank(bob);
        vm.expectRevert(ErrorsLib.TransferToContract.selector);
        lpUSDC.transferFrom(alice, address(lpUSDC), 50_000 * 10 ** 6);
        vm.stopPrank();
    }

    function test_transferFrom_zeroAmount() public {
        // Ensure Alice has enough USDC
        deal(address(USDC), alice, 100_000 * 10 ** 6);

        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), 100_000 * 10 ** 6);
        lpUSDC.deposit(100_000 * 10 ** 6);
        lpUSDC.approve(bob, 50_000 * 10 ** 6);
        vm.stopPrank();

        vm.startPrank(bob);
        bool success = lpUSDC.transferFrom(alice, charlie, 0);
        assertTrue(success, "Zero amount transferFrom should succeed");
        vm.stopPrank();
    }

    function test_transferFrom_noApproval() public {
        // Ensure Alice has enough USDC
        deal(address(USDC), alice, 100_000 * 10 ** 6);

        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), 100_000 * 10 ** 6);
        lpUSDC.deposit(100_000 * 10 ** 6);
        vm.stopPrank();

        vm.startPrank(bob);
        vm.expectRevert("ERC20: insufficient allowance");
        lpUSDC.transferFrom(alice, charlie, 50_000 * 10 ** 6);
        vm.stopPrank();
    }

    function test_transferFrom_afterApprovalRevoked() public {
        // Ensure Alice has enough USDC
        deal(address(USDC), alice, 100_000 * 10 ** 6);

        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), 100_000 * 10 ** 6);
        lpUSDC.deposit(100_000 * 10 ** 6);
        lpUSDC.approve(bob, 50_000 * 10 ** 6);
        lpUSDC.approve(bob, 0); // Revoke approval
        vm.stopPrank();

        vm.startPrank(bob);
        vm.expectRevert("ERC20: insufficient allowance");
        lpUSDC.transferFrom(alice, charlie, 50_000 * 10 ** 6);
        vm.stopPrank();
    }

    function test_approve_and_allowance() public {
        uint256 approvalAmount = 50_000 * 10 ** 6;

        // Initial allowance should be zero
        assertEq(lpUSDC.allowance(alice, bob), 0, "Initial allowance should be zero");

        // Test approve
        vm.startPrank(alice);
        bool success = lpUSDC.approve(bob, approvalAmount);
        assertTrue(success, "Approve should succeed");
        vm.stopPrank();

        // Verify allowance after approval
        assertEq(lpUSDC.allowance(alice, bob), approvalAmount, "Allowance not set correctly");

        // Test changing approval
        uint256 newApprovalAmount = 75_000 * 10 ** 6;
        vm.startPrank(alice);
        success = lpUSDC.approve(bob, newApprovalAmount);
        assertTrue(success, "Changing approval should succeed");
        vm.stopPrank();

        // Verify updated allowance
        assertEq(lpUSDC.allowance(alice, bob), newApprovalAmount, "Allowance not updated correctly");

        // Test revoking approval
        vm.startPrank(alice);
        success = lpUSDC.approve(bob, 0);
        assertTrue(success, "Revoking approval should succeed");
        vm.stopPrank();

        // Verify zero allowance after revocation
        assertEq(lpUSDC.allowance(alice, bob), 0, "Allowance should be zero after revocation");
    }

    function test_approve_zeroAddress() public {
        vm.startPrank(alice);
        vm.expectRevert("ERC20: approve to the zero address");
        lpUSDC.approve(address(0), 50_000 * 10 ** 6);
        vm.stopPrank();
    }

    function test_approve_emitsEvent() public {
        uint256 approvalAmount = 50_000 * 10 ** 6;

        vm.startPrank(alice);
        vm.expectEmit(true, true, false, true, address(lpUSDC));
        emit IERC20.Approval(alice, bob, approvalAmount);
        lpUSDC.approve(bob, approvalAmount);
        vm.stopPrank();
    }

    function test_approve_multipleApprovals() public {
        // Test approving multiple spenders
        vm.startPrank(alice);
        lpUSDC.approve(bob, 50_000 * 10 ** 6);
        lpUSDC.approve(charlie, 30_000 * 10 ** 6);
        vm.stopPrank();

        // Verify different allowances for different spenders
        assertEq(lpUSDC.allowance(alice, bob), 50_000 * 10 ** 6, "Bob's allowance incorrect");
        assertEq(lpUSDC.allowance(alice, charlie), 30_000 * 10 ** 6, "Charlie's allowance incorrect");

        // Verify allowances are independent
        vm.startPrank(alice);
        lpUSDC.approve(bob, 0);
        vm.stopPrank();

        assertEq(lpUSDC.allowance(alice, bob), 0, "Bob's allowance should be zero");
        assertEq(lpUSDC.allowance(alice, charlie), 30_000 * 10 ** 6, "Charlie's allowance should remain unchanged");
    }
}
