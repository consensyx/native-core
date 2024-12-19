// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISignatureTransfer} from "@permit2/interfaces/ISignatureTransfer.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract Permit2Demo {
    using SafeERC20 for IERC20;

    // Permit2 contract address (Mainnet)
    ISignatureTransfer public constant PERMIT2 = ISignatureTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    // Transfer tokens using permit2
    function transferWithPermit2(
        address token,
        uint256 amount,
        address recipient,
        ISignatureTransfer.PermitTransferFrom calldata permit,
        bytes calldata signature
    ) external {
        // Verify token and amount match the permit
        require(token == permit.permitted.token, "Token mismatch");
        require(amount <= permit.permitted.amount, "Amount exceeds permitted");

        // Transfer tokens using permit2
        PERMIT2.permitTransferFrom(
            permit,
            ISignatureTransfer.SignatureTransferDetails({to: recipient, requestedAmount: amount}),
            msg.sender, // owner
            signature
        );

        // Emit event for tracking
        emit TransferWithPermit2(token, msg.sender, recipient, amount);
    }

    // Events
    event TransferWithPermit2(address indexed token, address indexed from, address indexed to, uint256 amount);
}
