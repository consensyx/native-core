// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {NativeRFQPool} from "../src/NativeRFQPool.sol";
import {MockERC20} from "../src/test/MockERC20.sol";

contract DeployPMMPoolScript is Script {
    function run() external {
        // Get deployment configuration from environment
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        string memory chainName = vm.envString("CHAIN_NAME");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        // Load deployment configurations and chain configs
        string memory coreDeployment =
            vm.readFile(string.concat(vm.projectRoot(), "/deployments/", chainName, "/Core.json"));
        string memory config = vm.readFile(string.concat(vm.projectRoot(), "/script/chain-config/", chainName, ".json"));

        // Get WETH address from chain config
        address WETH = abi.decode(vm.parseJson(config, ".WETH"), (address));

        // Get router address from core deployment
        address router = abi.decode(vm.parseJson(coreDeployment, ".NativeRouter"), (address));

        // Initialize PMM treasury
        // TODO: replace actual PMM treasury in production
        address treasury = deployer;

        // Deploy new RFQ Pool with initial configuration
        NativeRFQPool rfqPool = new NativeRFQPool(WETH, router, treasury, "Native RFQ Pool");

        // Set deployer as initial signer
        // TODO: replace actual PMM signer address in production
        address pmmSigner = deployer;
        rfqPool.setSigner(pmmSigner, true);

        console2.log("RFQ Pool deployed to:", address(rfqPool));

        vm.stopBroadcast();
    }
}
