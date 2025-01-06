// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {WETH9} from "../src/test/WETH9.sol";
import {MockERC20} from "../src/test/MockERC20.sol";
import {CreditVault} from "../src/CreditVault.sol";
import {NativeRouter} from "../src/NativeRouter.sol";
import {NativeLPToken} from "../src/NativeLPToken.sol";
import {NativeRFQPool} from "../src/NativeRFQPool.sol";
import {ICreditVault} from "../src/interfaces/ICreditVault.sol";

contract BaseTest is Test {
    // Constants
    address public deployer;
    address public alice;
    address public bob;
    address public charlie;
    address public dave;

    // Core contracts
    NativeRouter public router;
    NativeRFQPool public rfqPool;
    CreditVault public creditVault;

    // Token contracts
    WETH9 public weth;
    MockERC20 public USDC;
    MockERC20 public wbtc;
    MockERC20 public stone;

    // LP Tokens
    NativeLPToken public lpUSDC;
    NativeLPToken public lpWETH;
    NativeLPToken public lpWBTC;
    NativeLPToken public lpSTONE;

    // Add array to store integration test users
    address[] private testUsers;
    uint256 constant NUM_TEST_USERS = 50;

    // PMM EOA addresses
    address public halo;
    address public tokka;
    address public quadratic;
    address public timeResearch;
    address public gsr;

    // PMM RFQ Pools
    NativeRFQPool public haloRFQPool;
    NativeRFQPool public tokkaRFQPool;
    NativeRFQPool public quadraticRFQPool;
    NativeRFQPool public timeResearchRFQPool;
    NativeRFQPool public gsrRFQPool;

    // Add private keys for all PMMs
    uint256 internal haloKey;
    uint256 internal tokkaKey;
    uint256 internal quadraticKey;
    uint256 internal timeResearchKey;
    uint256 internal gsrKey;

    // Add deployer private key
    uint256 internal deployerKey;

    // Test user private keys
    uint256 internal aliceKey = 0x1111;
    uint256 internal bobKey = 0x2222;
    uint256 internal charlieKey = 0x3333;
    uint256 internal daveKey = 0x4444;

    function setUp() public virtual {
        // Generate deployer key and address
        deployerKey = 0xF66CE;
        deployer = vm.addr(deployerKey);

        alice = vm.addr(aliceKey);
        bob = vm.addr(bobKey);
        charlie = vm.addr(charlieKey);
        dave = vm.addr(daveKey);

        // Switch to deployer account and ensure it remains active until all deployments and setups are complete
        vm.startPrank(deployer);

        // Deploy tokens
        weth = new WETH9();
        USDC = new MockERC20("USD Coin", "USDC", 6);
        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        stone = new MockERC20("StakeStone Ether", "STONE", 18);

        // Deploy CreditVault
        creditVault = new CreditVault();

        // Deploy LP Tokens
        lpUSDC = new NativeLPToken("Native LP: USD Coin", "NT LP USDC", address(USDC), address(creditVault));
        lpWETH = new NativeLPToken("Native LP: Wrapped Ether", "NT LP WETH", address(weth), address(creditVault));
        lpWBTC = new NativeLPToken("Native LP: Wrapped BTC", "NT LP WBTC", address(wbtc), address(creditVault));
        lpSTONE = new NativeLPToken("Native LP: StakeStone Ether", "NT LP STONE", address(stone), address(creditVault));

        // Set minimum deposit amounts based on decimals
        lpUSDC.setMinDeposit(10 ** (6 - 2)); // USDC has 6 decimals -> 10^4
        lpWETH.setMinDeposit(10 ** (18 - 4)); // WETH has 18 decimals -> 10^14
        lpWBTC.setMinDeposit(10 ** (8 - 2)); // WBTC has 8 decimals -> 10^6
        lpSTONE.setMinDeposit(10 ** (18 - 4)); // STONE has 18 decimals -> 10^14

        // Support markets in CreditVault
        creditVault.supportMarket(lpUSDC);
        creditVault.supportMarket(lpWETH);
        creditVault.supportMarket(lpWBTC);
        creditVault.supportMarket(lpSTONE);

        // Deploy router
        router = new NativeRouter(address(creditVault), address(weth), deployer);

        // Deploy RFQ pool
        rfqPool = new NativeRFQPool(true, address(weth), address(router), address(creditVault), "Native RFQ Pool");

        rfqPool.setSigner(deployer, true);

        // Router set native pool
        router.setNativePool(address(rfqPool), true);

        // Setup CreditVault permissions and configurations
        creditVault.setCreditPool(address(rfqPool), true);
        creditVault.setSigner(deployer);
        creditVault.setLiquidator(deployer, makeAddr("liquidatorRecipient"), true);

        creditVault.setEpochUpdater(deployer);
        creditVault.setFeeWithdrawer(payable(deployer));

        // TODO: creditVault.setOracle();

        // Add authorization for RFQ pool to access all underlying tokens
        ICreditVault.TokenAmountUint[] memory allowances = new ICreditVault.TokenAmountUint[](4);
        allowances[0] = ICreditVault.TokenAmountUint({token: address(USDC), amount: type(uint256).max});
        allowances[1] = ICreditVault.TokenAmountUint({token: address(weth), amount: type(uint256).max});
        allowances[2] = ICreditVault.TokenAmountUint({token: address(wbtc), amount: type(uint256).max});
        allowances[3] = ICreditVault.TokenAmountUint({token: address(stone), amount: type(uint256).max});
        creditVault.setAllowance(allowances, address(rfqPool));

        // Mint and authorize USDC for users (1 million USDC each)
        uint256 initialDeposit = 1_000_000 * 10 ** 6; // 1M USDC
        address[] memory users = new address[](4);
        users[0] = alice;
        users[1] = bob;
        users[2] = charlie;
        users[3] = dave;

        // First mint USDC as deployer
        for (uint256 i = 0; i < users.length; i++) {
            USDC.mint(users[i], initialDeposit);
        }

        // Stop deployer's prank
        vm.stopPrank();

        // Then have each user grant approvals
        for (uint256 i = 0; i < users.length; i++) {
            vm.startPrank(users[i]);
            USDC.approve(address(creditVault), type(uint256).max);
            USDC.approve(address(lpUSDC), type(uint256).max);
            vm.stopPrank();
        }
    }

    function setupIntegrationTest() internal {
        // Switch to deployer for minting tokens
        vm.startPrank(deployer);

        // 1. Create 20 random users and mint tokens
        for (uint256 i = 0; i < NUM_TEST_USERS; i++) {
            address user = address(uint160(uint256(keccak256(abi.encodePacked(block.timestamp, i)))));
            testUsers.push(user);

            // 2. Initialize tokens for each user (as deployer)
            USDC.mint(user, 1_000_000_000 * 1e6);
            wbtc.mint(user, 100 * 1e8);
            stone.mint(user, 100 * 1e18);
        }

        vm.stopPrank();

        // Handle user-specific operations
        for (uint256 i = 0; i < NUM_TEST_USERS; i++) {
            address user = testUsers[i];

            // Handle WETH separately - need to deposit ETH
            vm.deal(user, 100 * 1e18);
            vm.startPrank(user);

            weth.deposit{value: 100 * 1e18}();

            // Approve LP tokens to spend
            USDC.approve(address(lpUSDC), type(uint256).max);
            weth.approve(address(lpWETH), type(uint256).max);
            wbtc.approve(address(lpWBTC), type(uint256).max);
            stone.approve(address(lpSTONE), type(uint256).max);

            vm.stopPrank();
        }

        // 3. Random deposits for each user
        for (uint256 i = 0; i < testUsers.length; i++) {
            address user = testUsers[i];
            vm.startPrank(user);

            // Calculate random deposit amounts (50-100% of balance)
            uint256 usdcAmount = _randomAmount(USDC.balanceOf(user), 10, lpUSDC);
            uint256 wethAmount = _randomAmount(weth.balanceOf(user), 10, lpWETH);
            uint256 wbtcAmount = _randomAmount(wbtc.balanceOf(user), 10, lpWBTC);
            uint256 stoneAmount = _randomAmount(stone.balanceOf(user), 10, lpSTONE);

            // Perform deposits
            lpUSDC.deposit(usdcAmount);
            lpWETH.deposit(wethAmount);
            lpWBTC.deposit(wbtcAmount);
            lpSTONE.deposit(stoneAmount);

            vm.stopPrank();
        }

        // 4. Verify setup conditions
        _verifySetup();
    }

    function _randomAmount(
        uint256 balance,
        uint256 minPercentage,
        NativeLPToken lpToken
    ) internal view returns (uint256) {
        // If balance is 0, return 0
        if (balance == 0) return 0;

        // Calculate base percentage: generates a random value between minPercentage and 100%
        uint256 basePercentage = minPercentage
            + uint256(
                keccak256(
                    abi.encodePacked(
                        balance // Include balance to increase randomness
                    )
                )
            ) % (100 - minPercentage); // Modulo operation ensures result is between minPercentage and 100

        // Generate non-zero decimal part (1-999)
        uint256 decimalPart = 1
            + uint256(keccak256(abi.encodePacked(type(NativeLPToken).runtimeCode, type(BaseTest).runtimeCode, balance)))
                % 999;

        // Calculate final amount
        uint256 baseAmount = (balance * basePercentage) / 100;

        // Add decimal part using IERC20Metadata
        uint256 decimals = IERC20Metadata(lpToken.underlying()).decimals();
        uint256 decimalAmount = (decimalPart * (10 ** (decimals - 3))); // -3 because decimalPart is 3 digits

        return baseAmount + decimalAmount;
    }

    function _verifySetup() internal view {
        // Verify for each LP token
        _verifyLPToken(lpUSDC, IERC20(address(USDC)));
        _verifyLPToken(lpWETH, IERC20(address(weth)));
        _verifyLPToken(lpWBTC, IERC20(address(wbtc)));
        _verifyLPToken(lpSTONE, IERC20(address(stone)));
    }

    function _verifyLPToken(NativeLPToken lpToken, IERC20 underlying) internal view {
        uint256 totalShares = lpToken.totalShares();
        uint256 totalUnderlying = lpToken.totalUnderlying();
        uint256 totalSupply = lpToken.totalSupply();

        // Check vault balance matches total underlying
        require(
            underlying.balanceOf(address(creditVault)) == totalUnderlying,
            "Vault balance mismatch with total underlying"
        );

        // Verify total supply matches total underlying
        require(totalSupply == totalUnderlying, "Total supply mismatch with total underlying");

        // Verify sum of all user shares and underlying
        uint256 sumShares;
        uint256 sumUnderlying;

        for (uint256 i = 0; i < testUsers.length; i++) {
            address user = testUsers[i];
            sumShares += lpToken.shares(user);
            sumUnderlying += lpToken.balanceOf(user);
        }

        require(sumShares == totalShares, "Sum of user shares mismatch");
        require(sumUnderlying == totalUnderlying, "Sum of user underlying mismatch");
    }

    function setupPMM() internal {
        // Switch to deployer
        vm.startPrank(deployer);

        // Create PMM EOA addresses and keys using fixed private keys
        haloKey = 0xA11CE;
        tokkaKey = 0xB22CE;
        quadraticKey = 0xC33CE;
        timeResearchKey = 0xD44CE;
        gsrKey = 0xE55CE;

        // Generate addresses from private keys
        halo = vm.addr(haloKey);
        tokka = vm.addr(tokkaKey);
        quadratic = vm.addr(quadraticKey);
        timeResearch = vm.addr(timeResearchKey);
        gsr = vm.addr(gsrKey);

        // Mint 1M USDC to each PMM EOA
        uint256 mintAmount = 1_000_000 * 10 ** 6; // 1M USDC with 6 decimals
        deal(address(USDC), halo, mintAmount);
        deal(address(USDC), tokka, mintAmount);
        deal(address(USDC), quadratic, mintAmount);
        deal(address(USDC), timeResearch, mintAmount);
        deal(address(USDC), gsr, mintAmount);

        // Deploy RFQ pools for each PMM
        haloRFQPool = new NativeRFQPool(false, address(weth), address(router), halo, "Halo RFQ Pool");
        tokkaRFQPool = new NativeRFQPool(false, address(weth), address(router), tokka, "Tokka RFQ Pool");
        quadraticRFQPool = new NativeRFQPool(false, address(weth), address(router), quadratic, "Quadratic RFQ Pool");
        timeResearchRFQPool =
            new NativeRFQPool(false, address(weth), address(router), timeResearch, "TimeResearch RFQ Pool");
        gsrRFQPool = new NativeRFQPool(false, address(weth), address(router), gsr, "GSR RFQ Pool");

        // Configure each RFQ pool with their respective EOA signers
        haloRFQPool.setSigner(halo, true);
        tokkaRFQPool.setSigner(tokka, true);
        quadraticRFQPool.setSigner(quadratic, true);
        timeResearchRFQPool.setSigner(timeResearch, true);
        gsrRFQPool.setSigner(gsr, true);

        // Configure the main RFQ pool with all PMM signers
        rfqPool.setSigner(halo, true);
        rfqPool.setSigner(tokka, true);
        rfqPool.setSigner(quadratic, true);
        rfqPool.setSigner(timeResearch, true);
        rfqPool.setSigner(gsr, true);

        // Set as native pools in Native Router
        router.setNativePool(address(haloRFQPool), true);
        router.setNativePool(address(tokkaRFQPool), true);
        router.setNativePool(address(quadraticRFQPool), true);
        router.setNativePool(address(timeResearchRFQPool), true);
        router.setNativePool(address(gsrRFQPool), true);

        // Credit vault set market marker address
        creditVault.setTrader(halo, halo, makeAddr("haloRecipient"), true, true);
        creditVault.setTrader(tokka, tokka, makeAddr("tokkaRecipient"), true, false);
        creditVault.setTrader(quadratic, quadratic, makeAddr("quadraticRecipient"), true, false);
        creditVault.setTrader(timeResearch, timeResearch, makeAddr("timeResearchRecipient"), true, false);
        creditVault.setTrader(gsr, gsr, makeAddr("gsrRecipient"), true, false);

        vm.stopPrank();
    }

    function _configureRFQPool(NativeRFQPool pool, address signer) internal {
        pool.setSigner(signer, true);
    }

    /// @dev Computes the EIP712 hash of a struct using the domain separator
    ///  @param structHash The hash of the struct data
    ///  @param verifyingContract The contract address that will verify the signature
    ///  @param name The name of the contract
    ///  @param version The version of the contract
    function _hashTypedDataV4(
        bytes32 structHash,
        address verifyingContract,
        string memory name,
        string memory version
    ) internal view returns (bytes32) {
        bytes32 domainSeparator = _domainSeparatorV4(verifyingContract, name, version);
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    ///  @dev Computes the EIP712 domain separator
    ///  @param verifyingContract The contract address that will verify the signature
    ///  @param name The name of the contract
    ///  @param version The version of the contract
    function _domainSeparatorV4(
        address verifyingContract,
        string memory name,
        string memory version
    ) internal view returns (bytes32) {
        // EIP712 Domain
        bytes32 EIP712_DOMAIN_TYPEHASH =
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                block.chainid,
                verifyingContract
            )
        );
    }
}
