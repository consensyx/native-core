// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {LPToken} from "../src/LPToken.sol";
import {console2} from "forge-std/console2.sol";
import {MockERC20} from "../src/test/MockERC20.sol";
import {Utils} from "./Utils.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

contract DeployLPTokenScript is Utils {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        string memory chainName = vm.envString("CHAIN_NAME");
        vm.startBroadcast(deployerPrivateKey);

        // 1. read underlying token from chaing-configs
        // NOTE: Replace the underlying token corresponding to the LP token you want to deploy.
        // IERC20Metadata underlying = IERC20Metadata(abi.decode(_readConfig(chainName, "WETH"), (address)));
        IERC20Metadata underlying = IERC20Metadata(abi.decode(_readConfig(chainName, "STONE"), (address)));
        string memory underlyingName = string.concat("Native-LP: ", underlying.name());
        string memory underlyingSymbol = string.concat("NT-LP-", underlying.symbol());

        // 2. read creditVault address
        string memory coreDeployment = _readDeployment(chainName, "Core");
        address creditVault = abi.decode(vm.parseJson(coreDeployment, ".CreditVault"), (address));

        // 3. deploy LPToken
        LPToken lptoken = new LPToken(underlyingName, underlyingSymbol, address(underlying), creditVault);

        // 4. log the deployed LPToken address
        console2.log("LPToken deployed to:", address(lptoken));
        console2.log("LPToken name:", underlyingName);
        console2.log("LPToken symbol:", underlyingSymbol);

        vm.stopBroadcast();
    }
}
