// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "forge-std/Script.sol";

contract Utils is Script {
    function _readDeployment(string memory chainName, string memory fileName) internal view returns (string memory) {
        string memory file = string.concat(vm.projectRoot(), "/deployments/", chainName, "/", fileName, ".json");
        return vm.readFile(file);
    }

    function _writeDeployment(string memory chainName, string memory fileName, string memory content) internal {
        string memory file = string.concat(vm.projectRoot(), "/deployments/", chainName, "/", fileName, ".json");
        vm.writeJson(content, file);
    }

    function _readConfig(string memory chainName, string memory key) internal view returns (bytes memory value) {
        string memory file = string.concat(vm.projectRoot(), "/script/chain-configs/", chainName, ".json");

        string memory configJson = vm.readFile(file);

        return vm.parseJson(configJson, string.concat(".", key));
    }
}
