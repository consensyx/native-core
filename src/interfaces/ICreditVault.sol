// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

interface ICreditVault {
    function swapCallback(
        address signer,
        address sellerToken,
        int256 amount0Delta,
        address buyerToken,
        int256 amount1Delta
    ) external;

    /// @notice Epoch Funding fee updates for a specific trader
    /// @param trader The address of the trader
    /// @param feeUpdates Array of funding fee updates for different tokens
    struct AccruedFundingFee {
        address trader;
        FundingFeeAmount[] feeUpdates;
    }

    /// @notice Details of funding and reserve fees for a specific token
    /// @param token The unerlying token address
    /// @param fundingFee  Amount of fee distributed to LP holders
    /// @param reserveFee Amount of fee reserved for the protocol
    struct FundingFeeAmount {
        address token;
        uint256 fundingFee;
        uint256 reserveFee;
    }

    /// @notice Represents a token amount with unsigned integer value
    /// @param token The address of underlying token
    /// @param amount The unsigned amount of tokens
    struct TokenAmountUint {
        address token;
        uint256 amount;
    }

    /// @notice Represents a token amount with signed integer value (for positions)
    /// @param token The address of underlying token
    /// @param amount The signed amount (positive for long, negative for short)
    struct TokenAmountInt {
        address token;
        int256 amount;
    }

    /// @notice Request parameters for position settlement
    /// @param nonce Unique identifier to prevent replay attacks
    /// @param deadline Timestamp after which the request expires
    /// @param trader Address of the trader whose positions are being settled
    /// @param positionUpdates Array of position changes to be settled
    struct SettlementRequest {
        uint256 nonce;
        uint256 deadline;
        address trader;
        TokenAmountInt[] positionUpdates;
    }

    /// @notice Request parameters for collateral removal
    /// @param nonce Unique identifier to prevent replay attacks
    /// @param deadline Timestamp after which the request expires
    /// @param trader Address of the trader removing collateral
    /// @param tokens Array of collateral tokens to be removed
    struct RemoveCollateralRequest {
        uint256 nonce;
        uint256 deadline;
        address trader;
        TokenAmountUint[] tokens;
    }

    /// @notice Request parameters for position liquidation
    /// @param nonce Unique identifier to prevent replay attacks
    /// @param deadline Timestamp after which the request expires
    /// @param trader Address of the trader being liquidated
    /// @param positionUpdates Array of position changes from liquidation
    /// @param claimCollaterals Array of collateral tokens to be claimed
    struct LiquidationRequest {
        uint256 nonce;
        uint256 deadline;
        address trader;
        TokenAmountInt[] positionUpdates;
        TokenAmountUint[] claimCollaterals;
    }

    /// @notice Emitted when a new market (LP token) is listed
    /// @param lpToken The address of the newly listed LP token
    event MarketListed(address lpToken);

    /// @notice Emitted when epoch funding fees are updated for traders
    /// @param accruedFundingFees Array of funding fee updates for different traders
    event EpochUpdated(AccruedFundingFee[] accruedFundingFees);

    /// @notice Emitted when a trader's positions are repaid
    /// @param trader The address of the trader whose positions are being repaid
    /// @param repayments Array of token amounts being repaid
    event Repaid(address trader, TokenAmountInt[] repayments);

    /// @notice Emitted when a trader's positions are settled
    /// @param trader The address of the trader whose positions are being settled
    /// @param positionUpdates Array of position changes
    event Settled(address trader, TokenAmountInt[] positionUpdates);

    /// @notice Emitted when collateral is added for a trader
    /// @param trader The address of the trader receiving collateral
    /// @param collateralUpdates Array of collateral token amounts added
    event CollateralAdded(address trader, TokenAmountUint[] collateralUpdates);

    /// @notice Emitted when collateral is removed for a trader
    /// @param trader The address of the trader removing collateral
    /// @param collateralUpdates Array of collateral token amounts removed
    event CollateralRemoved(address trader, TokenAmountUint[] collateralUpdates);

    /// @notice Emitted when a trader's positions are liquidated
    /// @param trader The address of the trader being liquidated
    /// @param liquidator The address performing the liquidation
    /// @param positionUpdates Array of position changes from liquidation
    /// @param claimCollaterals Array of collateral tokens claimed by liquidator
    event Liquidated(
        address trader, address liquidator, TokenAmountInt[] positionUpdates, TokenAmountUint[] claimCollaterals
    );

    /// @notice Emitted when a native pool's status is updated
    /// @param pool The address of the native pool
    /// @param isActive The new status of the pool
    event NativePoolUpdated(address indexed pool, bool isActive);

    /// @notice Emitted when liquidator is set
    event LiquidatorSet(address liquidator, bool status);

    /// @notice Emitted when signer is set
    event SignerSet(address signer);

    /// @notice Emitted when epoch updater is set
    event EpochUpdaterSet(address epochUpdater);

    /// @notice Emitted when fee withdrawer is set
    event FeeWithdrawerSet(address feeWithdrawer);
}
