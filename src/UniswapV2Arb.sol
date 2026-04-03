//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV2Router} from "./interfaces/UniswapInterfaces.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract UniswapV2Arb is Ownable {
    // To use for approval of USDT (or other tokens with non-standard approval behavior)
    using SafeERC20 for IERC20;
    address[] public routers;
    ArbPath[] public paths;

    mapping(address => bool) public isRegisteredRouter;

    struct ArbPath {
        address token1;
        address stable;
        address token2;
    }

    error UniswapV2Arb_NoProfitMade();
    error UniswapV2Arb_ZeroInputAmount();
    error UniswapV2Arb_RouterNotRegistered(address router);
    error UniswapV2Arb_RouterAlreadyRegistered(address router);

    constructor(address _owner) Ownable(_owner) {}

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

    function addPath(
        address _token1,
        address _stable,
        address _token2
    ) external onlyOwner {
        paths.push(ArbPath(_token1, _stable, _token2));
    }

    function swap(
        address router,
        address _tokenIn,
        address _tokenOut,
        uint256 _amount
    ) private {
        if (!isRegisteredRouter[router])
            revert UniswapV2Arb_RouterNotRegistered(router);

        IERC20(_tokenIn).forceApprove(router, _amount); // handles USDT's non-standard approve
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
        uint tradeableAmount = token2Balance - token2InitialBalance;
        swap(_router2, _token2, _token1, tradeableAmount);
        uint endBalance = IERC20(_token1).balanceOf(address(this));

        if (endBalance <= startBalance) revert UniswapV2Arb_NoProfitMade();
    }

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
        uint tradeableAmount2 = IERC20(_token2).balanceOf(address(this)) -
            token2InitialBalance;

        uint token3InitialBalance = IERC20(_token3).balanceOf(address(this));
        swap(_router2, _token2, _token3, tradeableAmount2);
        uint tradeableAmount3 = IERC20(_token3).balanceOf(address(this)) -
            token3InitialBalance;

        swap(_router3, _token3, _token1, tradeableAmount3);
        uint endBalance = IERC20(_token1).balanceOf(address(this));

        if (endBalance <= startBalance) revert UniswapV2Arb_NoProfitMade();
    }

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

    function getBalance(
        address _tokenContractAddress
    ) external view returns (uint256) {
        uint balance = IERC20(_tokenContractAddress).balanceOf(address(this));
        return balance;
    }

    function getRouters() external view returns (address[] memory) {
        return routers;
    }

    function pathsLength() external view returns (uint256) {
        return paths.length;
    }

    function recoverEth() external onlyOwner {
        payable(msg.sender).transfer(address(this).balance);
    }

    function recoverTokens(address tokenAddress) external onlyOwner {
        IERC20 token = IERC20(tokenAddress);
        token.transfer(msg.sender, token.balanceOf(address(this)));
    }
}
