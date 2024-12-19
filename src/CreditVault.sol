// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712, ECDSA} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import "./libraries/ConstantsLib.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {ICreditVault} from "./interfaces/ICreditVault.sol";

import {LPToken} from "./LPToken.sol";

/// @title CreditVault - Manages trader positions and collateral
/// @notice Handles asset custody, position settlement, and LP token integration
contract CreditVault is ICreditVault, EIP712, Ownable2Step {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SafeCast for int256;

    /*//////////////////////////////////////////////////////////////////////////
                                     STATE VARIABLES
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Address that can withdraw protocol fees
    address payable public feeWithdrawer;

    /// @notice Accumulated funding rate fees charged from traders
    uint256 public fundingFees;

    /// @notice signer for permissioned functions: liquidate, settle, etc.
    address public signer;

    /// @notice epoch updater address
    address public epochUpdater;

    /// @notice A list of all markets
    LPToken[] public allLPTokens;

    /// @notice A list of all native pools
    address[] public poolArray;

    /// @notice (trader => timestamp)
    mapping(address => uint256) public lastEpochUpdateTimestamp;

    /// @notice map from underlying address to LP token
    mapping(address => LPToken) public lpTokens;

    /// @notice  trader_address => underlying token => amount (positive for long, negative for short)
    mapping(address => mapping(address => int256)) public positions;

    /// @notice traders' collateral trader_address => token => amount
    mapping(address => mapping(address => uint256)) public creditCollateral;

    /// @dev If a LP token is supported
    mapping(address => bool) public supportedMarkets;

    /// @notice relate settler address to trader (trader_address => settler_address)
    mapping(address => address) public settlers;

    /// @notice whitelist for traders (RFQ providers)
    mapping(address => bool) public isTraders;

    /// @notice whitelist for liquidators
    mapping(address => bool) public isLiquidators;

    // @notice Mapping to track used nonces for preventing replay attacks
    mapping(uint256 => bool) public nonces;

    /// @notice Mapping of authorized isNativePools this vault is serving as treasury to
    mapping(address => bool) public isNativePools;

    /*//////////////////////////////////////////////////////////////////////////
                                     CONSTRUCTOR
    //////////////////////////////////////////////////////////////////////////*/

    constructor() EIP712("Native Credit Vault", "1") {}

    /// @notice Callback function called by NativeRFQPool after swap execution to update trader positions
    /// @dev Only callable by whitelisted NativePools, it's called after the swap is executed
    /// @param trader The address of the market maker
    /// @param sellerToken The address of the token that the swapper is selling, i.e. tokenIn
    /// @param amountIn The amount of the token that the swapper is selling
    /// @param buyerToken The address of the token that the swapper is buying, i.e. tokenOut
    /// @param amountOut The amount of the token that the swapper is buying
    function swapCallback(
        address trader,
        address sellerToken,
        int256 amountIn,
        address buyerToken,
        int256 amountOut
    ) external {
        require(isNativePools[msg.sender], ErrorsLib.OnlyNativePool());

        // Increase seller token position
        positions[trader][sellerToken] += amountIn;
        // Decrease buyer token position
        positions[trader][buyerToken] -= amountOut;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    PERMISSIONED FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Updates funding fees for traders at the end of each epoch
    /// @dev Only callable by the epoch updater
    /// @dev For each trader:
    ///      1. Checks if minimum epoch interval has elapsed
    ///      2. Distributes LP fees to LP token holders
    ///      3. Accumulates funding fees
    ///      4. Updates trader positions by deducting fees
    /// @param accruedFees Array of funding fee updates for different traders
    function epochUpdate(AccruedFundingFee[] calldata accruedFees) external {
        require(msg.sender == epochUpdater, ErrorsLib.OnlyEpochUpdater());

        for (uint256 i = 0; i < accruedFees.length; ++i) {
            address trader = accruedFees[i].trader;

            if (block.timestamp - lastEpochUpdateTimestamp[trader] < EPOCH_UPDATE_INTERVAL) {
                revert ErrorsLib.EpochUpdateInCoolDown();
            }

            for (uint256 j = 0; j < accruedFees[i].feeUpdates.length; ++j) {
                address token = accruedFees[i].feeUpdates[j].token;
                uint256 lpFee = accruedFees[i].feeUpdates[j].lpFee;
                uint256 fundingFee = accruedFees[i].feeUpdates[j].fundingFee;

                uint256 beforeExchangeRate = lpTokens[token].exchangeRate();

                if (lpFee > 0) {
                    // Distribute the LP fee to all LPToken holders
                    lpTokens[token].distributeYield(lpFee);

                    // Verify the exchange rate increase is not more than 1% after distributing LP fees
                    if (((lpTokens[token].exchangeRate() - beforeExchangeRate) * 10_000) / beforeExchangeRate > 100) {
                        revert ErrorsLib.ExchangeRateIncreaseTooMuch();
                    }
                }

                // Accumulate the funding rate fee into the total funding rate fees
                fundingFees += fundingFee;
                // Subtract the funding fee amount and LP fee amount from the trader's position for this token
                positions[trader][token] -= (lpFee + fundingFee).toInt256();
            }

            lastEpochUpdateTimestamp[trader] = block.timestamp;
        }

        emit EpochUpdated(accruedFees);
    }

    /// @notice Called by traders to settle the positions
    /// @dev This transaction requires off-chain calculation to verify if the trader's credit meets the criteria. See comments for the calculation logic.
    /// @param request The struct of the settlement request containing info of long and short positions to settle
    /// @param signature The signature of the settlement request
    function settle(
        SettlementRequest calldata request,
        bytes calldata signature
    ) external onlyTraderOrSettler(request.trader) {
        _verifySettleSignature(request, signature);

        _updatePositions(request.positionUpdates, request.trader);

        // execute token transfers
        for (uint256 i; i < request.positionUpdates.length; ++i) {
            address token = request.positionUpdates[i].token;
            int256 amount = request.positionUpdates[i].amount;

            if (amount > 0) {
                IERC20(token).safeTransferFrom(msg.sender, address(this), amount.toUint256());
            } else {
                IERC20(token).safeTransfer(request.recipient, (-amount).toUint256());
            }
        }

        emit Settled(request.trader, request.positionUpdates);
    }

    /// @notice Called by traders to remove collateral
    /// @dev This transaction requires off-chain calculation to verify if the trader's credit meets the criteria. See comments for the calculation logic.
    /// @param request The struct of the remove collateral request containing info of collateral to remove
    /// @param signature The signature of the remove collateral request
    function removeCollateral(
        RemoveCollateralRequest calldata request,
        bytes calldata signature
    ) external onlyTraderOrSettler(request.trader) {
        _verifyRemoveCollateralSignature(request, signature);

        for (uint256 i; i < request.tokens.length; ++i) {
            creditCollateral[request.trader][request.tokens[i].token] -= request.tokens[i].amount;
        }

        for (uint256 i; i < request.tokens.length; ++i) {
            address token = request.tokens[i].token;
            uint256 amount = request.tokens[i].amount;

            IERC20(token).safeTransfer(request.recipient, amount);
        }

        emit CollateralRemoved(request.trader, request.tokens);
    }

    /// @notice Called by liquidators to liquidate the underwater positions
    /// @dev This transaction requires off-chain calculation to verify if the trader's credit meets the criteria. See comments for the calculation logic.
    /// @param request The struct of the liquidation request containing info of long and short positions to liquidate
    /// @param signature The signature of the liquidation request
    function liquidate(LiquidationRequest calldata request, bytes calldata signature) external onlyLiquidator {
        _verifyLiquidationSignature(request, signature);

        _updatePositions(request.positionUpdates, request.trader);

        for (uint256 i; i < request.claimCollaterals.length; ++i) {
            creditCollateral[request.trader][request.claimCollaterals[i].token] -= request.claimCollaterals[i].amount;
        }

        for (uint256 i; i < request.positionUpdates.length; ++i) {
            address token = request.positionUpdates[i].token;
            int256 amount = request.positionUpdates[i].amount;
            if (amount > 0) {
                IERC20(token).safeTransferFrom(msg.sender, address(this), amount.toUint256());
            } else {
                IERC20(token).safeTransfer(request.recipient, (-amount).toUint256());
            }
        }

        for (uint256 i; i < request.claimCollaterals.length; ++i) {
            address token = request.claimCollaterals[i].token;
            uint256 amount = request.claimCollaterals[i].amount;
            IERC20(token).safeTransfer(request.recipient, amount);
        }

        emit Liquidated(request.trader, msg.sender, request.positionUpdates, request.claimCollaterals);
    }

    /// @notice Allows fee withdrawer to claim accumulated funding fees
    /// @dev Only callable by feeWithdrawer address
    /// @param underlying The token address of the fees to withdraw
    /// @param recipient The address that will receive the fees
    /// @param amount The amount of fees to withdraw
    function withdrawFundingFees(address underlying, address recipient, uint256 amount) external {
        require(msg.sender == feeWithdrawer, ErrorsLib.OnlyFeeWithdrawer());
        require(amount <= fundingFees, ErrorsLib.InsufficientFundingFees());

        fundingFees -= amount;

        // Withdraw underlying from vault
        IERC20(underlying).safeTransfer(recipient, amount);
    }

    /// @notice Transfers underlying assets from vault to recipient
    /// @dev Only callable by supported LP tokens
    /// @param to Recipient of the underlying assets
    /// @param amount Amount of underlying assets to transfer
    function transferOut(address to, uint256 amount) external {
        require(supportedMarkets[msg.sender], ErrorsLib.OnlyLpToken());

        // Each LP token can only transfer its own underlying token
        IERC20(LPToken(msg.sender).underlying()).safeTransfer(to, amount);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    PERMISSIONLESS FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Adds collateral for a trader's position
    /// @dev PERMISSIONLESS: Anyone can add collateral for any trader
    /// @dev Off-chain system will update trader's credit limit off-chain via event emission
    /// @param tokens Array of {token, amount} structs to be added as collateral
    /// @param trader Address of the trader receiving the collateral
    function addCollateral(TokenAmountUint[] calldata tokens, address trader) external {
        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i].token;
            require(supportedMarkets[token], ErrorsLib.OnlyLpToken());

            uint256 amount = tokens[i].amount;
            creditCollateral[trader][token] += amount;

            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        }

        emit CollateralAdded(trader, tokens);
    }

    /// @notice Repays trader's short positions
    /// @dev PERMISSIONLESS: Anyone can repay positions for any trader
    /// @param positionUpdates Array of {token, amount} structs representing positions to repay
    /// @param trader Address of the trader whose positions are being repaid
    function repay(TokenAmountInt[] calldata positionUpdates, address trader) external {
        _updatePositions(positionUpdates, trader);

        // the safeCast to Uint256 will revert if the repayments amount is negative
        for (uint256 i; i < positionUpdates.length; ++i) {
            IERC20(positionUpdates[i].token).safeTransferFrom(
                msg.sender, address(this), positionUpdates[i].amount.toUint256()
            );
        }

        emit Repaid(trader, positionUpdates);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Lists a new market (LP token)
    /// @dev Only callable by owner
    /// @param lpToken Address of the LP token to be listed
    function supportMarket(LPToken lpToken) external onlyOwner {
        // Check if market is already listed
        require(!supportedMarkets[address(lpToken)], ErrorsLib.TokenAlreadyListed());

        address underlying = address(lpToken.underlying());

        // Verify market configuration
        require(
            address(lpTokens[underlying]) == address(0) && lpToken.creditVault() == address(this),
            ErrorsLib.InvalidMarket()
        );

        // Sanity check to make sure its really LPToken
        require(address(lpToken.underlying()) != address(0), ErrorsLib.InvalidLPToken());

        // Update storage
        lpTokens[underlying] = lpToken;
        supportedMarkets[address(lpToken)] = true;
        allLPTokens.push(LPToken(lpToken));

        emit MarketListed(address(lpToken));
    }

    /// @notice Updates native pool whitelist status
    /// @dev Only callable by owner
    /// @param isActive to whitelist, false to remove from whitelist
    function setNativePool(address pool, bool isActive) external onlyOwner {
        require(pool != address(0), ErrorsLib.ZeroAddress());

        isNativePools[pool] = isActive;
        poolArray.push(pool);

        emit NativePoolUpdated(pool, isActive);
    }

    /// @notice Approves native pool to spend vault's underlying tokens
    /// @dev Only callable by owner
    /// @dev Pool must be whitelisted as native pool
    /// @param tokens Array of {token, amount} structs to approve
    /// @param pool Address of native pool to receive approval
    function setAllowance(TokenAmountUint[] calldata tokens, address pool) external onlyOwner {
        require(isNativePools[pool], ErrorsLib.OnlyNativePool());

        for (uint256 i; i < tokens.length; ++i) {
            require(tokens[i].token != address(0), ErrorsLib.ZeroAddress());

            IERC20(tokens[i].token).safeApprove(pool, tokens[i].amount);
        }
    }

    /// @notice Manages trader permissions and settlement addresses
    /// @dev Only callable by owner
    /// @param trader Address to configure trading permissions for
    /// @param settler Address authorized to settle positions on trader's behalf
    /// @param isTrader True to enable trading, false to revoke permissions
    function setTrader(address trader, address settler, bool isTrader) external onlyOwner {
        require(trader != address(0) && settler != address(0), ErrorsLib.ZeroAddress());

        isTraders[trader] = isTrader;
        settlers[trader] = settler;
    }

    /// @notice Set or remove liquidator permissions
    /// @dev Only callable by owner
    /// @param liquidator The address to grant/revoke liquidator permissions
    /// @param status True to whitelist, false to remove from whitelist
    function setLiquidator(address liquidator, bool status) external onlyOwner {
        require(liquidator != address(0), ErrorsLib.ZeroAddress());

        isLiquidators[liquidator] = status;
    }

    /// @notice Updates the authorized signer for permissioned operations
    /// @dev Only callable by owner
    /// @dev Signer verifies signatures for settlements, liquidations, and collateral removals
    /// @param _signer New signer address (cannot be zero address)
    function setSigner(address _signer) external onlyOwner {
        require(_signer != address(0), ErrorsLib.ZeroAddress());

        signer = _signer;
    }

    /// @notice Updates the authorized epoch updater address
    /// @dev Only callable by owner
    /// @dev Epoch updater is responsible for funding fee updates and distributions
    /// @param _epochUpdater New epoch updater address (cannot be zero address)
    function setEpochUpdater(address _epochUpdater) external onlyOwner {
        require(_epochUpdater != address(0), ErrorsLib.ZeroAddress());

        epochUpdater = _epochUpdater;
    }

    /// @notice Updates the authorized fee withdrawer address
    /// @dev Only callable by owner
    /// @dev Fee withdrawer can claim accumulated funding fees from the vault
    /// @param _feeWithdrawer New fee withdrawer address (cannot be zero address)
    function setFeeWithdrawer(address payable _feeWithdrawer) external onlyOwner {
        require(_feeWithdrawer != address(0), ErrorsLib.ZeroAddress());

        feeWithdrawer = _feeWithdrawer;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    function _updateNonce(uint256 nonce) internal {
        require(!nonces[nonce], ErrorsLib.NonceUsed());

        nonces[nonce] = true;
    }

    function _updatePositions(ICreditVault.TokenAmountInt[] memory positionUpdates, address trader) internal {
        for (uint256 i; i < positionUpdates.length; ++i) {
            address token = positionUpdates[i].token;
            int256 amount = positionUpdates[i].amount;
            int256 newPositionValue = positions[trader][token] + amount;

            // Position must decrease without flipping its sign (e.g. long 100 -> long 50, not long 100 -> short 20)
            if (positions[trader][token] * amount >= 0 || positions[trader][token] * newPositionValue < 0) {
                revert ErrorsLib.InvalidPositionUpdateAmount();
            }

            positions[trader][token] = newPositionValue;
        }
    }

    function _verifySettleSignature(
        ICreditVault.SettlementRequest calldata request,
        bytes calldata signature
    ) internal {
        require(request.deadline >= block.timestamp, ErrorsLib.RequestExpired());

        _updateNonce(request.nonce);

        bytes32 msgHash = keccak256(
            abi.encode(
                SETTLEMENT_REQUEST_SIGNATURE_HASH,
                request.nonce,
                request.deadline,
                request.trader,
                keccak256(abi.encode(request.positionUpdates)),
                request.recipient
            )
        );
        bytes32 digest = _hashTypedDataV4(msgHash);
        address recoveredSigner = ECDSA.recover(digest, signature);

        require(recoveredSigner == signer, ErrorsLib.InvalidSignature());
    }

    function _verifyRemoveCollateralSignature(
        ICreditVault.RemoveCollateralRequest calldata request,
        bytes calldata signature
    ) internal {
        require(request.deadline >= block.timestamp, ErrorsLib.RequestExpired());

        _updateNonce(request.nonce);

        bytes32 msgHash = keccak256(
            abi.encode(
                REMOVE_COLLATERAL_REQUEST_SIGNATURE_HASH,
                request.nonce,
                request.deadline,
                request.trader,
                keccak256(abi.encode(request.tokens)),
                request.recipient
            )
        );
        bytes32 digest = _hashTypedDataV4(msgHash);
        address recoveredSigner = ECDSA.recover(digest, signature);

        require(recoveredSigner == signer, ErrorsLib.InvalidSignature());
    }

    function _verifyLiquidationSignature(
        ICreditVault.LiquidationRequest calldata request,
        bytes calldata signature
    ) internal {
        require(request.deadline >= block.timestamp, ErrorsLib.RequestExpired());

        _updateNonce(request.nonce);

        bytes32 msgHash = keccak256(
            abi.encode(
                LIQUIDATION_REQUEST_SIGNATURE_HASH,
                request.nonce,
                request.deadline,
                request.trader,
                keccak256(abi.encode(request.positionUpdates)),
                keccak256(abi.encode(request.claimCollaterals)),
                request.recipient
            )
        );
        bytes32 digest = _hashTypedDataV4(msgHash);
        address recoveredSigner = ECDSA.recover(digest, signature);

        require(recoveredSigner == signer, ErrorsLib.InvalidSignature());
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     MODIFIERS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Separate the address of trader signer and settlement wallet as the frequency of the 2 operations is very different and trader could have different security setup for 2 addresses
    modifier onlyTraderOrSettler(address trader) {
        require(isTraders[msg.sender] || (isTraders[trader] && msg.sender == settlers[trader]), ErrorsLib.OnlyTrader());
        _;
    }

    modifier onlyLiquidator() {
        require(isLiquidators[msg.sender], ErrorsLib.OnlyLiquidator());
        _;
    }
}
