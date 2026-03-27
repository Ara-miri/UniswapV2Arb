//SPDX-Licence-Identifier: MIT
// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.28;

import {ERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// ─── Mock Uniswap V2 Router ───────────────────────────────────────────────────

contract MockRouter {
    uint256 public rateNumerator;
    uint256 public rateDenominator;

    constructor(uint256 _num, uint256 _den) {
        rateNumerator = _num;
        rateDenominator = _den;
    }

    function getAmountsOut(
        uint256 amountIn,
        address[] calldata path
    ) external view returns (uint256[] memory amounts) {
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        amounts[path.length - 1] = (amountIn * rateNumerator) / rateDenominator;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256,
        address[] calldata path,
        address to,
        uint256
    ) external returns (uint256[] memory amounts) {
        address tokenIn = path[0];
        address tokenOut = path[path.length - 1];
        uint256 amountOut = (amountIn * rateNumerator) / rateDenominator;

        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).transfer(to, amountOut);

        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        amounts[path.length - 1] = amountOut;
    }
}

// ─── Reverting Router (for getAmountOutMin try/catch test) ───────────────────

contract RevertingRouter {
    function getAmountsOut(
        uint256,
        address[] calldata
    ) external pure returns (uint256[] memory) {
        revert("pool does not exist");
    }
}
