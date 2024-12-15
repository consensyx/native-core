// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {LPToken} from "../src/LPToken.sol";
import {NativeRFQPool} from "../src/NativeRFQPool.sol";
import {console2} from "forge-std/console2.sol";
import {MockERC20} from "../src/test/MockERC20.sol";
import {Utils} from "./Utils.sol";

contract DeployPMMPoolScript is Utils {
    function run() external {
        // Get deployment configuration from environment
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        string memory chainName = vm.envString("CHAIN_NAME");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        // Load deployment configurations and chain-specific settings
        string memory coreDeployment = _readDeployment(chainName, "Core");
        string memory chainConfigs =
            vm.readFile(string.concat(vm.projectRoot(), "/script/chain-configs/", chainName, ".json"));

        // Get WETH address from chain config
        address WETH = abi.decode(vm.parseJson(chainConfigs, ".WETH"), (address));

        // Get router address from core deployment
        // Note: creditVault is currently commented out as it's not being used
        address router = abi.decode(vm.parseJson(coreDeployment, ".NativeRouter"), (address));

        // Initialize PMM treasury (currently set to deployer address)
        // TODO: replace with actual PMM treasury address in production
        address pmmtreasury = deployer;

        // Deploy new RFQ Pool with initial configuration
        NativeRFQPool rfqPool = new NativeRFQPool(
            WETH, // wrapped ETH address
            router, // router contract address
            pmmtreasury, // treasury address
            "Native RFQ Pool" // pool name
        );

        // Set deployer as initial signer
        rfqPool.setSigner(deployer, true);
        // Note: Callback is currently disabled
        // rfqPool.setEnableCallback(true);

        console2.log("RFQ Pool deployed to:", address(rfqPool));

        vm.stopBroadcast();
    }
}
