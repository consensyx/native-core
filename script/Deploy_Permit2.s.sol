// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {MockERC20} from "../src/test/MockERC20.sol";
import {Permit2Demo} from "../src/test/Permit2Demo.sol";
import {ISignatureTransfer} from "@permit2/interfaces/ISignatureTransfer.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {console2 as console} from "forge-std/console2.sol";

contract Permit2DemoScript is Script {
    // Constants
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // Permit2 specific constants
    bytes32 constant _TYPE_HASH = keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");
    bytes32 constant _HASHED_NAME = keccak256("Permit2");
    bytes32 constant _TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");
    bytes32 constant _PERMIT_TRANSFER_FROM_TYPEHASH = keccak256(
        "PermitTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline)TokenPermissions(address token,uint256 amount)"
    );

    function run() public {
        // Setup private key for signing
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(privateKey);
        address recipient = vm.addr(vm.envUint("PRIVATE_KEY2"));

        // Deploy contracts
        vm.startBroadcast(privateKey);

        MockERC20 token = new MockERC20("Mock Token", "MTK", 6);

        console.log("token address", address(token));
        Permit2Demo permit2Handler = new Permit2Demo();
        console.log("permit2Handler address", address(permit2Handler));
        // Mint tokens to owner
        token.mint(owner, 10_000e6);

        console.log("alice initial token balance", token.balanceOf(owner));
        console.log("recipient initial token balance", token.balanceOf(recipient));

        // Approve Permit2
        token.approve(PERMIT2, type(uint256).max);

        // Prepare permit data
        uint256 amount = 100e6;
        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 1 hours;

        // Create permit struct
        ISignatureTransfer.PermitTransferFrom memory permitData = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: address(token), amount: amount}),
            nonce: nonce,
            deadline: deadline
        });

        // Generate signature
        bytes memory signature = _generateSignature(permitData, address(permit2Handler), privateKey);

        // Execute transfer
        permit2Handler.transferWithPermit2(address(token), amount, recipient, permitData, signature);

        console.log("after transferFrom, alice token balance", token.balanceOf(owner));
        console.log("after transferFrom, recipient token balance", token.balanceOf(recipient));

        vm.stopBroadcast();
    }

    function _generateSignature(
        ISignatureTransfer.PermitTransferFrom memory permit,
        address spender,
        uint256 privateKey
    ) internal view returns (bytes memory) {
        // Hash token permissions
        bytes32 tokenPermissionsHash =
            keccak256(abi.encode(_TOKEN_PERMISSIONS_TYPEHASH, permit.permitted.token, permit.permitted.amount));

        // Generate permit hash
        bytes32 permitHash = keccak256(
            abi.encode(_PERMIT_TRANSFER_FROM_TYPEHASH, tokenPermissionsHash, spender, permit.nonce, permit.deadline)
        );

        // Calculate domain separator
        bytes32 domainSeparator = keccak256(abi.encode(_TYPE_HASH, _HASHED_NAME, block.chainid, PERMIT2));

        // Calculate final digest
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, permitHash));

        // Sign the digest
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);

        // Return signature
        return abi.encodePacked(r, s, v);
    }
}
