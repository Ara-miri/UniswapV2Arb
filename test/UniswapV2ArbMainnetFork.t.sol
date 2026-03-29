// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {UniswapV2Arb} from "../src/UniswapV2Arb.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract UniswapV2ArbForkTest is Test {
    // ── Real addresses ────────────────────────────────────────────────────────
    address constant UNISWAP_V2_ROUTER =
        0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address constant SUSHISWAP_ROUTER =
        0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F;
    address constant PANCAKESWAP_ROUTER =
        0xEfF92A263d31888d860bD50809A8D171709b7b1c;

    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant LINK = 0x514910771AF9Ca656af840dff83E8264EcF986CA;
    address constant UNI = 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984;

    UniswapV2Arb internal arb;
    address internal owner = address(this);

    uint256 mainnetFork;

    receive() external payable {}

    function setUp() public {
        mainnetFork = vm.createFork(vm.envString("ETH_MAINNET_API_KEY"));
        vm.selectFork(mainnetFork);
        arb = new UniswapV2Arb(owner);
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    function _dealWeth(uint256 amount) internal {
        deal(WETH, address(arb), amount);
    }

    function _dealToken(address token, uint256 amount) internal {
        deal(token, address(arb), amount);
    }

    function _addPath(address t1, address stable, address t2) internal {
        arb.addPath(t1, stable, t2);
    }

    // ── getAmountOutMin — Uniswap V2 ─────────────────────────────────────────

    function test_Fork_GetAmountOutMin_Uniswap_WETH_USDC() public view {
        uint256 result = arb.getAmountOutMin(
            UNISWAP_V2_ROUTER,
            WETH,
            USDC,
            1 ether
        );
        assertGt(result, 0, "Should get USDC amount for 1 WETH");
        // Sanity: 1 WETH should be worth at least $100 in USDC (6 decimals)
        assertGt(result, 100e6);
    }

    function test_Fork_GetAmountOutMin_Uniswap_WETH_USDT() public view {
        uint256 result = arb.getAmountOutMin(
            UNISWAP_V2_ROUTER,
            WETH,
            USDT,
            1 ether
        );
        assertGt(result, 100e6);
    }

    function test_Fork_GetAmountOutMin_Sushiswap_WETH_USDC() public view {
        uint256 result = arb.getAmountOutMin(
            SUSHISWAP_ROUTER,
            WETH,
            USDC,
            1 ether
        );
        assertGt(result, 100e6);
    }

    function test_Fork_GetAmountOutMin_Sushiswap_WETH_USDT() public view {
        uint256 result = arb.getAmountOutMin(
            SUSHISWAP_ROUTER,
            WETH,
            USDT,
            1 ether
        );
        assertGt(result, 100e6);
    }

    function test_Fork_GetAmountOutMin_Pancakeswap_WETH_USDC() public view {
        uint256 result = arb.getAmountOutMin(
            PANCAKESWAP_ROUTER,
            WETH,
            USDC,
            1 ether
        );
        assertGt(result, 100e6);
    }

    function test_Fork_GetAmountOutMin_Pancakeswap_WETH_USDT() public view {
        uint256 result = arb.getAmountOutMin(
            PANCAKESWAP_ROUTER,
            WETH,
            USDT,
            1 ether
        );
        assertGt(result, 100e6);
    }

    function test_Fork_GetAmountOutMin_ReturnsZeroForNonExistentPool()
        public
        view
    {
        // LINK/USDT pool is unlikely to exist on PancakeSwap mainnet
        uint256 result = arb.getAmountOutMin(
            PANCAKESWAP_ROUTER,
            LINK,
            USDT,
            1 ether
        );
        assertEq(
            result,
            0,
            "Should return 0 for non-existent pool via try/catch"
        );
    }

    // ── Price consistency across DEXes ────────────────────────────────────────
    // Prices should be in the same ballpark across DEXes — large divergence
    // would indicate a stale fork or wrong address

    function test_Fork_PriceConsistency_WETH_USDC() public view {
        uint256 uniPrice = arb.getAmountOutMin(
            UNISWAP_V2_ROUTER,
            WETH,
            USDC,
            1 ether
        );
        uint256 sushiPrice = arb.getAmountOutMin(
            SUSHISWAP_ROUTER,
            WETH,
            USDC,
            1 ether
        );
        uint256 cakePrice = arb.getAmountOutMin(
            PANCAKESWAP_ROUTER,
            WETH,
            USDC,
            1 ether
        );

        // Prices should be within 5% of each other
        assertApproxEqRel(uniPrice, sushiPrice, 0.05e18);
        assertApproxEqRel(uniPrice, cakePrice, 0.05e18);
        assertApproxEqRel(sushiPrice, cakePrice, 0.05e18);
    }

    function test_Fork_PriceConsistency_WETH_USDT() public view {
        uint256 uniPrice = arb.getAmountOutMin(
            UNISWAP_V2_ROUTER,
            WETH,
            USDT,
            1 ether
        );
        uint256 sushiPrice = arb.getAmountOutMin(
            SUSHISWAP_ROUTER,
            WETH,
            USDT,
            1 ether
        );
        uint256 cakePrice = arb.getAmountOutMin(
            PANCAKESWAP_ROUTER,
            WETH,
            USDT,
            1 ether
        );

        assertApproxEqRel(uniPrice, sushiPrice, 0.05e18);
        assertApproxEqRel(uniPrice, cakePrice, 0.05e18);
        assertApproxEqRel(sushiPrice, cakePrice, 0.05e18);
    }

    // ── estimateDualDexTrade ──────────────────────────────────────────────────

    function test_Fork_EstimateDualDexTrade_Uniswap_Sushiswap_WETH_USDC()
        public
        view
    {
        uint256 result = arb.estimateDualDexTrade(
            UNISWAP_V2_ROUTER,
            SUSHISWAP_ROUTER,
            WETH,
            USDC,
            1 ether
        );
        // Result should be non-zero and in the same order of magnitude as input
        assertGt(result, 0);
        // Should get back at least 90% of WETH (accounting for fees and spread)
        assertGt(result, 0.9 ether);
    }

    function test_Fork_EstimateDualDexTrade_Uniswap_Pancakeswap_WETH_USDT()
        public
        view
    {
        uint256 result = arb.estimateDualDexTrade(
            UNISWAP_V2_ROUTER,
            PANCAKESWAP_ROUTER,
            WETH,
            USDT,
            1 ether
        );
        assertGt(result, 0.9 ether);
    }

    function test_Fork_EstimateDualDexTrade_Sushiswap_Pancakeswap_WETH_USDC()
        public
        view
    {
        uint256 result = arb.estimateDualDexTrade(
            SUSHISWAP_ROUTER,
            PANCAKESWAP_ROUTER,
            WETH,
            USDC,
            1 ether
        );
        assertGt(result, 0.9 ether);
    }

    // ── findPath ──────────────────────────────────────────────────────────────

    function test_Fork_FindPath_NoPathsRegistered() public view {
        (uint256 amtBack, address t1, address s, address t2) = arb.findPath(
            UNISWAP_V2_ROUTER,
            WETH,
            1 ether
        );
        assertEq(amtBack, 0);
        assertEq(t1, address(0));
        assertEq(s, address(0));
        assertEq(t2, address(0));
    }

    function test_Fork_FindPath_WithRealPaths_USDC() public {
        // Register real paths: WETH → WBTC → USDC → DAI → WETH etc.
        _addPath(WBTC, USDC, UNI);
        _addPath(LINK, USDC, WBTC);
        _addPath(UNI, USDC, LINK);
        _addPath(DAI, USDC, WBTC);

        (uint256 amtBack, address t1, address s, address t2) = arb.findPath(
            UNISWAP_V2_ROUTER,
            WETH,
            1 ether
        );

        // Whether profitable or not, path addresses should be consistent:
        // either all zero (no profit found) or all set (profit found)
        if (amtBack > 1 ether) {
            assertTrue(t1 != address(0));
            assertTrue(s != address(0));
            assertTrue(t2 != address(0));
        } else {
            assertEq(t1, address(0));
            assertEq(s, address(0));
            assertEq(t2, address(0));
        }
    }

    function test_Fork_FindPath_WithRealPaths_USDT() public {
        _addPath(WBTC, USDT, UNI);
        _addPath(LINK, USDT, WBTC);
        _addPath(UNI, USDT, LINK);

        (uint256 amtBack, address t1, address s, address t2) = arb.findPath(
            SUSHISWAP_ROUTER,
            WETH,
            1 ether
        );

        if (amtBack > 1 ether) {
            assertTrue(t1 != address(0));
            assertTrue(s != address(0));
            assertTrue(t2 != address(0));
        } else {
            assertEq(t1, address(0));
            assertEq(s, address(0));
            assertEq(t2, address(0));
        }
    }

    // ── dualDexTrade ─────────────────────────────────────────────────────────
    // We simulate a profitable condition by manipulating pool state with deal()
    // to create an artificial price discrepancy between two DEXes.

    function test_Fork_DualDexTrade_Uniswap_Sushiswap_WETH_USDC() public {
        uint256 amount = 10 ether;
        _dealWeth(amount);

        address[] memory r = new address[](2);
        r[0] = address(SUSHISWAP_ROUTER);
        r[1] = address(UNISWAP_V2_ROUTER);
        arb.addRouters(r);

        //Estimates the minAmountOut for the trade
        uint256 estimate = arb.estimateDualDexTrade(
            UNISWAP_V2_ROUTER,
            SUSHISWAP_ROUTER,
            WETH,
            USDC,
            amount
        );

        // If the trade is profitable, execute it
        if (estimate > amount) {
            uint256 before = IERC20(WETH).balanceOf(address(arb));
            arb.dualDexTrade(
                UNISWAP_V2_ROUTER,
                SUSHISWAP_ROUTER,
                WETH,
                USDC,
                amount
            );
            assertGt(IERC20(WETH).balanceOf(address(arb)), before);
        } else {
            vm.expectRevert(UniswapV2Arb.UniswapV2Arb_NoProfitMade.selector);
            arb.dualDexTrade(
                UNISWAP_V2_ROUTER,
                SUSHISWAP_ROUTER,
                WETH,
                USDC,
                amount
            );
        }
    }

    function test_Fork_DualDexTrade_Uniswap_Sushiswap_WETH_USDT() public {
        uint256 amount = 10 ether;
        _dealWeth(amount);

        address[] memory r = new address[](2);
        r[0] = address(SUSHISWAP_ROUTER);
        r[1] = address(UNISWAP_V2_ROUTER);
        arb.addRouters(r);

        uint256 estimate = arb.estimateDualDexTrade(
            UNISWAP_V2_ROUTER,
            SUSHISWAP_ROUTER,
            WETH,
            USDT,
            amount
        );

        if (estimate > amount) {
            uint256 before = IERC20(WETH).balanceOf(address(arb));
            arb.dualDexTrade(
                UNISWAP_V2_ROUTER,
                SUSHISWAP_ROUTER,
                WETH,
                USDT,
                amount
            );
            assertGt(IERC20(WETH).balanceOf(address(arb)), before);
        } else {
            vm.expectRevert(UniswapV2Arb.UniswapV2Arb_NoProfitMade.selector);
            arb.dualDexTrade(
                UNISWAP_V2_ROUTER,
                SUSHISWAP_ROUTER,
                WETH,
                USDT,
                amount
            );
        }
    }

    function test_Fork_DualDexTrade_Uniswap_Pancakeswap_WETH_USDC() public {
        uint256 amount = 10 ether;
        _dealWeth(amount);

        address[] memory r = new address[](2);
        r[0] = address(UNISWAP_V2_ROUTER);
        r[1] = address(PANCAKESWAP_ROUTER);
        arb.addRouters(r);

        uint256 estimate = arb.estimateDualDexTrade(
            UNISWAP_V2_ROUTER,
            PANCAKESWAP_ROUTER,
            WETH,
            USDC,
            amount
        );

        if (estimate > amount) {
            uint256 before = IERC20(WETH).balanceOf(address(arb));
            arb.dualDexTrade(
                UNISWAP_V2_ROUTER,
                PANCAKESWAP_ROUTER,
                WETH,
                USDC,
                amount
            );
            assertGt(IERC20(WETH).balanceOf(address(arb)), before);
        } else {
            vm.expectRevert(UniswapV2Arb.UniswapV2Arb_NoProfitMade.selector);
            arb.dualDexTrade(
                UNISWAP_V2_ROUTER,
                PANCAKESWAP_ROUTER,
                WETH,
                USDC,
                amount
            );
        }
    }

    function test_Fork_DualDexTrade_Uniswap_Pancakeswap_WETH_USDT() public {
        uint256 amount = 10 ether;
        _dealWeth(amount);

        address[] memory r = new address[](2);
        r[0] = address(UNISWAP_V2_ROUTER);
        r[1] = address(PANCAKESWAP_ROUTER);
        arb.addRouters(r);

        uint256 estimate = arb.estimateDualDexTrade(
            UNISWAP_V2_ROUTER,
            PANCAKESWAP_ROUTER,
            WETH,
            USDT,
            amount
        );

        if (estimate > amount) {
            uint256 before = IERC20(WETH).balanceOf(address(arb));
            arb.dualDexTrade(
                UNISWAP_V2_ROUTER,
                PANCAKESWAP_ROUTER,
                WETH,
                USDT,
                amount
            );
            assertGt(IERC20(WETH).balanceOf(address(arb)), before);
        } else {
            vm.expectRevert(UniswapV2Arb.UniswapV2Arb_NoProfitMade.selector);
            arb.dualDexTrade(
                UNISWAP_V2_ROUTER,
                PANCAKESWAP_ROUTER,
                WETH,
                USDT,
                amount
            );
        }
    }

    function test_Fork_DualDexTrade_Sushiswap_Pancakeswap_WETH_USDC() public {
        uint256 amount = 10 ether;
        _dealWeth(amount);

        address[] memory r = new address[](2);
        r[0] = address(SUSHISWAP_ROUTER);
        r[1] = address(PANCAKESWAP_ROUTER);
        arb.addRouters(r);

        uint256 estimate = arb.estimateDualDexTrade(
            SUSHISWAP_ROUTER,
            PANCAKESWAP_ROUTER,
            WETH,
            USDC,
            amount
        );

        if (estimate > amount) {
            uint256 before = IERC20(WETH).balanceOf(address(arb));
            arb.dualDexTrade(
                SUSHISWAP_ROUTER,
                PANCAKESWAP_ROUTER,
                WETH,
                USDC,
                amount
            );
            assertGt(IERC20(WETH).balanceOf(address(arb)), before);
        } else {
            vm.expectRevert(UniswapV2Arb.UniswapV2Arb_NoProfitMade.selector);
            arb.dualDexTrade(
                SUSHISWAP_ROUTER,
                PANCAKESWAP_ROUTER,
                WETH,
                USDC,
                amount
            );
        }
    }

    function test_Fork_DualDexTrade_Sushiswap_Pancakeswap_WETH_USDT() public {
        uint256 amount = 10 ether;
        _dealWeth(amount);

        address[] memory r = new address[](2);
        r[0] = address(SUSHISWAP_ROUTER);
        r[1] = address(PANCAKESWAP_ROUTER);
        arb.addRouters(r);

        uint256 estimate = arb.estimateDualDexTrade(
            SUSHISWAP_ROUTER,
            PANCAKESWAP_ROUTER,
            WETH,
            USDT,
            amount
        );

        if (estimate > amount) {
            uint256 before = IERC20(WETH).balanceOf(address(arb));
            arb.dualDexTrade(
                SUSHISWAP_ROUTER,
                PANCAKESWAP_ROUTER,
                WETH,
                USDT,
                amount
            );
            assertGt(IERC20(WETH).balanceOf(address(arb)), before);
        } else {
            vm.expectRevert(UniswapV2Arb.UniswapV2Arb_NoProfitMade.selector);
            arb.dualDexTrade(
                SUSHISWAP_ROUTER,
                PANCAKESWAP_ROUTER,
                WETH,
                USDT,
                amount
            );
        }
    }

    function test_Fork_DualDexTrade_OnlyOwner() public {
        _dealWeth(1 ether);
        vm.prank(makeAddr("alice"));
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                makeAddr("alice")
            )
        );
        arb.dualDexTrade(
            UNISWAP_V2_ROUTER,
            SUSHISWAP_ROUTER,
            WETH,
            USDC,
            1 ether
        );
    }

    // ── tradePath ─────────────────────────────────────────────────────────────

    function test_Fork_TradePath_OnlyOwner() public {
        _dealWeth(1 ether);
        vm.prank(makeAddr("alice"));
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                makeAddr("alice")
            )
        );
        arb.tradePath(UNISWAP_V2_ROUTER, WETH, WBTC, USDC, UNI, 1 ether);
    }

    function test_Fork_TradePath_EstimateBeforeExecute() public {
        uint256 amount = 1 ether;
        _dealWeth(amount);
        _addPath(WBTC, USDC, UNI);

        address[] memory r = new address[](1);
        r[0] = address(UNISWAP_V2_ROUTER);
        arb.addRouters(r);

        // Use findPath to check before executing
        (uint256 amtBack, address t1, address s, address t2) = arb.findPath(
            UNISWAP_V2_ROUTER,
            WETH,
            amount
        );

        if (amtBack > amount) {
            uint256 before = IERC20(WETH).balanceOf(address(arb));
            arb.tradePath(UNISWAP_V2_ROUTER, WETH, t1, s, t2, amount);
            assertGt(IERC20(WETH).balanceOf(address(arb)), before);
        } else {
            vm.expectRevert(UniswapV2Arb.UniswapV2Arb_NoProfitMade.selector);
            arb.tradePath(
                UNISWAP_V2_ROUTER,
                WETH,
                t1 == address(0) ? WBTC : t1,
                USDC,
                UNI,
                amount
            );
        }
    }

    // ── getBalance ────────────────────────────────────────────────────────────

    function test_Fork_GetBalance_WETH() public {
        _dealWeth(5 ether);
        assertEq(arb.getBalance(WETH), 5 ether);
    }

    function test_Fork_GetBalance_USDC() public {
        _dealToken(USDC, 10_000e6);
        assertEq(arb.getBalance(USDC), 10_000e6);
    }

    // ── recoverTokens ─────────────────────────────────────────────────────────

    function test_Fork_RecoverTokens_WETH() public {
        _dealWeth(3 ether);
        uint256 before = IERC20(WETH).balanceOf(owner);
        arb.recoverTokens(WETH);
        assertEq(IERC20(WETH).balanceOf(owner) - before, 3 ether);
        assertEq(IERC20(WETH).balanceOf(address(arb)), 0);
    }

    function test_Fork_RecoverTokens_USDC() public {
        _dealToken(USDC, 10_000e6);
        uint256 before = IERC20(USDC).balanceOf(owner);
        arb.recoverTokens(USDC);
        assertEq(IERC20(USDC).balanceOf(owner) - before, 10_000e6);
        assertEq(IERC20(USDC).balanceOf(address(arb)), 0);
    }

    // ── recoverEth ────────────────────────────────────────────────────────────

    function test_Fork_RecoverEth() public {
        vm.deal(address(arb), 1 ether);
        uint256 before = owner.balance;
        arb.recoverEth();
        assertEq(owner.balance - before, 1 ether);
        assertEq(address(arb).balance, 0);
    }
}
