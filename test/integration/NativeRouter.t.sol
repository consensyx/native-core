// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {BaseTest} from "../BaseTest.t.sol";
import {NativeRFQPool} from "../../src/NativeRFQPool.sol";
import {IQuote} from "../../src/interfaces/IQuote.sol";
import {SignatureUtils} from "../helpers/SignatureUtils.sol";
import {ErrorsLib} from "../../src/libraries/ErrorsLib.sol";

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
        uint256 vaultInitialUsdc = USDC.balanceOf(address(creditVault));
        int256 haloInitialEthPosition = creditVault.positions(halo, address(weth));
        int256 haloInitialUsdcPosition = creditVault.positions(halo, address(USDC));

        // Calculate amounts
        uint256 ethPriceInUsdc = 3000 * 10 ** 6;
        uint256 sellAmount = _calculateSellAmount();
        uint256 expectedUsdcAmount = sellAmount * ethPriceInUsdc / 1 ether;

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

        // 1 WETH = 3000 USDC
        uint256 sellAmount = 1 ether;
        uint256 expectedUsdcAmount = 3000 * 10 ** 6;
        uint256 widgetFeeRate = 100; // 1%
        uint256 expectedWidgetFee = sellAmount * widgetFeeRate / 10_000;
        uint256 effectiveSellAmount = sellAmount - expectedWidgetFee;
        uint256 effectiveUsdcAmount = (effectiveSellAmount * expectedUsdcAmount) / sellAmount;

        IQuote.RFQTQuote memory quote = IQuote.RFQTQuote({
            pool: address(haloRFQPool),
            signer: halo,
            recipient: alice,
            sellerToken: address(weth),
            buyerToken: address(USDC),
            sellerTokenAmount: sellAmount,
            buyerTokenAmount: expectedUsdcAmount,
            amountOutMinimum: effectiveUsdcAmount,
            deadlineTimestamp: block.timestamp + 1 hours,
            nonce: 0,
            multiHop: false,
            signature: bytes(""),
            externalSwapCalldata: bytes(""),
            quoteId: bytes16(uint128(1)),
            widgetFee: IQuote.WidgetFee({feeRecipient: deployer, feeRate: widgetFeeRate}),
            widgetFeeSignature: bytes("")
        });

        bytes32 quoteDigest = SignatureUtils.generateQuoteSignature(quote);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(haloKey, quoteDigest);
        quote.signature = abi.encodePacked(r, s, v);
        bytes32 widgetFeeDigest = SignatureUtils.generateWidgetFeeSignature(quote, alice, address(router));
        (v, r, s) = vm.sign(deployerKey, widgetFeeDigest);
        quote.widgetFeeSignature = abi.encodePacked(r, s, v);

        vm.startPrank(alice);
        weth.approve(address(router), sellAmount);
        router.tradeRFQT(quote, 0, 0);
        vm.stopPrank();

        // verify balances
        assertEq(weth.balanceOf(alice), initialBalances[0] - sellAmount, "Alice WETH balance incorrect");
        assertEq(USDC.balanceOf(alice), initialBalances[1] + effectiveUsdcAmount, "Alice USDC balance incorrect");
        assertEq(weth.balanceOf(halo), initialBalances[2] + effectiveSellAmount, "Halo WETH balance incorrect");
        assertEq(USDC.balanceOf(halo), initialBalances[3] - effectiveUsdcAmount, "Halo USDC balance incorrect");
        assertEq(weth.balanceOf(deployer), initialBalances[4] + expectedWidgetFee, "Deployer should receive widget fee");
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

    function test_tradeRFQMultiHopWithWidgetFeeOnlyFirstHop() public {
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

        // Store initial balances and setup amounts
        _executeMultiHopTest();
    }

    function _executeMultiHopTest() internal {
        uint256 wethAmount = 1 ether;
        uint256 widgetFeeRate = 100; // 1%
        uint256 expectedWidgetFee = wethAmount * widgetFeeRate / 10_000;
        uint256 effectiveWethAmount = wethAmount - expectedWidgetFee;

        // Calculate swap amounts: 1 WETH = 3000 USDC, 1 WBTC = 90000 USDC
        uint256 usdcFromWeth = 3000 * 10 ** 6; // 3000 USDC
        uint256 effectiveUsdcAmount = (effectiveWethAmount * usdcFromWeth) / wethAmount;
        uint256 wbtcFromUsdc = effectiveUsdcAmount * 10 ** 8 / (90_000 * 10 ** 6);

        // Store balances
        uint256 aliceInitialWeth = weth.balanceOf(alice);
        uint256 aliceInitialWbtc = wbtc.balanceOf(alice);
        uint256 deployerInitialWeth = weth.balanceOf(deployer);

        // Create and execute first hop
        IQuote.RFQTQuote memory firstHop = _createFirstHopQuote(wethAmount, usdcFromWeth, widgetFeeRate);

        // Create and execute second hop
        IQuote.RFQTQuote memory secondHop = _createSecondHopQuote(effectiveUsdcAmount, wbtcFromUsdc);

        vm.startPrank(alice);
        weth.approve(address(router), wethAmount);
        router.tradeRFQT(firstHop, 0, 0);
        router.tradeRFQT(secondHop, 0, 0);
        vm.stopPrank();

        // Verify results
        assertEq(weth.balanceOf(alice), aliceInitialWeth - wethAmount, "Alice WETH balance incorrect");
        assertEq(wbtc.balanceOf(alice), aliceInitialWbtc + wbtcFromUsdc, "Alice WBTC balance incorrect");
        assertEq(
            weth.balanceOf(deployer), deployerInitialWeth + expectedWidgetFee, "Widget fee only charged on first hop"
        );
        assertEq(USDC.balanceOf(address(router)), 0, "No USDC left in router");
    }

    function _createFirstHopQuote(
        uint256 wethAmount,
        uint256 usdcAmount,
        uint256 widgetFeeRate
    ) internal view returns (IQuote.RFQTQuote memory) {
        uint256 effectiveUsdcAmount = (wethAmount - wethAmount * widgetFeeRate / 10_000) * usdcAmount / wethAmount;

        IQuote.RFQTQuote memory quote = IQuote.RFQTQuote({
            pool: address(haloRFQPool),
            signer: halo,
            recipient: address(router),
            sellerToken: address(weth),
            buyerToken: address(USDC),
            sellerTokenAmount: wethAmount,
            buyerTokenAmount: usdcAmount,
            amountOutMinimum: effectiveUsdcAmount,
            deadlineTimestamp: block.timestamp + 1 hours,
            nonce: 0,
            multiHop: false,
            signature: bytes(""),
            externalSwapCalldata: bytes(""),
            quoteId: bytes16(uint128(1)),
            widgetFee: IQuote.WidgetFee({feeRecipient: deployer, feeRate: widgetFeeRate}),
            widgetFeeSignature: bytes("")
        });

        // Generate signatures
        bytes32 quoteDigest = SignatureUtils.generateQuoteSignature(quote);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(haloKey, quoteDigest);
        quote.signature = abi.encodePacked(r, s, v);

        bytes32 widgetFeeDigest = SignatureUtils.generateWidgetFeeSignature(quote, alice, address(router));
        (v, r, s) = vm.sign(deployerKey, widgetFeeDigest);
        quote.widgetFeeSignature = abi.encodePacked(r, s, v);

        return quote;
    }

    function _createSecondHopQuote(
        uint256 usdcAmount,
        uint256 wbtcAmount
    ) internal view returns (IQuote.RFQTQuote memory) {
        IQuote.RFQTQuote memory quote = IQuote.RFQTQuote({
            pool: address(haloRFQPool),
            signer: halo,
            recipient: alice,
            sellerToken: address(USDC),
            buyerToken: address(wbtc),
            sellerTokenAmount: usdcAmount,
            buyerTokenAmount: wbtcAmount,
            amountOutMinimum: wbtcAmount,
            deadlineTimestamp: block.timestamp + 1 hours,
            nonce: 1,
            multiHop: true,
            signature: bytes(""),
            externalSwapCalldata: bytes(""),
            quoteId: bytes16(uint128(2)),
            widgetFee: IQuote.WidgetFee({feeRecipient: deployer, feeRate: 0}),
            widgetFeeSignature: bytes("")
        });

        // Generate signatures
        bytes32 quoteDigest = SignatureUtils.generateQuoteSignature(quote);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(haloKey, quoteDigest);
        quote.signature = abi.encodePacked(r, s, v);

        bytes32 widgetFeeDigest = SignatureUtils.generateWidgetFeeSignature(quote, alice, address(router));
        (v, r, s) = vm.sign(deployerKey, widgetFeeDigest);
        quote.widgetFeeSignature = abi.encodePacked(r, s, v);

        return quote;
    }

    /// @notice Calculates a random sell amount for testing trades
    /// @dev The amount is capped at 50% of vault balance to avoid liquidity issues
    /// @return sellAmount The calculated sell amount
    function _calculateSellAmount() internal view returns (uint256) {
        // Get Alice's WETH balance
        uint256 aliceEthBalance = weth.balanceOf(alice);

        // Calculate random amount between 10-100% of Alice's balance
        uint256 sellAmount = _randomAmount(aliceEthBalance, 10, lpWETH);

        // Cap sell amount at 50% of vault balance for safety
        uint256 vaultBalance = weth.balanceOf(address(creditVault));
        if (sellAmount > vaultBalance / 2) {
            sellAmount = vaultBalance / 2;
        }

        return sellAmount;
    }

    function _createQuote(
        address poolAddress,
        uint256 sellAmount,
        uint256 expectedUsdcAmount
    ) internal view returns (IQuote.RFQTQuote memory) {
        IQuote.RFQTQuote memory quote = IQuote.RFQTQuote({
            pool: poolAddress,
            signer: halo,
            recipient: alice,
            sellerToken: address(weth),
            buyerToken: address(USDC),
            sellerTokenAmount: sellAmount,
            buyerTokenAmount: expectedUsdcAmount,
            amountOutMinimum: expectedUsdcAmount,
            deadlineTimestamp: block.timestamp + 1 hours,
            nonce: 0,
            multiHop: false,
            signature: bytes(""),
            externalSwapCalldata: bytes(""),
            quoteId: bytes16(0),
            widgetFee: IQuote.WidgetFee({feeRecipient: deployer, feeRate: 0}),
            widgetFeeSignature: bytes("")
        });

        // Generate quote signature
        bytes32 quoteDigest = SignatureUtils.generateQuoteSignature(quote);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(haloKey, quoteDigest);
        quote.signature = abi.encodePacked(r, s, v);

        // Generate widget fee signature
        bytes32 widgetFeeDigest = SignatureUtils.generateWidgetFeeSignature(quote, alice, address(router));
        (v, r, s) = vm.sign(deployerKey, widgetFeeDigest);
        quote.widgetFeeSignature = abi.encodePacked(r, s, v);

        return quote;
    }

    function _createQuoteWithWidgetFee(
        address poolAddress,
        uint256 sellAmount,
        uint256 expectedUsdcAmount,
        uint256 widgetFeeRate
    ) internal view returns (IQuote.RFQTQuote memory) {
        // For quote signature, we need to use WETH address since NativeRFQPool converts address(0) to WETH for signature verification
        IQuote.RFQTQuote memory quoteForSig = IQuote.RFQTQuote({
            pool: poolAddress,
            signer: halo,
            recipient: alice,
            sellerToken: address(weth), // Use WETH for signature
            buyerToken: address(USDC),
            sellerTokenAmount: sellAmount,
            buyerTokenAmount: expectedUsdcAmount,
            amountOutMinimum: expectedUsdcAmount,
            deadlineTimestamp: block.timestamp + 1 hours,
            nonce: 0,
            multiHop: false,
            signature: bytes(""),
            externalSwapCalldata: bytes(""),
            quoteId: bytes16(0),
            widgetFee: IQuote.WidgetFee({feeRecipient: deployer, feeRate: widgetFeeRate}),
            widgetFeeSignature: bytes("")
        });

        // Generate quote signature using WETH address
        bytes32 quoteDigest = SignatureUtils.generateQuoteSignature(quoteForSig);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(haloKey, quoteDigest);

        // Now create the actual quote with address(0) for native ETH
        IQuote.RFQTQuote memory quote = IQuote.RFQTQuote({
            pool: poolAddress,
            signer: halo,
            recipient: alice,
            sellerToken: address(0), // Native ETH for router
            buyerToken: address(USDC),
            sellerTokenAmount: sellAmount,
            buyerTokenAmount: expectedUsdcAmount,
            amountOutMinimum: expectedUsdcAmount,
            deadlineTimestamp: block.timestamp + 1 hours,
            nonce: 0,
            multiHop: false,
            signature: abi.encodePacked(r, s, v), // Use signature generated with WETH
            externalSwapCalldata: bytes(""),
            quoteId: bytes16(0),
            widgetFee: IQuote.WidgetFee({feeRecipient: deployer, feeRate: widgetFeeRate}),
            widgetFeeSignature: bytes("")
        });

        // Generate widget fee signature
        bytes32 widgetFeeDigest = SignatureUtils.generateWidgetFeeSignature(quote, alice, address(router));
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
