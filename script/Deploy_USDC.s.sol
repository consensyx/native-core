// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {MockERC20} from "../src/test/MockERC20.sol";
import {console2} from "forge-std/console2.sol";

contract DeployUSDCScript is Script {
    function run() external returns (address) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        MockERC20 USDC = new MockERC20("USD Coin", "USDC", 6);

        console2.log("USDC deployed to:", address(USDC));

        vm.stopBroadcast();
        return address(USDC);
    }
}
