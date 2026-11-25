// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "../../../src/libraries/ConstantsLib.sol";
import {ErrorsLib} from "../../../src/libraries/ErrorsLib.sol";

import {ICreditVault} from "../../../src/interfaces/ICreditVault.sol";
import {MockERC20} from "../../../src/test/MockERC20.sol";
import {NativeLPToken} from "../../../src/NativeLPToken.sol";
import {Sentinel} from "../../../src/periphery/Sentinel.sol";
import {BaseTest} from "../../BaseTest.t.sol";

import {console2} from "forge-std/console2.sol";
import {SignatureUtils} from "../../helpers/SignatureUtils.sol";

contract SentinelTest is BaseTest {
    Sentinel public sentinel;
    address public emergencyPauser;

    function setUp() public override {
        super.setUp();

        // Create emergency pauser address
        emergencyPauser = makeAddr("emergencyPauser");

        // Deploy Sentinel with CreditVault
        vm.startPrank(deployer);
        sentinel = new Sentinel(address(creditVault));

        // Transfer CreditVault ownership to Sentinel
        creditVault.transferOwnership(address(sentinel));
        vm.stopPrank();

        // Accept ownership through Sentinel
        vm.prank(deployer);
        sentinel.acceptVaultOwnership();

        // Add emergency pauser
        address[] memory pausers = new address[](1);
        pausers[0] = emergencyPauser;
        vm.prank(deployer);
        sentinel.addEmergencyPausers(pausers);
    }

    /*//////////////////////////////////////////////////////////////////////////
                    CRITICAL: OWNERSHIP TRANSFER TESTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Test complete ownership transfer and re-transfer lifecycle
    /// @dev This is THE MOST CRITICAL test - ownership must NEVER be locked
    function testOwnershipTransferLifecycle() public {
        // Scenario 1: Initial state - Sentinel owns CreditVault
        assertEq(creditVault.owner(), address(sentinel), "Sentinel should be current owner");
        assertEq(creditVault.pendingOwner(), address(0), "No pending owner initially");

        // Scenario 2: Transfer ownership to a new address (simulating upgrade/migration)
        address newOwner = makeAddr("newOwner");

        vm.prank(deployer);
        sentinel.transferVaultOwnership(newOwner);

        // Verify transfer initiated but not completed
        assertEq(creditVault.owner(), address(sentinel), "Sentinel still owner before acceptance");
        assertEq(creditVault.pendingOwner(), newOwner, "NewOwner should be pending");

        // Scenario 3: New owner accepts ownership
        vm.prank(newOwner);
        creditVault.acceptOwnership();

        // Verify ownership fully transferred
        assertEq(creditVault.owner(), newOwner, "NewOwner should be new owner");
        assertEq(creditVault.pendingOwner(), address(0), "No pending owner after acceptance");

        // Scenario 4: New owner can transfer back to Sentinel (or another address)
        vm.prank(newOwner);
        creditVault.transferOwnership(address(sentinel));

        assertEq(creditVault.owner(), newOwner, "NewOwner still owner before acceptance");
        assertEq(creditVault.pendingOwner(), address(sentinel), "Sentinel should be pending");

        // Scenario 5: Sentinel accepts ownership back
        vm.prank(deployer);
        sentinel.acceptVaultOwnership();

        // Verify ownership returned to Sentinel
        assertEq(creditVault.owner(), address(sentinel), "Sentinel should be owner again");
        assertEq(creditVault.pendingOwner(), address(0), "No pending owner");

        // Scenario 6: Transfer to yet another address to prove repeatability
        address thirdOwner = makeAddr("thirdOwner");

        vm.prank(deployer);
        sentinel.transferVaultOwnership(thirdOwner);

        vm.prank(thirdOwner);
        creditVault.acceptOwnership();

        assertEq(creditVault.owner(), thirdOwner, "ThirdOwner should be owner");
        assertEq(creditVault.pendingOwner(), address(0), "No pending owner");
    }

    /// @notice Test that pending ownership can be overwritten before acceptance
    /// @dev Critical: if first transfer is to wrong address, we can fix it
    function testOwnershipTransferCanBeOverwritten() public {
        // Transfer to wrong address
        address wrongOwner = makeAddr("wrongOwner");

        vm.prank(deployer);
        sentinel.transferVaultOwnership(wrongOwner);

        assertEq(creditVault.pendingOwner(), wrongOwner, "WrongOwner should be pending");

        // Correct the mistake by transferring to correct address
        address correctOwner = makeAddr("correctOwner");

        vm.prank(deployer);
        sentinel.transferVaultOwnership(correctOwner);

        assertEq(creditVault.pendingOwner(), correctOwner, "CorrectOwner should be pending");
        assertEq(creditVault.owner(), address(sentinel), "Sentinel still owner");

        // Wrong owner cannot accept anymore
        vm.prank(wrongOwner);
        vm.expectRevert();
        creditVault.acceptOwnership();

        // Correct owner can accept
        vm.prank(correctOwner);
        creditVault.acceptOwnership();

        assertEq(creditVault.owner(), correctOwner, "CorrectOwner should be owner");
    }

    /// @notice Test ownership transfer access control
    /// @dev Only Sentinel owner can initiate transfer
    function testOwnershipTransferAccessControl() public {
        address attacker = makeAddr("attacker");
        address newOwner = makeAddr("newOwner");

        // Non-owner cannot transfer
        vm.prank(attacker);
        vm.expectRevert();
        sentinel.transferVaultOwnership(newOwner);

        // Ownership unchanged
        assertEq(creditVault.owner(), address(sentinel), "Sentinel still owner");
        assertEq(creditVault.pendingOwner(), address(0), "No pending owner");
    }

    /// @notice Test accept ownership access control
    /// @dev Only Sentinel owner can accept on behalf of Sentinel
    function testAcceptOwnershipAccessControl() public {
        // Setup: Transfer ownership from external owner back to Sentinel
        address externalOwner = makeAddr("externalOwner");

        // First transfer to external owner
        vm.prank(deployer);
        sentinel.transferVaultOwnership(externalOwner);

        vm.prank(externalOwner);
        creditVault.acceptOwnership();

        // Now transfer back to Sentinel
        vm.prank(externalOwner);
        creditVault.transferOwnership(address(sentinel));

        assertEq(creditVault.pendingOwner(), address(sentinel), "Sentinel should be pending");

        // Non-owner cannot accept on behalf of Sentinel
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert();
        sentinel.acceptVaultOwnership();

        // Only Sentinel owner can accept
        vm.prank(deployer);
        sentinel.acceptVaultOwnership();

        assertEq(creditVault.owner(), address(sentinel), "Sentinel should be owner");
    }

    /// @notice Test that ownership transfer works even during emergency pause
    /// @dev CRITICAL: Must be able to transfer ownership to fix bugs even in emergency
    function testOwnershipTransferWorksWhenEmergencyPaused() public {
        // Setup: Add a trader to track
        address testTrader = makeAddr("emergencyTestTrader");
        address testRecipient = makeAddr("emergencyTestRecipient");

        vm.prank(deployer);
        sentinel.setTrader(testTrader, testTrader, testRecipient, true, true);

        address[] memory tradersToAdd = new address[](1);
        tradersToAdd[0] = testTrader;

        vm.prank(deployer);
        sentinel.addTraders(tradersToAdd);

        // Setup pool for emergency pause requirement
        _setupTestPool();

        // Trigger emergency pause
        vm.prank(emergencyPauser);
        sentinel.emergencyPause();

        assertTrue(sentinel.emergencyPaused(), "Sentinel should be emergency paused");
        assertFalse(creditVault.traders(testTrader), "Traders should be disabled");

        // Should still be able to transfer ownership during emergency
        address newOwner = makeAddr("newOwner");

        vm.prank(deployer);
        sentinel.transferVaultOwnership(newOwner);

        assertEq(creditVault.pendingOwner(), newOwner, "Transfer should work during emergency");

        // Should be able to accept even during emergency
        vm.prank(newOwner);
        creditVault.acceptOwnership();

        assertEq(creditVault.owner(), newOwner, "Acceptance should work during emergency");
        assertTrue(sentinel.emergencyPaused(), "Emergency state persists after ownership transfer");

        // Transfer ownership back to Sentinel
        vm.prank(newOwner);
        creditVault.transferOwnership(address(sentinel));

        vm.prank(deployer);
        sentinel.acceptVaultOwnership();

        assertEq(creditVault.owner(), address(sentinel), "Sentinel should be owner again");

        // Unpause and verify everything returns to normal
        vm.prank(deployer);
        sentinel.emergencyUnpause();

        assertFalse(sentinel.emergencyPaused(), "Sentinel should be unpaused");
        assertTrue(creditVault.traders(testTrader), "Traders should be re-enabled");

        // Verify trader can still operate normally after full cycle
        vm.prank(deployer);
        sentinel.setCreditPool(address(rfqPool), true);

        vm.prank(address(rfqPool));
        creditVault.swapCallback(testTrader, address(USDC), 1000e6, address(weth), 1 ether);

        assertEq(creditVault.positions(testTrader, address(USDC)), 1000e6, "Trader position should be created");
    }

    /// @notice Test ownership transfer to zero address is prevented
    /// @dev Prevent accidental lock of ownership
    function testOwnershipTransferToZeroAddressPrevented() public {
        vm.prank(deployer);
        vm.expectRevert();
        sentinel.transferVaultOwnership(address(0));

        // Ownership unchanged
        assertEq(creditVault.owner(), address(sentinel), "Sentinel still owner");
    }

    /// @notice Test rapid ownership transfers
    /// @dev Ensure no race conditions or state corruption
    function testRapidOwnershipTransfers() public {
        address owner1 = makeAddr("owner1");
        address owner2 = makeAddr("owner2");
        address owner3 = makeAddr("owner3");

        // Transfer 1
        vm.prank(deployer);
        sentinel.transferVaultOwnership(owner1);

        vm.prank(owner1);
        creditVault.acceptOwnership();

        // Transfer 2
        vm.prank(owner1);
        creditVault.transferOwnership(owner2);

        vm.prank(owner2);
        creditVault.acceptOwnership();

        // Transfer 3
        vm.prank(owner2);
        creditVault.transferOwnership(owner3);

        vm.prank(owner3);
        creditVault.acceptOwnership();

        // Transfer back to Sentinel
        vm.prank(owner3);
        creditVault.transferOwnership(address(sentinel));

        vm.prank(deployer);
        sentinel.acceptVaultOwnership();

        // Verify final state is clean
        assertEq(creditVault.owner(), address(sentinel), "Sentinel should be final owner");
        assertEq(creditVault.pendingOwner(), address(0), "No pending owner");
    }

    /// @notice Test ownership transfer during active operations
    /// @dev Ownership transfer should not interfere with ongoing operations
    function testOwnershipTransferDuringOperations() public {
        // Setup: Create active positions
        address testTrader = makeAddr("operationsTestTrader");
        address testRecipient = makeAddr("operationsTestRecipient");

        vm.prank(deployer);
        sentinel.setTrader(testTrader, testTrader, testRecipient, true, true);

        vm.prank(deployer);
        sentinel.setCreditPool(address(rfqPool), true);

        // Create position
        vm.prank(address(rfqPool));
        creditVault.swapCallback(testTrader, address(USDC), 1000e6, address(weth), 1 ether);

        int256 positionBefore = creditVault.positions(testTrader, address(USDC));

        // Transfer ownership while position exists
        address newOwner = makeAddr("newOwner");

        vm.prank(deployer);
        sentinel.transferVaultOwnership(newOwner);

        vm.prank(newOwner);
        creditVault.acceptOwnership();

        // Verify positions are not affected
        assertEq(creditVault.positions(testTrader, address(USDC)), positionBefore, "Position unchanged");

        // Verify new owner can manage the vault
        address anotherTrader = makeAddr("anotherTrader");
        address anotherRecipient = makeAddr("anotherRecipient");

        vm.prank(newOwner);
        creditVault.setTrader(anotherTrader, anotherTrader, anotherRecipient, true, true);

        assertTrue(creditVault.traders(anotherTrader), "New owner can set traders");
    }

    /*//////////////////////////////////////////////////////////////////////////
                        CRITICAL: EMERGENCY MANAGEMENT TESTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Test emergency pause functionality - can pause all traders and pools
    /// @dev This is Sentinel's core business function
    function testEmergencyPauseByPauser() public {
        // Setup: Create and enable traders and pools
        address trader1 = makeAddr("emergencyTrader1");
        address trader2 = makeAddr("emergencyTrader2");
        address recipient1 = makeAddr("emergencyRecipient1");
        address recipient2 = makeAddr("emergencyRecipient2");
        address pool1 = makeAddr("emergencyPool1");
        address pool2 = makeAddr("emergencyPool2");

        // Enable traders
        vm.prank(deployer);
        sentinel.setTrader(trader1, trader1, recipient1, true, false);

        vm.prank(deployer);
        sentinel.setTrader(trader2, trader2, recipient2, true, true); // whitelist trader

        // Enable pools
        vm.prank(deployer);
        sentinel.setCreditPool(pool1, true);

        vm.prank(deployer);
        sentinel.setCreditPool(pool2, true);

        // Add to tracking
        address[] memory traders = new address[](2);
        traders[0] = trader1;
        traders[1] = trader2;

        address[] memory pools = new address[](2);
        pools[0] = pool1;
        pools[1] = pool2;

        vm.prank(deployer);
        sentinel.addTraders(traders);

        vm.prank(deployer);
        sentinel.addPools(pools);

        // Verify all enabled before pause
        assertTrue(creditVault.traders(trader1), "Trader1 should be enabled");
        assertTrue(creditVault.traders(trader2), "Trader2 should be enabled");
        assertTrue(creditVault.whitelistTraders(trader2), "Trader2 should be whitelisted");
        assertTrue(creditVault.creditPools(pool1), "Pool1 should be enabled");
        assertTrue(creditVault.creditPools(pool2), "Pool2 should be enabled");

        // Execute emergency pause by emergency pauser
        vm.prank(emergencyPauser);
        sentinel.emergencyPause();

        // Verify emergency state
        assertTrue(sentinel.emergencyPaused(), "Sentinel should be in emergency state");

        // Verify all traders disabled
        assertFalse(creditVault.traders(trader1), "Trader1 should be disabled");
        assertFalse(creditVault.traders(trader2), "Trader2 should be disabled");

        // Verify whitelist status preserved
        assertTrue(creditVault.whitelistTraders(trader2), "Trader2 whitelist should be preserved");
        assertFalse(creditVault.whitelistTraders(trader1), "Trader1 should not be whitelisted");

        // Verify all pools disabled
        assertFalse(creditVault.creditPools(pool1), "Pool1 should be disabled");
        assertFalse(creditVault.creditPools(pool2), "Pool2 should be disabled");
    }

    /// @notice Test that owner can also trigger emergency pause
    function testEmergencyPauseByOwner() public {
        // Setup trader
        address trader = makeAddr("pauseTestTrader");
        address recipient = makeAddr("pauseTestRecipient");
        vm.prank(deployer);
        sentinel.setTrader(trader, trader, recipient, true, false);

        address[] memory traders = new address[](1);
        traders[0] = trader;

        vm.prank(deployer);
        sentinel.addTraders(traders);

        // Setup pool for emergency pause requirement
        _setupTestPool();

        // Owner can pause
        vm.prank(deployer);
        sentinel.emergencyPause();

        assertTrue(sentinel.emergencyPaused(), "Sentinel should be paused");
        assertFalse(creditVault.traders(trader), "Trader should be disabled");
    }

    /// @notice Test emergency pause access control
    function testEmergencyPauseAccessControl() public {
        address attacker = makeAddr("attacker");

        // Non-authorized address cannot pause
        vm.prank(attacker);
        vm.expectRevert(bytes("Only emergency pauser or owner"));
        sentinel.emergencyPause();

        assertFalse(sentinel.emergencyPaused(), "Should not be paused");
    }

    /// @notice Test cannot pause when already paused
    function testEmergencyPauseAlreadyPaused() public {
        // Setup trader first
        address trader = makeAddr("alreadyPausedTrader");
        address recipient = makeAddr("alreadyPausedRecipient");

        vm.prank(deployer);
        sentinel.setTrader(trader, trader, recipient, true, false);

        address[] memory traders = new address[](1);
        traders[0] = trader;

        vm.prank(deployer);
        sentinel.addTraders(traders);

        // Setup pool for emergency pause requirement
        _setupTestPool();

        // First pause
        vm.prank(emergencyPauser);
        sentinel.emergencyPause();

        assertTrue(sentinel.emergencyPaused(), "Should be paused");

        // Try to pause again
        vm.prank(emergencyPauser);
        vm.expectRevert(bytes("Already paused"));
        sentinel.emergencyPause();
    }

    /// @notice Test emergency unpause functionality - restores all traders and pools
    function testEmergencyUnpauseSuccess() public {
        // Setup and pause first
        address trader1 = makeAddr("unpauseTrader1");
        address trader2 = makeAddr("unpauseTrader2");
        address recipient1 = makeAddr("unpauseRecipient1");
        address recipient2 = makeAddr("unpauseRecipient2");
        address pool1 = makeAddr("unpausePool1");

        vm.prank(deployer);
        sentinel.setTrader(trader1, trader1, recipient1, true, false);

        vm.prank(deployer);
        sentinel.setTrader(trader2, trader2, recipient2, true, true); // whitelist

        vm.prank(deployer);
        sentinel.setCreditPool(pool1, true);

        address[] memory traders = new address[](2);
        traders[0] = trader1;
        traders[1] = trader2;

        address[] memory pools = new address[](1);
        pools[0] = pool1;

        vm.prank(deployer);
        sentinel.addTraders(traders);

        vm.prank(deployer);
        sentinel.addPools(pools);

        // Pause
        vm.prank(emergencyPauser);
        sentinel.emergencyPause();

        assertTrue(sentinel.emergencyPaused(), "Should be paused");
        assertFalse(creditVault.traders(trader1), "Trader1 should be disabled");
        assertFalse(creditVault.traders(trader2), "Trader2 should be disabled");
        assertFalse(creditVault.creditPools(pool1), "Pool should be disabled");

        // Unpause (only owner can unpause)
        vm.prank(deployer);
        sentinel.emergencyUnpause();

        // Verify emergency state cleared
        assertFalse(sentinel.emergencyPaused(), "Should not be paused");

        // Verify all traders restored
        assertTrue(creditVault.traders(trader1), "Trader1 should be re-enabled");
        assertTrue(creditVault.traders(trader2), "Trader2 should be re-enabled");

        // Verify whitelist status preserved
        assertFalse(creditVault.whitelistTraders(trader1), "Trader1 should not be whitelisted");
        assertTrue(creditVault.whitelistTraders(trader2), "Trader2 whitelist should be preserved");

        // Verify pool restored
        assertTrue(creditVault.creditPools(pool1), "Pool should be re-enabled");
    }

    /// @notice Test emergency unpause access control - only owner
    function testEmergencyUnpauseAccessControl() public {
        // Setup trader first
        address trader = makeAddr("unpauseAccessTrader");
        address recipient = makeAddr("unpauseAccessRecipient");

        vm.prank(deployer);
        sentinel.setTrader(trader, trader, recipient, true, false);

        address[] memory traders = new address[](1);
        traders[0] = trader;

        vm.prank(deployer);
        sentinel.addTraders(traders);

        // Setup pool for emergency pause requirement
        _setupTestPool();

        // Setup and pause
        vm.prank(emergencyPauser);
        sentinel.emergencyPause();

        assertTrue(sentinel.emergencyPaused(), "Should be paused");

        // Emergency pauser cannot unpause (only owner can)
        vm.prank(emergencyPauser);
        vm.expectRevert();
        sentinel.emergencyUnpause();

        // Attacker cannot unpause
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert();
        sentinel.emergencyUnpause();

        // Still paused
        assertTrue(sentinel.emergencyPaused(), "Should still be paused");

        // Only owner can unpause
        vm.prank(deployer);
        sentinel.emergencyUnpause();

        assertFalse(sentinel.emergencyPaused(), "Should be unpaused");
    }

    /// @notice Test cannot unpause when not paused
    function testEmergencyUnpauseNotPaused() public {
        assertFalse(sentinel.emergencyPaused(), "Should not be paused initially");

        vm.prank(deployer);
        vm.expectRevert(bytes("Not paused"));
        sentinel.emergencyUnpause();
    }

    /// @notice Test emergency pause with empty tracking lists should revert
    function testEmergencyPauseWithEmptyListsRevert() public {
        // No traders or pools added to tracking

        // Should revert with empty lists to prevent misconfiguration
        vm.prank(emergencyPauser);
        vm.expectRevert(bytes("No traders or pools to pause"));
        sentinel.emergencyPause();

        assertFalse(sentinel.emergencyPaused(), "Should not be paused");
    }

    /// @notice Test emergency unpause with empty tracking lists should revert
    function testEmergencyUnpauseWithEmptyListsRevert() public {
        // Setup: Create a trader and pool, then pause
        address trader = makeAddr("emptyListTrader");
        address recipient = makeAddr("emptyListRecipient");

        vm.prank(deployer);
        sentinel.setTrader(trader, trader, recipient, true, false);

        address[] memory traders = new address[](1);
        traders[0] = trader;

        vm.prank(deployer);
        sentinel.addTraders(traders);

        // Setup pool for emergency pause requirement
        _setupTestPool();

        // Pause
        vm.prank(emergencyPauser);
        sentinel.emergencyPause();

        assertTrue(sentinel.emergencyPaused(), "Should be paused");

        // Remove all traders from tracking
        vm.prank(deployer);
        sentinel.removeTraders(traders);

        // Now unpause should revert because traders list is empty (even though pools exist)
        vm.prank(deployer);
        vm.expectRevert(bytes("No traders or pools to unpause"));
        sentinel.emergencyUnpause();
    }

    /// @notice Test addEmergencyPausers and removeEmergencyPausers functionality
    function testAddRemoveEmergencyPausersSuccess() public {
        // Setup trader first
        address trader = makeAddr("pauserTestTrader");
        address recipient = makeAddr("pauserTestRecipient");

        vm.prank(deployer);
        sentinel.setTrader(trader, trader, recipient, true, false);

        address[] memory traders = new address[](1);
        traders[0] = trader;

        vm.prank(deployer);
        sentinel.addTraders(traders);

        // Setup pool for emergency pause requirement
        _setupTestPool();

        address newPauser = makeAddr("newEmergencyPauser");

        // Add new emergency pauser
        address[] memory newPausers = new address[](1);
        newPausers[0] = newPauser;

        vm.prank(deployer);
        sentinel.addEmergencyPausers(newPausers);

        // Verify new pauser is set
        assertTrue(sentinel.isPauser(newPauser), "New pauser should be authorized");

        // New pauser can trigger pause
        vm.prank(newPauser);
        sentinel.emergencyPause();

        assertTrue(sentinel.emergencyPaused(), "New pauser should be able to pause");

        // Unpause first
        vm.prank(deployer);
        sentinel.emergencyUnpause();

        // Remove old pauser
        address[] memory oldPausers = new address[](1);
        oldPausers[0] = emergencyPauser;

        vm.prank(deployer);
        sentinel.removeEmergencyPausers(oldPausers);

        // Old pauser cannot pause anymore
        vm.prank(emergencyPauser);
        vm.expectRevert(bytes("Only emergency pauser or owner"));
        sentinel.emergencyPause();

        // Verify old pauser is removed
        assertFalse(sentinel.isPauser(emergencyPauser), "Old pauser should be removed");
    }

    /// @notice Test addEmergencyPausers access control
    function testAddEmergencyPausersAccessControl() public {
        address attacker = makeAddr("attacker");
        address newPauser = makeAddr("newPauser");

        address[] memory pausers = new address[](1);
        pausers[0] = newPauser;

        // Non-owner cannot add emergency pauser
        vm.prank(attacker);
        vm.expectRevert();
        sentinel.addEmergencyPausers(pausers);

        // Verify pauser not added
        assertFalse(sentinel.isPauser(newPauser), "Pauser should not be added");
    }

    /// @notice Test cannot add zero address as emergency pauser
    function testAddEmergencyPausersZeroAddress() public {
        address[] memory pausers = new address[](1);
        pausers[0] = address(0);

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        sentinel.addEmergencyPausers(pausers);
    }

    /// @notice Test multiple pause/unpause cycles
    function testMultiplePauseUnpauseCycles() public {
        // Setup trader
        address trader = makeAddr("cycleTrader");
        address recipient = makeAddr("cycleRecipient");
        vm.prank(deployer);
        sentinel.setTrader(trader, trader, recipient, true, true);

        address[] memory traders = new address[](1);
        traders[0] = trader;
        vm.prank(deployer);
        sentinel.addTraders(traders);

        // Setup pool for emergency pause requirement
        _setupTestPool();

        // Cycle 3 times
        for (uint256 i = 0; i < 3; i++) {
            // Pause
            vm.prank(emergencyPauser);
            sentinel.emergencyPause();

            assertTrue(sentinel.emergencyPaused(), "Should be paused in cycle");
            assertFalse(creditVault.traders(trader), "Trader should be disabled in cycle");
            assertTrue(creditVault.whitelistTraders(trader), "Whitelist should be preserved in cycle");

            // Unpause
            vm.prank(deployer);
            sentinel.emergencyUnpause();

            assertFalse(sentinel.emergencyPaused(), "Should be unpaused in cycle");
            assertTrue(creditVault.traders(trader), "Trader should be re-enabled in cycle");
            assertTrue(creditVault.whitelistTraders(trader), "Whitelist should still be preserved in cycle");
        }
    }

    /// @notice Test emergency pause/unpause with non-synchronized trader tracking
    /// @dev CRITICAL: This test demonstrates TWO trader synchronization issues:
    ///      Issue 1: Disabled trader NOT removed from tracking -> gets RE-ENABLED on unpause
    ///      Issue 2: Enabled trader NOT added to tracking -> does NOT get disabled on pause
    ///      Proper workflows:
    ///        - Enable trader -> add to tracking list
    ///        - Disable trader -> remove from tracking list
    function testEmergencyPauseUnpauseWithNonSyncTraderTracking() public {
        // Scenario 1: Traders that ARE properly tracked
        address trackedRegularTrader = makeAddr("trackedRegularTrader");
        address trackedRegularRecipient = makeAddr("trackedRegularRecipient");

        address trackedWhitelistTrader = makeAddr("trackedWhitelistTrader");
        address trackedWhitelistRecipient = makeAddr("trackedWhitelistRecipient");

        // Scenario 2: Trader disabled but FORGOT to remove from tracking (sync issue #1)
        address disabledButTrackedTrader = makeAddr("disabledButTrackedTrader");
        address disabledButTrackedRecipient = makeAddr("disabledButTrackedRecipient");

        // Scenario 3: Trader enabled but FORGOT to add to tracking (sync issue #2)
        address enabledButNotTrackedTrader = makeAddr("enabledButNotTrackedTrader");
        address enabledButNotTrackedRecipient = makeAddr("enabledButNotTrackedRecipient");

        // Setup: Enable properly tracked traders
        vm.prank(deployer);
        sentinel.setTrader(trackedRegularTrader, trackedRegularTrader, trackedRegularRecipient, true, false);

        vm.prank(deployer);
        sentinel.setTrader(trackedWhitelistTrader, trackedWhitelistTrader, trackedWhitelistRecipient, true, true);

        // Setup: Enable trader that will be disabled but stay in tracking (simulates operator error)
        vm.prank(deployer);
        sentinel.setTrader(disabledButTrackedTrader, disabledButTrackedTrader, disabledButTrackedRecipient, true, false);

        // Setup: Enable trader but don't add to tracking (simulates operator error)
        vm.prank(deployer);
        sentinel.setTrader(
            enabledButNotTrackedTrader, enabledButNotTrackedTrader, enabledButNotTrackedRecipient, true, false
        );

        // Setup pool for emergency pause requirement
        _setupTestPool();

        // Add only some traders to tracking (forgetting enabledButNotTrackedTrader)
        address[] memory traders = new address[](3);
        traders[0] = trackedRegularTrader;
        traders[1] = trackedWhitelistTrader;
        traders[2] = disabledButTrackedTrader;

        vm.prank(deployer);
        sentinel.addTraders(traders);

        // Disable one trader but FORGET to remove from tracking (sync issue #1)
        vm.prank(deployer);
        sentinel.setTrader(
            disabledButTrackedTrader, disabledButTrackedTrader, disabledButTrackedRecipient, false, false
        );

        // Verify state before pause
        assertTrue(creditVault.traders(trackedRegularTrader), "Tracked regular trader should be enabled");
        assertTrue(creditVault.traders(trackedWhitelistTrader), "Tracked whitelist trader should be enabled");
        assertFalse(creditVault.traders(disabledButTrackedTrader), "Disabled trader should be disabled");
        assertTrue(creditVault.traders(enabledButNotTrackedTrader), "Enabled but not tracked trader should be enabled");

        // Execute emergency pause
        vm.prank(emergencyPauser);
        sentinel.emergencyPause();

        // Verify pause effects
        assertFalse(creditVault.traders(trackedRegularTrader), "Tracked regular trader should be disabled");
        assertFalse(creditVault.traders(trackedWhitelistTrader), "Tracked whitelist trader should be disabled");
        assertFalse(creditVault.traders(disabledButTrackedTrader), "Already disabled trader should remain disabled");

        // ⚠️ SYNC ISSUE #2: Enabled trader not in tracking list does NOT get paused!
        assertTrue(creditVault.traders(enabledButNotTrackedTrader), "Not tracked trader remains enabled (sync issue!)");

        // Verify whitelist status preserved during pause
        assertFalse(creditVault.whitelistTraders(trackedRegularTrader), "Regular trader should not be whitelisted");
        assertTrue(creditVault.whitelistTraders(trackedWhitelistTrader), "Whitelist should be preserved");

        // Execute emergency unpause
        vm.prank(deployer);
        sentinel.emergencyUnpause();

        // Verify unpause effects
        assertTrue(creditVault.traders(trackedRegularTrader), "Tracked regular trader should be re-enabled");
        assertTrue(creditVault.traders(trackedWhitelistTrader), "Tracked whitelist trader should be re-enabled");

        // ⚠️ SYNC ISSUE #1: Previously disabled trader gets RE-ENABLED because it's in tracking!
        assertTrue(creditVault.traders(disabledButTrackedTrader), "Disabled trader gets RE-ENABLED (sync issue!)");

        // ⚠️ SYNC ISSUE #2: This trader was never paused, so it stays enabled
        assertTrue(creditVault.traders(enabledButNotTrackedTrader), "Not tracked trader stayed enabled throughout");

        // Verify whitelist status preserved after unpause
        assertTrue(creditVault.whitelistTraders(trackedWhitelistTrader), "Whitelist should still be preserved");
    }

    /// @notice Test manual remediation of non-synced traders during emergency
    /// @dev This demonstrates BACKUP methods to handle trader sync issues discovered during emergency:
    ///      Method 1: Use setTrader() to manually disable forgotten traders
    ///      Method 2: Add forgotten trader to tracking, then re-pause/unpause
    ///      Both methods can fix the trader sync issue, but have different use cases
    function testEmergencyNonSyncTraderRemediation() public {
        // Setup: 3 traders enabled in CreditVault
        address trackedTrader1 = makeAddr("trackedTrader1");
        address trackedTrader1Recipient = makeAddr("trackedTrader1Recipient");

        address trackedTrader2 = makeAddr("trackedTrader2");
        address trackedTrader2Recipient = makeAddr("trackedTrader2Recipient");

        address forgottenTrader = makeAddr("forgottenTrader");
        address forgottenTraderRecipient = makeAddr("forgottenTraderRecipient");

        // Enable all 3 traders
        vm.prank(deployer);
        sentinel.setTrader(trackedTrader1, trackedTrader1, trackedTrader1Recipient, true, false);

        vm.prank(deployer);
        sentinel.setTrader(trackedTrader2, trackedTrader2, trackedTrader2Recipient, true, false);

        vm.prank(deployer);
        sentinel.setTrader(forgottenTrader, forgottenTrader, forgottenTraderRecipient, true, false);

        // Setup pool for emergency pause requirement
        _setupTestPool();

        // Only add 2 traders to tracking (FORGET the third one - simulates operator error)
        address[] memory traders = new address[](2);
        traders[0] = trackedTrader1;
        traders[1] = trackedTrader2;

        vm.prank(deployer);
        sentinel.addTraders(traders);

        // Verify all traders are enabled before emergency
        assertTrue(creditVault.traders(trackedTrader1), "Tracked trader 1 should be enabled");
        assertTrue(creditVault.traders(trackedTrader2), "Tracked trader 2 should be enabled");
        assertTrue(creditVault.traders(forgottenTrader), "Forgotten trader should be enabled");

        // Emergency pause is triggered
        vm.prank(emergencyPauser);
        sentinel.emergencyPause();

        // Verify tracked traders are disabled
        assertFalse(creditVault.traders(trackedTrader1), "Tracked trader 1 should be disabled");
        assertFalse(creditVault.traders(trackedTrader2), "Tracked trader 2 should be disabled");

        // ⚠️ Problem discovered: Forgotten trader is still enabled!
        assertTrue(creditVault.traders(forgottenTrader), "Forgotten trader still enabled - SECURITY ISSUE!");

        // ============================================================================
        // REMEDIATION METHOD 1: Manual disable via setTrader (IMMEDIATE FIX)
        // ============================================================================
        // Advantage: Can be done immediately without unpause/re-pause cycle
        // Use case: Quick fix when only a few traders were forgotten

        vm.prank(deployer);
        sentinel.setTrader(forgottenTrader, forgottenTrader, forgottenTraderRecipient, false, false);

        // Verify the forgotten trader is now disabled
        assertFalse(creditVault.traders(forgottenTrader), "Forgotten trader should now be disabled (manual fix)");

        // System is now in correct emergency state - all traders disabled
        assertFalse(creditVault.traders(trackedTrader1), "Tracked trader 1 still disabled");
        assertFalse(creditVault.traders(trackedTrader2), "Tracked trader 2 still disabled");
        assertFalse(creditVault.traders(forgottenTrader), "Forgotten trader now disabled");

        // ============================================================================
        // Later: Add forgotten trader to tracking for proper future emergency handling
        // ============================================================================
        address[] memory forgottenTraders = new address[](1);
        forgottenTraders[0] = forgottenTrader;

        vm.prank(deployer);
        sentinel.addTraders(forgottenTraders);

        // Verify it's now tracked
        assertTrue(sentinel.isTrader(forgottenTrader), "Forgotten trader should now be tracked");

        // Now when we unpause, all traders (including previously forgotten one) will be restored
        vm.prank(deployer);
        sentinel.emergencyUnpause();

        // Verify all traders are re-enabled after unpause
        assertTrue(creditVault.traders(trackedTrader1), "Tracked trader 1 should be re-enabled");
        assertTrue(creditVault.traders(trackedTrader2), "Tracked trader 2 should be re-enabled");
        assertTrue(creditVault.traders(forgottenTrader), "Forgotten trader should be re-enabled");

        // ============================================================================
        // ALTERNATIVE: REMEDIATION METHOD 2 - Add to tracking then re-pause/unpause
        // ============================================================================
        // Now let's simulate this alternative approach from the beginning

        // Reset: Enable a new forgotten trader
        address anotherForgottenTrader = makeAddr("anotherForgottenTrader");
        address anotherForgottenRecipient = makeAddr("anotherForgottenRecipient");

        vm.prank(deployer);
        sentinel.setTrader(anotherForgottenTrader, anotherForgottenTrader, anotherForgottenRecipient, true, false);

        assertTrue(creditVault.traders(anotherForgottenTrader), "Another forgotten trader should be enabled");

        // Pause again (all tracked traders get disabled, but new forgotten trader doesn't)
        vm.prank(emergencyPauser);
        sentinel.emergencyPause();

        assertFalse(creditVault.traders(trackedTrader1), "Tracked trader 1 disabled");
        assertFalse(creditVault.traders(trackedTrader2), "Tracked trader 2 disabled");
        assertFalse(creditVault.traders(forgottenTrader), "Previously forgotten (now tracked) disabled");
        assertTrue(creditVault.traders(anotherForgottenTrader), "New forgotten trader still enabled - ISSUE!");

        // Method 2: Add to tracking list
        address[] memory newForgottenTraders = new address[](1);
        newForgottenTraders[0] = anotherForgottenTrader;

        vm.prank(deployer);
        sentinel.addTraders(newForgottenTraders);

        // Unpause first (to reset state)
        vm.prank(deployer);
        sentinel.emergencyUnpause();

        // All traders are now enabled
        assertTrue(creditVault.traders(anotherForgottenTrader), "New forgotten trader re-enabled");

        // Re-pause - now the newly tracked trader will also be disabled
        vm.prank(emergencyPauser);
        sentinel.emergencyPause();

        // Verify all traders (including newly tracked one) are now disabled
        assertFalse(creditVault.traders(trackedTrader1), "Tracked trader 1 disabled");
        assertFalse(creditVault.traders(trackedTrader2), "Tracked trader 2 disabled");
        assertFalse(creditVault.traders(forgottenTrader), "Previously forgotten trader disabled");
        assertFalse(creditVault.traders(anotherForgottenTrader), "Newly tracked trader also disabled!");

        // Summary of remediation methods:
        // Method 1 (setTrader): Fast, immediate, good for few traders, doesn't require unpause
        // Method 2 (add + re-pause): More systematic, good for many traders, requires unpause cycle
    }

    /// @notice Test manual remediation of non-synced pools during emergency
    /// @dev This demonstrates BACKUP methods to handle pool sync issues discovered during emergency:
    ///      Method 1: Use setCreditPool() to manually disable forgotten pools
    ///      Method 2: Add forgotten pool to tracking, then re-pause/unpause
    ///      Both methods can fix the pool sync issue, but have different use cases
    function testEmergencyNonSyncPoolRemediation() public {
        // Setup: Create a trader first (required for emergency pause)
        address testTrader = makeAddr("testTrader");
        address testRecipient = makeAddr("testRecipient");

        vm.prank(deployer);
        sentinel.setTrader(testTrader, testTrader, testRecipient, true, false);

        address[] memory traders = new address[](1);
        traders[0] = testTrader;
        vm.prank(deployer);
        sentinel.addTraders(traders);

        // Setup: 3 pools enabled in CreditVault
        address trackedPool1 = makeAddr("trackedPool1");
        address trackedPool2 = makeAddr("trackedPool2");
        address forgottenPool = makeAddr("forgottenPool");

        // Enable all 3 pools
        vm.prank(deployer);
        sentinel.setCreditPool(trackedPool1, true);

        vm.prank(deployer);
        sentinel.setCreditPool(trackedPool2, true);

        vm.prank(deployer);
        sentinel.setCreditPool(forgottenPool, true);

        // Only add 2 pools to tracking (FORGET the third one - simulates operator error)
        address[] memory pools = new address[](2);
        pools[0] = trackedPool1;
        pools[1] = trackedPool2;

        vm.prank(deployer);
        sentinel.addPools(pools);

        // Verify all pools are enabled before emergency
        assertTrue(creditVault.creditPools(trackedPool1), "Tracked pool 1 should be enabled");
        assertTrue(creditVault.creditPools(trackedPool2), "Tracked pool 2 should be enabled");
        assertTrue(creditVault.creditPools(forgottenPool), "Forgotten pool should be enabled");

        // Emergency pause is triggered
        vm.prank(emergencyPauser);
        sentinel.emergencyPause();

        // Verify tracked pools are disabled
        assertFalse(creditVault.creditPools(trackedPool1), "Tracked pool 1 should be disabled");
        assertFalse(creditVault.creditPools(trackedPool2), "Tracked pool 2 should be disabled");

        // ⚠️ Problem discovered: Forgotten pool is still enabled!
        assertTrue(creditVault.creditPools(forgottenPool), "Forgotten pool still enabled - SECURITY ISSUE!");

        // ============================================================================
        // REMEDIATION METHOD 1: Manual disable via setCreditPool (IMMEDIATE FIX)
        // ============================================================================
        // Advantage: Can be done immediately without unpause/re-pause cycle
        // Use case: Quick fix when only a few pools were forgotten

        vm.prank(deployer);
        sentinel.setCreditPool(forgottenPool, false);

        // Verify the forgotten pool is now disabled
        assertFalse(creditVault.creditPools(forgottenPool), "Forgotten pool should now be disabled (manual fix)");

        // System is now in correct emergency state - all pools disabled
        assertFalse(creditVault.creditPools(trackedPool1), "Tracked pool 1 still disabled");
        assertFalse(creditVault.creditPools(trackedPool2), "Tracked pool 2 still disabled");
        assertFalse(creditVault.creditPools(forgottenPool), "Forgotten pool now disabled");

        // ============================================================================
        // Later: Add forgotten pool to tracking for proper future emergency handling
        // ============================================================================
        address[] memory forgottenPools = new address[](1);
        forgottenPools[0] = forgottenPool;

        vm.prank(deployer);
        sentinel.addPools(forgottenPools);

        // Verify it's now tracked
        assertTrue(sentinel.isCreditPool(forgottenPool), "Forgotten pool should now be tracked");

        // Now when we unpause, all pools (including previously forgotten one) will be restored
        vm.prank(deployer);
        sentinel.emergencyUnpause();

        // Verify all pools are re-enabled after unpause
        assertTrue(creditVault.creditPools(trackedPool1), "Tracked pool 1 should be re-enabled");
        assertTrue(creditVault.creditPools(trackedPool2), "Tracked pool 2 should be re-enabled");
        assertTrue(creditVault.creditPools(forgottenPool), "Forgotten pool should be re-enabled");

        // ============================================================================
        // ALTERNATIVE: REMEDIATION METHOD 2 - Add to tracking then re-pause/unpause
        // ============================================================================
        // Now let's simulate this alternative approach from the beginning

        // Reset: Enable a new forgotten pool
        address anotherForgottenPool = makeAddr("anotherForgottenPool");

        vm.prank(deployer);
        sentinel.setCreditPool(anotherForgottenPool, true);

        assertTrue(creditVault.creditPools(anotherForgottenPool), "Another forgotten pool should be enabled");

        // Pause again (all tracked pools get disabled, but new forgotten pool doesn't)
        vm.prank(emergencyPauser);
        sentinel.emergencyPause();

        assertFalse(creditVault.creditPools(trackedPool1), "Tracked pool 1 disabled");
        assertFalse(creditVault.creditPools(trackedPool2), "Tracked pool 2 disabled");
        assertFalse(creditVault.creditPools(forgottenPool), "Previously forgotten (now tracked) disabled");
        assertTrue(creditVault.creditPools(anotherForgottenPool), "New forgotten pool still enabled - ISSUE!");

        // Method 2: Add to tracking list
        address[] memory newForgottenPools = new address[](1);
        newForgottenPools[0] = anotherForgottenPool;

        vm.prank(deployer);
        sentinel.addPools(newForgottenPools);

        // Unpause first (to reset state)
        vm.prank(deployer);
        sentinel.emergencyUnpause();

        // All pools are now enabled
        assertTrue(creditVault.creditPools(anotherForgottenPool), "New forgotten pool re-enabled");

        // Re-pause - now the newly tracked pool will also be disabled
        vm.prank(emergencyPauser);
        sentinel.emergencyPause();

        // Verify all pools (including newly tracked one) are now disabled
        assertFalse(creditVault.creditPools(trackedPool1), "Tracked pool 1 disabled");
        assertFalse(creditVault.creditPools(trackedPool2), "Tracked pool 2 disabled");
        assertFalse(creditVault.creditPools(forgottenPool), "Previously forgotten pool disabled");
        assertFalse(creditVault.creditPools(anotherForgottenPool), "Newly tracked pool also disabled!");

        // Summary of remediation methods:
        // Method 1 (setCreditPool): Fast, immediate, good for few pools, doesn't require unpause
        // Method 2 (add + re-pause): More systematic, good for many pools, requires unpause cycle
    }

    /// @notice Gas limit stress test for emergency pause/unpause with large number of traders and pools
    /// @dev Tests the boundary of how many traders/pools can be handled before hitting gas limits
    ///      Ratio: 5 traders : 1 pool (reflecting realistic production scenarios)
    ///
    ///      Test Results with 4.5M Gas Limit (enforced via low-level call for BOTH operations):
    ///      - 130 traders, 26 pools: ✅ Pause: 1.28M, Unpause: 4.36M, Total: 5.64M
    ///      - 150 traders, 30 pools: ❌ Unpause EXCEEDS 4.5M gas limit
    ///
    ///      Key Insight - EVM SSTORE Gas Cost Asymmetry:
    ///      - Pause (disable: true→false): ~9.8k gas per trader (SSTORE_RESET)
    ///      - Unpause (enable: false→true): ~33.5k gas per trader (SSTORE_SET from zero)
    ///      - Unpause consumes ~3.4x MORE gas than pause due to EVM's storage pricing
    ///      - This asymmetry is the PRIMARY constraint for sizing Sentinel instances
    ///
    ///      Production Constraints (Ethereum mainnet):
    ///      - Block gas limit: ~45M (total for all transactions in a block)
    ///      - Conservative single tx limit: 4.5M gas (1/10 of Ethereum block gas limit)
    ///        * Rationale: Allows ~100 transactions per block on Ethereum mainnet
    ///        * This ensures emergency operations can coexist with other transactions
    ///      - Validated boundary: 130 traders + 26 pools (5:1 ratio)
    ///
    ///      Recommendation for production:
    ///      - Ethereum mainnet: Maximum 130 traders + 26 pools per Sentinel instance
    ///      - Emergency pause: ✅ 1.3M gas (ample headroom)
    ///      - Emergency unpause: ✅ 4.4M gas (fits within limit, bottleneck operation)
    ///
    ///      L2 Chain Considerations:
    ///      - L2 chains typically have fewer transactions per block (<< 100 tx/block)
    ///      - This allows for HIGHER single tx gas limits (e.g., 10M-20M gas)
    ///      - Result: L2 deployments can support MORE traders/pools per Sentinel instance
    ///      - Example: With 10M gas limit → ~290 traders + 58 pools (unpause-constrained)
    ///      - Example: With 20M gas limit → ~580 traders + 116 pools (unpause-constrained)
    ///
    ///      Scaling strategy:
    ///      - For larger deployments: Use multiple Sentinel instances (horizontal sharding)
    ///      - Each Sentinel manages a subset of traders/pools independently
    function testEmergencyPauseUnpauseGasLimitStressTest() public {
        // Testing with 130 traders and 26 pools to fit within 4.5M gas limit for BOTH pause and unpause
        // This represents a conservative boundary for a single Sentinel instance
        uint256 numTraders = 130;
        uint256 numPools = 26;

        // Setup traders
        address[] memory traders = new address[](numTraders);
        for (uint256 i = 0; i < numTraders; i++) {
            address trader = address(uint160(0x1000 + i));
            address recipient = address(uint160(0x2000 + i));

            vm.prank(deployer);
            sentinel.setTrader(trader, trader, recipient, true, false);

            traders[i] = trader;
        }

        // Add traders to tracking
        vm.prank(deployer);
        sentinel.addTraders(traders);

        // Setup pools
        address[] memory pools = new address[](numPools);
        for (uint256 i = 0; i < numPools; i++) {
            address pool = address(uint160(0x3000 + i));

            vm.prank(deployer);
            sentinel.setCreditPool(pool, true);

            pools[i] = pool;
        }

        // Add pools to tracking
        vm.prank(deployer);
        sentinel.addPools(pools);

        // Verify some traders and pools are enabled
        assertTrue(creditVault.traders(traders[0]), "First trader should be enabled");
        assertTrue(creditVault.traders(traders[numTraders - 1]), "Last trader should be enabled");
        assertTrue(creditVault.creditPools(pools[0]), "First pool should be enabled");
        assertTrue(creditVault.creditPools(pools[numPools - 1]), "Last pool should be enabled");

        // Measure gas for emergency pause with 4.5M gas limit
        // This represents 1/10 of Ethereum block gas limit (~45M)
        uint256 GAS_LIMIT = 4_500_000;
        uint256 gasBefore = gasleft();

        vm.prank(emergencyPauser);
        // Use low-level call with gas limit to test the constraint
        (bool success,) =
            address(sentinel).call{gas: GAS_LIMIT}(abi.encodeWithSelector(sentinel.emergencyPause.selector));

        uint256 gasUsedPause = gasBefore - gasleft();

        // Assert the pause succeeded within the gas limit
        assertTrue(success, "Emergency pause should succeed within 4.5M gas limit");
        assertTrue(sentinel.emergencyPaused(), "Should be paused");

        // Verify some traders and pools are disabled
        assertFalse(creditVault.traders(traders[0]), "First trader should be disabled");
        assertFalse(creditVault.traders(traders[numTraders - 1]), "Last trader should be disabled");
        assertFalse(creditVault.creditPools(pools[0]), "First pool should be disabled");
        assertFalse(creditVault.creditPools(pools[numPools - 1]), "Last pool should be disabled");

        // Measure gas for emergency unpause with same 4.5M gas limit
        // Note: Unpause consumes ~3.4x more gas than pause due to EVM SSTORE costs
        gasBefore = gasleft();

        vm.prank(deployer);
        // Use low-level call with gas limit to test the constraint
        (bool successUnpause,) =
            address(sentinel).call{gas: GAS_LIMIT}(abi.encodeWithSelector(sentinel.emergencyUnpause.selector));

        uint256 gasUsedUnpause = gasBefore - gasleft();

        // Assert both operations succeeded within the gas limit
        assertTrue(successUnpause, "Emergency unpause should succeed within 4.5M gas limit");
        assertFalse(sentinel.emergencyPaused(), "Should be unpaused");

        // Verify some traders and pools are re-enabled
        assertTrue(creditVault.traders(traders[0]), "First trader should be re-enabled");
        assertTrue(creditVault.traders(traders[numTraders - 1]), "Last trader should be re-enabled");
        assertTrue(creditVault.creditPools(pools[0]), "First pool should be re-enabled");
        assertTrue(creditVault.creditPools(pools[numPools - 1]), "Last pool should be re-enabled");

        // Log gas usage for analysis
        emit log_named_uint("Traders count", numTraders);
        emit log_named_uint("Pools count", numPools);
        emit log_named_uint("Gas used for pause", gasUsedPause);
        emit log_named_uint("Gas used for unpause", gasUsedUnpause);
        emit log_named_uint("Total gas for pause/unpause cycle", gasUsedPause + gasUsedUnpause);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            MIRROR FUNCTIONS TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function testSupportMarketSuccess() public {
        // Create a new LP token for testing
        vm.startPrank(deployer);
        MockERC20 newToken = new MockERC20("New Token", "NEW", 18);
        NativeLPToken newLPToken = new NativeLPToken("New LP Token", "nlpNEW", address(newToken), address(creditVault));
        vm.stopPrank();

        // Test successful market support
        vm.prank(deployer);
        sentinel.supportMarket(newLPToken);

        // Verify the market is supported in CreditVault
        assertTrue(creditVault.supportedMarkets(address(newLPToken)));
    }

    function testSupportMarketRevert() public {
        address nonOwner = makeAddr("nonOwner");

        // Create a new LP token for testing
        vm.startPrank(deployer);
        MockERC20 newToken = new MockERC20("New Token", "NEW", 18);
        NativeLPToken newLPToken = new NativeLPToken("New LP Token", "nlpNEW", address(newToken), address(creditVault));
        vm.stopPrank();

        // Test revert when called by non-owner
        vm.prank(nonOwner);
        vm.expectRevert();
        sentinel.supportMarket(newLPToken);
    }

    function testSetCreditPoolSuccess() public {
        address testPool = makeAddr("testPool");

        // Test enabling credit pool
        vm.prank(deployer);
        sentinel.setCreditPool(testPool, true);
        assertTrue(creditVault.creditPools(testPool));

        // Test disabling credit pool
        vm.prank(deployer);
        sentinel.setCreditPool(testPool, false);
        assertFalse(creditVault.creditPools(testPool));
    }

    function testSetCreditPoolRevert() public {
        address nonOwner = makeAddr("nonOwner");
        address testPool = makeAddr("testPool");

        // Test revert when called by non-owner
        vm.prank(nonOwner);
        vm.expectRevert();
        sentinel.setCreditPool(testPool, true);
    }

    function testSetAllowanceSuccess() public {
        address testPool = makeAddr("testPool");

        // Enable the pool first
        vm.prank(deployer);
        sentinel.setCreditPool(testPool, true);

        // Create allowance array
        ICreditVault.TokenAmountUint[] memory tokens = new ICreditVault.TokenAmountUint[](2);
        tokens[0] = ICreditVault.TokenAmountUint({token: address(USDC), amount: 1000e6});
        tokens[1] = ICreditVault.TokenAmountUint({token: address(weth), amount: 10e18});

        // Test setting allowance
        vm.prank(deployer);
        sentinel.setAllowance(tokens, testPool);

        // Verify allowances are set correctly
        assertEq(USDC.allowance(address(creditVault), testPool), tokens[0].amount, "USDC allowance not set correctly");
        assertEq(weth.allowance(address(creditVault), testPool), tokens[1].amount, "WETH allowance not set correctly");
    }

    function testSetAllowanceRevert() public {
        address nonOwner = makeAddr("nonOwner");
        address testPool = makeAddr("testPool");

        // Create allowance array
        ICreditVault.TokenAmountUint[] memory tokens = new ICreditVault.TokenAmountUint[](1);
        tokens[0] = ICreditVault.TokenAmountUint({token: address(USDC), amount: 1000e6});

        // Test revert when called by non-owner
        vm.prank(nonOwner);
        vm.expectRevert();
        sentinel.setAllowance(tokens, testPool);
    }

    function testSetRebalanceCapSuccess() public {
        address testOperator = makeAddr("testOperator");
        address testSettler = makeAddr("testSettler");
        address testRecipient = makeAddr("testRecipient");
        address testToken = address(USDC);
        uint256 testLimit = 1000e6;

        // First make the operator a trader so it can have rebalance cap
        vm.prank(deployer);
        sentinel.setTrader(testOperator, testSettler, testRecipient, true, false);

        // Test 1: Set initial rebalance cap
        vm.prank(deployer);
        sentinel.setRebalanceCap(testOperator, testToken, testLimit);

        // Verify initial rebalance cap is set correctly
        (uint256 limit, uint256 used, uint256 lastDay) = creditVault.rebalanceCaps(testOperator, testToken);
        assertEq(limit, testLimit, "Initial rebalance cap limit not set correctly");
        assertEq(used, 0, "Initial rebalance cap used should be 0");
        assertEq(lastDay, block.timestamp / 86_400, "Initial rebalance cap lastDay not set correctly");

        // Test 2: Update rebalance cap to a different value
        uint256 newLimit = 2000e6;
        vm.prank(deployer);
        sentinel.setRebalanceCap(testOperator, testToken, newLimit);

        // Verify updated rebalance cap
        (limit, used, lastDay) = creditVault.rebalanceCaps(testOperator, testToken);
        assertEq(limit, newLimit, "Updated rebalance cap limit not set correctly");
        assertEq(used, 0, "Updated rebalance cap used should reset to 0");
        assertEq(lastDay, block.timestamp / 86_400, "Updated rebalance cap lastDay should be current day");

        // Test 3: Set unlimited cap (limit = 0)
        vm.prank(deployer);
        sentinel.setRebalanceCap(testOperator, testToken, 0);

        // Verify unlimited cap
        (limit, used, lastDay) = creditVault.rebalanceCaps(testOperator, testToken);
        assertEq(limit, 0, "Unlimited rebalance cap limit should be 0");
        assertEq(used, 0, "Unlimited rebalance cap used should be 0");
        assertEq(lastDay, block.timestamp / 86_400, "Unlimited rebalance cap lastDay should be current day");

        // Test 4: Set cap for different token
        address anotherToken = address(weth);
        uint256 anotherLimit = 5e18;
        vm.prank(deployer);
        sentinel.setRebalanceCap(testOperator, anotherToken, anotherLimit);

        // Verify cap for different token
        (limit, used, lastDay) = creditVault.rebalanceCaps(testOperator, anotherToken);
        assertEq(limit, anotherLimit, "Different token rebalance cap limit not set correctly");
        assertEq(used, 0, "Different token rebalance cap used should be 0");
        assertEq(lastDay, block.timestamp / 86_400, "Different token rebalance cap lastDay should be current day");

        // Verify original token cap is unchanged
        (limit, used, lastDay) = creditVault.rebalanceCaps(testOperator, testToken);
        assertEq(limit, 0, "Original token cap should remain unlimited");
    }

    function testSetRebalanceCapRevert() public {
        address nonOwner = makeAddr("nonOwner");
        address testTrader = makeAddr("testTrader");

        // Test revert when called by non-owner
        vm.prank(nonOwner);
        vm.expectRevert();
        sentinel.setRebalanceCap(testTrader, address(USDC), 1000e6);
    }

    function testSetTraderSuccess() public {
        address testTrader = makeAddr("testTrader");
        address testSettler = makeAddr("testSettler");
        address testRecipient = makeAddr("testRecipient");

        // Test enabling trader
        vm.prank(deployer);
        sentinel.setTrader(testTrader, testSettler, testRecipient, true, false);
        assertTrue(creditVault.traders(testTrader));

        // Test disabling trader
        vm.prank(deployer);
        sentinel.setTrader(testTrader, testSettler, testRecipient, false, false);
        assertFalse(creditVault.traders(testTrader));

        // Test enabling whitelist trader
        vm.prank(deployer);
        sentinel.setTrader(testTrader, testSettler, testRecipient, true, true);
        assertTrue(creditVault.traders(testTrader));
        assertTrue(creditVault.whitelistTraders(testTrader));
    }

    function testSetTraderRevert() public {
        address nonOwner = makeAddr("nonOwner");
        address testTrader = makeAddr("testTrader");
        address testSettler = makeAddr("testSettler");
        address testRecipient = makeAddr("testRecipient");

        // Test revert when called by non-owner
        vm.prank(nonOwner);
        vm.expectRevert();
        sentinel.setTrader(testTrader, testSettler, testRecipient, true, false);
    }

    function testSetLiquidatorSuccess() public {
        address testLiquidator = makeAddr("testLiquidator");
        address testRecipient = makeAddr("testRecipient");

        // Test enabling liquidator
        vm.prank(deployer);
        sentinel.setLiquidator(testLiquidator, testRecipient, true);
        assertTrue(creditVault.liquidators(testLiquidator));

        // Test disabling liquidator
        vm.prank(deployer);
        sentinel.setLiquidator(testLiquidator, testRecipient, false);
        assertFalse(creditVault.liquidators(testLiquidator));
    }

    function testSetLiquidatorRevert() public {
        address nonOwner = makeAddr("nonOwner");
        address testLiquidator = makeAddr("testLiquidator");
        address testRecipient = makeAddr("testRecipient");

        // Test revert when called by non-owner
        vm.prank(nonOwner);
        vm.expectRevert();
        sentinel.setLiquidator(testLiquidator, testRecipient, true);
    }

    function testSetSignerSuccess() public {
        address newSigner = makeAddr("newSigner");

        // Test setting new signer
        vm.prank(deployer);
        sentinel.setSigner(newSigner);
        assertEq(creditVault.signer(), newSigner);
    }

    function testSetSignerRevert() public {
        address nonOwner = makeAddr("nonOwner");
        address testSigner = makeAddr("testSigner");

        // Test revert when called by non-owner
        vm.prank(nonOwner);
        vm.expectRevert();
        sentinel.setSigner(testSigner);

        // Test zero address revert
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        sentinel.setSigner(address(0));
    }

    function testSetEpochUpdaterSuccess() public {
        address newEpochUpdater = makeAddr("newEpochUpdater");

        // Test setting new epoch updater
        vm.prank(deployer);
        sentinel.setEpochUpdater(newEpochUpdater);
        assertEq(creditVault.epochUpdater(), newEpochUpdater);
    }

    function testSetEpochUpdaterRevert() public {
        address nonOwner = makeAddr("nonOwner");
        address testEpochUpdater = makeAddr("testEpochUpdater");

        // Test revert when called by non-owner
        vm.prank(nonOwner);
        vm.expectRevert();
        sentinel.setEpochUpdater(testEpochUpdater);

        // Test zero address revert
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        sentinel.setEpochUpdater(address(0));
    }

    function testSetFeeWithdrawerSuccess() public {
        address payable newFeeWithdrawer = payable(makeAddr("newFeeWithdrawer"));

        // Test setting new fee withdrawer
        vm.prank(deployer);
        sentinel.setFeeWithdrawer(newFeeWithdrawer);
        assertEq(creditVault.feeWithdrawer(), newFeeWithdrawer);
    }

    function testSetFeeWithdrawerRevert() public {
        address nonOwner = makeAddr("nonOwner");
        address testFeeWithdrawer = makeAddr("testFeeWithdrawer");

        // Test revert when called by non-owner
        vm.prank(nonOwner);
        vm.expectRevert();
        sentinel.setFeeWithdrawer(payable(testFeeWithdrawer));

        // Test zero address revert
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        sentinel.setFeeWithdrawer(payable(address(0)));
    }

    /*//////////////////////////////////////////////////////////////////////////
                            TRADERS MANAGEMENT TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function testTradersManagement() public {
        // Create test addresses
        address trader1 = makeAddr("trader1");
        address trader2 = makeAddr("trader2");
        address trader3 = makeAddr("trader3");
        address trader4 = makeAddr("trader4");

        // Verify initial state - no traders tracked
        // Note: We can't directly check array length, but we can verify through isTrader mapping

        // Test 1: Add single trader
        address[] memory singleTrader = new address[](1);
        singleTrader[0] = trader1;

        vm.prank(deployer);
        sentinel.addTraders(singleTrader);

        // Verify trader1 is tracked
        assertTrue(sentinel.isTrader(trader1), "trader1 should be tracked");
        assertEq(sentinel.traders(0), trader1, "trader1 should be at index 0");

        // Test 2: Add multiple traders
        address[] memory multipleTraders = new address[](3);
        multipleTraders[0] = trader2;
        multipleTraders[1] = trader3;
        multipleTraders[2] = trader4;

        vm.prank(deployer);
        sentinel.addTraders(multipleTraders);

        // Verify all traders are tracked
        assertTrue(sentinel.isTrader(trader1), "trader1 should still be tracked");
        assertTrue(sentinel.isTrader(trader2), "trader2 should be tracked");
        assertTrue(sentinel.isTrader(trader3), "trader3 should be tracked");
        assertTrue(sentinel.isTrader(trader4), "trader4 should be tracked");

        // Verify array contains all traders
        assertEq(sentinel.traders(0), trader1, "trader1 should be at index 0");
        assertEq(sentinel.traders(1), trader2, "trader2 should be at index 1");
        assertEq(sentinel.traders(2), trader3, "trader3 should be at index 2");
        assertEq(sentinel.traders(3), trader4, "trader4 should be at index 3");

        // Test 3: Remove single trader from middle
        address[] memory removeOne = new address[](1);
        removeOne[0] = trader2;

        vm.prank(deployer);
        sentinel.removeTraders(removeOne);

        // Verify trader2 is removed and array is compacted
        assertFalse(sentinel.isTrader(trader2), "trader2 should not be tracked");
        assertTrue(sentinel.isTrader(trader1), "trader1 should still be tracked");
        assertTrue(sentinel.isTrader(trader3), "trader3 should still be tracked");
        assertTrue(sentinel.isTrader(trader4), "trader4 should still be tracked");

        // Verify array is compacted (trader4 should have moved to index 1)
        assertEq(sentinel.traders(0), trader1, "trader1 should be at index 0");
        assertEq(sentinel.traders(1), trader4, "trader4 should have moved to index 1");
        assertEq(sentinel.traders(2), trader3, "trader3 should be at index 2");

        // Test 4: Remove multiple traders
        address[] memory removeMultiple = new address[](2);
        removeMultiple[0] = trader1;
        removeMultiple[1] = trader3;

        vm.prank(deployer);
        sentinel.removeTraders(removeMultiple);

        // Verify only trader4 remains
        assertFalse(sentinel.isTrader(trader1), "trader1 should not be tracked");
        assertFalse(sentinel.isTrader(trader3), "trader3 should not be tracked");
        assertTrue(sentinel.isTrader(trader4), "trader4 should still be tracked");
        assertEq(sentinel.traders(0), trader4, "trader4 should be the only remaining trader");

        // Test 5: Remove last trader
        address[] memory removeLast = new address[](1);
        removeLast[0] = trader4;

        vm.prank(deployer);
        sentinel.removeTraders(removeLast);

        // Verify no traders remain
        assertFalse(sentinel.isTrader(trader4), "trader4 should not be tracked");

        // Test 6: Re-add traders to verify system can handle empty -> populated
        vm.prank(deployer);
        sentinel.addTraders(multipleTraders); // Re-add trader2, trader3, trader4

        // Verify all are tracked again
        assertTrue(sentinel.isTrader(trader2), "trader2 should be tracked again");
        assertTrue(sentinel.isTrader(trader3), "trader3 should be tracked again");
        assertTrue(sentinel.isTrader(trader4), "trader4 should be tracked again");

        // Test 7: Multiple add/remove cycles to ensure consistency
        for (uint256 i = 0; i < 3; i++) {
            // Remove all
            address[] memory removeAll = new address[](3);
            removeAll[0] = trader2;
            removeAll[1] = trader3;
            removeAll[2] = trader4;

            vm.prank(deployer);
            sentinel.removeTraders(removeAll);

            // Verify all removed
            assertFalse(sentinel.isTrader(trader2), "trader2 should not be tracked in cycle");
            assertFalse(sentinel.isTrader(trader3), "trader3 should not be tracked in cycle");
            assertFalse(sentinel.isTrader(trader4), "trader4 should not be tracked in cycle");

            // Add them back
            vm.prank(deployer);
            sentinel.addTraders(multipleTraders);

            // Verify all added back
            assertTrue(sentinel.isTrader(trader2), "trader2 should be tracked again in cycle");
            assertTrue(sentinel.isTrader(trader3), "trader3 should be tracked again in cycle");
            assertTrue(sentinel.isTrader(trader4), "trader4 should be tracked again in cycle");
        }
    }

    function testTradersManagementRevert() public {
        address trader1 = makeAddr("trader1");
        address trader2 = makeAddr("trader2");
        address nonOwner = makeAddr("nonOwner");

        // Test 1: Non-owner cannot add traders
        address[] memory traders = new address[](1);
        traders[0] = trader1;

        vm.prank(nonOwner);
        vm.expectRevert();
        sentinel.addTraders(traders);

        // Test 2: Non-owner cannot remove traders
        vm.prank(nonOwner);
        vm.expectRevert();
        sentinel.removeTraders(traders);

        // Test 3: Cannot add zero address
        address[] memory zeroTraders = new address[](1);
        zeroTraders[0] = address(0);

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        sentinel.addTraders(zeroTraders);

        // Test 4: Cannot remove zero address (will fail with "Trader not tracked" since zero address is never tracked)
        vm.prank(deployer);
        vm.expectRevert(bytes("Trader not tracked"));
        sentinel.removeTraders(zeroTraders);

        // Test 5: Cannot add duplicate trader
        vm.prank(deployer);
        sentinel.addTraders(traders); // Add trader1

        vm.prank(deployer);
        vm.expectRevert(bytes("Trader already tracked"));
        sentinel.addTraders(traders); // Try to add trader1 again

        // Test 6: Cannot remove non-existent trader
        address[] memory nonExistentTraders = new address[](1);
        nonExistentTraders[0] = trader2; // trader2 was never added

        vm.prank(deployer);
        vm.expectRevert(bytes("Trader not tracked"));
        sentinel.removeTraders(nonExistentTraders);

        // Test 7: Cannot add duplicate in same call
        address[] memory duplicateInCall = new address[](2);
        duplicateInCall[0] = trader2;
        duplicateInCall[1] = trader2; // Duplicate in same array

        vm.prank(deployer);
        vm.expectRevert(bytes("Trader already tracked"));
        sentinel.addTraders(duplicateInCall);

        // Test 8: Cannot remove same trader twice in same call
        address[] memory duplicateRemove = new address[](2);
        duplicateRemove[0] = trader1; // trader1 exists
        duplicateRemove[1] = trader1; // Duplicate removal

        vm.prank(deployer);
        vm.expectRevert(bytes("Trader not tracked"));
        sentinel.removeTraders(duplicateRemove);

        // Test 9: Empty array should succeed (edge case)
        address[] memory emptyArray = new address[](0);

        vm.prank(deployer);
        sentinel.addTraders(emptyArray); // Should succeed without doing anything

        vm.prank(deployer);
        sentinel.removeTraders(emptyArray); // Should succeed without doing anything
    }

    /*//////////////////////////////////////////////////////////////////////////
                        EMERGENCY PAUSERS MANAGEMENT TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function testEmergencyPausersManagement() public {
        // Create test addresses
        address pauser1 = makeAddr("pauser1");
        address pauser2 = makeAddr("pauser2");
        address pauser3 = makeAddr("pauser3");
        address pauser4 = makeAddr("pauser4");

        // Verify initial state - one pauser (emergencyPauser) from setUp
        assertTrue(sentinel.isPauser(emergencyPauser), "emergencyPauser should be tracked from setUp");
        assertEq(sentinel.emergencyPausers(0), emergencyPauser, "emergencyPauser should be at index 0");

        // Test 1: Add single pauser
        address[] memory singlePauser = new address[](1);
        singlePauser[0] = pauser1;

        vm.prank(deployer);
        sentinel.addEmergencyPausers(singlePauser);

        // Verify pauser1 is tracked
        assertTrue(sentinel.isPauser(pauser1), "pauser1 should be tracked");
        assertEq(sentinel.emergencyPausers(1), pauser1, "pauser1 should be at index 1");

        // Test 2: Add multiple pausers
        address[] memory multiplePausers = new address[](3);
        multiplePausers[0] = pauser2;
        multiplePausers[1] = pauser3;
        multiplePausers[2] = pauser4;

        vm.prank(deployer);
        sentinel.addEmergencyPausers(multiplePausers);

        // Verify all pausers are tracked
        assertTrue(sentinel.isPauser(emergencyPauser), "emergencyPauser should still be tracked");
        assertTrue(sentinel.isPauser(pauser1), "pauser1 should still be tracked");
        assertTrue(sentinel.isPauser(pauser2), "pauser2 should be tracked");
        assertTrue(sentinel.isPauser(pauser3), "pauser3 should be tracked");
        assertTrue(sentinel.isPauser(pauser4), "pauser4 should be tracked");

        // Verify array contains all pausers
        assertEq(sentinel.emergencyPausers(0), emergencyPauser, "emergencyPauser should be at index 0");
        assertEq(sentinel.emergencyPausers(1), pauser1, "pauser1 should be at index 1");
        assertEq(sentinel.emergencyPausers(2), pauser2, "pauser2 should be at index 2");
        assertEq(sentinel.emergencyPausers(3), pauser3, "pauser3 should be at index 3");
        assertEq(sentinel.emergencyPausers(4), pauser4, "pauser4 should be at index 4");

        // Test 3: Remove single pauser from middle
        address[] memory removeOne = new address[](1);
        removeOne[0] = pauser2;

        vm.prank(deployer);
        sentinel.removeEmergencyPausers(removeOne);

        // Verify pauser2 is removed and array is compacted
        assertFalse(sentinel.isPauser(pauser2), "pauser2 should not be tracked");
        assertTrue(sentinel.isPauser(emergencyPauser), "emergencyPauser should still be tracked");
        assertTrue(sentinel.isPauser(pauser1), "pauser1 should still be tracked");
        assertTrue(sentinel.isPauser(pauser3), "pauser3 should still be tracked");
        assertTrue(sentinel.isPauser(pauser4), "pauser4 should still be tracked");

        // Verify array is compacted (pauser4 should have moved to index 2)
        assertEq(sentinel.emergencyPausers(0), emergencyPauser, "emergencyPauser should be at index 0");
        assertEq(sentinel.emergencyPausers(1), pauser1, "pauser1 should be at index 1");
        assertEq(sentinel.emergencyPausers(2), pauser4, "pauser4 should have moved to index 2");
        assertEq(sentinel.emergencyPausers(3), pauser3, "pauser3 should be at index 3");

        // Test 4: Remove multiple pausers
        address[] memory removeMultiple = new address[](2);
        removeMultiple[0] = pauser1;
        removeMultiple[1] = pauser3;

        vm.prank(deployer);
        sentinel.removeEmergencyPausers(removeMultiple);

        // Verify only emergencyPauser and pauser4 remain
        assertFalse(sentinel.isPauser(pauser1), "pauser1 should not be tracked");
        assertFalse(sentinel.isPauser(pauser3), "pauser3 should not be tracked");
        assertTrue(sentinel.isPauser(emergencyPauser), "emergencyPauser should still be tracked");
        assertTrue(sentinel.isPauser(pauser4), "pauser4 should still be tracked");

        // Test 5: Remove pauser4
        address[] memory removeAnother = new address[](1);
        removeAnother[0] = pauser4;

        vm.prank(deployer);
        sentinel.removeEmergencyPausers(removeAnother);

        // Verify only emergencyPauser remains
        assertFalse(sentinel.isPauser(pauser4), "pauser4 should not be tracked");
        assertTrue(sentinel.isPauser(emergencyPauser), "emergencyPauser should still be tracked");
        assertEq(sentinel.emergencyPausers(0), emergencyPauser, "emergencyPauser should be the only remaining pauser");

        // Test 6: Re-add pausers to verify system can handle removal -> populated
        vm.prank(deployer);
        sentinel.addEmergencyPausers(multiplePausers); // Re-add pauser2, pauser3, pauser4

        // Verify all are tracked again
        assertTrue(sentinel.isPauser(pauser2), "pauser2 should be tracked again");
        assertTrue(sentinel.isPauser(pauser3), "pauser3 should be tracked again");
        assertTrue(sentinel.isPauser(pauser4), "pauser4 should be tracked again");

        // Test 7: Multiple add/remove cycles to ensure consistency
        for (uint256 i = 0; i < 3; i++) {
            // Remove all except emergencyPauser
            address[] memory removeAll = new address[](3);
            removeAll[0] = pauser2;
            removeAll[1] = pauser3;
            removeAll[2] = pauser4;

            vm.prank(deployer);
            sentinel.removeEmergencyPausers(removeAll);

            // Verify all removed
            assertFalse(sentinel.isPauser(pauser2), "pauser2 should not be tracked in cycle");
            assertFalse(sentinel.isPauser(pauser3), "pauser3 should not be tracked in cycle");
            assertFalse(sentinel.isPauser(pauser4), "pauser4 should not be tracked in cycle");

            // Add them back
            vm.prank(deployer);
            sentinel.addEmergencyPausers(multiplePausers);

            // Verify all added back
            assertTrue(sentinel.isPauser(pauser2), "pauser2 should be tracked again in cycle");
            assertTrue(sentinel.isPauser(pauser3), "pauser3 should be tracked again in cycle");
            assertTrue(sentinel.isPauser(pauser4), "pauser4 should be tracked again in cycle");
        }
    }

    function testEmergencyPausersManagementRevert() public {
        address pauser1 = makeAddr("pauser1");
        address pauser2 = makeAddr("pauser2");
        address nonOwner = makeAddr("nonOwner");

        // Test 1: Non-owner cannot add pausers
        address[] memory pausers = new address[](1);
        pausers[0] = pauser1;

        vm.prank(nonOwner);
        vm.expectRevert();
        sentinel.addEmergencyPausers(pausers);

        // Test 2: Non-owner cannot remove pausers
        vm.prank(nonOwner);
        vm.expectRevert();
        sentinel.removeEmergencyPausers(pausers);

        // Test 3: Cannot add zero address
        address[] memory zeroPausers = new address[](1);
        zeroPausers[0] = address(0);

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        sentinel.addEmergencyPausers(zeroPausers);

        // Test 4: Cannot remove zero address (will fail with "Pauser not authorized" since zero address is never tracked)
        vm.prank(deployer);
        vm.expectRevert(bytes("Pauser not authorized"));
        sentinel.removeEmergencyPausers(zeroPausers);

        // Test 5: Cannot add duplicate pauser
        vm.prank(deployer);
        sentinel.addEmergencyPausers(pausers); // Add pauser1

        vm.prank(deployer);
        vm.expectRevert(bytes("Pauser already authorized"));
        sentinel.addEmergencyPausers(pausers); // Try to add pauser1 again

        // Test 6: Cannot remove non-existent pauser
        address[] memory nonExistentPausers = new address[](1);
        nonExistentPausers[0] = pauser2; // pauser2 was never added

        vm.prank(deployer);
        vm.expectRevert(bytes("Pauser not authorized"));
        sentinel.removeEmergencyPausers(nonExistentPausers);

        // Test 7: Cannot add duplicate in same call
        address[] memory duplicateInCall = new address[](2);
        duplicateInCall[0] = pauser2;
        duplicateInCall[1] = pauser2; // Duplicate in same array

        vm.prank(deployer);
        vm.expectRevert(bytes("Pauser already authorized"));
        sentinel.addEmergencyPausers(duplicateInCall);

        // Test 8: Cannot remove same pauser twice in same call
        address[] memory duplicateRemove = new address[](2);
        duplicateRemove[0] = pauser1; // pauser1 exists
        duplicateRemove[1] = pauser1; // Duplicate removal

        vm.prank(deployer);
        vm.expectRevert(bytes("Pauser not authorized"));
        sentinel.removeEmergencyPausers(duplicateRemove);

        // Test 9: Empty array should succeed (edge case)
        address[] memory emptyArray = new address[](0);

        vm.prank(deployer);
        sentinel.addEmergencyPausers(emptyArray); // Should succeed without doing anything

        vm.prank(deployer);
        sentinel.removeEmergencyPausers(emptyArray); // Should succeed without doing anything
    }

    function testGetEmergencyPausers() public {
        // Initial state - should have one pauser from setUp
        address[] memory pausers = sentinel.getEmergencyPausers();
        assertEq(pausers.length, 1, "Should have 1 pauser initially");
        assertEq(pausers[0], emergencyPauser, "Should be the emergency pauser from setUp");

        // Add more pausers
        address pauser2 = makeAddr("pauser2");
        address pauser3 = makeAddr("pauser3");

        address[] memory newPausers = new address[](2);
        newPausers[0] = pauser2;
        newPausers[1] = pauser3;

        vm.prank(deployer);
        sentinel.addEmergencyPausers(newPausers);

        // Verify all pausers are returned
        pausers = sentinel.getEmergencyPausers();
        assertEq(pausers.length, 3, "Should have 3 pausers");
        assertEq(pausers[0], emergencyPauser, "First pauser should be emergencyPauser");
        assertEq(pausers[1], pauser2, "Second pauser should be pauser2");
        assertEq(pausers[2], pauser3, "Third pauser should be pauser3");

        // Remove one pauser
        address[] memory removePausers = new address[](1);
        removePausers[0] = pauser2;

        vm.prank(deployer);
        sentinel.removeEmergencyPausers(removePausers);

        // Verify pauser removed
        pausers = sentinel.getEmergencyPausers();
        assertEq(pausers.length, 2, "Should have 2 pausers after removal");
        // Note: pauser3 should have moved to index 1 due to array compaction
        assertTrue(sentinel.isPauser(emergencyPauser), "emergencyPauser should still be tracked");
        assertTrue(sentinel.isPauser(pauser3), "pauser3 should still be tracked");
        assertFalse(sentinel.isPauser(pauser2), "pauser2 should be removed");
    }

    /*//////////////////////////////////////////////////////////////////////////
                            POOLS MANAGEMENT TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function testPoolsManagement() public {
        // Create test addresses
        address pool1 = makeAddr("pool1");
        address pool2 = makeAddr("pool2");
        address pool3 = makeAddr("pool3");
        address pool4 = makeAddr("pool4");

        // Verify initial state - no pools tracked
        // Note: We can't directly check array length, but we can verify through isCreditPool mapping

        // Test 1: Add single pool
        address[] memory singlePool = new address[](1);
        singlePool[0] = pool1;

        vm.prank(deployer);
        sentinel.addPools(singlePool);

        // Verify pool1 is tracked
        assertTrue(sentinel.isCreditPool(pool1), "pool1 should be tracked");
        assertEq(sentinel.pools(0), pool1, "pool1 should be at index 0");

        // Test 2: Add multiple pools
        address[] memory multiplePools = new address[](3);
        multiplePools[0] = pool2;
        multiplePools[1] = pool3;
        multiplePools[2] = pool4;

        vm.prank(deployer);
        sentinel.addPools(multiplePools);

        // Verify all pools are tracked
        assertTrue(sentinel.isCreditPool(pool1), "pool1 should still be tracked");
        assertTrue(sentinel.isCreditPool(pool2), "pool2 should be tracked");
        assertTrue(sentinel.isCreditPool(pool3), "pool3 should be tracked");
        assertTrue(sentinel.isCreditPool(pool4), "pool4 should be tracked");

        // Verify array contains all pools
        assertEq(sentinel.pools(0), pool1, "pool1 should be at index 0");
        assertEq(sentinel.pools(1), pool2, "pool2 should be at index 1");
        assertEq(sentinel.pools(2), pool3, "pool3 should be at index 2");
        assertEq(sentinel.pools(3), pool4, "pool4 should be at index 3");

        // Test 3: Remove single pool from middle
        address[] memory removeOne = new address[](1);
        removeOne[0] = pool2;

        vm.prank(deployer);
        sentinel.removePools(removeOne);

        // Verify pool2 is removed and array is compacted
        assertFalse(sentinel.isCreditPool(pool2), "pool2 should not be tracked");
        assertTrue(sentinel.isCreditPool(pool1), "pool1 should still be tracked");
        assertTrue(sentinel.isCreditPool(pool3), "pool3 should still be tracked");
        assertTrue(sentinel.isCreditPool(pool4), "pool4 should still be tracked");

        // Verify array is compacted (pool4 should have moved to index 1)
        assertEq(sentinel.pools(0), pool1, "pool1 should be at index 0");
        assertEq(sentinel.pools(1), pool4, "pool4 should have moved to index 1");
        assertEq(sentinel.pools(2), pool3, "pool3 should be at index 2");

        // Test 4: Remove multiple pools
        address[] memory removeMultiple = new address[](2);
        removeMultiple[0] = pool1;
        removeMultiple[1] = pool3;

        vm.prank(deployer);
        sentinel.removePools(removeMultiple);

        // Verify only pool4 remains
        assertFalse(sentinel.isCreditPool(pool1), "pool1 should not be tracked");
        assertFalse(sentinel.isCreditPool(pool3), "pool3 should not be tracked");
        assertTrue(sentinel.isCreditPool(pool4), "pool4 should still be tracked");
        assertEq(sentinel.pools(0), pool4, "pool4 should be the only remaining pool");

        // Test 5: Remove last pool
        address[] memory removeLast = new address[](1);
        removeLast[0] = pool4;

        vm.prank(deployer);
        sentinel.removePools(removeLast);

        // Verify no pools remain
        assertFalse(sentinel.isCreditPool(pool4), "pool4 should not be tracked");

        // Test 6: Re-add pools to verify system can handle empty -> populated
        vm.prank(deployer);
        sentinel.addPools(multiplePools); // Re-add pool2, pool3, pool4

        // Verify all are tracked again
        assertTrue(sentinel.isCreditPool(pool2), "pool2 should be tracked again");
        assertTrue(sentinel.isCreditPool(pool3), "pool3 should be tracked again");
        assertTrue(sentinel.isCreditPool(pool4), "pool4 should be tracked again");

        // Test 7: Multiple add/remove cycles to ensure consistency
        for (uint256 i = 0; i < 3; i++) {
            // Remove all
            address[] memory removeAll = new address[](3);
            removeAll[0] = pool2;
            removeAll[1] = pool3;
            removeAll[2] = pool4;

            vm.prank(deployer);
            sentinel.removePools(removeAll);

            // Verify all removed
            assertFalse(sentinel.isCreditPool(pool2), "pool2 should not be tracked in cycle");
            assertFalse(sentinel.isCreditPool(pool3), "pool3 should not be tracked in cycle");
            assertFalse(sentinel.isCreditPool(pool4), "pool4 should not be tracked in cycle");

            // Add them back
            vm.prank(deployer);
            sentinel.addPools(multiplePools);

            // Verify all added back
            assertTrue(sentinel.isCreditPool(pool2), "pool2 should be tracked again in cycle");
            assertTrue(sentinel.isCreditPool(pool3), "pool3 should be tracked again in cycle");
            assertTrue(sentinel.isCreditPool(pool4), "pool4 should be tracked again in cycle");
        }
    }

    function testPoolsManagementRevert() public {
        address pool1 = makeAddr("pool1");
        address pool2 = makeAddr("pool2");
        address nonOwner = makeAddr("nonOwner");

        // Test 1: Non-owner cannot add pools
        address[] memory pools = new address[](1);
        pools[0] = pool1;

        vm.prank(nonOwner);
        vm.expectRevert();
        sentinel.addPools(pools);

        // Test 2: Non-owner cannot remove pools
        vm.prank(nonOwner);
        vm.expectRevert();
        sentinel.removePools(pools);

        // Test 3: Cannot add zero address
        address[] memory zeroPools = new address[](1);
        zeroPools[0] = address(0);

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        sentinel.addPools(zeroPools);

        // Test 4: Cannot remove zero address (will fail with "Pool not tracked" since zero address is never tracked)
        vm.prank(deployer);
        vm.expectRevert(bytes("Pool not tracked"));
        sentinel.removePools(zeroPools);

        // Test 5: Cannot add duplicate pool
        vm.prank(deployer);
        sentinel.addPools(pools); // Add pool1

        vm.prank(deployer);
        vm.expectRevert(bytes("Pool already tracked"));
        sentinel.addPools(pools); // Try to add pool1 again

        // Test 6: Cannot remove non-existent pool
        address[] memory nonExistentPools = new address[](1);
        nonExistentPools[0] = pool2; // pool2 was never added

        vm.prank(deployer);
        vm.expectRevert(bytes("Pool not tracked"));
        sentinel.removePools(nonExistentPools);

        // Test 7: Cannot add duplicate in same call
        address[] memory duplicateInCall = new address[](2);
        duplicateInCall[0] = pool2;
        duplicateInCall[1] = pool2; // Duplicate in same array

        vm.prank(deployer);
        vm.expectRevert(bytes("Pool already tracked"));
        sentinel.addPools(duplicateInCall);

        // Test 8: Cannot remove same pool twice in same call
        address[] memory duplicateRemove = new address[](2);
        duplicateRemove[0] = pool1; // pool1 exists
        duplicateRemove[1] = pool1; // Duplicate removal

        vm.prank(deployer);
        vm.expectRevert(bytes("Pool not tracked"));
        sentinel.removePools(duplicateRemove);

        // Test 9: Empty array should succeed (edge case)
        address[] memory emptyArray = new address[](0);

        vm.prank(deployer);
        sentinel.addPools(emptyArray); // Should succeed without doing anything

        vm.prank(deployer);
        sentinel.removePools(emptyArray); // Should succeed without doing anything
    }

    /*//////////////////////////////////////////////////////////////////////////
                    CRITICAL: NON-MIRROR FUNCTIONS AFTER OWNERSHIP TRANSFER
    //////////////////////////////////////////////////////////////////////////*/

    function testSettleWorksAfterOwnershipTransfer() public {
        // Setup: Create trader via Sentinel (ownership already transferred in setUp)
        address testTrader = makeAddr("testTrader");
        address testSettler = makeAddr("testSettler");
        address testRecipient = makeAddr("testRecipient");

        // 1. Set trader through Sentinel
        vm.prank(deployer);
        sentinel.setTrader(testTrader, testSettler, testRecipient, true, true);

        // Verify trader is set in CreditVault
        assertTrue(creditVault.traders(testTrader), "Trader should be enabled");

        // 2. Set signer through Sentinel
        vm.prank(deployer);
        sentinel.setSigner(deployer);

        // 3. Enable RFQ pool through Sentinel
        vm.prank(deployer);
        sentinel.setCreditPool(address(rfqPool), true);

        // 4. Create initial position via swapCallback
        vm.prank(address(rfqPool));
        creditVault.swapCallback(
            testTrader,
            address(USDC),
            6000e6, // Initial USDC long position
            address(weth),
            2 ether // Initial WETH short position
        );

        // 5. Setup balances and approvals
        deal(address(weth), testSettler, 1 ether);
        deal(address(USDC), address(creditVault), 6000e6);

        vm.startPrank(testSettler);
        weth.approve(address(creditVault), 1 ether);
        vm.stopPrank();

        // 6. Prepare settlement request
        ICreditVault.TokenAmountInt[] memory positionUpdates = new ICreditVault.TokenAmountInt[](2);
        positionUpdates[0] = ICreditVault.TokenAmountInt({
            token: address(USDC),
            amount: -3000e6 // Reduce USDC long position
        });
        positionUpdates[1] = ICreditVault.TokenAmountInt({
            token: address(weth),
            amount: 1 ether // Reduce WETH short position
        });

        ICreditVault.SettlementRequest memory request = ICreditVault.SettlementRequest({
            nonce: 0,
            deadline: block.timestamp + 3600,
            trader: testTrader,
            positionUpdates: positionUpdates
        });

        // 7. Generate signature
        bytes32 digest = SignatureUtils.generateSettleSignature(request, testRecipient, address(creditVault));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(deployerKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // 8. Record initial states
        int256 initialUSDCPosition = creditVault.positions(testTrader, address(USDC));
        int256 initialWETHPosition = creditVault.positions(testTrader, address(weth));
        uint256 initialRecipientUSDC = USDC.balanceOf(testRecipient);

        // 9. Execute settlement (this is the key test - settle should work after ownership transfer)
        vm.prank(testSettler);
        creditVault.settle(request, signature);

        // 10. Verify settlement worked correctly
        assertEq(
            creditVault.positions(testTrader, address(USDC)),
            initialUSDCPosition - 3000e6,
            "USDC position should be reduced"
        );
        assertEq(
            creditVault.positions(testTrader, address(weth)),
            initialWETHPosition + 1 ether,
            "WETH position should be reduced"
        );
        assertEq(USDC.balanceOf(testRecipient), initialRecipientUSDC + 3000e6, "Recipient should receive USDC");
    }

    function testRepayWorksAfterOwnershipTransfer() public {
        // Setup: Create trader via Sentinel
        address testTrader = makeAddr("testTrader");
        address testRecipient = makeAddr("testRecipient");

        // 1. Set trader through Sentinel
        vm.prank(deployer);
        sentinel.setTrader(testTrader, testTrader, testRecipient, true, true);

        // 2. Enable RFQ pool through Sentinel
        vm.prank(deployer);
        sentinel.setCreditPool(address(rfqPool), true);

        // 3. Create initial short position via swapCallback
        vm.prank(address(rfqPool));
        creditVault.swapCallback(
            testTrader,
            address(USDC),
            6000e6, // Initial USDC long position
            address(weth),
            2 ether // Initial WETH short position
        );

        // 4. Setup balances and approvals for repayment
        deal(address(weth), testTrader, 1 ether);
        vm.startPrank(testTrader);
        weth.approve(address(creditVault), 1 ether);

        // 5. Prepare repayment
        ICreditVault.TokenAmountInt[] memory positionUpdates = new ICreditVault.TokenAmountInt[](1);
        positionUpdates[0] = ICreditVault.TokenAmountInt({
            token: address(weth),
            amount: 1 ether // Repay 1 ether
        });

        // 6. Record initial states
        int256 initialWETHPosition = creditVault.positions(testTrader, address(weth));
        uint256 initialVaultWETH = weth.balanceOf(address(creditVault));

        // 7. Execute repay (this should work after ownership transfer)
        creditVault.repay(positionUpdates, testTrader);
        vm.stopPrank();

        // 8. Verify repayment worked correctly
        assertEq(
            creditVault.positions(testTrader, address(weth)),
            initialWETHPosition + 1 ether,
            "WETH position should increase (less short)"
        );
        assertEq(weth.balanceOf(address(creditVault)), initialVaultWETH + 1 ether, "Vault should receive WETH");
    }

    function testAddCollateralWorksAfterOwnershipTransfer() public {
        // Setup: Create trader via Sentinel
        address testTrader = makeAddr("testTrader");
        address testRecipient = makeAddr("testRecipient");

        // 1. Set trader through Sentinel
        vm.prank(deployer);
        sentinel.setTrader(testTrader, testTrader, testRecipient, true, true);

        // 2. Setup balances
        uint256 collateralAmount = 1000e6;
        deal(address(lpUSDC), testTrader, collateralAmount);

        // 3. Prepare token array
        ICreditVault.TokenAmountUint[] memory tokens = new ICreditVault.TokenAmountUint[](1);
        tokens[0] = ICreditVault.TokenAmountUint({token: address(lpUSDC), amount: collateralAmount});

        // 4. Approve and add collateral
        vm.startPrank(testTrader);
        lpUSDC.approve(address(creditVault), collateralAmount);

        // 5. Record initial state
        uint256 initialCollateral = creditVault.collateral(testTrader, address(lpUSDC));

        // 6. Execute addCollateral (this should work after ownership transfer)
        creditVault.addCollateral(tokens, testTrader);
        vm.stopPrank();

        // 7. Verify collateral was added correctly
        assertEq(
            creditVault.collateral(testTrader, address(lpUSDC)),
            initialCollateral + collateralAmount,
            "Collateral should be added"
        );
    }

    function testRemoveCollateralWorksAfterOwnershipTransfer() public {
        // Setup: Create trader via Sentinel
        address testTrader = makeAddr("testTrader");
        address testRecipient = makeAddr("testRecipient");

        // 1. Set trader and signer through Sentinel
        vm.prank(deployer);
        sentinel.setTrader(testTrader, testTrader, testRecipient, true, true);

        vm.prank(deployer);
        sentinel.setSigner(deployer);

        // 2. Setup balances and add collateral first
        uint256 collateralAmount = 1000e6;
        deal(address(lpUSDC), testTrader, collateralAmount);

        vm.startPrank(testTrader);
        lpUSDC.approve(address(creditVault), collateralAmount);

        ICreditVault.TokenAmountUint[] memory addTokens = new ICreditVault.TokenAmountUint[](1);
        addTokens[0] = ICreditVault.TokenAmountUint({token: address(lpUSDC), amount: collateralAmount});
        creditVault.addCollateral(addTokens, testTrader);
        vm.stopPrank();

        // 3. Prepare remove collateral request
        ICreditVault.TokenAmountUint[] memory removeTokens = new ICreditVault.TokenAmountUint[](1);
        removeTokens[0] = ICreditVault.TokenAmountUint({
            token: address(lpUSDC),
            amount: collateralAmount / 2 // Remove half
        });

        ICreditVault.RemoveCollateralRequest memory request = ICreditVault.RemoveCollateralRequest({
            nonce: 0,
            deadline: block.timestamp + 3600,
            trader: testTrader,
            tokens: removeTokens
        });

        // 4. Generate signature
        bytes32 digest = SignatureUtils.generateRemoveCollateralSignature(request, testRecipient, address(creditVault));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(deployerKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // 5. Record initial states
        uint256 initialCollateral = creditVault.collateral(testTrader, address(lpUSDC));
        uint256 initialRecipientBalance = lpUSDC.balanceOf(testRecipient);

        // 6. Execute remove collateral (this should work after ownership transfer)
        vm.prank(testTrader);
        creditVault.removeCollateral(request, signature);

        // 7. Verify collateral removal worked correctly
        assertEq(
            creditVault.collateral(testTrader, address(lpUSDC)),
            initialCollateral - collateralAmount / 2,
            "Collateral should be reduced"
        );
        assertEq(
            lpUSDC.balanceOf(testRecipient),
            initialRecipientBalance + collateralAmount / 2,
            "Recipient should receive LP tokens"
        );
    }

    function testLiquidateWorksAfterOwnershipTransfer() public {
        // Setup traders and liquidators via Sentinel
        address testTrader = makeAddr("testTrader");
        address testLiquidatorRecipient = makeAddr("testLiquidatorRecipient");

        // 1. Set trader and liquidator through Sentinel
        vm.prank(deployer);
        sentinel.setTrader(testTrader, testTrader, makeAddr("testTraderRecipient"), true, true);

        vm.prank(deployer);
        sentinel.setLiquidator(alice, testLiquidatorRecipient, true);

        vm.prank(deployer);
        sentinel.setSigner(deployer);

        // 2. Enable RFQ pool through Sentinel
        vm.prank(deployer);
        sentinel.setCreditPool(address(rfqPool), true);

        // 3. Create initial position via swapCallback
        vm.prank(address(rfqPool));
        creditVault.swapCallback(testTrader, address(USDC), 6000e6, address(weth), 2 ether);

        // 4. Add collateral for the trader
        deal(address(lpUSDC), testTrader, 1000e6);
        vm.startPrank(testTrader);
        lpUSDC.approve(address(creditVault), 1000e6);
        ICreditVault.TokenAmountUint[] memory addTokens = new ICreditVault.TokenAmountUint[](1);
        addTokens[0] = ICreditVault.TokenAmountUint({token: address(lpUSDC), amount: 1000e6});
        creditVault.addCollateral(addTokens, testTrader);
        vm.stopPrank();

        // 5. Ensure vault has enough tokens and setup liquidator
        deal(address(USDC), address(creditVault), 6000e6);
        deal(address(weth), address(creditVault), 2 ether);
        deal(address(weth), alice, 1 ether);
        vm.startPrank(alice);
        weth.approve(address(creditVault), 1 ether);
        vm.stopPrank();

        // 6. Prepare and execute liquidation
        ICreditVault.TokenAmountInt[] memory positionUpdates = new ICreditVault.TokenAmountInt[](2);
        positionUpdates[0] = ICreditVault.TokenAmountInt({token: address(USDC), amount: -3000e6});
        positionUpdates[1] = ICreditVault.TokenAmountInt({token: address(weth), amount: 1 ether});

        ICreditVault.TokenAmountUint[] memory claimCollaterals = new ICreditVault.TokenAmountUint[](1);
        claimCollaterals[0] = ICreditVault.TokenAmountUint({token: address(lpUSDC), amount: 500e6});

        ICreditVault.LiquidationRequest memory request = ICreditVault.LiquidationRequest({
            nonce: 0,
            deadline: block.timestamp + 3600,
            trader: testTrader,
            positionUpdates: positionUpdates,
            claimCollaterals: claimCollaterals
        });

        bytes32 digest =
            SignatureUtils.generateLiquidationSignature(request, testLiquidatorRecipient, address(creditVault));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(deployerKey, digest);

        // 7. Execute liquidation
        vm.prank(alice);
        creditVault.liquidate(request, abi.encodePacked(r, s, v));

        // 8. Verify liquidation worked correctly
        // Verify trader's collateral decreased and liquidator received it
        assertEq(creditVault.collateral(testTrader, address(lpUSDC)), 500e6, "Trader should have 500e6 collateral left");
        assertEq(lpUSDC.balanceOf(testLiquidatorRecipient), 500e6, "Liquidator should receive 500e6 collateral");

        // Verify trader's positions were updated
        assertEq(creditVault.positions(testTrader, address(USDC)), 3000e6, "Trader USDC position should be 3000e6");
        assertEq(creditVault.positions(testTrader, address(weth)), -1 ether, "Trader WETH position should be -1 ether");

        // Verify liquidator paid WETH and received USDC
        assertEq(weth.balanceOf(alice), 0, "Liquidator should have paid 1 ether WETH");
        assertEq(USDC.balanceOf(testLiquidatorRecipient), 3000e6, "Liquidator should receive 3000e6 USDC");
    }

    function testEpochUpdateWorksAfterOwnershipTransfer() public {
        // Move time forward to avoid any cooldown
        vm.warp(block.timestamp + EPOCH_UPDATE_INTERVAL + 1);

        // Setup: Set epoch updater through Sentinel
        address testEpochUpdater = makeAddr("testEpochUpdater");

        vm.prank(deployer);
        sentinel.setEpochUpdater(testEpochUpdater);

        // Verify epoch updater is set
        assertEq(creditVault.epochUpdater(), testEpochUpdater, "Epoch updater should be set");

        // Setup LP pool with deposits
        deal(address(USDC), alice, 10_000e6);
        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), 10_000e6);
        lpUSDC.deposit(10_000e6);
        vm.stopPrank();

        // Create a position for halo first via swapCallback
        vm.prank(deployer);
        sentinel.setCreditPool(address(rfqPool), true);

        vm.prank(address(rfqPool));
        creditVault.swapCallback(halo, address(USDC), 5000e6, address(weth), 1 ether);

        // Record initial position before epoch update
        int256 initialPosition = creditVault.positions(halo, address(USDC));

        // Prepare epoch update
        ICreditVault.FundingFeeAmount[] memory feeUpdates = new ICreditVault.FundingFeeAmount[](1);
        feeUpdates[0] = ICreditVault.FundingFeeAmount({token: address(USDC), reserveFee: 100, fundingFee: 50});

        ICreditVault.AccruedFundingFee[] memory accruedFees = new ICreditVault.AccruedFundingFee[](1);
        accruedFees[0] = ICreditVault.AccruedFundingFee({trader: halo, feeUpdates: feeUpdates});

        // Execute epoch update (this should work after ownership transfer)
        vm.prank(testEpochUpdater);
        creditVault.epochUpdate(accruedFees);

        // Verify epoch update worked
        assertEq(creditVault.reserveFees(address(USDC)), 100, "Reserve fees should be accrued");
        assertEq(
            creditVault.lastEpochUpdateTimestamp(halo), block.timestamp, "Last epoch update timestamp should be set"
        );

        // Verify trader's position decreased by total fees (reserveFee + fundingFee)
        assertEq(
            creditVault.positions(halo, address(USDC)),
            initialPosition - 150, // 100 (reserveFee) + 50 (fundingFee)
            "Trader position should decrease by total fees"
        );
    }

    function testWithdrawReserveWorksAfterOwnershipTransfer() public {
        // Move time forward to avoid any cooldown
        vm.warp(block.timestamp + EPOCH_UPDATE_INTERVAL + 1);

        // Setup: Set fee withdrawer through Sentinel
        address testFeeWithdrawer = payable(makeAddr("testFeeWithdrawer"));

        vm.prank(deployer);
        sentinel.setFeeWithdrawer(payable(testFeeWithdrawer));

        // Verify fee withdrawer is set
        assertEq(creditVault.feeWithdrawer(), testFeeWithdrawer, "Fee withdrawer should be set");

        // Setup LP pool and accrue fees first
        deal(address(USDC), alice, 10_000e6);
        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), 10_000e6);
        lpUSDC.deposit(10_000e6);
        vm.stopPrank();

        // Create a position for tokka first via swapCallback
        vm.prank(deployer);
        sentinel.setCreditPool(address(rfqPool), true);

        vm.prank(address(rfqPool));
        creditVault.swapCallback(tokka, address(USDC), 10_000e6, address(weth), 2 ether);

        // Record initial state before epoch update
        int256 initialTraderPosition = creditVault.positions(tokka, address(USDC));
        uint256 initialVaultBalance = USDC.balanceOf(address(creditVault));

        vm.prank(deployer);
        sentinel.setEpochUpdater(deployer);

        // Accrue some fees
        ICreditVault.FundingFeeAmount[] memory feeUpdates = new ICreditVault.FundingFeeAmount[](1);
        feeUpdates[0] = ICreditVault.FundingFeeAmount({token: address(USDC), reserveFee: 100, fundingFee: 50});

        ICreditVault.AccruedFundingFee[] memory accruedFees = new ICreditVault.AccruedFundingFee[](1);
        accruedFees[0] = ICreditVault.AccruedFundingFee({trader: tokka, feeUpdates: feeUpdates});

        vm.prank(deployer);
        creditVault.epochUpdate(accruedFees);

        // Verify epoch update worked correctly
        assertEq(creditVault.reserveFees(address(USDC)), 100, "Reserve fees should be 100 after epoch update");
        assertEq(
            creditVault.positions(tokka, address(USDC)),
            initialTraderPosition - 150, // 100 reserveFee + 50 fundingFee
            "Trader position should decrease by total fees"
        );
        assertEq(
            USDC.balanceOf(address(creditVault)),
            initialVaultBalance,
            "Vault balance should not change after epoch update (fees are internal accounting)"
        );

        // Record initial balances before withdrawal
        uint256 initialWithdrawerBalance = USDC.balanceOf(testFeeWithdrawer);
        uint256 initialReserveFees = creditVault.reserveFees(address(USDC));

        // Execute withdraw reserve (this should work after ownership transfer)
        vm.prank(testFeeWithdrawer);
        creditVault.withdrawReserve(address(USDC), testFeeWithdrawer, 50);

        // Verify withdrawal worked correctly
        assertEq(
            creditVault.reserveFees(address(USDC)), initialReserveFees - 50, "Reserve fees should be reduced by 50"
        );
        assertEq(
            USDC.balanceOf(testFeeWithdrawer), initialWithdrawerBalance + 50, "Fee withdrawer should receive 50 USDC"
        );
        assertEq(
            USDC.balanceOf(address(creditVault)), initialVaultBalance - 50, "Vault balance should decrease by 50 USDC"
        );

        // Test withdrawing remaining fees
        vm.prank(testFeeWithdrawer);
        creditVault.withdrawReserve(address(USDC), testFeeWithdrawer, 50);

        // Verify all reserve fees are withdrawn
        assertEq(creditVault.reserveFees(address(USDC)), 0, "All reserve fees should be withdrawn");
        assertEq(
            USDC.balanceOf(testFeeWithdrawer), initialWithdrawerBalance + 100, "Fee withdrawer should receive total 100"
        );
        assertEq(
            USDC.balanceOf(address(creditVault)),
            initialVaultBalance - 100,
            "Vault balance should decrease by total 100 USDC"
        );
    }

    function testSwapCallbackWorksAfterOwnershipTransfer() public {
        // Setup: Enable RFQ pool through Sentinel
        vm.prank(deployer);
        sentinel.setCreditPool(address(rfqPool), true);

        // Verify pool is enabled
        assertTrue(creditVault.creditPools(address(rfqPool)), "RFQ pool should be enabled");

        // Setup trader
        address testTrader = makeAddr("testTrader");
        vm.prank(deployer);
        sentinel.setTrader(testTrader, testTrader, makeAddr("testRecipient"), true, true);

        // Record initial positions
        int256 initialUSDCPosition = creditVault.positions(testTrader, address(USDC));
        int256 initialWETHPosition = creditVault.positions(testTrader, address(weth));

        // Execute swapCallback (this should work after ownership transfer)
        vm.prank(address(rfqPool));
        creditVault.swapCallback(
            testTrader,
            address(USDC),
            1000e6, // Sell 1000 USDC
            address(weth),
            1 ether // Buy 1 WETH
        );

        // Verify callback worked correctly
        assertEq(
            creditVault.positions(testTrader, address(USDC)),
            initialUSDCPosition + 1000e6,
            "USDC position should increase"
        );
        assertEq(
            creditVault.positions(testTrader, address(weth)),
            initialWETHPosition - 1 ether,
            "WETH position should decrease"
        );
    }

    function testPayWorksAfterOwnershipTransfer() public {
        // Setup: Deposit to LP token
        deal(address(USDC), alice, 10_000e6);
        vm.startPrank(alice);
        USDC.approve(address(lpUSDC), 10_000e6);
        lpUSDC.deposit(10_000e6);
        vm.stopPrank();

        // Record initial balances
        uint256 initialAliceBalance = USDC.balanceOf(alice);
        uint256 initialVaultBalance = USDC.balanceOf(address(creditVault));

        // Execute pay (this should work after ownership transfer)
        uint256 payAmount = 1000e6;
        vm.prank(address(lpUSDC));
        creditVault.pay(alice, payAmount);

        // Verify pay worked correctly
        assertEq(USDC.balanceOf(alice), initialAliceBalance + payAmount, "Alice should receive USDC");
        assertEq(USDC.balanceOf(address(creditVault)), initialVaultBalance - payAmount, "Vault balance should decrease");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Helper function to setup a test pool for emergency pause requirements
    /// @dev Creates, enables, and tracks a test pool in Sentinel
    /// @return testPool The address of the created test pool
    function _setupTestPool() private returns (address testPool) {
        testPool = makeAddr("testPool");

        vm.prank(deployer);
        sentinel.setCreditPool(testPool, true);

        address[] memory pools = new address[](1);
        pools[0] = testPool;

        vm.prank(deployer);
        sentinel.addPools(pools);
    }
}
