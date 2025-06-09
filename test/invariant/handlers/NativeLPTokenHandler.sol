// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {StdUtils} from "forge-std/StdUtils.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {CommonBase} from "forge-std/Base.sol";
import {NativeLPToken} from "../../../src/NativeLPToken.sol";
import {AddressSet, LibAddressSet} from "../helpers/AddressSet.sol";
import {MockERC20} from "../../../src/test/MockERC20.sol";
import "../../../src/libraries/ConstantsLib.sol";

import {console} from "forge-std/console.sol";

contract NativeLPTokenHandler is CommonBase, StdUtils, StdInvariant {
    using LibAddressSet for AddressSet;

    address public deployer;
    NativeLPToken public lpToken;
    MockERC20 public underlying;

    AddressSet internal _actors;
    AddressSet internal _excludedSenders;

    // Ghost variables
    uint256 public ghost_sumOfShares;
    uint256 public ghost_totalDeposits;
    uint256 public ghost_totalWithdrawals;
    uint256 public ghost_vaultBalance;
    uint256 public ghost_totalUnderlying;

    constructor(address _deployer, NativeLPToken _lpToken) {
        deployer = _deployer;
        lpToken = _lpToken;
        underlying = MockERC20(address(lpToken.underlying()));

        _excludedSenders.add(address(lpToken));
        _excludedSenders.add(address(lpToken.creditVault()));
        _excludedSenders.add(address(lpToken.underlying()));
    }

    function deposit(uint256 amount, address who) public nonExcludedSenders(who) {
        vm.assume(who != address(0));

        // Make sure amount is greater than minDeposit in case minDeposit is 0
        amount = bound(amount, lpToken.minDeposit() + 1, 1000 * 1e6);

        console.log("Handler - msg.sender is:", msg.sender);
        console.log("Handler - vault is:", address(lpToken.creditVault()));
        // Print initial state
        console.log("Before deposit - totalUnderlying:", lpToken.totalUnderlying());
        console.log("Before deposit - ghost_totalUnderlying:", ghost_totalUnderlying);

        uint256 sharesBefore = lpToken.shares(who);
        uint256 totalSharesBefore = lpToken.totalShares();
        bool isFirstDeposit = (totalSharesBefore == 0);

        // Mint tokens for deposit
        vm.prank(deployer);
        underlying.mint(who, amount);

        // Track actor
        _actors.add(who);

        // Execute deposit
        vm.startPrank(who);
        console.log("Before deposit - amount:", amount);
        console.log("Before deposit - shares:", lpToken.shares(who));
        console.log("Before deposit - totalShares:", lpToken.totalShares());
        underlying.approve(address(lpToken), amount);
        uint256 mintedShares = lpToken.deposit(amount);
        console.log("After deposit - mintedShares:", mintedShares);
        console.log("After deposit - shares:", lpToken.shares(who));
        console.log("After deposit - totalShares:", lpToken.totalShares());
        vm.stopPrank();

        // Update ghost variables
        uint256 userSharesGained = lpToken.shares(who) - sharesBefore;
        ghost_sumOfShares += userSharesGained;

        // On first deposit, also track MINIMUM_SHARE minted to address(0)
        if (isFirstDeposit) {
            ghost_sumOfShares += MINIMUM_SHARE;
        }

        ghost_totalDeposits += amount;
        ghost_vaultBalance += amount;
        ghost_totalUnderlying += amount;

        // Print final state
        console.log("After deposit - totalUnderlying:", lpToken.totalUnderlying());
        console.log("After deposit - ghost_totalUnderlying:", ghost_totalUnderlying);
        console.log("Deposit amount:", amount);
    }

    function redeem(uint256 shareAmount, address who) public nonExcludedSenders(who) {
        // Print initial state
        console.log("Before redeem - totalUnderlying:", lpToken.totalUnderlying());
        console.log("Before redeem - ghost_totalUnderlying:", ghost_totalUnderlying);

        // Bound share amount
        uint256 userShares = lpToken.shares(who);
        shareAmount = bound(shareAmount, 1, userShares);

        if (shareAmount == 0) return;

        // Execute redeem
        vm.startPrank(who);
        uint256 underlyingBefore = underlying.balanceOf(who);
        lpToken.redeem(shareAmount);
        uint256 underlyingAfter = underlying.balanceOf(who);
        vm.stopPrank();

        uint256 underlyingAmount = underlyingAfter - underlyingBefore;

        // Update ghost variables
        ghost_sumOfShares -= shareAmount;
        ghost_totalWithdrawals += underlyingAmount;
        ghost_vaultBalance -= underlyingAmount;
        ghost_totalUnderlying -= underlyingAmount;

        // Print final state
        console.log("After redeem - totalUnderlying:", lpToken.totalUnderlying());
        console.log("After redeem - ghost_totalUnderlying:", ghost_totalUnderlying);
        console.log("Redeem amount:", underlyingAmount);
    }

    // Function to print complete state
    function printState() public view {
        console.log("=== Current State ===");
        console.log("LP totalUnderlying:", lpToken.totalUnderlying());
        console.log("Ghost totalUnderlying:", ghost_totalUnderlying);
        console.log("Total deposits:", ghost_totalDeposits);
        console.log("Total withdrawals:", ghost_totalWithdrawals);
        console.log("Vault balance:", underlying.balanceOf(address(lpToken.creditVault())));
        console.log("Ghost vault balance:", ghost_vaultBalance);
        console.log("==================");
    }

    modifier nonExcludedSenders(address sender) {
        require(!_excludedSenders.contains(sender), "Sender is excluded sender");
        _;
    }
}
