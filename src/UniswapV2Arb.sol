//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV2Router} from "./interfaces/UniswapInterfaces.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title UniswapV2Arb
/// @notice Detects and executes arbitrage opportunities across Uniswap V2 compatible DEXes.
/// @dev Supports 2-hop (dualDexTrade), 3-hop (triDexTrade), and 4-hop single-router
///      (tradePath) trades. findPath scans registered ArbPath structs on-chain to find
///      profitable routes. All trade functions are restricted to the owner.
contract UniswapV2Arb is Ownable {
    // SafeERC20 handles tokens with non-standard approve() behavior such as USDT,
    // which does not return a bool and causes a silent revert when decoded as one.
    using SafeERC20 for IERC20;

    /// @notice List of registered router addresses available for swaps.
    address[] public routers;

    /// @notice List of registered arbitrage paths scanned by findPath().
    ArbPath[] public paths;

    /// @notice Maps a router address to its registration status.
    /// @dev Enables O(1) validation in swap() instead of iterating the routers array.
    mapping(address => bool) public isRegisteredRouter;

    /// @notice Represents a 4-hop arbitrage path for use with findPath() and tradePath().
    /// @dev Route: baseAsset → token1 → stable → token2 → baseAsset
    struct ArbPath {
        address token1;
        address stable;
        address token2;
    }

    // Thrown when a trade completes without making a profit.
    error UniswapV2Arb_NoProfitMade();

    // Thrown when a zero amount is passed to an estimate function.
    error UniswapV2Arb_ZeroInputAmount();

    // Thrown when swap() is called with an unregistered router.
    // router The unregistered router address that was passed.
    error UniswapV2Arb_RouterNotRegistered(address router);

    // Thrown when addRouters() is called with an already registered router.
    // router The duplicate router address that was passed.
    error UniswapV2Arb_RouterAlreadyRegistered(address router);

    /// @param _owner The address that will own this contract and have exclusive trade access.
    constructor(address _owner) Ownable(_owner) {}

    /// @notice Registers one or more routers for use in swaps.
    /// @dev Routers must be registered before they can be passed to any trade function.
    ///      Uses isRegisteredRouter mapping for O(1) duplicate detection.
    ///      Uses unchecked increment to save ~30 gas per iteration.
    /// @param _routers Array of router addresses to register.
    function addRouters(address[] calldata _routers) external onlyOwner {
        for (uint i = 0; i < _routers.length; ) {
            if (isRegisteredRouter[_routers[i]])
                revert UniswapV2Arb_RouterAlreadyRegistered(_routers[i]);
            isRegisteredRouter[_routers[i]] = true;
            routers.push(_routers[i]);
            unchecked {
                ++i; // saves ~30 gas per iteration vs i++
            }
        }
    }

    /// @notice Registers a 4-hop arbitrage path for use with findPath().
    /// @dev Route: baseAsset → _token1 → _stable → _token2 → baseAsset.
    /// @param _token1 The first intermediate token.
    /// @param _stable The stable token used as the second intermediate.
    /// @param _token2 The third intermediate token before returning to the base asset.
    function addPath(
        address _token1,
        address _stable,
        address _token2
    ) external onlyOwner {
        paths.push(ArbPath(_token1, _stable, _token2));
    }

    /// @notice Executes a single token swap on a registered router.
    /// @dev Private — called internally by dualDexTrade, triDexTrade, and tradePath.
    ///      Validates router registration before proceeding.
    ///      Uses forceApprove to safely handle USDT and other non-standard ERC20 tokens
    ///      that do not return a bool from approve(), or that revert when a non-zero
    ///      allowance is approved without first resetting to zero.
    ///      amountOutMin is set to 1 — there is no slippage protection.
    /// @param router The registered router to execute the swap on.
    /// @param _tokenIn The token to sell.
    /// @param _tokenOut The token to buy.
    /// @param _amount The amount of _tokenIn to swap.
    function swap(
        address router,
        address _tokenIn,
        address _tokenOut,
        uint256 _amount
    ) private {
        if (!isRegisteredRouter[router])
            revert UniswapV2Arb_RouterNotRegistered(router);

        IERC20(_tokenIn).forceApprove(router, _amount);
        address[] memory path;
        path = new address[](2);
        path[0] = _tokenIn;
        path[1] = _tokenOut;
        uint deadline = block.timestamp + 300;
        IUniswapV2Router(router).swapExactTokensForTokens(
            _amount,
            1,
            path,
            address(this),
            deadline
        );
    }

    /// @notice Returns the expected output amount for a swap on a given router.
    /// @dev Wraps getAmountsOut in a try/catch so missing or illiquid pools
    ///      return 0 instead of reverting. Safe to use in view estimation loops.
    /// @param router The router to query.
    /// @param _tokenIn The input token address.
    /// @param _tokenOut The output token address.
    /// @param _amount The input amount.
    /// @return The expected output amount, or 0 if the pool does not exist or has no liquidity.
    function getAmountOutMin(
        address router,
        address _tokenIn,
        address _tokenOut,
        uint256 _amount
    ) public view returns (uint256) {
        address[] memory path;
        path = new address[](2);
        path[0] = _tokenIn;
        path[1] = _tokenOut;
        uint256 result = 0;
        try IUniswapV2Router(router).getAmountsOut(_amount, path) returns (
            uint256[] memory amountOutMins
        ) {
            result = amountOutMins[path.length - 1];
        } catch {}
        return result;
    }

    /// @notice Estimates the return of a 2-hop arbitrage trade across two routers.
    /// @dev Does not execute any swap. Call this before dualDexTrade to check profitability.
    ///      Route: _token1 →[_router1]→ _token2 →[_router2]→ _token1
    /// @param _router1 Router for leg 1 (_token1 → _token2).
    /// @param _router2 Router for leg 2 (_token2 → _token1).
    /// @param _token1 The base token (start and end of the route).
    /// @param _token2 The intermediate token.
    /// @param _amount The input amount of _token1.
    /// @return The estimated amount of _token1 received after both swaps.
    function estimateDualDexTrade(
        address _router1,
        address _router2,
        address _token1,
        address _token2,
        uint256 _amount
    ) external view returns (uint256) {
        uint256 amtBack1 = getAmountOutMin(_router1, _token1, _token2, _amount);
        uint256 amtBack2 = getAmountOutMin(
            _router2,
            _token2,
            _token1,
            amtBack1
        );
        return amtBack2;
    }

    /// @notice Executes a 2-hop arbitrage trade across two routers.
    /// @dev Snapshots the contract's _token2 balance before leg 1 and only trades
    ///      the newly acquired delta in leg 2, leaving any pre-existing _token2
    ///      balance untouched. Reverts if endBalance <= startBalance.
    ///      Route: _token1 →[_router1]→ _token2 →[_router2]→ _token1
    /// @param _router1 Router for leg 1.
    /// @param _router2 Router for leg 2.
    /// @param _token1 The base token.
    /// @param _token2 The intermediate token.
    /// @param _amount The amount of _token1 to trade.
    function dualDexTrade(
        address _router1,
        address _router2,
        address _token1,
        address _token2,
        uint256 _amount
    ) external onlyOwner {
        uint startBalance = IERC20(_token1).balanceOf(address(this));
        uint token2InitialBalance = IERC20(_token2).balanceOf(address(this));
        swap(_router1, _token1, _token2, _amount);
        uint token2Balance = IERC20(_token2).balanceOf(address(this));

        // Only trade the newly acquired _token2, not any pre-existing balance
        uint tradeableAmount = token2Balance - token2InitialBalance;
        swap(_router2, _token2, _token1, tradeableAmount);
        uint endBalance = IERC20(_token1).balanceOf(address(this));

        if (endBalance <= startBalance) revert UniswapV2Arb_NoProfitMade();
    }

    /// @notice Estimates the return of a 3-hop arbitrage trade across three routers.
    /// @dev Does not execute any swap. Call this before triDexTrade to check profitability.
    ///      Reverts if _amount is zero to prevent meaningless estimates.
    ///      Route: _token1 →[_router1]→ _token2 →[_router2]→ _token3 →[_router3]→ _token1
    /// @param _router1 Router for leg 1.
    /// @param _router2 Router for leg 2.
    /// @param _router3 Router for leg 3.
    /// @param _token1 The base token (start and end of the route).
    /// @param _token2 The first intermediate token.
    /// @param _token3 The second intermediate token.
    /// @param _amount The input amount of _token1.
    /// @return The estimated amount of _token1 received after all three swaps.
    function estimateTriDexTrade(
        address _router1,
        address _router2,
        address _router3,
        address _token1,
        address _token2,
        address _token3,
        uint256 _amount
    ) external view returns (uint256) {
        if (_amount == 0) revert UniswapV2Arb_ZeroInputAmount();
        uint256 amt = getAmountOutMin(_router1, _token1, _token2, _amount);
        amt = getAmountOutMin(_router2, _token2, _token3, amt);
        amt = getAmountOutMin(_router3, _token3, _token1, amt);
        return amt;
    }

    /// @notice Executes a 3-hop arbitrage trade across three routers.
    /// @dev Each leg snapshots the intermediate token balance before swapping and
    ///      only trades the delta, leaving pre-existing balances untouched.
    ///      Reverts if endBalance <= startBalance.
    ///      Route: _token1 →[_router1]→ _token2 →[_router2]→ _token3 →[_router3]→ _token1
    /// @param _router1 Router for leg 1.
    /// @param _router2 Router for leg 2.
    /// @param _router3 Router for leg 3.
    /// @param _token1 The base token.
    /// @param _token2 The first intermediate token.
    /// @param _token3 The second intermediate token.
    /// @param _amount The amount of _token1 to trade.
    function triDexTrade(
        address _router1,
        address _router2,
        address _router3,
        address _token1,
        address _token2,
        address _token3,
        uint256 _amount
    ) external onlyOwner {
        uint startBalance = IERC20(_token1).balanceOf(address(this));

        uint token2InitialBalance = IERC20(_token2).balanceOf(address(this));
        swap(_router1, _token1, _token2, _amount);

        // Only trade the delta acquired in leg 1
        uint tradeableAmount2 = IERC20(_token2).balanceOf(address(this)) -
            token2InitialBalance;

        uint token3InitialBalance = IERC20(_token3).balanceOf(address(this));
        swap(_router2, _token2, _token3, tradeableAmount2);

        // Only trade the delta acquired in leg 2
        uint tradeableAmount3 = IERC20(_token3).balanceOf(address(this)) -
            token3InitialBalance;

        swap(_router3, _token3, _token1, tradeableAmount3);
        uint endBalance = IERC20(_token1).balanceOf(address(this));

        if (endBalance <= startBalance) revert UniswapV2Arb_NoProfitMade();
    }

    /// @notice Scans registered ArbPath entries to find a profitable 4-hop route.
    /// @dev Simulates each path without executing any swaps. Returns on the first
    ///      profitable path found. Returns all zeros if no profitable path exists.
    ///      Route per path: _baseAsset → token1 → stable → token2 → _baseAsset
    /// @param _router The router to simulate all hops on.
    /// @param _baseAsset The starting and ending token.
    /// @param _amount The input amount of _baseAsset.
    /// @return amtBack The estimated return if a profitable path is found, else 0.
    /// @return token1 The first intermediate token of the profitable path, else address(0).
    /// @return stable The stable token of the profitable path, else address(0).
    /// @return token2 The third intermediate token of the profitable path, else address(0).
    function findPath(
        address _router,
        address _baseAsset,
        uint256 _amount
    ) external view returns (uint256, address, address, address) {
        for (uint i = 0; i < paths.length; i++) {
            uint256 amt = getAmountOutMin(
                _router,
                _baseAsset,
                paths[i].token1,
                _amount
            );
            amt = getAmountOutMin(
                _router,
                paths[i].token1,
                paths[i].stable,
                amt
            );
            amt = getAmountOutMin(
                _router,
                paths[i].stable,
                paths[i].token2,
                amt
            );
            amt = getAmountOutMin(_router, paths[i].token2, _baseAsset, amt);
            if (amt > _amount) {
                return (amt, paths[i].token1, paths[i].stable, paths[i].token2);
            }
        }
        return (0, address(0), address(0), address(0));
    }

    /// @notice Executes a 4-hop arbitrage trade on a single router.
    /// @dev All four swaps go through the same router — cannot exploit cross-DEX
    ///      price differences. Each leg only trades the delta from the previous leg.
    ///      Reverts if endBalance <= startBalance.
    ///      Route: _token1 → _token2 → _token3 → _token4 → _token1 (all on _router1)
    /// @param _router1 The router to use for all four hops.
    /// @param _token1 The base token (start and end of the route).
    /// @param _token2 First intermediate token.
    /// @param _token3 Second intermediate token.
    /// @param _token4 Third intermediate token.
    /// @param _amount The amount of _token1 to trade.
    function tradePath(
        address _router1,
        address _token1,
        address _token2,
        address _token3,
        address _token4,
        uint256 _amount
    ) external onlyOwner {
        uint startBalance = IERC20(_token1).balanceOf(address(this));
        uint token2InitialBalance = IERC20(_token2).balanceOf(address(this));
        uint token3InitialBalance = IERC20(_token3).balanceOf(address(this));
        uint token4InitialBalance = IERC20(_token4).balanceOf(address(this));
        swap(_router1, _token1, _token2, _amount);
        uint tradeableAmount2 = IERC20(_token2).balanceOf(address(this)) -
            token2InitialBalance;
        swap(_router1, _token2, _token3, tradeableAmount2);
        uint tradeableAmount3 = IERC20(_token3).balanceOf(address(this)) -
            token3InitialBalance;
        swap(_router1, _token3, _token4, tradeableAmount3);
        uint tradeableAmount4 = IERC20(_token4).balanceOf(address(this)) -
            token4InitialBalance;
        swap(_router1, _token4, _token1, tradeableAmount4);
        uint endBalance = IERC20(_token1).balanceOf(address(this));

        if (endBalance <= startBalance) revert UniswapV2Arb_NoProfitMade();
    }

    /// @notice Returns the ERC20 token balance held by this contract.
    /// @param _tokenContractAddress The ERC20 token to check.
    /// @return The contract's balance of the specified token.
    function getBalance(
        address _tokenContractAddress
    ) external view returns (uint256) {
        uint balance = IERC20(_tokenContractAddress).balanceOf(address(this));
        return balance;
    }

    /// @notice Returns the full list of registered router addresses.
    /// @dev The public routers array generates a routers(uint256) index getter automatically,
    ///      but not a full-array getter — this function fills that gap for off-chain consumers.
    /// @return Array of all registered router addresses.
    function getRouters() external view returns (address[] memory) {
        return routers;
    }

    /// @notice Returns the number of registered arbitrage paths.
    /// @return The length of the paths array.
    function pathsLength() external view returns (uint256) {
        return paths.length;
    }

    /// @notice Withdraws all ETH held by this contract to the owner.
    function recoverEth() external onlyOwner {
        payable(msg.sender).transfer(address(this).balance);
    }

    /// @notice Withdraws the entire balance of an ERC20 token to the owner.
    /// @dev Used to recover tokens sent directly to the contract or left after a trade.
    /// @param tokenAddress The ERC20 token to recover.
    function recoverTokens(address tokenAddress) external onlyOwner {
        IERC20 token = IERC20(tokenAddress);
        token.transfer(msg.sender, token.balanceOf(address(this)));
    }
}
