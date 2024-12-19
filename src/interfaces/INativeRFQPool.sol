// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {IQuote} from "./IQuote.sol";

/// @title Native RFQ Pool Interface
interface INativeRFQPool is IQuote {
    /// @notice Execute an RFQ trade with a signed quote
    /// @param quote The RFQ quote containing trade details
    function tradeRFQT(RFQTQuote memory quote) external;

    /// @notice Fill an order with permit2 authorization
    /// @param quote The quote containing trade parameters
    function fillOrder(PermitQuote memory quote) external;

    /// @notice Emitted when a signer's status is updated
    event SignerUpdated(address signer, bool value);

    /// @notice Emitted when treasury address is set
    event TreasurySet(address treasury);

    /// @notice Emitted when callback is enabled or disabled
    event EnableCallbackSet(bool value);

    /// @notice Emitted when an RFQ trade is executed
    event RFQTrade(
        address recipient,
        address sellerToken,
        address buyerToken,
        uint256 sellerTokenAmount,
        uint256 buyerTokenAmount,
        bytes16 quoteId,
        address signer
    );

    /// @notice Emitted when an order is filled
    event OrderFilled(
        address recipient,
        address sellerToken,
        address buyerToken,
        uint256 sellerTokenAmount,
        uint256 buyerTokenAmount,
        address signer,
        bytes orderBookSig,
        bytes32 orderBookDigest
    );
}
