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
        router.tradeRFQT(quote);
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
        router.tradeRFQT(quote);
        vm.stopPrank();

        // Verify PMM trade results
        assertEq(weth.balanceOf(alice), aliceInitialEth - sellAmount, "Alice ETH balance incorrect");
        assertEq(USDC.balanceOf(alice), aliceInitialUsdc + expectedUsdcAmount, "Alice USDC balance incorrect");
        assertEq(USDC.balanceOf(halo), haloInitialUsdc - expectedUsdcAmount, "Halo USDC balance incorrect");
    }

    function test_tradeAutoSign() public {
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

        // Create and execute the trade
        IQuote.AutoSignQuote memory quote =
            _createAutoSignQuote(haloKey, deployerKey, address(rfqPool), sellAmount, expectedUsdcAmount);

        vm.startPrank(alice);
        weth.approve(address(router), sellAmount);
        router.tradeAutoSign(quote);
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

    function test_tradeAutoSign_revertScenarios() public {
        // initialize bobKey
        uint256 bobKey = 0xB0B;
        vm.label(vm.addr(bobKey), "bob");

        setupPMM();
        deal(address(weth), alice, 10 ether);

        // Calculate amounts
        uint256 ethPriceInUsdc = 3000 * 10 ** 6;
        uint256 sellAmount = _calculateSellAmount();
        uint256 expectedUsdcAmount = sellAmount * ethPriceInUsdc / 1 ether;

        // Create base quote
        IQuote.AutoSignQuote memory quote =
            _createAutoSignQuote(haloKey, bobKey, address(rfqPool), sellAmount, expectedUsdcAmount);

        vm.startPrank(alice);
        weth.approve(address(router), sellAmount);

        // Test 1: Invalid deployer signature
        vm.expectRevert(ErrorsLib.InvalidSigner.selector);
        router.tradeAutoSign(quote);

        // Test 2: Invalid market maker signature
        {
            bytes32 orderBookDigest = keccak256("helloworld");
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobKey, orderBookDigest);
            bytes memory orderBookSig = abi.encodePacked(r, s, v);

            quote.orderBookSig = orderBookSig;
            quote.orderBookDigest = orderBookDigest;
        }

        vm.expectRevert(ErrorsLib.InvalidSigner.selector);
        router.tradeAutoSign(quote);

        // Test 3: Expired deadline
        vm.warp(block.timestamp + 2 hours);

        vm.expectRevert(ErrorsLib.RFQQuoteExpired.selector);
        router.tradeAutoSign(quote);

        vm.stopPrank();
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
            effectiveSellerTokenAmount: sellAmount,
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

    function _createAutoSignQuote(
        uint256 marketMakerKey,
        uint256 deployerKey,
        address poolAddress,
        uint256 sellAmount,
        uint256 expectedUsdcAmount
    ) internal view returns (IQuote.AutoSignQuote memory) {
        // Create orderbook digest and signature using market maker private key
        bytes32 orderBookDigest = keccak256("helloworld");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(marketMakerKey, orderBookDigest);
        bytes memory orderBookSig = abi.encodePacked(r, s, v);

        IQuote.AutoSignQuote memory quote = IQuote.AutoSignQuote({
            nonce: 0,
            pool: poolAddress,
            signer: halo,
            recipient: alice,
            buyerToken: address(USDC),
            sellerToken: address(weth),
            buyerTokenAmount: expectedUsdcAmount,
            sellerTokenAmount: sellAmount,
            effectiveSellerTokenAmount: sellAmount,
            deadline: block.timestamp + 1 hours,
            signature: bytes(""),
            multiHop: false,
            widgetFee: IQuote.WidgetFee({feeRecipient: deployer, feeRate: 0}),
            orderBookSig: orderBookSig,
            orderBookDigest: orderBookDigest
        });

        // keccak256("AUTOSIGN(uint256 nonce,address recipient,address sellerToken,address buyerToken,address sellerTokenAmount,address buyerTokenAmount,uint256 deadline)")
        bytes32 AUTO_SIGN_SIGNATURE_HASH = 0x413b57dcf6b1f3987cb232981f0871744ebe2dd46e25a0d16f50c4fd66f1f144;

        // Generate auto-sign signature using deployer's key
        bytes32 autoSignDigest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    AUTO_SIGN_SIGNATURE_HASH,
                    quote.nonce,
                    quote.recipient,
                    quote.sellerToken,
                    quote.buyerToken,
                    quote.sellerTokenAmount,
                    quote.buyerTokenAmount,
                    quote.deadline
                )
            ),
            address(router),
            "Native Router",
            "1"
        );

        (v, r, s) = vm.sign(deployerKey, autoSignDigest);
        quote.signature = abi.encodePacked(r, s, v);

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
