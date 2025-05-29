// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {BaseHook} from "./forks/BaseHook.sol";
import {SafeCallback} from "v4-periphery/src/base/SafeCallback.sol";
import {ImmutableState} from "v4-periphery/src/base/ImmutableState.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";

import {PredicateClient} from "@predicate/contracts/src/examples/wrapper/PredicateClientWrapper.sol";
import {PredicateMessage} from "@predicate/contracts/src/interfaces/IPredicateClient.sol";

/**
 * @title PredicateSwap
 * @author Predicate Labs
 * @notice A compliant exchange for stablecoins.
 */
contract PredicateSwap is BaseHook, SafeCallback, PredicateClient, Ownable {
    using SafeCast for uint256;
    using PoolIdLibrary for PoolKey;

    error PredicateAuthorizationFailed();
    error DonationNotAllowed();
    
    event PolicyUpdated(string policyID);
    event PredicateManagerUpdated(address predicateManager);

    constructor(
        IPoolManager poolManager_,
        address _serviceManager,
        string memory _policyID,
        address _owner
    ) SafeCallback(poolManager_) Ownable(_owner) {
        _initPredicateClient(_serviceManager, _policyID);
    }

    function _poolManager() internal view override returns (IPoolManager) {
        return poolManager;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Constant sum swap via custom accounting, tokens are exchanged 1:1
    function _beforeSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Calculate swap details
        uint256 amount = params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        bool isExactInput = params.amountSpecified < 0;
        
        // Perform the swap accounting
        (Currency inputCurrency, Currency outputCurrency) = params.zeroForOne 
            ? (key.currency0, key.currency1) 
            : (key.currency1, key.currency0);
            
        poolManager.mint(address(this), inputCurrency.toId(), amount);
        poolManager.burn(address(this), outputCurrency.toId(), amount);

        // Authorize the transaction with Predicate
        _validatePredicateAuthorization(sender, key, params, hookData);

        // Return delta
        int128 tokenAmount = amount.toInt128();
        BeforeSwapDelta returnDelta = isExactInput 
            ? toBeforeSwapDelta(tokenAmount, -tokenAmount) 
            : toBeforeSwapDelta(-tokenAmount, tokenAmount);

        return (BaseHook.beforeSwap.selector, returnDelta, 0);
    }

    /// @notice Internal function to validate predicate authorization
    function _validatePredicateAuthorization(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) internal {
        PredicateMessage memory predicateMessage = abi.decode(hookData, (PredicateMessage));

        bytes memory encodeSigAndArgs = abi.encodeWithSignature(
            "_beforeSwap(address,address,address,uint24,int24,address,bool,int256)",
            sender,
            key.currency0,
            key.currency1,
            key.fee,
            key.tickSpacing,
            address(key.hooks),
            params.zeroForOne,
            params.amountSpecified
        );

        if (!_authorizeTransaction(predicateMessage, encodeSigAndArgs, sender, 0)) {
            revert PredicateAuthorizationFailed();
        }
    }

    /// @notice No donations allowed
    function _beforeDonate(
        address sender,
        PoolKey calldata key,
        uint256 amount0,
        uint256 amount1,
        bytes calldata hookData
    ) internal override returns (bytes4) {
        revert DonationNotAllowed();
    }

    /// @notice Implementation of SafeCallback's _unlockCallback
    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        // This function is required by SafeCallback but can be left empty for now
        // as the hook doesn't need to perform any unlock operations
        return "";
    }

    /**
     * @notice Sets the policy ID read by Predicate Operators
     * @param _policyID The new policy ID
     */
    function setPolicy(
        string memory _policyID
    ) external onlyOwner {
        _setPolicy(_policyID);
        emit PolicyUpdated(_policyID);
    }

    /**
     * @notice Sets the predicate manager used to authorize transactions
     * @param _predicateManager The new predicate manager
     */
    function setPredicateManager(
        address _predicateManager
    ) external onlyOwner {
        _setPredicateManager(_predicateManager);
        emit PredicateManagerUpdated(_predicateManager);
    }
}
