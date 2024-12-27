// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {Script} from "forge-std/Script.sol";
import {NativeLPToken} from "../src/NativeLPToken.sol";
import {CreditVault} from "../src/CreditVault.sol";
import {MockERC20} from "../src/test/MockERC20.sol";

import {console2} from "forge-std/console2.sol";

contract DeployLPTokenScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        string memory chainName = vm.envString("CHAIN_NAME");
        vm.startBroadcast(deployerPrivateKey);

        // 1. read underlying token from chain-config
        IERC20Metadata underlying = IERC20Metadata(
            abi.decode(
                vm.parseJson(
                    vm.readFile(string.concat(vm.projectRoot(), "/script/chain-config/", chainName, ".json")), ".USDC"
                ),
                (address)
            )
        );
        string memory underlyingName = string.concat("Native-LP: ", underlying.name());
        string memory underlyingSymbol = string.concat("NT-LP-", underlying.symbol());

        // 2. read creditVault address
        string memory coreDeployment =
            vm.readFile(string.concat(vm.projectRoot(), "/deployments/", chainName, "/Core.json"));

        address creditVault = abi.decode(vm.parseJson(coreDeployment, ".CreditVault"), (address));

        // 3. deploy LPToken
        NativeLPToken lptoken = new NativeLPToken(underlyingName, underlyingSymbol, address(underlying), creditVault);

        // 4. log the deployed LPToken address
        console2.log("LPToken deployed to:", address(lptoken));
        console2.log("LPToken name:", underlyingName);
        console2.log("LPToken symbol:", underlyingSymbol);

        // 5. support the NativeLPToken in creditVault
        CreditVault(creditVault).supportMarket(lptoken);

        vm.stopBroadcast();
    }
}
