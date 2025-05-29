// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

import {Constants} from "./base/Constants.sol";
import {PredicateSwap} from "../src/PredicateSwap.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

/// @notice Mines the address and deploys the PredicateSwap.sol Hook contract
contract PredicateSwapScript is Script, Constants {
    function setUp() public {}

    function run() public {
        // hook contracts must have specific flags encoded in the address
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );

        // Mine a salt that will produce a hook address with the correct flags
        address serviceManager = address(0x1); // Placeholder service manager
        string memory policyID = "default-policy"; // Placeholder policy ID
        address owner = msg.sender; // Script deployer as owner
        
        bytes memory constructorArgs = abi.encode(POOLMANAGER, serviceManager, policyID, owner);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(PredicateSwap).creationCode, constructorArgs);

        // Deploy the hook using CREATE2
        vm.broadcast();
        PredicateSwap predicateSwap = new PredicateSwap{salt: salt}(
            IPoolManager(POOLMANAGER), 
            serviceManager, 
            policyID, 
            owner
        );
        require(address(predicateSwap) == hookAddress, "PredicateSwapScript: hook address mismatch");
    }
}
