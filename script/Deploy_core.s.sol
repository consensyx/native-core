// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {CreditVault} from "../src/CreditVault.sol";
import {NativeRouter} from "../src/NativeRouter.sol";
import {NativeRFQPool} from "../src/NativeRFQPool.sol";
import {MockERC20} from "../src/test/MockERC20.sol";
import {ICreditVault} from "../src/interfaces/ICreditVault.sol";

contract DeployCoreScript is Script {
    // Deployment addresses
    address public WETH;
    address public USDC;

    CreditVault public creditVault;
    NativeRouter public router;
    NativeRFQPool public rfqPool;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        string memory chainName = vm.envString("CHAIN_NAME");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Read WETH and USDC address
        string memory config = vm.readFile(string.concat(vm.projectRoot(), "/script/chain-config/", chainName, ".json"));

        WETH = abi.decode(vm.parseJson(config, ".WETH"), (address));
        USDC = abi.decode(vm.parseJson(config, ".USDC"), (address));

        // 2. Deploy CreditVault
        creditVault = new CreditVault();
        console2.log("CreditVault deployed at:", address(creditVault));

        // 3. Deploy Router
        router = new NativeRouter(
            address(creditVault),
            WETH,
            deployer // Initial widget fee signer
        );
        console2.log("Router deployed at:", address(router));

        // 4. Deploy RFQ Pool
        rfqPool = new NativeRFQPool(WETH, address(router), address(creditVault), "Native RFQ Pool");
        rfqPool.setEnableCallback(true);

        // 5 Set credit vault configuration
        creditVault.setCreditPool(address(rfqPool), true);
        creditVault.setSigner(deployer);
        creditVault.setLiquidator(deployer, deployer, true);
        creditVault.setEpochUpdater(deployer);
        creditVault.setFeeWithdrawer(payable(deployer));

        // 6 Set allowance for RFQ Pool
        ICreditVault.TokenAmountUint[] memory allowances = new ICreditVault.TokenAmountUint[](2);
        allowances[0] = ICreditVault.TokenAmountUint({token: USDC, amount: type(uint256).max});
        allowances[1] = ICreditVault.TokenAmountUint({token: WETH, amount: type(uint256).max});
        creditVault.setAllowance(allowances, address(rfqPool));

        // 7 Save deployments
        string memory key = "Core";
        vm.serializeAddress(key, "CreditVault", address(creditVault));
        vm.serializeAddress(key, "NativeRouter", address(router));
        string memory output = vm.serializeAddress(key, "NativeRFQPool", address(rfqPool));

        vm.writeJson(output, string.concat(vm.projectRoot(), "/deployments/", chainName, "/", key, ".json"));

        vm.stopBroadcast();
    }
}
