// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {IQuote} from "./IQuote.sol";

interface INativeRouter is IQuote {
    function tradeRFQT(RFQTQuote memory quote) external payable;

    function tradeAutoSign(AutoSignQuote memory quote) external payable;

    event RefundETH(address recipient, uint256 amount);

    event SetSigner(address widgetFeeSigner);

    event WidgetFeeTransfer(
        address widgetFeeRecipient, uint256 widgetFeeRate, uint256 widgetFeeAmount, address widgetFeeToken
    );
}
