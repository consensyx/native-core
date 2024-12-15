// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {LPToken} from "../../src/LPToken.sol";
import {LPTokenHandler} from "./handlers/LPTokenHandler.sol";
import {AddressSet} from "./helpers/AddressSet.sol";
import {BaseTest} from "../BaseTest.t.sol";

contract LPTokenInvariants is BaseTest {
    LPToken public lpToken;
    LPTokenHandler public handler;

    function setUp() public override {
        super.setUp();

        lpToken = lpUSDC;
        handler = new LPTokenHandler(deployer, lpUSDC);

        // Target handler for invariant testing
        targetContract(address(handler));

        // Exclude these addresses as transaction senders
        excludeSender(address(lpToken));
        excludeSender(address(creditVault));
        excludeSender(address(USDC));
    }

    /// @notice The sum of all user shares should equal totalShares
    function invariant_sumOfSharesEqualsTotalShares() public view {
        assertEq(handler.ghost_sumOfShares(), lpToken.totalShares(), "Sum of shares != totalShares");
    }

    /// @notice Total underlying should match actual token balance
    function invariant_underlyingBalance() public view {
        assertEq(
            lpToken.underlying().balanceOf(address(lpToken.creditVault())),
            handler.ghost_vaultBalance(),
            "Vault balance tracking mismatch"
        );
        assertEq(
            lpToken.totalUnderlying(),
            lpToken.underlying().balanceOf(address(lpToken.creditVault())),
            "Total underlying mismatch"
        );

        assertEq(lpToken.totalUnderlying(), handler.ghost_totalUnderlying(), "Mismatch in totalUnderlying");
    }

    /// @notice Total supply should match total underlying
    function invariant_totalSupplyMatchesUnderlying() public view {
        assertEq(lpToken.totalSupply(), lpToken.totalUnderlying(), "Supply != underlying");
    }

    /// @notice Total underlying should match net deposits plus yield
    function invariant_underlyingMatchesNetDeposits() public view {
        uint256 netDeposits = handler.ghost_totalDeposits() - handler.ghost_totalWithdrawals();
        // The difference between totalUnderlying and netDeposits should be the accumulated yield
        assertTrue(lpToken.totalUnderlying() >= netDeposits, "Total underlying should be >= net deposits");
    }

    /// @notice Check deposit/withdrawal accounting
    function invariant_depositWithdrawalAccounting() public view {
        // Total withdrawals should never exceed total deposits plus yield
        assertTrue(
            handler.ghost_totalWithdrawals() <= handler.ghost_totalDeposits(), "Withdrawals exceed deposits plus yield"
        );
    }
}
