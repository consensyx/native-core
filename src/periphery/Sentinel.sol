// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {CreditVault} from "../CreditVault.sol";
import {NativeLPToken} from "../NativeLPToken.sol";
import {ErrorsLib} from "../libraries/ErrorsLib.sol";
import {ICreditVault} from "../interfaces/ICreditVault.sol";
import {ReentrancyGuardTransient} from "../libraries/ReentrancyGuardTransient.sol";

/// @title Sentinel - Guardian Contract for CreditVault Emergency Control
//
/// @notice Sentinel acts as a secure intermediary owner for CreditVault, providing emergency pause capabilities
/// while maintaining proper access control separation. It enables rapid response to security threats without
/// requiring multi-sig coordination during critical incidents.
//
/// @notice Key Responsibilities:
/// 1) **Emergency Response**: Allows designated emergencyPauser to immediately disable all tracked traders and pools
/// 2) **Ownership Management**: Acts as CreditVault owner, proxying administrative functions with additional safety checks
/// 3) **State Tracking**: Maintains synchronized lists of active traders and pools for atomic emergency operations
/// 4) **Recovery Management**: Provides controlled unpause mechanism that requires owner (multi-sig) approval
//
/// @dev Architecture Pattern:
/// ```
///   Multi-Sig Owner → Sentinel (this) → CreditVault
///                     ↓
///              Emergency Pauser (hot wallet)
/// ```
contract Sentinel is Ownable2Step, ReentrancyGuardTransient {
    /// @notice Configuration data for a tracked trader
    struct Trader {
        address trader; // The trader's address
        address settler; // Address authorized to settle the trader's positions
        address recipient; // Address to receive trader's proceeds
        bool isTrader; // Whether this address is an active trader
        bool isWhitelistTrader; // Whether this trader has whitelist privileges
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    STATE VARIABLES
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Emergency pause state flag
    /// @dev Only the owner can unpause via emergencyUnpause()
    bool public emergencyPaused;

    /// @notice The CreditVault instance under Sentinel's administrative control
    /// @dev Sentinel is set as the owner of this CreditVault during deployment
    CreditVault public immutable creditVault;

    /// @notice Array of addresses authorized to trigger emergency pause operations
    address[] public emergencyPausers;

    /// @notice Array of all trader addresses currently being tracked for emergency operations
    /// @dev MUST be kept in sync with CreditVault's enabled traders
    /// @dev Use addTraders()/removeTraders() to maintain synchronization
    address[] public traders;

    /// @notice Array of all credit pool addresses currently being tracked for emergency operations
    /// @dev MUST be kept in sync with CreditVault's enabled pools
    /// @dev Use addPools()/removePools() to maintain synchronization
    address[] public pools;

    /// @notice Mapping to check if an address is in the traders tracking list
    mapping(address => bool) public isTrader;

    /// @notice Mapping to check if an address is in the pools tracking list
    mapping(address => bool) public isCreditPool;

    /// @notice Mapping to check if an address is authorized as an emergency pauser
    mapping(address => bool) public isPauser;

    /*//////////////////////////////////////////////////////////////////////////
                                        EVENTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Emitted when emergency pause is activated
    /// @param traders The list of trader addresses that were disabled
    /// @param pools The list of pool addresses that were disabled
    event EmergencyPaused(address[] traders, address[] pools);

    /// @notice Emitted when emergency pause is deactivated and normal operations resume
    /// @param traders The list of trader addresses that were re-enabled
    /// @param pools The list of pool addresses that were re-enabled
    event EmergencyUnpaused(address[] traders, address[] pools);

    /// @notice Emitted when emergency pausers are added to the authorized list
    /// @param addedPausers The new pausers being authorized
    event EmergencyPausersAdded(address[] addedPausers);

    /// @notice Emitted when emergency pausers are removed from the authorized list
    /// @param removedPausers The pausers being removed from authorization
    event EmergencyPausersRemoved(address[] removedPausers);

    /// @notice Emitted when traders are added to the emergency tracking list
    /// @param addedTraders The new traders being tracked
    event TradersAdded(address[] addedTraders);

    /// @notice Emitted when traders are removed from the emergency tracking list
    /// @param removedTraders The traders being removed from tracking
    event TradersRemoved(address[] removedTraders);

    /// @notice Emitted when pools are added to the emergency tracking list
    /// @param addedPools The new pools being tracked
    event PoolsAdded(address[] addedPools);

    /// @notice Emitted when pools are removed from the emergency tracking list
    /// @param removedPools The pools being removed from tracking
    event PoolsRemoved(address[] removedPools);

    /*//////////////////////////////////////////////////////////////////////////
                                    CONSTRUCTOR
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Initialize Sentinel with CreditVault
    //
    /// @param _creditVault The CreditVault address that Sentinel will control
    constructor(address _creditVault) {
        require(_creditVault != address(0), ErrorsLib.ZeroAddress());

        creditVault = CreditVault(_creditVault);
    }

    /*//////////////////////////////////////////////////////////////////////////
                              EMERGENCY PAUSE/UNPAUSE
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Immediately disables all tracked traders and pools in response to a security threat
    /// @dev This is the primary emergency response mechanism. It atomically disables all tracked entities
    /// to halt potentially malicious activity while preserving their configuration for later recovery.
    //
    /// @dev Access Control:
    /// - Callable by: Any authorized emergency pauser OR owner (multi-sig)
    /// - Rationale: Allows fast response without multi-sig delay during active attacks
    /// - Supports both automated EOA triggers and manual multi-sig intervention
    //
    /// @dev State Machine:
    /// ```
    ///   Normal Operations  ──emergencyPause()──>  Emergency Paused
    ///         ^                                         |
    ///         └──────────emergencyUnpause()─────────────┘
    ///                    (owner only)
    /// ```
    function emergencyPause() external nonReentrant {
        require(isPauser[msg.sender] || msg.sender == owner(), "Only emergency pauser or owner");
        require(!emergencyPaused, "Already paused");
        require(traders.length > 0 && pools.length > 0, "No traders or pools to pause");

        emergencyPaused = true;

        // Disable all tracked traders
        for (uint256 i = 0; i < traders.length; i++) {
            address trader = traders[i];

            // Disable trader while preserving whitelist status
            creditVault.setTrader(
                trader,
                creditVault.traderToSettler(trader),
                creditVault.traderToRecipient(trader),
                false, // disable trader
                creditVault.whitelistTraders(trader) // preserve original whitelist status
            );
        }

        // Disable all tracked credit pools
        for (uint256 i = 0; i < pools.length; i++) {
            address pool = pools[i];

            // Disable pool
            creditVault.setCreditPool(pool, false);
        }

        emit EmergencyPaused(traders, pools);
    }

    /// @notice Restores all tracked traders and pools to their pre-pause operational state
    /// @dev This function should only be called after the security threat has been resolved and
    /// the system has been verified to be safe for resuming normal operations.
    //
    /// @dev Recovery Workflow:
    /// 1. Emergency detected → emergencyPause() called by hot wallet
    /// 2. Investigation and remediation performed off-chain
    /// 3. Multi-sig reviews and confirms system is safe
    /// 4. Multi-sig calls emergencyUnpause() to restore operations
    function emergencyUnpause() external onlyOwner nonReentrant {
        require(emergencyPaused, "Not paused");
        require(traders.length > 0 && pools.length > 0, "No traders or pools to unpause");

        // Restore all tracked traders
        for (uint256 i = 0; i < traders.length; i++) {
            address trader = traders[i];

            creditVault.setTrader(
                trader,
                creditVault.traderToSettler(trader),
                creditVault.traderToRecipient(trader),
                true, // re-enable trader
                creditVault.whitelistTraders(trader) // restore whitelist status
            );
        }

        // Restore all tracked pools
        for (uint256 i = 0; i < pools.length; i++) {
            address pool = pools[i];

            creditVault.setCreditPool(pool, true);
        }

        emergencyPaused = false;
        emit EmergencyUnpaused(traders, pools);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            VAULT OWNERSHIP MANAGEMENT
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Transfer CreditVault ownership to a new owner address
    //
    /// @dev !!! EXTREME CAUTION REQUIRED - READ CAREFULLY !!!
    //
    /// @dev This function initiates transfer of CreditVault ownership AWAY from Sentinel.
    /// Once completed (via acceptOwnership on the new owner), Sentinel will lose ALL administrative
    /// control over CreditVault, including:
    /// - Emergency pause capabilities will be PERMANENTLY DISABLED
    /// - All proxied admin functions in this contract will become unusable
    /// - Cannot be reversed without cooperation from the new owner
    //
    /// @dev Pre-Transfer Checklist:
    /// [x] Verify newOwner is a secure multi-sig wallet
    /// [x] Confirm multi-sig signers have access and understand their responsibilities
    /// [x] Test newOwner's ability to call acceptOwnership
    /// [x] Ensure newOwner is NOT a contract without proper ownership acceptance logic
    /// [x] Document the transfer in operational procedures
    //
    /// @param newOwner The address that will become the new owner of CreditVault
    function transferVaultOwnership(address newOwner) external onlyOwner nonReentrant {
        require(newOwner != address(0), ErrorsLib.ZeroAddress());
        creditVault.transferOwnership(newOwner);
    }

    /// @notice Accepts pending ownership transfer of CreditVault to this Sentinel
    /// @dev This is used when CreditVault ownership is being transferred TO Sentinel from another owner.
    /// Required by the Ownable2Step pattern to complete ownership transfer.
    function acceptVaultOwnership() external onlyOwner nonReentrant {
        creditVault.acceptOwnership();
    }

    /*//////////////////////////////////////////////////////////////////////////
                                ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Adds addresses to the emergency pauser authorization list
    /// @param _pausers Array of addresses to authorize as emergency pausers
    function addEmergencyPausers(address[] calldata _pausers) external onlyOwner {
        for (uint256 i = 0; i < _pausers.length; ++i) {
            address pauser = _pausers[i];

            require(pauser != address(0), ErrorsLib.ZeroAddress());
            require(!isPauser[pauser], "Pauser already authorized");

            emergencyPausers.push(pauser);
            isPauser[pauser] = true;
        }
        emit EmergencyPausersAdded(_pausers);
    }

    /// @notice Removes addresses from the emergency pauser authorization list
    /// @param _pausers Array of addresses to revoke emergency pauser authorization from
    function removeEmergencyPausers(address[] calldata _pausers) external onlyOwner {
        for (uint256 i = 0; i < _pausers.length; ++i) {
            address pauser = _pausers[i];

            require(isPauser[pauser], "Pauser not authorized");

            // Find and remove from array
            for (uint256 j = 0; j < emergencyPausers.length; j++) {
                if (emergencyPausers[j] == pauser) {
                    emergencyPausers[j] = emergencyPausers[emergencyPausers.length - 1];
                    emergencyPausers.pop();
                    isPauser[pauser] = false;
                    break;
                }
            }
        }
        emit EmergencyPausersRemoved(_pausers);
    }

    // ══════════════════════════════════════════════════════════════════════════
    //                  !!! SYNCHRONIZATION WITH CREDIT VAULT !!!
    // ══════════════════════════════════════════════════════════════════════════
    // Tracking lists (traders/pools) MUST mirror CreditVault's enabled state
    // Unsynchronized lists will cause incomplete pause/unpause coverage
    //
    // CORRECT WORKFLOW:
    //   1. To enable a new trader:
    //      a) Call setTrader(..., enabled=true)    [enables in CreditVault]
    //      b) Call addTraders([trader])            [adds to emergency tracking]
    //
    //   2. To disable an existing trader:
    //      a) Call setTrader(..., enabled=false)   [disables in CreditVault]
    //      b) Call removeTraders([trader])         [removes from emergency tracking]
    //
    // ══════════════════════════════════════════════════════════════════════════

    /// @notice Adds trader addresses to the emergency pause tracking list
    //
    /// @dev Workflow:
    /// 1. First: Call setTrader(trader, settler, recipient, enabled=true, isWhitelist) to enable in CreditVault
    /// 2. Then: Call addTraders([trader]) to add to emergency tracking
    //
    /// @param _traders Array of trader addresses to begin tracking
    function addTraders(address[] calldata _traders) external onlyOwner {
        for (uint256 i = 0; i < _traders.length; ++i) {
            address trader = _traders[i];

            require(trader != address(0), ErrorsLib.ZeroAddress());
            require(!isTrader[trader], "Trader already tracked");

            traders.push(trader);
            isTrader[trader] = true;
        }
        emit TradersAdded(_traders);
    }

    /// @notice Removes trader addresses from the emergency pause tracking list
    //
    /// @dev Workflow:
    /// 1. First: Call setTrader(trader, ..., enabled=false) to disable in CreditVault
    /// 2. Then: Call removeTraders([trader]) to remove from emergency tracking
    //
    /// @param _traders Array of trader addresses to stop tracking
    function removeTraders(address[] calldata _traders) external onlyOwner {
        for (uint256 i = 0; i < _traders.length; ++i) {
            address trader = _traders[i];

            require(isTrader[trader], "Trader not tracked");

            // Find and remove from array
            for (uint256 j = 0; j < traders.length; j++) {
                if (traders[j] == trader) {
                    traders[j] = traders[traders.length - 1];
                    traders.pop();
                    isTrader[trader] = false;
                    break;
                }
            }
        }
        emit TradersRemoved(_traders);
    }

    /// @notice Adds credit pool addresses to the emergency pause tracking list
    //
    /// @dev Workflow:
    /// 1. First: Call setCreditPool(pool, enabled=true) to enable in CreditVault
    /// 2. Then: Call addPools([pool]) to add to emergency tracking
    //
    /// @param _pools Array of pool addresses to begin tracking
    function addPools(address[] calldata _pools) external onlyOwner {
        for (uint256 i = 0; i < _pools.length; ++i) {
            address pool = _pools[i];

            require(pool != address(0), ErrorsLib.ZeroAddress());
            require(!isCreditPool[pool], "Pool already tracked");

            pools.push(pool);
            isCreditPool[pool] = true;
        }
        emit PoolsAdded(_pools);
    }

    /// @notice Removes credit pool addresses from the emergency pause tracking list
    //
    /// @dev Workflow:
    /// 1. First: Call setCreditPool(pool, enabled=false) to disable in CreditVault
    /// 2. Then: Call removePools([pool]) to remove from emergency tracking
    //
    /// @param _pools Array of pool addresses to stop tracking
    function removePools(address[] calldata _pools) external onlyOwner {
        for (uint256 i = 0; i < _pools.length; ++i) {
            address pool = _pools[i];

            require(isCreditPool[pool], "Pool not tracked");

            // Find and remove from array
            for (uint256 j = 0; j < pools.length; j++) {
                if (pools[j] == pool) {
                    pools[j] = pools[pools.length - 1];
                    pools.pop();
                    isCreditPool[pool] = false;
                    break;
                }
            }
        }
        emit PoolsRemoved(_pools);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            MIRROR CREDIT VAULT OWNER FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/
    //
    // The functions below are direct proxies to CreditVault owner functions.
    // They enable the multi-sig owner to manage CreditVault through Sentinel's
    // additional security layer (non-reentrancy, ownership validation).
    //
    // All functions are onlyOwner and nonReentrant for enhanced security.
    //
    /*//////////////////////////////////////////////////////////////////////////*/

    /// @notice Adds support for a new LP token market in CreditVault
    //
    /// @dev Directly mirrors CreditVault.supportMarket()
    /// @dev After calling this, consider calling addPools() if the market includes credit pools
    //
    /// @param lpToken The NativeLPToken contract representing the new market
    function supportMarket(NativeLPToken lpToken) external onlyOwner nonReentrant {
        creditVault.supportMarket(lpToken);
    }

    /// @notice Enables or disables a credit pool in CreditVault
    //
    /// @dev Directly mirrors CreditVault.setCreditPool()
    /// @dev IMPORTANT: REMEMBER TO SYNC - After calling this, update Sentinel's tracking lists:
    /// - If enabled=true: call addPools([pool])
    /// - If enabled=false: call removePools([pool])
    //
    /// @param pool The address of the credit pool
    /// @param enabled True to enable, false to disable
    function setCreditPool(address pool, bool enabled) external onlyOwner nonReentrant {
        creditVault.setCreditPool(pool, enabled);
    }

    /// @notice Configures token allowances for a credit pool
    //
    /// @dev Directly mirrors CreditVault.setAllowance()
    /// @dev Allows the pool to spend CreditVault's tokens up to specified amounts
    //
    /// @param tokens Array of token addresses and amounts to approve
    /// @param pool The pool address to grant allowances to
    function setAllowance(
        ICreditVault.TokenAmountUint[] calldata tokens,
        address pool
    ) external onlyOwner nonReentrant {
        creditVault.setAllowance(tokens, pool);
    }

    /// @notice Sets the rebalancing cap for an operator on a specific token
    //
    /// @dev Directly mirrors CreditVault.setRebalanceCap()
    /// @dev Used to limit exposure in case of operator compromise
    //
    /// @param operator The address authorized to perform rebalancing
    /// @param token The token for which to set the cap
    /// @param limit The maximum amount the operator can rebalance
    function setRebalanceCap(address operator, address token, uint256 limit) external onlyOwner nonReentrant {
        creditVault.setRebalanceCap(operator, token, limit);
    }

    /// @notice Configures trader permissions and settings in CreditVault
    //
    /// @dev Directly mirrors CreditVault.setTrader()
    /// @dev IMPORTANT: REMEMBER TO SYNC - After calling this, update Sentinel's tracking lists:
    /// - If enabled=true: call addTraders([trader])
    /// - If enabled=false: call removeTraders([trader])
    //
    /// @param trader The trader's address
    /// @param settler The address authorized to settle the trader's positions
    /// @param recipient The address to receive the trader's proceeds
    /// @param enabled Whether to enable (true) or disable (false) the trader
    /// @param isWhitelistTrader Whether the trader has whitelist privileges
    function setTrader(
        address trader,
        address settler,
        address recipient,
        bool enabled,
        bool isWhitelistTrader
    ) external onlyOwner nonReentrant {
        creditVault.setTrader(trader, settler, recipient, enabled, isWhitelistTrader);
    }

    /// @notice Configures liquidator permissions in CreditVault
    //
    /// @dev Directly mirrors CreditVault.setLiquidator()
    /// @dev Liquidators can forcibly close undercollateralized positions
    //
    /// @param liquidator The liquidator's address
    /// @param recipient The address to receive liquidation proceeds
    /// @param status True to authorize, false to revoke authorization
    function setLiquidator(address liquidator, address recipient, bool status) external onlyOwner nonReentrant {
        creditVault.setLiquidator(liquidator, recipient, status);
    }

    /// @notice Updates the authorized signer address for CreditVault operations
    //
    /// @dev Directly mirrors CreditVault.setSigner()
    /// @dev The signer is used to validate off-chain signed messages for certain operations
    //
    /// @param _signer The new signer address
    function setSigner(address _signer) external onlyOwner nonReentrant {
        creditVault.setSigner(_signer);
    }

    /// @notice Updates the epoch updater address
    //
    /// @dev Directly mirrors CreditVault.setEpochUpdater()
    /// @dev The epoch updater is authorized to advance time-based epochs in the system
    //
    /// @param _epochUpdater The new epoch updater address
    function setEpochUpdater(address _epochUpdater) external onlyOwner nonReentrant {
        creditVault.setEpochUpdater(_epochUpdater);
    }

    /// @notice Updates the fee withdrawer address
    //
    /// @dev Directly mirrors CreditVault.setFeeWithdrawer()
    /// @dev The fee withdrawer can collect accumulated protocol fees from CreditVault
    //
    /// @param _feeWithdrawer The new fee withdrawer address (must be payable)
    function setFeeWithdrawer(address payable _feeWithdrawer) external onlyOwner nonReentrant {
        creditVault.setFeeWithdrawer(_feeWithdrawer);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Returns all tracked trader addresses
    /// @return Array of all trader addresses currently being tracked for emergency operations
    function getTraders() external view returns (address[] memory) {
        return traders;
    }

    /// @notice Returns all tracked pool addresses
    /// @return Array of all pool addresses currently being tracked for emergency operations
    function getPools() external view returns (address[] memory) {
        return pools;
    }

    /// @notice Returns all authorized emergency pauser addresses
    /// @return Array of all addresses authorized to trigger emergency pause operations
    function getEmergencyPausers() external view returns (address[] memory) {
        return emergencyPausers;
    }
}
