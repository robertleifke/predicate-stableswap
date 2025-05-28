// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
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
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title PredicateSwap
 * @author Predicate Labs
 * @notice A compliant exchange for stablecoins.
 */
contract PredicateSwap is BaseHook, SafeCallback, PredicateClient, Ownable2Step {
    using SafeCast for uint256;
    using PoolIdLibrary for PoolKey;

    error DonationNotAllowed();
    error AuthorizedUserNotAllowed();

    // ----------------------------
    // State Variables
    // ----------------------------
    // IV4Router public router;
    // IPositionManager public posm;
    // mapping(address => bool) public isAuthorizedLP;
    // mapping(address => bool) public isAuthorizedSwapper;

    // ----------------------------
    // Events
    // ----------------------------
    event PolicyUpdated(string policyID);
    event PredicateManagerUpdated(address predicateManager);
    event RouterUpdated(address router);
    event PosmUpdated(address posm);
    event AuthorizedLPAdded(address lp);
    event AuthorizedLPRemoved(address lp);
    event AuthorizedSwapperAdded(address swapper);
    event AuthorizedUserRemoved(address user);

    constructor(
        IPoolManager poolManager_,
        IV4Router router_,
        IPositionManager posm_,
        address serviceManager_
    ) SafeCallback(poolManager_) {
        router = router_;
        posm = posm_;
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
    function _beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // determine inbound/outbound token based on 0->1 or 1->0 swap
        (Currency inputCurrency, Currency outputCurrency) =
            params.zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);

        bool isExactInput = params.amountSpecified < 0;

        // tokens are always swapped 1:1, so use amountSpecified to determine both input and output amounts
        uint256 amount = isExactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);

        // take the input token, as ERC6909, from the PoolManager
        // the debt will be paid by the swapper via the swap router
        // input currency is added to hook's reserves
        poolManager.mint(address(this), inputCurrency.toId(), amount);

        // pay the output token, as ERC6909, to the PoolManager
        // the credit will be forwarded to the swap router, which then forwards it to the swapper
        // output currency is paid from the hook's reserves
        poolManager.burn(address(this), outputCurrency.toId(), amount);

        int128 tokenAmount = amount.toInt128();
        // return the delta to the PoolManager, so it can process the accounting
        // exact input:
        //   specifiedDelta = positive, to offset the input token taken by the hook (negative delta)
        //   unspecifiedDelta = negative, to offset the credit of the output token paid by the hook (positive delta)
        // exact output:
        //   specifiedDelta = negative, to offset the output token paid by the hook (positive delta)
        //   unspecifiedDelta = positive, to offset the input token taken by the hook (negative delta)
        BeforeSwapDelta returnDelta =
            isExactInput ? toBeforeSwapDelta(tokenAmount, -tokenAmount) : toBeforeSwapDelta(-tokenAmount, tokenAmount);

        return (BaseHook.beforeSwap.selector, returnDelta, 0);
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

    /**
     * @notice Sets the router contract used to get the msgSender()
     * @param _router The new router
     */
    function setRouter(
        V4Router _router
    ) external onlyOwner {
        router = _router;
        emit RouterUpdated(address(_router));
    }

    /**
     * @notice Sets the position manager contract
     * @param _posm The new position manager
     */
    function setPosm(
        PositionManager _posm
    ) external onlyOwner {
        posm = _posm;
        emit PosmUpdated(address(_posm));
    }

    /**
     * @notice Adds authorized liquidity providers
     * @param _lps The addresses of the liquidity providers to add
     */
    function addAuthorizedLPs(
        address[] memory _lps
    ) external onlyOwner {
        for (uint256 i = 0; i < _lps.length; i++) {
            isAuthorizedLP[_lps[i]] = true;
            emit AuthorizedLPAdded(_lps[i]);
        }
    }

    /**
     * @notice Removes authorized liquidity providers
     * @param _lps The addresses of the liquidity providers to remove
     */
    function removeAuthorizedLPs(
        address[] memory _lps
    ) external onlyOwner {
        for (uint256 i = 0; i < _lps.length; i++) {
            isAuthorizedLP[_lps[i]] = false;
            emit AuthorizedLPRemoved(_lps[i]);
        }
    }

    /**
     * @notice Adds authorized swappers for swaps to bypass the predicate check
     * @param _users The addresses of the swappers to add
     */
    function addAuthorizedSwapper(
        address[] memory _users
    ) external onlyOwner {
        for (uint256 i = 0; i < _users.length; i++) {
            isAuthorizedSwapper[_users[i]] = true;
            emit AuthorizedSwapperAdded(_users[i]);
        }
    }

    /**
     * @notice Removes authorized swappers from the list
     * @param _users The addresses of the swappers to remove
     */
    function removeAuthorizedSwapper(
        address[] memory _users
    ) external onlyOwner {
        for (uint256 i = 0; i < _users.length; i++) {
            isAuthorizedSwapper[_users[i]] = false;
            emit AuthorizedUserRemoved(_users[i]);
        }
    }
}
