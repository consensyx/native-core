// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../../src/interfaces/IQuote.sol";
import "../../src/interfaces/ICreditVault.sol";

library SignatureUtils {
    function generateQuoteSignature(IQuote.RFQTQuote memory quote) internal view returns (bytes32) {
        // keccak256("Order(uint256 nonce,address signer,address buyerToken,address sellerToken,uint256 buyerTokenAmount,uint256 sellerTokenAmount,uint256 deadlineTimestamp,uint256 decayStartTime,uint256 decayEndTime,uint256 decayExponent,uint256 maxSlippageBps,bytes16 quoteId)");
        bytes32 ORDER_SIGNATURE_HASH = 0x4565bd20a17f238b49f99e4a1b2efa1e0c58f85e5c81d4f4a8957f3b991c4f8a;

        bytes32 quoteStructHash = keccak256(
            abi.encode(
                ORDER_SIGNATURE_HASH,
                quote.nonce,
                quote.signer,
                quote.buyerToken,
                quote.sellerToken,
                quote.buyerTokenAmount,
                quote.sellerTokenAmount,
                quote.deadlineTimestamp,
                quote.decayStartTime,
                quote.decayEndTime,
                quote.decayExponent,
                quote.maxSlippageBps,
                quote.quoteId
            )
        );

        return _hashTypedDataV4(quoteStructHash, quote.pool, "Native RFQ Pool", "1");
    }

    function generateWidgetFeeSignature(
        IQuote.RFQTQuote memory quote,
        address routerAddress
    ) internal view returns (bytes32) {
        bytes32 RFQ_QUOTE_WIDGET_SIGNATURE_HASH =
            keccak256("RFQTQuote(bytes32 quote,address widgetFeeRecipient,uint256 widgetFeeRate)");

        bytes32 quoteHash = _generateQuoteHash(quote);
        bytes32 widgetFeeStructHash = keccak256(
            abi.encode(
                RFQ_QUOTE_WIDGET_SIGNATURE_HASH, quoteHash, quote.widgetFee.feeRecipient, quote.widgetFee.feeRate
            )
        );

        return _hashTypedDataV4(widgetFeeStructHash, routerAddress, "Native Router", "1");
    }

    function _generateQuoteHash(IQuote.RFQTQuote memory quote) internal pure returns (bytes32) {
        // This matches the exact logic in NativeRouter._verifyRFQSignature
        return keccak256(
            abi.encode(
                quote.pool,
                quote.recipient,
                quote.sellerToken,
                quote.buyerToken,
                quote.sellerTokenAmount,
                quote.buyerTokenAmount,
                quote.deadlineTimestamp,
                quote.decayStartTime,
                quote.decayExponent,
                quote.maxSlippageBps,
                quote.multiHop,
                quote.signature
            )
        );
    }

    function _hashTypedDataV4(
        bytes32 structHash,
        address verifyingContract,
        string memory name,
        string memory version
    ) internal view returns (bytes32) {
        bytes32 DOMAIN_SEPARATOR_TYPEHASH =
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

        bytes32 domainSeparator = keccak256(
            abi.encode(
                DOMAIN_SEPARATOR_TYPEHASH,
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                block.chainid,
                verifyingContract
            )
        );

        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function generateSettleSignature(
        ICreditVault.SettlementRequest memory request,
        address recipient,
        address creditVault
    ) internal view returns (bytes32) {
        // keccak256("SettlementRequest(uint256 nonce,uint256 deadline,address trader,bytes32 positionUpdates,address recipient)")
        bytes32 SETTLEMENT_REQUEST_SIGNATURE_HASH = 0xe83563cdfbb4d31bd8759eea5a634fbe67ea13b6739d04d2426c621fee979fa4;

        bytes32 msgHash = keccak256(
            abi.encode(
                SETTLEMENT_REQUEST_SIGNATURE_HASH,
                request.nonce,
                request.deadline,
                request.trader,
                keccak256(abi.encode(request.positionUpdates)),
                recipient
            )
        );

        return _hashTypedDataV4(msgHash, creditVault, "Native Credit Vault", "1");
    }

    function generateRemoveCollateralSignature(
        ICreditVault.RemoveCollateralRequest memory request,
        address recipient,
        address creditVault
    ) internal view returns (bytes32) {
        // keccak256("RemoveCollateralRequest(uint256 nonce,uint256 deadline,address trader,bytes32 tokens,address recipient)")
        bytes32 REMOVE_COLLATERAL_REQUEST_SIGNATURE_HASH =
            0x6b9aa5f8de278806afcc63bb2d2e633b4da3536375ca60f09ae8fae5829b3c46;

        bytes32 msgHash = keccak256(
            abi.encode(
                REMOVE_COLLATERAL_REQUEST_SIGNATURE_HASH,
                request.nonce,
                request.deadline,
                request.trader,
                keccak256(abi.encode(request.tokens)),
                recipient
            )
        );

        return _hashTypedDataV4(msgHash, creditVault, "Native Credit Vault", "1");
    }

    function generateLiquidationSignature(
        ICreditVault.LiquidationRequest memory request,
        address recipient,
        address creditVault
    ) internal view returns (bytes32) {
        // keccak256("LiquidationRequest(uint256 nonce,uint256 deadline,address trader,bytes32 positionUpdates,bytes32 claimCollaterals,address recipient)")
        bytes32 LIQUIDATION_REQUEST_SIGNATURE_HASH = 0x76c5f3d53a01a9f0a59b081b22aba3a0f03248e9241993e97d1d025ef2ffaac2;

        bytes32 msgHash = keccak256(
            abi.encode(
                LIQUIDATION_REQUEST_SIGNATURE_HASH,
                request.nonce,
                request.deadline,
                request.trader,
                keccak256(abi.encode(request.positionUpdates)),
                keccak256(abi.encode(request.claimCollaterals)),
                recipient
            )
        );

        return _hashTypedDataV4(msgHash, creditVault, "Native Credit Vault", "1");
    }
}
