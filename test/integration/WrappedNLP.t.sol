// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {WrappedNLP} from "../../src/WrappedNLP.sol";
import {WithdrawQueue} from "../../src/WithdrawQueue.sol";
import {BaseTest} from "../BaseTest.t.sol";
import {ErrorsLib} from "../../src/libraries/ErrorsLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {console2 as console} from "forge-std/console2.sol";

contract WrappedNLPTest is BaseTest {
    WrappedNLP public wnlpUSDC;
    WrappedNLP public wnlpWETH;
    WithdrawQueue public queueUSDC;
    WithdrawQueue public queueWETH;

    uint256 constant MINIMUM_SHARE = 1000;
    uint256 constant INITIAL_DEPOSIT = 1000e6; // 1000 USDC
    uint256 constant INITIAL_DEPOSIT_WETH = 1e18; // 1 WETH
    uint256 constant AFF_FEE_CAP_BPS = 500;

    function setUp() public override {
        super.setUp();

        vm.startPrank(deployer);

        // Give deployer some ETH for testing
        vm.deal(deployer, 20 ether);

        // Deploy WrappedNLP contracts for USDC and WETH
        wnlpUSDC = new WrappedNLP(string.concat("Wrapped ", USDC.name()), string.concat("wNLP-", USDC.symbol()), lpUSDC);
        wnlpWETH = new WrappedNLP(string.concat("Wrapped ", weth.name()), string.concat("wNLP-", weth.symbol()), lpWETH);

        // Deploy WithdrawQueue contracts
        queueUSDC = new WithdrawQueue(wnlpUSDC, AFF_FEE_CAP_BPS);
        queueWETH = new WithdrawQueue(wnlpWETH, AFF_FEE_CAP_BPS);

        // Set WithdrawQueue contracts in WrappedNLP
        wnlpUSDC.setWithdrawQueue(address(queueUSDC));
        wnlpWETH.setWithdrawQueue(address(queueWETH));

        // Set WrappedNLP contracts as trusted operators so they can use redeemTo
        address[] memory accounts = new address[](2);
        bool[] memory statuses = new bool[](2);
        accounts[0] = address(wnlpUSDC);
        accounts[1] = address(wnlpWETH);
        statuses[0] = true;
        statuses[1] = true;

        // Set WrappedNLP contracts as trusted operators
        lpUSDC.setTrustedOperator(accounts, statuses);
        lpWETH.setTrustedOperator(accounts, statuses);

        // Set WrappedNLP contracts as exempt from cooldown restrictions
        lpUSDC.setRedeemCooldownExempt(accounts, statuses);
        lpWETH.setRedeemCooldownExempt(accounts, statuses);

        // Set NLP token cooldown period to 1 day
        lpUSDC.setMinRedeemInterval(1 days);
        lpWETH.setMinRedeemInterval(1 days);

        // Setup test balances
        USDC.mint(alice, 10_000e6);
        USDC.mint(bob, 10_000e6);
        USDC.mint(charlie, 10_000e6);

        weth.deposit{value: 10 ether}();
        weth.transfer(alice, 5 ether);
        weth.transfer(bob, 3 ether);
        weth.transfer(charlie, 2 ether);

        vm.stopPrank();

        // Setup approvals for WrappedNLP to transfer NLP tokens from users
        vm.startPrank(alice);
        IERC20(lpUSDC).approve(address(wnlpUSDC), type(uint256).max);
        IERC20(lpWETH).approve(address(wnlpWETH), type(uint256).max);
        USDC.approve(address(wnlpUSDC), type(uint256).max);
        weth.approve(address(wnlpWETH), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        IERC20(lpUSDC).approve(address(wnlpUSDC), type(uint256).max);
        IERC20(lpWETH).approve(address(wnlpWETH), type(uint256).max);
        USDC.approve(address(wnlpUSDC), type(uint256).max);
        weth.approve(address(wnlpWETH), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(charlie);
        IERC20(lpUSDC).approve(address(wnlpUSDC), type(uint256).max);
        IERC20(lpWETH).approve(address(wnlpWETH), type(uint256).max);
        USDC.approve(address(wnlpUSDC), type(uint256).max);
        weth.approve(address(wnlpWETH), type(uint256).max);
        vm.stopPrank();
    }

    // ============================
    // Constructor Tests
    // ============================

    function test_constructor() public view {
        assertEq(address(wnlpUSDC.nlp()), address(lpUSDC));
        assertEq(address(wnlpUSDC.underlying()), address(USDC));
        assertEq(wnlpUSDC.name(), string.concat("Wrapped ", USDC.name()));
        assertEq(wnlpUSDC.symbol(), string.concat("wNLP-", USDC.symbol()));
        assertEq(wnlpUSDC.decimals(), USDC.decimals());
        assertEq(wnlpUSDC.feeRecipient(), deployer);
        assertEq(wnlpUSDC.instantRedeemFeeBips(), lpUSDC.earlyWithdrawFeeBips());
        assertEq(address(wnlpUSDC.withdrawQueue()), address(queueUSDC));
    }

    // ============================
    // depositAndWrap Tests
    // ============================

    function test_depositAndWrap_success() public {
        vm.startPrank(alice);

        uint256 initialBalance = USDC.balanceOf(alice);
        uint256 initialVaultBalance = USDC.balanceOf(address(creditVault));

        uint256 wNLPReceived = wnlpUSDC.depositAndWrap(alice, INITIAL_DEPOSIT);

        assertEq(USDC.balanceOf(alice), initialBalance - INITIAL_DEPOSIT);
        assertEq(USDC.balanceOf(address(creditVault)), initialVaultBalance + INITIAL_DEPOSIT);
        assertEq(wnlpUSDC.balanceOf(alice), wNLPReceived);
        // First deposit should mint (amount - MINIMUM_SHARE) wNLP
        assertEq(wNLPReceived, INITIAL_DEPOSIT - MINIMUM_SHARE);

        vm.stopPrank();
    }

    function test_depositAndWrap_toOtherAddress() public {
        vm.startPrank(alice);

        uint256 bobInitialBalance = wnlpUSDC.balanceOf(bob);

        uint256 wNLPReceived = wnlpUSDC.depositAndWrap(bob, INITIAL_DEPOSIT);

        assertEq(wnlpUSDC.balanceOf(bob), bobInitialBalance + wNLPReceived);
        assertEq(wnlpUSDC.balanceOf(alice), 0);

        vm.stopPrank();
    }

    function test_depositAndWrap_zeroAmount() public {
        vm.startPrank(alice);

        vm.expectRevert(ErrorsLib.ZeroAmount.selector);
        wnlpUSDC.depositAndWrap(alice, 0);

        vm.stopPrank();
    }

    function test_depositAndWrap_zeroAddress() public {
        vm.startPrank(alice);

        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        wnlpUSDC.depositAndWrap(address(0), INITIAL_DEPOSIT);

        vm.stopPrank();
    }

    function test_depositAndWrap_multipleDeposits() public {
        // Alice's first deposit
        vm.startPrank(alice);
        uint256 aliceWNLP1 = wnlpUSDC.depositAndWrap(alice, INITIAL_DEPOSIT);
        uint256 aliceBalanceAfterFirst = wnlpUSDC.balanceOf(alice);
        assertEq(aliceWNLP1, INITIAL_DEPOSIT - MINIMUM_SHARE); // First deposit loses MINIMUM_SHARE
        vm.stopPrank();

        // Bob deposits different amount (2x Alice's amount)
        vm.startPrank(bob);
        uint256 bobDepositAmount = 2000e6; // 2000 USDC
        uint256 bobWNLP = wnlpUSDC.depositAndWrap(bob, bobDepositAmount);
        assertEq(bobWNLP, (aliceWNLP1 + MINIMUM_SHARE) * 2);
        vm.stopPrank();

        // Alice's second deposit
        vm.startPrank(alice);
        uint256 aliceSecondDeposit = 500e6; // 500 USDC
        uint256 aliceWNLP2 = wnlpUSDC.depositAndWrap(alice, aliceSecondDeposit);
        uint256 aliceBalanceAfterSecond = wnlpUSDC.balanceOf(alice);
        // Alice's total should be sum of both deposits
        assertEq(aliceBalanceAfterSecond, aliceBalanceAfterFirst + aliceWNLP2);
        assertEq(aliceWNLP2, (aliceWNLP1 + MINIMUM_SHARE) / 2);
        vm.stopPrank();

        // Charlie deposits even larger amount
        vm.startPrank(charlie);
        uint256 charlieDepositAmount = 3000e6;
        uint256 charlieWNLP = wnlpUSDC.depositAndWrap(charlie, charlieDepositAmount);
        assertEq(charlieWNLP, (aliceWNLP1 + MINIMUM_SHARE) * 3);
        vm.stopPrank();

        // Verify final balances
        uint256 totalAliceDeposit = INITIAL_DEPOSIT + aliceSecondDeposit;
        uint256 totalBobDeposit = bobDepositAmount;
        uint256 totalCharlieDeposit = charlieDepositAmount;

        assertEq(wnlpUSDC.balanceOf(alice), aliceWNLP1 + aliceWNLP2);
        assertEq(wnlpUSDC.balanceOf(bob), bobWNLP);
        assertEq(wnlpUSDC.balanceOf(charlie), charlieWNLP);

        // Verify total supply matches sum of all deposits minus MINIMUM_SHARE
        uint256 totalDeposited = totalAliceDeposit + totalBobDeposit + totalCharlieDeposit;
        assertEq(wnlpUSDC.totalSupply(), totalDeposited - MINIMUM_SHARE);
    }

    function test_depositAndWrap_irregularAmounts() public {
        uint256 aliceFirstWNLP;
        uint256 bobFirstWNLP;
        uint256 totalDeposited;

        // Alice's first deposit (1,111,111)
        {
            uint256 amount = 1_111_111;
            vm.startPrank(alice);
            aliceFirstWNLP = wnlpUSDC.depositAndWrap(alice, amount);
            assertEq(aliceFirstWNLP, amount - MINIMUM_SHARE);
            vm.stopPrank();
            totalDeposited = amount;
        }

        // Bob deposits (2,222,222 - exactly 2x Alice's amount)
        {
            uint256 amount = 2_222_222;
            vm.startPrank(bob);
            bobFirstWNLP = wnlpUSDC.depositAndWrap(bob, amount);
            // Bob deposits 2x, should get 2x shares
            assertEq(bobFirstWNLP, (aliceFirstWNLP + MINIMUM_SHARE) * 2);
            // Verify: Bob's amount is 2x Alice's amount
            vm.stopPrank();
            totalDeposited += amount;
        }

        // Alice's second deposit (333,333 - 3x of base unit 111,111)
        {
            uint256 amount = 333_333;
            vm.startPrank(alice);
            uint256 aliceBalanceBefore = wnlpUSDC.balanceOf(alice);
            uint256 aliceSecondWNLP = wnlpUSDC.depositAndWrap(alice, amount);
            assertEq(aliceSecondWNLP, amount);
            assertEq(wnlpUSDC.balanceOf(alice), aliceBalanceBefore + aliceSecondWNLP);
            vm.stopPrank();
            totalDeposited += amount;
        }

        // Bob's second deposit (555,555 - 5x of base unit 111,111)
        {
            uint256 amount = 555_555;
            vm.startPrank(bob);
            uint256 bobBalanceBefore = wnlpUSDC.balanceOf(bob);
            uint256 bobSecondWNLP = wnlpUSDC.depositAndWrap(bob, amount);
            assertEq(bobSecondWNLP, amount);
            assertEq(wnlpUSDC.balanceOf(bob), bobBalanceBefore + bobSecondWNLP);
            vm.stopPrank();
            totalDeposited += amount;
        }

        // Charlie deposits (4,444,444 - exactly 4x Bob's first deposit)
        {
            uint256 amount = 4_444_444;
            vm.startPrank(charlie);
            uint256 charlieWNLP = wnlpUSDC.depositAndWrap(charlie, amount);
            assertEq(charlieWNLP, amount);
            // Verify: Charlie gets 2x Bob's first wNLP
            assertEq(charlieWNLP, bobFirstWNLP * 2);
            vm.stopPrank();
            totalDeposited += amount;
        }

        assertEq(wnlpUSDC.totalSupply(), totalDeposited - MINIMUM_SHARE);

        // Verify individual balances sum up correctly
        uint256 totalBalances = wnlpUSDC.balanceOf(alice) + wnlpUSDC.balanceOf(bob) + wnlpUSDC.balanceOf(charlie);
        assertEq(totalBalances, wnlpUSDC.totalSupply());
    }

    // ============================
    // wrap Tests
    // ============================

    function test_wrap_success() public {
        // Bob is the first depositor
        vm.startPrank(bob);
        USDC.approve(address(lpUSDC), INITIAL_DEPOSIT * 2);
        uint256 bobNlpShares = lpUSDC.deposit(INITIAL_DEPOSIT * 2);
        vm.stopPrank();

        // Alice deposits to get NLP (not first depositor)
        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), INITIAL_DEPOSIT * 3);
        uint256 aliceNlpShares = lpUSDC.deposit(INITIAL_DEPOSIT * 3);
        vm.stopPrank();

        // Charlie also deposits
        vm.startPrank(charlie);
        USDC.approve(address(lpUSDC), INITIAL_DEPOSIT);
        uint256 charlieNlpShares = lpUSDC.deposit(INITIAL_DEPOSIT);
        vm.stopPrank();

        // Wait for cooldown period
        vm.warp(block.timestamp + 1 days + 1);

        // Alice wraps only part of her NLP (60% of her balance)
        vm.startPrank(alice);
        uint256 initialAliceNLP = lpUSDC.balanceOf(alice);
        assertEq(initialAliceNLP, aliceNlpShares);

        uint256 amountToWrap = (aliceNlpShares * 60) / 100;
        uint256 wNLPReceived = wnlpUSDC.wrap(amountToWrap);

        // Alice should have 40% NLP remaining
        assertEq(lpUSDC.balanceOf(alice), aliceNlpShares - amountToWrap);
        assertEq(wnlpUSDC.balanceOf(alice), wNLPReceived);
        assertEq(wNLPReceived, amountToWrap);
        vm.stopPrank();

        // Bob wraps 75% of his NLP
        vm.startPrank(bob);
        uint256 bobAmountToWrap = (bobNlpShares * 75) / 100;
        uint256 bobWNLPReceived = wnlpUSDC.wrap(bobAmountToWrap);

        assertEq(lpUSDC.balanceOf(bob), bobNlpShares - bobAmountToWrap);
        assertEq(wnlpUSDC.balanceOf(bob), bobWNLPReceived);
        assertEq(bobWNLPReceived, bobAmountToWrap);
        vm.stopPrank();

        // Charlie wraps all his NLP
        vm.startPrank(charlie);
        uint256 charlieWNLPReceived = wnlpUSDC.wrap(charlieNlpShares);

        assertEq(lpUSDC.balanceOf(charlie), 0);
        assertEq(wnlpUSDC.balanceOf(charlie), charlieWNLPReceived);
        assertEq(charlieWNLPReceived, charlieNlpShares);
        vm.stopPrank();

        // Verify total wNLP supply equals sum of all wrapped amounts
        assertEq(wnlpUSDC.totalSupply(), wNLPReceived + bobWNLPReceived + charlieWNLPReceived);
    }

    function test_wrap_withExchangeRateIncrease() public {
        // Mint sufficient USDC for deployer to simulate yield distribution
        vm.prank(deployer);
        USDC.mint(deployer, 10_000_000 * 1e6); // 10M USDC for yield simulation

        uint256 aliceNlpShares1;
        uint256 bobNlpShares1;
        address vault = lpUSDC.creditVault();

        // Phase 1: Initial deposits to establish the pool
        // Alice and Bob each have 10,000 USDC from setup
        {
            vm.startPrank(alice);
            USDC.approve(address(lpUSDC), 5000 * 1e6);
            aliceNlpShares1 = lpUSDC.deposit(5000 * 1e6);
            vm.stopPrank();

            vm.startPrank(bob);
            USDC.approve(address(lpUSDC), 8000 * 1e6);
            bobNlpShares1 = lpUSDC.deposit(8000 * 1e6);
            vm.stopPrank();
        }

        // Record initial state
        uint256 initialExchangeRate = lpUSDC.exchangeRate();
        uint256 initialTotalUnderlying = lpUSDC.totalUnderlying();

        // Phase 2: Simulate yield distribution (increases exchange rate)
        // Mock vault to distribute 10% yield to the pool
        {
            uint256 yieldAmount = initialTotalUnderlying / 10; // 10% yield

            // Vault distributes yield
            vm.prank(vault);
            lpUSDC.distributeYield(yieldAmount);
        }

        // Verify exchange rate increased
        uint256 newExchangeRate = lpUSDC.exchangeRate();

        assertEq(newExchangeRate, (initialExchangeRate * 11) / 10);

        // Shares remain the same after yield distribution
        assertEq(lpUSDC.sharesOf(alice), aliceNlpShares1);
        assertEq(lpUSDC.sharesOf(bob), bobNlpShares1);

        // Wait for cooldown period
        vm.warp(block.timestamp + 1 days + 1);

        uint256 aliceWNLP1;

        // Phase 3: Alice wraps 50% of her NLP balance after yield accrual
        {
            vm.startPrank(alice);
            uint256 aliceNLPBalance = lpUSDC.balanceOf(alice);

            // Alice wraps 50% of her NLP balance (in underlying terms)
            uint256 nlpAmountToWrap = aliceNLPBalance / 2;
            aliceWNLP1 = wnlpUSDC.wrap(nlpAmountToWrap);

            // wNLP amount should equal the shares actually transferred
            uint256 expectedShares = lpUSDC.getSharesByUnderlying(nlpAmountToWrap);
            assertEq(aliceWNLP1, expectedShares);

            // Underlying value should match
            uint256 underlyingValue = lpUSDC.getUnderlyingByShares(aliceWNLP1);
            uint256 wnlpUnderlyingValue = wnlpUSDC.getNlpByWnlp(aliceWNLP1);
            assertApproxEqAbs(underlyingValue, wnlpUnderlyingValue, 1);

            // The underlying value should be more than shares count due to yield
            assertGt(underlyingValue, aliceWNLP1);
            vm.stopPrank();
        }

        // Phase 4: Another round of yield distribution
        {
            uint256 currentTotalUnderlying = lpUSDC.totalUnderlying();
            uint256 yieldAmount2 = currentTotalUnderlying / 20; // 5% more yield

            vm.prank(vault);
            lpUSDC.distributeYield(yieldAmount2);
        }

        // Exchange rate should have increased again
        uint256 exchangeRateAfterSecondYield = lpUSDC.exchangeRate();
        assertGt(exchangeRateAfterSecondYield, newExchangeRate);

        uint256 bobWNLP1;

        // Phase 5: Bob wraps 80% of his NLP balance after second yield
        {
            vm.startPrank(bob);
            uint256 bobNLPBalance = lpUSDC.balanceOf(bob);

            uint256 bobNlpToWrap = (bobNLPBalance * 80) / 100;
            bobWNLP1 = wnlpUSDC.wrap(bobNlpToWrap);

            uint256 expectedShares = lpUSDC.getSharesByUnderlying(bobNlpToWrap);
            assertEq(bobWNLP1, expectedShares);

            uint256 bobUnderlyingValue = lpUSDC.getUnderlyingByShares(bobWNLP1);
            uint256 bobWNLPUnderlyingValue = wnlpUSDC.getNlpByWnlp(bobWNLP1);
            assertApproxEqAbs(bobUnderlyingValue, bobWNLPUnderlyingValue, 1);

            vm.stopPrank();
        }

        // Phase 6: Alice wraps her remaining NLP balance
        {
            vm.startPrank(alice);
            uint256 aliceRemainingNLP = lpUSDC.balanceOf(alice);
            uint256 aliceWNLP2 = wnlpUSDC.wrap(aliceRemainingNLP);

            // Alice's total wNLP (in shares) should equal her original NLP shares (with rounding tolerance)
            uint256 aliceTotalWNLP = wnlpUSDC.balanceOf(alice);
            assertEq(aliceTotalWNLP, aliceWNLP1 + aliceWNLP2);
            assertApproxEqAbs(aliceTotalWNLP, aliceNlpShares1, 1);
            // Alice should have 0 or dust amount of NLP shares left due to rounding
            assertApproxEqAbs(lpUSDC.sharesOf(alice), 0, 1);
            vm.stopPrank();
        }

        // Final verification: wNLP underlying value consistency
        {
            uint256 totalWNLP = wnlpUSDC.totalSupply();
            uint256 totalWNLPUnderlying = wnlpUSDC.getNlpByWnlp(totalWNLP);
            uint256 wrappedNLPUnderlying = lpUSDC.getUnderlyingByShares(totalWNLP);

            assertApproxEqAbs(totalWNLPUnderlying, wrappedNLPUnderlying, 10);

            // Verify individual holdings match their share amounts (with rounding tolerance)
            assertApproxEqAbs(wnlpUSDC.balanceOf(alice), aliceNlpShares1, 1);
            assertEq(wnlpUSDC.balanceOf(bob), bobWNLP1);
        }
    }

    function test_wrap_zeroAmount() public {
        vm.startPrank(alice);

        vm.expectRevert(ErrorsLib.ZeroAmount.selector);
        wnlpUSDC.wrap(0);

        vm.stopPrank();
    }

    // ============================
    // unwrapAndRedeem Tests (via WithdrawQueue)
    // ============================

    function test_unwrapAndRedeem_onlyWithdrawQueue() public {
        // Setup: Alice deposits and wraps
        vm.startPrank(alice);
        uint256 wNLPAmount = wnlpUSDC.depositAndWrap(alice, INITIAL_DEPOSIT);
        vm.stopPrank();

        // Try to call unwrapAndRedeem directly (should fail)
        vm.startPrank(alice);
        vm.expectRevert(ErrorsLib.NotTrustedOperator.selector);
        wnlpUSDC.unwrapAndRedeem(wNLPAmount, alice);
        vm.stopPrank();
    }

    function test_unwrapAndRedeem_viaWhitelist() public {
        // Setup: Alice deposits and wraps
        vm.startPrank(alice);
        uint256 wNLPAmount = wnlpUSDC.depositAndWrap(alice, INITIAL_DEPOSIT);
        vm.stopPrank();

        // Add Alice to whitelist
        vm.startPrank(deployer);
        address[] memory accounts = new address[](1);
        bool[] memory statuses = new bool[](1);
        accounts[0] = alice;
        statuses[0] = true;
        wnlpUSDC.setRedeemWhitelist(accounts, statuses);
        vm.stopPrank();

        // Now Alice can call unwrapAndRedeem
        vm.startPrank(alice);
        uint256 initialUSDC = USDC.balanceOf(alice);

        wnlpUSDC.unwrapAndRedeem(wNLPAmount, alice);

        assertEq(USDC.balanceOf(alice), initialUSDC + INITIAL_DEPOSIT - MINIMUM_SHARE);
        assertEq(wnlpUSDC.balanceOf(alice), 0);
        vm.stopPrank();
    }

    function test_unwrapAndRedeem_zeroAmount() public {
        // Add Alice to whitelist
        vm.startPrank(deployer);
        address[] memory accounts = new address[](1);
        bool[] memory statuses = new bool[](1);
        accounts[0] = alice;
        statuses[0] = true;
        wnlpUSDC.setRedeemWhitelist(accounts, statuses);
        vm.stopPrank();

        vm.startPrank(alice);
        vm.expectRevert(ErrorsLib.ZeroAmount.selector);
        wnlpUSDC.unwrapAndRedeem(0, alice);
        vm.stopPrank();
    }

    function test_unwrapAndRedeem_zeroAddress() public {
        // Setup: Alice deposits and wraps
        vm.startPrank(alice);
        uint256 wNLPAmount = wnlpUSDC.depositAndWrap(alice, INITIAL_DEPOSIT);
        vm.stopPrank();

        // Add Alice to whitelist
        vm.startPrank(deployer);
        address[] memory accounts = new address[](1);
        bool[] memory statuses = new bool[](1);
        accounts[0] = alice;
        statuses[0] = true;
        wnlpUSDC.setRedeemWhitelist(accounts, statuses);
        vm.stopPrank();

        vm.startPrank(alice);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        wnlpUSDC.unwrapAndRedeem(wNLPAmount, address(0));
        vm.stopPrank();
    }

    // ============================
    // instantRedeem Tests
    // ============================

    function test_instantRedeem_success() public {
        // Setup: Ensure fee is set to a known value (e.g., 1% = 100 bips)
        vm.prank(deployer);
        wnlpUSDC.setInstantRedeemFeeBips(100);

        // Alice deposits and wraps
        vm.startPrank(alice);
        uint256 depositAmount = INITIAL_DEPOSIT; // 1000e6 USDC
        uint256 wNLPAmount = wnlpUSDC.depositAndWrap(alice, depositAmount);

        // wNLP amount should equal deposit minus locked MINIMUM_SHARE for first deposit
        assertEq(wNLPAmount, depositAmount - MINIMUM_SHARE);

        uint256 aliceUSDCBefore = USDC.balanceOf(alice);
        uint256 feeReceiverBalanceBefore = USDC.balanceOf(deployer);

        // Instant redeem all wNLP
        uint256 redeemedAmount = wnlpUSDC.instantRedeem(wNLPAmount, alice);

        // Calculate expected amounts with 1% fee
        uint256 underlyingAmount = lpUSDC.getUnderlyingByShares(wNLPAmount);
        uint256 expectedFee = (underlyingAmount * 100) / 10_000; // 1% fee
        uint256 expectedNetAmount = underlyingAmount - expectedFee;

        // Verify redeemed amount matches expected net amount
        assertEq(redeemedAmount, expectedNetAmount);

        // Verify Alice received the correct amount
        assertEq(USDC.balanceOf(alice) - aliceUSDCBefore, expectedNetAmount);

        // Verify wNLP balance is zero
        assertEq(wnlpUSDC.balanceOf(alice), 0);

        // Verify fee was collected correctly
        uint256 feeCollected = USDC.balanceOf(deployer) - feeReceiverBalanceBefore;

        assertEq(feeCollected, expectedFee);

        vm.stopPrank();
    }

    function test_instantRedeem_withZeroFee() public {
        // Set fee to 0
        vm.startPrank(deployer);
        wnlpUSDC.setInstantRedeemFeeBips(0);
        vm.stopPrank();

        // Setup: Alice deposits and wraps
        vm.startPrank(alice);
        uint256 depositAmount = INITIAL_DEPOSIT;
        uint256 wNLPAmount = wnlpUSDC.depositAndWrap(alice, depositAmount);

        uint256 aliceUSDCBefore = USDC.balanceOf(alice);
        uint256 feeReceiverBalanceBefore = USDC.balanceOf(deployer);

        // Instant redeem with zero fee
        uint256 redeemedAmount = wnlpUSDC.instantRedeem(wNLPAmount, alice);

        // Calculate expected amount (no fee)
        uint256 expectedAmount = lpUSDC.getUnderlyingByShares(wNLPAmount);

        // Verify redeemed amount equals full underlying amount (no fee deducted)
        assertEq(redeemedAmount, expectedAmount);

        // Verify Alice received the full amount
        assertEq(USDC.balanceOf(alice) - aliceUSDCBefore, expectedAmount);

        // Verify no fee was collected
        assertEq(USDC.balanceOf(deployer), feeReceiverBalanceBefore);

        // Verify wNLP balance is zero
        assertEq(wnlpUSDC.balanceOf(alice), 0);

        vm.stopPrank();
    }

    function test_instantRedeem_belowMinimum() public {
        vm.startPrank(alice);
        wnlpUSDC.depositAndWrap(alice, INITIAL_DEPOSIT);

        // Try to redeem less than MIN_INSTANT_REDEEM_AMOUNT (1000)
        vm.expectRevert("Below minimum instant redeem amount");
        wnlpUSDC.instantRedeem(999, alice);

        vm.stopPrank();
    }

    function test_instantRedeem_zeroAddress() public {
        vm.startPrank(alice);

        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        wnlpUSDC.instantRedeem(1000e6, address(0));

        vm.stopPrank();
    }

    // ============================
    // Admin Functions Tests
    // ============================

    function test_setWithdrawQueue_success() public {
        WithdrawQueue newQueue = new WithdrawQueue(wnlpUSDC, AFF_FEE_CAP_BPS);

        vm.startPrank(deployer);

        wnlpUSDC.setWithdrawQueue(address(newQueue));

        assertEq(address(wnlpUSDC.withdrawQueue()), address(newQueue));

        vm.stopPrank();
    }

    function test_setWithdrawQueue_zeroAddress() public {
        vm.startPrank(deployer);

        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        wnlpUSDC.setWithdrawQueue(address(0));

        vm.stopPrank();
    }

    function test_setWithdrawQueue_onlyOwner() public {
        WithdrawQueue newQueue = new WithdrawQueue(wnlpUSDC, AFF_FEE_CAP_BPS);

        vm.startPrank(alice);

        vm.expectRevert();
        wnlpUSDC.setWithdrawQueue(address(newQueue));

        vm.stopPrank();
    }

    function test_setRedeemWhitelist_success() public {
        vm.startPrank(deployer);

        address[] memory accounts = new address[](2);
        bool[] memory statuses = new bool[](2);
        accounts[0] = alice;
        accounts[1] = bob;
        statuses[0] = true;
        statuses[1] = true;

        wnlpUSDC.setRedeemWhitelist(accounts, statuses);

        assertTrue(wnlpUSDC.redeemWhitelist(alice));
        assertTrue(wnlpUSDC.redeemWhitelist(bob));

        vm.stopPrank();
    }

    function test_setRedeemWhitelist_remove() public {
        // First add Alice to whitelist
        vm.startPrank(deployer);
        address[] memory accounts = new address[](1);
        bool[] memory statuses = new bool[](1);
        accounts[0] = alice;
        statuses[0] = true;
        wnlpUSDC.setRedeemWhitelist(accounts, statuses);
        assertTrue(wnlpUSDC.redeemWhitelist(alice));

        // Now remove Alice
        statuses[0] = false;
        wnlpUSDC.setRedeemWhitelist(accounts, statuses);
        assertFalse(wnlpUSDC.redeemWhitelist(alice));

        vm.stopPrank();
    }

    function test_setRedeemWhitelist_zeroAddress() public {
        vm.startPrank(deployer);

        address[] memory accounts = new address[](1);
        bool[] memory statuses = new bool[](1);
        accounts[0] = address(0);
        statuses[0] = true;

        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        wnlpUSDC.setRedeemWhitelist(accounts, statuses);

        vm.stopPrank();
    }

    function test_setRedeemWhitelist_onlyOwner() public {
        vm.startPrank(alice);

        address[] memory accounts = new address[](1);
        bool[] memory statuses = new bool[](1);
        accounts[0] = bob;
        statuses[0] = true;

        vm.expectRevert();
        wnlpUSDC.setRedeemWhitelist(accounts, statuses);

        vm.stopPrank();
    }

    function test_setFeeRecipient() public {
        // Non-owner cannot set
        vm.prank(alice);
        vm.expectRevert();
        wnlpUSDC.setFeeRecipient(bob);

        // Cannot set zero address
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        wnlpUSDC.setFeeRecipient(address(0));

        // Owner can set valid address
        vm.prank(deployer);
        wnlpUSDC.setFeeRecipient(alice);
        assertEq(wnlpUSDC.feeRecipient(), alice);
    }

    function test_setInstantRedeemFeeBips() public {
        // Non-owner cannot set
        vm.prank(alice);
        vm.expectRevert();
        wnlpUSDC.setInstantRedeemFeeBips(500);

        // Owner can set normal value (5%)
        vm.prank(deployer);
        wnlpUSDC.setInstantRedeemFeeBips(500);
        assertEq(wnlpUSDC.instantRedeemFeeBips(), 500);

        // Owner can set max value (25%)
        vm.prank(deployer);
        wnlpUSDC.setInstantRedeemFeeBips(2500);
        assertEq(wnlpUSDC.instantRedeemFeeBips(), 2500);

        // Cannot exceed max
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.InvalidFeeBips.selector);
        wnlpUSDC.setInstantRedeemFeeBips(2501);
    }

    function test_instantRedeemEnabled() public {
        // Initially enabled by default
        assertEq(wnlpUSDC.instantRedeemEnabled(), true);

        // Non-owner cannot change
        vm.prank(alice);
        vm.expectRevert();
        wnlpUSDC.setInstantRedeemEnabled(false);

        // Owner disables instant redeem
        vm.prank(deployer);
        wnlpUSDC.setInstantRedeemEnabled(false);
        assertEq(wnlpUSDC.instantRedeemEnabled(), false);

        // Instant redeem should be blocked
        vm.startPrank(alice);
        uint256 wNLPAmount = wnlpUSDC.depositAndWrap(alice, INITIAL_DEPOSIT);
        vm.expectRevert("Instant redeem disabled");
        wnlpUSDC.instantRedeem(wNLPAmount, alice);
        vm.stopPrank();

        // Owner re-enables instant redeem
        vm.prank(deployer);
        wnlpUSDC.setInstantRedeemEnabled(true);
        assertEq(wnlpUSDC.instantRedeemEnabled(), true);

        // Now instant redeem should work
        vm.prank(alice);
        wnlpUSDC.instantRedeem(wNLPAmount, alice);
    }

    // ============================
    // WithdrawQueue Tests
    // ============================

    function test_queue_requestWithdrawal_success() public {
        // Alice deposits and wraps
        vm.startPrank(alice);
        uint256 depositAmount = INITIAL_DEPOSIT;
        uint256 wNLPAmount = wnlpUSDC.depositAndWrap(alice, depositAmount);

        // Approve queue to transfer wNLP
        IERC20(wnlpUSDC).approve(address(queueUSDC), wNLPAmount);

        uint256 aliceWNLPBefore = wnlpUSDC.balanceOf(alice);
        uint256 queueBalanceBefore = wnlpUSDC.balanceOf(address(queueUSDC));
        uint256 totalUnclaimedBefore = queueUSDC.totalUnclaimedAmount();

        // Request withdrawal
        queueUSDC.requestWithdrawal(wNLPAmount);

        // Verify wNLP transferred to queue
        assertEq(wnlpUSDC.balanceOf(alice), aliceWNLPBefore - wNLPAmount);
        assertEq(wnlpUSDC.balanceOf(address(queueUSDC)), queueBalanceBefore + wNLPAmount);

        // Verify total unclaimed amount updated
        assertEq(queueUSDC.totalUnclaimedAmount(), totalUnclaimedBefore + wNLPAmount);

        // Verify withdrawal request created
        (uint256 requestedAmount, uint256 claimableTime,) = queueUSDC.withdrawalRequests(alice);
        assertEq(requestedAmount, wNLPAmount);
        assertEq(claimableTime, block.timestamp + 8 hours);

        vm.stopPrank();
    }

    function test_queue_requestWithdrawal_reverts() public {
        vm.startPrank(alice);
        uint256 wNLPAmount = wnlpUSDC.depositAndWrap(alice, INITIAL_DEPOSIT);
        IERC20(wnlpUSDC).approve(address(queueUSDC), wNLPAmount);

        // Cannot withdraw less than MIN_WITHDRAWAL_AMOUNT (1000)
        vm.expectRevert("Below minimum withdrawal amount");
        queueUSDC.requestWithdrawal(999);

        // Make first request
        queueUSDC.requestWithdrawal(wNLPAmount / 2);

        // Cannot make another request while one exists
        vm.expectRevert("Pending request exists");
        queueUSDC.requestWithdrawal(wNLPAmount / 2);

        vm.stopPrank();
    }

    function test_queue_claimWithdrawal_success() public {
        // Alice requests withdrawal
        vm.startPrank(alice);
        uint256 depositAmount = INITIAL_DEPOSIT;
        uint256 wNLPAmount = wnlpUSDC.depositAndWrap(alice, depositAmount);
        IERC20(wnlpUSDC).approve(address(queueUSDC), wNLPAmount);
        queueUSDC.requestWithdrawal(wNLPAmount);
        vm.stopPrank();

        // Fast forward past withdrawal window
        vm.warp(block.timestamp + 8 hours + 1);

        // Claim withdrawal
        vm.startPrank(alice);
        uint256 aliceUSDCBefore = USDC.balanceOf(alice);
        uint256 totalUnclaimedBefore = queueUSDC.totalUnclaimedAmount();

        uint256 underlyingReceived = queueUSDC.claimWithdrawal();

        // Verify underlying tokens received
        uint256 expectedUnderlying = lpUSDC.getUnderlyingByShares(wNLPAmount);
        assertEq(underlyingReceived, expectedUnderlying);
        assertEq(USDC.balanceOf(alice) - aliceUSDCBefore, underlyingReceived);

        // Verify total unclaimed amount decreased
        assertEq(queueUSDC.totalUnclaimedAmount(), totalUnclaimedBefore - wNLPAmount);

        // Verify request deleted
        (uint256 requestedAmount,,) = queueUSDC.withdrawalRequests(alice);
        assertEq(requestedAmount, 0);

        // Verify queue wNLP balance decreased
        assertEq(wnlpUSDC.balanceOf(address(queueUSDC)), 0);

        vm.stopPrank();
    }

    function test_queue_claimWithdrawal_reverts() public {
        vm.startPrank(alice);

        // Cannot claim without a request
        vm.expectRevert(ErrorsLib.ZeroAmount.selector);
        queueUSDC.claimWithdrawal();

        // Make a withdrawal request
        uint256 wNLPAmount = wnlpUSDC.depositAndWrap(alice, INITIAL_DEPOSIT);
        IERC20(wnlpUSDC).approve(address(queueUSDC), wNLPAmount);
        queueUSDC.requestWithdrawal(wNLPAmount);

        // Cannot claim before window expires
        vm.expectRevert("Not claimable");
        queueUSDC.claimWithdrawal();

        vm.stopPrank();
    }

    function test_queue_claimWithdrawalTo_success() public {
        // Alice requests withdrawal
        vm.startPrank(alice);
        uint256 wNLPAmount = wnlpUSDC.depositAndWrap(alice, INITIAL_DEPOSIT);
        IERC20(wnlpUSDC).approve(address(queueUSDC), wNLPAmount);
        queueUSDC.requestWithdrawal(wNLPAmount);
        vm.stopPrank();

        // Fast forward past withdrawal window
        vm.warp(block.timestamp + 8 hours + 1);

        // Claim to Bob's address
        vm.startPrank(alice);
        uint256 bobUSDCBefore = USDC.balanceOf(bob);
        uint256 aliceUSDCBefore = USDC.balanceOf(alice);

        uint256 underlyingReceived = queueUSDC.claimWithdrawalTo(bob);

        // Verify underlying tokens received
        uint256 expectedUnderlying = lpUSDC.getUnderlyingByShares(wNLPAmount);
        assertEq(underlyingReceived, expectedUnderlying);

        // Verify Bob received the tokens, not Alice
        assertEq(USDC.balanceOf(bob) - bobUSDCBefore, underlyingReceived);
        assertEq(USDC.balanceOf(alice), aliceUSDCBefore);

        // Verify request deleted
        (uint256 requestedAmount,,) = queueUSDC.withdrawalRequests(alice);
        assertEq(requestedAmount, 0);

        vm.stopPrank();
    }

    function test_queue_claimWithdrawalTo_zeroAddress() public {
        vm.startPrank(alice);

        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        queueUSDC.claimWithdrawalTo(address(0));

        vm.stopPrank();
    }

    function test_queue_cancelWithdrawal_success() public {
        // Alice requests withdrawal
        vm.startPrank(alice);
        uint256 depositAmount = INITIAL_DEPOSIT;
        uint256 wNLPAmount = wnlpUSDC.depositAndWrap(alice, depositAmount);
        IERC20(wnlpUSDC).approve(address(queueUSDC), wNLPAmount);
        queueUSDC.requestWithdrawal(wNLPAmount);

        // Verify request exists
        (uint256 requestedAmount, uint256 claimableTime,) = queueUSDC.withdrawalRequests(alice);
        assertEq(requestedAmount, wNLPAmount);
        assertGt(claimableTime, block.timestamp);

        uint256 aliceWNLPBefore = wnlpUSDC.balanceOf(alice);
        uint256 queueBalanceBefore = wnlpUSDC.balanceOf(address(queueUSDC));
        uint256 totalUnclaimedBefore = queueUSDC.totalUnclaimedAmount();

        // Cancel withdrawal
        uint256 returnedAmount = queueUSDC.cancelWithdrawal();

        // Verify returned amount matches
        assertEq(returnedAmount, wNLPAmount);

        // Verify wNLP returned to Alice
        assertEq(wnlpUSDC.balanceOf(alice), aliceWNLPBefore + wNLPAmount);
        assertEq(wnlpUSDC.balanceOf(address(queueUSDC)), queueBalanceBefore - wNLPAmount);

        // Verify total unclaimed amount decreased
        assertEq(queueUSDC.totalUnclaimedAmount(), totalUnclaimedBefore - wNLPAmount);

        // Verify request deleted
        (uint256 newRequestedAmount,,) = queueUSDC.withdrawalRequests(alice);
        assertEq(newRequestedAmount, 0);

        vm.stopPrank();
    }

    function test_queue_cancelWithdrawal_afterClaimableTime() public {
        // Alice requests withdrawal
        vm.startPrank(alice);
        uint256 wNLPAmount = wnlpUSDC.depositAndWrap(alice, INITIAL_DEPOSIT);
        IERC20(wnlpUSDC).approve(address(queueUSDC), wNLPAmount);
        queueUSDC.requestWithdrawal(wNLPAmount);
        vm.stopPrank();

        // Fast forward past claimable time
        vm.warp(block.timestamp + 8 hours + 1);

        // Alice should still be able to cancel even after claimable time
        vm.startPrank(alice);
        uint256 aliceWNLPBefore = wnlpUSDC.balanceOf(alice);

        uint256 returnedAmount = queueUSDC.cancelWithdrawal();

        // Verify returned amount matches
        assertEq(returnedAmount, wNLPAmount);

        // Verify wNLP returned to Alice
        assertEq(wnlpUSDC.balanceOf(alice), aliceWNLPBefore + wNLPAmount);

        // Verify request deleted
        (uint256 requestedAmount,,) = queueUSDC.withdrawalRequests(alice);
        assertEq(requestedAmount, 0);

        vm.stopPrank();
    }

    function test_queue_cancelWithdrawal_noPendingRequest() public {
        vm.startPrank(alice);

        // Try to cancel without a request
        vm.expectRevert("No pending request");
        queueUSDC.cancelWithdrawal();

        vm.stopPrank();
    }

    function test_queue_cancelWithdrawal_afterAlreadyCancelled() public {
        // Alice requests withdrawal
        vm.startPrank(alice);
        uint256 wNLPAmount = wnlpUSDC.depositAndWrap(alice, INITIAL_DEPOSIT);
        IERC20(wnlpUSDC).approve(address(queueUSDC), wNLPAmount);
        queueUSDC.requestWithdrawal(wNLPAmount);

        // Cancel once
        queueUSDC.cancelWithdrawal();

        // Try to cancel again
        vm.expectRevert("No pending request");
        queueUSDC.cancelWithdrawal();

        vm.stopPrank();
    }

    function test_queue_cancelAndRequestAgain() public {
        // Alice deposits and wraps
        vm.startPrank(alice);
        uint256 depositAmount = INITIAL_DEPOSIT;
        uint256 wNLPAmount = wnlpUSDC.depositAndWrap(alice, depositAmount);
        IERC20(wnlpUSDC).approve(address(queueUSDC), wNLPAmount);

        // Phase 1: First withdrawal request (50% of wNLP)
        uint256 firstRequestAmount = wNLPAmount / 2;
        queueUSDC.requestWithdrawal(firstRequestAmount);

        // Verify first request
        (uint256 requestedAmount1, uint256 claimableTime1,) = queueUSDC.withdrawalRequests(alice);
        assertEq(requestedAmount1, firstRequestAmount);
        assertEq(claimableTime1, block.timestamp + 8 hours);

        // Verify Alice's balances after first request
        assertEq(wnlpUSDC.balanceOf(alice), wNLPAmount - firstRequestAmount);
        assertEq(wnlpUSDC.balanceOf(address(queueUSDC)), firstRequestAmount);
        assertEq(queueUSDC.totalUnclaimedAmount(), firstRequestAmount);

        // Phase 2: Cancel the first withdrawal
        uint256 cancelledAmount = queueUSDC.cancelWithdrawal();

        // Verify cancelled amount matches
        assertEq(cancelledAmount, firstRequestAmount);

        // Verify cancellation
        (uint256 requestedAmount2,,) = queueUSDC.withdrawalRequests(alice);
        assertEq(requestedAmount2, 0);
        assertEq(wnlpUSDC.balanceOf(alice), wNLPAmount); // All wNLP returned
        assertEq(wnlpUSDC.balanceOf(address(queueUSDC)), 0);
        assertEq(queueUSDC.totalUnclaimedAmount(), 0);

        // Phase 3: Request again with different amount (25% of wNLP)
        uint256 secondRequestAmount = wNLPAmount / 4;
        queueUSDC.requestWithdrawal(secondRequestAmount);

        // Verify second request
        (uint256 requestedAmount3, uint256 claimableTime2,) = queueUSDC.withdrawalRequests(alice);
        assertEq(requestedAmount3, secondRequestAmount);
        assertEq(claimableTime2, block.timestamp + 8 hours);

        // Verify balances after second request
        assertEq(wnlpUSDC.balanceOf(alice), wNLPAmount - secondRequestAmount);
        assertEq(wnlpUSDC.balanceOf(address(queueUSDC)), secondRequestAmount);
        assertEq(queueUSDC.totalUnclaimedAmount(), secondRequestAmount);

        vm.stopPrank();

        // Phase 4: Fast forward past claimable time and claim
        vm.warp(block.timestamp + 8 hours + 1);

        vm.startPrank(alice);
        uint256 aliceUSDCBefore = USDC.balanceOf(alice);

        uint256 underlyingReceived = queueUSDC.claimWithdrawal();

        // Verify claim completed successfully
        uint256 expectedUnderlying = lpUSDC.getUnderlyingByShares(secondRequestAmount);
        assertEq(underlyingReceived, expectedUnderlying);
        assertEq(USDC.balanceOf(alice) - aliceUSDCBefore, underlyingReceived);

        // Verify all state cleared
        (uint256 finalRequestAmount,,) = queueUSDC.withdrawalRequests(alice);
        assertEq(finalRequestAmount, 0);
        assertEq(wnlpUSDC.balanceOf(address(queueUSDC)), 0);
        assertEq(queueUSDC.totalUnclaimedAmount(), 0);

        // Alice should have remaining wNLP (75% of original) plus received USDC
        uint256 remainingWNLP = wNLPAmount - secondRequestAmount;
        assertEq(wnlpUSDC.balanceOf(alice), remainingWNLP);

        vm.stopPrank();
    }

    function test_queue_setWithdrawalWindow() public {
        // Non-owner cannot set
        vm.prank(alice);
        vm.expectRevert();
        queueUSDC.setWithdrawalWindow(1 hours);

        // Cannot exceed max (14 days)
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.InvalidAmount.selector);
        queueUSDC.setWithdrawalWindow(15 days);

        // Owner can set valid window
        vm.prank(deployer);
        queueUSDC.setWithdrawalWindow(12 hours);
        assertEq(queueUSDC.withdrawalWindow(), 12 hours);

        // Owner can set max window
        vm.prank(deployer);
        queueUSDC.setWithdrawalWindow(14 days);
        assertEq(queueUSDC.withdrawalWindow(), 14 days);
    }

    function test_queue_getWithdrawalRequest() public {
        // Alice requests withdrawal
        vm.startPrank(alice);
        uint256 wNLPAmount = wnlpUSDC.depositAndWrap(alice, INITIAL_DEPOSIT);
        IERC20(wnlpUSDC).approve(address(queueUSDC), wNLPAmount);
        queueUSDC.requestWithdrawal(wNLPAmount);
        vm.stopPrank();

        // Get request via view function returns struct
        (uint256 amount, uint256 claimableTime,) = queueUSDC.withdrawalRequests(alice);

        assertEq(amount, wNLPAmount);
        assertEq(claimableTime, block.timestamp + 8 hours);
    }

    function test_queue_multipleUsersSequential() public {
        uint256 aliceAmount = 5000 * 1e6;
        uint256 bobAmount = 3000 * 1e6;
        uint256 charlieAmount = 2000 * 1e6;

        // Alice requests
        {
            vm.startPrank(alice);
            USDC.approve(address(wnlpUSDC), aliceAmount);
            uint256 aliceWNLP = wnlpUSDC.depositAndWrap(alice, aliceAmount);
            IERC20(wnlpUSDC).approve(address(queueUSDC), aliceWNLP);
            queueUSDC.requestWithdrawal(aliceWNLP);
            vm.stopPrank();
        }

        // Bob requests
        {
            vm.startPrank(bob);
            USDC.approve(address(wnlpUSDC), bobAmount);
            uint256 bobWNLP = wnlpUSDC.depositAndWrap(bob, bobAmount);
            IERC20(wnlpUSDC).approve(address(queueUSDC), bobWNLP);
            queueUSDC.requestWithdrawal(bobWNLP);
            vm.stopPrank();
        }

        // Charlie requests
        {
            vm.startPrank(charlie);
            USDC.approve(address(wnlpUSDC), charlieAmount);
            uint256 charlieWNLP = wnlpUSDC.depositAndWrap(charlie, charlieAmount);
            IERC20(wnlpUSDC).approve(address(queueUSDC), charlieWNLP);
            queueUSDC.requestWithdrawal(charlieWNLP);
            vm.stopPrank();
        }

        // Verify total unclaimed amount
        (uint256 aliceReq,,) = queueUSDC.withdrawalRequests(alice);
        (uint256 bobReq,,) = queueUSDC.withdrawalRequests(bob);
        (uint256 charlieReq,,) = queueUSDC.withdrawalRequests(charlie);

        assertEq(queueUSDC.totalUnclaimedAmount(), aliceReq + bobReq + charlieReq);

        // Fast forward and let them claim
        vm.warp(block.timestamp + 8 hours + 1);

        // Alice claims
        uint256 aliceBalanceBefore = USDC.balanceOf(alice);
        vm.prank(alice);
        uint256 aliceReceived = queueUSDC.claimWithdrawal();
        assertEq(USDC.balanceOf(alice) - aliceBalanceBefore, aliceReceived);
        assertEq(aliceReceived, aliceAmount - MINIMUM_SHARE);

        // Bob claims
        uint256 bobBalanceBefore = USDC.balanceOf(bob);
        vm.prank(bob);
        uint256 bobReceived = queueUSDC.claimWithdrawal();
        assertEq(USDC.balanceOf(bob) - bobBalanceBefore, bobReceived);
        assertEq(bobReceived, bobAmount);

        // Charlie claims
        uint256 charlieBalanceBefore = USDC.balanceOf(charlie);
        vm.prank(charlie);
        uint256 charlieReceived = queueUSDC.claimWithdrawal();
        assertEq(USDC.balanceOf(charlie) - charlieBalanceBefore, charlieReceived);
        assertEq(charlieReceived, charlieAmount);

        // Verify all cleared
        assertEq(queueUSDC.totalUnclaimedAmount(), 0);
        assertEq(wnlpUSDC.balanceOf(address(queueUSDC)), 0);
    }

    function test_queue_name() public view {
        // Verify queue name matches expected format
        string memory expectedName = string.concat(wnlpUSDC.symbol(), "-Queue");
        assertEq(queueUSDC.name(), expectedName);
    }

    function test_queue_setFeeRecipient() public {
        // Non-owner cannot set
        vm.prank(alice);
        vm.expectRevert();
        queueUSDC.setFeeRecipient(bob);

        // Cannot set zero address
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        queueUSDC.setFeeRecipient(address(0));

        // Owner can set valid address
        vm.prank(deployer);
        queueUSDC.setFeeRecipient(charlie);
        assertEq(queueUSDC.feeRecipient(), charlie);

        // Change to another address
        vm.prank(deployer);
        queueUSDC.setFeeRecipient(bob);
        assertEq(queueUSDC.feeRecipient(), bob);
    }

    function test_queue_affiliateFeeConfig_ownerOnlyAndCapped() public {
        // Cap is fixed at deployment time
        assertEq(queueUSDC.maxAffFeeBps(), AFF_FEE_CAP_BPS);

        // Non-owner cannot set per-affiliate fee
        vm.prank(alice);
        vm.expectRevert();
        queueUSDC.setAffiliateFee(bob, 300);

        // Per-affiliate fee cannot exceed cap
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.InvalidFeeBips.selector);
        queueUSDC.setAffiliateFee(bob, AFF_FEE_CAP_BPS + 1);

        // Owner can set valid per-affiliate fee
        vm.prank(deployer);
        queueUSDC.setAffiliateFee(bob, 300);
        assertEq(queueUSDC.affiliateFeeBps(bob), 300);
    }

    function test_queue_setAffiliateFee_zeroAddressAndCapBoundary() public {
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        queueUSDC.setAffiliateFee(address(0), 100);

        vm.prank(deployer);
        queueUSDC.setAffiliateFee(bob, AFF_FEE_CAP_BPS);
        assertEq(queueUSDC.affiliateFeeBps(bob), AFF_FEE_CAP_BPS);
    }

    function test_queue_scheduleWithdrawalFor_claimWithAffiliateFee() public {
        vm.prank(deployer);
        queueUSDC.setAffiliateFee(bob, 300);

        // Bob acts as relayer and contributes his own wNLP for Alice
        vm.startPrank(bob);
        uint256 wNLPAmount = wnlpUSDC.depositAndWrap(bob, INITIAL_DEPOSIT);
        IERC20(wnlpUSDC).approve(address(queueUSDC), wNLPAmount);
        queueUSDC.scheduleWithdrawalFor(alice, wNLPAmount);
        vm.stopPrank();

        assertEq(queueUSDC.totalUnclaimedAmount(), wNLPAmount);
        assertEq(queueUSDC.withdrawalAffiliate(alice), bob);

        vm.warp(block.timestamp + 8 hours + 1);

        uint256 aliceUSDCBefore = USDC.balanceOf(alice);
        uint256 bobUSDCBefore = USDC.balanceOf(bob);
        uint256 expectedUnderlying = lpUSDC.getUnderlyingByShares(wNLPAmount);
        uint256 expectedAffiliateFee = expectedUnderlying * 300 / 10_000;

        vm.prank(alice);
        uint256 underlyingReceived = queueUSDC.claimWithdrawal();

        assertEq(underlyingReceived, expectedUnderlying);
        assertEq(USDC.balanceOf(alice) - aliceUSDCBefore, expectedUnderlying - expectedAffiliateFee);
        assertEq(USDC.balanceOf(bob) - bobUSDCBefore, expectedAffiliateFee);
        assertEq(queueUSDC.totalUnclaimedAmount(), 0);
        assertEq(queueUSDC.withdrawalAffiliate(alice), address(0));
    }

    function test_queue_scheduleWithdrawalFor_revertsForUnregisteredAffiliate() public {
        vm.startPrank(charlie);
        uint256 wNLPAmount = wnlpUSDC.depositAndWrap(charlie, INITIAL_DEPOSIT);
        IERC20(wnlpUSDC).approve(address(queueUSDC), wNLPAmount);
        vm.expectRevert("Unregistered Affiliate");
        queueUSDC.scheduleWithdrawalFor(alice, wNLPAmount);
        vm.stopPrank();
    }

    function test_queue_scheduleWithdrawalFor_affiliateClearedOnCancel() public {
        vm.prank(deployer);
        queueUSDC.setAffiliateFee(bob, 300);

        vm.startPrank(bob);
        uint256 wNLPAmount = wnlpUSDC.depositAndWrap(bob, INITIAL_DEPOSIT);
        IERC20(wnlpUSDC).approve(address(queueUSDC), wNLPAmount);
        queueUSDC.scheduleWithdrawalFor(alice, wNLPAmount);
        vm.stopPrank();

        assertEq(queueUSDC.totalUnclaimedAmount(), wNLPAmount);
        assertEq(queueUSDC.withdrawalAffiliate(alice), bob);

        vm.prank(alice);
        queueUSDC.cancelWithdrawal();

        assertEq(queueUSDC.totalUnclaimedAmount(), 0);
        assertEq(queueUSDC.withdrawalAffiliate(alice), address(0));
    }

    function test_queue_scheduleWithdrawalFor_feeUpdateAffectsPending_andSelfRequestHasNoAffiliate() public {
        vm.prank(deployer);
        queueUSDC.setAffiliateFee(bob, 300);

        // Bob schedules for Alice while fee is 300 bps.
        vm.startPrank(bob);
        uint256 relayedWNLPAmount = wnlpUSDC.depositAndWrap(bob, INITIAL_DEPOSIT);
        IERC20(wnlpUSDC).approve(address(queueUSDC), relayedWNLPAmount);
        queueUSDC.scheduleWithdrawalFor(alice, relayedWNLPAmount);
        vm.stopPrank();
        assertEq(queueUSDC.totalUnclaimedAmount(), relayedWNLPAmount);
        assertEq(queueUSDC.withdrawalAffiliate(alice), bob);

        // Fee is updated before claim; pending request should use latest fee.
        vm.prank(deployer);
        queueUSDC.setAffiliateFee(bob, 0);

        vm.warp(block.timestamp + 8 hours + 1);

        uint256 aliceBeforeClaim = USDC.balanceOf(alice);
        uint256 bobBeforeClaim = USDC.balanceOf(bob);
        uint256 expectedRelayedUnderlying = lpUSDC.getUnderlyingByShares(relayedWNLPAmount);

        vm.prank(alice);
        uint256 relayedUnderlyingReceived = queueUSDC.claimWithdrawal();

        assertEq(relayedUnderlyingReceived, expectedRelayedUnderlying);
        assertEq(USDC.balanceOf(alice) - aliceBeforeClaim, expectedRelayedUnderlying);
        assertEq(USDC.balanceOf(bob) - bobBeforeClaim, 0);
        assertEq(queueUSDC.totalUnclaimedAmount(), 0);
        assertEq(queueUSDC.withdrawalAffiliate(alice), address(0));

        // Self-request path should never attach affiliate.
        vm.startPrank(alice);
        uint256 selfWNLPAmount = wnlpUSDC.depositAndWrap(alice, INITIAL_DEPOSIT);
        IERC20(wnlpUSDC).approve(address(queueUSDC), selfWNLPAmount);
        queueUSDC.requestWithdrawal(selfWNLPAmount);
        vm.stopPrank();

        assertEq(queueUSDC.totalUnclaimedAmount(), selfWNLPAmount);
        assertEq(queueUSDC.withdrawalAffiliate(alice), address(0));
    }

    function test_queue_scheduleWithdrawalFor_reverts_invalidParams_pending_andZeroFeeAffiliate() public {
        vm.prank(deployer);
        queueUSDC.setAffiliateFee(bob, 300);

        vm.startPrank(bob);
        uint256 wNLPAmount = wnlpUSDC.depositAndWrap(bob, INITIAL_DEPOSIT);
        IERC20(wnlpUSDC).approve(address(queueUSDC), wNLPAmount);

        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        queueUSDC.scheduleWithdrawalFor(address(0), wNLPAmount);

        vm.expectRevert("Below minimum withdrawal amount");
        queueUSDC.scheduleWithdrawalFor(alice, 999);

        queueUSDC.scheduleWithdrawalFor(alice, wNLPAmount);

        vm.expectRevert("Pending request exists");
        queueUSDC.scheduleWithdrawalFor(alice, wNLPAmount);
        vm.stopPrank();

        vm.prank(deployer);
        queueUSDC.setAffiliateFee(bob, 0);

        vm.prank(bob);
        vm.expectRevert("Unregistered Affiliate");
        queueUSDC.scheduleWithdrawalFor(charlie, wNLPAmount);
    }

    function test_queue_underlyingSnapshot_recordedCorrectly() public {
        // Alice deposits and wraps
        vm.startPrank(alice);
        uint256 depositAmount = INITIAL_DEPOSIT;
        uint256 wNLPAmount = wnlpUSDC.depositAndWrap(alice, depositAmount);
        IERC20(wnlpUSDC).approve(address(queueUSDC), wNLPAmount);

        // Get expected underlying amount before request
        uint256 expectedUnderlying = wnlpUSDC.getNlpByWnlp(wNLPAmount);

        // Request withdrawal
        queueUSDC.requestWithdrawal(wNLPAmount);

        // Verify underlyingSnapshot was recorded correctly
        (uint256 requestedWNLP, uint256 claimableTime, uint256 underlyingSnapshot) = queueUSDC.withdrawalRequests(alice);
        assertEq(requestedWNLP, wNLPAmount);
        assertEq(underlyingSnapshot, expectedUnderlying);
        assertGt(claimableTime, block.timestamp);

        vm.stopPrank();
    }

    function test_queue_yieldCollection_withRebasing() public {
        // Set charlie as feeRecipient
        vm.prank(deployer);
        queueUSDC.setFeeRecipient(charlie);

        // Alice deposits and wraps
        vm.startPrank(alice);
        uint256 depositAmount = 5000 * 1e6; // 5000 USDC
        uint256 wNLPAmount = wnlpUSDC.depositAndWrap(alice, depositAmount);
        IERC20(wnlpUSDC).approve(address(queueUSDC), wNLPAmount);

        // Request withdrawal and record snapshot
        queueUSDC.requestWithdrawal(wNLPAmount);
        (,, uint256 underlyingSnapshot) = queueUSDC.withdrawalRequests(alice);
        vm.stopPrank();

        // Simulate yield distribution (10% yield)
        address vault = lpUSDC.creditVault();
        uint256 currentTotalUnderlying = lpUSDC.totalUnderlying();
        uint256 yieldAmount = currentTotalUnderlying / 10; // 10% yield

        // Mint USDC to vault for yield distribution
        vm.prank(deployer);
        USDC.mint(vault, yieldAmount);

        vm.prank(vault);
        lpUSDC.distributeYield(yieldAmount);

        // Fast forward past withdrawal window
        vm.warp(block.timestamp + 8 hours + 1);

        // Record balances before claim
        uint256 aliceUSDCBefore = USDC.balanceOf(alice);
        uint256 charlieUSDCBefore = USDC.balanceOf(charlie);

        // Alice claims
        vm.prank(alice);
        uint256 underlyingReceived = queueUSDC.claimWithdrawal();

        // Verify Alice received exactly the snapshot amount
        assertEq(underlyingReceived, underlyingSnapshot);
        assertEq(USDC.balanceOf(alice) - aliceUSDCBefore, underlyingSnapshot);

        // Verify charlie (feeRecipient) received the excess yield
        uint256 charlieReceived = USDC.balanceOf(charlie) - charlieUSDCBefore;
        assertGt(charlieReceived, 0, "Fee recipient should receive excess yield");

        // Calculate expected yield (approximately 10% of snapshot)
        uint256 expectedYield = underlyingSnapshot / 10;
        assertApproxEqAbs(charlieReceived, expectedYield, expectedYield / 100); // 1% tolerance
    }

    function test_queue_yieldCollection_noYield() public {
        // Set charlie as feeRecipient
        vm.prank(deployer);
        queueUSDC.setFeeRecipient(charlie);

        // Alice deposits and wraps
        vm.startPrank(alice);
        uint256 depositAmount = INITIAL_DEPOSIT;
        uint256 wNLPAmount = wnlpUSDC.depositAndWrap(alice, depositAmount);
        IERC20(wnlpUSDC).approve(address(queueUSDC), wNLPAmount);

        // Request withdrawal
        queueUSDC.requestWithdrawal(wNLPAmount);
        (,, uint256 underlyingSnapshot) = queueUSDC.withdrawalRequests(alice);
        vm.stopPrank();

        // Fast forward past withdrawal window WITHOUT any yield distribution
        vm.warp(block.timestamp + 8 hours + 1);

        // Record balances before claim
        uint256 aliceUSDCBefore = USDC.balanceOf(alice);
        uint256 charlieUSDCBefore = USDC.balanceOf(charlie);

        // Alice claims
        vm.prank(alice);
        uint256 underlyingReceived = queueUSDC.claimWithdrawal();

        // Verify Alice received exactly the snapshot amount
        assertEq(underlyingReceived, underlyingSnapshot);
        assertEq(USDC.balanceOf(alice) - aliceUSDCBefore, underlyingSnapshot);

        // Verify charlie (feeRecipient) received nothing (no yield)
        assertEq(USDC.balanceOf(charlie), charlieUSDCBefore);
    }

    function test_queue_pause_unpause() public {
        // Only owner can pause
        vm.prank(alice);
        vm.expectRevert();
        queueUSDC.pause();

        // Owner pauses
        vm.prank(deployer);
        queueUSDC.pause();
        assertTrue(queueUSDC.paused());

        // Cannot request when paused
        vm.startPrank(alice);
        uint256 wNLPAmount = wnlpUSDC.depositAndWrap(alice, INITIAL_DEPOSIT);
        IERC20(wnlpUSDC).approve(address(queueUSDC), wNLPAmount);

        vm.expectRevert("Pausable: paused");
        queueUSDC.requestWithdrawal(wNLPAmount);
        vm.stopPrank();

        // Only owner can unpause
        vm.prank(alice);
        vm.expectRevert();
        queueUSDC.unpause();

        // Owner unpauses
        vm.prank(deployer);
        queueUSDC.unpause();
        assertFalse(queueUSDC.paused());

        // Can request after unpause
        vm.prank(alice);
        queueUSDC.requestWithdrawal(wNLPAmount);
    }
}
