// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {MockERC20} from "../src/test/MockERC20.sol";
import {console2} from "forge-std/console2.sol";

contract DeployERC20Script is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // 0. set token name and symbol
        // string memory tokenName = "USD Coin";
        string memory tokenName = "StakeStone Ether";
        // 1. set token symbol
        // string memory tokenSymbol = "USDC";
        string memory tokenSymbol = "STONE";

        // 2. set token decimals
        // uint8 tokenDecimals = 6;
        uint8 tokenDecimals = 18;

        MockERC20 erc20Token = new MockERC20(tokenName, tokenSymbol, tokenDecimals);

        console2.log("Token deployed to:", address(erc20Token));
        console2.log("Token name:", tokenName);

        vm.stopBroadcast();
    }
}
