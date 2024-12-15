// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {WETH9} from "../src/test/WETH9.sol";
import {console2} from "forge-std/console2.sol";

contract DeployWETH9 is Script {
    function run() external returns (WETH9) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        WETH9 weth = new WETH9();

        console2.log("WETH9 deployed to:", address(weth));

        vm.stopBroadcast();
        return weth;
    }
}
