// SPDX-License-Identifier: MIT
// Tells the Solidity compiler to compile only from v0.8.13 to v0.9.0
pragma solidity ^0.8.12;

import {PredicateClient} from "@predicate/contracts/src/mixins/PredicateClient.sol";
import {PredicateMessage} from "@predicate/contracts/src/interfaces/IPredicateClient.sol";
import {IPredicateManager} from "@predicate/contracts/src/interfaces/IPredicateManager.sol";

contract PredicateClientWrapper is PredicateClient {
    constructor(address _serviceManager, string memory _policyID) {
        _initPredicateClient(_serviceManager, _policyID);
    }
    
    /* TODO: Handle Specific Function Calls */ 


		// functions to complete the PredicateClient interface
    function setPolicy(
        string memory _policyID
    ) external {
        _setPolicy(_policyID);
    }

    function setPredicateManager(
        address _predicateManager
    ) public {
        _setPredicateManager(_predicateManager);
    }
}
