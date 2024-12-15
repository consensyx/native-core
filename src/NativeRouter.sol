// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EIP712, ECDSA} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import {IWETH9} from "./interfaces/IWETH9.sol";
import {INativeRouter} from "./interfaces/INativeRouter.sol";

import "./libraries/ConstantsLib.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {Orders} from "./libraries/Order.sol";
import {SafeCast} from "./libraries/SafeCast.sol";
import {Multicall} from "./libraries/Multicall.sol";
import {TransferHelper} from "./libraries/TransferHelper.sol";
import {ReentrancyGuardTransient} from "./libraries/ReentrancyGuardTransient.sol";

import {CreditVault} from "./CreditVault.sol";
import {NativeRFQPool} from "./NativeRFQPool.sol";
import {ExternalSwap} from "./libraries/ExternalSwap.sol";

contract NativeRouter is INativeRouter, EIP712, Ownable, ReentrancyGuardTransient, Multicall {
    using SafeCast for uint256;

    /// @dev Address of the Wrapped Ether (WETH9) contract
    address public WETH9;

    /// @dev Address of the CreditVault contract that manages credit and native pools
    address public vault;

    /// @dev Address of signer authorized to sign RFQ trade and auto-sign trade messages
    address public signer;

    /// @notice Mapping to track used nonces for preventing replay attacks
    mapping(uint256 => bool) public nonces;

    /// @dev Mapping to track which external routers are whitelisted for swaps
    mapping(address => bool) public whitelistRouter;

    /*//////////////////////////////////////////////////////////////////////////
                                     RECEIVE FUNCTION
    //////////////////////////////////////////////////////////////////////////*/

    receive() external payable {
        if (msg.sender != WETH9) {
            revert ErrorsLib.OnlyWETH9();
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     CONSTRUCTOR
    //////////////////////////////////////////////////////////////////////////*/

    constructor(address _vault, address _WETH9, address _signer) EIP712("Native Router", "1") {
        if (_vault == address(0) || _WETH9 == address(0)) revert ErrorsLib.ZeroAddress();

        vault = _vault;
        WETH9 = _WETH9;

        setSigner(_signer);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                      RFQ TRADING
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Execute a Request for Quote (RFQ) trade based on market maker's signed quote
    /// @dev This function facilitates trades between swappers and Native's partnered market makers:
    ///      1. Swapper requests quote from Native API
    ///      2. Market maker provides and signs the quote
    ///      3. Native backend builds calldata with quote and signature
    ///      4. Swapper executes trade using the calldata
    function tradeRFQT(RFQTQuote memory quote) external payable override nonReentrant {
        _validateQuote(quote.effectiveSellerTokenAmount, quote.sellerTokenAmount, quote.deadlineTimestamp);

        _verifyWidgetSignature(quote);

        bool isRFQPool = CreditVault(vault).isNativePools(quote.pool);
        // address(this) is used for externalSwap
        address payee = isRFQPool ? NativeRFQPool(payable(quote.pool)).treasury() : address(this);

        quote.effectiveSellerTokenAmount = _transferSellerToken(
            quote.multiHop, payee, quote.sellerToken, quote.effectiveSellerTokenAmount, quote.widgetFee
        );

        if (isRFQPool) {
            NativeRFQPool(payable(quote.pool)).tradeRFQT(quote);
        } else if (whitelistRouter[quote.pool]) {
            Orders.Order memory order = Orders.Order({
                id: 0, // not used
                signer: address(0), // not used
                buyer: quote.pool,
                seller: address(0), // not used
                buyerToken: quote.buyerToken,
                sellerToken: quote.sellerToken,
                buyerTokenAmount: quote.buyerTokenAmount,
                sellerTokenAmount: quote.sellerTokenAmount,
                deadlineTimestamp: quote.deadlineTimestamp,
                caller: msg.sender,
                quoteId: quote.quoteId
            });

            uint256 actualAmountOut = ExternalSwap.externalSwap(
                order, quote.effectiveSellerTokenAmount, quote.recipient, address(this), quote.externalSwapCalldata
            );

            if (actualAmountOut < quote.amountOutMinimum) {
                revert ErrorsLib.NotEnoughAmountOut(actualAmountOut, quote.amountOutMinimum);
            }
        } else {
            revert ErrorsLib.InvalidRFQPool();
        }
    }

    /// @notice Execute an auto-sign trade based on pre-signed market maker quotes
    /// @dev This function enables automated trading using market makers' pre-signed quotes:
    ///      1. Market makers periodically submit signed quotes with expiry to Native API
    ///      2. When swapper requests a trade, Native API matches it with available quotes
    ///      3. If a match is found, trade executes automatically without additional market maker interaction
    /// @dev Key differences from RFQT:
    ///      1. Uses pre-signed quotes instead of real-time signatures
    ///      2. Requires additional order book verification
    ///      3. Enables faster execution as no real-time market maker interaction needed
    function tradeAutoSign(AutoSignQuote memory quote) external payable override nonReentrant {
        _validateQuote(quote.effectiveSellerTokenAmount, quote.sellerTokenAmount, quote.deadline);

        _verifyAutoSignature(quote);

        if (!CreditVault(vault).isNativePools(quote.pool)) revert ErrorsLib.InvalidRFQPool();

        address payee = NativeRFQPool(payable(quote.pool)).treasury();

        quote.effectiveSellerTokenAmount = _transferSellerToken(
            quote.multiHop, payee, quote.sellerToken, quote.effectiveSellerTokenAmount, quote.widgetFee
        );

        if (nonces[quote.nonce]) {
            revert ErrorsLib.NonceUsed();
        }
        nonces[quote.nonce] = true;

        NativeRFQPool(payable(quote.pool)).tradeAutoSign(quote);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     EMERGENCY CALL
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Emergency function to refund stuck ETH from the contract
    /// @dev Can only be called by contract owner in emergency situations
    /// @param recipient The address to receive the refunded ETH
    /// @param amount The amount of ETH to refund
    function refundETH(address recipient, uint256 amount) public payable onlyOwner nonReentrant {
        if (address(this).balance > 0) TransferHelper.safeTransferETH(recipient, amount);
        emit RefundETH(recipient, amount);
    }

    /// @notice Emergency function to refund stuck ERC20 tokens from the contract
    /// @dev Can only be called by contract owner in emergency situations
    /// @param token The address of the ERC20 token to refund
    /// @param amount The amount of tokens to refund
    /// @param recipient The address to receive the refunded tokens
    function refundERC20(address token, uint256 amount, address recipient) public payable onlyOwner nonReentrant {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (amount > balance) {
            revert ErrorsLib.InsufficientTokenAmount();
        }

        if (balance > 0) {
            TransferHelper.safeTransfer(token, recipient, balance);
        }
    }

    /// @notice Emergency function to unwrap WETH9 stuck in the contract
    /// @dev Can only be called by contract owner in emergency situations
    /// @param amount The amount of WETH9 to unwrap
    /// @param recipient The address to receive the unwrapped ETH
    function unwrapWETH9(uint256 amount, address recipient) public payable onlyOwner nonReentrant {
        if (amount == 0 || IWETH9(WETH9).balanceOf(address(this)) < amount) {
            revert ErrorsLib.InvalidWETH9Amount();
        }

        uint256 beforeETHBalance = address(this).balance;
        IWETH9(WETH9).withdraw(amount);

        TransferHelper.safeTransferETH(recipient, address(this).balance - beforeETHBalance);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Set the authorized signer for widget fee and auto-sign messages
    /// @dev Can only be called by contract owner
    /// @param _signer The new signer address to be set
    /// @dev Security considerations:
    ///      - Only owner can call (onlyOwner modifier)
    ///      - Prevents setting zero address as signer
    ///      - Emits SetSigner event for transparency
    function setSigner(address _signer) public onlyOwner {
        if (_signer == address(0)) {
            revert ErrorsLib.ZeroAddress();
        }
        signer = _signer;
        emit SetSigner(signer);
    }

    /// @notice Batch set whitelist status for external routers
    /// @dev Can only be called by contract owner
    /// @param routers Array of router addresses to be whitelisted/blacklisted
    /// @param values Array of boolean values corresponding to each router
    function setWhitelistRouter(address[] calldata routers, bool[] calldata values) external onlyOwner {
        if (routers.length != values.length) {
            revert ErrorsLib.ArraysLengthMismatch();
        }

        for (uint256 i; i < routers.length; ++i) {
            whitelistRouter[routers[i]] = values[i];
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    function _transferSellerToken(
        bool multiHop,
        address payee,
        address sellerToken,
        uint256 sellerTokenAmount,
        WidgetFee memory widgetFee
    ) internal returns (uint256 effectiveSellerTokenAmount) {
        if (msg.value > 0 && !multiHop) {
            if (sellerToken != address(0)) {
                revert ErrorsLib.UnexpectedMsgValue();
            }

            if (sellerTokenAmount > msg.value) {
                revert ErrorsLib.InvalidAmount();
            }

            // slither-disable-next-line arbitrary-send-eth
            // WETH9 is a trusted contract widely used in the ecosystem
            IWETH9(WETH9).deposit{value: sellerTokenAmount}();

            effectiveSellerTokenAmount = _chargeWidgetFee(widgetFee, sellerTokenAmount, WETH9, true);

            TransferHelper.safeTransfer(WETH9, payee, effectiveSellerTokenAmount);
        } else {
            effectiveSellerTokenAmount = _chargeWidgetFee(widgetFee, sellerTokenAmount, sellerToken, false);

            if (multiHop) {
                TransferHelper.safeTransfer(sellerToken, payee, effectiveSellerTokenAmount);
            } else {
                TransferHelper.safeTransferFrom(sellerToken, msg.sender, payee, effectiveSellerTokenAmount);
            }
        }
    }

    function _chargeWidgetFee(
        WidgetFee memory widgetFee,
        uint256 amountIn,
        address sellerToken,
        bool hasAlreadyPaid
    ) internal returns (uint256) {
        if (widgetFee.feeRate > 0) {
            if (widgetFee.feeRate > 10_000) {
                revert ErrorsLib.InvalidWidgetFeeRate();
            }
            uint256 widgetFeeAmount = (amountIn * widgetFee.feeRate) / 10_000;
            TransferHelper.safeTransferFrom(
                sellerToken, hasAlreadyPaid ? address(this) : msg.sender, widgetFee.feeRecipient, widgetFeeAmount
            );
            emit WidgetFeeTransfer(widgetFee.feeRecipient, widgetFee.feeRate, widgetFeeAmount, sellerToken);

            amountIn -= widgetFeeAmount;
        }

        return amountIn;
    }

    function _validateQuote(
        uint256 effectiveSellerTokenAmount,
        uint256 sellerTokenAmount,
        uint256 deadlineTimestamp
    ) internal view {
        if (effectiveSellerTokenAmount > sellerTokenAmount) {
            revert ErrorsLib.InvalidAmount();
        }

        if (deadlineTimestamp < block.timestamp) {
            revert ErrorsLib.RFQQuoteExpired();
        }
    }

    function _verifyWidgetSignature(RFQTQuote memory quote) internal view {
        bytes32 quoteHash = keccak256(
            abi.encode(
                quote.pool,
                quote.signer,
                quote.recipient,
                quote.sellerToken,
                quote.buyerToken,
                quote.sellerTokenAmount,
                quote.buyerTokenAmount,
                quote.deadlineTimestamp,
                quote.nonce,
                quote.multiHop,
                quote.signature,
                quote.externalSwapCalldata,
                msg.sender
            )
        );

        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    RFQ_QUOTE_WIDGET_SIGNATURE_HASH, quoteHash, quote.widgetFee.feeRecipient, quote.widgetFee.feeRate
                )
            )
        );

        address recoveredSigner = ECDSA.recover(digest, quote.widgetFeeSignature);

        if (signer != recoveredSigner) {
            revert ErrorsLib.InvalidWidgetFeeSignature();
        }
    }

    function _verifyAutoSignature(AutoSignQuote memory quote) internal view {
        bytes32 digest = _hashTypedDataV4(
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
            )
        );

        address recoveredSigner = ECDSA.recover(digest, quote.signature);

        address recoveredMMSigner = ECDSA.recover(quote.orderBookDigest, quote.orderBookSig);

        if (signer != recoveredSigner || recoveredMMSigner != quote.signer) {
            revert ErrorsLib.InvalidSigner();
        }
    }
}
