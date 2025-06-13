// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {BaseTest} from "../BaseTest.t.sol";
import {NativeRouter} from "../../src/NativeRouter.sol";
import {NativeRFQPool} from "../../src/NativeRFQPool.sol";
import {IQuote} from "../../src/interfaces/IQuote.sol";
import {SignatureUtils} from "../helpers/SignatureUtils.sol";
import {ICreditVault} from "../../src/interfaces/ICreditVault.sol";

import {console2} from "forge-std/console2.sol";

contract NativeRFQPoolTest is BaseTest {
    NativeRouter public router2;
    NativeRFQPool public rfqPool2;

    // State variables to store initial balances and positions
    mapping(address => mapping(address => uint256)) private initialBalances;
    mapping(address => mapping(address => int256)) private initialPositions;

    // Struct to reduce stack depth in _createQuote function
    struct QuoteParams {
        address poolAddress;
        uint256 sellAmount;
        uint256 expectedAmount;
        address recipient;
        address sellerToken;
        address buyerToken;
    }

    // Struct to hold signature data
    struct SignatureData {
        bytes32 quoteDigest;
        bytes32 widgetFeeDigest;
        address routerAddress;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    function setUp() public override {
        super.setUp();

        // Block 1: Create router2 and rfqPool2
        {
            vm.startPrank(deployer);

            router2 = new NativeRouter(address(creditVault), address(weth), deployer);

            rfqPool2 = new NativeRFQPool(true, address(weth), address(router2), address(creditVault), "RFQPool2");

            rfqPool2.setSigner(deployer, true);

            router2.setNativePool(address(rfqPool2), true);

            creditVault.setCreditPool(address(rfqPool2), true);

            // Ensure CreditVault has enough WETH
            deal(address(weth), address(creditVault), 100 ether);
            vm.stopPrank();
        }

        // Block 2: Set up CreditVault allowances
        {
            vm.startPrank(deployer);
            ICreditVault.TokenAmountUint[] memory tokens = new ICreditVault.TokenAmountUint[](2);
            tokens[0] = ICreditVault.TokenAmountUint({token: address(USDC), amount: type(uint256).max});
            tokens[1] = ICreditVault.TokenAmountUint({token: address(weth), amount: type(uint256).max});
            creditVault.setAllowance(tokens, address(rfqPool2));
            vm.stopPrank();
        }

        // Block 3: Set up Bob's balances and approvals
        {
            deal(address(weth), bob, 100 ether);
            vm.startPrank(bob);
            weth.approve(address(router2), type(uint256).max);
            vm.stopPrank();
        }

        // Block 4: Set up Alice's balances and approvals
        {
            deal(address(USDC), alice, 13_000 * 10 ** 6); // Give Alice 13,000 USDC (10,000 for LP + 3,000 for trading)
            vm.startPrank(alice);
            USDC.approve(address(lpUSDC), type(uint256).max);
            lpUSDC.deposit(10_000 * 10 ** 6); // Alice deposits 10,000 USDC
            USDC.approve(address(router2), type(uint256).max);
            vm.stopPrank();
        }
    }

    function test_multipleRoutersAndPools() public {
        _setupInitialState();
        (uint256 bobWETHSellAmount, uint256 bobExpectedUSDCAmount) = _executeBobTrade();
        (uint256 aliceUSDCSellAmount, uint256 aliceExpectedWETHAmount) = _executeAliceTrade();
        _verifyAllTradeResults(bobWETHSellAmount, bobExpectedUSDCAmount, aliceUSDCSellAmount, aliceExpectedWETHAmount);
    }

    function _setupInitialState() internal {
        setupPMM(); // Initialize halo address

        // Re-set halo as signer for both pools
        vm.startPrank(deployer);
        rfqPool.setSigner(halo, true);
        rfqPool2.setSigner(halo, true);
        vm.stopPrank();

        // Charlie deposits ETH into lpWETH
        deal(address(weth), charlie, 100 ether);
        vm.startPrank(charlie);
        weth.approve(address(lpWETH), type(uint256).max);
        lpWETH.deposit(100 ether);
        vm.stopPrank();

        // Record initial balances for both tokens
        initialBalances[bob][address(weth)] = weth.balanceOf(bob);
        initialBalances[bob][address(USDC)] = USDC.balanceOf(bob);
        initialBalances[alice][address(weth)] = weth.balanceOf(alice);
        initialBalances[alice][address(USDC)] = USDC.balanceOf(alice);
        initialBalances[address(creditVault)][address(weth)] = weth.balanceOf(address(creditVault));

        initialPositions[halo][address(weth)] = creditVault.positions(halo, address(weth));
        initialPositions[halo][address(USDC)] = creditVault.positions(halo, address(USDC));
    }

    function _executeBobTrade() internal returns (uint256 wethSellAmount, uint256 expectedUSDCAmount) {
        wethSellAmount = 1 ether;
        expectedUSDCAmount = 3000 * 10 ** 6;

        IQuote.RFQTQuote memory quote =
            _createQuote(address(rfqPool), wethSellAmount, expectedUSDCAmount, bob, address(weth), address(USDC));

        vm.startPrank(bob);
        weth.approve(address(router), wethSellAmount);
        router.tradeRFQT(quote, 0, 0);
        vm.stopPrank();

        return (wethSellAmount, expectedUSDCAmount);
    }

    function _executeAliceTrade() internal returns (uint256 usdcSellAmount, uint256 expectedWETHAmount) {
        usdcSellAmount = 3000 * 10 ** 6;
        expectedWETHAmount = 1 ether;

        IQuote.RFQTQuote memory quote =
            _createQuote(address(rfqPool2), usdcSellAmount, expectedWETHAmount, alice, address(USDC), address(weth));

        vm.startPrank(alice);
        USDC.approve(address(router2), usdcSellAmount);
        router2.tradeRFQT(quote, 0, 0);
        vm.stopPrank();

        return (usdcSellAmount, expectedWETHAmount);
    }

    function _verifyAllTradeResults(
        uint256 bobWETHSellAmount,
        uint256 bobExpectedUSDCAmount,
        uint256 aliceUSDCSellAmount,
        uint256 aliceExpectedWETHAmount
    ) internal view {
        assertEq(
            weth.balanceOf(bob), initialBalances[bob][address(weth)] - bobWETHSellAmount, "Bob WETH balance incorrect"
        );
        assertEq(
            USDC.balanceOf(bob),
            initialBalances[bob][address(USDC)] + bobExpectedUSDCAmount,
            "Bob USDC balance incorrect"
        );

        assertEq(
            weth.balanceOf(alice),
            initialBalances[alice][address(weth)] + aliceExpectedWETHAmount,
            "Alice WETH balance incorrect"
        );
        assertEq(
            USDC.balanceOf(alice),
            initialBalances[alice][address(USDC)] - aliceUSDCSellAmount,
            "Alice USDC balance incorrect"
        );

        _verifyCreditVaultResults(
            bobWETHSellAmount, bobExpectedUSDCAmount, aliceUSDCSellAmount, aliceExpectedWETHAmount
        );
    }

    function _verifyCreditVaultResults(
        uint256 bobWETHSellAmount,
        uint256 bobExpectedUSDCAmount,
        uint256 aliceUSDCSellAmount,
        uint256 aliceExpectedWETHAmount
    ) internal view {
        assertEq(
            creditVault.positions(halo, address(weth)),
            initialPositions[halo][address(weth)] + int256(bobWETHSellAmount) - int256(aliceExpectedWETHAmount),
            "Halo WETH position incorrect"
        );
        assertEq(
            creditVault.positions(halo, address(USDC)),
            initialPositions[halo][address(USDC)] - int256(bobExpectedUSDCAmount) + int256(aliceUSDCSellAmount),
            "Halo USDC position incorrect"
        );
    }

    function _createQuote(
        address poolAddress,
        uint256 sellAmount,
        uint256 expectedUsdcAmount,
        address recipient,
        address sellerToken,
        address buyerToken
    ) internal view returns (IQuote.RFQTQuote memory) {
        QuoteParams memory params = QuoteParams({
            poolAddress: poolAddress,
            sellAmount: sellAmount,
            expectedAmount: expectedUsdcAmount,
            recipient: recipient,
            sellerToken: sellerToken,
            buyerToken: buyerToken
        });

        return _buildQuoteWithParams(params);
    }

    function _buildQuoteWithParams(QuoteParams memory params) internal view returns (IQuote.RFQTQuote memory) {
        IQuote.RFQTQuote memory quote;

        // Block 1: Create quote structure
        {
            quote = IQuote.RFQTQuote({
                pool: params.poolAddress,
                signer: halo,
                recipient: params.recipient,
                sellerToken: params.sellerToken,
                buyerToken: params.buyerToken,
                sellerTokenAmount: params.sellAmount,
                buyerTokenAmount: params.expectedAmount,
                amountOutMinimum: params.expectedAmount,
                deadlineTimestamp: block.timestamp + 1 hours,
                // decay mechanism
                decayStartTime: block.timestamp,
                decayExponent: 0,
                maxSlippageBps: 0,
                // end decay mechanism
                nonce: 0,
                multiHop: false,
                signature: bytes(""),
                externalSwapCalldata: bytes(""),
                quoteId: bytes16(0),
                widgetFee: IQuote.WidgetFee({feeRecipient: deployer, feeRate: 0}),
                widgetFeeSignature: bytes("")
            });
        }

        return _signQuote(quote, params);
    }

    function _signQuote(
        IQuote.RFQTQuote memory quote,
        QuoteParams memory params
    ) internal view returns (IQuote.RFQTQuote memory) {
        SignatureData memory sigData;

        // Block 1: Generate quote signature
        {
            sigData.quoteDigest = SignatureUtils.generateQuoteSignature(quote);
            (sigData.v, sigData.r, sigData.s) = vm.sign(haloKey, sigData.quoteDigest);
            quote.signature = abi.encodePacked(sigData.r, sigData.s, sigData.v);
        }

        // Block 2: Generate widget fee signature
        {
            sigData.routerAddress = params.poolAddress == address(rfqPool) ? address(router) : address(router2);
            sigData.widgetFeeDigest = SignatureUtils.generateWidgetFeeSignature(quote, sigData.routerAddress);
            (sigData.v, sigData.r, sigData.s) = vm.sign(deployerKey, sigData.widgetFeeDigest);
            quote.widgetFeeSignature = abi.encodePacked(sigData.r, sigData.s, sigData.v);
        }

        return quote;
    }
}
