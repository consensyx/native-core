// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {BaseTest} from "../BaseTest.t.sol";
import {NativeRFQPool} from "../../src/NativeRFQPool.sol";
import {IQuote} from "../../src/interfaces/IQuote.sol";
import {SignatureUtils} from "../helpers/SignatureUtils.sol";
import {ErrorsLib} from "../../src/libraries/ErrorsLib.sol";

import {console2 as console} from "forge-std/console2.sol";

contract NativeRouterTest is BaseTest {
    function setUp() public virtual override {
        super.setUp();
    }

    function test_tradeRFQWithCredit() public {
        setupPMM();

        // Mint WETH for Alice
        deal(address(weth), alice, 10 ether);

        // Store initial balances first
        uint256 aliceInitialEth = weth.balanceOf(alice);
        uint256 aliceInitialUsdc = USDC.balanceOf(alice);
        uint256 vaultInitialEth = weth.balanceOf(address(creditVault));
        int256 haloInitialEthPosition = creditVault.positions(halo, address(weth));
        int256 haloInitialUsdcPosition = creditVault.positions(halo, address(USDC));

        // Calculate amounts
        uint256 ethPriceInUsdc = 3000 * 10 ** 6;
        uint256 sellAmount = _calculateSellAmount();
        uint256 expectedUsdcAmount = sellAmount * ethPriceInUsdc / 1 ether;

        deal(address(USDC), bob, expectedUsdcAmount);
        vm.startPrank(bob);

        USDC.approve(address(lpUSDC), expectedUsdcAmount);
        lpUSDC.deposit(expectedUsdcAmount);
        vm.stopPrank();
        uint256 vaultInitialUsdc = USDC.balanceOf(address(creditVault));

        // Execute the trade
        IQuote.RFQTQuote memory quote = _createQuote(address(rfqPool), sellAmount, expectedUsdcAmount);

        vm.startPrank(alice);
        weth.approve(address(router), sellAmount);
        router.tradeRFQT(quote, quote.sellerTokenAmount, quote.amountOutMinimum);
        vm.stopPrank();

        // Verify results
        _verifyTradeResults(
            sellAmount,
            expectedUsdcAmount,
            aliceInitialEth,
            aliceInitialUsdc,
            vaultInitialEth,
            vaultInitialUsdc,
            haloInitialEthPosition,
            haloInitialUsdcPosition
        );
    }

    function test_tradeRFQWithPMMInventory() public {
        setupPMM();

        // Mint WETH for Alice (this is still needed since BaseTest doesn't give Alice any WETH)
        deal(address(weth), alice, 10 ether);

        // Approve PMM pool to spend Halo's USDC
        vm.prank(halo);
        USDC.approve(address(haloRFQPool), type(uint256).max);

        // Store initial balances
        uint256 aliceInitialEth = weth.balanceOf(alice);
        uint256 aliceInitialUsdc = USDC.balanceOf(alice);
        uint256 haloInitialUsdc = USDC.balanceOf(halo);

        // Calculate amounts
        uint256 ethPriceInUsdc = 3000 * 10 ** 6;
        uint256 sellAmount = _calculateSellAmount();
        uint256 expectedUsdcAmount = sellAmount * ethPriceInUsdc / 1 ether;

        // Create and execute the trade
        IQuote.RFQTQuote memory quote = _createQuote(address(haloRFQPool), sellAmount, expectedUsdcAmount);

        vm.startPrank(alice);
        weth.approve(address(router), sellAmount);
        router.tradeRFQT(quote, 0, 0);
        vm.stopPrank();

        // Verify PMM trade results
        assertEq(weth.balanceOf(alice), aliceInitialEth - sellAmount, "Alice ETH balance incorrect");
        assertEq(USDC.balanceOf(alice), aliceInitialUsdc + expectedUsdcAmount, "Alice USDC balance incorrect");
        assertEq(USDC.balanceOf(halo), haloInitialUsdc - expectedUsdcAmount, "Halo USDC balance incorrect");
    }

    function test_tradeRFQWithERC20TokenWithWidgetFee() public {
        setupPMM();

        deal(address(weth), alice, 10 ether);

        vm.startPrank(deployer);
        USDC.mint(halo, 1_000_000 * 10 ** 6);
        vm.stopPrank();

        vm.startPrank(halo);
        USDC.approve(address(haloRFQPool), type(uint256).max);
        vm.stopPrank();

        uint256[5] memory initialBalances = [
            weth.balanceOf(alice),
            USDC.balanceOf(alice),
            weth.balanceOf(halo),
            USDC.balanceOf(halo),
            weth.balanceOf(deployer)
        ];

        IQuote.RFQTQuote memory quote;
        uint256 sellAmount;
        uint256 effectiveUsdcAmount;
        uint256 expectedWidgetFee;

        // Block 1: Calculate amounts and create quote
        {
            // 1 WETH = 3000 USDC
            sellAmount = 1 ether;
            uint256 expectedUsdcAmount = 3000 * 10 ** 6;
            uint256 widgetFeeRate = 100; // 1%
            expectedWidgetFee = sellAmount * widgetFeeRate / 10_000;
            uint256 effectiveSellAmount = sellAmount - expectedWidgetFee;
            effectiveUsdcAmount = (effectiveSellAmount * expectedUsdcAmount) / sellAmount;

            quote = IQuote.RFQTQuote({
                pool: address(haloRFQPool),
                signer: halo,
                recipient: alice,
                sellerToken: address(weth),
                buyerToken: address(USDC),
                sellerTokenAmount: sellAmount,
                buyerTokenAmount: expectedUsdcAmount,
                deadlineTimestamp: block.timestamp + 1 hours,
                nonce: 0,
                confidenceExtractedValueT: 0,
                confidenceExtractedValueN: block.timestamp + 1 hours,
                confidenceExtractedValueE: 0,
                confidenceExtractedValueM: 0,
                quoteId: bytes16(uint128(1)),
                multiHop: false,
                signature: bytes(""),
                widgetFee: IQuote.WidgetFee({feeRecipient: deployer, feeRate: widgetFeeRate}),
                widgetFeeSignature: bytes(""),
                amountOutMinimum: effectiveUsdcAmount
            });
        }

        // Block 2: Generate signatures
        {
            bytes32 quoteDigest = SignatureUtils.generateQuoteSignature(quote);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(haloKey, quoteDigest);
            quote.signature = abi.encodePacked(r, s, v);

            bytes32 widgetFeeDigest = SignatureUtils.generateWidgetFeeSignature(quote, address(router));
            (v, r, s) = vm.sign(deployerKey, widgetFeeDigest);
            quote.widgetFeeSignature = abi.encodePacked(r, s, v);
        }

        // Block 3: Execute trade and verify results
        {
            vm.startPrank(alice);
            weth.approve(address(router), sellAmount);
            router.tradeRFQT(quote, 0, 0);
            vm.stopPrank();

            // verify balances
            assertEq(weth.balanceOf(alice), initialBalances[0] - sellAmount, "Alice WETH balance incorrect");
            assertEq(USDC.balanceOf(alice), initialBalances[1] + effectiveUsdcAmount, "Alice USDC balance incorrect");
            assertEq(
                weth.balanceOf(halo), initialBalances[2] + sellAmount - expectedWidgetFee, "Halo WETH balance incorrect"
            );
            assertEq(USDC.balanceOf(halo), initialBalances[3] - effectiveUsdcAmount, "Halo USDC balance incorrect");
            assertEq(
                weth.balanceOf(deployer), initialBalances[4] + expectedWidgetFee, "Deployer should receive widget fee"
            );
        }
    }

    function test_tradeRFQWithNativeETHAndWidgetFee() public {
        setupPMM();

        // Give Alice some ETH
        vm.deal(alice, 10 ether);

        // Approve PMM pool to spend Halo's USDC
        vm.prank(halo);
        USDC.approve(address(haloRFQPool), type(uint256).max);

        // Store initial balances
        uint256 aliceInitialEth = alice.balance;
        uint256 aliceInitialUsdc = USDC.balanceOf(alice);
        uint256 haloInitialUsdc = USDC.balanceOf(halo);
        uint256 deployerInitialWeth = weth.balanceOf(deployer); // Widget fee recipient

        // Calculate amounts
        uint256 ethPriceInUsdc = 3000 * 10 ** 6;
        uint256 sellAmount = 1 ether; // Use fixed amount for clearer testing
        uint256 quoteUsdcAmount = sellAmount * ethPriceInUsdc / 1 ether; // 3000 USDC

        // Set widget fee rate to 1% (100 basis points)
        uint256 widgetFeeRate = 100;
        uint256 expectedWidgetFee = sellAmount * widgetFeeRate / 10_000;
        uint256 effectiveSellerAmount = sellAmount - expectedWidgetFee;

        // Calculate expected USDC amount after proportional reduction due to widget fee
        uint256 expectedUsdcAmount = (effectiveSellerAmount * quoteUsdcAmount) / sellAmount;

        // Create quote with native ETH (sellerToken = address(0)) and widget fee
        IQuote.RFQTQuote memory quote = _createQuoteWithWidgetFee(
            address(haloRFQPool),
            sellAmount,
            quoteUsdcAmount, // Use the full quote amount, not the reduced amount
            widgetFeeRate
        );

        // Execute the trade with native ETH
        vm.startPrank(alice);
        router.tradeRFQT{value: sellAmount}(quote, 0, 0);
        vm.stopPrank();

        // Verify results
        assertEq(alice.balance, aliceInitialEth - sellAmount, "Alice ETH balance incorrect");
        assertEq(USDC.balanceOf(alice), aliceInitialUsdc + expectedUsdcAmount, "Alice USDC balance incorrect");
        assertEq(USDC.balanceOf(halo), haloInitialUsdc - expectedUsdcAmount, "Halo USDC balance incorrect");

        // Verify widget fee was charged correctly (fee recipient should receive WETH)
        assertEq(
            weth.balanceOf(deployer),
            deployerInitialWeth + expectedWidgetFee,
            "Widget fee recipient WETH balance incorrect"
        );

        // Verify the pool treasury received the correct amount (after fee deduction)
        // Since haloRFQPool.treasury() returns halo's address, the WETH goes to halo
        assertEq(weth.balanceOf(halo), effectiveSellerAmount, "Pool treasury WETH balance incorrect");
    }

    function test_tradeRFQMultiHop_Multicall() public {
        setupPMM();

        // Setup
        deal(address(weth), alice, 10 ether);

        vm.startPrank(deployer);
        USDC.mint(halo, 1_000_000 * 10 ** 6);
        wbtc.mint(halo, 100 * 10 ** 8);
        vm.stopPrank();

        vm.startPrank(halo);
        USDC.approve(address(haloRFQPool), type(uint256).max);
        wbtc.approve(address(haloRFQPool), type(uint256).max);
        vm.stopPrank();

        _executeMultiHopTest();
    }

    function test_tradeRFQMultiHop_Multicall_WithNativeETH() public {
        setupPMM();

        // Setup - Give Alice native ETH instead of WETH
        vm.deal(alice, 10 ether);

        vm.startPrank(deployer);
        USDC.mint(halo, 1_000_000 * 10 ** 6);
        wbtc.mint(halo, 100 * 10 ** 8);
        vm.stopPrank();

        vm.startPrank(halo);
        USDC.approve(address(haloRFQPool), type(uint256).max);
        wbtc.approve(address(haloRFQPool), type(uint256).max);
        vm.stopPrank();

        _executeMultiHopTestWithNativeETH();
    }

    function test_tradeRFQT_MulticallUnwrapBuyerTokenToETH() public {
        setupPMM();

        // Setup - Give Alice USDC to trade for WETH
        uint256 usdcAmount = 3000 * 10 ** 6; // 3000 USDC
        deal(address(USDC), alice, usdcAmount);

        // Setup halo with WETH for the trade
        vm.startPrank(deployer);
        deal(address(weth), halo, 10 ether);
        vm.stopPrank();

        vm.startPrank(halo);
        weth.approve(address(haloRFQPool), type(uint256).max);
        vm.stopPrank();

        // Give WETH9 contract some ETH balance for withdrawals
        vm.deal(address(weth), 2 ether);

        _executeBuyerTokenUnwrapToETHTest(usdcAmount);
    }

    function test_measureGasUsageWithConfidenceExtractedValue() public {
        setupPMM();

        // Set a proper current time to avoid underflow
        vm.warp(1000); // Set current time to 1000 seconds

        // Mint WETH for Alice
        deal(address(weth), alice, 10 ether);

        // Calculate amounts
        uint256 ethPriceInUsdc = 3000 * 10 ** 6;
        uint256 sellAmount = _calculateSellAmount();
        uint256 expectedUsdcAmount = sellAmount * ethPriceInUsdc / 1 ether;

        // Setup vault USDC balance
        deal(address(USDC), bob, expectedUsdcAmount);
        vm.startPrank(bob);
        USDC.approve(address(lpUSDC), expectedUsdcAmount);
        lpUSDC.deposit(expectedUsdcAmount);
        vm.stopPrank();

        IQuote.RFQTQuote memory quote =
            _createQuoteWithConfidenceExtractedValue(address(rfqPool), sellAmount, expectedUsdcAmount);

        vm.startPrank(alice);
        weth.approve(address(router), sellAmount);

        // Measure gas usage
        uint256 gasStart = gasleft();
        router.tradeRFQT(quote, quote.sellerTokenAmount, quote.amountOutMinimum);
        uint256 gasUsed = gasStart - gasleft();

        vm.stopPrank();

        console.log("=== Gas Usage Report (With confidenceExtractedValue) ===");
        console.log("Trade amount (WETH):", sellAmount);
        console.log("Expected USDC out:", expectedUsdcAmount);
        console.log("confidenceExtractedValueE:", quote.confidenceExtractedValueE);
        console.log("confidenceExtractedValueM:", quote.confidenceExtractedValueM);
        console.log("confidenceExtractedValueN:", quote.confidenceExtractedValueN);
        console.log("Time elapsed (seconds):", block.timestamp - quote.confidenceExtractedValueT);
        console.log("Gas used for tradeRFQT:", gasUsed);
        console.log("====================================");
    }

    function test_measureGasUsageWithoutConfidenceExtractedValue() public {
        setupPMM();

        // Set a proper current time to avoid underflow
        vm.warp(1000); // Set current time to 1000 seconds

        // Mint WETH for Alice
        deal(address(weth), alice, 10 ether);

        // Calculate amounts
        uint256 ethPriceInUsdc = 3000 * 10 ** 6;
        uint256 sellAmount = _calculateSellAmount();
        uint256 expectedUsdcAmount = sellAmount * ethPriceInUsdc / 1 ether;

        // Setup vault USDC balance
        deal(address(USDC), bob, expectedUsdcAmount);
        vm.startPrank(bob);
        USDC.approve(address(lpUSDC), expectedUsdcAmount);
        lpUSDC.deposit(expectedUsdcAmount);
        vm.stopPrank();

        IQuote.RFQTQuote memory quote = _createQuote(address(rfqPool), sellAmount, expectedUsdcAmount);

        vm.startPrank(alice);
        weth.approve(address(router), sellAmount);

        // Measure gas usage
        uint256 gasStart = gasleft();
        router.tradeRFQT(quote, quote.sellerTokenAmount, quote.amountOutMinimum);
        uint256 gasUsed = gasStart - gasleft();

        vm.stopPrank();

        console.log("=== Gas Usage Report (Without confidenceExtractedValue) ===");
        console.log("Trade amount (WETH):", sellAmount);
        console.log("Expected USDC out:", expectedUsdcAmount);
        console.log("Gas used for tradeRFQT:", gasUsed);
        console.log("========================================");
    }

    function test_externalSwap_Success() public {
        setupPMM();

        // Setup mock external contract address
        address mockExternalContract = makeAddr("mockExternalContract");

        // Setup test parameters
        uint256 returnAmount = 1000 * 10 ** 6; // 1000 USDC returned by external contract
        uint256 minReturnAmount = 900 * 10 ** 6; // 900 USDC minimum expected

        // Use a simple mock function for testing purposes
        bytes memory callData = abi.encodeWithSignature(
            "mockSwapFunction(uint256)",
            1 ether // amountIn
        );

        // Add mock contract to whitelist
        vm.prank(deployer);
        router.setExternalSwapSource(mockExternalContract, true);

        // Mock the external contract call to return the expected amount
        vm.mockCall(mockExternalContract, callData, abi.encode(returnAmount));

        // Generate signature for external swap
        bytes32 digest = SignatureUtils.generateExternalSwapSignature(
            mockExternalContract,
            address(weth),
            mockExternalContract,
            1 ether,
            callData,
            minReturnAmount,
            address(router)
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(deployerKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Create external swap parameters
        IQuote.ExternalSwap memory params = IQuote.ExternalSwap({
            target: mockExternalContract,
            fromToken: address(weth),
            spender: mockExternalContract, // In this test, we'll use the same address for simplicity
            fromTokenAmount: 1 ether,
            minReturnAmount: minReturnAmount,
            callData: callData,
            signature: signature
        });

        // Give Alice some WETH and approve router
        deal(address(weth), alice, params.fromTokenAmount);
        vm.prank(alice);
        weth.approve(address(router), params.fromTokenAmount);

        // Execute external swap
        vm.prank(alice);
        router.externalSwap(params);

        // Cleanup
        vm.clearMockedCalls();
    }

    // Struct to hold hop quote parameters
    struct HopQuoteParams {
        address recipient;
        address sellerToken;
        address buyerToken;
        uint256 sellerTokenAmount;
        uint256 buyerTokenAmount;
        uint256 nonce;
        uint256 quoteId;
        bool multiHop;
        uint256 widgetFeeRate;
        bool applyWidgetFeeToAmount; // Whether to calculate effective amount based on widget fee
    }

    function _createHopQuote(HopQuoteParams memory params) internal view returns (IQuote.RFQTQuote memory) {
        IQuote.RFQTQuote memory quote;

        // Block 1: Calculate amounts and create quote structure
        {
            uint256 amountOutMinimum = params.buyerTokenAmount;

            // Apply widget fee calculation if needed (for first hop)
            if (params.applyWidgetFeeToAmount && params.widgetFeeRate > 0) {
                uint256 effectiveSellerAmount =
                    params.sellerTokenAmount - (params.sellerTokenAmount * params.widgetFeeRate / 10_000);
                amountOutMinimum = (effectiveSellerAmount * params.buyerTokenAmount) / params.sellerTokenAmount;
            }

            quote = IQuote.RFQTQuote({
                pool: address(haloRFQPool),
                signer: halo,
                recipient: params.recipient,
                sellerToken: params.sellerToken,
                buyerToken: params.buyerToken,
                sellerTokenAmount: params.sellerTokenAmount,
                buyerTokenAmount: params.buyerTokenAmount,
                deadlineTimestamp: block.timestamp + 1 hours,
                nonce: params.nonce,
                confidenceExtractedValueT: 0,
                confidenceExtractedValueN: block.timestamp + 1 hours,
                confidenceExtractedValueE: 0,
                confidenceExtractedValueM: 0,
                quoteId: bytes16(uint128(params.quoteId)),
                multiHop: params.multiHop,
                signature: bytes(""),
                widgetFee: IQuote.WidgetFee({feeRecipient: deployer, feeRate: params.widgetFeeRate}),
                widgetFeeSignature: bytes(""),
                amountOutMinimum: amountOutMinimum
            });
        }

        // Block 2: Generate quote signature with proper ETH handling
        {
            // For signature generation, convert address(0) to WETH address like NativeRFQPool does
            IQuote.RFQTQuote memory quoteForSig = quote;
            quoteForSig.sellerToken = quote.sellerToken == address(0) ? address(weth) : quote.sellerToken;
            quoteForSig.buyerToken = quote.buyerToken == address(0) ? address(weth) : quote.buyerToken;

            bytes32 quoteDigest = SignatureUtils.generateQuoteSignature(quoteForSig);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(haloKey, quoteDigest);
            quote.signature = abi.encodePacked(r, s, v);
        }

        // Block 3: Generate widget fee signature
        {
            bytes32 widgetFeeDigest = SignatureUtils.generateWidgetFeeSignature(quote, address(router));
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(deployerKey, widgetFeeDigest);
            quote.widgetFeeSignature = abi.encodePacked(r, s, v);
        }

        return quote;
    }

    function _createFirstHopQuote(
        uint256 wethAmount,
        uint256 usdcAmount,
        uint256 widgetFeeRate
    ) internal view returns (IQuote.RFQTQuote memory) {
        return _createHopQuote(
            HopQuoteParams({
                recipient: address(router),
                sellerToken: address(weth),
                buyerToken: address(USDC),
                sellerTokenAmount: wethAmount,
                buyerTokenAmount: usdcAmount,
                nonce: 0,
                quoteId: 1,
                multiHop: false,
                widgetFeeRate: widgetFeeRate,
                applyWidgetFeeToAmount: true
            })
        );
    }

    function _createSecondHopQuote(
        uint256 usdcAmount,
        uint256 wbtcAmount
    ) internal view returns (IQuote.RFQTQuote memory) {
        return _createHopQuote(
            HopQuoteParams({
                recipient: alice,
                sellerToken: address(USDC),
                buyerToken: address(wbtc),
                sellerTokenAmount: usdcAmount,
                buyerTokenAmount: wbtcAmount,
                nonce: 1,
                quoteId: 2,
                multiHop: true,
                widgetFeeRate: 0,
                applyWidgetFeeToAmount: false
            })
        );
    }

    /// @notice Calculates a random sell amount for testing trades
    /// @dev The amount is capped at 50% of vault balance to avoid liquidity issues
    /// @return sellAmount The calculated sell amount
    function _calculateSellAmount() internal view returns (uint256) {
        // Get Alice's WETH balance
        uint256 aliceEthBalance = weth.balanceOf(alice);

        // Calculate random amount between 10-100% of Alice's balance
        uint256 sellAmount = _randomAmount(aliceEthBalance, 10, lpWETH);

        return sellAmount;
    }

    function _createQuote(
        address poolAddress,
        uint256 sellAmount,
        uint256 expectedUsdcAmount
    ) internal view returns (IQuote.RFQTQuote memory) {
        IQuote.RFQTQuote memory quote;

        // Block 1: Create quote structure
        {
            quote = IQuote.RFQTQuote({
                pool: poolAddress,
                signer: halo,
                recipient: alice,
                sellerToken: address(weth),
                buyerToken: address(USDC),
                sellerTokenAmount: sellAmount,
                buyerTokenAmount: expectedUsdcAmount,
                deadlineTimestamp: block.timestamp + 1 hours,
                nonce: 0,
                confidenceExtractedValueT: 0,
                confidenceExtractedValueN: block.timestamp + 1 hours,
                confidenceExtractedValueE: 0,
                confidenceExtractedValueM: 0,
                quoteId: bytes16(0),
                multiHop: false,
                signature: bytes(""),
                widgetFee: IQuote.WidgetFee({feeRecipient: deployer, feeRate: 0}),
                widgetFeeSignature: bytes(""),
                amountOutMinimum: expectedUsdcAmount
            });
        }

        // Block 2: Generate quote signature
        {
            bytes32 quoteDigest = SignatureUtils.generateQuoteSignature(quote);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(haloKey, quoteDigest);
            quote.signature = abi.encodePacked(r, s, v);
        }

        // Block 3: Generate widget fee signature
        {
            bytes32 widgetFeeDigest = SignatureUtils.generateWidgetFeeSignature(quote, address(router));
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(deployerKey, widgetFeeDigest);
            quote.widgetFeeSignature = abi.encodePacked(r, s, v);
        }

        return quote;
    }

    function _createQuoteWithConfidenceExtractedValue(
        address poolAddress,
        uint256 sellAmount,
        uint256 expectedUsdcAmount
    ) internal view returns (IQuote.RFQTQuote memory) {
        IQuote.RFQTQuote memory quote;

        // Block 1: Calculate timing and create quote structure
        {
            uint256 confidenceExtractedValueT = block.timestamp - 30;
            uint256 deadlineTimestamp = confidenceExtractedValueT + 60;
            uint256 confidenceExtractedValueN = deadlineTimestamp - 20;

            uint256 confidenceRatio = 750_000; // 0.75 * 1e6
            uint256 confidenceExtractedValueM = 100; // 1%

            // ratioPowered = timeRatio^2 = 0.5625 (with 1e12 precision = 562500000000)
            uint256 ratioPowered = confidenceRatio ** 2; // 750000^2 = 562500000000
            uint256 scalePowered = 1e6 ** 2; // 1e12

            // adjustmentBps = (562500000000 * 100 * 10000) / (1e12 * 10000) = 56.25 bps = 0.5625%
            uint256 adjustmentBps = (ratioPowered * confidenceExtractedValueM * 10_000) / (scalePowered * 10_000);

            // Reduce amountOutMinimum by the expected slippage
            uint256 adjustedAmountOutMinimum = expectedUsdcAmount * (10_000 - adjustmentBps) / 10_000;

            quote = IQuote.RFQTQuote({
                pool: poolAddress,
                signer: halo,
                recipient: alice,
                sellerToken: address(weth),
                buyerToken: address(USDC),
                sellerTokenAmount: sellAmount,
                buyerTokenAmount: expectedUsdcAmount,
                deadlineTimestamp: deadlineTimestamp,
                nonce: 0,
                confidenceExtractedValueT: confidenceExtractedValueT,
                confidenceExtractedValueN: confidenceExtractedValueN,
                confidenceExtractedValueE: 2,
                confidenceExtractedValueM: confidenceExtractedValueM,
                quoteId: bytes16(0),
                multiHop: false,
                signature: bytes(""),
                widgetFee: IQuote.WidgetFee({feeRecipient: deployer, feeRate: 0}),
                widgetFeeSignature: bytes(""),
                amountOutMinimum: adjustedAmountOutMinimum
            });
        }

        // Block 2: Generate quote signature
        {
            bytes32 quoteDigest = SignatureUtils.generateQuoteSignature(quote);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(haloKey, quoteDigest);
            quote.signature = abi.encodePacked(r, s, v);
        }

        // Block 3: Generate widget fee signature
        {
            bytes32 widgetFeeDigest = SignatureUtils.generateWidgetFeeSignature(quote, address(router));
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(deployerKey, widgetFeeDigest);
            quote.widgetFeeSignature = abi.encodePacked(r, s, v);
        }

        return quote;
    }

    function _createQuoteWithWidgetFee(
        address poolAddress,
        uint256 sellAmount,
        uint256 expectedUsdcAmount,
        uint256 widgetFeeRate
    ) internal view returns (IQuote.RFQTQuote memory) {
        // Block 1: Create quote for signature generation
        IQuote.RFQTQuote memory quote;
        bytes32 quoteDigest;
        bytes32 widgetFeeDigest;

        {
            // For quote signature, we need to use WETH address since NativeRFQPool converts address(0) to WETH for signature verification
            IQuote.RFQTQuote memory quoteForSig = IQuote.RFQTQuote({
                pool: poolAddress,
                signer: halo,
                recipient: alice,
                sellerToken: address(weth), // Use WETH for signature
                buyerToken: address(USDC),
                sellerTokenAmount: sellAmount,
                buyerTokenAmount: expectedUsdcAmount,
                deadlineTimestamp: block.timestamp + 1 hours,
                nonce: 0,
                confidenceExtractedValueT: 0,
                confidenceExtractedValueN: block.timestamp + 1 hours,
                confidenceExtractedValueE: 0,
                confidenceExtractedValueM: 0,
                quoteId: bytes16(0),
                multiHop: false,
                signature: bytes(""),
                widgetFee: IQuote.WidgetFee({feeRecipient: deployer, feeRate: widgetFeeRate}),
                widgetFeeSignature: bytes(""),
                amountOutMinimum: expectedUsdcAmount
            });

            // Generate quote signature using WETH address
            quoteDigest = SignatureUtils.generateQuoteSignature(quoteForSig);
        }

        // Block 2: Generate signatures and create final quote
        {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(haloKey, quoteDigest);
            bytes memory quoteSignature = abi.encodePacked(r, s, v);

            // Calculate effective amount after widget fee for amountOutMinimum
            uint256 effectiveSellerAmount = sellAmount - (sellAmount * widgetFeeRate / 10_000);
            uint256 effectiveUsdcAmount = (effectiveSellerAmount * expectedUsdcAmount) / sellAmount;

            // Now create the actual quote with address(0) for native ETH
            quote = IQuote.RFQTQuote({
                pool: poolAddress,
                signer: halo,
                recipient: alice,
                sellerToken: address(0), // Native ETH for router
                buyerToken: address(USDC),
                sellerTokenAmount: sellAmount,
                buyerTokenAmount: expectedUsdcAmount,
                deadlineTimestamp: block.timestamp + 1 hours,
                nonce: 0,
                confidenceExtractedValueT: 0,
                confidenceExtractedValueN: block.timestamp + 1 hours,
                confidenceExtractedValueE: 0,
                confidenceExtractedValueM: 0,
                quoteId: bytes16(0),
                multiHop: false,
                signature: quoteSignature, // Use signature generated with WETH
                widgetFee: IQuote.WidgetFee({feeRecipient: deployer, feeRate: widgetFeeRate}),
                widgetFeeSignature: bytes(""),
                amountOutMinimum: effectiveUsdcAmount
            });

            // Generate widget fee signature
            widgetFeeDigest = SignatureUtils.generateWidgetFeeSignature(quote, address(router));
        }

        // Block 3: Finalize widget fee signature
        {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(deployerKey, widgetFeeDigest);
            quote.widgetFeeSignature = abi.encodePacked(r, s, v);
        }

        return quote;
    }

    struct MultiHopParams {
        uint256 wethAmount;
        uint256 widgetFeeRate;
        uint256 expectedWidgetFee;
        uint256 effectiveWethAmount;
        uint256 usdcFromWeth;
        uint256 effectiveUsdcAmount;
        uint256 wbtcFromUsdc;
    }

    function _executeMultiHopTest() internal {
        // Use struct to avoid stack too deep
        MultiHopParams memory params;

        params.wethAmount = 1 ether;
        params.widgetFeeRate = 100; // 1%
        params.expectedWidgetFee = params.wethAmount * params.widgetFeeRate / 10_000;
        params.effectiveWethAmount = params.wethAmount - params.expectedWidgetFee;

        // Calculate swap amounts: 1 WETH = 3000 USDC, 1 WBTC = 90000 USDC
        params.usdcFromWeth = 3000 * 10 ** 6; // 3000 USDC
        params.effectiveUsdcAmount = (params.effectiveWethAmount * params.usdcFromWeth) / params.wethAmount;
        params.wbtcFromUsdc = params.effectiveUsdcAmount * 10 ** 8 / (90_000 * 10 ** 6);

        // Store initial balances
        uint256[3] memory initialBalances = [weth.balanceOf(alice), wbtc.balanceOf(alice), weth.balanceOf(deployer)];

        // Execute atomic multicall
        _executeAtomicMultiHop(params);

        // Verify results
        assertEq(weth.balanceOf(alice), initialBalances[0] - params.wethAmount, "Alice WETH balance incorrect");
        assertEq(wbtc.balanceOf(alice), initialBalances[1] + params.wbtcFromUsdc, "Alice WBTC balance incorrect");
        assertEq(
            weth.balanceOf(deployer),
            initialBalances[2] + params.expectedWidgetFee,
            "Widget fee only charged on first hop"
        );
        assertEq(USDC.balanceOf(address(router)), 0, "No USDC left in router");
    }

    function _executeMultiHopTestWithNativeETH() internal {
        // Use struct to avoid stack too deep
        MultiHopParams memory params;

        params.wethAmount = 1 ether;
        params.widgetFeeRate = 100; // 1%
        params.expectedWidgetFee = params.wethAmount * params.widgetFeeRate / 10_000;
        params.effectiveWethAmount = params.wethAmount - params.expectedWidgetFee;

        // Calculate swap amounts: 1 ETH = 3000 USDC, 1 WBTC = 90000 USDC
        params.usdcFromWeth = 3000 * 10 ** 6; // 3000 USDC
        params.effectiveUsdcAmount = (params.effectiveWethAmount * params.usdcFromWeth) / params.wethAmount;
        params.wbtcFromUsdc = params.effectiveUsdcAmount * 10 ** 8 / (90_000 * 10 ** 6);

        // Store initial balances (using alice.balance for ETH)
        uint256[3] memory initialBalances = [alice.balance, wbtc.balanceOf(alice), weth.balanceOf(deployer)];

        // Execute atomic multicall with native ETH
        _executeAtomicMultiHopWithNativeETH(params);

        // Verify results - Alice's ETH balance should decrease
        assertEq(alice.balance, initialBalances[0] - params.wethAmount, "Alice ETH balance incorrect");
        assertEq(wbtc.balanceOf(alice), initialBalances[1] + params.wbtcFromUsdc, "Alice WBTC balance incorrect");
        assertEq(
            weth.balanceOf(deployer),
            initialBalances[2] + params.expectedWidgetFee,
            "Widget fee only charged on first hop"
        );
        assertEq(USDC.balanceOf(address(router)), 0, "No USDC left in router");
    }

    function _executeAtomicMultiHop(MultiHopParams memory params) internal {
        // Create quotes
        IQuote.RFQTQuote memory firstHop =
            _createFirstHopQuote(params.wethAmount, params.usdcFromWeth, params.widgetFeeRate);
        IQuote.RFQTQuote memory secondHop = _createSecondHopQuote(params.effectiveUsdcAmount, params.wbtcFromUsdc);

        // Prepare multicall data to avoid stack depth issues
        bytes[] memory multicallData = new bytes[](2);
        multicallData[0] = abi.encodeCall(router.tradeRFQT, (firstHop, 0, 0));
        multicallData[1] = abi.encodeCall(router.tradeRFQT, (secondHop, 0, 0));

        // Execute both trades atomically via multicall
        vm.startPrank(alice);
        weth.approve(address(router), params.wethAmount);
        router.multicall(multicallData);
        vm.stopPrank();
    }

    function _executeAtomicMultiHopWithNativeETH(MultiHopParams memory params) internal {
        // Create quotes - first hop uses native ETH (address(0) as sellerToken)
        IQuote.RFQTQuote memory firstHop =
            _createFirstHopQuoteWithNativeETH(params.wethAmount, params.usdcFromWeth, params.widgetFeeRate);
        IQuote.RFQTQuote memory secondHop = _createSecondHopQuote(params.effectiveUsdcAmount, params.wbtcFromUsdc);

        // Prepare multicall data to avoid stack depth issues
        bytes[] memory multicallData = new bytes[](2);
        multicallData[0] = abi.encodeCall(router.tradeRFQT, (firstHop, 0, 0));
        multicallData[1] = abi.encodeCall(router.tradeRFQT, (secondHop, 0, 0));

        // Execute both trades atomically via multicall with ETH value
        vm.startPrank(alice);
        // No WETH approval needed, sending ETH directly
        router.multicall{value: params.wethAmount}(multicallData);
        vm.stopPrank();
    }

    function _createFirstHopQuoteWithNativeETH(
        uint256 ethAmount,
        uint256 usdcAmount,
        uint256 widgetFeeRate
    ) internal view returns (IQuote.RFQTQuote memory) {
        // Create quote for signature generation using WETH address
        IQuote.RFQTQuote memory quoteForSig;
        bytes32 quoteDigest;

        // Calculate effective amount after widget fee
        uint256 effectiveSellerAmount = ethAmount - (ethAmount * widgetFeeRate / 10_000);
        uint256 effectiveUsdcAmount = (effectiveSellerAmount * usdcAmount) / ethAmount;

        {
            quoteForSig = IQuote.RFQTQuote({
                pool: address(haloRFQPool),
                signer: halo,
                recipient: address(router),
                sellerToken: address(weth), // Use WETH for signature
                buyerToken: address(USDC),
                sellerTokenAmount: ethAmount,
                buyerTokenAmount: usdcAmount,
                deadlineTimestamp: block.timestamp + 1 hours,
                nonce: 0,
                confidenceExtractedValueT: 0,
                confidenceExtractedValueN: block.timestamp + 1 hours,
                confidenceExtractedValueE: 0,
                confidenceExtractedValueM: 0,
                quoteId: bytes16(uint128(1)),
                multiHop: false,
                signature: bytes(""),
                widgetFee: IQuote.WidgetFee({feeRecipient: deployer, feeRate: widgetFeeRate}),
                widgetFeeSignature: bytes(""),
                amountOutMinimum: usdcAmount
            });

            // Generate quote signature using WETH address
            quoteDigest = SignatureUtils.generateQuoteSignature(quoteForSig);
        }

        // Generate signatures and create final quote
        {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(haloKey, quoteDigest);
            bytes memory quoteSignature = abi.encodePacked(r, s, v);

            // Now create the actual quote with address(0) for native ETH
            IQuote.RFQTQuote memory quote = IQuote.RFQTQuote({
                pool: address(haloRFQPool),
                signer: halo,
                recipient: address(router),
                sellerToken: address(0), // Native ETH for router
                buyerToken: address(USDC),
                sellerTokenAmount: ethAmount,
                buyerTokenAmount: usdcAmount,
                deadlineTimestamp: block.timestamp + 1 hours,
                nonce: 0,
                confidenceExtractedValueT: 0,
                confidenceExtractedValueN: block.timestamp + 1 hours,
                confidenceExtractedValueE: 0,
                confidenceExtractedValueM: 0,
                quoteId: bytes16(uint128(1)),
                multiHop: false,
                signature: quoteSignature, // Use signature generated with WETH
                widgetFee: IQuote.WidgetFee({feeRecipient: deployer, feeRate: widgetFeeRate}),
                widgetFeeSignature: bytes(""),
                amountOutMinimum: effectiveUsdcAmount
            });

            // Generate widget fee signature
            bytes32 widgetFeeDigest = SignatureUtils.generateWidgetFeeSignature(quote, address(router));
            (v, r, s) = vm.sign(deployerKey, widgetFeeDigest);
            quote.widgetFeeSignature = abi.encodePacked(r, s, v);

            return quote;
        }
    }

    function _executeBuyerTokenUnwrapToETHTest(uint256 usdcAmount) internal {
        // Calculate expected amounts
        uint256 expectedWethAmount = 1 ether; // 1 WETH for 3000 USDC (price: 3000 USDC/ETH)
        uint256 widgetFeeRate = 50; // 0.5%

        // Widget fee is charged on USDC (seller token), not WETH (buyer token)
        uint256 expectedUsdcWidgetFee = usdcAmount * widgetFeeRate / 10_000;
        uint256 effectiveUsdcAmount = usdcAmount - expectedUsdcWidgetFee;

        // WETH amount is proportionally reduced based on effective USDC
        uint256 effectiveWethAmount = (effectiveUsdcAmount * expectedWethAmount) / usdcAmount;

        // Store initial balances
        uint256 aliceInitialUsdc = USDC.balanceOf(alice);
        uint256 aliceInitialEth = alice.balance;
        uint256 deployerInitialUsdc = USDC.balanceOf(deployer); // Widget fee recipient for USDC

        // Create quote for USDC → WETH trade
        IQuote.RFQTQuote memory quote = _createUSDCToWETHQuote(usdcAmount, expectedWethAmount, widgetFeeRate);

        // Prepare multicall data
        bytes[] memory multicallData = new bytes[](2);

        // First call: Trade USDC for WETH (WETH goes to router)
        multicallData[0] = abi.encodeCall(router.tradeRFQT, (quote, 0, 0));

        // Second call: Unwrap WETH to ETH (ETH goes to alice)
        multicallData[1] = abi.encodeCall(router.unwrapWETH9, (alice));

        // Execute both operations atomically
        vm.startPrank(alice);
        USDC.approve(address(router), usdcAmount);
        router.multicall(multicallData);
        vm.stopPrank();

        // Verify results
        assertEq(USDC.balanceOf(alice), aliceInitialUsdc - usdcAmount, "Alice USDC balance incorrect");
        assertEq(alice.balance, aliceInitialEth + effectiveWethAmount, "Alice ETH balance incorrect");
        assertEq(
            USDC.balanceOf(deployer),
            deployerInitialUsdc + expectedUsdcWidgetFee,
            "Widget fee recipient USDC balance incorrect"
        );
        assertEq(weth.balanceOf(address(router)), 0, "No WETH left in router");
        assertEq(address(router).balance, 0, "No ETH left in router");
    }

    function _createUSDCToWETHQuote(
        uint256 usdcAmount,
        uint256 wethAmount,
        uint256 widgetFeeRate
    ) internal view returns (IQuote.RFQTQuote memory) {
        // Calculate effective amount after widget fee
        uint256 effectiveWethAmount = wethAmount - (wethAmount * widgetFeeRate / 10_000);

        IQuote.RFQTQuote memory quote = IQuote.RFQTQuote({
            pool: address(haloRFQPool),
            signer: halo,
            recipient: address(router), // WETH goes to router for unwrapping
            sellerToken: address(USDC),
            buyerToken: address(weth),
            sellerTokenAmount: usdcAmount,
            buyerTokenAmount: wethAmount,
            deadlineTimestamp: block.timestamp + 1 hours,
            nonce: 0,
            confidenceExtractedValueT: 0,
            confidenceExtractedValueN: block.timestamp + 1 hours,
            confidenceExtractedValueE: 0,
            confidenceExtractedValueM: 0,
            quoteId: bytes16(uint128(1)),
            multiHop: false,
            signature: bytes(""),
            widgetFee: IQuote.WidgetFee({feeRecipient: deployer, feeRate: widgetFeeRate}),
            widgetFeeSignature: bytes(""),
            amountOutMinimum: effectiveWethAmount
        });

        // Generate quote signature
        bytes32 quoteDigest = SignatureUtils.generateQuoteSignature(quote);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(haloKey, quoteDigest);
        quote.signature = abi.encodePacked(r, s, v);

        // Generate widget fee signature
        bytes32 widgetFeeDigest = SignatureUtils.generateWidgetFeeSignature(quote, address(router));
        (v, r, s) = vm.sign(deployerKey, widgetFeeDigest);
        quote.widgetFeeSignature = abi.encodePacked(r, s, v);

        return quote;
    }

    function _verifyTradeResults(
        uint256 sellAmount,
        uint256 expectedUsdcAmount,
        uint256 aliceInitialEth,
        uint256 aliceInitialUsdc,
        uint256 vaultInitialEth,
        uint256 vaultInitialUsdc,
        int256 haloInitialEthPosition,
        int256 haloInitialUsdcPosition
    ) internal view {
        assertEq(weth.balanceOf(alice), aliceInitialEth - sellAmount, "Alice ETH balance incorrect");
        assertEq(USDC.balanceOf(alice), aliceInitialUsdc + expectedUsdcAmount, "Alice USDC balance incorrect");
        assertEq(
            creditVault.positions(halo, address(weth)) - haloInitialEthPosition,
            int256(sellAmount),
            "Halo ETH position incorrect"
        );
        assertEq(
            creditVault.positions(halo, address(USDC)) - haloInitialUsdcPosition,
            -int256(expectedUsdcAmount),
            "Halo USDC position incorrect"
        );
        assertEq(
            weth.balanceOf(address(creditVault)), vaultInitialEth + sellAmount, "CreditVault ETH balance incorrect"
        );
        assertEq(
            USDC.balanceOf(address(creditVault)),
            vaultInitialUsdc - expectedUsdcAmount,
            "CreditVault USDC balance incorrect"
        );
    }
}
