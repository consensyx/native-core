// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {IQuote} from "./IQuote.sol";

interface INativeRFQPool is IQuote {
    function tradeRFQT(RFQTQuote memory quote) external;

    function tradeAutoSign(AutoSignQuote memory quote) external;

    event SignerUpdated(address signer, bool value);
    event TreasurySet(address treasury);
    event EnableCallbackSet(bool value);
    event RFQTrade(
        address recipient,
        address sellerToken,
        address buyerToken,
        uint256 sellerTokenAmount,
        uint256 buyerTokenAmount,
        bytes16 quoteId,
        address signer
    );

    event AutoSignTrade(
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
