// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../../src/libraries/ConstantsLib.sol";
import {ErrorsLib} from "../../src/libraries/ErrorsLib.sol";

import {ICreditVault} from "../../src/interfaces/ICreditVault.sol";
import {MockERC20} from "../../src/test/MockERC20.sol";
import {NativeLPToken} from "../../src/NativeLPToken.sol";
import {NativeRFQPool} from "../../src/NativeRFQPool.sol";
import {SignatureUtils} from "../helpers/SignatureUtils.sol";
import {BaseTest} from "../BaseTest.t.sol";

import {console2} from "forge-std/console2.sol";

contract CreditVaultTest is BaseTest {
    function setUp() public override {
        super.setUp();

        // Set initial timestamp to avoid any cooldown issues
        vm.warp(1_000_000);

        // Setup PMM traders including halo
        setupPMM();

        // Set deployer as epochUpdater and setup trader
        vm.startPrank(deployer);
        creditVault.setEpochUpdater(deployer);
        creditVault.setTrader(halo, halo, halo, true);
        vm.stopPrank();
    }

    function test_epochUpdate_onlyEpochUpdater() public {
        // Setup initial LP token state
        deal(address(USDC), alice, 10_000);
        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), 10_000);
        vm.stopPrank();

        vm.startPrank(deployer);
        lpUSDC.setMinDeposit(100);
        vm.stopPrank();

        vm.startPrank(alice);
        lpUSDC.deposit(10_000);
        vm.stopPrank();

        ICreditVault.FundingFeeAmount[] memory feeUpdates = new ICreditVault.FundingFeeAmount[](1);
        feeUpdates[0] = ICreditVault.FundingFeeAmount({token: address(USDC), reserveFee: 10, fundingFee: 5});

        ICreditVault.AccruedFundingFee[] memory accruedFees = new ICreditVault.AccruedFundingFee[](1);
        accruedFees[0] = ICreditVault.AccruedFundingFee({trader: halo, feeUpdates: feeUpdates});

        // Non-epochUpdater should fail
        vm.prank(alice);
        vm.expectRevert(ErrorsLib.OnlyEpochUpdater.selector);
        creditVault.epochUpdate(accruedFees);

        // EpochUpdater should succeed
        vm.prank(deployer);
        creditVault.epochUpdate(accruedFees);
    }

    function test_epochUpdate_cooldownPeriod() public {
        // Setup initial LP token state
        deal(address(USDC), alice, 10_000);
        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), 10_000);
        vm.stopPrank();

        vm.startPrank(deployer);
        lpUSDC.setMinDeposit(100);
        vm.stopPrank();

        vm.startPrank(alice);
        lpUSDC.deposit(10_000);
        vm.stopPrank();

        ICreditVault.FundingFeeAmount[] memory feeUpdates = new ICreditVault.FundingFeeAmount[](1);
        feeUpdates[0] = ICreditVault.FundingFeeAmount({token: address(USDC), reserveFee: 10, fundingFee: 5});

        ICreditVault.AccruedFundingFee[] memory accruedFees = new ICreditVault.AccruedFundingFee[](1);
        accruedFees[0] = ICreditVault.AccruedFundingFee({trader: halo, feeUpdates: feeUpdates});

        // First update should succeed
        vm.prank(deployer);
        creditVault.epochUpdate(accruedFees);

        // Verify lastEpochUpdateTimestamp
        assertEq(creditVault.lastEpochUpdateTimestamp(halo), block.timestamp);

        // Try to update again immediately should fail
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.EpochUpdateInCoolDown.selector);
        creditVault.epochUpdate(accruedFees);

        // Move forward just before cooldown ends
        vm.warp(block.timestamp + EPOCH_UPDATE_INTERVAL - 1);
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.EpochUpdateInCoolDown.selector);
        creditVault.epochUpdate(accruedFees);

        // Move forward past cooldown period
        vm.warp(block.timestamp + 2);
        vm.prank(deployer);
        creditVault.epochUpdate(accruedFees);
    }

    function test_epochUpdate_lpPoolNotInitialized() public {
        // Create fee updates
        ICreditVault.FundingFeeAmount[] memory feeUpdates = new ICreditVault.FundingFeeAmount[](1);
        feeUpdates[0] = ICreditVault.FundingFeeAmount({token: address(USDC), reserveFee: 100, fundingFee: 50});

        ICreditVault.AccruedFundingFee[] memory accruedFees = new ICreditVault.AccruedFundingFee[](1);
        accruedFees[0] = ICreditVault.AccruedFundingFee({trader: halo, feeUpdates: feeUpdates});

        // Verify LP pool is empty
        assertEq(lpUSDC.totalShares(), 0);

        // Should revert when trying to distribute yield to empty LP pool
        vm.startPrank(deployer);
        vm.expectRevert(ErrorsLib.PoolNotInitialized.selector);
        creditVault.epochUpdate(accruedFees);
        vm.stopPrank();
    }

    function test_epochUpdate_exchangeRateLimit() public {
        // Setup initial LP token state with small totalUnderlying
        deal(address(USDC), alice, 1000);

        // Alice approves and deposits
        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), 1000);
        vm.stopPrank();

        // Deployer sets minDeposit and Alice deposits
        vm.startPrank(deployer);
        lpUSDC.setMinDeposit(100); // Set a small minimum deposit amount
        vm.stopPrank();

        vm.startPrank(alice);
        lpUSDC.deposit(1000);
        vm.stopPrank();

        // Create fee update with large lpFee that would cause exchange rate to increase too much
        ICreditVault.FundingFeeAmount[] memory feeUpdates = new ICreditVault.FundingFeeAmount[](1);
        feeUpdates[0] = ICreditVault.FundingFeeAmount({
            token: address(USDC),
            reserveFee: 100,
            fundingFee: 1000 // This would cause >1% increase in exchange rate
        });

        ICreditVault.AccruedFundingFee[] memory accruedFees = new ICreditVault.AccruedFundingFee[](1);
        accruedFees[0] = ICreditVault.AccruedFundingFee({trader: halo, feeUpdates: feeUpdates});

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ExchangeRateIncreaseTooMuch.selector);
        creditVault.epochUpdate(accruedFees);
    }

    function test_epochUpdate_feeAccrual() public {
        // Setup initial LP token state with larger pool
        deal(address(USDC), alice, 10_000);
        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), 10_000);
        lpUSDC.deposit(10_000);
        vm.stopPrank();

        // Setup fee updates
        ICreditVault.FundingFeeAmount[] memory feeUpdates = new ICreditVault.FundingFeeAmount[](1);
        feeUpdates[0] = ICreditVault.FundingFeeAmount({token: address(USDC), reserveFee: 100, fundingFee: 50});

        ICreditVault.AccruedFundingFee[] memory accruedFees = new ICreditVault.AccruedFundingFee[](1);
        accruedFees[0] = ICreditVault.AccruedFundingFee({trader: alice, feeUpdates: feeUpdates});

        // Record initial balances
        uint256 vaultInitialBalance = USDC.balanceOf(address(creditVault));
        uint256 feeWithdrawerInitialBalance = USDC.balanceOf(address(deployer)); // Assume deployer is the fee withdrawer

        // Update epoch to accrue fees
        vm.prank(deployer);
        creditVault.epochUpdate(accruedFees);

        // Verify funding rate fees were accrued
        assertEq(creditVault.reserveFees(address(USDC)), 100);

        // Withdraw funding rate fees
        vm.prank(deployer);
        creditVault.withdrawReserve(address(USDC), deployer, 100);

        // Verify final balances
        assertEq(creditVault.reserveFees(address(USDC)), 0);
        assertEq(
            USDC.balanceOf(address(creditVault)),
            vaultInitialBalance - 100,
            "Vault balance should decrease by fee amount"
        );
        assertEq(
            USDC.balanceOf(address(deployer)),
            feeWithdrawerInitialBalance + 100,
            "Fee withdrawer balance should increase by fee amount"
        );
    }

    function test_withdrawFundingFee() public {
        // Setup: Accumulate some funding fees first
        deal(address(USDC), alice, 10_000);
        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), 10_000);
        lpUSDC.deposit(10_000);
        vm.stopPrank();

        ICreditVault.FundingFeeAmount[] memory feeUpdates = new ICreditVault.FundingFeeAmount[](1);
        feeUpdates[0] = ICreditVault.FundingFeeAmount({token: address(USDC), reserveFee: 100, fundingFee: 50});

        ICreditVault.AccruedFundingFee[] memory accruedFees = new ICreditVault.AccruedFundingFee[](1);
        accruedFees[0] = ICreditVault.AccruedFundingFee({trader: alice, feeUpdates: feeUpdates});

        vm.prank(deployer);
        creditVault.epochUpdate(accruedFees);

        // Test 1: Non-feeWithdrawer cannot withdraw
        address randomUser = address(0x999);
        vm.prank(randomUser);
        vm.expectRevert(ErrorsLib.OnlyFeeWithdrawer.selector);
        creditVault.withdrawReserve(address(USDC), randomUser, 50);

        // Test 2: Cannot withdraw more than the accumulated fees
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.InsufficientFundingFees.selector);
        creditVault.withdrawReserve(address(USDC), deployer, 150);

        // Test 3: Successful withdrawal
        uint256 initialVaultBalance = USDC.balanceOf(address(creditVault));
        uint256 initialWithdrawerBalance = USDC.balanceOf(deployer);
        uint256 initialTotalUnderlying = lpUSDC.totalUnderlying();

        vm.prank(deployer);
        creditVault.withdrawReserve(address(USDC), deployer, 50);

        // Verify state changes
        assertEq(creditVault.reserveFees(address(USDC)), 50, "Remaining funding fees should be 50");
        assertEq(
            USDC.balanceOf(address(creditVault)), initialVaultBalance - 50, "Vault USDC balance should decrease by 50"
        );
        assertEq(
            USDC.balanceOf(deployer), initialWithdrawerBalance + 50, "Withdrawer USDC balance should increase by 50"
        );
        assertEq(lpUSDC.totalUnderlying(), initialTotalUnderlying, "LP token total underlying should not change");
    }

    function test_supportMarket() public {
        // Prepare a new LP token for testing
        MockERC20 newToken = new MockERC20("New Token", "NEW", 18);
        NativeLPToken newLPToken = new NativeLPToken("LP New Token", "lpNEW", address(newToken), address(creditVault));

        // Test 1: Non-owner cannot call supportMarket
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        creditVault.supportMarket(newLPToken);

        // Test 2: LP token with mismatched creditVault address
        NativeLPToken wrongLPToken = new NativeLPToken(
            "Wrong LP Token",
            "WRONG",
            address(newToken),
            address(alice) // Use different creditVault address
        );

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.InvalidMarket.selector);
        creditVault.supportMarket(wrongLPToken);

        // Test 3: Successfully support market
        vm.startPrank(deployer); // Ensure the entire operation is performed by deployer
        creditVault.supportMarket(newLPToken);
        vm.stopPrank();

        // Verify state updates
        assertTrue(creditVault.supportedMarkets(address(newLPToken)), "Market should be supported");
        assertEq(
            address(creditVault.lpTokens(address(newToken))), address(newLPToken), "LP token mapping should be updated"
        );

        // Test 4: Cannot support already supported market
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.TokenAlreadyListed.selector);
        creditVault.supportMarket(newLPToken);
    }

    function test_setNativePool() public {
        // Create a new RFQ pool with deployer as owner
        vm.startPrank(deployer);
        NativeRFQPool newRFQPool =
            new NativeRFQPool(address(weth), address(router), address(creditVault), "TestRFQPool");

        // Enable callback for the pool (deployer is the owner)
        newRFQPool.setEnableCallback(true);
        vm.stopPrank();

        // Test 1: Non-owner cannot call setNativePool
        vm.startPrank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        creditVault.setNativePool(address(newRFQPool), true);
        vm.stopPrank();

        // Test 2: Cannot set zero address as pool
        vm.startPrank(deployer);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        creditVault.setNativePool(address(0), true);
        vm.stopPrank();

        // Test 3: Successfully set pool to true and verify state
        vm.startPrank(deployer);
        creditVault.setNativePool(address(newRFQPool), true);

        assertTrue(creditVault.isNativePools(address(newRFQPool)), "Pool should be set as native pool");
        vm.stopPrank();

        // Test 4: Successfully set pool to false and verify state
        vm.prank(deployer);
        creditVault.setNativePool(address(newRFQPool), false);
        assertFalse(creditVault.isNativePools(address(newRFQPool)), "Pool should not be native pool anymore");
    }

    function test_setAllowance() public {
        // Setup: Create and configure a new RFQ pool
        vm.startPrank(deployer);
        NativeRFQPool newRFQPool =
            new NativeRFQPool(address(weth), address(router), address(creditVault), "TestRFQPool");
        newRFQPool.setEnableCallback(true);

        // Enable the pool in CreditVault
        creditVault.setNativePool(address(newRFQPool), true);
        vm.stopPrank();

        // Prepare token amount array for testing
        ICreditVault.TokenAmountUint[] memory tokens = new ICreditVault.TokenAmountUint[](2);
        tokens[0] = ICreditVault.TokenAmountUint({token: address(USDC), amount: 1000 * 10 ** 6});
        tokens[1] = ICreditVault.TokenAmountUint({token: address(weth), amount: 1 ether});

        // Test 1: Non-owner cannot call setAllowance
        vm.startPrank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        creditVault.setAllowance(tokens, address(newRFQPool));
        vm.stopPrank();

        // Test 2: Cannot set allowance for non-native pool
        address nonNativePool = makeAddr("nonNativePool");
        vm.startPrank(deployer);
        vm.expectRevert(ErrorsLib.OnlyNativePool.selector);
        creditVault.setAllowance(tokens, nonNativePool);
        vm.stopPrank();

        // Test 3: Cannot set allowance for zero address token
        ICreditVault.TokenAmountUint[] memory tokensWithZeroAddress = new ICreditVault.TokenAmountUint[](1);
        tokensWithZeroAddress[0] = ICreditVault.TokenAmountUint({token: address(0), amount: 1000});

        vm.startPrank(deployer);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        creditVault.setAllowance(tokensWithZeroAddress, address(newRFQPool));
        vm.stopPrank();

        // Test 4: Successfully set allowance and verify values
        vm.startPrank(deployer);
        // First set allowances to 0
        ICreditVault.TokenAmountUint[] memory zeroTokens = new ICreditVault.TokenAmountUint[](2);
        zeroTokens[0] = ICreditVault.TokenAmountUint({token: address(USDC), amount: 0});
        zeroTokens[1] = ICreditVault.TokenAmountUint({token: address(weth), amount: 0});
        creditVault.setAllowance(zeroTokens, address(newRFQPool));

        // Then set new allowances
        creditVault.setAllowance(tokens, address(newRFQPool));

        // Verify allowances are set correctly
        assertEq(
            USDC.allowance(address(creditVault), address(newRFQPool)),
            tokens[0].amount,
            "USDC allowance not set correctly"
        );
        assertEq(
            weth.allowance(address(creditVault), address(newRFQPool)),
            tokens[1].amount,
            "WETH allowance not set correctly"
        );
        vm.stopPrank();

        // Test 5: Update existing allowances
        // First set to zero
        vm.startPrank(deployer);
        creditVault.setAllowance(zeroTokens, address(newRFQPool));

        // Then set new values
        tokens[0].amount = 2000 * 10 ** 6; // Double the USDC allowance
        tokens[1].amount = 2 ether; // Double the WETH allowance
        creditVault.setAllowance(tokens, address(newRFQPool));

        // Verify updated allowances
        assertEq(
            USDC.allowance(address(creditVault), address(newRFQPool)),
            tokens[0].amount,
            "Updated USDC allowance not set correctly"
        );
        assertEq(
            weth.allowance(address(creditVault), address(newRFQPool)),
            tokens[1].amount,
            "Updated WETH allowance not set correctly"
        );
        vm.stopPrank();
    }

    function test_setTrader() public {
        address newTrader = makeAddr("newTrader");

        // Test 1: Non-owner cannot call setTrader
        vm.startPrank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        creditVault.setTrader(newTrader, newTrader, newTrader, true);
        vm.stopPrank();

        // Test 2: Cannot set zero address as trader or settler
        vm.startPrank(deployer);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        creditVault.setTrader(address(0), newTrader, newTrader, true);

        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        creditVault.setTrader(newTrader, address(0), newTrader, true);

        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        creditVault.setTrader(newTrader, newTrader, address(0), true);

        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        creditVault.setTrader(address(0), address(0), address(0), true);
        vm.stopPrank();

        // Test 3: Successfully enable trader and verify states
        vm.startPrank(deployer);
        creditVault.setTrader(newTrader, newTrader, newTrader, true);

        // Verify states
        assertTrue(creditVault.traders(newTrader), "Trader should be enabled");
        assertEq(creditVault.traderToSettler(newTrader), newTrader, "Settler address should be set correctly");
        assertEq(creditVault.traderToRecipient(newTrader), newTrader, "Recipient address should be set correctly");
        vm.stopPrank();

        // Test 4: Successfully disable trader and verify states
        vm.startPrank(deployer);
        creditVault.setTrader(newTrader, newTrader, newTrader, false);

        // Verify states after disable
        assertFalse(creditVault.traders(newTrader), "Trader should be disabled");
        assertEq(creditVault.traderToSettler(newTrader), newTrader, "Settler address should remain unchanged");
        assertEq(creditVault.traderToRecipient(newTrader), newTrader, "Recipient address should remain unchanged");
        vm.stopPrank();

        // Test 5: Can re-enable disabled trader
        vm.startPrank(deployer);
        creditVault.setTrader(newTrader, newTrader, newTrader, true);

        // Verify states after re-enable
        assertTrue(creditVault.traders(newTrader), "Trader should be re-enabled");
        assertEq(creditVault.traderToSettler(newTrader), newTrader, "Settler address should remain unchanged");
        assertEq(creditVault.traderToRecipient(newTrader), newTrader, "Recipient address should remain unchanged");
        vm.stopPrank();
    }

    function test_setLiquidator() public {
        address newLiquidator = makeAddr("newLiquidator");

        // Test 1: Non-owner cannot call setLiquidator
        vm.startPrank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        creditVault.setLiquidator(newLiquidator, newLiquidator, true);
        vm.stopPrank();

        // Test 2: Cannot set zero address as liquidator
        vm.startPrank(deployer);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        creditVault.setLiquidator(address(0), address(0), true);
        vm.stopPrank();

        // Test 3: Successfully enable liquidator and verify state
        vm.startPrank(deployer);
        creditVault.setLiquidator(newLiquidator, newLiquidator, true);

        // Verify state
        assertTrue(creditVault.liquidators(newLiquidator), "Liquidator should be enabled");
        vm.stopPrank();

        // Test 4: Successfully disable liquidator and verify state
        vm.startPrank(deployer);
        creditVault.setLiquidator(newLiquidator, newLiquidator, false);

        // Verify state after disable
        assertFalse(creditVault.liquidators(newLiquidator), "Liquidator should be disabled");
        vm.stopPrank();

        // Test 5: Can re-enable disabled liquidator
        vm.startPrank(deployer);
        creditVault.setLiquidator(newLiquidator, newLiquidator, true);

        // Verify state after re-enable
        assertTrue(creditVault.liquidators(newLiquidator), "Liquidator should be re-enabled");
        vm.stopPrank();
    }

    function test_setSigner() public {
        address newSigner = makeAddr("newSigner");

        // Test 1: Non-owner cannot call setSigner
        vm.startPrank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        creditVault.setSigner(newSigner);
        vm.stopPrank();

        // Test 2: Cannot set zero address as signer
        vm.startPrank(deployer);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        creditVault.setSigner(address(0));
        vm.stopPrank();

        // Test 3: Successfully set new signer and verify state
        vm.startPrank(deployer);
        // Store old signer for comparison
        address oldSigner = creditVault.signer();

        // Set new signer
        creditVault.setSigner(newSigner);

        // Verify state
        assertEq(creditVault.signer(), newSigner, "New signer should be set correctly");
        assertNotEq(creditVault.signer(), oldSigner, "Signer should be different from old signer");
        vm.stopPrank();

        // Test 4: Can update signer multiple times
        vm.startPrank(deployer);
        address anotherSigner = makeAddr("anotherSigner");
        creditVault.setSigner(anotherSigner);

        // Verify updated state
        assertEq(creditVault.signer(), anotherSigner, "Another signer should be set correctly");
        assertNotEq(creditVault.signer(), newSigner, "Signer should be different from previous signer");
        vm.stopPrank();
    }

    function test_setEpochUpdater() public {
        address newEpochUpdater = makeAddr("newEpochUpdater");

        // Test 1: Non-owner cannot call setEpochUpdater
        vm.startPrank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        creditVault.setEpochUpdater(newEpochUpdater);
        vm.stopPrank();

        // Test 2: Cannot set zero address as epoch updater
        vm.startPrank(deployer);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        creditVault.setEpochUpdater(address(0));
        vm.stopPrank();

        // Test 3: Successfully set new epoch updater and verify state
        vm.startPrank(deployer);
        // Store old epoch updater for comparison
        address oldEpochUpdater = creditVault.epochUpdater();

        // Set new epoch updater
        creditVault.setEpochUpdater(newEpochUpdater);

        // Verify state
        assertEq(creditVault.epochUpdater(), newEpochUpdater, "New epoch updater should be set correctly");
        assertNotEq(creditVault.epochUpdater(), oldEpochUpdater, "Epoch updater should be different from old updater");
        vm.stopPrank();

        // Test 4: Can update epoch updater multiple times
        vm.startPrank(deployer);
        address anotherEpochUpdater = makeAddr("anotherEpochUpdater");
        creditVault.setEpochUpdater(anotherEpochUpdater);

        // Verify updated state
        assertEq(creditVault.epochUpdater(), anotherEpochUpdater, "Another epoch updater should be set correctly");
        assertNotEq(
            creditVault.epochUpdater(), newEpochUpdater, "Epoch updater should be different from previous updater"
        );
        vm.stopPrank();
    }

    function test_setFeeWithdrawer() public {
        address payable newFeeWithdrawer = payable(makeAddr("newFeeWithdrawer"));

        // Test 1: Non-owner cannot call setFeeWithdrawer
        vm.startPrank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        creditVault.setFeeWithdrawer(newFeeWithdrawer);
        vm.stopPrank();

        // Test 2: Cannot set zero address as fee withdrawer
        vm.startPrank(deployer);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        creditVault.setFeeWithdrawer(payable(address(0)));
        vm.stopPrank();

        // Test 3: Successfully set new fee withdrawer and verify state
        vm.startPrank(deployer);
        // Store old fee withdrawer for comparison
        address oldFeeWithdrawer = creditVault.feeWithdrawer();

        // Set new fee withdrawer
        creditVault.setFeeWithdrawer(newFeeWithdrawer);

        // Verify state
        assertEq(creditVault.feeWithdrawer(), newFeeWithdrawer, "New fee withdrawer should be set correctly");
        assertNotEq(
            creditVault.feeWithdrawer(), oldFeeWithdrawer, "Fee withdrawer should be different from old withdrawer"
        );
        vm.stopPrank();

        // Test 4: Can update fee withdrawer multiple times
        vm.startPrank(deployer);
        address payable anotherFeeWithdrawer = payable(makeAddr("anotherFeeWithdrawer"));
        creditVault.setFeeWithdrawer(anotherFeeWithdrawer);

        // Verify updated state
        assertEq(creditVault.feeWithdrawer(), anotherFeeWithdrawer, "Another fee withdrawer should be set correctly");
        assertNotEq(
            creditVault.feeWithdrawer(), newFeeWithdrawer, "Fee withdrawer should be different from previous withdrawer"
        );
        vm.stopPrank();
    }

    function test_swapCallback() public {
        // Setup: Create and configure a new RFQ pool
        vm.startPrank(deployer);
        NativeRFQPool newRFQPool =
            new NativeRFQPool(address(weth), address(router), address(creditVault), "TestRFQPool");
        newRFQPool.setEnableCallback(true);
        creditVault.setNativePool(address(newRFQPool), true);
        vm.stopPrank();

        address trader = makeAddr("trader");
        address sellerToken = address(weth);
        address buyerToken = address(USDC);
        int256 amountIn = 1 ether;
        int256 amountOut = 3000 * 10 ** 6; // 3000 USDC for 1 ETH

        // Test 1: Non-native pool cannot call swapCallback
        address nonNativePool = makeAddr("nonNativePool");
        vm.startPrank(nonNativePool);
        vm.expectRevert(ErrorsLib.OnlyNativePool.selector);
        creditVault.swapCallback(trader, sellerToken, amountIn, buyerToken, amountOut);
        vm.stopPrank();

        // Store initial positions
        int256 initialSellerTokenPosition = creditVault.positions(trader, sellerToken);
        int256 initialBuyerTokenPosition = creditVault.positions(trader, buyerToken);

        // Test 2: Successful swapCallback from native pool
        vm.prank(address(newRFQPool));
        creditVault.swapCallback(trader, sellerToken, amountIn, buyerToken, amountOut);

        // Verify position changes
        assertEq(
            creditVault.positions(trader, sellerToken),
            initialSellerTokenPosition + amountIn,
            "Seller token position not updated correctly"
        );
        assertEq(
            creditVault.positions(trader, buyerToken),
            initialBuyerTokenPosition - amountOut,
            "Buyer token position not updated correctly"
        );

        // Test 3: Multiple swaps accumulate positions correctly
        vm.prank(address(newRFQPool));
        creditVault.swapCallback(trader, sellerToken, amountIn, buyerToken, amountOut);

        // Verify accumulated position changes
        assertEq(
            creditVault.positions(trader, sellerToken),
            initialSellerTokenPosition + (amountIn * 2),
            "Accumulated seller token position not updated correctly"
        );
        assertEq(
            creditVault.positions(trader, buyerToken),
            initialBuyerTokenPosition - (amountOut * 2),
            "Accumulated buyer token position not updated correctly"
        );
    }

    function test_settle_success() public {
        // 1. Build initial positions for trader (alice) via swapCallback
        vm.startPrank(deployer);
        creditVault.setNativePool(address(rfqPool), true);
        vm.stopPrank();

        // Simulate a trade: alice sells USDC to buy WETH
        vm.prank(address(rfqPool));
        creditVault.swapCallback(
            alice,
            address(USDC),
            6000e6, // Initial USDC long position
            address(weth),
            2 ether // Initial WETH short position
        );

        // 2. Setup alice as trader and deployer as signer
        vm.startPrank(deployer);
        creditVault.setTrader(alice, alice, bob, true);
        creditVault.setSigner(deployer); // Use deployer as the signer
        vm.stopPrank();

        // 3. Setup balances and approvals
        // deal(address(USDC), alice, 3000e6); // alice needs USDC to transfer
        deal(address(weth), alice, 1 ether); // alice needs WETH to transfer
        deal(address(weth), bob, 0); // bob has no WETH
        deal(address(USDC), address(creditVault), 3000e6); // make sure credit vault have enough USDC

        vm.startPrank(alice);
        USDC.approve(address(creditVault), type(uint256).max);
        weth.approve(address(creditVault), type(uint256).max);
        vm.stopPrank();

        // 4. execute settlement
        _executeSettlement(alice, bob);

        // 5. Verify all settlement results

        // Verify positions
        assertEq(
            creditVault.positions(alice, address(weth)),
            -1 ether, // -2 ether + 1 ether = -1 ether
            "WETH position not updated correctly"
        );
        assertEq(
            creditVault.positions(alice, address(USDC)),
            (3000e6), // Initial 1M USDC
            "USDC position not updated correctly"
        );

        // Verify balances
        assertEq(
            weth.balanceOf(alice),
            0, // alice's WETH should be transferred to vault
            "WETH not transferred from trader"
        );

        assertEq(
            USDC.balanceOf(bob),
            1_003_000e6, // Initial 1M USDC + 3000e6 from settlement
            "USDC not transferred to recipient"
        );
    }

    function _executeSettlement(address trader, address recipient) internal {
        ICreditVault.TokenAmountInt[] memory positionUpdates = new ICreditVault.TokenAmountInt[](2);

        // For USDC: Current = 6000e6 (long)
        positionUpdates[0] = ICreditVault.TokenAmountInt({
            token: address(USDC),
            amount: -3000e6 // Negative: vault transfers to recipient to reduce long position
        });

        // For WETH: Current = -2 ether (short)
        positionUpdates[1] = ICreditVault.TokenAmountInt({
            token: address(weth),
            amount: 1 ether // Positive: alice transfers to vault to reduce short position
        });

        ICreditVault.SettlementRequest memory request = ICreditVault.SettlementRequest({
            nonce: 0,
            deadline: block.timestamp + 3600, // 1 hour from now
            trader: trader,
            positionUpdates: positionUpdates
        });

        bytes32 digest = SignatureUtils.generateSettleSignature(request, recipient, address(creditVault));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(deployerKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.startPrank(trader);
        creditVault.settle(request, signature);
        vm.stopPrank();
    }

    function test_addCollateral_success() public {
        // Setup initial balances
        uint256 collateralAmount = 1000e6;
        deal(address(lpUSDC), alice, collateralAmount);

        // Record initial states
        uint256 initialVaultBalance = IERC20(lpUSDC).balanceOf(address(creditVault));
        uint256 initialCollateral = creditVault.creditCollateral(alice, address(lpUSDC));

        // Prepare token array
        ICreditVault.TokenAmountUint[] memory tokens = new ICreditVault.TokenAmountUint[](1);
        tokens[0] = ICreditVault.TokenAmountUint({token: address(lpUSDC), amount: collateralAmount});

        // Approve and add collateral
        vm.startPrank(alice);
        IERC20(lpUSDC).approve(address(creditVault), collateralAmount);
        console2.log(uint256(111));
        console2.log(uint256(collateralAmount));
        // console2.log(address(lpUSDC));
        // console2.log(address(USDC));
        creditVault.addCollateral(tokens, alice);
        console2.log(uint256(222));
        vm.stopPrank();

        // Verify states after adding collateral
        assertEq(
            creditVault.creditCollateral(alice, address(lpUSDC)),
            initialCollateral + collateralAmount,
            "Collateral not added correctly"
        );
        assertEq(
            IERC20(lpUSDC).balanceOf(address(creditVault)),
            initialVaultBalance + collateralAmount,
            "Vault balance not updated correctly"
        );
        assertEq(IERC20(lpUSDC).balanceOf(alice), 0, "User balance not updated correctly");
    }

    function test_addCollateral_multipleTokens() public {
        // Setup initial balances for multiple LP tokens
        uint256 usdcAmount = 1000e6;
        uint256 wethAmount = 1 ether;
        deal(address(lpUSDC), alice, usdcAmount);
        deal(address(lpWETH), alice, wethAmount);

        // Prepare token array
        ICreditVault.TokenAmountUint[] memory tokens = new ICreditVault.TokenAmountUint[](2);
        tokens[0] = ICreditVault.TokenAmountUint({token: address(lpUSDC), amount: usdcAmount});
        tokens[1] = ICreditVault.TokenAmountUint({token: address(lpWETH), amount: wethAmount});

        // Approve and add collateral
        vm.startPrank(alice);
        IERC20(lpUSDC).approve(address(creditVault), usdcAmount);
        IERC20(lpWETH).approve(address(creditVault), wethAmount);
        creditVault.addCollateral(tokens, alice);
        vm.stopPrank();

        // Verify states for both tokens
        assertEq(
            creditVault.creditCollateral(alice, address(lpUSDC)), usdcAmount, "USDC collateral not added correctly"
        );
        assertEq(
            creditVault.creditCollateral(alice, address(lpWETH)), wethAmount, "WETH collateral not added correctly"
        );
    }

    function test_addCollateral_notLpToken() public {
        // Try to add non-LP token as collateral
        uint256 amount = 1000e6;
        deal(address(USDC), alice, amount);

        ICreditVault.TokenAmountUint[] memory tokens = new ICreditVault.TokenAmountUint[](1);
        tokens[0] = ICreditVault.TokenAmountUint({
            token: address(USDC), // Using USDC instead of lpUSDC
            amount: amount
        });

        vm.startPrank(alice);
        USDC.approve(address(creditVault), amount);

        // Should revert because USDC is not an LP token
        vm.expectRevert(ErrorsLib.OnlyLpToken.selector);
        creditVault.addCollateral(tokens, alice);
        vm.stopPrank();
    }

    function test_addCollateral_addForOthers() public {
        // Setup initial LP token state
        uint256 amount = 1000e6;

        // First mint USDC to alice
        deal(address(USDC), alice, amount);

        // Alice approves and deposits USDC to get lpUSDC
        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), amount);
        vm.stopPrank();

        // Deployer sets minDeposit and Alice deposits
        vm.startPrank(deployer);
        lpUSDC.setMinDeposit(100); // Set a small minimum deposit amount
        vm.stopPrank();

        vm.startPrank(alice);
        lpUSDC.deposit(amount);
        // Approve creditVault to spend lpUSDC right after deposit
        lpUSDC.approve(address(creditVault), amount);

        vm.stopPrank();

        // Prepare token array for adding collateral
        ICreditVault.TokenAmountUint[] memory tokens = new ICreditVault.TokenAmountUint[](1);
        tokens[0] = ICreditVault.TokenAmountUint({token: address(lpUSDC), amount: amount});

        // Record initial collateral for bob
        uint256 initialBobCollateral = creditVault.creditCollateral(bob, address(lpUSDC));

        // Alice adds collateral for Bob
        vm.startPrank(alice);
        try creditVault.addCollateral(tokens, bob) {
            console2.log("addCollateral succeeded");
        } catch Error(string memory reason) {
            console2.log("addCollateral failed with reason:", reason);
        }
        vm.stopPrank();

        // Verify Bob's collateral increased
        assertEq(
            creditVault.creditCollateral(bob, address(lpUSDC)),
            initialBobCollateral + amount,
            "Collateral not added correctly for other user"
        );
    }

    function test_removeCollateral() public {
        // Setup: First add some collateral
        uint256 amount = 1000e6;

        // First mint USDC to alice and deposit to get lpUSDC
        deal(address(USDC), alice, amount);
        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), amount);
        vm.stopPrank();

        vm.startPrank(deployer);
        lpUSDC.setMinDeposit(100);
        // Set alice as trader and settler
        creditVault.setTrader(alice, alice, alice, true);
        vm.stopPrank();

        vm.startPrank(alice);
        lpUSDC.deposit(amount);
        lpUSDC.approve(address(creditVault), amount);

        // Add collateral
        ICreditVault.TokenAmountUint[] memory addTokens = new ICreditVault.TokenAmountUint[](1);
        addTokens[0] = ICreditVault.TokenAmountUint({token: address(lpUSDC), amount: amount});
        creditVault.addCollateral(addTokens, alice);
        vm.stopPrank();

        // Prepare remove collateral request
        ICreditVault.TokenAmountUint[] memory removeTokens = new ICreditVault.TokenAmountUint[](1);
        removeTokens[0] = ICreditVault.TokenAmountUint({
            token: address(lpUSDC),
            amount: amount / 2 // Remove half of the collateral
        });

        ICreditVault.RemoveCollateralRequest memory request = ICreditVault.RemoveCollateralRequest({
            nonce: 0,
            deadline: block.timestamp + 3600,
            trader: alice,
            tokens: removeTokens
        });

        // Generate signature
        bytes32 digest = SignatureUtils.generateRemoveCollateralSignature(request, alice, address(creditVault));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(deployerKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Record initial states
        uint256 initialCollateral = creditVault.creditCollateral(alice, address(lpUSDC));
        uint256 initialBalance = lpUSDC.balanceOf(alice);

        // Execute remove collateral
        vm.startPrank(alice);
        creditVault.removeCollateral(request, signature);
        vm.stopPrank();

        // Verify states after removal
        assertEq(
            creditVault.creditCollateral(alice, address(lpUSDC)),
            initialCollateral - amount / 2,
            "Collateral not reduced correctly"
        );
        assertEq(lpUSDC.balanceOf(alice), initialBalance + amount / 2, "LP tokens not returned correctly");

        request = ICreditVault.RemoveCollateralRequest({
            nonce: 1,
            deadline: block.timestamp - 1, // Expired deadline
            trader: alice,
            tokens: removeTokens
        });

        digest = SignatureUtils.generateRemoveCollateralSignature(request, alice, address(creditVault));
        (v, r, s) = vm.sign(deployerKey, digest);
        signature = abi.encodePacked(r, s, v);

        // Should revert with expired deadline
        vm.startPrank(alice);
        vm.expectRevert(ErrorsLib.RequestExpired.selector);
        creditVault.removeCollateral(request, signature);
        vm.stopPrank();

        request = ICreditVault.RemoveCollateralRequest({
            nonce: 2,
            deadline: block.timestamp + 3600,
            trader: alice,
            tokens: removeTokens
        });

        // Use wrong private key to sign
        uint256 wrongKey = 0x12345;
        digest = SignatureUtils.generateRemoveCollateralSignature(request, alice, address(creditVault));
        (v, r, s) = vm.sign(wrongKey, digest);
        signature = abi.encodePacked(r, s, v);

        // Should revert with invalid signature
        vm.startPrank(alice);
        vm.expectRevert(ErrorsLib.InvalidSignature.selector);
        creditVault.removeCollateral(request, signature);
        vm.stopPrank();
    }

    function test_liquidate_success() public {
        uint256 amount = 1000e6;

        // 1. Setup native pool and create initial position via swapCallback
        vm.startPrank(deployer);
        creditVault.setNativePool(address(rfqPool), true);
        creditVault.setLiquidator(bob, bob, true);
        creditVault.setSigner(deployer);
        creditVault.setTrader(alice, alice, bob, true);
        vm.stopPrank();

        // Simulate a trade: alice sells USDC to buy WETH
        vm.prank(address(rfqPool));
        creditVault.swapCallback(
            alice,
            address(USDC),
            6000e6, // Initial USDC long position
            address(weth),
            2 ether // Initial WETH short position
        );

        // 2. Add collateral for the trader to be liquidated
        deal(address(lpUSDC), alice, amount);
        vm.startPrank(alice);
        lpUSDC.approve(address(creditVault), amount);

        ICreditVault.TokenAmountUint[] memory addTokens = new ICreditVault.TokenAmountUint[](1);
        addTokens[0] = ICreditVault.TokenAmountUint({token: address(lpUSDC), amount: amount});
        creditVault.addCollateral(addTokens, alice);
        vm.stopPrank();

        // 3. Ensure CreditVault has enough USDC and WETH
        deal(address(USDC), address(creditVault), 6000e6);
        deal(address(weth), address(creditVault), 2 ether);

        // 4. Ensure bob has enough WETH and approve CreditVault
        deal(address(weth), bob, 1 ether);
        vm.startPrank(bob);
        weth.approve(address(creditVault), 1 ether);
        vm.stopPrank();

        bytes memory signature;
        ICreditVault.LiquidationRequest memory request;
        {
            // 5. Prepare liquidation request
            ICreditVault.TokenAmountInt[] memory positionUpdates = new ICreditVault.TokenAmountInt[](2);
            positionUpdates[0] = ICreditVault.TokenAmountInt({
                token: address(USDC),
                amount: -3000e6 // Reduce USDC long position
            });
            positionUpdates[1] = ICreditVault.TokenAmountInt({
                token: address(weth),
                amount: 1 ether // Reduce WETH short position
            });

            ICreditVault.TokenAmountUint[] memory claimCollaterals = new ICreditVault.TokenAmountUint[](1);
            claimCollaterals[0] = ICreditVault.TokenAmountUint({
                token: address(lpUSDC),
                amount: amount / 2 // Claim half of the collateral
            });

            // ICreditVault.LiquidationRequest memory request = ICreditVault.LiquidationRequest({
            request = ICreditVault.LiquidationRequest({
                nonce: 0,
                deadline: block.timestamp + 3600,
                trader: alice,
                positionUpdates: positionUpdates,
                claimCollaterals: claimCollaterals
            });

            // 5. Generate and sign liquidation request
            bytes32 digest = SignatureUtils.generateLiquidationSignature(
                request, creditVault.traderToRecipient(alice), address(creditVault)
            );
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(deployerKey, digest);
            signature = abi.encodePacked(r, s, v);
        }

        // 6. Record initial states
        uint256 initialCollateral = creditVault.creditCollateral(alice, address(lpUSDC));
        uint256 initialBalance = lpUSDC.balanceOf(bob);
        int256 initialUSDCPosition = creditVault.positions(alice, address(USDC));
        int256 initialWETHPosition = creditVault.positions(alice, address(weth));

        // 7. Execute liquidation
        vm.startPrank(charlie);
        vm.expectRevert(ErrorsLib.OnlyLiquidator.selector);
        creditVault.liquidate(request, signature);
        vm.stopPrank();

        // 8. Execute liquidation
        vm.startPrank(bob);
        creditVault.liquidate(request, signature);
        vm.stopPrank();

        // 9. Verify states after liquidation
        // Check collateral changes
        assertEq(
            creditVault.creditCollateral(alice, address(lpUSDC)),
            initialCollateral - amount / 2,
            "Collateral not reduced correctly"
        );
        assertEq(lpUSDC.balanceOf(bob), initialBalance + amount / 2, "LP tokens not transferred correctly");

        // Check position changes
        assertEq(
            creditVault.positions(alice, address(USDC)),
            initialUSDCPosition + (-3000e6),
            "USDC position not updated correctly"
        );
        assertEq(
            creditVault.positions(alice, address(weth)),
            initialWETHPosition + 1 ether,
            "WETH position not updated correctly"
        );
    }

    function test_liquidate_notLiquidator() public {
        uint256 amount = 1000e6;

        // Setup similar to success case but don't set bob as liquidator
        deal(address(USDC), alice, amount);
        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), amount);
        lpUSDC.deposit(amount);
        lpUSDC.approve(address(creditVault), amount);

        ICreditVault.TokenAmountUint[] memory addTokens = new ICreditVault.TokenAmountUint[](1);
        addTokens[0] = ICreditVault.TokenAmountUint({token: address(lpUSDC), amount: amount});
        creditVault.addCollateral(addTokens, alice);
        vm.stopPrank();

        // Prepare liquidation request
        ICreditVault.TokenAmountInt[] memory positionUpdates = new ICreditVault.TokenAmountInt[](1);
        positionUpdates[0] = ICreditVault.TokenAmountInt({token: address(USDC), amount: -500e6});

        ICreditVault.TokenAmountUint[] memory claimCollaterals = new ICreditVault.TokenAmountUint[](1);
        claimCollaterals[0] = ICreditVault.TokenAmountUint({token: address(lpUSDC), amount: amount / 2});

        ICreditVault.LiquidationRequest memory request = ICreditVault.LiquidationRequest({
            nonce: 0,
            deadline: block.timestamp + 3600,
            trader: alice,
            positionUpdates: positionUpdates,
            claimCollaterals: claimCollaterals
        });

        bytes32 digest = SignatureUtils.generateLiquidationSignature(request, bob, address(creditVault));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(deployerKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Should revert when non-liquidator tries to liquidate
        vm.startPrank(bob);
        vm.expectRevert(ErrorsLib.OnlyLiquidator.selector);
        creditVault.liquidate(request, signature);
        vm.stopPrank();
    }

    function test_repay_success() public {
        // 1. Setup initial positions via swapCallback
        vm.startPrank(deployer);
        creditVault.setNativePool(address(rfqPool), true);
        vm.stopPrank();

        // Simulate a trade: alice sells USDC to buy WETH
        vm.prank(address(rfqPool));
        creditVault.swapCallback(
            alice,
            address(USDC),
            6000e6, // Initial USDC long position
            address(weth),
            2 ether // Initial WETH short position
        );

        // 2. Setup balances and approvals for repayment
        deal(address(weth), alice, 1 ether); // alice needs WETH to repay

        vm.startPrank(alice);
        weth.approve(address(creditVault), 1 ether);

        // 3. Prepare repayment
        ICreditVault.TokenAmountInt[] memory positionUpdates = new ICreditVault.TokenAmountInt[](1);
        positionUpdates[0] = ICreditVault.TokenAmountInt({
            token: address(weth),
            amount: 1 ether // Repay 1 ether
        });

        // 4. Record initial states
        int256 initialWETHPosition = creditVault.positions(alice, address(weth));
        uint256 initialWETHBalance = weth.balanceOf(alice);
        uint256 initialVaultWETHBalance = weth.balanceOf(address(creditVault));

        // 5. Execute repay
        creditVault.repay(positionUpdates, alice);
        vm.stopPrank();

        // 6. Verify states after repayment
        // Check position changes
        assertEq(
            creditVault.positions(alice, address(weth)),
            initialWETHPosition + 1 ether,
            "WETH position not updated correctly"
        );

        // Check balance changes
        assertEq(weth.balanceOf(alice), initialWETHBalance - 1 ether, "WETH not deducted from user");
        assertEq(weth.balanceOf(address(creditVault)), initialVaultWETHBalance + 1 ether, "WETH not added to vault");
    }

    function test_payLPtoken() public {
        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), 10_000e6);
        lpUSDC.deposit(10_000e6);
        vm.stopPrank();

        uint256 vaultInitialBalance = USDC.balanceOf(address(creditVault));
        uint256 aliceInitialBalance = USDC.balanceOf(alice);

        uint256 amount = 1000e6;

        // Test 1: Non-supported market cannot call pay
        address nonSupportedMarket = makeAddr("nonSupportedMarket");
        vm.prank(nonSupportedMarket);
        vm.expectRevert(ErrorsLib.OnlyLpToken.selector);
        creditVault.pay(alice, amount);

        // Test 2: Cannot pay more than totalUnderlying
        vm.prank(address(lpUSDC));
        vm.expectRevert(ErrorsLib.InsufficientUnderlying.selector);
        creditVault.pay(alice, 1_000_000e6);

        // Test 3: Successful transfer from supported LP token
        vm.prank(address(lpUSDC));
        creditVault.pay(alice, amount);

        // Verify balances after transfer
        assertEq(
            USDC.balanceOf(alice), aliceInitialBalance + amount, "Recipient balance should increase by transfer amount"
        );
        assertEq(
            USDC.balanceOf(address(creditVault)),
            vaultInitialBalance - amount,
            "Vault balance should decrease by transfer amount"
        );
    }
}
