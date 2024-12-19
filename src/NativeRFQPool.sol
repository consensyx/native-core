// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712, ECDSA} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import "./libraries/ConstantsLib.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";

import {IWETH9} from "./interfaces/IWETH9.sol";
import {ICreditVault} from "./interfaces/ICreditVault.sol";
import {INativeRFQPool} from "./interfaces/INativeRFQPool.sol";

contract NativeRFQPool is INativeRFQPool, Ownable2Step, EIP712 {
    using SafeERC20 for IERC20;
    using Address for address payable;

    /// @notice Flag to enable/disable post-trade callback to treasury
    bool public isEnableCallback;

    /// @notice Pool name
    string public name;

    /// @notice Address of the router contract that can execute trades
    address public router;

    /// @notice Address of the WETH contract for handling ETH/WETH conversions
    address public WETH9;

    /// @notice Address of the treasury that holds and manages tokens, can be a CreditVault or market maker own account
    address public treasury;

    /// @notice Mapping to track used nonces for preventing replay attacks
    mapping(uint256 => bool) public nonces;

    /// @notice Mapping of authorized market makers who can sign RFQ quotes
    mapping(address => bool) public isSigner;

    /*//////////////////////////////////////////////////////////////////////////
                                     RECEIVE FUNCTION
    //////////////////////////////////////////////////////////////////////////*/

    receive() external payable {
        require(msg.sender == WETH9, ErrorsLib.OnlyWETH9());
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     CONSTRUCTOR
    //////////////////////////////////////////////////////////////////////////*/

    constructor(
        address _WETH9,
        address _router,
        address _treasury,
        string memory _name
    ) EIP712("Native RFQ Pool", "1") {
        require(
            _WETH9 != address(0) && _router != address(0) && _treasury != address(0) && bytes(_name).length > 0,
            ErrorsLib.ZeroInput()
        );

        name = _name;
        router = _router;
        WETH9 = _WETH9;
        treasury = _treasury;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                      RFQ TRADING
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice See NativeRouter.tradeRFQT for detailed documentation
    /// @dev Called by NativeRouter to execute RFQ trades in the pool
    function tradeRFQT(RFQTQuote memory quote) external override onlyRouter {
        // Prevent replay attacks
        require(!nonces[quote.nonce], ErrorsLib.NonceUsed());

        // Verify market maker signature
        _verifyPMMSignature(quote);

        // Mark nonce as used
        nonces[quote.nonce] = true;

        // Handle ETH case: convert null address to WETH9 for seller token
        // buyerToken is validated in router and cannot be address(0)
        quote.sellerToken = quote.sellerToken == address(0) ? WETH9 : quote.sellerToken;

        uint256 buyerTokenAmount = _transferAndCallback(
            quote.signer,
            quote.recipient,
            quote.buyerToken,
            quote.sellerToken,
            quote.buyerTokenAmount,
            quote.sellerTokenAmount,
            quote.effectiveSellerTokenAmount
        );

        emit RFQTrade(
            quote.recipient,
            quote.sellerToken,
            quote.buyerToken,
            quote.effectiveSellerTokenAmount,
            buyerTokenAmount,
            quote.quoteId,
            quote.signer
        );
    }

    /// @notice See {NativeRouter-fillOrder} for detailed documentation
    /// @dev Called by NativeRouter to execute auto-sign trades in the pool
    function fillOrder(PermitQuote memory quote) external override onlyRouter {
        uint256 tokenOutAmount = _transferAndCallback(
            quote.marketMaker,
            quote.recipient,
            quote.tokenOut,
            quote.tokenIn,
            quote.amountOut,
            quote.amountIn,
            quote.effectiveAmountIn
        );

        emit OrderFilled(
            quote.recipient,
            quote.tokenIn,
            quote.tokenOut,
            quote.effectiveAmountIn,
            tokenOutAmount,
            quote.marketMaker,
            quote.orderBookSig,
            quote.orderBookDigest
        );
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Updates the treasury address that receives token
    /// @param newTreasury The new treasury address
    /// @dev Only callable by owner
    function setTreasury(address newTreasury) public onlyOwner {
        treasury = newTreasury;
        emit TreasurySet(newTreasury);
    }

    /// @notice Adds or removes a market maker's authorization to sign quotes
    /// @param signer The market maker's address
    /// @param status True to authorize, false to revoke
    /// @dev Only callable by owner
    function setSigner(address signer, bool status) external onlyOwner {
        isSigner[signer] = status;
        emit SignerUpdated(signer, status);
    }

    /// @notice Enables or disables post-trade callback functionality
    /// @dev Only callable by owner
    /// @param isEnable True to enable callbacks, false to disable
    function setEnableCallback(bool isEnable) external onlyOwner {
        isEnableCallback = isEnable;
        emit EnableCallbackSet(isEnable);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    function _transferAndCallback(
        address signer,
        address recipient,
        address buyerToken,
        address sellerToken,
        uint256 buyerTokenAmount,
        uint256 sellerTokenAmount,
        uint256 effectiveSellerTokenAmount
    ) internal returns (uint256 _buyerTokenAmount) {
        _buyerTokenAmount = effectiveSellerTokenAmount < sellerTokenAmount
            ? (effectiveSellerTokenAmount * buyerTokenAmount) / sellerTokenAmount
            : buyerTokenAmount;

        if (isEnableCallback) {
            require(
                effectiveSellerTokenAmount <= uint256(type(int256).max)
                    && _buyerTokenAmount <= uint256(type(int256).max),
                ErrorsLib.Overflow()
            );

            ICreditVault(treasury).swapCallback(
                signer, sellerToken, int256(effectiveSellerTokenAmount), buyerToken, int256(_buyerTokenAmount)
            );
        }

        _transferFromTreasury(buyerToken, recipient, _buyerTokenAmount);
    }

    /// @dev Helper function to transfer buyerToken from external account.
    function _transferFromTreasury(address token, address receiver, uint256 value) private {
        if (token == address(0)) {
            // slither-disable-next-line arbitrary-send-erc20
            IERC20(WETH9).safeTransferFrom(treasury, address(this), value);
            IWETH9(WETH9).withdraw(value);

            // Skip ETH initial balance check for saving gas
            payable(receiver).sendValue(value);
        } else {
            // slither-disable-next-line arbitrary-send-erc20
            IERC20(token).safeTransferFrom(treasury, receiver, value);
        }
    }

    function _verifyPMMSignature(RFQTQuote memory quote) internal view {
        require(isSigner[quote.signer], ErrorsLib.InvalidSigner());

        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    ORDER_SIGNATURE_HASH,
                    quote.nonce,
                    quote.signer,
                    address(this),
                    quote.recipient,
                    quote.buyerToken,
                    quote.sellerToken,
                    quote.buyerTokenAmount,
                    quote.sellerTokenAmount,
                    quote.deadlineTimestamp,
                    quote.recipient,
                    quote.quoteId
                )
            )
        );

        require(quote.signer == ECDSA.recover(digest, quote.signature), ErrorsLib.InvalidSignature());
    }

    modifier onlyRouter() {
        require(msg.sender == router, ErrorsLib.OnlyNativeRouter());
        _;
    }
}
