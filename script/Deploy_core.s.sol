// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {CreditVault} from "../src/CreditVault.sol";
import {NativeRouter} from "../src/NativeRouter.sol";
import {NativeRFQPool} from "../src/NativeRFQPool.sol";
import {ICreditVault} from "../src/interfaces/ICreditVault.sol";

contract DeployCoreScript is Script {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        string memory chainName = vm.envString("CHAIN_NAME");
        address epochUpdater = vm.envAddress("EPOCH_UPDATER");
        address operator = vm.envAddress("OPERATOR");
        address widgetSigner = vm.envAddress("WIDGET_SIGNER");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Read WETH address
        string memory config = vm.readFile(string.concat(vm.projectRoot(), "/script/chain-config/", chainName, ".json"));
        address WETH = abi.decode(vm.parseJson(config, ".WETH"), (address));

        // 2. Deploy CreditVault
        CreditVault creditVault = new CreditVault();
        console2.log("CreditVault deployed at:", address(creditVault));

        // 3. Deploy Router
        NativeRouter router = new NativeRouter(
            address(creditVault),
            WETH,
            deployer // Initial widget fee signer
        );
        console2.log("Router deployed at:", address(router));

        // 4. Deploy RFQ Pool
        NativeRFQPool rfqPool = new NativeRFQPool(true, WETH, address(router), address(creditVault), "Native RFQ Pool");

        // 5. Set credit vault configuration
        creditVault.setCreditPool(address(rfqPool), true);
        creditVault.setSigner(operator);
        creditVault.setEpochUpdater(epochUpdater);
        creditVault.setFeeWithdrawer(payable(deployer));

        // 6. Set router configuration
        router.setSigner(widgetSigner, true);
        router.setNativePool(address(rfqPool), true);

        // 7. Save deployments
        string memory key = "Core";
        vm.serializeAddress(key, "CreditVault", address(creditVault));
        vm.serializeAddress(key, "NativeRouter", address(router));
        string memory output = vm.serializeAddress(key, "NativeRFQPool", address(rfqPool));

        vm.writeJson(output, string.concat(vm.projectRoot(), "/deployments/", chainName, "/", key, ".json"));

        vm.stopBroadcast();
    }
}
