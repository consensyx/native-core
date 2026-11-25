// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20Metadata as IERC20} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {ErrorsLib} from "../libraries/ErrorsLib.sol";
import {SafeERC20} from "../libraries/SafeERC20.sol";
import {NativeLPToken} from "../NativeLPToken.sol";
import {ReentrancyGuardTransient} from "../libraries/ReentrancyGuardTransient.sol";

/**
 * @title LiquidityPairing
 * @notice A DeFi liquidity incentivization contract that enables projects/protocols to compete for liquidity
 * by offering their tokens as rewards.
 *
 * @dev This contract serves as a bridge between liquidity providers and the Native protocol:
 * - Projects can incentivize liquidity provision by offering their tokens as rewards
 * - Users can deposit underlying assets (e.g., USDT, WETH) and earn multiple reward tokens
 * - The deposited assets are used by Native protocol for market making
 *
 * Key features:
 * - Multi-token reward system (up to 5 different reward tokens)
 * - Time-based reward distribution
 * - Emergency withdrawal functionality
 * - Early withdrawal fee mechanism to protect against front-running
 */
contract LiquidityPairing is Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice User staking information
    struct UserInfo {
        uint256 shares; // Amount of LP shares owned by user
        mapping(address => uint256) rewardDebts; // User's reward debt per token
    }

    /// @notice Reward token information and accounting data
    struct RewardInfo {
        uint256 accTokenPerShare; // Accumulated rewards per share, scaled by precision
        uint256 rewardPerSecond; // Number of reward tokens distributed per second
        uint256 lastRewardTimestamp; // Last timestamp that rewards were calculated
        uint256 startTimestamp; // Timestamp when reward distribution starts
        uint256 endTimestamp; // Timestamp when reward distribution ends
        uint256 precision; // Precision factor to handle decimals correctly
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     STATE VARIABLES
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice The name of the liquidity pool identifies the project's incentivization pool it represents.
    /// @dev Format example: "ProjectX USDT Pool" - indicates this is ProjectX's liquidity incentivization pool for USDT
    string public name;

    /// @notice Maximum number of reward tokens allowed to control gas costs
    uint256 public constant MAX_REWARD_TOKENS = 5;

    /// @notice Total shares owned by this pairing contract in the LP token
    uint256 public totalShares;

    /// @notice Minimum time interval between deposit and redeem (in seconds)
    uint256 public minRedeemInterval = 8 hours;

    /// @notice The LP token representing the shared liquidity pool
    NativeLPToken public immutable stakedToken;

    /// @notice The protocol token address that this pairing contract is created for
    address public immutable protocolToken;

    /// @notice The underlying token that this LP token represents
    IERC20 public immutable underlying;

    /// @notice The address of the early withdraw fee receiver
    address public earlyWithdrawFeeReceiver;

    /// @notice Array of all project reward token addresses
    address[] public rewardTokens;

    /// @notice Mapping of reward token => reward information
    mapping(address => RewardInfo) public rewardTokenInfo;

    /// @notice Mapping of liquidity provider address => liquidity information
    mapping(address => UserInfo) public userInfo;

    /// @notice Mapping of user addresses to their next timestamp when they can redeem without early withdrawal fee
    mapping(address => uint256) public nextFreeRedeemTimestamp;

    /*//////////////////////////////////////////////////////////////////////////
                                        EVENTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a user provides liquidity
    /// @param user Address of the liquidity provider
    /// @param amount Amount of tokens provided
    /// @param shares Amount of LP shares received
    event LiquidityAdded(address indexed user, uint256 amount, uint256 shares);

    /// @notice Emitted when a user withdraws liquidity
    /// @param user Address of the liquidity provider
    /// @param shares Amount of LP shares burned
    /// @param amount Amount of tokens received
    event LiquidityRemoved(address indexed user, uint256 shares, uint256 amount);

    /// @notice Emitted when tokens are recovered from the contract
    event TokenRecovery(address indexed token, uint256 amount);

    /// @notice Event emitted when minimum redeem interval is updated
    event MinRedeemIntervalUpdated(uint256 newInterval);

    /// @notice Emitted when update pool is called
    event UpdatePool(address indexed token);

    /// @notice Emitted when a project updates their reward rate
    event RewardRateUpdated(address indexed token, uint256 newRate);

    /// @notice Emitted when a project adds their reward token
    event RewardTokenAdded(address indexed token, uint256 rewardPerSecond);

    /// @notice Emitted when rewards are harvested
    event RewardHarvested(address indexed receiver, address indexed rewardToken, uint256 amount);

    /// @notice Emitted when reward period is updated for a project
    event RewardTimestampsUpdated(address indexed token, uint256 startTimestamp, uint256 endTimestamp);

    /// @notice Event emitted when early withdraw fee receiver is updated
    event EarlyWithdrawFeeReceiverUpdated(address oldReceiver, address newReceiver);

    /// @notice Event emitted when liquidity is removed in emergency
    event EmergencyLiquidityRemoved(address indexed user, uint256 shares, uint256 amount);

    /// @notice Emitted when early withdrawal fee is collected
    event EarlyWithdrawFeeCollected(address indexed user, uint256 amount);

    /*//////////////////////////////////////////////////////////////////////////
                                     CONSTRUCTOR
    //////////////////////////////////////////////////////////////////////////*/

    constructor(string memory _name, NativeLPToken _stakedToken, address _protocolToken) {
        name = _name;
        stakedToken = _stakedToken;
        underlying = _stakedToken.underlying();
        protocolToken = _protocolToken;
        earlyWithdrawFeeReceiver = msg.sender;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     LIQUIDITY OPERATIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Allows users to add liquidity to the pool
    /// @param _amount Amount of tokens to provide
    /// @return shares Amount of LP shares received
    function addLiquidity(uint256 _amount) external nonReentrant returns (uint256 shares) {
        UserInfo storage user = userInfo[msg.sender];

        _updatePools();

        if (user.shares > 0) {
            _harvestRewards(msg.sender);
        }

        if (_amount > 0) {
            // Get balance before deposit to calculate actual shares minted
            uint256 sharesBefore = stakedToken.sharesOf(address(this));

            // Transfer underlying tokens from user
            underlying.safeTransferFrom(msg.sender, address(this), _amount);

            // Approve NativeLPToken to spend underlying
            underlying.safeApprove(address(stakedToken), _amount);

            // Deposit underlying to get LP shares
            shares = stakedToken.deposit(_amount);

            // Verify shares received
            require(stakedToken.sharesOf(address(this)) - sharesBefore == shares, "Shares mismatch");

            user.shares += shares;
            totalShares += shares;
        }

        // Update all reward debts based on shares
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            address token = rewardTokens[i];
            RewardInfo storage reward = rewardTokenInfo[token];
            user.rewardDebts[token] = (user.shares * reward.accTokenPerShare) / reward.precision;
        }

        // Update next free redeem timestamp
        nextFreeRedeemTimestamp[msg.sender] = block.timestamp + minRedeemInterval;

        emit LiquidityAdded(msg.sender, _amount, shares);

        return shares;
    }

    /// @notice Allows users to remove liquidity from the pool
    /// @param _shares Amount of LP shares to burn
    /// @return amount Amount of tokens received
    function removeLiquidity(uint256 _shares) external nonReentrant returns (uint256 amount) {
        UserInfo storage user = userInfo[msg.sender];
        require(user.shares >= _shares, "Insufficient shares");

        _updatePools();

        _harvestRewards(msg.sender);

        if (_shares > 0) {
            user.shares -= _shares;
            totalShares -= _shares;

            // Redeem LP shares for underlying tokens
            amount = stakedToken.redeem(_shares);

            amount = _transferUnderlyingAndFee(msg.sender, amount);
        }

        // Update all reward debts based on amount
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            address token = rewardTokens[i];
            RewardInfo storage reward = rewardTokenInfo[token];
            user.rewardDebts[token] = (user.shares * reward.accTokenPerShare) / reward.precision;
        }

        emit LiquidityRemoved(msg.sender, _shares, amount);
        return amount;
    }

    /// @notice Emergency withdraw liquidity without caring about rewards
    /// @return amount Amount of underlying tokens received
    function emergencyRemoveLiquidity() external nonReentrant returns (uint256 amount) {
        UserInfo storage user = userInfo[msg.sender];

        uint256 sharesToRemove = user.shares;
        require(sharesToRemove > 0, "No shares to redeem");

        // Update user's state
        user.shares = 0;
        totalShares = totalShares - sharesToRemove;

        // Redeem LP shares for underlying tokens without updating pools or harvesting rewards
        amount = stakedToken.redeem(sharesToRemove);

        // Reset all reward debts to 0
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            user.rewardDebts[rewardTokens[i]] = 0;
        }

        // Transfer underlying tokens to user
        amount = _transferUnderlyingAndFee(msg.sender, amount);

        emit EmergencyLiquidityRemoved(msg.sender, sharesToRemove, amount);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                SET REWARD TOKEN PARAMS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Update reward per second for a specific token
    /// @dev Can only be called before the reward distribution period starts
    /// @param _rewardToken Address of the reward token to update
    /// @param _rewardPerSecond New reward per second value
    function updateRewardPerSecond(address _rewardToken, uint256 _rewardPerSecond) external onlyOwner {
        RewardInfo storage reward = rewardTokenInfo[_rewardToken];

        // Can't update reward rate if pool has started
        require(block.timestamp < reward.startTimestamp, "Pool has started");

        uint256 decimalsRewardToken = uint256(IERC20(_rewardToken).decimals());
        require(reward.precision * _rewardPerSecond / (10 ** decimalsRewardToken) >= 1e8, "Reward rate too low");

        reward.rewardPerSecond = _rewardPerSecond;

        emit RewardRateUpdated(_rewardToken, _rewardPerSecond);
    }

    /// @notice Update reward token's start and end timestamps
    /// @dev Can update timestamps before pool starts or after it ends
    /// @notice Stop rewards for a reward token that has ended its distribution period
    /// @param _rewardToken Address of the reward token to update
    /// @param _startTimestamp New start timestamp
    /// @param _endTimestamp New end timestamp
    function updateRewardTimestamps(
        address _rewardToken,
        uint256 _startTimestamp,
        uint256 _endTimestamp
    ) external onlyOwner {
        RewardInfo storage reward = rewardTokenInfo[_rewardToken];
        require(reward.startTimestamp != 0, "Reward token not added");
        require(block.timestamp < reward.startTimestamp || block.timestamp > reward.endTimestamp, "Reward in progress");
        require(_startTimestamp < _endTimestamp, "End time must be after start time");
        require(block.timestamp < _startTimestamp, "Start time already passed");

        // Ensure previous round is properly finalized (by calling updatePool) before starting new round
        if (block.timestamp > reward.endTimestamp && totalShares > 0) {
            require(reward.lastRewardTimestamp == reward.endTimestamp, "Previous round reward accounting not finalized");
        }

        reward.startTimestamp = _startTimestamp;
        reward.endTimestamp = _endTimestamp;
        reward.lastRewardTimestamp = _startTimestamp;

        emit RewardTimestampsUpdated(_rewardToken, _startTimestamp, _endTimestamp);
    }

    /// @notice Updates reward state for a specific reward token, typically called to finalize a reward round
    /// @param _rewardToken Address of reward token to update
    function updatePool(address _rewardToken) external {
        _updatePool(_rewardToken);

        emit UpdatePool(_rewardToken);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                OTHER EXTERNAL FUNCTIONS 
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Add a new reward token to the staking pool
    /// @param _rewardToken Address of the reward token
    /// @param _rewardPerSecond Rewards distributed per second
    /// @param _startTimestamp Start timestamp of the reward period
    /// @param _endTimestamp End timestamp of the reward period
    function addRewardToken(
        address _rewardToken,
        uint256 _rewardPerSecond,
        uint256 _startTimestamp,
        uint256 _endTimestamp
    ) external onlyOwner {
        require(rewardTokens.length < MAX_REWARD_TOKENS, "Max reward tokens reached");
        require(_rewardToken != address(0), "Zero reward token address");
        require(_rewardToken != address(stakedToken), "Reward token cannot be stake token");
        require(_startTimestamp < _endTimestamp, "End time must be after start time");
        require(block.timestamp < _startTimestamp, "Start time already passed");
        require(stakedToken.trustedOperators(address(this)), "Current contract is not whitelisted");

        // Check for duplicate reward tokens
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            require(_rewardToken != rewardTokens[i], "Duplicate reward tokens");
        }

        uint256 decimals = IERC20(_rewardToken).decimals();
        // Maximum precision is 30 decimals to prevent overflow
        require(decimals < 30, "Token decimals exceed maximum precision");

        // Calculate precision scaling factor
        // We use precision to scale up reward calculations to prevent truncation errors
        // and maintain accuracy when calculating rewards per share
        uint256 precision = uint256(10 ** (uint256(30) - decimals));

        rewardTokenInfo[_rewardToken] = RewardInfo({
            accTokenPerShare: 0,
            rewardPerSecond: _rewardPerSecond,
            lastRewardTimestamp: _startTimestamp,
            startTimestamp: _startTimestamp,
            endTimestamp: _endTimestamp,
            precision: precision
        });

        rewardTokens.push(_rewardToken);

        require(precision * _rewardPerSecond / (10 ** decimals) >= 1e8, "Reward rate too low");

        emit RewardTokenAdded(_rewardToken, _rewardPerSecond);
    }

    /// @param _interval New minimum interval in seconds
    /// @dev Can only be called by the owner
    function setMinRedeemInterval(uint256 _interval) external onlyOwner {
        minRedeemInterval = _interval;

        emit MinRedeemIntervalUpdated(_interval);
    }

    /// @notice Sets the early withdraw fee receiver address
    /// @param _receiver New fee receiver address
    function setEarlyWithdrawFeeReceiver(address _receiver) external onlyOwner {
        require(_receiver != address(0), ErrorsLib.ZeroAddress());

        address oldReceiver = earlyWithdrawFeeReceiver;
        earlyWithdrawFeeReceiver = _receiver;

        emit EarlyWithdrawFeeReceiverUpdated(oldReceiver, _receiver);
    }

    /// @notice Allows the owner to recover tokens sent to the contract by mistake
    /// @dev Cannot recover staked token or reward tokens
    /// @param _token Token address to recover
    function recoverToken(address _token) external onlyOwner {
        require(
            _token != address(stakedToken) && _token != address(underlying),
            "Staked token and underlying not recoverable"
        );

        for (uint256 i = 0; i < rewardTokens.length; i++) {
            require(_token != rewardTokens[i], "Reward token not recoverable");
        }

        uint256 balance = IERC20(_token).balanceOf(address(this));
        require(balance != 0, "No tokens to recover");

        IERC20(_token).safeTransfer(msg.sender, balance);

        emit TokenRecovery(_token, balance);
    }

    /// @notice View function to see pending rewards for a user
    /// @param _user Address of the user to check
    /// @return tokens Array of reward token addresses
    /// @return rewards Array of pending reward amounts corresponding to each token
    function getPendingRewards(address _user)
        external
        view
        returns (address[] memory tokens, uint256[] memory rewards)
    {
        tokens = rewardTokens;
        rewards = new uint256[](tokens.length);

        UserInfo storage user = userInfo[_user];
        uint256 stakedTokenSupply = stakedToken.balanceOf(address(this));

        for (uint256 i = 0; i < tokens.length; i++) {
            RewardInfo storage reward = rewardTokenInfo[tokens[i]];
            uint256 accTokenPerShare = reward.accTokenPerShare;

            if (block.timestamp > reward.lastRewardTimestamp && stakedTokenSupply != 0) {
                uint256 multiplier =
                    _calcRewardInterval(reward.endTimestamp, reward.lastRewardTimestamp, block.timestamp);
                uint256 tokenReward = multiplier * reward.rewardPerSecond;

                accTokenPerShare += (tokenReward * reward.precision) / stakedTokenSupply;
            }

            rewards[i] = (user.shares * accTokenPerShare) / reward.precision - user.rewardDebts[tokens[i]];
        }

        return (tokens, rewards);
    }

    /// @notice Get the total underlying token amount for all shares in this contract
    /// @return The total underlying token amount
    function getTotalUnderlying() external view returns (uint256) {
        return stakedToken.getUnderlyingByShares(totalShares);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    function _updatePools() internal {
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            _updatePool(rewardTokens[i]);
        }
    }

    function _updatePool(address _rewardToken) internal {
        RewardInfo storage reward = rewardTokenInfo[_rewardToken];
        if (block.timestamp <= reward.lastRewardTimestamp) {
            return;
        }

        if (totalShares == 0) {
            reward.lastRewardTimestamp = block.timestamp;
            return;
        }

        uint256 multiplier = _calcRewardInterval(reward.endTimestamp, reward.lastRewardTimestamp, block.timestamp);
        uint256 tokenReward = multiplier * reward.rewardPerSecond;

        // update the accumulated reward per share
        reward.accTokenPerShare = reward.accTokenPerShare + (tokenReward * reward.precision) / totalShares;

        // If the last reward timestamp is after the end timestamp, set it to the end timestamp
        reward.lastRewardTimestamp = block.timestamp > reward.endTimestamp ? reward.endTimestamp : block.timestamp;
    }

    function _harvestRewards(address _user) internal {
        UserInfo storage user = userInfo[_user];

        for (uint256 i = 0; i < rewardTokens.length; i++) {
            address token = rewardTokens[i];
            RewardInfo storage reward = rewardTokenInfo[token];

            uint256 pending = (user.shares * reward.accTokenPerShare) / reward.precision - user.rewardDebts[token];

            if (pending > 0) {
                IERC20(token).safeTransfer(_user, pending);
                emit RewardHarvested(_user, token, pending);
            }
        }
    }

    /// @dev Calculates early withdraw fee if applicable and transfers tokens
    /// @param _user Address of the user receiving underlying tokens
    /// @param _amount Amount of underlying tokens before fee deduction
    /// @return amount Amount of underlying tokens after fee deduction
    function _transferUnderlyingAndFee(address _user, uint256 _amount) private returns (uint256 amount) {
        amount = _amount;
        uint256 earlyWithdrawFeeBips;
        uint256 earlyWithdrawFee;

        if (
            block.timestamp < nextFreeRedeemTimestamp[_user]
                && (earlyWithdrawFeeBips = stakedToken.earlyWithdrawFeeBips()) > 0
        ) {
            earlyWithdrawFee = (_amount * earlyWithdrawFeeBips) / 10_000;
            amount -= earlyWithdrawFee;
        }

        // Transfer underlying tokens to user
        underlying.safeTransfer(_user, amount);

        // Transfer early withdraw fee to fee receiver
        if (earlyWithdrawFee > 0) {
            underlying.safeTransfer(earlyWithdrawFeeReceiver, earlyWithdrawFee);
            emit EarlyWithdrawFeeCollected(_user, earlyWithdrawFee);
        }
    }

    function _calcRewardInterval(uint256 _endTimestamp, uint256 _from, uint256 _to) internal pure returns (uint256) {
        if (_to <= _endTimestamp) {
            return _to - _from;
        } else if (_from >= _endTimestamp) {
            return 0;
        } else {
            return _endTimestamp - _from;
        }
    }
}
