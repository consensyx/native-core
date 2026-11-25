// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {CreditVault} from "../CreditVault.sol";
import {ErrorsLib} from "../libraries/ErrorsLib.sol";
import {SafeERC20} from "../libraries/SafeERC20.sol";
import {ICreditVault} from "../interfaces/ICreditVault.sol";
import {ReentrancyGuardTransient} from "../libraries/ReentrancyGuardTransient.sol";

/// @title RepayExecutor - Contract-based settler for trader repayments
/// @notice Allows secure repayments by separating caller and payer roles
contract RepayExecutor is Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using SafeCast for int256;

    /// @notice The address that provides funds for repayments
    address public payer;

    /// @notice The CreditVault contract address
    CreditVault public immutable vault;

    /// @notice Whitelist for executors authorized to call repay function
    mapping(address => bool) public executors;

    /// @notice Emitted when payer address is updated
    event PayerUpdated(address indexed oldPayer, address indexed newPayer);

    /// @notice Emitted when executor status is updated
    event ExecutorSet(address indexed executor, bool status);

    /// @notice Emitted when repayment is executed
    event RepaymentExecuted(address indexed trader, ICreditVault.TokenAmountInt[] positionUpdates);

    constructor(address _vault, address _payer, address _executor) {
        require(_payer != address(0) && _vault != address(0) && _executor != address(0), ErrorsLib.ZeroAddress());

        payer = _payer;
        vault = CreditVault(_vault);

        setExecutor(_executor, true);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     REPAYMENT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Repays trader's short positions by transferring funds from payer to vault
    /// @param positionUpdates Array of {token, amount} structs representing positions to repay
    /// @param trader Address of the trader whose positions are being repaid
    function repay(ICreditVault.TokenAmountInt[] calldata positionUpdates, address trader) external nonReentrant {
        require(trader != address(0), ErrorsLib.ZeroAddress());
        require(executors[msg.sender], "Unauthorized");

        // Transfer funds from payer to this contract
        for (uint256 i; i < positionUpdates.length; ++i) {
            address token = positionUpdates[i].token;
            uint256 amount = positionUpdates[i].amount.toUint256();

            // Transfer from payer to this contract
            IERC20(token).safeTransferFrom(payer, address(this), amount);

            // Approve vault to transfer funds from this contract
            IERC20(token).safeApprove(address(vault), amount);
        }

        // vault.repay will transfer from this contract to vault
        vault.repay(positionUpdates, trader);

        emit RepaymentExecuted(trader, positionUpdates);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Sets the payer address that provides funds for repayments
    /// @param _payer New payer address (cannot be zero address)
    function setPayer(address _payer) external onlyOwner {
        require(_payer != address(0), ErrorsLib.ZeroAddress());

        address oldPayer = payer;
        payer = _payer;

        emit PayerUpdated(oldPayer, _payer);
    }

    /// @notice Sets or removes executor authorization
    /// @param executor The address to grant/revoke executor permissions
    /// @param status True to authorize, false to revoke authorization
    function setExecutor(address executor, bool status) public onlyOwner {
        require(executor != address(0), ErrorsLib.ZeroAddress());

        executors[executor] = status;

        emit ExecutorSet(executor, status);
    }

    /// @notice Rescue tokens accidentally sent to this contract
    /// @param token The address of the token to rescue
    /// @param to The recipient address that will receive the tokens
    /// @param amount The amount of tokens to rescue
    function rescueToken(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), ErrorsLib.ZeroAddress());

        IERC20(token).safeTransfer(to, amount);
    }
}
